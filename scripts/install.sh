#!/usr/bin/env bash
# install.sh – spielt die Konfiguration aus rootfs/ auf das System.
#
# Wird von bootstrap.sh aufgerufen, kann aber auch einzeln laufen, um
# Änderungen aus dem Repo auf ein bestehendes Gerät zu übernehmen:
#   sudo ./scripts/install.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Ports, die in der Firewall offen sein müssen
UFW_RULES=(
    "22/tcp"     # SSH
    "53"         # DNS (tcp + udp)
    "80/tcp"     # AdGuard Webinterface
    "443"        # AdGuard Webinterface HTTPS / DNS-over-HTTPS
)
# AdGuard Setup-Assistent: nur öffnen, solange AdGuard noch nicht eingerichtet ist.
# Sonst würde ein Projekt-Update den (laut README geschlossenen) Port wieder öffnen.
[[ -f /opt/AdGuardHome/AdGuardHome.yaml ]] || UFW_RULES+=("3000/tcp")

if [[ $EUID -ne 0 ]]; then
    echo "Please run as root (sudo $0)." >&2
    exit 1
fi

# Umstellung v1.1 -> v1.2: Der Projektordner hieß /opt/adguard-setup, und das
# Update-Skript bis v1.1 spielt die neue Version noch dorthin. Umziehen und von
# dort neu starten (siehe auch scripts/migrate.sh).
if [[ $REPO_DIR == /opt/adguard-setup ]]; then
    rm -rf /opt/system-setup
    mv /opt/adguard-setup /opt/system-setup
    exec /opt/system-setup/scripts/install.sh "$@"
fi

# Einmalige Umstellungen älterer Installationen (alte Namen, Pfade)
"$REPO_DIR/scripts/migrate.sh"

echo "==> Copying rootfs/ to / ..."
tar -C "$REPO_DIR/rootfs" -cf - . | tar -C / --no-same-owner -xvf -

# Region (Sprache der Texte, Datumsformat, NTP-Server), siehe scripts/set-region.sh
"$REPO_DIR/scripts/set-region.sh"

# Tastatur: setzt normalerweise der Installer (console-setup). Geräte bis v1.0
# hatten das Paket nicht und damit an der Konsole immer US-Layout. Nur wenn
# GAR KEINE Tastatur eingerichtet ist, das Layout der Region nehmen – eine
# vorhandene Einstellung wird nie geändert.
if [[ ! -s /etc/default/keyboard ]]; then
    keymap="$(sed -n 's/^KEYMAP=//p' /etc/system-region.conf | tr -d '"')"
    [[ $keymap =~ ^[a-z]{2,3}$ ]] || keymap=us
    echo "==> Keyboard layout: $keymap"
    cat > /etc/default/keyboard <<EOF
# KEYBOARD CONFIGURATION FILE (set by AdGuard-Wyse3040 install.sh from the region)
# Change with: sudo dpkg-reconfigure keyboard-configuration
XKBMODEL="pc105"
XKBLAYOUT="$keymap"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
EOF
    # Paket übernimmt die vorhandene Datei; ohne Internet beim nächsten Update erneut
    if DEBIAN_FRONTEND=noninteractive apt-get install -y -qq console-setup >/dev/null 2>&1; then
        setupcon --force 2>/dev/null || true
    else
        echo "WARNING: console-setup could not be installed – keyboard stays US until the next update." >&2
        rm -f /etc/default/keyboard
    fi
fi

echo "==> Installing texts to /usr/local/share/system-setup ..."
install -d /usr/local/share/system-setup/lang
install -m 644 "$REPO_DIR/scripts/i18n.sh" /usr/local/share/system-setup/i18n.sh
rm -f /usr/local/share/system-setup/lang/*.sh
install -m 644 "$REPO_DIR"/lang/*.sh /usr/local/share/system-setup/lang/

# Gerätespezifische Anpassungen (hardware/<gerät>/), nur wenn das Gerät erkannt wird
# shellcheck source=hardware.sh
source "$REPO_DIR/scripts/hardware.sh"
HW="$(detect_hardware)"
if [[ -n $HW && -d $REPO_DIR/hardware/$HW ]]; then
    echo "==> Device detected: $HW – applying hardware/$HW/ ..."
    tar -C "$REPO_DIR/hardware/$HW" -cf - . | tar -C / --no-same-owner -xvf -
else
    echo "==> No special device detected – no hardware adjustments needed."
fi

# AdGuard möchte sein Verzeichnis nur für root lesbar haben (sonst Warnung "permcheck")
[[ -d /opt/AdGuardHome ]] && chmod 700 /opt/AdGuardHome

echo "==> Login messages ..."
chmod 755 /etc/update-motd.d/*
# Debian-Standardtexte ausblenden (Lizenzhinweis + uname-Zeile), eigene MOTD reicht
: > /etc/motd
[[ -f /etc/update-motd.d/10-uname ]] && chmod -x /etc/update-motd.d/10-uname

echo "==> Installing the commands to /usr/local/sbin ..."
install -m 755 "$REPO_DIR/scripts/system-setup.sh"  /usr/local/sbin/system-setup
install -m 755 "$REPO_DIR/scripts/system-banner.sh" /usr/local/sbin/system-banner
install -m 755 "$REPO_DIR/scripts/system-backup.sh" /usr/local/sbin/system-backup
install -m 755 "$REPO_DIR/scripts/system-usb.sh"    /usr/local/sbin/system-usb
install -m 755 "$REPO_DIR/scripts/status.sh"         /usr/local/bin/status

# "status" darf die Übersicht ohne Passwort mit Admin-Rechten anzeigen.
# Vor dem Aktivieren prüfen – eine fehlerhafte sudoers-Datei würde sudo blockieren.
SUDOERS_TMP="$(mktemp)"
echo '%sudo ALL=(root) NOPASSWD: /etc/update-motd.d/99-custom-motd' > "$SUDOERS_TMP"
if visudo -cqf "$SUDOERS_TMP"; then
    install -m 440 "$SUDOERS_TMP" /etc/sudoers.d/system-status
else
    echo "WARNING: sudoers rule for 'status' is invalid – skipped." >&2
fi
rm -f "$SUDOERS_TMP"

echo "==> Firewall (ufw) ..."
for rule in "${UFW_RULES[@]}"; do
    ufw allow "$rule" >/dev/null
done
ufw --force enable

echo "==> Reloading services ..."
systemctl daemon-reexec          # system.conf.d (Watchdog) übernehmen
udevadm control --reload         # USB-Stick-Meldungen (90-system-usb.rules)
systemctl enable system-banner.service
systemctl enable --now system-banner.path
systemctl enable --now system-backup.timer
/usr/local/sbin/system-banner
systemctl restart systemd-journald
systemctl enable --now fail2ban
systemctl restart fail2ban
systemctl enable --now zramswap 2>/dev/null || true
timedatectl set-ntp true         # Uhrzeit automatisch per NTP (systemd-timesyncd)
systemctl restart systemd-timesyncd
systemctl restart zramswap 2>/dev/null || true

# Geänderte Modul-Sperren (modprobe.d) greifen erst mit neuer initramfs
echo "==> Updating initramfs ..."
update-initramfs -u

echo "==> Configuration applied."
