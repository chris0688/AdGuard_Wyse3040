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
# Intern (von adguard-setup genutzt):
#   adguard-backup --fetch-usb DIR     neueste Sicherung von einem USB-Stick nach DIR holen
#   adguard-backup --restore-file DATEI  ohne Rückfrage wiederherstellen
#
# Gesichert werden:
#   AdGuardHome-<datum>.yaml   AdGuard-Einstellungen, die letzten KEEP Versionen
#   adguard-setup.conf         Einstellungen aus adguard-setup (nur der aktuelle Stand)
#
# Texte: lang/<sprache>.sh, Abschnitt T_BACKUP_* (siehe scripts/i18n.sh)
set -euo pipefail
. /usr/local/share/adguard/i18n.sh

AGH_CONF="/opt/AdGuardHome/AdGuardHome.yaml"
AGH_SERVICE="AdGuardHome"
SETUP_CONF="/etc/adguard-setup.conf"
BACKUP_DIR="/var/backups/adguard"
KEEP=7
USB_DIR_NAME="AdGuard-Backup"
USB_KEEP=30

info() { printf '\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }
err()  { printf '\033[1;31m[x] %s\033[0m\n' "$*" >&2; }

# t "TEXT" ARGUMENTE... – übersetzten Text mit Platzhaltern ausgeben (ohne Zeilenende)
t() { local f="$1"; shift; printf -- "$f" "$@"; }

# ---------------------------------------------------------------- Sichern

# Backups, neueste zuerst
list_backups() {
    ls -1t "$BACKUP_DIR"/AdGuardHome-*.yaml 2>/dev/null || true
}

# Sichert die aktuelle Konfiguration, wenn sie sich von der neuesten Sicherung
# unterscheidet. Mit --ask (Menü) wird bei unveränderter Konfiguration gefragt,
# ob trotzdem gesichert werden soll.
# Rückgabe 0 = neue Sicherung angelegt, 1 = nichts zu tun.
backup_now() {
    local ask="${1:-}"
    backup_setup_conf
    if [[ ! -f $AGH_CONF ]]; then
        echo "$T_BACKUP_AGH_NOT_SET_UP"
        return 1
    fi
    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"

    local newest
    newest="$(list_backups | head -n1)"
    if [[ -n $newest ]] && cmp -s "$AGH_CONF" "$newest"; then
        t "$T_BACKUP_UNCHANGED\n" "$(pretty_date "$newest")"
        [[ $ask == --ask ]] || return 1
        adguard_yesno "$T_BACKUP_ANYWAY" n || return 1
    fi

    local target
    target="$BACKUP_DIR/AdGuardHome-$(date '+%Y-%m-%d_%H%M%S').yaml"
    install -m 600 "$AGH_CONF" "$target"
    t "$T_BACKUP_SAVED\n" "$(basename "$target")"

    # Nur die neuesten KEEP Versionen behalten
    list_backups | tail -n +$((KEEP + 1)) | xargs -r rm -f
    return 0
}

# Einstellungen aus adguard-setup sichern (nur der aktuelle Stand, ändert sich selten)
backup_setup_conf() {
    [[ -f $SETUP_CONF ]] || return 0
    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"
    if ! cmp -s "$SETUP_CONF" "$BACKUP_DIR/adguard-setup.conf"; then
        install -m 600 "$SETUP_CONF" "$BACKUP_DIR/adguard-setup.conf"
        echo "$T_BACKUP_SETTINGS_SAVED"
    fi
}

# ---------------------------------------------------------------- Anzeige / Auswahl

# "AdGuardHome-2026-10-18_033000.yaml" -> "18.10.2026 03:30" (Format der Region)
pretty_date() {
    local n="${1##*AdGuardHome-}"
    n="${n%.yaml}"
    adguard_date -d "${n:0:10} ${n:11:2}:${n:13:2}"
}

# Anzeigename einer Sicherungsdatei (auch für umbenannte Dateien auf dem Stick)
describe_file() {
    local b
    b="$(basename "$1")"
    if [[ $b =~ ^AdGuardHome-[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}\.yaml$ ]]; then
        pretty_date "$1"
    else
        t "%s  ($T_BACKUP_MODIFIED)\n" "$b" "$(adguard_date -r "$1")"
    fi
}

# Übersicht im Hauptmenü – bewusst ohne Nummern, die gehören dort dem Menü.
# Nummeriert wird erst im Auswahlschritt (choose_backup).
show_list() {
    local f
    mapfile -t BACKUPS < <(list_backups)
    if (( ${#BACKUPS[@]} == 0 )); then
        echo "$T_BACKUP_NONE_YET"
        return
    fi
    echo "$T_BACKUP_LIST_TITLE"
    for f in "${BACKUPS[@]}"; do
        printf '   •  %s   %6s\n' "$(pretty_date "$f")" "$(adguard_decimal "$(LC_ALL=C.UTF-8 du -h "$f" | cut -f1)")"
    done
    [[ -f $BACKUP_DIR/adguard-setup.conf ]] && echo "  + $T_BACKUP_SYSTEM_SETTINGS"
    return 0
}

# pick "Überschrift" [--alle] "Zeile 1" "Zeile 2" ... – Auswahlschritt mit
# nummerierter Liste und "0) zurück". Ergebnis in PICK (Nummer ab 1) bzw.
# PICK="ALLE" bei Enter mit --alle. Rückgabe 1 = zurück.
pick() {
    local title="$1" all="" i=1 line nr
    shift
    if [[ ${1:-} == --alle ]]; then all=1; shift; fi
    echo
    echo "$title"
    for line in "$@"; do
        printf '  %d)  %s\n' "$i" "$line"
        i=$((i + 1))
    done
    echo "  0)  $T_BACK"
    while true; do
        if [[ -n $all ]]; then
            read -rp "$T_CHOICE [$T_BACKUP_ENTER_ALL]: " nr
            [[ -z $nr ]] && { PICK="ALLE"; return 0; }
        else
            read -rp "$T_CHOICE [0]: " nr
            nr="${nr:-0}"
        fi
        [[ $nr == 0 ]] && return 1
        if [[ $nr =~ ^[0-9]+$ ]] && (( nr >= 1 && nr <= $# )); then
            PICK="$nr"
            return 0
        fi
        warn "$(t "$T_NUMBER_RANGE" 0 $#)"
    done
}

# choose_backup "Überschrift" [--alle] – Version aus der lokalen Liste wählen.
# Ergebnis in CHOSEN (eine Datei) bzw. CHOSEN="ALLE". Rückgabe 1 = zurück.
choose_backup() {
    local f lines=()
    for f in "${BACKUPS[@]}"; do
        lines+=("$(printf '%s   %6s' "$(pretty_date "$f")" "$(adguard_decimal "$(LC_ALL=C.UTF-8 du -h "$f" | cut -f1)")")")
    done
    lines[0]+="   ($T_BACKUP_NEWEST)"
    pick "$1" ${2:+"$2"} "${lines[@]}" || return 1
    if [[ $PICK == ALLE ]]; then
        CHOSEN="ALLE"
    else
        CHOSEN="${BACKUPS[$((PICK - 1))]}"
    fi
}

# ---------------------------------------------------------------- Wiederherstellen

restore() {
    choose_backup "$T_BACKUP_Q_RESTORE" || return 0
    restore_file "$CHOSEN" "$(pretty_date "$CHOSEN")" || true
}

# restore_file <datei> <anzeigename> [--yes] – spielt eine Konfiguration ein.
# Rückgabe 0 = AdGuard läuft mit der neuen Konfiguration.
restore_file() {
    local file="$1"
    if [[ ${3:-} != --yes ]]; then
        t "$T_BACKUP_RESTORING\n" "$2"
        if ! adguard_yesno "$T_BACKUP_Q_CONTINUE" n; then
            echo "$T_BACKUP_CANCELLED"
            return 0
        fi
    fi

    if ! grep -q '^dns:' "$file"; then
        err "$T_BACKUP_NOT_AGH_CONF"
        return 1
    fi

    # Aktuellen Stand vorher sichern, damit man auch zurück kann
    backup_now >/dev/null || true

    systemctl stop "$AGH_SERVICE" || true
    install -m 600 "$file" "$AGH_CONF"
    systemctl start "$AGH_SERVICE" || true
    sleep 3
    if systemctl is-active --quiet "$AGH_SERVICE"; then
        info "$T_BACKUP_RESTORED"
        return 0
    fi

    local previous
    previous="$(list_backups | head -n1)"
    if [[ -n $previous ]]; then
        err "$T_BACKUP_START_FAILED_ROLLBACK"
        systemctl stop "$AGH_SERVICE" || true
        install -m 600 "$previous" "$AGH_CONF"
        systemctl start "$AGH_SERVICE" || true
    else
        err "$(t "$T_BACKUP_START_FAILED" "journalctl -u $AGH_SERVICE")"
    fi
    return 1
}

export_for_download() {
    choose_backup "$T_BACKUP_Q_EXPORT" || return 0
    local user="${SUDO_USER:-}"
    if [[ -z $user || $user == root ]]; then
        warn "$T_BACKUP_EXPORT_NEED_SUDO"
        return 0
    fi
    local home target
    home="$(getent passwd "$user" | cut -d: -f6)"
    target="$home/$(basename "$CHOSEN")"
    install -m 600 -o "$user" -g "$(id -gn "$user")" "$CHOSEN" "$target"
    info "$(t "$T_BACKUP_EXPORTED" "$target")"
    echo "$T_BACKUP_EXPORT_HOW"
    echo "  scp ${user}@$(hostname -I | awk '{print $1}'):$(basename "$target") ."
    t "$T_BACKUP_EXPORT_CLEANUP\n" "rm ~/$(basename "$target")"
}

# ---------------------------------------------------------------- USB-Stick: Grundlagen

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
        echo "$NAME|${LABEL:-$T_USB_NO_NAME} ($FSTYPE, $(adguard_decimal "$SIZE"))"
    done < <(LC_ALL=C.UTF-8 lsblk -Ppno NAME,PKNAME,TYPE,FSTYPE,SIZE,LABEL)
}

# mount_dev <gerät> – hängt ein (falls nötig) und setzt MNT und MOUNTED_BY_US.
# Der Stick ist nur so lange eingehängt wie nötig (schützt vor Datenverlust
# bei Stromausfall).
mount_dev() {
    MNT="$(findmnt -nro TARGET -S "$1" 2>/dev/null | head -n1 || true)"
    MOUNTED_BY_US=0
    [[ -n $MNT ]] && return 0
    MNT="$(mktemp -d /mnt/adguard-usb.XXXX)"
    if ! mount -o nosuid,nodev,noexec "$1" "$MNT" 2>/dev/null \
       && ! mount -t ntfs3 -o nosuid,nodev,noexec "$1" "$MNT" 2>/dev/null; then
        rmdir "$MNT"
        return 1
    fi
    MOUNTED_BY_US=1
}

# umount_dev [leise] – hängt wieder aus, wenn wir eingehängt haben
umount_dev() {
    sync
    (( MOUNTED_BY_US )) || return 0
    if umount "$MNT"; then
        rmdir "$MNT" || true
        [[ ${1:-} == leise ]] || echo "$T_BACKUP_USB_UNMOUNTED"
    else
        warn "$(t "$T_BACKUP_USB_UNMOUNT_FAILED" "sudo umount $MNT")"
    fi
}

# Fragt nach, wenn mehrere Sticks stecken; setzt USB_DEV
select_usb() {
    local parts p lines=()
    mapfile -t parts < <(find_usb_partitions)
    if (( ${#parts[@]} == 0 )); then
        warn "$T_BACKUP_USB_NONE"
        return 1
    fi
    if (( ${#parts[@]} == 1 )); then
        USB_DEV="${parts[0]%%|*}"
        echo "$T_MOTD_USB ${parts[0]#*|}  [$USB_DEV]"
        return 0
    fi
    for p in "${parts[@]}"; do
        lines+=("${p#*|}  [${p%%|*}]")
    done
    pick "$T_BACKUP_Q_WHICH_USB" "${lines[@]}" || return 1
    USB_DEV="${parts[$((PICK - 1))]%%|*}"
}

mount_usb() {
    select_usb || return 1
    if ! mount_dev "$USB_DEV"; then
        err "$T_BACKUP_USB_MOUNT_FAILED"
        return 1
    fi
}

# Kopiert Dateien ins Backup-Verzeichnis des eingehängten Sticks.
# --preserve=timestamps: Reihenfolge nach Datum bleibt erhalten (auch auf FAT32).
copy_into_usb_dir() {
    mkdir -p "$MNT/$USB_DIR_NAME" && cp --preserve=timestamps "$@" "$MNT/$USB_DIR_NAME/"
}

# ---------------------------------------------------------------- USB-Stick: Menüpunkte

copy_to_usb() {
    if (( ${#BACKUPS[@]} == 0 )); then
        warn "$T_BACKUP_COPY_NONE"
        return 0
    fi
    local files=()
    choose_backup "$T_BACKUP_Q_COPY" --alle || return 0
    if [[ $CHOSEN == ALLE ]]; then
        files=("${BACKUPS[@]}")
    else
        files=("$CHOSEN")
    fi
    [[ -f $BACKUP_DIR/adguard-setup.conf ]] && files+=("$BACKUP_DIR/adguard-setup.conf")

    mount_usb || return 0
    if copy_into_usb_dir "${files[@]}"; then
        info "$(t "$T_BACKUP_COPIED" "$USB_DIR_NAME")"
        echo "$T_BACKUP_COPY_AUTO_HINT"
    else
        err "$T_BACKUP_COPY_FAILED"
    fi
    umount_dev
}

restore_from_usb() {
    local files f lines=() chosen tmp desc
    mount_usb || return 0
    # Gesucht wird im Ordner AdGuard-Backup/ und direkt im Hauptverzeichnis des Sticks
    mapfile -t files < <(ls -1t "$MNT/$USB_DIR_NAME"/*.yaml "$MNT"/AdGuardHome*.yaml 2>/dev/null || true)
    if (( ${#files[@]} == 0 )); then
        warn "$(t "$T_BACKUP_USB_NO_BACKUPS" "$USB_DIR_NAME/")"
        umount_dev
        return 0
    fi
    for f in "${files[@]}"; do
        lines+=("$(describe_file "$f")")
    done
    lines[0]+="   ($T_BACKUP_NEWEST)"
    if ! pick "$T_BACKUP_Q_RESTORE_USB" "${lines[@]}"; then
        umount_dev leise
        return 0
    fi
    chosen="${files[$((PICK - 1))]}"
    desc="$(t "$T_BACKUP_FROM_USB" "$(describe_file "$chosen")")"

    # Erst lokal zwischenspeichern, damit der Stick gleich wieder frei ist
    tmp="$(mktemp)"
    cp "$chosen" "$tmp"
    umount_dev
    restore_file "$tmp" "$desc" || true
    rm -f "$tmp"
}

# ---------------------------------------------------------------- USB-Stick: automatisch

# Für --auto: neueste Sicherung und Systemeinstellungen auf jeden eingesteckten
# Stick kopieren, auf dem es den Ordner AdGuard-Backup/ gibt (entsteht beim
# ersten Kopieren mit Menüpunkt 3). Ohne Rückfragen.
auto_copy_to_usb() {
    local newest="$1" p dir
    while IFS= read -r p; do
        mount_dev "${p%%|*}" || continue
        dir="$MNT/$USB_DIR_NAME"
        if [[ -d $dir ]]; then
            if [[ -n $newest && ! -f $dir/$(basename "$newest") ]]; then
                if copy_into_usb_dir "$newest"; then
                    t "$T_BACKUP_AUTO_COPIED\n" "${p#*|}"
                    # Nur eigene Sicherungen aufräumen, selbst abgelegte Dateien bleiben
                    ls -1t "$dir"/AdGuardHome-*.yaml 2>/dev/null \
                        | tail -n +$((USB_KEEP + 1)) | xargs -r rm -f
                else
                    t "$T_BACKUP_AUTO_COPY_FAILED\n" "${p#*|}" >&2
                fi
            fi
            if [[ -f $BACKUP_DIR/adguard-setup.conf ]] \
               && ! cmp -s "$BACKUP_DIR/adguard-setup.conf" "$dir/adguard-setup.conf"; then
                copy_into_usb_dir "$BACKUP_DIR/adguard-setup.conf" \
                    && t "$T_BACKUP_AUTO_SETTINGS_COPIED\n" "${p#*|}"
            fi
        fi
        umount_dev leise
    done < <(find_usb_partitions)
}

# Für --fetch-usb DIR (adguard-setup bei der Ersteinrichtung): sucht auf allen
# Sticks die neueste Sicherung und legt sie mit den Systemeinstellungen nach DIR:
#   DIR/AdGuardHome.yaml, DIR/adguard-setup.conf (falls vorhanden), DIR/source.txt
# Rückgabe 1, wenn nichts gefunden wurde.
fetch_from_usb() {
    local target="$1" p newest best="" best_name=""
    while IFS= read -r p; do
        mount_dev "${p%%|*}" || continue
        # Neueste nach Dateiname (enthält das Sicherungsdatum)
        newest="$(ls -1 "$MNT/$USB_DIR_NAME"/AdGuardHome-*.yaml 2>/dev/null | sort | tail -n1 || true)"
        if [[ -n $newest && $(basename "$newest") > $best_name ]]; then
            best_name="$(basename "$newest")"
            best="${p#*|}"
            cp "$newest" "$target/AdGuardHome.yaml"
            rm -f "$target/adguard-setup.conf"
            [[ -f $MNT/$USB_DIR_NAME/adguard-setup.conf ]] \
                && cp "$MNT/$USB_DIR_NAME/adguard-setup.conf" "$target/adguard-setup.conf"
        fi
        umount_dev leise
    done < <(find_usb_partitions)

    [[ -n $best_name ]] || return 1
    local text
    if [[ -f $target/adguard-setup.conf ]]; then
        text="$(t "$T_BACKUP_FOUND_WITH_SETTINGS" "$(pretty_date "$best_name")" "$best")"
    else
        text="$(t "$T_BACKUP_FOUND" "$(pretty_date "$best_name")" "$best")"
    fi
    echo "$text" > "$target/source.txt"
}

# ---------------------------------------------------------------- main

if [[ $EUID -ne 0 ]]; then
    err "$(t "$T_NEED_ROOT" adguard-backup)"
    exit 1
fi

case "${1:-}" in
    --auto)
        backup_now || true
        # Auch ohne Änderungen: ein neu eingesteckter Stick bekommt so beim
        # nächsten Lauf den aktuellen Stand.
        auto_copy_to_usb "$(list_backups | head -n1)"
        exit 0 ;;
    --fetch-usb)
        [[ -d ${2:-} ]] || { err "Usage: adguard-backup --fetch-usb DIRECTORY"; exit 2; }
        fetch_from_usb "$2"
        exit $? ;;
    --restore-file)
        [[ -f ${2:-} ]] || { err "Usage: adguard-backup --restore-file FILE"; exit 2; }
        restore_file "$2" "$2" --yes
        exit $? ;;
esac

while true; do
    echo
    info "$(t "$T_BACKUP_MENU_TITLE" "$BACKUP_DIR" "$KEEP")"
    show_list
    echo
    echo "  1) $T_BACKUP_MENU_1"
    echo "  2) $T_BACKUP_MENU_2"
    echo "  3) $T_BACKUP_MENU_3"
    echo "  4) $T_BACKUP_MENU_4"
    echo "  5) $T_BACKUP_MENU_5"
    echo "  0) $T_BACKUP_MENU_0"
    read -rp "$T_CHOICE [0]: " choice
    case "$choice" in
        1) backup_now --ask || true ;;
        2) (( ${#BACKUPS[@]} )) && restore ;;
        3) copy_to_usb ;;
        4) restore_from_usb ;;
        5) (( ${#BACKUPS[@]} )) && export_for_download ;;
        0|"") exit 0 ;;
        *) warn "$(t "$T_NUMBER_RANGE" 0 5)" ;;
    esac
done
