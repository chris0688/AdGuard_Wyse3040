#!/usr/bin/env bash
# bootstrap.sh – macht aus einem frischen Debian 13 einen AdGuard-DNS-Server.
#
#  * installiert die benötigten Pakete
#  * lädt AdGuard Home herunter und richtet es als Dienst ein
#  * spielt die Konfiguration aus rootfs/ ein (scripts/install.sh)
#
# Läuft automatisch beim ersten Start nach der USB-Installation
# (adguard-firstboot.service) oder manuell nach einer eigenen
# Debian-Installation:
#   sudo ./scripts/bootstrap.sh
#
# Das Script kann gefahrlos mehrfach laufen.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STATE_DIR="/var/lib/adguard-setup"
STATUS_ISSUE="/etc/issue.d/50-adguard-status.issue"

AGH_DIR="/opt/AdGuardHome"
AGH_URL_BASE="https://static.adtidy.org/adguardhome/release"

PACKAGES=(
    sudo curl ca-certificates
    systemd-timesyncd
    ufw
    fail2ban python3-systemd
    unattended-upgrades apt-listchanges
    zram-tools
)

export DEBIAN_FRONTEND=noninteractive

if [[ $EUID -ne 0 ]]; then
    echo "Please run as root (sudo $0)." >&2
    exit 1
fi

# ------------------------------------------------------------ Region und Texte
# Region (Sprache, NTP) aus dem Bootmenü bzw. der System-Locale festlegen, damit
# schon die Statusmeldungen in der richtigen Sprache erscheinen. Die Texte kommen
# hier noch aus dem Repo (install.sh installiert sie später nach /usr/local/share).
"$REPO_DIR/scripts/set-region.sh"
ADGUARD_SHARE="$REPO_DIR"
. "$REPO_DIR/scripts/i18n.sh"

# ------------------------------------------------------------ Statusanzeige
# Zeigt den Fortschritt auch am Bildschirm vor dem Login an (/etc/issue.d).
# Texte T_BOOT_* sind reines ASCII (Schrift der Konsole vor dem Login).

status() {   # status "farbe" "text"
    mkdir -p "$(dirname "$STATUS_ISSUE")"
    printf '\\e{%s}    >> %s\\e{reset}\n\n' "$1" "$2" > "$STATUS_ISSUE"
    agetty --reload 2>/dev/null || true
    echo "==> $2"
}

on_error() {
    status lightred "$T_BOOT_FAILED"
}
trap on_error ERR

# ------------------------------------------------------------ Internet abwarten
# Direkt nach dem Start ist oft noch keine IP da. Statt "fehlgeschlagen" anzuzeigen,
# warten, bis die Debian-Paketquelle erreichbar ist (bewusst http: funktioniert
# auch, falls die Uhr noch falsch geht).

internet_ok() { curl -fsS -o /dev/null --max-time 5 http://deb.debian.org/debian/; }

if ! internet_ok; then
    status yellow "$T_BOOT_WAIT_INTERNET"
    until internet_ok; do sleep 10; done
fi

# ------------------------------------------------------------ Pakete

status yellow "$T_BOOT_PACKAGES"
apt-get update
apt-get install -y "${PACKAGES[@]}"
# Prozessor-Microcode (Sicherheits-/Stabilitätsupdates der CPU) passend zum Hersteller.
# Nur verfügbar, wenn non-free-firmware in den Paketquellen ist.
case "$(awk -F': ' '/^vendor_id/ {print $2; exit}' /proc/cpuinfo)" in
    GenuineIntel) MICROCODE=intel-microcode ;;
    AuthenticAMD) MICROCODE=amd64-microcode ;;
    *)            MICROCODE="" ;;
esac
if [[ -n $MICROCODE ]]; then
    apt-get install -y "$MICROCODE" 2>/dev/null || echo "$MICROCODE not available – skipped."
fi

# ------------------------------------------------------------ AdGuard Home

agh_arch() {
    case "$(dpkg --print-architecture)" in
        amd64) echo amd64 ;;
        i386)  echo 386 ;;
        arm64) echo arm64 ;;
        armhf) echo armv7 ;;
        *)     echo "Unsupported architecture: $(dpkg --print-architecture)" >&2; return 1 ;;
    esac
}

if [[ -x $AGH_DIR/AdGuardHome ]]; then
    echo "AdGuard Home is already installed – skipped."
else
    status yellow "$T_BOOT_ADGUARD"
    tmp="$(mktemp -d)"
    curl -fsSL --retry 5 --retry-delay 10 \
        -o "$tmp/agh.tar.gz" "$AGH_URL_BASE/AdGuardHome_linux_$(agh_arch).tar.gz"
    tar -C /opt -xzf "$tmp/agh.tar.gz"
    rm -rf "$tmp"
    "$AGH_DIR/AdGuardHome" -s install
fi

# ------------------------------------------------------------ Konfiguration

status yellow "$T_BOOT_CONFIG"
"$REPO_DIR/scripts/install.sh"

mkdir -p "$STATE_DIR"
date '+%Y-%m-%d %H:%M' > "$STATE_DIR/bootstrap.done"

rm -f "$STATUS_ISSUE"
agetty --reload 2>/dev/null || true
echo "==> $(printf "$T_BOOT_DONE" "http://$(hostname -I | awk '{print $1}'):3000")"
