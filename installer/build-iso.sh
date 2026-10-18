#!/usr/bin/env bash
# build-iso.sh – baut den USB-Installationsstick (ISO) für den AdGuard-Wyse3040.
#
# Lädt die aktuelle offizielle Debian-13-Netinstall-ISO, prüft die Prüfsumme und
# fügt hinzu:
#   /preseed.cfg       Antworten für den Installer
#   /boot/grub/grub.cfg  eigenes Bootmenü
#   /adguard-setup/     dieses Repo (rootfs/, scripts/, installer/)
#
# Benötigt: Linux, WSL oder Docker mit  xorriso curl  (Debian: apt install xorriso curl)
# Aufruf im Repo-Ordner:  ./installer/build-iso.sh
# Ergebnis:               build/adguard-wyse3040-debian-<version>.iso
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$REPO_DIR/build"
MIRROR="https://cdimage.debian.org/debian-cd/current/amd64/iso-cd"

for cmd in xorriso curl sha256sum; do
    command -v "$cmd" >/dev/null || { echo "Fehlt: $cmd  (apt install xorriso curl)" >&2; exit 1; }
done

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

echo "==> Suche aktuelle Debian-Netinstall-ISO ..."
curl -fsSL -o SHA256SUMS "$MIRROR/SHA256SUMS"
ISO_NAME="$(awk '/amd64-netinst\.iso$/ {print $2; exit}' SHA256SUMS)"
[[ -n $ISO_NAME ]] || { echo "Keine Netinstall-ISO in SHA256SUMS gefunden." >&2; exit 1; }
DEBIAN_VERSION="$(sed -E 's/debian-([0-9.]+)-.*/\1/' <<<"$ISO_NAME")"

if ! sha256sum --ignore-missing -c SHA256SUMS 2>/dev/null | grep -q "^$ISO_NAME: OK"; then
    echo "==> Lade $ISO_NAME ..."
    curl -fL --progress-bar -o "$ISO_NAME" "$MIRROR/$ISO_NAME"
    sha256sum --ignore-missing -c SHA256SUMS | grep -q "^$ISO_NAME: OK" \
        || { echo "Prüfsumme stimmt nicht!" >&2; exit 1; }
fi
echo "    $ISO_NAME (Prüfsumme OK)"

echo "==> Stelle Repo-Dateien zusammen ..."
STAGE="$BUILD_DIR/stage"
rm -rf "$STAGE"
mkdir -p "$STAGE/adguard-setup"
cp -r "$REPO_DIR/rootfs" "$REPO_DIR/hardware" "$REPO_DIR/scripts" "$REPO_DIR/installer" "$STAGE/adguard-setup/"
# Falls unter Windows ausgecheckt: Zeilenenden sicherheitshalber auf LF
find "$STAGE" -type f -exec sed -i 's/\r$//' {} +
chmod 755 "$STAGE"/adguard-setup/scripts/*.sh "$STAGE"/adguard-setup/rootfs/etc/update-motd.d/*

OUT_ISO="$BUILD_DIR/adguard-wyse3040-debian-$DEBIAN_VERSION.iso"
rm -f "$OUT_ISO"

echo "==> Baue $(basename "$OUT_ISO") ..."
# -boot_image any replay übernimmt die Bootfähigkeit (UEFI + BIOS) der Original-ISO
xorriso -indev "$ISO_NAME" -outdev "$OUT_ISO" \
    -map "$STAGE/adguard-setup"           /adguard-setup \
    -map "$REPO_DIR/installer/preseed.cfg" /preseed.cfg \
    -map "$REPO_DIR/installer/grub.cfg"    /boot/grub/grub.cfg \
    -boot_image any replay

echo
echo "Fertig: $OUT_ISO"
echo "Mit Rufus (DD-Modus) oder balenaEtcher auf einen USB-Stick schreiben."
