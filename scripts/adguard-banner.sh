#!/usr/bin/env bash
# adguard-banner – erzeugt den Login-Banner (/etc/issue) passend zum Zustand:
#   * Web-Konsole (Cockpit), falls installiert
#   * Link zum AdGuard-Einrichtungsassistenten, solange AdGuard nicht eingerichtet ist
#   * Warnung, solange ein Benutzer noch das Standardpasswort hat
#
# Auf dem Gerät: /usr/local/sbin/adguard-banner
# Läuft beim Start und automatisch bei Passwortänderung bzw. nach der
# AdGuard-Einrichtung (adguard-banner.path).
set -euo pipefail
# Zeichen statt Bytes zählen (Ausrichtung bei Umlauten)
export LC_ALL=C.UTF-8
. /usr/local/share/adguard/i18n.sh

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

{
    echo
    echo "$LINE"
    printf '\\e{bold}\\e{white}    %s\\e{reset}  -  \\S{PRETTY_NAME}\n' "$T_BANNER_TITLE"
    echo "$LINE"
    issue_row "$T_BANNER_HOSTNAME" '\n'
    issue_row "$T_BANNER_IP" '\4'
    issue_row "$T_BANNER_ADGUARD" "http://\\4$agh_port"
    if [[ ! -f $AGH_CONF ]]; then
        issue_row "$T_BANNER_FIRST_SETUP" 'http://\4:3000' "  \\e{yellow}($T_BANNER_NOT_SET_UP)\\e{reset}"
    fi
    if (( cockpit )); then
        issue_row "$T_BANNER_WEBCONSOLE" 'https://\4:9090'
    fi
    # Eingesteckte USB-Sticks (wird beim Einstecken/Abziehen neu erzeugt)
    if [[ -x /usr/local/sbin/adguard-usb ]]; then
        while IFS='|' read -r label rest; do
            [[ -n $label ]] && issue_row "$T_BANNER_USB" "$label" " $rest"
        done < <(/usr/local/sbin/adguard-usb issue || true)
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
mkdir -p /var/lib/adguard-setup
for f in /etc/issue.d/cockpit.issue /etc/motd.d/cockpit; do
    if [[ -e $f || -L $f ]]; then
        dpkg-divert --local --rename --divert "/var/lib/adguard-setup/$(basename "$f").disabled" --add "$f" >/dev/null
    fi
done

# Frühere Version legte die USB-Zeile separat ab (unterhalb des Banners)
rm -f /etc/issue.d/60-adguard-usb.issue

# Angezeigten Banner an der Konsole sofort aktualisieren
agetty --reload 2>/dev/null || true
