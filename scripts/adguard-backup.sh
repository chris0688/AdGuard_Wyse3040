#!/usr/bin/env bash
# adguard-backup – Versionen der AdGuard-Einstellungen sichern und wiederherstellen.
#
# Auf dem Gerät: /usr/local/sbin/adguard-backup
#
#   sudo adguard-backup          Menü: Versionen anzeigen, sichern, wiederherstellen,
#                                auf USB-Stick kopieren / von USB-Stick wiederherstellen,
#                                Version zum Herunterladen bereitlegen
#   adguard-backup --auto        (täglich per Timer) sichert nur, wenn sich die
#                                Einstellungen seit der letzten Sicherung geändert haben,
#                                und kopiert die neueste Version auf eingesteckte USB-Sticks
#                                mit Ordner AdGuard-Backup/
#
# Behalten werden die letzten KEEP Versionen in BACKUP_DIR.
set -euo pipefail

AGH_CONF="/opt/AdGuardHome/AdGuardHome.yaml"
AGH_SERVICE="AdGuardHome"
BACKUP_DIR="/var/backups/adguard"
KEEP=7

info() { printf '\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }
err()  { printf '\033[1;31m[x] %s\033[0m\n' "$*" >&2; }

# Backups, neueste zuerst
list_backups() {
    ls -1t "$BACKUP_DIR"/AdGuardHome-*.yaml 2>/dev/null || true
}

# Sichert die aktuelle Konfiguration, wenn sie sich von der neuesten Sicherung
# unterscheidet. Rückgabe 0 = neue Sicherung angelegt, 1 = nichts zu tun.
backup_now() {
    if [[ ! -f $AGH_CONF ]]; then
        echo "AdGuard ist noch nicht eingerichtet – nichts zu sichern."
        return 1
    fi
    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"

    local newest
    newest="$(list_backups | head -n1)"
    if [[ -n $newest ]] && cmp -s "$AGH_CONF" "$newest"; then
        echo "Keine Änderungen seit der letzten Sicherung ($(basename "$newest"))."
        return 1
    fi

    local target
    target="$BACKUP_DIR/AdGuardHome-$(date '+%Y-%m-%d_%H%M%S').yaml"
    install -m 600 "$AGH_CONF" "$target"
    echo "Gesichert: $(basename "$target")"

    # Nur die neuesten KEEP Versionen behalten
    list_backups | tail -n +$((KEEP + 1)) | xargs -r rm -f
    return 0
}

# "AdGuardHome-2026-10-18_033000.yaml" -> "18.10.2026 03:30"
pretty_date() {
    local n="${1##*/AdGuardHome-}"
    n="${n%.yaml}"
    echo "${n:8:2}.${n:5:2}.${n:0:4} ${n:11:2}:${n:13:2}"
}

show_list() {
    local i=1 f
    mapfile -t BACKUPS < <(list_backups)
    if (( ${#BACKUPS[@]} == 0 )); then
        echo "Noch keine Sicherungen vorhanden."
        return
    fi
    echo "Gesicherte Versionen (neueste zuerst):"
    for f in "${BACKUPS[@]}"; do
        printf '  %d)  %s   %6s\n' "$i" "$(pretty_date "$f")" "$(du -h "$f" | cut -f1)"
        i=$((i + 1))
    done
}

choose_backup() {   # Ergebnis in CHOSEN
    local nr
    read -rp "Nummer der Version: " nr
    if [[ ! $nr =~ ^[0-9]+$ ]] || (( nr < 1 || nr > ${#BACKUPS[@]} )); then
        warn "Ungültige Nummer."
        return 1
    fi
    CHOSEN="${BACKUPS[$((nr - 1))]}"
}

restore() {
    choose_backup || return 0
    restore_file "$CHOSEN" "$(pretty_date "$CHOSEN")"
}

# restore_file <datei> <anzeigename> – spielt eine Konfiguration ein
restore_file() {
    local file="$1" a
    echo "Wiederherstellen: $2"
    read -rp "AdGuard wird kurz neu gestartet. Fortfahren? [j/N]: " a
    [[ ${a,,} == j* ]] || { echo "Abgebrochen."; return 0; }

    # Aktuellen Stand vorher sichern, damit man auch zurück kann
    backup_now >/dev/null || true

    systemctl stop "$AGH_SERVICE" || true
    install -m 600 "$file" "$AGH_CONF"
    systemctl start "$AGH_SERVICE" || true
    sleep 3
    if systemctl is-active --quiet "$AGH_SERVICE"; then
        info "Wiederhergestellt. AdGuard läuft."
    else
        local previous
        previous="$(list_backups | head -n1)"
        if [[ -n $previous ]]; then
            err "AdGuard startet mit dieser Version nicht – stelle vorherigen Stand wieder her."
            systemctl stop "$AGH_SERVICE" || true
            install -m 600 "$previous" "$AGH_CONF"
            systemctl start "$AGH_SERVICE" || true
        else
            err "AdGuard startet mit dieser Version nicht. Details: journalctl -u $AGH_SERVICE"
        fi
    fi
}

export_for_download() {
    choose_backup || return 0
    local user="${SUDO_USER:-}"
    if [[ -z $user || $user == root ]]; then
        warn "Bitte mit sudo als normaler Benutzer aufrufen (z.B. adguard)."
        return 0
    fi
    local home target
    home="$(getent passwd "$user" | cut -d: -f6)"
    target="$home/$(basename "$CHOSEN")"
    install -m 600 -o "$user" -g "$(id -gn "$user")" "$CHOSEN" "$target"
    info "Bereitgelegt: $target"
    echo "Auf den PC holen z.B. mit WinSCP oder:"
    echo "  scp ${user}@$(hostname -I | awk '{print $1}'):$(basename "$target") ."
    echo "Danach auf dem Gerät wieder löschen: rm ~/$(basename "$target")"
}

# ---------------------------------------------------------------- USB-Stick

USB_DIR_NAME="AdGuard-Backup"
USB_DEV=""
USB_MNT=""
USB_MOUNTED_BY_US=0

# Listet Partitionen auf USB-Laufwerken mit lesbarem Dateisystem:
# "GERÄT|Beschreibung" pro Zeile
find_usb_partitions() {
    local line NAME PKNAME TYPE FSTYPE SIZE LABEL tran
    while read -r line; do
        eval "$line"
        case "$FSTYPE" in vfat|exfat|ntfs|ext2|ext3|ext4) ;; *) continue ;; esac
        case "$TYPE" in
            part) tran="$(lsblk -dno TRAN "$PKNAME" 2>/dev/null || true)" ;;
            disk) tran="$(lsblk -dno TRAN "$NAME" 2>/dev/null || true)" ;;   # Stick ohne Partitionstabelle
            *)    continue ;;
        esac
        [[ $tran == usb ]] || continue
        echo "$NAME|${LABEL:-ohne Namen} ($FSTYPE, $SIZE)"
    done < <(lsblk -Ppno NAME,PKNAME,TYPE,FSTYPE,SIZE,LABEL)
}

# Setzt USB_DEV; fragt nach, wenn mehrere Sticks stecken
select_usb() {
    local parts p nr i=1
    mapfile -t parts < <(find_usb_partitions)
    if (( ${#parts[@]} == 0 )); then
        warn "Kein USB-Stick gefunden (unterstützt: FAT32, exFAT, NTFS, ext4)."
        return 1
    fi
    if (( ${#parts[@]} == 1 )); then
        USB_DEV="${parts[0]%%|*}"
        echo "USB-Stick: ${parts[0]#*|}  [$USB_DEV]"
        return 0
    fi
    echo "Gefundene USB-Laufwerke:"
    for p in "${parts[@]}"; do
        printf '  %d)  %s  [%s]\n' "$i" "${p#*|}" "${p%%|*}"
        i=$((i + 1))
    done
    read -rp "Welches? Nummer: " nr
    if [[ ! $nr =~ ^[0-9]+$ ]] || (( nr < 1 || nr > ${#parts[@]} )); then
        warn "Ungültige Nummer."
        return 1
    fi
    USB_DEV="${parts[$((nr - 1))]%%|*}"
}

mount_usb() {
    select_usb || return 1
    USB_MNT="$(findmnt -nro TARGET -S "$USB_DEV" 2>/dev/null | head -n1 || true)"
    if [[ -n $USB_MNT ]]; then
        USB_MOUNTED_BY_US=0          # war schon eingehängt
        return 0
    fi
    USB_MNT="$(mktemp -d /mnt/adguard-usb.XXXX)"
    if ! mount -o nosuid,nodev,noexec "$USB_DEV" "$USB_MNT" 2>/dev/null \
       && ! mount -t ntfs3 -o nosuid,nodev,noexec "$USB_DEV" "$USB_MNT" 2>/dev/null; then
        err "USB-Stick konnte nicht eingebunden werden."
        rmdir "$USB_MNT"
        return 1
    fi
    USB_MOUNTED_BY_US=1
}

umount_usb() {
    sync
    if (( USB_MOUNTED_BY_US )); then
        if umount "$USB_MNT"; then
            rmdir "$USB_MNT" || true
            echo "USB-Stick ausgehängt – er kann stecken bleiben oder gefahrlos abgezogen werden."
        else
            warn "USB-Stick konnte nicht ausgehängt werden – vor dem Abziehen: sudo umount $USB_MNT"
        fi
    fi
}

copy_to_usb() {
    if (( ${#BACKUPS[@]} == 0 )); then
        warn "Noch keine Sicherungen vorhanden – zuerst (s) jetzt sichern."
        return 0
    fi
    local sel f files=()
    read -rp "Nummer der Version oder (a) für alle: " sel
    if [[ ${sel,,} == a* ]]; then
        files=("${BACKUPS[@]}")
    elif [[ $sel =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#BACKUPS[@]} )); then
        files=("${BACKUPS[$((sel - 1))]}")
    else
        warn "Ungültige Auswahl."
        return 0
    fi

    mount_usb || return 0
    if mkdir -p "$USB_MNT/$USB_DIR_NAME" && cp "${files[@]}" "$USB_MNT/$USB_DIR_NAME/"; then
        info "${#files[@]} Version(en) auf den USB-Stick kopiert (Ordner $USB_DIR_NAME)."
        echo "Bleibt der Stick stecken, wird jede neue Sicherung automatisch mit draufkopiert."
    else
        err "Kopieren fehlgeschlagen (Stick voll oder schreibgeschützt?)."
    fi
    umount_usb
}

# Für --auto: die neueste Sicherung auf jeden eingesteckten USB-Stick kopieren,
# auf dem es den Ordner AdGuard-Backup/ gibt (entsteht beim ersten Kopieren mit (u)).
# Ohne Rückfragen; der Stick ist nur während des Kopierens eingehängt.
USB_KEEP=30
auto_copy_to_usb() {
    local newest="$1" p dev mnt mounted
    while IFS= read -r p; do
        dev="${p%%|*}"
        mnt="$(findmnt -nro TARGET -S "$dev" 2>/dev/null | head -n1 || true)"
        mounted=0
        if [[ -z $mnt ]]; then
            mnt="$(mktemp -d /mnt/adguard-usb.XXXX)"
            if ! mount -o nosuid,nodev,noexec "$dev" "$mnt" 2>/dev/null \
               && ! mount -t ntfs3 -o nosuid,nodev,noexec "$dev" "$mnt" 2>/dev/null; then
                rmdir "$mnt"
                continue
            fi
            mounted=1
        fi
        if [[ -d $mnt/$USB_DIR_NAME && ! -f $mnt/$USB_DIR_NAME/$(basename "$newest") ]]; then
            if cp "$newest" "$mnt/$USB_DIR_NAME/"; then
                echo "Auch auf USB-Stick kopiert: ${p#*|}"
                # Nur eigene Sicherungen aufräumen, selbst abgelegte Dateien bleiben
                ls -1t "$mnt/$USB_DIR_NAME"/AdGuardHome-*.yaml 2>/dev/null \
                    | tail -n +$((USB_KEEP + 1)) | xargs -r rm -f
            else
                echo "Kopieren auf USB-Stick fehlgeschlagen: ${p#*|}" >&2
            fi
        fi
        sync
        if (( mounted )); then
            umount "$mnt" && rmdir "$mnt" || true
        fi
    done < <(find_usb_partitions)
}

# Anzeigename einer Sicherungsdatei (auch für umbenannte Dateien auf dem Stick)
describe_file() {
    local b
    b="$(basename "$1")"
    if [[ $b =~ ^AdGuardHome-[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}\.yaml$ ]]; then
        pretty_date "$1"
    else
        echo "$b  (geändert $(date -r "$1" '+%d.%m.%Y %H:%M'))"
    fi
}

restore_from_usb() {
    local files f nr i=1 chosen tmp desc
    mount_usb || return 0
    # Gesucht wird im Ordner AdGuard-Backup/ und direkt im Hauptverzeichnis des Sticks
    mapfile -t files < <(ls -1t "$USB_MNT/$USB_DIR_NAME"/*.yaml "$USB_MNT"/AdGuardHome*.yaml 2>/dev/null || true)
    if (( ${#files[@]} == 0 )); then
        warn "Keine Sicherungen auf dem Stick gefunden (erwartet im Ordner $USB_DIR_NAME/)."
        umount_usb
        return 0
    fi
    echo "Sicherungen auf dem USB-Stick (neueste zuerst):"
    for f in "${files[@]}"; do
        printf '  %d)  %s\n' "$i" "$(describe_file "$f")"
        i=$((i + 1))
    done
    read -rp "Nummer der Version: " nr
    if [[ ! $nr =~ ^[0-9]+$ ]] || (( nr < 1 || nr > ${#files[@]} )); then
        warn "Ungültige Nummer."
        umount_usb
        return 0
    fi
    chosen="${files[$((nr - 1))]}"
    desc="$(describe_file "$chosen") vom USB-Stick"

    # Erst lokal zwischenspeichern, damit der Stick gleich wieder frei ist
    tmp="$(mktemp)"
    cp "$chosen" "$tmp"
    umount_usb

    if ! grep -q '^dns:' "$tmp"; then
        err "Das sieht nicht nach einer AdGuard-Konfiguration aus – abgebrochen."
        rm -f "$tmp"
        return 0
    fi
    restore_file "$tmp" "$desc"
    rm -f "$tmp"
}

# ---------------------------------------------------------------- main

if [[ $EUID -ne 0 ]]; then
    err "Bitte als root ausführen: sudo adguard-backup"
    exit 1
fi

if [[ ${1:-} == --auto ]]; then
    backup_now || true
    newest="$(list_backups | head -n1)"
    # Auch wenn sich nichts geändert hat: ein neu eingesteckter Stick bekommt so
    # beim nächsten Lauf den aktuellen Stand.
    [[ -n $newest ]] && auto_copy_to_usb "$newest"
    exit 0
fi

while true; do
    echo
    info "AdGuard-Einstellungen – Sicherungen ($BACKUP_DIR, es werden die letzten $KEEP behalten)"
    show_list
    echo
    echo "  (s) jetzt sichern            (w) Version wiederherstellen"
    echo "  (u) auf USB-Stick kopieren   (v) von USB-Stick wiederherstellen"
    echo "  (d) Version zum Download bereitlegen (WinSCP/scp)"
    echo "  (q) beenden"
    read -rp "Auswahl: " choice
    case "${choice,,}" in
        s) backup_now || true ;;
        w) (( ${#BACKUPS[@]} )) && restore ;;
        u) copy_to_usb ;;
        v) restore_from_usb ;;
        d) (( ${#BACKUPS[@]} )) && export_for_download ;;
        q|"") exit 0 ;;
        *) warn "Unbekannte Auswahl." ;;
    esac
done
