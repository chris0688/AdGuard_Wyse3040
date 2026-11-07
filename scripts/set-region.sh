#!/usr/bin/env bash
# set-region.sh – legt die Region des Geräts fest: Sprache der Texte, Datums- und
# Zahlenformat, NTP-Server.
#
#   sudo ./scripts/set-region.sh [REGION]     z.B. de_DE, en_US (siehe region/)
#
# Ohne Angabe gilt die bisherige Region (/etc/adguard-region.conf, beim
# Installieren aus dem Bootmenü gesetzt), sonst die zur System-Locale passende
# (Geräte vor v1.1 waren deutsch: LANG=de_DE.UTF-8 -> de_DE), sonst en_US.
#
# Schreibt:
#   /etc/adguard-region.conf                      gelesen von scripts/i18n.sh
#   /etc/systemd/timesyncd.conf.d/adguard.conf    NTP-Server der Region
#
# Locale, Tastatur und Zeitzone des Systems setzt nur der Installer. Sie werden
# hier bewusst NICHT geändert (sonst würde ein Update eigene Einstellungen
# überschreiben); siehe README.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REGION_CONF="/etc/adguard-region.conf"
NTP_CONF="/etc/systemd/timesyncd.conf.d/adguard.conf"

if [[ $EUID -ne 0 ]]; then
    echo "Please run as root (sudo $0)." >&2
    exit 1
fi

valid() { [[ $1 =~ ^[A-Za-z]{2,3}_[A-Za-z0-9]{2,3}$ && -f $REPO_DIR/region/$1.conf ]]; }

region="${1:-}"
if [[ -z $region && -f $REGION_CONF ]]; then
    region="$(sed -n 's/^REGION=//p' "$REGION_CONF" | head -n1)"
fi
if ! valid "$region"; then
    [[ -n ${1:-} ]] && { echo "Unknown region: $1 (see region/)" >&2; exit 2; }
    locale="$(sed -n 's/^LANG=//p' /etc/default/locale 2>/dev/null | tr -d '"' | head -n1)"
    region=""
    if [[ -n $locale ]]; then
        region="$(grep -lx "LOCALE=$locale" "$REPO_DIR"/region/*.conf 2>/dev/null | head -n1 || true)"
        region="$(basename "${region:-}" .conf)"
    fi
    valid "$region" || region=en_US
fi

src="$REPO_DIR/region/$region.conf"
{
    echo "# AdGuard-Wyse3040 – Region (erzeugt von set-region.sh aus region/$region.conf)"
    echo "# Ändern: sudo /opt/adguard-setup/scripts/set-region.sh <REGION>"
    echo "REGION=$region"
    grep -E '^(TEXTS|LOCALE|KEYMAP|TIMEZONE|NTP_POOL|DATE_FORMAT|DECIMAL)=' "$src"
} > "$REGION_CONF.tmp"
mv "$REGION_CONF.tmp" "$REGION_CONF"
chmod 644 "$REGION_CONF"

# NTP-Server: 0.<pool> bis 3.<pool>, Debians Pool als Rückfall
pool="$(sed -n 's/^NTP_POOL=//p' "$src" | tr -d '"')"
[[ $pool =~ ^[a-z0-9.-]+$ ]] || pool=pool.ntp.org
mkdir -p "$(dirname "$NTP_CONF")"
cat > "$NTP_CONF" <<EOF
# Uhrzeit aus dem pool.ntp.org-Projekt (Region $region, erzeugt von set-region.sh).
# Fällt ein Server aus, wird automatisch der nächste genommen; sind alle nicht
# erreichbar, greift Debians Pool als Rückfall.
#
# Status prüfen:  timedatectl timesync-status
[Time]
NTP=0.$pool 1.$pool 2.$pool 3.$pool
FallbackNTP=0.debian.pool.ntp.org 1.debian.pool.ntp.org 2.debian.pool.ntp.org 3.debian.pool.ntp.org
EOF

echo "==> Region: $region"
