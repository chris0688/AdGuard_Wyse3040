#!/bin/sh
# status – zeigt die Systemübersicht (wie nach dem Login) jederzeit erneut an.
# Auf dem Gerät: /usr/local/bin/status
#
# Läuft mit Admin-Rechten, damit Backups und AdGuard-Konfiguration gelesen
# werden können. Dafür ist kein Passwort nötig (/etc/sudoers.d/adguard-status),
# das Script zeigt nur an und ändert nichts.
exec sudo /etc/update-motd.d/99-custom-motd
