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

AGH_CONF="/opt/AdGuardHome/AdGuardHome.yaml"
LINE='\e{lightgreen}  =================================================================\e{reset}'

# Benutzer (UID >= 1000), die ihr Passwort beim nächsten Login ändern müssen.
# Das setzt der Installer für das Standardpasswort (chage -d 0).
pending_users="$(awk -F: '
    NR == FNR { if ($3 >= 1000 && $3 < 65534) human[$1] = 1; next }
    ($1 in human) && $3 == "0" { print $1 }
' /etc/passwd /etc/shadow | paste -sd ' ')"

cockpit=0
systemctl is-enabled --quiet cockpit.socket 2>/dev/null && cockpit=1

{
    echo
    echo "$LINE"
    echo '\e{bold}\e{white}    AdGuard Home DNS-Server\e{reset}  -  \S{PRETTY_NAME}'
    echo "$LINE"
    echo '\e{lightblue}    Hostname:         \e{lightcyan}\n\e{reset}'
    echo '\e{lightblue}    IP-Adresse:       \e{lightcyan}\4\e{reset}'
    echo '\e{lightblue}    AdGuard:          \e{lightcyan}http://\4\e{reset}'
    if [[ ! -f $AGH_CONF ]]; then
        echo '\e{lightblue}    Ersteinrichtung:  \e{lightcyan}http://\4:3000\e{reset}  \e{yellow}(AdGuard noch nicht eingerichtet)\e{reset}'
    fi
    if (( cockpit )); then
        echo '\e{lightblue}    Web-Konsole:      \e{lightcyan}https://\4:9090\e{reset}'
    fi
    echo "$LINE"
    if [[ -n $pending_users ]]; then
        echo
        echo '\e{lightred}\e{bold}    !! SICHERHEIT: Das Standardpasswort ist noch aktiv !!\e{reset}'
        echo "\\e{lightred}    Bitte jetzt anmelden (Benutzer: $pending_users) und ein neues Passwort setzen.\\e{reset}"
        echo '\e{lightred}    Bis dahin ist das Gerät per SSH mit dem öffentlich bekannten Passwort erreichbar.\e{reset}'
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

# Angezeigten Banner an der Konsole sofort aktualisieren
agetty --reload 2>/dev/null || true
