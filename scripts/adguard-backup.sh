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
set -euo pipefail

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

# ---------------------------------------------------------------- Sichern

# Backups, neueste zuerst
list_backups() {
    ls -1t "$BACKUP_DIR"/AdGuardHome-*.yaml 2>/dev/null || true
}

# Sichert die aktuelle Konfiguration, wenn sie sich von der neuesten Sicherung
# unterscheidet. Rückgabe 0 = neue Sicherung angelegt, 1 = nichts zu tun.
backup_now() {
    backup_setup_conf
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

# Einstellungen aus adguard-setup sichern (nur der aktuelle Stand, ändert sich selten)
backup_setup_conf() {
    [[ -f $SETUP_CONF ]] || return 0
    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"
    if ! cmp -s "$SETUP_CONF" "$BACKUP_DIR/adguard-setup.conf"; then
        install -m 600 "$SETUP_CONF" "$BACKUP_DIR/adguard-setup.conf"
        echo "Systemeinstellungen (adguard-setup) gesichert."
    fi
}

# ---------------------------------------------------------------- Anzeige / Auswahl

# "AdGuardHome-2026-10-18_033000.yaml" -> "18.10.2026 03:30"
pretty_date() {
    local n="${1##*AdGuardHome-}"
    n="${n%.yaml}"
    echo "${n:8:2}.${n:5:2}.${n:0:4} ${n:11:2}:${n:13:2}"
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
    [[ -f $BACKUP_DIR/adguard-setup.conf ]] && echo "  + Systemeinstellungen (adguard-setup)"
    return 0
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

# ---------------------------------------------------------------- Wiederherstellen

restore() {
    choose_backup || return 0
    restore_file "$CHOSEN" "$(pretty_date "$CHOSEN")" || true
}

# restore_file <datei> <anzeigename> [--yes] – spielt eine Konfiguration ein.
# Rückgabe 0 = AdGuard läuft mit der neuen Konfiguration.
restore_file() {
    local file="$1" a
    if [[ ${3:-} != --yes ]]; then
        echo "Wiederherstellen: $2"
        read -rp "AdGuard wird kurz neu gestartet. Fortfahren? [j/N]: " a
        [[ ${a,,} == j* ]] || { echo "Abgebrochen."; return 0; }
    fi

    if ! grep -q '^dns:' "$file"; then
        err "Das sieht nicht nach einer AdGuard-Konfiguration aus – abgebrochen."
        return 1
    fi

    # Aktuellen Stand vorher sichern, damit man auch zurück kann
    backup_now >/dev/null || true

    systemctl stop "$AGH_SERVICE" || true
    install -m 600 "$file" "$AGH_CONF"
    systemctl start "$AGH_SERVICE" || true
    sleep 3
    if systemctl is-active --quiet "$AGH_SERVICE"; then
        info "Wiederhergestellt. AdGuard läuft."
        return 0
    fi

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
    return 1
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
        echo "$NAME|${LABEL:-ohne Namen} ($FSTYPE, $SIZE)"
    done < <(lsblk -Ppno NAME,PKNAME,TYPE,FSTYPE,SIZE,LABEL)
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
        [[ ${1:-} == leise ]] || echo "USB-Stick ausgehängt – er kann stecken bleiben oder gefahrlos abgezogen werden."
    else
        warn "USB-Stick konnte nicht ausgehängt werden – vor dem Abziehen: sudo umount $MNT"
    fi
}

# Fragt nach, wenn mehrere Sticks stecken; setzt USB_DEV
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
    if ! mount_dev "$USB_DEV"; then
        err "USB-Stick konnte nicht eingebunden werden."
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
        warn "Noch keine Sicherungen vorhanden – zuerst (s) jetzt sichern."
        return 0
    fi
    local sel files=()
    read -rp "Nummer der Version oder (a) für alle: " sel
    if [[ ${sel,,} == a* ]]; then
        files=("${BACKUPS[@]}")
    elif [[ $sel =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#BACKUPS[@]} )); then
        files=("${BACKUPS[$((sel - 1))]}")
    else
        warn "Ungültige Auswahl."
        return 0
    fi
    [[ -f $BACKUP_DIR/adguard-setup.conf ]] && files+=("$BACKUP_DIR/adguard-setup.conf")

    mount_usb || return 0
    if copy_into_usb_dir "${files[@]}"; then
        info "Auf den USB-Stick kopiert (Ordner $USB_DIR_NAME)."
        echo "Bleibt der Stick stecken, wird jede neue Sicherung automatisch mit draufkopiert."
    else
        err "Kopieren fehlgeschlagen (Stick voll oder schreibgeschützt?)."
    fi
    umount_dev
}

restore_from_usb() {
    local files f nr i=1 chosen tmp desc
    mount_usb || return 0
    # Gesucht wird im Ordner AdGuard-Backup/ und direkt im Hauptverzeichnis des Sticks
    mapfile -t files < <(ls -1t "$MNT/$USB_DIR_NAME"/*.yaml "$MNT"/AdGuardHome*.yaml 2>/dev/null || true)
    if (( ${#files[@]} == 0 )); then
        warn "Keine Sicherungen auf dem Stick gefunden (erwartet im Ordner $USB_DIR_NAME/)."
        umount_dev
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
        umount_dev
        return 0
    fi
    chosen="${files[$((nr - 1))]}"
    desc="$(describe_file "$chosen") vom USB-Stick"

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
# ersten Kopieren mit (u)). Ohne Rückfragen.
auto_copy_to_usb() {
    local newest="$1" p dir
    while IFS= read -r p; do
        mount_dev "${p%%|*}" || continue
        dir="$MNT/$USB_DIR_NAME"
        if [[ -d $dir ]]; then
            if [[ -n $newest && ! -f $dir/$(basename "$newest") ]]; then
                if copy_into_usb_dir "$newest"; then
                    echo "Auch auf USB-Stick kopiert: ${p#*|}"
                    # Nur eigene Sicherungen aufräumen, selbst abgelegte Dateien bleiben
                    ls -1t "$dir"/AdGuardHome-*.yaml 2>/dev/null \
                        | tail -n +$((USB_KEEP + 1)) | xargs -r rm -f
                else
                    echo "Kopieren auf USB-Stick fehlgeschlagen: ${p#*|}" >&2
                fi
            fi
            if [[ -f $BACKUP_DIR/adguard-setup.conf ]] \
               && ! cmp -s "$BACKUP_DIR/adguard-setup.conf" "$dir/adguard-setup.conf"; then
                copy_into_usb_dir "$BACKUP_DIR/adguard-setup.conf" \
                    && echo "Systemeinstellungen auf USB-Stick kopiert: ${p#*|}"
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
    local extra=""
    [[ -f $target/adguard-setup.conf ]] && extra=" + Systemeinstellungen"
    echo "Stand $(pretty_date "$best_name")$extra, USB-Stick $best" > "$target/source.txt"
}

# ---------------------------------------------------------------- main

if [[ $EUID -ne 0 ]]; then
    err "Bitte als root ausführen: sudo adguard-backup"
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
        [[ -d ${2:-} ]] || { err "Aufruf: adguard-backup --fetch-usb VERZEICHNIS"; exit 2; }
        fetch_from_usb "$2"
        exit $? ;;
    --restore-file)
        [[ -f ${2:-} ]] || { err "Aufruf: adguard-backup --restore-file DATEI"; exit 2; }
        restore_file "$2" "$2" --yes
        exit $? ;;
esac

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
