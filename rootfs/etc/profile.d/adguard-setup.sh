# /etc/profile.d/adguard-setup.sh
# Fragt beim Login nach der Grundeinrichtung (Hostname, Neustart, DHCP/feste IP),
# bis "sudo adguard-setup" einmal vollständig durchgelaufen ist.

# Nur interaktive Shells (nicht bei scp, ssh <befehl> usw.)
case $- in *i*) ;; *) return 0 ;; esac

[ -f /var/lib/adguard-setup/setup.done ] && return 0

if [ ! -f /var/lib/adguard-setup/bootstrap.done ]; then
    printf '\n\033[1;33mDie automatische Ersteinrichtung läuft noch.\033[0m\n'
    printf 'Fortschritt: journalctl -fu adguard-firstboot\n\n'
    return 0
fi

# Nur Benutzer mit Admin-Rechten fragen
id -nG 2>/dev/null | grep -qw sudo || [ "$(id -u)" -eq 0 ] || return 0

printf '\n\033[1;33mDie Grundeinrichtung (Hostname, Neustart-Zeitplan, DHCP oder feste IP) ist noch nicht erledigt.\033[0m\n'
# Nur eindeutige Antworten gelten, sonst wird erneut gefragt
while true; do
    printf 'Jetzt starten? [J/n] '
    read -r _adguard_answer
    case "$_adguard_answer" in
        ""|[jJ]|[jJ][aA]|[yY]|[yY][eE][sS])
            sudo /usr/local/sbin/adguard-setup
            break ;;
        [nN]|[nN][eE][iI][nN]|[nN][oO])
            printf 'Später starten mit: sudo adguard-setup\n\n'
            break ;;
        *)
            printf 'Bitte j (ja) oder n (nein) eingeben.\n' ;;
    esac
done
unset _adguard_answer
