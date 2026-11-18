#!/usr/bin/env bash
# migrate.sh – einmalige Umstellungen älterer Installationen (von install.sh
# aufgerufen, vor allem anderen). Jeder Schritt prüft selbst, ob es noch etwas
# umzustellen gibt; auf aktuellen Geräten passiert nichts.
#
# Entfernen: Ein Block darf erst raus, wenn MIN_UPDATE_FROM (im Repo-Hauptordner)
# mindestens die Version nennt, die im Block steht. Dann lehnt das Update ältere
# Geräte ab, bevor es etwas ändert. ACHTUNG: Geräte bis v1.1 kennen
# MIN_UPDATE_FROM noch nicht – für sie gilt dann nur Neuinstallation + Backup.
set -euo pipefail

# Nur für Tests: alle Pfade unter einem anderen Wurzelordner (auf dem Gerät leer)
R="${MIGRATE_ROOT:-}"
SYSD="$R/etc/systemd/system"

# ------------------------------------------------------------ v1.1 -> v1.2
# Umbenennung adguard-* -> system-* (Befehle, Dienste, Pfade). Der USB-Ordner
# AdGuard-Backup/ bleibt; den Projektordner /opt/adguard-setup zieht schon
# install.sh um (das Skript läuft von dort).
migrate_v1_2() {
    local f old new was_enabled=0

    # Alte Dienste abschalten, sonst laufen sie doppelt. Besonders wichtig:
    # adguard-firstboot prüft die alte bootstrap.done und würde nach dem Umzug
    # der Statusdateien die Ersteinrichtung erneut starten.
    for f in adguard-backup.timer adguard-backup.service adguard-banner.path \
             adguard-banner.service adguard-firstboot.service; do
        if [[ -f $SYSD/$f ]]; then
            systemctl disable --now "$f" >/dev/null 2>&1 || true
            rm -f "$SYSD/$f"
        fi
    done

    # Regelmäßiger Neustart (von adguard-setup erzeugt): gleicher Zeitplan, neuer Name
    if [[ -f $SYSD/adguard-reboot.timer ]]; then
        if systemctl is-enabled --quiet adguard-reboot.timer 2>/dev/null; then was_enabled=1; fi
        systemctl disable --now adguard-reboot.timer >/dev/null 2>&1 || true
        for f in timer service; do
            old="$SYSD/adguard-reboot.$f"
            [[ -f $old ]] || continue
            sed 's/adguard-setup/system-setup/g' "$old" > "$SYSD/system-reboot.$f"
            rm -f "$old"
        done
        systemctl daemon-reload
        if (( was_enabled )); then
            systemctl enable --now system-reboot.timer >/dev/null 2>&1 || true
        fi
        echo "==> Migrated: reboot schedule -> system-reboot.timer"
    fi
    if [[ -f $R/etc/apt/apt.conf.d/53adguard-reboot-time ]]; then
        mv "$R/etc/apt/apt.conf.d/53adguard-reboot-time" "$R/etc/apt/apt.conf.d/53system-reboot-time"
    fi

    # Cockpit-Hinweise sind per dpkg-divert in den alten Statusordner verschoben.
    # Zurücknehmen (die Datei kommt an ihren Platz zurück); system-banner leitet
    # sie danach in den neuen Ordner um.
    for f in /etc/issue.d/cockpit.issue /etc/motd.d/cockpit; do
        if dpkg-divert --list "$f" 2>/dev/null | grep -q '/var/lib/adguard-setup/'; then
            dpkg-divert --local --rename --remove "$f" >/dev/null
        fi
    done

    # Statusdateien (setup.done, bootstrap.done)
    if [[ -d $R/var/lib/adguard-setup ]]; then
        mkdir -p "$R/var/lib/system-setup"
        cp -a "$R/var/lib/adguard-setup/." "$R/var/lib/system-setup/"
        rm -rf "$R/var/lib/adguard-setup"
        echo "==> Migrated: /var/lib/adguard-setup -> /var/lib/system-setup"
    fi

    # Einstellungen und Region (vor set-region.sh, das die Region liest)
    for f in setup region; do
        old="$R/etc/adguard-$f.conf"
        new="$R/etc/system-$f.conf"
        if [[ -f $old ]]; then
            [[ -f $new ]] || mv "$old" "$new"
            rm -f "$old"
            echo "==> Migrated: /etc/adguard-$f.conf -> /etc/system-$f.conf"
        fi
    done

    # Backups (die Einstellungsdatei darin heißt jetzt system-setup.conf)
    if [[ -d $R/var/backups/adguard ]]; then
        mkdir -p "$R/var/backups/system-backup"
        chmod 700 "$R/var/backups/system-backup"
        cp -a "$R/var/backups/adguard/." "$R/var/backups/system-backup/"
        rm -rf "$R/var/backups/adguard"
        echo "==> Migrated: /var/backups/adguard -> /var/backups/system-backup"
    fi
    old="$R/var/backups/system-backup/adguard-setup.conf"
    new="$R/var/backups/system-backup/system-setup.conf"
    if [[ -f $old ]]; then
        [[ -f $new ]] || mv "$old" "$new"
        rm -f "$old"
    fi

    # Alte Befehle, Texte und Konfigurationsdateien mit altem Namen
    rm -f "$R/usr/local/sbin/adguard-setup" "$R/usr/local/sbin/adguard-backup" \
          "$R/usr/local/sbin/adguard-banner" "$R/usr/local/sbin/adguard-usb"
    rm -rf "$R/usr/local/share/adguard"
    rm -f "$R/etc/profile.d/adguard-setup.sh" \
          "$R/etc/udev/rules.d/90-adguard-usb.rules" \
          "$R/etc/systemd/journald.conf.d/adguard.conf" \
          "$R/etc/systemd/logind.conf.d/adguard.conf" \
          "$R/etc/systemd/timesyncd.conf.d/adguard.conf" \
          "$R/etc/sudoers.d/adguard-status" \
          "$R/etc/issue.d/50-adguard-status.issue" \
          "$R/etc/issue.d/60-adguard-usb.issue"
    systemctl daemon-reload
}

migrate_v1_2
