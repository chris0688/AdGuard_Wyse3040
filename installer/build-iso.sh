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
# Ergebnis:               build/adguard-wyse3040-<projektversion>-debian-<version>.iso
#
# Projektversion: Umgebungsvariable VERSION (z.B. VERSION=v0.5), sonst aus
# git (Tag, z.B. "v0.5" oder "v0.5-3-gabc1234" für Stände nach dem Tag), sonst "dev".
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

VERSION="${VERSION:-$(git -C "$REPO_DIR" describe --tags --always --dirty 2>/dev/null || echo dev)}"
VERSION="$(tr -c 'A-Za-z0-9._-' '_' <<<"$VERSION" | sed 's/_$//')"   # sicher für Dateinamen
echo "    Projektversion: $VERSION"

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
cp -r "$REPO_DIR/rootfs" "$REPO_DIR/hardware" "$REPO_DIR/scripts" "$REPO_DIR/installer" \
      "$REPO_DIR/lang" "$REPO_DIR/region" "$STAGE/adguard-setup/"
# Falls unter Windows ausgecheckt: Zeilenenden sicherheitshalber auf LF
find "$STAGE" -type f -exec sed -i 's/\r$//' {} +
chmod 755 "$STAGE"/adguard-setup/scripts/*.sh "$STAGE"/adguard-setup/rootfs/etc/update-motd.d/*
# Version für das installierte Gerät (Anzeige in der Begrüßung)
echo "$VERSION (Debian $DEBIAN_VERSION, $(date +%Y-%m-%d))" > "$STAGE/adguard-setup/VERSION"
# Woher "sudo adguard-setup --update" Updates holt (bei GitHub-Builds automatisch das
# eigene Repo, also auch bei Forks richtig; sonst Standard aus adguard-setup.sh)
if [[ -n ${GITHUB_REPOSITORY:-} ]]; then
    echo "$GITHUB_REPOSITORY" > "$STAGE/adguard-setup/REPO"
fi

# ---------------------------------------------------------------- Bootmenü
# Ein Installationseintrag je region/<REGION>.conf, sortiert nach ORDER (fehlt =
# ans Ende), der erste ist im Untermenü vorausgewählt. Beschriftung aus den
# Feldern, in der Sprache des Eintrags, z.B.
#   "Deutsch | Tastatur: Deutsch (de) | Zeitzone: Europe/Berlin"
echo "==> Erzeuge Bootmenü ..."
install_entries() {
    local f region order
    for f in "$STAGE"/adguard-setup/region/*.conf; do
        order="$(sed -n 's/^ORDER=//p' "$f")"
        echo "${order:-999} $(basename "$f" .conf)"
    done | sort -k1,1n -k2,2 | while read -r order region; do
        (
            f="$STAGE/adguard-setup/region/$region.conf"
            get() { sed -n "s/^$1=//p" "$f" | tr -d '"' | head -n1; }
            texts="$(get TEXTS)" locale="$(get LOCALE)" keymap="$(get KEYMAP)"
            keymap_name="$(get KEYMAP_NAME)" tz="$(get TIMEZONE)"
            for v in texts locale keymap keymap_name tz; do
                [[ -n ${!v} ]] || { echo "region/$region.conf: $v fehlt" >&2; exit 1; }
            done
            # Beschriftung: englisch als Rückfall, dann die Sprache des Eintrags
            . "$STAGE/adguard-setup/lang/en.sh"
            [[ -f $STAGE/adguard-setup/lang/$texts.sh ]] || { echo "lang/$texts.sh fehlt (region/$region.conf)" >&2; exit 1; }
            . "$STAGE/adguard-setup/lang/$texts.sh"
            label="$LANG_NAME | $T_GRUB_KEYBOARD: $keymap_name ($keymap) | $T_GRUB_TIMEZONE: $tz"
            if LC_ALL=C grep -q '[^ -~]' <<<"$label" || [[ $label == *'"'* ]]; then
                echo "Bootmenü: nur ASCII ohne \" erlaubt: $label" >&2
                exit 1
            fi
            echo "    menuentry \"$label\" {"
            echo "        linux  /install.amd/vmlinuz auto=true priority=critical file=/cdrom/preseed.cfg locale=$locale keymap=$keymap time/zone=$tz adguard_region=$region modprobe.blacklist=dw_dmac,dw_dmac_core --- quiet"
            echo "        initrd /install.amd/initrd.gz"
            echo "    }"
            echo "       $label" >&2
        ) || exit 1
    done
}
install_entries > "$STAGE/install-entries.cfg"
[[ -s $STAGE/install-entries.cfg ]] || { echo "Keine Einträge für das Bootmenü (region/*.conf)." >&2; exit 1; }
awk -v entries="$STAGE/install-entries.cfg" '
    $1 == "@INSTALL_ENTRIES@" { while ((getline l < entries) > 0) print l; next }
    { print }' "$STAGE/adguard-setup/installer/grub.cfg" > "$STAGE/grub.cfg"

OUT_ISO="$BUILD_DIR/adguard-wyse3040-$VERSION-debian-$DEBIAN_VERSION.iso"
rm -f "$OUT_ISO"

echo "==> Baue $(basename "$OUT_ISO") ..."
# -boot_image any replay übernimmt die Bootfähigkeit (UEFI + BIOS) der Original-ISO
xorriso -indev "$ISO_NAME" -outdev "$OUT_ISO" \
    -map "$STAGE/adguard-setup"           /adguard-setup \
    -map "$STAGE/adguard-setup/installer/preseed.cfg" /preseed.cfg \
    -map "$STAGE/grub.cfg"                            /boot/grub/grub.cfg \
    -boot_image any replay

echo
echo "Fertig: $OUT_ISO"
echo "Mit Rufus (DD-Modus) oder balenaEtcher auf einen USB-Stick schreiben."
