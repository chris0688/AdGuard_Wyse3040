# AdGuard Home auf Dell Wyse 3040

Ein ausgedienter Dell Wyse 3040 Thin Client wird zum stromsparenden, **headless**
laufenden DNS-Werbeblocker für das ganze Heimnetz, mit
[AdGuard Home](https://github.com/AdguardTeam/AdGuardHome) auf Debian 13.

Die Installation läuft **vollautomatisch von einem USB-Stick**: Stick einstecken,
Eintrag im Bootmenü wählen, warten. Danach wird AdGuard bequem im Browser
eingerichtet. Linux-Kenntnisse sind dafür nicht nötig.

Gebaut für den Wyse 3040, funktioniert aber auch auf
[anderer Hardware](#andere-hardware) (praktisch jeder 64-Bit-PC mit UEFI).

---

## Inhalt

- [Schnellstart](#schnellstart)
- [Sicherheit](#sicherheit)
- [Was eingerichtet wird](#was-eingerichtet-wird)
- [So funktioniert die Installation](#so-funktioniert-die-installation)
- [Repository-Aufbau](#repository-aufbau)
- [USB-Stick (ISO) bauen](#usb-stick-iso-bauen)
- [Alternative: Debian selbst installieren](#alternative-debian-selbst-installieren)
- [Grundeinrichtung: `adguard-setup`](#grundeinrichtung-adguard-setup)
- [Konfiguration ändern](#konfiguration-ändern)
- [Wartung & Troubleshooting](#wartung--troubleshooting)
- [Tipps für den Betrieb](#tipps-für-den-betrieb)
- [Hardware & BIOS](#hardware--bios)
- [Andere Hardware](#andere-hardware)
- [Lizenz & Rechtliches](#lizenz--rechtliches)

---

## Schnellstart

**Du brauchst:** Dell Wyse 3040 mit Netzwerkkabel (Internet nötig), USB-Stick
(≥ 1 GB), Tastatur und Monitor nur für die Installation.

1. **ISO herunterladen** – die neueste `adguard-wyse3040-debian-13.x.iso` unter
   [**Releases**](../../releases/latest) (oder [selbst bauen](#usb-stick-iso-bauen)) –
   und auf einen USB-Stick bringen:
   - **[Ventoy](https://www.ventoy.net):** ISO einfach auf den Stick kopieren.
   - **[Rufus](https://rufus.ie):** ISO auswählen, bei Nachfrage **DD-Modus** wählen.
   - **[balenaEtcher](https://etcher.balena.io):** ISO auswählen, schreiben.
2. **Vom Stick starten:** Stick in den Wyse stecken, einschalten und dabei
   **F12** drücken → USB-Stick auswählen. Bei Ventoy im Menü die ISO wählen,
   dann *Boot in normal mode*.
3. **Im Bootmenü** den Eintrag
   `AdGuard Home - automatisch installieren` auswählen.
   ⚠️ **Die interne eMMC/Festplatte wird dabei ohne weitere Rückfrage gelöscht.**
4. **Warten** (ca. 15–30 Minuten). Am Ende **schaltet sich der Wyse von selbst aus**.
5. **USB-Stick abziehen** und den Wyse wieder einschalten. Beim ersten Start
   werden AdGuard Home und alle Einstellungen installiert (ca. 5 Minuten). Der
   Fortschritt steht am Bildschirm.
6. **Anmelden** (am Gerät oder per SSH: `ssh adguard@<IP>`; die IP steht auf dem
   Bildschirm). Benutzer `adguard`, Passwort `AdGuardRootPW1`. Danach geht es
   automatisch weiter:
   - Ein **neues Passwort** muss gesetzt werden (siehe [Sicherheit](#sicherheit)).
   - Die **Grundeinrichtung** startet: Hostname, **regelmäßiger Neustart**,
     optional die Web-Verwaltung Cockpit, **DHCP oder feste IP**
     (siehe [`adguard-setup`](#grundeinrichtung-adguard-setup)).
7. Im Browser **`http://<IP>:3000`** öffnen und den AdGuard-Einrichtungsassistenten
   durchklicken (Admin-Benutzer mit **sicherem Passwort** anlegen, Webinterface auf
   Port 80, DNS auf Port 53).
8. Im **Router** die IP des Wyse als DNS-Server eintragen. Fertig. 🎉

## Sicherheit

> [!IMPORTANT]
> Das Standardpasswort `AdGuardRootPW1` steht öffentlich in dieser Anleitung.
> **Es muss aus Sicherheitsgründen unbedingt geändert werden.** Das System
> erzwingt das beim ersten Login. Bis dahin zeigt der Login-Bildschirm am Gerät
> eine rote Warnung mit den Zugangsdaten, denn AdGuard lässt sich auch ohne
> Linux-Login im Browser einrichten, und man könnte das Passwort sonst vergessen.

- Der Benutzer `adguard` ist der Administrator (über `sudo`). Ein direkter
  **root-Login ist deaktiviert**, es gibt also kein separates root-Passwort.
- Passwort später ändern: `passwd` (eigenes) oder `sudo adguard-setup`.
- Für den **AdGuard-Admin** im Webinterface ebenfalls ein eigenes, sicheres
  Passwort wählen. Es ist unabhängig vom Linux-Passwort.
- **Niemals** im Router Ports (53, 80, 443, 22, 9090) aus dem Internet auf den
  Wyse weiterleiten. Der DNS-Server ist nur für das eigene Heimnetz gedacht.
- SSH ist mit fail2ban gegen Passwort-Raten geschützt.

## Was eingerichtet wird

| Bereich | Beschreibung | Datei(en) |
|---------|--------------|-----------|
| Basis | Debian 13 „Trixie“ minimal, ohne Desktop, mit SSH-Server. Benutzer `adguard` mit sudo-Rechten, kein root-Login. | `installer/preseed.cfg` |
| Partitionierung | erste interne Platte (eMMC, NVMe oder SATA; USB wird übersprungen): EFI + eine ext4-Partition (`noatime`), **keine Swap-Partition** | `installer/preseed.cfg` |
| AdGuard Home | aktuelle Version nach `/opt/AdGuardHome`, systemd-Dienst `AdGuardHome` | `scripts/bootstrap.sh` |
| Login-Banner (vor Login) | farbiges Banner mit Hostname, IP, AdGuard-Adresse, ggf. Einrichtungsassistent und Web-Konsole; **rote Warnung, solange das Standardpasswort aktiv ist**; zeigt während der Ersteinrichtung den Fortschritt | `scripts/adguard-banner.sh`, `rootfs/etc/systemd/system/adguard-banner.*` |
| Begrüßung (nach Login) | AdGuard-Logo, Gerät, Systemstatus mit RAM-/Speicher-Balken, Temperatur, AdGuard-Status, Web-Konsole, Auto-Update (aktiv + letzter Lauf), Auto-Neustart | `rootfs/etc/update-motd.d/99-custom-motd` |
| Logs begrenzen | systemd-Journal max. 200 MB / 1 Monat, Älteres wird automatisch gelöscht | `rootfs/etc/systemd/journald.conf.d/adguard.conf` |
| Automatische Updates | `unattended-upgrades` (Debian + Security), entfernt alte Kernel, **Neustart zur eingestellten Uhrzeit** (Standard 04:00) falls nötig | `rootfs/etc/apt/apt.conf.d/20auto-upgrades`, `52unattended-upgrades-local` |
| Regelmäßiger Neustart | täglich oder wöchentlich zur gleichen Uhrzeit (empfohlen), wird in `adguard-setup` abgefragt | `scripts/adguard-setup.sh` |
| Watchdog | startet das Gerät automatisch neu, falls sich das System komplett aufhängt (sofern ein Watchdog-Chip vorhanden ist, beim Wyse 3040 ja) | `rootfs/etc/systemd/system.conf.d/watchdog.conf` |
| Paket-Cache | wird alle 7 Tage aufgeräumt | `rootfs/etc/apt/apt.conf.d/70autoclean` |
| Uhrzeit | automatisch per NTP von `de.pool.ntp.org` (Rückfall: Debian-Pool); die Begrüßung warnt, falls nicht synchronisiert | `rootfs/etc/systemd/timesyncd.conf.d/adguard.conf` |
| Firewall (ufw) | offen: 22/tcp (SSH), 53 (DNS), 80/tcp, 443, 3000/tcp (Setup-Assistent) | `scripts/install.sh` |
| fail2ban | SSH: 5 Fehlversuche in 10 Min. → 15 Min. Sperre, Wiederholungstäter länger (bis 1 Woche) | `rootfs/etc/fail2ban/jail.local` |
| zram-Swap | komprimierter Swap im RAM (50 %), schont die eMMC | `rootfs/etc/default/zramswap` |
| Power-Taste | kurzer Druck fährt sauber herunter | `rootfs/etc/systemd/logind.conf.d/adguard.conf` |
| Wyse-Fix (**nur Wyse 3040**) | DMA-Treiber `dw_dmac` gesperrt: Ohne den Fix hängt der Wyse 3040 beim Herunterfahren/Neustarten und schaltet sich nicht aus. Wird nur eingespielt, wenn das Gerät erkannt wird. | `hardware/wyse3040/etc/modprobe.d/wyse-fix.conf` |
| Grundeinrichtung | Hostname, Neustart-Plan, optional Cockpit, DHCP/feste IP; startet automatisch beim ersten Login | `scripts/adguard-setup.sh` → `sudo adguard-setup`, `rootfs/etc/profile.d/adguard-setup.sh` |

Unter `rootfs/` liegen nur **eigene Dateien bzw. Drop-ins** (`*.conf.d/`,
`*-local`), nie komplette Kopien von Paketdateien. So bleiben Debian-Updates
konfliktfrei, und es ist sofort sichtbar, was angepasst wurde.

## So funktioniert die Installation

```
 USB-Stick (Debian-Netinstall + Repo)
 │
 ├─ Debian-Installer liest installer/preseed.cfg
 │    → Sprache, Netzwerk (DHCP), Benutzer, interne Platte partitionieren,
 │      Minimalsystem
 │    → late_command: Repo nach /opt/adguard-setup kopieren,
 │                    Wyse-Fix aktivieren (nur Wyse 3040),
 │                    Ersteinrichtungs-Dienst einschalten
 │    → Gerät schaltet sich aus
 │
 └─ Erster Start von der internen Platte
      adguard-firstboot.service → scripts/bootstrap.sh
        → Pakete installieren (ufw, fail2ban, unattended-upgrades, zram,
          Microcode passend zu Intel/AMD …)
        → AdGuard Home herunterladen und als Dienst einrichten
        → scripts/install.sh: rootfs/ einspielen, Gerät erkennen und
          ggf. hardware/<gerät>/ einspielen, Firewall, Dienste
        → /var/lib/adguard-setup/bootstrap.done (Dienst läuft danach nie wieder)
```

Schlägt etwas fehl (z.B. kein Internet), versucht der Dienst es alle 30 Sekunden
erneut; die Login-Anzeige zeigt dann einen Hinweis.

## Repository-Aufbau

```
.
├── .github/workflows/build-iso.yml      # GitHub baut die ISO bei neuem Tag
├── installer/
│   ├── build-iso.sh                     # baut den USB-Stick (ISO)
│   ├── preseed.cfg                      # Antworten für den Debian-Installer
│   ├── grub.cfg                         # Bootmenü des Sticks
│   └── adguard-firstboot.service        # startet bootstrap.sh beim 1. Boot
├── scripts/
│   ├── bootstrap.sh                     # Pakete + AdGuard + install.sh
│   ├── install.sh                       # spielt rootfs/ ein (auch einzeln nutzbar)
│   ├── hardware.sh                      # Geräteerkennung
│   ├── adguard-setup.sh                 # Hostname / Passwort / Neustart / Cockpit / IP
│   └── adguard-banner.sh                # erzeugt den Login-Banner (/etc/issue)
├── rootfs/                              # Dateien 1:1 wie auf dem System (alle Geräte)
│   └── etc/ ...                         #   z.B. rootfs/etc/fail2ban/jail.local
└── hardware/                            # nur für erkannte Geräte
    └── wyse3040/etc/ ...                #   Wyse-Fix
```

## USB-Stick (ISO) bauen

`installer/build-iso.sh` lädt die **aktuelle offizielle Debian-13-Netinstall-ISO**,
prüft deren Prüfsumme und baut Bootmenü, Antwortdatei und dieses Repo ein. Es
braucht ein Linux mit `xorriso` und `curl`. Unter Windows geht das so:

**Mit WSL** (Windows-Subsystem für Linux, z.B. Debian/Ubuntu):

```bash
sudo apt install xorriso curl
cd /mnt/c/Users/<name>/Documents/git/AdGuard_Wyse3040
./installer/build-iso.sh
```

**Mit Docker Desktop** (PowerShell, im Repo-Ordner):

```powershell
docker run --rm -v "${PWD}:/w" -w /w debian:13 bash -c "apt-get update -qq && apt-get install -y -qq xorriso curl && ./installer/build-iso.sh"
```

Ergebnis: `build/adguard-wyse3040-debian-13.x.iso` (ca. 800 MB). Der Ordner
`build/` wird nicht eingecheckt.

> Die ISO nach jeder Änderung am Repo neu bauen. Sie enthält immer den Stand,
> der beim Bauen im Ordner lag.

### Automatisch über GitHub (Release)

GitHub baut die ISO selbst ([`.github/workflows/build-iso.yml`](.github/workflows/build-iso.yml)).
Für eine neue Version einen Tag setzen und pushen:

```bash
git tag v1.1
git push origin v1.1
```

Nach ca. 5 Minuten liegt die ISO unter **Releases**. Ein Test-Build ohne Release
geht über *Actions → ISO bauen → Run workflow*.

Ein neuer Build lohnt sich nach Änderungen am Repo oder nach einer neuen
Debian-Unterversion (13.x). Die Pakete selbst werden bei der Installation ohnehin
aktuell aus dem Internet geladen.

## Alternative: Debian selbst installieren

Wer Debian 13 lieber selbst installiert (oder ein anderes Gerät nutzt, z.B. einen
Raspberry Pi):

1. Debian 13 minimal installieren: bei der Softwareauswahl nur
   **SSH-Server** und **Standard-Systemwerkzeuge** anhaken.
2. Danach auf dem Gerät:
   ```bash
   sudo apt install git
   git clone <repo-url> && cd AdGuard_Wyse3040
   sudo ./scripts/bootstrap.sh
   ```

## Grundeinrichtung: `adguard-setup`

Startet **automatisch beim ersten Login** und erinnert bei jedem weiteren Login,
bis es einmal durchgelaufen ist. Jederzeit erneut aufrufbar mit:

```bash
sudo adguard-setup
```

Jeder Schritt lässt sich überspringen:

| Schritt | Was passiert |
|---------|--------------|
| 1. Hostname | setzt den Hostnamen und passt `/etc/hosts` an (Standard: `adguard`) |
| 2. Passwort | ändert das Passwort eines Linux-Benutzers |
| 3. Neustart | **Uhrzeit** für Neustarts (Standard 04:00, gilt auch für Neustarts nach Updates) und **regelmäßiger Neustart** (empfohlen): täglich oder wöchentlich mit Wochentag (Standard Sonntag) |
| 4. Cockpit | installiert auf Wunsch die [Web-Verwaltung](#web-verwaltung-cockpit) |
| 5. Netzwerk | **DHCP behalten** oder **feste IP** mit Gateway und DNS vergeben. Erkennt `ifupdown` (Debian-Standard), `systemd-networkd` und NetworkManager. Wird nach einem Neustart aktiv. |

Hinweise zum Netzwerk:

- Ein DNS-Server braucht eine **gleichbleibende Adresse**: entweder hier eine
  feste IP vergeben oder im Router eine feste DHCP-Adresse für den Wyse
  reservieren und DHCP behalten.
- Als DNS für das Gerät **selbst** wird der Router bzw. ein externer Server
  eingetragen, nicht der eigene AdGuard. So funktionieren Updates auch dann, wenn
  AdGuard einmal nicht läuft.
- Bei SSH-Verbindung nach dem Neustart mit der **neuen** IP verbinden.

### Web-Verwaltung (Cockpit)

Optional über `adguard-setup` installierbar. [Cockpit](https://cockpit-project.org)
ist eine Weboberfläche für das Linux-System unter **`https://<IP>:9090`**
(Login mit dem Linux-Benutzer `adguard`):

- Terminal im Browser (SSH-Client überflüssig)
- Updates anzeigen und installieren
- Logs, Dienste, CPU/RAM-Verlauf, Neustart/Herunterfahren

Die Adresse steht nach der Installation auch im Login-Banner und in der
Begrüßung. Die Browser-Warnung zum Zertifikat beim ersten Aufruf ist normal
(selbst signiert).

## Konfiguration ändern

**Repo → Gerät:** Datei unter `rootfs/` ändern und das Repo auf das Gerät bringen
(`git pull` in einem Klon oder per `scp`), dann:

```bash
sudo ./scripts/install.sh
```

**Gerät → Repo:** Wurde direkt auf dem Gerät etwas geändert, die Datei mit `scp`
holen (Beispiel von Windows aus, im Repo-Ordner):

```powershell
scp adguard@<IP>:/etc/<pfad>/<datei> rootfs/etc/<pfad>/
```

**Welche Dateien wurden auf einem Gerät geändert?**

```bash
# Paket-Konfigdateien, die vom Auslieferungszustand abweichen (unabhängig vom Datum)
sudo dpkg --verify | grep ' c /etc'

# Wann wurde installiert?
ls -ld --time-style=full-iso /var/log/installer

# Alle Dateien in /etc mit Änderungszeit, chronologisch
sudo find /etc -type f -printf '%TY-%Tm-%Td %TH:%TM  %p\n' | sort

# Nur Dateien, die in einem Zeitfenster geändert wurden (Datum + Uhrzeit)
sudo find /etc -type f -newermt '2026-03-01 14:30' ! -newermt '2026-03-01 18:00'
```

## Wartung & Troubleshooting

| Aufgabe | Befehl |
|---------|--------|
| Ersteinrichtung verfolgen | `journalctl -fu adguard-firstboot` |
| Status AdGuard | `systemctl status AdGuardHome` |
| AdGuard neu starten | `sudo systemctl restart AdGuardHome` |
| AdGuard-Update | Webinterface oder `sudo /opt/AdGuardHome/AdGuardHome --update` |
| Firewall-Regeln | `sudo ufw status verbose` |
| Port 3000 schließen (nach Ersteinrichtung) | `sudo ufw delete allow 3000/tcp` |
| fail2ban-Status / IP entsperren | `sudo fail2ban-client status sshd` · `sudo fail2ban-client set sshd unbanip <IP>` |
| Speicherplatz | `df -h /` · `sudo du -xh / --max-depth=2 \| sort -h \| tail` |
| Journal-Größe | `journalctl --disk-usage` |
| Letzte Auto-Updates | `less /var/log/unattended-upgrades/unattended-upgrades.log` |
| Port 53 belegt? | `sudo ss -tulpn \| grep ':53'` |
| Uhrzeit / Zeitsync prüfen | `timedatectl` (erwartet: „System clock synchronized: yes“) |
| Neustart-Plan anzeigen / ändern | `systemctl list-timers adguard-reboot.timer` · `sudo adguard-setup` |
| Watchdog aktiv? | `sudo wdctl` |

Hinweis zum nächtlichen Neustart: Währenddessen (ca. 1 Minute) ist DNS im Netz
nicht erreichbar. Uhrzeit und Rhythmus lassen sich mit `sudo adguard-setup` ändern.

## Tipps für den Betrieb

- **AdGuard Home selbst aktualisieren:** Die automatischen Updates betreffen nur
  Debian, **nicht AdGuard Home**. Ist eine neue Version verfügbar, zeigt das
  AdGuard-Dashboard oben einen Hinweis; das Update ist dann ein Klick. Einfach ab
  und zu ins Dashboard schauen.
- **Abfrageprotokoll begrenzen:** AdGuard speichert standardmäßig alle
  DNS-Anfragen der letzten 90 Tage. Das kann auf Dauer über 1 GB werden, was auf
  der kleinen eMMC knapp wird. Empfehlung: in AdGuard unter
  *Einstellungen → Allgemeine Einstellungen → Protokoll* die Aufbewahrung auf
  **7 Tage** (oder 24 Stunden) stellen.

- **IPv6 beachten:** Viele Router (z.B. FritzBox) verteilen per IPv6 zusätzlich
  sich selbst als DNS-Server. Dann fragen Geräte am AdGuard vorbei. Abhilfe: im
  Router auch für IPv6 den Wyse als DNS eintragen oder die IPv6-DNS-Verteilung
  abschalten. Prüfen: Im AdGuard-Dashboard sollten alle Geräte auftauchen.
- **Regelmäßig ein Backup der AdGuard-Einstellungen machen**, vor allem nach
  größeren Änderungen. Das Webinterface hat dafür keine Funktion, aber alle
  Einstellungen (Filter, eigene Regeln, Clients, Admin-Zugang) stecken in einer
  einzigen Datei: `/opt/AdGuardHome/AdGuardHome.yaml`.

  **Sichern:**
  1. Auf dem Gerät (SSH oder Cockpit-Terminal) die Datei ins Home-Verzeichnis kopieren,
     da sie nur für root lesbar ist:
     ```bash
     sudo cp /opt/AdGuardHome/AdGuardHome.yaml ~/AdGuardHome-$(date +%F).yaml
     sudo chown $USER ~/AdGuardHome-*.yaml
     ```
  2. Auf den PC holen: mit [WinSCP](https://winscp.net) (grafisch, Anmeldung wie
     bei SSH) oder in PowerShell:
     ```powershell
     scp "adguard@<IP>:AdGuardHome-*.yaml" .
     ```

  **Wiederherstellen** (z.B. nach einer Neuinstallation): Den AdGuard-
  Einrichtungsassistenten **nicht** durchklicken, sondern die Datei aufs Gerät
  kopieren und dort:
  ```bash
  sudo systemctl stop AdGuardHome
  sudo cp ~/AdGuardHome-<datum>.yaml /opt/AdGuardHome/AdGuardHome.yaml
  sudo systemctl start AdGuardHome
  ```

  Die Datei enthält den (verschlüsselten) Admin-Zugang, also sicher aufbewahren.
- **Port 3000** wird nach dem Einrichtungsassistenten nicht mehr gebraucht:
  `sudo ufw delete allow 3000/tcp`.

## Hardware & BIOS

| Komponente | Dell Wyse 3040 |
|------------|----------------|
| CPU        | Intel Atom x5-Z8350, 4 Kerne, 1,44 GHz |
| RAM        | 2 GB DDR3L (verlötet) |
| Speicher   | 8 GB oder 16 GB eMMC (verlötet) |
| Netzwerk   | 1 GbE |
| Verbrauch  | ca. 3–5 W |
| Boot       | nur UEFI |

- **F2** beim Start: BIOS-Setup · **F12**: Bootmenü
- Standard-BIOS-Passwort: `Fireport`
- Empfohlen für Dauerbetrieb: *Power Management → AC Recovery = **Power On***,
  damit der Wyse nach einem Stromausfall von selbst wieder startet.
- Startet der Stick nicht: im BIOS *Secure Boot* deaktivieren und
  *USB Boot* aktivieren.

## Andere Hardware

Das Projekt ist nicht an den Wyse 3040 gebunden. Die USB-Installation läuft auf
praktisch jedem **64-Bit-PC (x86-64) mit UEFI**, z.B. andere Thin Clients
(Fujitsu Futro, HP t-Serie), Mini-PCs oder alte Laptops.

**Mindestens:** 1 GB RAM, 8 GB Speicher, Netzwerkkabel.

Was sich je nach Hardware anpasst:

| Was | Verhalten |
|-----|-----------|
| Zielfestplatte | erste interne Platte: eMMC → NVMe → SATA. USB-Laufwerke, Wechseldatenträger und SD-Karten werden übersprungen. ⚠️ Bei mehreren internen Platten wird die **erste** gelöscht. |
| Wyse-Fix | wird nur auf einem erkannten Wyse 3040 eingespielt ([`hardware/`](hardware/)) |
| Microcode | Intel oder AMD, je nach Prozessor |
| Watchdog | nutzt den vorhandenen Watchdog-Chip; ohne Chip passiert nichts |

**Nicht unterstützt** von der USB-Installation:

- **Alte PCs ohne UEFI** (nur Legacy-BIOS): Der Stick startet dort zwar, zeigt
  aber nur das normale Debian-Menü. Dann Debian manuell installieren und
  `bootstrap.sh` nutzen ([Alternative](#alternative-debian-selbst-installieren)).
- **Raspberry Pi / ARM:** Es gibt keine passende ISO. Debian oder Raspberry Pi
  OS installieren und `bootstrap.sh` nutzen. Das Script lädt automatisch die
  ARM-Version von AdGuard (ungetestet).

## Lizenz & Rechtliches

- Die Scripts und Konfigurationsdateien in diesem Repository stehen unter der
  [MIT-Lizenz](LICENSE).
- Die ISO basiert auf der **unveränderten offiziellen Debian-Netinstall-ISO**;
  hinzugefügt werden nur die Dateien dieses Repos. Debian ist freie Software und
  darf weitergegeben werden. Der Quellcode aller Debian-Pakete ist bei Debian
  verfügbar ([cdimage.debian.org](https://cdimage.debian.org/cdimage/release/),
  [snapshot.debian.org](https://snapshot.debian.org/)).
- **AdGuard Home ist nicht in der ISO enthalten.** Es wird bei der Installation
  direkt von den offiziellen AdGuard-Servern geladen und steht unter der
  [GPL-3.0](https://github.com/AdguardTeam/AdGuardHome/blob/master/LICENSE.txt).
- Dies ist ein privates Hobbyprojekt ohne Verbindung zu AdGuard Software Ltd.,
  Dell Technologies oder dem Debian-Projekt. Alle Marken gehören ihren
  jeweiligen Inhabern. Nutzung auf eigene Gefahr.
