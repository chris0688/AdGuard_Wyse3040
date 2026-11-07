#!/usr/bin/env bash
# adguard-usb – Infos zu eingesteckten USB-Sticks
#
# Auf dem Gerät: /usr/local/sbin/adguard-usb
#
#   adguard-usb info           eine Zeile je Stick: Name, Dateisystem, frei/gesamt,
#                              Anzahl Backups im Ordner AdGuard-Backup/ (für "status")
#
# Intern:
#   adguard-usb issue          "NAME|(DATEISYSTEM, GRÖSSE)" je Stick für den
#                              Login-Banner (adguard-banner formatiert die Zeilen)
#   adguard-usb event add|remove GERÄT [NAME]
#                              (von udev, 90-adguard-usb.rules) Eintrag ins
#                              Systemprotokoll, danach Login-Banner neu erzeugen
#
# Für frei/belegt wird ein nicht eingehängter Stick kurz NUR LESEND eingehängt.
set -uo pipefail
export LC_ALL=C.UTF-8   # feste Zahlenformate (lsblk/df), Dezimaltrennzeichen setzt die Region
. /usr/local/share/adguard/i18n.sh

USB_DIR_NAME="AdGuard-Backup"

# "GERÄT|NAME|DATEISYSTEM|GRÖSSE" je USB-Datenträger mit Dateisystem
list_usb() {
    local line NAME PKNAME TYPE FSTYPE SIZE LABEL tran
    while read -r line; do
        eval "$line"
        [[ -n $FSTYPE ]] || continue
        case "$TYPE" in
            part) tran="$(lsblk -dno TRAN "$PKNAME" 2>/dev/null)" ;;
            disk) tran="$(lsblk -dno TRAN "$NAME" 2>/dev/null)" ;;   # Stick ohne Partitionstabelle
            *)    continue ;;
        esac
        [[ $tran == usb ]] || continue
        echo "$NAME|${LABEL:-$T_USB_NO_NAME}|$FSTYPE|$(adguard_decimal "$SIZE")"
    done < <(lsblk -Ppno NAME,PKNAME,TYPE,FSTYPE,SIZE,LABEL 2>/dev/null)
}

# Bytes -> "6.9 GB" bzw. "512 MB" (mit dem Dezimaltrennzeichen der Region)
human() {
    adguard_decimal "$(awk -v b="$1" 'BEGIN {
        if (b >= 1e9) printf "%.1f GB\n", b / 1e9; else printf "%d MB\n", b / 1e6
    }')"
}

# info_line GERÄT NAME DATEISYSTEM GRÖSSE
# -> "HP_TOOLS (vfat) – 6.9 GB free of 7.5 GB – 3 backups"
info_line() {
    local dev="$1" label="$2" fs="$3" size="$4" mnt tmp="" opts total used avail n text
    text="$label ($fs)"

    mnt="$(findmnt -nro TARGET -S "$dev" 2>/dev/null | head -n1)"
    if [[ -z $mnt ]]; then
        case "$fs" in vfat|exfat|ntfs|ext2|ext3|ext4) ;; *) echo "$text – $size"; return ;; esac
        opts="ro,nosuid,nodev,noexec"
        [[ $fs == ext* ]] && opts+=",noload"   # nichts schreiben, auch kein Journal
        tmp="$(mktemp -d /run/adguard-usb.XXXX)"
        if ! timeout 10 mount -o "$opts" "$dev" "$tmp" 2>/dev/null \
           && ! timeout 10 mount -t ntfs3 -o "$opts" "$dev" "$tmp" 2>/dev/null; then
            rmdir "$tmp"
            echo "$text – $size, $T_USB_UNREADABLE"
            return
        fi
        mnt="$tmp"
    fi

    read -r total used avail < <(df -B1 --output=size,used,avail "$mnt" | awk 'NR==2')
    text+=" – $(printf "$T_USB_FREE_OF" "$(human "$avail")" "$(human "$total")")"
    if [[ -d $mnt/$USB_DIR_NAME ]]; then
        n=$(find "$mnt/$USB_DIR_NAME" -maxdepth 1 -name '*.yaml' | wc -l)
        if (( n == 1 )); then
            text+=" – $T_USB_BACKUPS_ONE"
        else
            text+=" – $(printf "$T_USB_BACKUPS_MANY" "$n")"
        fi
    else
        text+=" – $T_USB_BACKUPS_NONE"
    fi

    if [[ -n $tmp ]]; then
        umount "$tmp" 2>/dev/null && rmdir "$tmp"
    fi
    echo "$text"
}

cmd_info() {
    local d l f s
    while IFS='|' read -r d l f s; do
        info_line "$d" "$l" "$f" "$s"
    done < <(list_usb)
}

# Daten für den Login-Banner (ohne Einhängen, nur Name und Größe)
cmd_issue() {
    local d l f s
    while IFS='|' read -r d l f s; do
        echo "$l|($f, $s)"
    done < <(list_usb)
}

# Bewusst keine Meldung in offene Terminals (Konsole/SSH): Das stört die
# Eingabezeile und ist bei SSH-Sitzungen fehleranfällig. Info gibt es im
# Login-Banner, in "status" und im Protokoll.
cmd_event() {
    local action="$1" name="$2" label="${3:-}" msg d l f s
    case "$action" in
        add)
            sleep 1   # Stick erst fertig erkennen lassen
            msg="$(printf "$T_USB_PLUGGED" "${label:-$T_USB_NO_NAME} ($name)")"
            while IFS='|' read -r d l f s; do
                [[ $d == "/dev/$name" ]] && msg="$(printf "$T_USB_PLUGGED" "$(info_line "$d" "$l" "$f" "$s")")"
            done < <(list_usb)
            ;;
        remove)
            msg="$(printf "$T_USB_REMOVED" "${label:-$T_USB_NO_NAME} ($name)")" ;;
        *)  return 2 ;;
    esac
    logger -t adguard-usb "$msg"
    /usr/local/sbin/adguard-banner || true
}

if [[ $EUID -ne 0 ]]; then
    printf "$T_NEED_ROOT\n" "adguard-usb ${1:-info}" >&2
    exit 1
fi

case "${1:-info}" in
    info)  cmd_info ;;
    issue) cmd_issue ;;
    event) [[ $# -ge 3 ]] || { echo "Usage: adguard-usb event add|remove DEVICE [NAME]" >&2; exit 2; }
           cmd_event "$2" "$3" "${4:-}" ;;
    *)     echo "Usage: adguard-usb [info|issue]" >&2; exit 2 ;;
esac
