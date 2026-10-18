#!/usr/bin/env bash
# adguard-backup – Versionen der AdGuard-Einstellungen sichern und wiederherstellen.
#
# Auf dem Gerät: /usr/local/sbin/adguard-backup
#
#   sudo adguard-backup          Menü: Versionen anzeigen, sichern, wiederherstellen,
#                                Version zum Herunterladen bereitlegen
#   adguard-backup --auto        (täglich per Timer) sichert nur, wenn sich die
#                                Einstellungen seit der letzten Sicherung geändert haben
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
    echo "Wiederherstellen: $(pretty_date "$CHOSEN")"
    read -rp "AdGuard wird kurz neu gestartet. Fortfahren? [j/N]: " a
    [[ ${a,,} == j* ]] || { echo "Abgebrochen."; return 0; }

    # Aktuellen Stand vorher sichern, damit man auch zurück kann
    backup_now >/dev/null || true

    systemctl stop "$AGH_SERVICE" || true
    install -m 600 "$CHOSEN" "$AGH_CONF"
    systemctl start "$AGH_SERVICE" || true
    sleep 3
    if systemctl is-active --quiet "$AGH_SERVICE"; then
        info "Wiederhergestellt. AdGuard läuft."
    else
        err "AdGuard startet mit dieser Version nicht – stelle vorherigen Stand wieder her."
        systemctl stop "$AGH_SERVICE" || true
        install -m 600 "$(list_backups | head -n1)" "$AGH_CONF"
        systemctl start "$AGH_SERVICE" || true
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

# ---------------------------------------------------------------- main

if [[ $EUID -ne 0 ]]; then
    err "Bitte als root ausführen: sudo adguard-backup"
    exit 1
fi

if [[ ${1:-} == --auto ]]; then
    backup_now || true
    exit 0
fi

while true; do
    echo
    info "AdGuard-Einstellungen – Sicherungen ($BACKUP_DIR, es werden die letzten $KEEP behalten)"
    show_list
    echo
    echo "  (s) jetzt sichern   (w) Version wiederherstellen   (d) Version zum Download bereitlegen   (q) beenden"
    read -rp "Auswahl: " choice
    case "${choice,,}" in
        s) backup_now || true ;;
        w) (( ${#BACKUPS[@]} )) && restore ;;
        d) (( ${#BACKUPS[@]} )) && export_for_download ;;
        q|"") exit 0 ;;
        *) warn "Unbekannte Auswahl." ;;
    esac
done
