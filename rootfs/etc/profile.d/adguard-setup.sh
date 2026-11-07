# /etc/profile.d/adguard-setup.sh
# Fragt beim Login nach der Grundeinrichtung (Hostname, Neustart, DHCP/feste IP),
# bis "sudo adguard-setup" einmal vollständig durchgelaufen ist.
# Texte: lang/<sprache>.sh, Abschnitt T_PROFILE_* (siehe scripts/i18n.sh)

# Nur interaktive Shells (nicht bei scp, ssh <befehl> usw.)
case $- in *i*) ;; *) return 0 ;; esac

[ -f /var/lib/adguard-setup/setup.done ] && return 0

# In einer Subshell, damit Texte und Hilfsfunktionen nicht in der
# Login-Shell landen. Während der Ersteinrichtung sind die Texte noch nicht
# installiert, dann kommen sie direkt aus dem Repo.
(
    if [ -r /usr/local/share/adguard/i18n.sh ]; then
        . /usr/local/share/adguard/i18n.sh
    elif [ -r /opt/adguard-setup/scripts/i18n.sh ]; then
        ADGUARD_SHARE=/opt/adguard-setup
        . /opt/adguard-setup/scripts/i18n.sh
    else
        exit 0
    fi

    if [ ! -f /var/lib/adguard-setup/bootstrap.done ]; then
        printf '\n\033[1;33m%s\033[0m\n' "$T_PROFILE_BOOTSTRAP_RUNNING"
        printf '%s journalctl -fu adguard-firstboot\n\n' "$T_PROFILE_PROGRESS"
        exit 0
    fi

    # Nur Benutzer mit Admin-Rechten fragen
    id -nG 2>/dev/null | grep -qw sudo || [ "$(id -u)" -eq 0 ] || exit 0

    printf '\n\033[1;33m%s\033[0m\n' "$T_PROFILE_SETUP_PENDING"
    if adguard_yesno "$T_PROFILE_Q_START" y; then
        sudo /usr/local/sbin/adguard-setup
    else
        printf '%s sudo adguard-setup\n\n' "$T_PROFILE_LATER"
    fi
)
