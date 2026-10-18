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
printf 'Jetzt starten? [J/n] '
read -r _adguard_answer
case "$_adguard_answer" in
    [nN]*) printf 'Später starten mit: sudo adguard-setup\n\n' ;;
    *)     sudo /usr/local/sbin/adguard-setup ;;
esac
unset _adguard_answer
