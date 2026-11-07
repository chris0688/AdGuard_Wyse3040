#!/usr/bin/env bash
# adguard-setup.sh – Grundeinrichtung des AdGuard-Servers (Hostname, Passwort, Neustart, IP)
#
# Auf dem Gerät installiert als:  /usr/local/sbin/adguard-setup
# Aufruf:                         sudo adguard-setup
#                                 sudo adguard-setup --update   (Projekt-Update von GitHub)
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
# adguard-backup mitgesichert. Dort stehen nur Codes (z.B. REBOOT_DAY=Sun), nie
# übersetzte Texte – ein Backup passt so auch auf ein Gerät mit anderer Sprache.
#
# Die AdGuard-Einrichtung (Admin-Benutzer, Upstreams, Filter) erfolgt über
# den Setup-Assistenten im Webinterface (Port 3000) und nicht hier.
#
# Texte: lang/<sprache>.sh, Abschnitte T_SETUP_* und T_UPDATE_* (siehe scripts/i18n.sh)
set -euo pipefail
. /usr/local/share/adguard/i18n.sh

STATE_DIR="/var/lib/adguard-setup"
DONE_FILE="$STATE_DIR/setup.done"
SETUP_CONF="/etc/adguard-setup.conf"
# Formatversion von /etc/adguard-setup.conf. Erhöhen, wenn sich Bedeutung oder
# Format eines Eintrags ändert (dann beim Einlesen umrechnen). Neue Einträge
# brauchen keine neue Version: Fehlende Werte werden einfach normal abgefragt.
CONF_VERSION=1
# Alle Einträge, die das Setup speichert. Neue Frage im Setup = neuen Eintrag hier
# und in save_settings ergänzen; Geräte ohne diesen Eintrag bekommen dann in der
# Begrüßung den Hinweis, adguard-setup erneut auszuführen.
SETTINGS_KEYS=(HOSTNAME REBOOT_TIME REBOOT_MODE REBOOT_DAY COCKPIT NET_MODE NET_ADDR NET_GW NET_DNS1 NET_DNS2)
ADGUARD_BACKUP="/usr/local/sbin/adguard-backup"

# Projekt-Update (sudo adguard-setup --update)
SETUP_DIR="/opt/adguard-setup"
# GitHub-Repo, aus dem Updates kommen (beim ISO-Bau in $SETUP_DIR/REPO hinterlegt)
DEFAULT_REPO="chris0688/AdGuard_Wyse3040"

NEED_REBOOT=0

# Vorschlagswerte aus einem Backup (leer = normale Standardwerte)
declare -A PRESET=()
# Netzwerk-Einstellung, falls in diesem Lauf geändert (sonst wird der Ist-Zustand gespeichert)
NET_MODE="" NET_ADDR="" NET_GW="" NET_DNS1="" NET_DNS2=""

# ---------------------------------------------------------------- Hilfsfunktionen

info()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn()  { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }
err()   { printf '\033[1;31m[x] %s\033[0m\n' "$*" >&2; }

# t "TEXT" ARGUMENTE... – übersetzten Text mit Platzhaltern ausgeben (ohne Zeilenende)
t() { local f="$1"; shift; printf -- "$f" "$@"; }

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
        warn "$(t "$T_NUMBER_RANGE" 1 $#)" >&2
    done
}

# yesno "Frage" "y|n" -> Rückgabewert 0 bei ja (siehe adguard_yesno in i18n.sh)
yesno() { adguard_yesno "$@"; }


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
        warn "$(t "$T_SETUP_INVALID_IPV4" "$v")" >&2
    done
}

# ---------------------------------------------------------------- Einstellungsdatei

# Liest KEY=WERT-Zeilen als Vorschlagswerte. Wird bewusst NICHT als Shell-Code
# ausgeführt (die Datei kann von einem USB-Stick stammen); nur bekannte Schlüssel
# und harmlose Zeichen werden übernommen.
load_presets() {
    local k v
    while IFS='=' read -r k v; do
        if [[ " ${SETTINGS_KEYS[*]} " == *" $k "* && $v =~ ^[A-Za-z0-9.:/_-]*$ ]]; then
            PRESET[$k]="$v"
        fi
    done < "$1"
}

# Neue Fragen im Setup erkennen (z.B. nach einem Projekt-Update): Jeder Schritt
# speichert seine Antwort als Eintrag in /etc/adguard-setup.conf. Fehlt dort ein
# Eintrag aus SETTINGS_KEYS, wurde diese Frage auf dem Gerät noch nie beantwortet.
# Ausgabe: fehlende Einträge; Rückgabe 1, wenn welche fehlen.
check_settings() {
    local k missing=()
    [[ -f $SETUP_CONF ]] || return 0   # Setup noch nie gelaufen: darauf weist die Begrüßung schon hin
    for k in "${SETTINGS_KEYS[@]}"; do
        grep -q "^$k=" "$SETUP_CONF" || missing+=("$k")
    done
    (( ${#missing[@]} == 0 )) && return 0
    echo "${missing[*]}"
    return 1
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

# Eingerichteter Neustart-Plan -> "none", "daily" oder "weekly <Tag>" (z.B. "weekly Sun")
current_reboot_plan() {
    local cal
    if systemctl is-enabled --quiet adguard-reboot.timer 2>/dev/null && [[ -f $REBOOT_TIMER ]]; then
        cal="$(sed -n 's/^OnCalendar=//p' "$REBOOT_TIMER")"
        if [[ $cal == '*-*-*'* ]]; then
            echo daily
        else
            echo "weekly ${cal%% *}"
        fi
    else
        echo none
    fi
}

# Schreibt die aktuellen Einstellungen nach /etc/adguard-setup.conf
save_settings() {
    local reboot_mode reboot_day="" cockpit=no
    read -r reboot_mode reboot_day < <(current_reboot_plan)
    dpkg -s cockpit-ws &>/dev/null && cockpit=yes
    [[ -n $NET_MODE ]] || detect_network_state

    {
        echo "# adguard-setup – gewählte Einstellungen (wird von adguard-backup mitgesichert)"
        echo "# Stand: $(date '+%Y-%m-%d %H:%M')"
        echo "CONF_VERSION=$CONF_VERSION"
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

    info "$T_SETUP_RESTORE_TITLE"
    t "$T_SETUP_RESTORE_FOUND\n" "$(cat "$dir/source.txt")"
    echo

    # Auswahl je nachdem, ob Systemeinstellungen im Backup enthalten sind
    local restore_agh=0 use_settings=0
    if [[ -f $dir/adguard-setup.conf ]]; then
        choice="$(choose "$T_CHOICE" 1 \
            "$T_SETUP_RESTORE_ALL" \
            "$T_SETUP_RESTORE_AGH_ONLY" \
            "$T_SETUP_RESTORE_NOTHING")"
        case "$choice" in
            1) restore_agh=1; use_settings=1 ;;
            2) restore_agh=1 ;;
        esac
    else
        choice="$(choose "$T_CHOICE" 1 \
            "$T_SETUP_RESTORE_AGH" \
            "$T_SETUP_RESTORE_NOTHING")"
        [[ $choice == 1 ]] && restore_agh=1
    fi

    if (( restore_agh )); then
        if "$ADGUARD_BACKUP" --restore-file "$dir/AdGuardHome.yaml"; then
            echo "$T_SETUP_RESTORE_DONE"
        else
            warn "$T_SETUP_RESTORE_FAILED"
        fi
    else
        echo "$T_SETUP_RESTORE_SKIPPED"
    fi
    if (( use_settings )); then
        load_presets "$dir/adguard-setup.conf"
        echo
        echo "$T_SETUP_PRESETS_1"
        echo "$T_SETUP_PRESETS_2"
    fi
    rm -rf "$dir"
}

# ---------------------------------------------------------------- 1. Hostname

step_hostname() {
    info "$T_SETUP_HOSTNAME_TITLE"
    local current new def=n suggestion
    current="$(hostname)"
    suggestion="$current"
    t "$T_SETUP_HOSTNAME_CURRENT\n" "$current"
    if [[ -n ${PRESET[HOSTNAME]:-} && ${PRESET[HOSTNAME]} != "$current" ]]; then
        t "$T_SETUP_FROM_BACKUP\n" "${PRESET[HOSTNAME]}"
        def=y
        suggestion="${PRESET[HOSTNAME]}"
    fi
    yesno "$T_SETUP_HOSTNAME_Q_CHANGE" "$def" || return 0

    new="$(ask "$T_SETUP_HOSTNAME_Q_NEW" "$suggestion")"
    if [[ ! $new =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
        warn "$T_SETUP_HOSTNAME_INVALID"
        return 0
    fi
    hostnamectl set-hostname "$new"
    # 127.0.1.1-Eintrag in /etc/hosts anpassen (Debian-Konvention)
    if grep -q '^127\.0\.1\.1' /etc/hosts; then
        sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$new/" /etc/hosts
    else
        printf '127.0.1.1\t%s\n' "$new" >> /etc/hosts
    fi
    t "$T_SETUP_HOSTNAME_SET\n" "$new"
}

# ---------------------------------------------------------------- 2. Linux-Passwort

step_linux_password() {
    info "$T_SETUP_PASSWORD_TITLE"
    local default_user user
    default_user="${SUDO_USER:-$(getent passwd 1000 | cut -d: -f1)}"
    yesno "$T_SETUP_PASSWORD_Q_CHANGE" n || return 0

    user="$(ask "$T_SETUP_PASSWORD_Q_USER" "${default_user:-root}")"
    if ! id "$user" &>/dev/null; then
        warn "$(t "$T_SETUP_PASSWORD_NO_USER" "$user")"
        return 0
    fi
    passwd "$user"
}

# ---------------------------------------------------------------- 3. Neustart-Zeitplan

REBOOT_TIMER="/etc/systemd/system/adguard-reboot.timer"
REBOOT_SERVICE="/etc/systemd/system/adguard-reboot.service"
APT_REBOOT_CONF="/etc/apt/apt.conf.d/53adguard-reboot-time"

step_reboot() {
    info "$T_SETUP_REBOOT_TITLE"
    local time freq day_nr day_code calendar desc i
    local def_time def_regular=y def_freq=1 def_day=7 days=()
    local -a DAY_CODES=(Mon Tue Wed Thu Fri Sat Sun)
    local plan_mode="${PRESET[REBOOT_MODE]:-}" plan_day="${PRESET[REBOOT_DAY]:-}"
    def_time="${PRESET[REBOOT_TIME]:-$(current_reboot_time)}"
    # Ohne Backup-Werte den eingerichteten Plan vorschlagen, damit Enter beim
    # erneuten Ausführen nichts verändert. Beim allerersten Lauf: Empfehlung.
    if [[ -z $plan_mode && -f $DONE_FILE ]]; then
        read -r plan_mode plan_day < <(current_reboot_plan)
    fi
    [[ $plan_mode == none ]] && def_regular=n
    [[ $plan_mode == daily ]] && def_freq=2
    for i in "${!DAY_CODES[@]}"; do
        [[ ${DAY_CODES[$i]} == "$plan_day" ]] && def_day=$((i + 1))
        days+=("$(weekday_name $((i + 1)))")
    done

    desc="$(adguard_reboot_text)"
    t "$T_SETUP_REBOOT_CURRENT\n" "${desc:-$T_SETUP_REBOOT_NONE}"
    # Die Uhrzeit gilt in der Zeitzone des Geräts (bei UTC evtl. nicht nachts!)
    t "$T_SETUP_REBOOT_SYSTEM_TIME\n" "$(date '+%H:%M')" \
        "$(timedatectl show -p Timezone --value 2>/dev/null || echo '?')"
    echo
    echo "$T_SETUP_REBOOT_INFO_1"
    echo "$T_SETUP_REBOOT_INFO_2"
    echo "$T_SETUP_REBOOT_INFO_3"
    echo

    while true; do
        time="$(ask "$T_SETUP_REBOOT_Q_TIME" "$def_time")"
        [[ $time =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] && break
        warn "$T_SETUP_REBOOT_TIME_FORMAT"
    done
    printf '// erzeugt von adguard-setup\nUnattended-Upgrade::Automatic-Reboot-Time "%s";\n' "$time" > "$APT_REBOOT_CONF"

    if ! yesno "$T_SETUP_REBOOT_Q_REGULAR" "$def_regular"; then
        if [[ -f $REBOOT_TIMER ]]; then
            systemctl disable --now adguard-reboot.timer 2>/dev/null || true
            rm -f "$REBOOT_TIMER" "$REBOOT_SERVICE"
            systemctl daemon-reload
        fi
        t "$T_SETUP_REBOOT_ONLY_UPDATES\n" "$time"
        return 0
    fi

    echo "$T_SETUP_REBOOT_Q_HOW_OFTEN"
    freq="$(choose "$T_CHOICE" "$def_freq" "$T_SETUP_REBOOT_WEEKLY" "$T_SETUP_REBOOT_DAILY")"
    if [[ $freq == 2 ]]; then
        calendar="*-*-*"
        desc="$(t "$T_REBOOT_DAILY" "$time")"
    else
        echo "$T_SETUP_REBOOT_Q_DAY"
        day_nr="$(choose "$T_CHOICE" "$def_day" "${days[@]}")"
        day_code="${DAY_CODES[$((day_nr - 1))]}"
        calendar="$day_code *-*-*"
        desc="$(t "$T_REBOOT_WEEKLY" "${days[$((day_nr - 1))]}" "$time")"
    fi

    # Die Beschreibung ist nur für systemctl; Begrüßung und Setup lesen OnCalendar
    cat > "$REBOOT_SERVICE" <<EOF
# erzeugt von adguard-setup
[Unit]
Description=$T_SETUP_REBOOT_SERVICE_DESC

[Service]
Type=oneshot
ExecStart=/usr/bin/systemctl reboot
EOF
    cat > "$REBOOT_TIMER" <<EOF
# erzeugt von adguard-setup – ändern mit: sudo adguard-setup
[Unit]
Description=$(t "$T_SETUP_REBOOT_TIMER_DESC" "$desc")

[Timer]
OnCalendar=$calendar $time:00
# Verpasste Termine (Gerät war aus) NICHT nachholen
Persistent=false

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now adguard-reboot.timer
    t "$T_SETUP_REBOOT_DONE\n" "$desc"
}

# ---------------------------------------------------------------- 4. Cockpit

step_cockpit() {
    info "$T_SETUP_COCKPIT_TITLE"
    local ip
    ip="$(hostname -I | awk '{print $1}')"
    if dpkg -s cockpit-ws &>/dev/null; then
        t "$T_SETUP_COCKPIT_INSTALLED\n" "https://$ip:9090"
        return 0
    fi
    echo "$T_SETUP_COCKPIT_INFO_1"
    t "$T_SETUP_COCKPIT_INFO_2\n" "https://$ip:9090"
    local def=n
    if [[ ${PRESET[COCKPIT]:-} == yes ]]; then
        echo "$T_SETUP_COCKPIT_IN_BACKUP"
        def=y
    fi
    yesno "$T_SETUP_COCKPIT_Q_INSTALL" "$def" || return 0

    # --no-install-recommends: sonst würde u.a. NetworkManager mitinstalliert und
    # die Netzwerkkonfiguration übernehmen.
    apt-get update -qq
    apt-get install -y --no-install-recommends \
        cockpit-ws cockpit-system cockpit-bridge cockpit-packagekit
    ufw allow 9090/tcp >/dev/null
    systemctl enable --now cockpit.socket
    # Web-Konsole in den Login-Banner aufnehmen
    /usr/local/sbin/adguard-banner || true
    t "$T_SETUP_COCKPIT_DONE\n" "https://$ip:9090"
    warn "$T_SETUP_CERT_WARNING"
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
        warn "$T_SETUP_NET_RESOLV_SYMLINK"
        return
    fi
    {
        echo "# erzeugt von adguard-setup"
        for d in "$@"; do [[ -n $d ]] && echo "nameserver $d"; done
    } > /etc/resolv.conf
}

step_network() {
    info "$T_SETUP_NET_TITLE"
    local iface backend cur mode addr gw dns1 dns2
    iface="$(detect_iface)"
    backend="$(detect_backend)"
    cur="$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4; exit}')"
    # DHCP-Adressen haben eine Ablaufzeit und sind als "dynamic" markiert
    local cur_dhcp=0 cur_mode="$T_SETUP_NET_STATIC_IP"
    if ip -4 -o addr show dev "$iface" 2>/dev/null | grep -q dynamic; then
        cur_dhcp=1
        cur_mode="DHCP"
    fi

    t "$T_SETUP_NET_CURRENT\n" "$iface" "${cur:-$T_SETUP_NET_NONE}" "$cur_mode" "$backend"
    echo
    echo "$T_SETUP_NET_INFO_1"
    echo "$T_SETUP_NET_INFO_2"
    echo "$T_SETUP_NET_INFO_3"
    echo

    local def_mode=3
    case "${PRESET[NET_MODE]:-}" in
        static)
            def_mode=2
            t "$T_SETUP_NET_BACKUP_STATIC\n" "${PRESET[NET_ADDR]:-?}" "${PRESET[NET_GW]:-?}"
            warn "$T_SETUP_NET_ADDR_IN_USE"
            echo ;;
        dhcp)
            def_mode=1
            t "$T_SETUP_FROM_BACKUP\n" "DHCP"
            echo ;;
    esac

    mode="$(choose "$T_CHOICE" "$def_mode" "$T_SETUP_NET_OPT_DHCP" "$T_SETUP_NET_OPT_STATIC" \
            "$(t "$T_SETUP_NET_OPT_KEEP" "$cur_mode")")"
    case "$mode" in
        2) mode=static ;;
        1) mode=dhcp
            if (( cur_dhcp )); then echo "$T_SETUP_NET_DHCP_ACTIVE"; return 0; fi ;;
        *)  echo "$T_SETUP_NET_UNCHANGED"; return 0 ;;
    esac
    iface="$(ask "$T_SETUP_NET_Q_IFACE" "$iface")"

    if [[ $mode == static ]]; then
        while true; do
            addr="$(ask "$T_SETUP_NET_Q_ADDR" "${PRESET[NET_ADDR]:-${cur:-192.168.1.53/24}}")"
            valid_cidr "$addr" && break
            warn "$T_SETUP_NET_ADDR_FORMAT"
        done
        gw="$(ask_ipv4 "$T_SETUP_NET_Q_GW" "${PRESET[NET_GW]:-$(ip -4 route show default | awk '{print $3; exit}')}")"
        # Das Gerät selbst nicht über den eigenen AdGuard auflösen lassen – sonst
        # gehen Updates nicht, wenn AdGuard mal hängt.
        dns1="$(ask_ipv4 "$T_SETUP_NET_Q_DNS1" "${PRESET[NET_DNS1]:-$gw}")"
        # "-" statt ":-": ein im Backup bewusst leerer zweiter DNS bleibt leer
        dns2="$(ask "$T_SETUP_NET_Q_DNS2" "${PRESET[NET_DNS2]-9.9.9.9}")"
        if [[ -n $dns2 ]] && ! valid_ipv4 "$dns2"; then
            warn "$T_SETUP_NET_DNS2_INVALID"
            dns2=""
        fi
    fi

    echo
    t "$T_SETUP_NET_SUMMARY\n" "$iface -> $mode ${addr:-} ${gw:+gw $gw} ${dns1:+dns $dns1 $dns2}"
    yesno "$T_SETUP_NET_Q_APPLY" y || { warn "$T_SETUP_NET_UNCHANGED"; return 0; }

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
            err "$T_SETUP_NET_UNKNOWN_BACKEND"
            return 0
            ;;
    esac

    # Für /etc/adguard-setup.conf merken (gilt erst nach dem Neustart)
    NET_MODE="$mode" NET_ADDR="${addr:-}" NET_GW="${gw:-}" NET_DNS1="${dns1:-}" NET_DNS2="${dns2:-}"

    echo "$T_SETUP_NET_DONE"
    [[ $mode == static ]] && t "$T_SETUP_NET_NEW_URL\n" "http://${addr%/*}/"
    NEED_REBOOT=1
}

# ---------------------------------------------------------------- Projekt-Update

# Installierte Projektversion, z.B. "v1.0.0" (erstes Wort aus $SETUP_DIR/VERSION)
installed_version() {
    awk 'NR == 1 {print $1}' "$SETUP_DIR/VERSION" 2>/dev/null
}

# version_gt A B -> wahr, wenn A neuer ist als B (v1.0.10 > v1.0.9)
version_gt() {
    [[ $1 != "$2" && $(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1) == "$1" ]]
}

# Abschnitte aus CHANGELOG.md, die neuer als die installierte Version sind
# (bei unbekannter Version nur der neueste Abschnitt)
show_changes() {
    local file="$1" from="$2" line ver show=0 shown=0
    [[ -f $file ]] || { echo "  ($T_UPDATE_NO_CHANGELOG)"; return; }
    while IFS= read -r line; do
        if [[ $line =~ ^##[[:space:]]+(v[0-9][0-9A-Za-z.-]*) ]]; then
            ver="${BASH_REMATCH[1]}"
            show=0
            if [[ $from =~ ^v[0-9] ]]; then
                version_gt "$ver" "$from" && show=1
            else
                (( shown == 0 )) && show=1
            fi
            (( show )) && shown=$((shown + 1))
        fi
        (( show )) && echo "  $line"
    done < "$file"
    (( shown )) || echo "  ($T_UPDATE_NO_ENTRIES)"
}

do_update() {
    local repo current latest tmp changelog
    repo="$(cat "$SETUP_DIR/REPO" 2>/dev/null || true)"
    [[ $repo =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || repo="$DEFAULT_REPO"
    current="$(installed_version)"

    info "$T_UPDATE_TITLE"
    t "$T_UPDATE_SEARCHING\n" "github.com/$repo"
    latest="$(curl -fsSL --max-time 20 "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null \
              | sed -n 's/^[[:space:]]*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
    if [[ ! $latest =~ ^v[0-9][0-9A-Za-z.-]*$ ]]; then
        err "$T_UPDATE_NO_LATEST"
        return 1
    fi

    echo
    t "  $T_UPDATE_INSTALLED\n" "${current:-$T_UPDATE_UNKNOWN}"
    t "  $T_UPDATE_AVAILABLE\n" "$latest"
    if [[ $current == "$latest" ]] || { [[ $current =~ ^v[0-9] ]] && ! version_gt "$latest" "$current"; }; then
        echo
        info "$(t "$T_UPDATE_UP_TO_DATE" "$current")"
        return 0
    fi

    tmp="$(mktemp -d)"
    # Aufruf endet direkt nach do_update (siehe main). Pfad schon hier einsetzen:
    # beim EXIT ist die lokale Variable $tmp nicht mehr gültig (set -u).
    trap "rm -rf -- '$tmp'" EXIT
    if ! curl -fsSL --max-time 120 "https://github.com/$repo/archive/refs/tags/$latest.tar.gz" \
            | tar -xz -C "$tmp" --strip-components=1 \
       || [[ ! -f $tmp/scripts/install.sh ]]; then
        err "$(t "$T_UPDATE_DOWNLOAD_FAILED" "$latest")"
        return 1
    fi

    # Änderungsliste in der Sprache des Geräts, sonst die englische
    changelog="$tmp/CHANGELOG.$TEXTS.md"
    [[ -f $changelog ]] || changelog="$tmp/CHANGELOG.md"

    echo
    echo "  $T_UPDATE_CHANGES"
    echo "  ----------------------------------------------------------------"
    show_changes "$changelog" "$current"
    echo "  ----------------------------------------------------------------"
    t "  $T_UPDATE_DETAILS\n" "https://github.com/$repo/releases"
    echo
    warn "$T_UPDATE_READ_FIRST"
    echo "$T_UPDATE_WARNING"
    echo
    local answer
    read -rp "$(t "$T_UPDATE_Q_CONFIRM" "$T_UPDATE_CONFIRM_WORD") " answer
    if [[ ${answer,,} != "${T_UPDATE_CONFIRM_WORD,,}" && ${answer,,} != yes ]]; then
        echo "$T_UPDATE_CANCELLED"
        return 0
    fi

    info "$T_UPDATE_BACKING_UP"
    [[ -x $ADGUARD_BACKUP ]] && "$ADGUARD_BACKUP" --auto || true

    info "$(t "$T_UPDATE_INSTALLING" "$latest")"
    rm -rf "$SETUP_DIR.new"
    cp -a "$tmp" "$SETUP_DIR.new"
    echo "$latest ($(t "$T_UPDATE_VERSION_NOTE" "$(date "+$DATE_FORMAT")"))" > "$SETUP_DIR.new/VERSION"
    echo "$repo" > "$SETUP_DIR.new/REPO"
    chmod 755 "$SETUP_DIR.new" "$SETUP_DIR.new"/scripts/*.sh
    rm -rf "$SETUP_DIR"
    mv "$SETUP_DIR.new" "$SETUP_DIR"
    if ! "$SETUP_DIR/scripts/install.sh" > /var/log/adguard-setup-update.log 2>&1; then
        err "$(t "$T_UPDATE_INSTALL_FAILED" /var/log/adguard-setup-update.log)"
        return 1
    fi

    info "$(t "$T_UPDATE_DONE" "$latest")"
    echo
    /etc/update-motd.d/99-custom-motd 2>/dev/null || true
}

# ---------------------------------------------------------------- main

main() {
    if [[ $EUID -ne 0 ]]; then
        err "$(t "$T_NEED_ROOT" "$0")"
        exit 1
    fi

    case "${1:-}" in
        --update)
            # exit direkt hier: install.sh ersetzt dieses Skript, Bash soll danach
            # nichts mehr aus der Datei nachlesen
            do_update
            exit $? ;;
        --check)
            # für die Begrüßung: gibt es Fragen, die noch nie beantwortet wurden?
            check_settings
            exit $? ;;
        --version)
            echo "AdGuard-Wyse3040 $(cat "$SETUP_DIR/VERSION" 2>/dev/null || echo "$T_UPDATE_UNKNOWN")"
            exit 0 ;;
        "") ;;
        *)  echo "$T_SETUP_USAGE"
            exit 2 ;;
    esac

    echo "======================================================"
    echo "  $T_SETUP_TITLE"
    echo "======================================================"
    if [[ -f $DONE_FILE ]]; then
        t "$T_SETUP_LAST_RUN\n" "$(adguard_date -d "$(cat "$DONE_FILE")" 2>/dev/null || cat "$DONE_FILE")"
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

    info "$T_SETUP_DONE"
    if (( NEED_REBOOT )); then
        warn "$T_SETUP_REBOOT_NEEDED"
        warn "$T_SETUP_REBOOT_NEW_IP"
        if yesno "$T_SETUP_Q_REBOOT_NOW" y; then
            systemctl reboot
            return 0
        fi
        warn "$T_SETUP_REBOOT_LATER"
    fi

    # Ergebnis gleich als Systemübersicht anzeigen (wie der Befehl "status")
    echo
    /etc/update-motd.d/99-custom-motd 2>/dev/null || true
}

main "$@"
