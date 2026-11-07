# Changes

Newest version first. `sudo adguard-setup --update` also shows this list before
an update. Changes that only take effect on a **reinstall** (e.g. installer,
partitioning) are marked as such.
Deutsche Fassung: [CHANGELOG.de.md](CHANGELOG.de.md)

## v1.1.0

- New: **multilingual**. Language and country are chosen in the boot menu
  (English, German for Germany/Austria/Switzerland); English is preselected
  (reinstall only).
- All texts (menus, messages, login banner, `status`) come from language files
  (`lang/`); date and number format and time servers come from the region
  (`region/`). More languages and countries can be added without code changes.
- Existing devices stay German after the update (the region is detected from
  the system locale).
- The reboot step in the setup shows the device's time and time zone.
- The README is now in English, the German version is in `README.de.md`.
- Deutsch: Neu ist die **Mehrsprachigkeit**. Sprache und Land werden bei einer
  Neuinstallation im Bootmenü gewählt. Bestehende Geräte bleiben nach dem
  Update deutsch. Die README ist jetzt Englisch, die deutsche Fassung steht in
  `README.de.md`. Künftige Änderungslisten erscheinen auf deutschen Geräten
  wieder auf Deutsch.

## v1.0.1

- Login banner and `status` show the AdGuard address with the port chosen in
  the setup wizard (port 80 without, as before).
- `status` points out when this port is not open in the firewall and shows the
  command to open it.

## v1.0.0

- First stable version (German only). Same content as v0.9.2, fully tested on
  the Dell Wyse 3040: installation, basic setup, backup and restore (also via
  USB stick), reboot schedule, project update.

## v0.9.2

- Fixed: `adguard-setup --update` reported "tmp ist nicht gesetzt" at the end
  and left the download folder in `/tmp`. The message appears one last time
  when updating to this version.
- Welcome screen: the notice "The setup has new settings" is now more visible
  at the very bottom, right above the prompt, with a red "[!] NEW".

## v0.9.1

- New: `sudo adguard-setup --version` shows the installed project version.

## v0.9.0

- New: **project update** with `sudo adguard-setup --update`. It checks the
  latest release on GitHub, shows the changes, creates a backup and installs
  the new version. AdGuard Home itself is not changed.
- Port 3000 (AdGuard setup wizard) is only opened while AdGuard is not set up.
  A closed port therefore stays closed after an update.
- `adguard-setup.conf` now contains a format version (`CONF_VERSION`).
- If an update adds a new question to the setup, the welcome screen asks you
  to run `sudo adguard-setup` again.
- Fixed: when running `adguard-setup` again, the reboot step always proposed
  "weekly, Sunday" instead of the configured schedule. Enter now keeps the
  existing schedule.

## v0.8.4

- USB stick: no more messages in open terminals; the info is shown on the login
  screen, in `status` and in the log (`journalctl -t adguard-usb`).

## v0.8.3

- Backup menu: versions are numbered only in the selection step, with
  "0) back"; same scheme when selecting the USB stick.
- Login screen: USB stick line inside the box.
- First boot waits for internet and shows "waiting for internet" instead of
  "failed" (reinstall only).

## v0.8.2

- Plugged-in USB sticks are shown on the login screen and in `status`
  (free/used, number of backups).

## v0.8.1

- "Back up now" offers a backup even without changes.

## v0.8

- Simpler default password: `adguard` (reinstall only).
- Always install via network cable, never via Wi-Fi (reinstall only).

## v0.1 – v0.7

- Test phase: automatic installation, basic setup, backups with USB stick,
  login banner, system summary, watchdog, time synchronization.
