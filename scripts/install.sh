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
    "3000/tcp"   # AdGuard Setup-Assistent (nur bis zur Ersteinrichtung nötig)
)

if [[ $EUID -ne 0 ]]; then
    echo "Bitte als root ausführen (sudo $0)." >&2
    exit 1
fi

echo "==> Kopiere rootfs/ nach / ..."
tar -C "$REPO_DIR/rootfs" -cf - . | tar -C / --no-same-owner -xvf -

# Gerätespezifische Anpassungen (hardware/<gerät>/), nur wenn das Gerät erkannt wird
# shellcheck source=hardware.sh
source "$REPO_DIR/scripts/hardware.sh"
HW="$(detect_hardware)"
if [[ -n $HW && -d $REPO_DIR/hardware/$HW ]]; then
    echo "==> Gerät erkannt: $HW – spiele hardware/$HW/ ein ..."
    tar -C "$REPO_DIR/hardware/$HW" -cf - . | tar -C / --no-same-owner -xvf -
else
    echo "==> Kein spezielles Gerät erkannt – keine Hardware-Anpassungen nötig."
fi

echo "==> Login-Nachrichten ..."
chmod 755 /etc/update-motd.d/*
# Debian-Standardtexte ausblenden (Lizenzhinweis + uname-Zeile), eigene MOTD reicht
: > /etc/motd
[[ -f /etc/update-motd.d/10-uname ]] && chmod -x /etc/update-motd.d/10-uname

echo "==> Installiere adguard-setup und adguard-banner nach /usr/local/sbin ..."
install -m 755 "$REPO_DIR/scripts/adguard-setup.sh"  /usr/local/sbin/adguard-setup
install -m 755 "$REPO_DIR/scripts/adguard-banner.sh" /usr/local/sbin/adguard-banner
install -m 755 "$REPO_DIR/scripts/adguard-backup.sh" /usr/local/sbin/adguard-backup

echo "==> Firewall (ufw) ..."
for rule in "${UFW_RULES[@]}"; do
    ufw allow "$rule" >/dev/null
done
ufw --force enable

echo "==> Dienste neu laden ..."
systemctl daemon-reexec          # system.conf.d (Watchdog) übernehmen
systemctl enable adguard-banner.service
systemctl enable --now adguard-banner.path
systemctl enable --now adguard-backup.timer
/usr/local/sbin/adguard-banner
systemctl restart systemd-journald
systemctl enable --now fail2ban
systemctl restart fail2ban
systemctl enable --now zramswap 2>/dev/null || true
timedatectl set-ntp true         # Uhrzeit automatisch per NTP (systemd-timesyncd)
systemctl restart systemd-timesyncd
systemctl restart zramswap 2>/dev/null || true

# Geänderte Modul-Sperren (modprobe.d) greifen erst mit neuer initramfs
echo "==> Aktualisiere initramfs ..."
update-initramfs -u

echo "==> Konfiguration eingespielt."
