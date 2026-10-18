# /etc/profile.d/wyse-setup.sh
# Fragt beim Login nach der Grundeinrichtung (Hostname, Neustart, DHCP/feste IP),
# bis "sudo wyse-setup" einmal vollständig durchgelaufen ist.

# Nur interaktive Shells (nicht bei scp, ssh <befehl> usw.)
case $- in *i*) ;; *) return 0 ;; esac

[ -f /var/lib/wyse-setup/setup.done ] && return 0

if [ ! -f /var/lib/wyse-setup/bootstrap.done ]; then
    printf '\n\033[1;33mDie automatische Ersteinrichtung läuft noch.\033[0m\n'
    printf 'Fortschritt: journalctl -fu adguard-wyse-firstboot\n\n'
    return 0
fi

# Nur Benutzer mit Admin-Rechten fragen
id -nG 2>/dev/null | grep -qw sudo || [ "$(id -u)" -eq 0 ] || return 0

printf '\n\033[1;33mDie Grundeinrichtung (Hostname, Neustart-Zeitplan, DHCP oder feste IP) ist noch nicht erledigt.\033[0m\n'
printf 'Jetzt starten? [J/n] '
read -r _wyse_answer
case "$_wyse_answer" in
    [nN]*) printf 'Später starten mit: sudo wyse-setup\n\n' ;;
    *)     sudo /usr/local/sbin/wyse-setup ;;
esac
unset _wyse_answer
