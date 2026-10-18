#!/usr/bin/env bash
# wyse-setup.sh – Grundeinstellungen für den AdGuard-Wyse3040 (Hostname, Passwort, IP)
#
# Auf dem Gerät installiert als:  /usr/local/sbin/wyse-setup
# Aufruf:                         sudo wyse-setup
#
# Schritte (jeder einzeln überspringbar):
#   1. Hostname setzen
#   2. Linux-Passwort ändern
#   3. Web-Verwaltung Cockpit installieren (optional)
#   4. Netzwerk: DHCP oder feste IP
#
# Die AdGuard-Einrichtung (Admin-Benutzer, Upstreams, Filter) erfolgt über
# den Setup-Assistenten im Webinterface (Port 3000) und nicht hier.
set -euo pipefail

STATE_DIR="/var/lib/wyse-setup"
DONE_FILE="$STATE_DIR/setup.done"

NEED_REBOOT=0

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

# ---------------------------------------------------------------- 1. Hostname

step_hostname() {
    info "Hostname"
    local current new
    current="$(hostname)"
    echo "Aktueller Hostname: $current"
    yesno "Hostname ändern?" n || return 0

    new="$(ask "Neuer Hostname" "$current")"
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

# ---------------------------------------------------------------- 3. Cockpit

step_cockpit() {
    info "Web-Verwaltung (Cockpit)"
    local ip
    ip="$(hostname -I | awk '{print $1}')"
    if dpkg -s cockpit-ws &>/dev/null; then
        echo "Cockpit ist installiert: https://$ip:9090"
        return 0
    fi
    echo "Cockpit ist eine Weboberfläche für die Linux-Verwaltung: Terminal im"
    echo "Browser, Updates, Logs, Dienste, Neustart. Belegt nur Arbeitsspeicher,"
    echo "solange jemand angemeldet ist. Adresse danach: https://$ip:9090"
    yesno "Cockpit installieren?" n || return 0

    # --no-install-recommends: sonst würde u.a. NetworkManager mitinstalliert und
    # die Netzwerkkonfiguration übernehmen.
    apt-get update -qq
    apt-get install -y --no-install-recommends \
        cockpit-ws cockpit-system cockpit-bridge cockpit-packagekit
    ufw allow 9090/tcp >/dev/null
    systemctl enable --now cockpit.socket
    echo "Cockpit installiert: https://$ip:9090  (Login mit dem Linux-Benutzer)"
    warn "Der Browser warnt beim ersten Aufruf vor dem selbst signierten Zertifikat – das ist normal."
}

# ---------------------------------------------------------------- 4. Netzwerk

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
        echo "# erzeugt von wyse-setup"
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

    mode="$(ask "(d)HCP verwenden, (s)tatische IP vergeben oder (u)nverändert lassen" "u")"
    case "${mode,,}" in
        s*) mode=static ;;
        d*) mode=dhcp
            if [[ $cur_mode == DHCP ]]; then echo "DHCP ist bereits aktiv."; return 0; fi ;;
        *)  echo "Netzwerk bleibt unverändert."; return 0 ;;
    esac
    iface="$(ask "Schnittstelle" "$iface")"

    if [[ $mode == static ]]; then
        mode=static
        while true; do
            addr="$(ask "IP-Adresse mit Präfix (z.B. 192.168.1.53/24)" "${cur:-192.168.1.53/24}")"
            valid_cidr "$addr" && break
            warn "Bitte im Format a.b.c.d/nn angeben."
        done
        gw="$(ask_ipv4 "Gateway (Router)" "$(ip -4 route show default | awk '{print $3; exit}')")"
        # Das Gerät selbst nicht über den eigenen AdGuard auflösen lassen – sonst
        # gehen Updates nicht, wenn AdGuard mal hängt.
        dns1="$(ask_ipv4 "DNS-Server für das Gerät selbst" "$gw")"
        dns2="$(ask "Zweiter DNS-Server (leer = keiner)" "9.9.9.9")"
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
                echo "# erzeugt von wyse-setup – Backup: /etc/network/interfaces.bak.*"
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
                echo "# erzeugt von wyse-setup"
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
    echo "  AdGuard Wyse 3040 – Einrichtung"
    echo "======================================================"
    if [[ -f $DONE_FILE ]]; then
        echo "Zuletzt ausgeführt: $(cat "$DONE_FILE")"
    fi

    step_hostname
    step_linux_password
    step_cockpit
    step_network

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
