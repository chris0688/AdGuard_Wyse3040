# Changes

Newest version first. `sudo system-setup --update` also shows this list before
an update. Changes that only take effect on a **reinstall** (e.g. installer,
partitioning) are marked as such.
Deutsche Fassung: [CHANGELOG.de.md](CHANGELOG.de.md)

## v1.2.3

- Setup step password: the user is chosen from a numbered list (the logged-in
  user is preselected) instead of typing the name. The old password is not
  asked for (the setup runs with admin rights).

## v1.2.2

- Setup step administrator: after switching away from `adguard`, the setup now
  offers "leave unchanged" (default), "create another administrator" and
  "delete another administrator". This way the name can also be changed later.
  The user currently logged in is never deleted.

## v1.2.1

- Fixed: with a static IP, the login banner on the monitor showed `127.0.1.1`
  instead of the IP after boot (the address is set before the cable is
  connected, and the banner was not redrawn). The banner now names the network
  interface explicitly.
- Network step in the setup: with several wired network interfaces, the setup
  asks which one is connected to your home network (with IP and link status).
  The choice is stored locally only, not in the backup – on other hardware the
  interfaces have different names. With one interface there is no question.

## v1.2.0

- **New command names:** `adguard-setup` is now **`system-setup`**,
  `adguard-backup` is now **`system-backup`** (the old names sounded like
  AdGuard Home itself). The old commands no longer exist after the update.
- The update converts everything automatically: settings, region, backups,
  reboot schedule, services and paths (`/etc/system-setup.conf`,
  `/var/backups/system-backup` …). The folder `AdGuard-Backup/` on the USB
  stick stays; old sticks are still recognized.
- New in the setup: **your own administrator** instead of the publicly known
  user `adguard` (optional, default no). The next time you run the setup as
  the new user, `adguard` can be deleted.
- New: `sudo system-setup --update VERSION` updates to a specific version.
  Releases can require a minimum version (`MIN_UPDATE_FROM`); devices that are
  too old are then refused before anything is changed.
- After the update, the welcome screen asks you to run `sudo system-setup`
  (new question about the administrator).

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
- Fixed: the keyboard on the device was always US layout (package
  `console-setup` was missing). New installations use the layout from the boot
  menu; existing devices without a keyboard setting get the region's layout on
  update (German: `de`).
- The README is now in English, the German version is in `README.de.md`.
- Deutsch: Neu ist die **Mehrsprachigkeit**. Sprache und Land werden bei einer
  Neuinstallation im Bootmenü gewählt. Bestehende Geräte bleiben nach dem
  Update deutsch und bekommen an der Konsole das deutsche Tastaturlayout (war
  bisher US). Die README ist jetzt Englisch, die deutsche Fassung steht in
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
