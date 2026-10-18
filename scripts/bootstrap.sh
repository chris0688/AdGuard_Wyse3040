#!/usr/bin/env bash
# bootstrap.sh – macht aus einem frischen Debian 13 einen AdGuard-DNS-Server.
#
#  * installiert die benötigten Pakete
#  * lädt AdGuard Home herunter und richtet es als Dienst ein
#  * spielt die Konfiguration aus rootfs/ ein (scripts/install.sh)
#
# Läuft automatisch beim ersten Start nach der USB-Installation
# (adguard-wyse-firstboot.service) oder manuell nach einer eigenen
# Debian-Installation:
#   sudo ./scripts/bootstrap.sh
#
# Das Script kann gefahrlos mehrfach laufen.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STATE_DIR="/var/lib/wyse-setup"
STATUS_ISSUE="/etc/issue.d/50-wyse-status.issue"

AGH_DIR="/opt/AdGuardHome"
AGH_URL_BASE="https://static.adtidy.org/adguardhome/release"

PACKAGES=(
    sudo curl ca-certificates
    ufw
    fail2ban python3-systemd
    unattended-upgrades apt-listchanges
    zram-tools
)

export DEBIAN_FRONTEND=noninteractive

# ------------------------------------------------------------ Statusanzeige
# Zeigt den Fortschritt auch am Bildschirm vor dem Login an (/etc/issue.d).

status() {   # status "farbe" "text"
    mkdir -p "$(dirname "$STATUS_ISSUE")"
    printf '\\e{%s}    >> %s\\e{reset}\n\n' "$1" "$2" > "$STATUS_ISSUE"
    agetty --reload 2>/dev/null || true
    echo "==> $2"
}

on_error() {
    status lightred "Einrichtung FEHLGESCHLAGEN - Details: journalctl -u adguard-wyse-firstboot"
}
trap on_error ERR

if [[ $EUID -ne 0 ]]; then
    echo "Bitte als root ausführen (sudo $0)." >&2
    exit 1
fi

# ------------------------------------------------------------ Pakete

status yellow "Einrichtung laeuft (Pakete werden installiert) - bitte warten ..."
apt-get update
apt-get install -y "${PACKAGES[@]}"
# Prozessor-Microcode: nur verfügbar, wenn non-free-firmware in den Paketquellen ist
apt-get install -y intel-microcode 2>/dev/null || echo "intel-microcode nicht verfügbar – übersprungen."

# ------------------------------------------------------------ AdGuard Home

agh_arch() {
    case "$(dpkg --print-architecture)" in
        amd64) echo amd64 ;;
        i386)  echo 386 ;;
        arm64) echo arm64 ;;
        armhf) echo armv7 ;;
        *)     echo "Nicht unterstützte Architektur: $(dpkg --print-architecture)" >&2; return 1 ;;
    esac
}

if [[ -x $AGH_DIR/AdGuardHome ]]; then
    echo "AdGuard Home ist bereits installiert – übersprungen."
else
    status yellow "Einrichtung laeuft (AdGuard Home wird installiert) - bitte warten ..."
    tmp="$(mktemp -d)"
    curl -fsSL --retry 5 --retry-delay 10 \
        -o "$tmp/agh.tar.gz" "$AGH_URL_BASE/AdGuardHome_linux_$(agh_arch).tar.gz"
    tar -C /opt -xzf "$tmp/agh.tar.gz"
    rm -rf "$tmp"
    "$AGH_DIR/AdGuardHome" -s install
fi

# ------------------------------------------------------------ Konfiguration

status yellow "Einrichtung laeuft (Konfiguration) - bitte warten ..."
"$REPO_DIR/scripts/install.sh"

mkdir -p "$STATE_DIR"
date '+%Y-%m-%d %H:%M' > "$STATE_DIR/bootstrap.done"

rm -f "$STATUS_ISSUE"
agetty --reload 2>/dev/null || true
echo "==> Fertig. AdGuard Home einrichten unter http://$(hostname -I | awk '{print $1}'):3000"
