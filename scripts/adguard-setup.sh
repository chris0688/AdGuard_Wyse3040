#!/usr/bin/env bash
# adguard-setup.sh – Grundeinrichtung des AdGuard-Servers (Hostname, Passwort, Neustart, IP)
#
# Auf dem Gerät installiert als:  /usr/local/sbin/adguard-setup
# Aufruf:                         sudo adguard-setup
#
# Schritte (jeder einzeln überspringbar):
#   0. nur beim ersten Lauf: Backup von USB-Stick übernehmen (AdGuard und/oder
#      diese Einstellungen als Vorschlagswerte)
#   1. Hostname setzen
#   2. Linux-Passwort ändern
#   3. Automatischer Neustart: täglich/wöchentlich, Uhrzeit (auch für Updates)
#   4. Web-Verwaltung Cockpit installieren (optional)
#   5. Netzwerk: DHCP oder feste IP
#
# Die gewählten Einstellungen landen in /etc/adguard-setup.conf und werden von
# adguard-backup mitgesichert.
#
# Die AdGuard-Einrichtung (Admin-Benutzer, Upstreams, Filter) erfolgt über
# den Setup-Assistenten im Webinterface (Port 3000) und nicht hier.
set -euo pipefail

STATE_DIR="/var/lib/adguard-setup"
DONE_FILE="$STATE_DIR/setup.done"
SETUP_CONF="/etc/adguard-setup.conf"
ADGUARD_BACKUP="/usr/local/sbin/adguard-backup"

NEED_REBOOT=0

# Vorschlagswerte aus einem Backup (leer = normale Standardwerte)
declare -A PRESET=()
# Netzwerk-Einstellung, falls in diesem Lauf geändert (sonst wird der Ist-Zustand gespeichert)
NET_MODE="" NET_ADDR="" NET_GW="" NET_DNS1="" NET_DNS2=""

# ---------------------------------------------------------------- Hilfsfunktionen

info()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn()  { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }
err()   { printf '\033[1;31m[x] %s\033[0m\n' "$*" >&2; }

# ask "Frage" "Default" -> Antwort auf stdout
ask() {
    local answer
    read -rp "$1 [${2}]: " answer
    echo "${answer:-$2}"
}

# choose "Frage" <standard-nr> "Option 1" "Option 2" ... -> gewählte Nummer auf stdout
choose() {
    local question="$1" def="$2" i=1 opt answer
    shift 2
    for opt in "$@"; do
        printf '  %d) %s\n' "$i" "$opt" >&2
        i=$((i + 1))
    done
    while true; do
        read -rp "$question [$def]: " answer
        answer="${answer:-$def}"
        if [[ $answer =~ ^[0-9]+$ ]] && (( answer >= 1 && answer <= $# )); then
            echo "$answer"
            return
        fi
        warn "Bitte eine Zahl von 1 bis $# eingeben." >&2
    done
}

# yesno "Frage" "j|n" -> Rückgabewert 0 bei ja
yesno() {
    local def="$2" answer
    read -rp "$1 [$( [[ $def == j ]] && echo 'J/n' || echo 'j/N' )]: " answer
    answer="${answer:-$def}"
    [[ ${answer,,} == j* || ${answer,,} == y* ]]
}


valid_ipv4() {
    local ip="$1" IFS=. o
    [[ $ip =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    for o in $ip; do (( o <= 255 )) || return 1; done
}

valid_cidr() {
    [[ $1 == */* ]] || return 1
    valid_ipv4 "${1%/*}" && [[ ${1#*/} =~ ^[0-9]+$ ]] && (( ${1#*/} >= 1 && ${1#*/} <= 32 ))
}

ask_ipv4() {   # ask_ipv4 "Frage" "Default"
    local v
    while true; do
        v="$(ask "$1" "$2")"
        valid_ipv4 "$v" && { echo "$v"; return; }
        warn "Ungültige IPv4-Adresse: $v" >&2
    done
}

# ---------------------------------------------------------------- Einstellungsdatei

# Liest KEY=WERT-Zeilen als Vorschlagswerte. Wird bewusst NICHT als Shell-Code
# ausgeführt (die Datei kann von einem USB-Stick stammen); nur bekannte Schlüssel
# und harmlose Zeichen werden übernommen.
load_presets() {
    local k v
    while IFS='=' read -r k v; do
        case "$k" in
            HOSTNAME|REBOOT_TIME|REBOOT_MODE|REBOOT_DAY|COCKPIT|NET_MODE|NET_ADDR|NET_GW|NET_DNS1|NET_DNS2)
                [[ $v =~ ^[A-Za-z0-9.:/_-]*$ ]] && PRESET[$k]="$v" ;;
        esac
    done < "$1"
}

# Aktuelle Uhrzeit für Neustarts (aus der apt-Einstellung), sonst 04:00
current_reboot_time() {
    local t=""
    [[ -f $APT_REBOOT_CONF ]] && t="$(grep -oE '[0-9]{2}:[0-9]{2}' "$APT_REBOOT_CONF" | head -n1 || true)"
    echo "${t:-04:00}"
}

# Netzwerk-Ist-Zustand in NET_* übernehmen (wenn in diesem Lauf nichts geändert wurde)
detect_network_state() {
    local iface
    iface="$(detect_iface)"
    if ip -4 -o addr show dev "$iface" 2>/dev/null | grep -q dynamic; then
        NET_MODE=dhcp
    else
        NET_MODE=static
        NET_ADDR="$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4; exit}')"
        NET_GW="$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}')"
        NET_DNS1="$(awk '/^nameserver [0-9.]+$/ {print $2}' /etc/resolv.conf 2>/dev/null | sed -n 1p)"
        NET_DNS2="$(awk '/^nameserver [0-9.]+$/ {print $2}' /etc/resolv.conf 2>/dev/null | sed -n 2p)"
    fi
}

# Schreibt die aktuellen Einstellungen nach /etc/adguard-setup.conf
save_settings() {
    local reboot_mode=none reboot_day="" cal cockpit=no
    if systemctl is-enabled --quiet adguard-reboot.timer 2>/dev/null && [[ -f $REBOOT_TIMER ]]; then
        cal="$(sed -n 's/^OnCalendar=//p' "$REBOOT_TIMER")"
        if [[ $cal == '*-*-*'* ]]; then
            reboot_mode=daily
        else
            reboot_mode=weekly
            reboot_day="${cal%% *}"
        fi
    fi
    dpkg -s cockpit-ws &>/dev/null && cockpit=yes
    [[ -n $NET_MODE ]] || detect_network_state

    {
        echo "# adguard-setup – gewählte Einstellungen (wird von adguard-backup mitgesichert)"
        echo "# Stand: $(date '+%d.%m.%Y %H:%M')"
        echo "HOSTNAME=$(hostname)"
        echo "REBOOT_TIME=$(current_reboot_time)"
        echo "REBOOT_MODE=$reboot_mode"
        echo "REBOOT_DAY=$reboot_day"
        echo "COCKPIT=$cockpit"
        echo "NET_MODE=$NET_MODE"
        echo "NET_ADDR=$NET_ADDR"
        echo "NET_GW=$NET_GW"
        echo "NET_DNS1=$NET_DNS1"
        echo "NET_DNS2=$NET_DNS2"
    } > "$SETUP_CONF"
}

# ---------------------------------------------------------------- 0. Backup übernehmen

step_restore() {
    # Nur bei der allerersten Einrichtung anbieten (später: sudo adguard-backup)
    [[ -f $DONE_FILE ]] && return 0
    [[ -x $ADGUARD_BACKUP ]] || return 0

    local dir choice
    dir="$(mktemp -d)"
    if ! "$ADGUARD_BACKUP" --fetch-usb "$dir" >/dev/null 2>&1; then
        rm -rf "$dir"
        return 0          # kein Stick mit Backup – normal weiter
    fi

    info "Backup auf USB-Stick gefunden"
    echo "Gefunden: $(cat "$dir/source.txt")"
    echo

    # Auswahl je nachdem, ob Systemeinstellungen im Backup enthalten sind
    local restore_agh=0 use_settings=0
    if [[ -f $dir/adguard-setup.conf ]]; then
        choice="$(choose "Auswahl" 1 \
            "AdGuard + Systemeinstellungen übernehmen (empfohlen)" \
            "nur AdGuard übernehmen" \
            "nichts übernehmen, neu einrichten")"
        case "$choice" in
            1) restore_agh=1; use_settings=1 ;;
            2) restore_agh=1 ;;
        esac
    else
        choice="$(choose "Auswahl" 1 \
            "AdGuard übernehmen (empfohlen)" \
            "nichts übernehmen, neu einrichten")"
        [[ $choice == 1 ]] && restore_agh=1
    fi

    if (( restore_agh )); then
        if "$ADGUARD_BACKUP" --restore-file "$dir/AdGuardHome.yaml"; then
            echo "AdGuard-Einstellungen übernommen – der Einrichtungsassistent ist nicht mehr nötig."
        else
            warn "AdGuard-Einstellungen konnten nicht übernommen werden."
        fi
    else
        echo "Es wird nichts übernommen."
    fi
    if (( use_settings )); then
        load_presets "$dir/adguard-setup.conf"
        echo
        echo "Die folgenden Fragen sind mit den Werten aus dem Backup vorausgefüllt."
        echo "Einfach mit Enter bestätigen oder bei Bedarf ändern."
    fi
    rm -rf "$dir"
}

# ---------------------------------------------------------------- 1. Hostname

step_hostname() {
    info "Hostname"
    local current new def=n suggestion
    current="$(hostname)"
    suggestion="$current"
    echo "Aktueller Hostname: $current"
    if [[ -n ${PRESET[HOSTNAME]:-} && ${PRESET[HOSTNAME]} != "$current" ]]; then
        echo "Aus dem Backup:     ${PRESET[HOSTNAME]}"
        def=j
        suggestion="${PRESET[HOSTNAME]}"
    fi
    yesno "Hostname ändern?" "$def" || return 0

    new="$(ask "Neuer Hostname" "$suggestion")"
    if [[ ! $new =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
        warn "Ungültiger Hostname – übersprungen."
        return 0
    fi
    hostnamectl set-hostname "$new"
    # 127.0.1.1-Eintrag in /etc/hosts anpassen (Debian-Konvention)
    if grep -q '^127\.0\.1\.1' /etc/hosts; then
        sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$new/" /etc/hosts
    else
        printf '127.0.1.1\t%s\n' "$new" >> /etc/hosts
    fi
    echo "Hostname gesetzt: $new"
}

# ---------------------------------------------------------------- 2. Linux-Passwort

step_linux_password() {
    info "Linux-Benutzerpasswort"
    local default_user user
    default_user="${SUDO_USER:-$(getent passwd 1000 | cut -d: -f1)}"
    yesno "Passwort eines Linux-Benutzers ändern?" n || return 0

    user="$(ask "Benutzer" "${default_user:-root}")"
    if ! id "$user" &>/dev/null; then
        warn "Benutzer '$user' existiert nicht – übersprungen."
        return 0
    fi
    passwd "$user"
}

# ---------------------------------------------------------------- 3. Neustart-Zeitplan

REBOOT_TIMER="/etc/systemd/system/adguard-reboot.timer"
REBOOT_SERVICE="/etc/systemd/system/adguard-reboot.service"
APT_REBOOT_CONF="/etc/apt/apt.conf.d/53adguard-reboot-time"

step_reboot() {
    info "Automatischer Neustart"
    local time freq day_nr day day_en desc
    local def_time def_regular=j def_freq=1 def_day=7
    local -a DAYS_DE=(Montag Dienstag Mittwoch Donnerstag Freitag Samstag Sonntag)
    local -a DAYS_EN=(Mon Tue Wed Thu Fri Sat Sun)
    def_time="${PRESET[REBOOT_TIME]:-$(current_reboot_time)}"
    [[ ${PRESET[REBOOT_MODE]:-} == none ]] && def_regular=n
    [[ ${PRESET[REBOOT_MODE]:-} == daily ]] && def_freq=2
    case "${PRESET[REBOOT_DAY]:-}" in
        Mon) def_day=1 ;; Tue) def_day=2 ;; Wed) def_day=3 ;; Thu) def_day=4 ;;
        Fri) def_day=5 ;; Sat) def_day=6 ;; Sun) def_day=7 ;;
    esac

    if systemctl is-enabled --quiet adguard-reboot.timer 2>/dev/null; then
        echo "Aktuell: $(systemctl show -p Description --value adguard-reboot.timer)"
    else
        echo "Aktuell: kein regelmäßiger Neustart eingerichtet."
    fi
    echo
    echo "Ein regelmäßiger Neustart hält das System auf Dauer stabil. Während des"
    echo "Neustarts (ca. 1 Minute) ist DNS im Netz nicht erreichbar, deshalb nachts."
    echo "Die Uhrzeit gilt auch für Neustarts, die nach automatischen Updates nötig sind."
    echo

    while true; do
        time="$(ask "Uhrzeit für Neustarts (HH:MM)" "$def_time")"
        [[ $time =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] && break
        warn "Bitte im Format HH:MM angeben, z.B. 04:00."
    done
    printf '// erzeugt von adguard-setup\nUnattended-Upgrade::Automatic-Reboot-Time "%s";\n' "$time" > "$APT_REBOOT_CONF"

    if ! yesno "Regelmäßigen Neustart einrichten? (empfohlen)" "$def_regular"; then
        if [[ -f $REBOOT_TIMER ]]; then
            systemctl disable --now adguard-reboot.timer 2>/dev/null || true
            rm -f "$REBOOT_TIMER" "$REBOOT_SERVICE"
            systemctl daemon-reload
        fi
        echo "Kein regelmäßiger Neustart. Neustarts nach Updates: $time Uhr."
        return 0
    fi

    echo "Wie oft?"
    freq="$(choose "Auswahl" "$def_freq" "wöchentlich" "täglich")"
    if [[ $freq == 2 ]]; then
        day_en="*-*-*"
        desc="täglich um $time Uhr"
    else
        echo "An welchem Wochentag?"
        day_nr="$(choose "Auswahl" "$def_day" "${DAYS_DE[@]}")"
        day="${DAYS_DE[$((day_nr - 1))]}"
        day_en="${DAYS_EN[$((day_nr - 1))]} *-*-*"
        desc="wöchentlich am $day um $time Uhr"
    fi

    cat > "$REBOOT_SERVICE" <<EOF
# erzeugt von adguard-setup
[Unit]
Description=Regelmäßiger Neustart

[Service]
Type=oneshot
ExecStart=/usr/bin/systemctl reboot
EOF
    cat > "$REBOOT_TIMER" <<EOF
# erzeugt von adguard-setup – ändern mit: sudo adguard-setup
[Unit]
Description=Neustart $desc

[Timer]
OnCalendar=$day_en $time:00
# Verpasste Termine (Gerät war aus) NICHT nachholen
Persistent=false

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now adguard-reboot.timer
    echo "Eingerichtet: Neustart $desc."
}

# ---------------------------------------------------------------- 4. Cockpit

step_cockpit() {
    info "Web-Verwaltung (Cockpit)"
    local ip
    ip="$(hostname -I | awk '{print $1}')"
    if dpkg -s cockpit-ws &>/dev/null; then
        echo "Cockpit ist installiert: https://$ip:9090"
        return 0
    fi
    echo "Cockpit ist eine Weboberfläche für die Linux-Verwaltung: Terminal im"
    echo "Browser, Updates, Logs, Dienste, Neustart. Adresse danach: https://$ip:9090"
    local def=n
    if [[ ${PRESET[COCKPIT]:-} == yes ]]; then
        echo "Laut Backup war Cockpit installiert."
        def=j
    fi
    yesno "Cockpit installieren?" "$def" || return 0

    # --no-install-recommends: sonst würde u.a. NetworkManager mitinstalliert und
    # die Netzwerkkonfiguration übernehmen.
    apt-get update -qq
    apt-get install -y --no-install-recommends \
        cockpit-ws cockpit-system cockpit-bridge cockpit-packagekit
    ufw allow 9090/tcp >/dev/null
    systemctl enable --now cockpit.socket
    # Web-Konsole in den Login-Banner aufnehmen
    /usr/local/sbin/adguard-banner || true
    echo "Cockpit installiert: https://$ip:9090  (Login mit dem Linux-Benutzer)"
    warn "Der Browser warnt beim ersten Aufruf vor dem selbst signierten Zertifikat – das ist normal."
}

# ---------------------------------------------------------------- 5. Netzwerk

detect_iface() {
    local i
    i="$(ip -o route show default 2>/dev/null | awk '{print $5; exit}')"
    if [[ -z $i ]]; then
        i="$(ip -o link show | awk -F': ' '$2 != "lo" {print $2; exit}' | cut -d@ -f1)"
    fi
    echo "$i"
}

detect_backend() {
    if systemctl is-active --quiet NetworkManager 2>/dev/null; then
        echo networkmanager
    elif systemctl is-active --quiet systemd-networkd 2>/dev/null; then
        echo networkd
    elif [[ -f /etc/network/interfaces ]]; then
        echo ifupdown
    else
        echo unknown
    fi
}

write_resolv_conf() {   # write_resolv_conf dns1 [dns2]
    if [[ -L /etc/resolv.conf ]]; then
        warn "/etc/resolv.conf ist ein Symlink (resolvconf/systemd-resolved) – nicht angefasst."
        return
    fi
    {
        echo "# erzeugt von adguard-setup"
        for d in "$@"; do [[ -n $d ]] && echo "nameserver $d"; done
    } > /etc/resolv.conf
}

step_network() {
    info "Netzwerk"
    local iface backend cur mode addr gw dns1 dns2
    iface="$(detect_iface)"
    backend="$(detect_backend)"
    cur="$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4; exit}')"
    # DHCP-Adressen haben eine Ablaufzeit und sind als "dynamic" markiert
    local cur_mode="feste IP"
    ip -4 -o addr show dev "$iface" 2>/dev/null | grep -q dynamic && cur_mode="DHCP"

    echo "Schnittstelle: $iface   Adresse: ${cur:-keine}   Modus: $cur_mode   Verwaltung: $backend"
    echo
    echo "Ein DNS-Server sollte immer unter derselben Adresse erreichbar sein. Dafür"
    echo "entweder hier eine feste IP vergeben oder im Router für dieses Gerät eine"
    echo "feste DHCP-Adresse reservieren (dann DHCP behalten)."
    echo

    local def_mode=3
    case "${PRESET[NET_MODE]:-}" in
        static)
            def_mode=2
            echo "Aus dem Backup: feste IP ${PRESET[NET_ADDR]:-?}, Gateway ${PRESET[NET_GW]:-?}"
            warn "Diese Adresse darf im Netz nicht schon vergeben sein (z.B. durch das alte Gerät)."
            echo ;;
        dhcp)
            def_mode=1
            echo "Aus dem Backup: DHCP"
            echo ;;
    esac

    mode="$(choose "Auswahl" "$def_mode" "DHCP (Adresse vom Router)" "feste IP vergeben" "unverändert lassen ($cur_mode)")"
    case "$mode" in
        2) mode=static ;;
        1) mode=dhcp
            if [[ $cur_mode == DHCP ]]; then echo "DHCP ist bereits aktiv."; return 0; fi ;;
        *)  echo "Netzwerk bleibt unverändert."; return 0 ;;
    esac
    iface="$(ask "Schnittstelle" "$iface")"

    if [[ $mode == static ]]; then
        mode=static
        while true; do
            addr="$(ask "IP-Adresse mit Präfix (z.B. 192.168.1.53/24)" "${PRESET[NET_ADDR]:-${cur:-192.168.1.53/24}}")"
            valid_cidr "$addr" && break
            warn "Bitte im Format a.b.c.d/nn angeben."
        done
        gw="$(ask_ipv4 "Gateway (Router)" "${PRESET[NET_GW]:-$(ip -4 route show default | awk '{print $3; exit}')}")"
        # Das Gerät selbst nicht über den eigenen AdGuard auflösen lassen – sonst
        # gehen Updates nicht, wenn AdGuard mal hängt.
        dns1="$(ask_ipv4 "DNS-Server für das Gerät selbst" "${PRESET[NET_DNS1]:-$gw}")"
        # "-" statt ":-": ein im Backup bewusst leerer zweiter DNS bleibt leer
        dns2="$(ask "Zweiter DNS-Server (leer = keiner)" "${PRESET[NET_DNS2]-9.9.9.9}")"
        if [[ -n $dns2 ]] && ! valid_ipv4 "$dns2"; then
            warn "Ungültiger zweiter DNS – wird ignoriert."
            dns2=""
        fi
    fi

    echo
    echo "Zusammenfassung: $iface -> $mode ${addr:-} ${gw:+gw $gw} ${dns1:+dns $dns1 $dns2}"
    yesno "So übernehmen?" j || { warn "Netzwerk unverändert."; return 0; }

    case "$backend" in
        ifupdown)
            cp -a /etc/network/interfaces "/etc/network/interfaces.bak.$(date +%Y%m%d%H%M%S)"
            {
                echo "# erzeugt von adguard-setup – Backup: /etc/network/interfaces.bak.*"
                echo "source /etc/network/interfaces.d/*"
                echo
                echo "auto lo"
                echo "iface lo inet loopback"
                echo
                echo "allow-hotplug $iface"
                if [[ $mode == static ]]; then
                    echo "iface $iface inet static"
                    echo "    address $addr"
                    echo "    gateway $gw"
                else
                    echo "iface $iface inet dhcp"
                fi
            } > /etc/network/interfaces
            [[ $mode == static ]] && write_resolv_conf "$dns1" "$dns2"
            ;;
        networkd)
            local f="/etc/systemd/network/10-$iface.network"
            {
                echo "# erzeugt von adguard-setup"
                echo "[Match]"
                echo "Name=$iface"
                echo
                echo "[Network]"
                if [[ $mode == static ]]; then
                    echo "Address=$addr"
                    echo "Gateway=$gw"
                    echo "DNS=$dns1"
                    [[ -n $dns2 ]] && echo "DNS=$dns2"
                else
                    echo "DHCP=ipv4"
                fi
            } > "$f"
            ;;
        networkmanager)
            local con
            con="$(nmcli -g GENERAL.CONNECTION device show "$iface" | head -n1)"
            if [[ $mode == static ]]; then
                nmcli con mod "$con" ipv4.method manual ipv4.addresses "$addr" \
                    ipv4.gateway "$gw" ipv4.dns "$dns1${dns2:+ $dns2}"
            else
                nmcli con mod "$con" ipv4.method auto ipv4.addresses "" ipv4.gateway "" ipv4.dns ""
            fi
            ;;
        *)
            err "Unbekannte Netzwerkverwaltung – bitte manuell konfigurieren."
            return 0
            ;;
    esac

    # Für /etc/adguard-setup.conf merken (gilt erst nach dem Neustart)
    NET_MODE="$mode" NET_ADDR="${addr:-}" NET_GW="${gw:-}" NET_DNS1="${dns1:-}" NET_DNS2="${dns2:-}"

    echo "Netzwerk konfiguriert. Wird nach dem Neustart aktiv."
    [[ $mode == static ]] && echo "AdGuard ist dann erreichbar unter: http://${addr%/*}/"
    NEED_REBOOT=1
}

# ---------------------------------------------------------------- main

main() {
    if [[ $EUID -ne 0 ]]; then
        err "Bitte als root ausführen: sudo $0"
        exit 1
    fi

    echo "======================================================"
    echo "  AdGuard Home – Grundeinrichtung"
    echo "======================================================"
    if [[ -f $DONE_FILE ]]; then
        echo "Zuletzt ausgeführt: $(cat "$DONE_FILE")"
    fi

    step_restore
    step_hostname
    step_linux_password
    step_reboot
    step_cockpit
    step_network

    save_settings
    # Einstellungen gleich mitsichern (sonst erst in der nächsten Nacht)
    [[ -x $ADGUARD_BACKUP ]] && "$ADGUARD_BACKUP" --auto >/dev/null 2>&1 || true

    mkdir -p "$STATE_DIR"
    date '+%Y-%m-%d %H:%M' > "$DONE_FILE"

    info "Fertig."
    if (( NEED_REBOOT )); then
        warn "Ein Neustart ist nötig, damit alle Änderungen greifen."
        warn "Bei SSH-Verbindung: nach dem Neustart ggf. mit der NEUEN IP verbinden."
        if yesno "Jetzt neu starten?" j; then systemctl reboot; fi
    fi
}

main "$@"
