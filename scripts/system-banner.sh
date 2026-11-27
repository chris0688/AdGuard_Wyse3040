#!/usr/bin/env bash
# system-banner – erzeugt den Login-Banner (/etc/issue) passend zum Zustand:
#   * Web-Konsole (Cockpit), falls installiert
#   * Link zum AdGuard-Einrichtungsassistenten, solange AdGuard nicht eingerichtet ist
#   * Warnung, solange ein Benutzer noch das Standardpasswort hat
#
# Auf dem Gerät: /usr/local/sbin/system-banner
# Läuft beim Start und automatisch bei Passwortänderung bzw. nach der
# AdGuard-Einrichtung (system-banner.path).
set -euo pipefail
# Zeichen statt Bytes zählen (Ausrichtung bei Umlauten)
export LC_ALL=C.UTF-8
. /usr/local/share/system-setup/i18n.sh

AGH_CONF="/opt/AdGuardHome/AdGuardHome.yaml"

# Standardpasswort aus installer/preseed.cfg (steht ohnehin öffentlich im README).
# Wird nur angezeigt, solange es noch aktiv ist, und nur an der lokalen Konsole.
DEFAULT_PASSWORD="adguard"
LINE='\e{lightgreen}  =================================================================\e{reset}'

# issue_row "Bezeichnung" "Wert" ["Zusatz"] – eine Zeile im Kasten, Werte
# untereinander. Wert darf agetty-Platzhalter enthalten (\4 = IP, \n = Hostname).
issue_row() {
    local pad=$(( 18 - ${#1} ))
    (( pad < 1 )) && pad=1
    printf '\\e{lightblue}    %s%*s\\e{lightcyan}%s\\e{reset}%s\n' "$1" "$pad" '' "$2" "${3:-}"
}

# Benutzer (UID >= 1000), die ihr Passwort beim nächsten Login ändern müssen.
# Das setzt der Installer für das Standardpasswort (chage -d 0).
pending_users="$(awk -F: '
    NR == FNR { if ($3 >= 1000 && $3 < 65534) human[$1] = 1; next }
    ($1 in human) && $3 == "0" { print $1 }
' /etc/passwd /etc/shadow | paste -sd ' ')"

cockpit=0
systemctl is-enabled --quiet cockpit.socket 2>/dev/null && cockpit=1

# Port des Webinterface (im Einrichtungsassistenten gewählt), bei 80 ohne Angabe.
# Der Banner wird bei Änderungen an der AdGuard-Konfiguration neu erzeugt.
agh_port=""
if [[ -f $AGH_CONF ]]; then
    agh_port="$(awk '/^[^ #]/ { http = ($1 == "http:") }
                     http && $1 == "address:" { gsub(/"/, "", $2); sub(/.*:/, "", $2); print $2; exit }' "$AGH_CONF")"
    [[ $agh_port =~ ^[0-9]+$ && $agh_port != 80 ]] && agh_port=":$agh_port" || agh_port=""
fi

# IP-Platzhalter für agetty mit fester Netzwerkkarte, z.B. \4{enp1s0}.
# Ohne Angabe nimmt agetty die erste Karte, die schon VERBUNDEN ist, sonst die
# Adresse des Hostnamens (127.0.1.1). Bei fester IP ist die Adresse aber schon
# gesetzt, bevor das Kabel verbunden ist – dann blieb 127.0.1.1 stehen, weil
# agetty nur bei Adressänderungen neu zeichnet. Mit fester Karte zeigt es deren
# Adresse sofort (bei DHCP weiterhin, sobald sie kommt).
# Karte: die mit der Standardroute, sonst die erste kabelgebundene, sonst \4.
net_iface() {
    local i
    i="$(ip -o route show default 2>/dev/null | awk '{print $5; exit}')"
    if [[ -z $i ]]; then
        for i in /sys/class/net/*; do
            [[ -e $i/device && ! -d $i/wireless && ! -d $i/phy80211 ]] || continue
            [[ $(cat "$i/type" 2>/dev/null) == 1 ]] || continue
            i="${i##*/}"
            break
        done
        [[ $i == /* || $i == *'*'* ]] && i=""
    fi
    [[ $i =~ ^[A-Za-z0-9._-]+$ ]] && echo "$i"
    return 0
}
iface="$(net_iface)"
IP='\4'
[[ -n $iface ]] && IP="\\4{$iface}"

{
    echo
    echo "$LINE"
    printf '\\e{bold}\\e{white}    %s\\e{reset}  -  \\S{PRETTY_NAME}\n' "$T_BANNER_TITLE"
    echo "$LINE"
    issue_row "$T_BANNER_HOSTNAME" '\n'
    issue_row "$T_BANNER_IP" "$IP"
    issue_row "$T_BANNER_ADGUARD" "http://$IP$agh_port"
    if [[ ! -f $AGH_CONF ]]; then
        issue_row "$T_BANNER_FIRST_SETUP" "http://$IP:3000" "  \\e{yellow}($T_BANNER_NOT_SET_UP)\\e{reset}"
    fi
    if (( cockpit )); then
        issue_row "$T_BANNER_WEBCONSOLE" "https://$IP:9090"
    fi
    # Eingesteckte USB-Sticks (wird beim Einstecken/Abziehen neu erzeugt)
    if [[ -x /usr/local/sbin/system-usb ]]; then
        while IFS='|' read -r label rest; do
            [[ -n $label ]] && issue_row "$T_BANNER_USB" "$label" " $rest"
        done < <(/usr/local/sbin/system-usb issue || true)
    fi
    echo "$LINE"
    if [[ -n $pending_users ]]; then
        echo
        printf '\\e{lightred}\\e{bold}    %s\\e{reset}\n' "$T_BANNER_PW_TITLE"
        printf '\\e{lightred}    %s\\e{reset}\n' "$T_BANNER_PW_ACTION"
        printf '\\e{lightred}      %s \\e{bold}%s\\e{reset}\\e{lightred}   %s \\e{bold}%s\\e{reset}\n' \
            "$T_BANNER_PW_USER" "$pending_users" "$T_BANNER_PW_PASSWORD" "$DEFAULT_PASSWORD"
        printf '\\e{lightred}    %s\\e{reset}\n' "$T_BANNER_PW_RISK"
    fi
    echo
} > /etc/issue

# Cockpit bringt eigene (englische) Hinweise für Banner und Begrüßung mit.
# Die sind hier schon enthalten, daher ausblenden (bleibt auch nach Updates so).
# Nach dem Umleiten (dpkg-divert) existiert die Datei nicht mehr an der alten Stelle,
# auch Paket-Updates legen sie dann nicht wieder an.
mkdir -p /var/lib/system-setup
for f in /etc/issue.d/cockpit.issue /etc/motd.d/cockpit; do
    if [[ -e $f || -L $f ]]; then
        dpkg-divert --local --rename --divert "/var/lib/system-setup/$(basename "$f").disabled" --add "$f" >/dev/null
    fi
done


# Angezeigten Banner an der Konsole sofort aktualisieren
agetty --reload 2>/dev/null || true
