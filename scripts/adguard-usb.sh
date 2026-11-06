#!/usr/bin/env bash
# adguard-usb – Infos zu eingesteckten USB-Sticks
#
# Auf dem Gerät: /usr/local/sbin/adguard-usb
#
#   adguard-usb info           eine Zeile je Stick: Name, Dateisystem, frei/gesamt,
#                              Anzahl Backups im Ordner AdGuard-Backup/ (für "status")
#
# Intern:
#   adguard-usb issue          Zeilen "USB-Stick" für den Login-Banner (adguard-banner)
#   adguard-usb event add|remove GERÄT [NAME]
#                              (von udev, 90-adguard-usb.rules) Meldung an alle
#                              angemeldeten Sitzungen (Konsole, SSH) und ins
#                              Systemprotokoll, danach Login-Banner neu erzeugen
#
# Für frei/belegt wird ein nicht eingehängter Stick kurz NUR LESEND eingehängt.
set -uo pipefail

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
        echo "$NAME|${LABEL:-ohne Namen}|$FSTYPE|$SIZE"
    done < <(lsblk -Ppno NAME,PKNAME,TYPE,FSTYPE,SIZE,LABEL 2>/dev/null)
}

# Bytes -> "6,9 GB" bzw. "512 MB"
human() {
    awk -v b="$1" 'BEGIN {
        if (b >= 1e9) s = sprintf("%.1f GB", b / 1e9); else s = sprintf("%d MB", b / 1e6)
        gsub(/\./, ",", s); print s
    }'
}

# info_line GERÄT NAME DATEISYSTEM GRÖSSE
# -> "HP_TOOLS (vfat) – 6,9 GB frei von 7,5 GB – 3 Backups"
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
            echo "$text – $size, nicht lesbar"
            return
        fi
        mnt="$tmp"
    fi

    read -r total used avail < <(df -B1 --output=size,used,avail "$mnt" | awk 'NR==2')
    text+=" – $(human "$avail") frei von $(human "$total")"
    if [[ -d $mnt/$USB_DIR_NAME ]]; then
        n=$(find "$mnt/$USB_DIR_NAME" -maxdepth 1 -name '*.yaml' | wc -l)
        if (( n == 1 )); then text+=" – 1 Backup"; else text+=" – $n Backups"; fi
    else
        text+=" – keine Backups"
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

# Zeilen für den Login-Banner (ohne Einhängen, nur Name und Größe);
# adguard-banner baut sie in den Kasten mit Hostname/IP ein
cmd_issue() {
    local d l f s
    while IFS='|' read -r d l f s; do
        echo "\\e{lightblue}    USB-Stick:        \\e{lightcyan}$l\\e{reset} ($f, $s)"
    done < <(list_usb)
}

# Meldung an alle Terminals angemeldeter Benutzer (lokale Konsole und SSH).
# Nicht über "who": Debian 13 führt die utmp-Liste nicht mehr zuverlässig,
# SSH-Sitzungen fehlen dort. Stattdessen Sitzungen von systemd-logind plus
# alle offenen Pseudo-Terminals (SSH, Cockpit-Terminal).
broadcast() {
    local s tty
    {
        for s in $(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}'); do
            tty="$(loginctl show-session "$s" -p TTY --value 2>/dev/null)"
            [[ -n $tty ]] && echo "/dev/${tty#/dev/}"
        done
        ls -1 /dev/pts/[0-9]* 2>/dev/null
    } | sort -u | while read -r tty; do
        [[ -c $tty ]] || continue
        timeout 2 sh -c 'printf "\r\n\033[1;36m[USB]\033[0m %s\r\n" "$1" > "$2"' _ "$1" "$tty" 2>/dev/null
    done
}

cmd_event() {
    local action="$1" name="$2" label="${3:-}" msg d l f s
    case "$action" in
        add)
            sleep 1   # Stick erst fertig erkennen lassen
            msg="USB-Stick eingesteckt: ${label:-ohne Namen} ($name)"
            while IFS='|' read -r d l f s; do
                [[ $d == "/dev/$name" ]] && msg="USB-Stick eingesteckt: $(info_line "$d" "$l" "$f" "$s")"
            done < <(list_usb)
            ;;
        remove)
            msg="USB-Stick getrennt: ${label:-ohne Namen} ($name)" ;;
        *)  return 2 ;;
    esac
    logger -t adguard-usb "$msg"
    broadcast "$msg"
    /usr/local/sbin/adguard-banner || true
}

if [[ $EUID -ne 0 ]]; then
    echo "Bitte als root ausführen: sudo adguard-usb ${1:-info}" >&2
    exit 1
fi

case "${1:-info}" in
    info)  cmd_info ;;
    issue) cmd_issue ;;
    event) [[ $# -ge 3 ]] || { echo "Aufruf: adguard-usb event add|remove GERÄT [NAME]" >&2; exit 2; }
           cmd_event "$2" "$3" "${4:-}" ;;
    *)     echo "Aufruf: adguard-usb [info|issue]" >&2; exit 2 ;;
esac
