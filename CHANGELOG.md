# Änderungen

Neueste Version oben. Diese Liste zeigt auch `sudo adguard-setup --update` vor
einem Update an. Änderungen, die nur bei einer **Neuinstallation** wirken (z.B.
Installer, Partitionierung), sind entsprechend gekennzeichnet.

## v0.9.2

- Fehler behoben: `adguard-setup --update` meldete am Ende „tmp ist nicht
  gesetzt“ und ließ den Download-Ordner in `/tmp` liegen. Die Meldung kommt
  beim Update auf diese Version noch ein letztes Mal.

## v0.9.1

- Neu: `sudo adguard-setup --version` zeigt die installierte Projektversion.

## v0.9.0

- Neu: **Projekt-Update** mit `sudo adguard-setup --update`. Es prüft das neueste
  Release auf GitHub, zeigt die Änderungen, legt ein Backup an und spielt die
  neue Version ein. AdGuard Home selbst wird dabei nicht verändert.
- Port 3000 (AdGuard-Einrichtungsassistent) wird nur noch geöffnet, solange
  AdGuard nicht eingerichtet ist. Ein geschlossener Port bleibt so auch nach
  einem Update geschlossen.
- `adguard-setup.conf` enthält jetzt eine Formatversion (`CONF_VERSION`).
- Kommt nach einem Update eine neue Frage ins Setup, weist die Begrüßung darauf
  hin, `sudo adguard-setup` erneut auszuführen.
- Fehler behoben: Beim erneuten Ausführen von `adguard-setup` schlug der
  Neustart-Schritt immer „wöchentlich, Sonntag“ vor statt des eingerichteten
  Plans. Jetzt übernimmt Enter den bisherigen Plan.

## v0.8.4

- USB-Stick: keine Meldungen mehr in offenen Terminals; die Info steht im
  Anmeldebildschirm, in `status` und im Protokoll (`journalctl -t adguard-usb`).

## v0.8.3

- Backup-Menü: Versionen werden erst im Auswahlschritt nummeriert, mit
  „0) zurück“; gleiches Schema bei der Auswahl des USB-Sticks.
- Anmeldebildschirm: USB-Stick-Zeile im Kasten.
- Erster Start wartet auf Internet und zeigt „Warte auf Internet“ statt
  „fehlgeschlagen“ (nur bei Neuinstallation).

## v0.8.2

- Anzeige eingesteckter USB-Sticks im Anmeldebildschirm und in `status`
  (frei/belegt, Anzahl Backups).

## v0.8.1

- „Jetzt sichern“ bietet auch ohne Änderungen eine Sicherung an.

## v0.8

- Standardpasswort vereinfacht: `adguard` (nur bei Neuinstallation).
- Installation immer per Netzwerkkabel, nie per WLAN (nur bei Neuinstallation).

## v0.1 – v0.7

- Testphase: automatische Installation, Grundeinrichtung, Backups mit USB-Stick,
  Login-Banner, Systemübersicht, Watchdog, Zeitsynchronisation.
