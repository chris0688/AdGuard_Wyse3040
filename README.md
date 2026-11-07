# AdGuard Home on Dell Wyse 3040

**English** · [Deutsch](README.de.md)

Turn a retired Dell Wyse 3040 thin client into a low-power, **headless**
DNS ad blocker for your whole home network, running
[AdGuard Home](https://github.com/AdguardTeam/AdGuardHome) on Debian 13.

Installation is **fully automatic from a USB stick**: plug in the stick, pick
an entry in the boot menu, wait. Afterwards AdGuard is set up comfortably in
the browser. No Linux knowledge required.

Built for the Wyse 3040, but also works on
[other hardware](#other-hardware) (practically any 64-bit PC with UEFI).
Language and country are chosen in the boot menu (English, German, more can be
[added](#languages-and-regions)).

---

## Contents

- [Quick start](#quick-start)
- [Security](#security)
- [What gets set up](#what-gets-set-up)
- [How the installation works](#how-the-installation-works)
- [Repository layout](#repository-layout)
- [Building the USB stick (ISO)](#building-the-usb-stick-iso)
- [Alternative: install Debian yourself](#alternative-install-debian-yourself)
- [Basic setup: `adguard-setup`](#basic-setup-adguard-setup)
- [Updating the project](#updating-the-project)
- [Changing the configuration](#changing-the-configuration)
- [Setting up a new device from a backup](#setting-up-a-new-device-from-a-backup)
- [Maintenance & troubleshooting](#maintenance--troubleshooting)
- [Tips for daily use](#tips-for-daily-use)
- [Hardware & BIOS](#hardware--bios)
- [Other hardware](#other-hardware)
- [Languages and regions](#languages-and-regions)
- [License & legal](#license--legal)

---

## Quick start

**You need:** a Dell Wyse 3040 with a network cable (internet required), a USB
stick (≥ 1 GB), and a keyboard and monitor for the installation only.

1. **Download the ISO** – the latest ISO (e.g. `adguard-wyse3040-v1.1.0-debian-13.x.iso`) from
   [**Releases**](../../releases/latest) (or [build it yourself](#building-the-usb-stick-iso)) –
   and put it on a USB stick:
   - **[Ventoy](https://www.ventoy.net):** simply copy the ISO to the stick.
   - **[Rufus](https://rufus.ie):** select the ISO, choose **DD mode** when asked.
   - **[balenaEtcher](https://etcher.balena.io):** select the ISO, flash.
2. **Boot from the stick:** plug the stick into the Wyse, switch it on and press
   **F12** → select the USB stick. With Ventoy, pick the ISO in the menu, then
   *Boot in normal mode*.
3. **In the boot menu** choose `AdGuard Home: install / installieren` and then
   your **language**, e.g.
   `English | Keyboard: English US (us) | Time zone: UTC`.
   ⚠️ **The internal eMMC/disk is erased without any further confirmation.**
4. **Wait** (about 15–30 minutes). At the end the **Wyse switches itself off**.
5. **Remove the USB stick** and switch the Wyse on again. On first boot, AdGuard
   Home and all settings are installed (about 5 minutes). Progress is shown on
   the screen.
6. **Log in** (on the device or via SSH: `ssh adguard@<IP>`; the IP is shown on
   the screen). User `adguard`, password `adguard`. Then it continues
   automatically:
   - You must set a **new password** (see [Security](#security)).
   - The **basic setup** starts: hostname, **regular reboot**, optionally the
     Cockpit web console, **DHCP or static IP**
     (see [`adguard-setup`](#basic-setup-adguard-setup)).
7. Open **`http://<IP>:3000`** in a browser and go through the AdGuard setup
   wizard (create an admin user with a **strong password**, web interface on
   port 80, DNS on port 53). If you pick another port for the web interface,
   the banner and `status` show it; you have to open it in the firewall
   yourself, `status` then shows the command.
8. In your **router**, enter the IP of the Wyse as the DNS server. Done. 🎉

## Security

> [!IMPORTANT]
> The default password `adguard` is published in this guide.
> **For security reasons it must be changed.** The system enforces this on the
> first login. Until then, the login screen on the device shows a red warning
> with the credentials, because AdGuard can be set up in the browser without a
> Linux login, and you might otherwise forget the password.

- The user `adguard` is the administrator (via `sudo`). Direct **root login is
  disabled**, so there is no separate root password.
- Change the password later: `passwd` (your own) or `sudo adguard-setup`.
- Choose a separate, strong password for the **AdGuard admin** in the web
  interface as well. It is independent of the Linux password.
- **Never** forward ports (53, 80, 443, 22, 9090) from the internet to the Wyse
  in your router. The DNS server is meant for your home network only.
- SSH is protected against password guessing with fail2ban.

## What gets set up

| Area | Description | File(s) |
|------|-------------|---------|
| Base | Debian 13 "Trixie" minimal, no desktop, with SSH server. User `adguard` with sudo rights, no root login. | `installer/preseed.cfg` |
| Partitioning | first internal disk (eMMC, NVMe or SATA; USB is skipped): EFI + one ext4 partition (`noatime`), **no swap partition** | `installer/preseed.cfg` |
| AdGuard Home | current version in `/opt/AdGuardHome`, systemd service `AdGuardHome` | `scripts/bootstrap.sh` |
| Login banner (before login) | colored banner with hostname, IP, AdGuard address, setup wizard if pending, web console and plugged-in USB sticks; **red warning while the default password is active**; shows progress during the initial setup | `scripts/adguard-banner.sh`, `rootfs/etc/systemd/system/adguard-banner.*` |
| Welcome (after login, again with `status`) | AdGuard logo, device, installed version, system status with RAM/storage bars, temperature, AdGuard status, web console, auto-update (active + last run), auto-reboot, last backup, USB stick (free/used, backups), most important commands | `rootfs/etc/update-motd.d/99-custom-motd` |
| Language & region | texts, date/number format and time servers according to the boot menu entry; keyboard and time zone are set by the installer | `lang/`, `region/`, `scripts/set-region.sh` |
| Log limits | systemd journal max. 200 MB / 1 month, older entries are deleted automatically | `rootfs/etc/systemd/journald.conf.d/adguard.conf` |
| Automatic updates | `unattended-upgrades` (Debian + security), removes old kernels, **reboots at the configured time** (default 04:00) if required | `rootfs/etc/apt/apt.conf.d/20auto-upgrades`, `52unattended-upgrades-local` |
| Regular reboot | daily or weekly at the same time (recommended), asked in `adguard-setup` | `scripts/adguard-setup.sh` |
| Watchdog | reboots the device automatically if the system hangs completely (if a watchdog chip exists – the Wyse 3040 has one) | `rootfs/etc/systemd/system.conf.d/watchdog.conf` |
| Package cache | cleaned every 7 days | `rootfs/etc/apt/apt.conf.d/70autoclean` |
| Time | automatically via NTP from the region's pool, e.g. `pool.ntp.org` (fallback: Debian pool); the welcome screen warns if not synchronized | `scripts/set-region.sh` → `/etc/systemd/timesyncd.conf.d/adguard.conf` |
| AdGuard backup | daily at 03:30 when changed, last 7 versions, plus the system settings from `adguard-setup`; manage, restore and use a USB stick with `sudo adguard-backup`; offered automatically on reinstall | `scripts/adguard-backup.sh`, `rootfs/etc/systemd/system/adguard-backup.*` |
| USB stick info | shown on the login screen (updates when plugging in/removing) and in `status` (free/used, number of backups) | `scripts/adguard-usb.sh`, `rootfs/etc/udev/rules.d/90-adguard-usb.rules` |
| Firewall (ufw) | open: 22/tcp (SSH), 53 (DNS), 80/tcp, 443, 3000/tcp (setup wizard) | `scripts/install.sh` |
| fail2ban | SSH: 5 failed attempts in 10 min → 15 min ban, repeat offenders longer (up to 1 week) | `rootfs/etc/fail2ban/jail.local` |
| zram swap | compressed swap in RAM (50 %), spares the eMMC | `rootfs/etc/default/zramswap` |
| Power button | a short press shuts down cleanly | `rootfs/etc/systemd/logind.conf.d/adguard.conf` |
| Wyse fix (**Wyse 3040 only**) | DMA driver `dw_dmac` blacklisted: without the fix the Wyse 3040 hangs on shutdown/reboot and does not power off. Only applied when the device is detected. | `hardware/wyse3040/etc/modprobe.d/wyse-fix.conf` |
| Basic setup | restore a backup (on reinstall), hostname, password, reboot schedule, optional Cockpit, DHCP/static IP; starts automatically on first login | `scripts/adguard-setup.sh` → `sudo adguard-setup`, `rootfs/etc/profile.d/adguard-setup.sh` |

`rootfs/` contains only **own files or drop-ins** (`*.conf.d/`, `*-local`),
never full copies of package files. This keeps Debian updates conflict-free and
makes it obvious what was changed.

## How the installation works

```
 USB stick (Debian netinstall + repo)
 │
 ├─ Boot menu: choose language/region (locale, keymap, time/zone)
 ├─ Debian installer reads installer/preseed.cfg
 │    → network (DHCP), user, partition the internal disk,
 │      minimal system
 │    → late_command: copy repo to /opt/adguard-setup, remember the region,
 │                    enable the Wyse fix (Wyse 3040 only),
 │                    enable the first-boot service
 │    → device switches off
 │
 └─ First boot from the internal disk
      adguard-firstboot.service → scripts/bootstrap.sh
        → set the region (scripts/set-region.sh: language, NTP)
        → install packages (ufw, fail2ban, unattended-upgrades, zram,
          microcode for Intel/AMD …)
        → download AdGuard Home and set it up as a service
        → scripts/install.sh: apply rootfs/, detect the device and apply
          hardware/<device>/ if needed, firewall, services
        → /var/lib/adguard-setup/bootstrap.done (the service never runs again)
```

If there is no internet yet (e.g. no IP yet or the cable is not plugged in),
the setup waits for it; the login screen then shows "Waiting for internet". If
something fails after that, the service retries every 30 seconds; the login
screen then shows a notice.

## Repository layout

```
.
├── .github/workflows/build-iso.yml      # GitHub builds the ISO on a new tag
├── installer/
│   ├── build-iso.sh                     # builds the USB stick (ISO)
│   ├── preseed.cfg                      # answers for the Debian installer
│   ├── grub.cfg                         # boot menu of the stick (template)
│   └── adguard-firstboot.service        # runs bootstrap.sh on first boot
├── lang/                                # texts per language: en.sh (reference), de.sh …
├── region/                              # per country: en_US.conf, de_DE.conf … (boot menu)
├── scripts/
│   ├── bootstrap.sh                     # packages + AdGuard + install.sh
│   ├── install.sh                       # applies rootfs/ (can also run on its own)
│   ├── set-region.sh                    # region of the device (language, NTP)
│   ├── i18n.sh                          # loads the texts (used by all scripts)
│   ├── check-lang.sh                    # checks the language files
│   ├── hardware.sh                      # device detection
│   ├── adguard-setup.sh                 # hostname / password / reboot / Cockpit / IP
│   ├── adguard-banner.sh                # generates the login banner (/etc/issue)
│   ├── adguard-backup.sh                # backups of the AdGuard settings
│   ├── adguard-usb.sh                   # USB stick info for login banner + "status"
│   └── status.sh                        # "status" command: show the summary again
├── rootfs/                              # files 1:1 as on the system (all devices)
│   └── etc/ ...                         #   e.g. rootfs/etc/fail2ban/jail.local
└── hardware/                            # only for detected devices
    └── wyse3040/etc/ ...                #   Wyse fix
```

Code comments are in German (the project started in German); contributions in
English are welcome.

## Building the USB stick (ISO)

`installer/build-iso.sh` downloads the **current official Debian 13 netinstall
ISO**, verifies its checksum and adds the boot menu, the answer file and this
repo. It needs Linux with `xorriso` and `curl`. On Windows:

**With WSL** (Windows Subsystem for Linux, e.g. Debian/Ubuntu):

```bash
sudo apt install xorriso curl
cd /mnt/c/Users/<name>/Documents/git/AdGuard_Wyse3040
./installer/build-iso.sh
```

**With Docker Desktop** (PowerShell, in the repo folder):

```powershell
docker run --rm -v "${PWD}:/w" -w /w debian:13 bash -c "apt-get update -qq && apt-get install -y -qq xorriso curl && ./installer/build-iso.sh"
```

Result: `build/adguard-wyse3040-<version>-debian-13.x.iso` (about 800 MB). The
version comes from the git tag (e.g. `v1.1.0`). The `build/` folder is not
committed.

> Rebuild the ISO after every change to the repo. It always contains the state
> of the folder at build time.

### Automatically via GitHub (release)

GitHub builds the ISO itself ([`.github/workflows/build-iso.yml`](.github/workflows/build-iso.yml)).
For a new version, create and push a tag:

```bash
git tag v1.1.1
git push origin v1.1.1
```

Before that, run `./scripts/check-lang.sh` and add a `## v…` section for the new
version to `CHANGELOG.md` (English) and `CHANGELOG.de.md`. They are used for the
release text and for the update display.

After about 5 minutes the ISO is available under **Releases**. A test build
without a release: *Actions → ISO bauen → Run workflow*.

A new build is worthwhile after changes to the repo or after a new Debian point
release (13.x). The packages themselves are downloaded fresh from the internet
during installation anyway.

## Alternative: install Debian yourself

If you prefer to install Debian 13 yourself (or use another device, e.g. a
Raspberry Pi):

1. Install Debian 13 minimal: in the software selection, only tick
   **SSH server** and **standard system utilities**.
2. Then on the device:
   ```bash
   sudo apt install git
   git clone <repo-url> && cd AdGuard_Wyse3040
   sudo ./scripts/bootstrap.sh
   ```
   The region (language of the texts, time servers) follows the system locale,
   e.g. `en_GB.UTF-8` → `en_GB`. Another region:
   `sudo ./scripts/set-region.sh de_DE` and then `sudo ./scripts/install.sh`.

## Basic setup: `adguard-setup`

Starts **automatically on the first login** and reminds you on every login
until it has run through once. Can be run again at any time:

```bash
sudo adguard-setup
```

Every step can be skipped:

| Step | What happens |
|------|--------------|
| 0. Restore backup | **first run only**, if a USB stick with a backup (folder `AdGuard-Backup/`) is plugged in: choose **1)** AdGuard + system settings, **2)** AdGuard only, **3)** nothing. With 1) the following questions are **pre-filled** with the saved values; just confirm with Enter. See [new device from a backup](#setting-up-a-new-device-from-a-backup). |
| 1. Hostname | sets the hostname and updates `/etc/hosts` (default: `adguard`) |
| 2. Password | changes the password of a Linux user |
| 3. Reboot | **time** for reboots (default 04:00, also used for reboots after updates) and **regular reboot** (recommended): daily or weekly on a chosen day (default Sunday). The current time and time zone of the device are shown for reference. |
| 4. Cockpit | optionally installs the [web console](#web-console-cockpit) |
| 5. Network | **keep DHCP** or set a **static IP** with gateway and DNS. Supports `ifupdown` (Debian default), `systemd-networkd` and NetworkManager. Takes effect after a reboot. |

`adguard-setup` stores the chosen settings in `/etc/adguard-setup.conf`
(hostname, reboot schedule, Cockpit yes/no, DHCP or static IP). The file is
backed up by [`adguard-backup`](#tips-for-daily-use). The Linux password is
deliberately **not** stored.

Network notes:

- A DNS server needs a **fixed address**: either set a static IP here or
  reserve a fixed DHCP address for the Wyse in your router and keep DHCP.
- The DNS server for the device **itself** is the router or an external
  server, not its own AdGuard. This way updates still work when AdGuard is not
  running.
- When connected via SSH, reconnect to the **new** IP after the reboot.

### Web console (Cockpit)

Optionally installed via `adguard-setup`. [Cockpit](https://cockpit-project.org)
is a web interface for the Linux system at **`https://<IP>:9090`** (log in with
the Linux user `adguard`):

- terminal in the browser (no SSH client needed)
- show and install updates
- logs, services, CPU/RAM history, reboot/shutdown

After installation the address is also shown in the login banner and the
welcome screen. The browser warning about the certificate on first access is
normal (self-signed).

## Updating the project

New versions of this project (scripts, banner, settings) can be installed
without reinstalling:

```bash
sudo adguard-setup --update
```

This checks the latest [release](../../releases), shows the changes from
[CHANGELOG.md](CHANGELOG.md) (on German devices from
[CHANGELOG.de.md](CHANGELOG.de.md)) and asks for confirmation. To confirm, you
have to type `yes`. A backup is created automatically before installing.
`sudo adguard-setup --version` shows the installed version.

- The update runs **only on command**, never automatically. If everything
  works, it is not necessary. Read the changes first and decide whether you
  need them.
- **AdGuard Home** itself is **not** updated (do that in the AdGuard web
  interface); the regular Debian updates run automatically anyway.
- Your own changes to files of this project on the device are overwritten.
- Going **back** to the previous version is not possible, only via a
  [reinstall with backup](#setting-up-a-new-device-from-a-backup).
- Changes to the installer (e.g. partitioning) only take effect on a
  reinstall; the change log marks them.
- If an update brings **new questions to the setup**, the welcome screen shows
  "The setup has new settings". Then run `sudo adguard-setup`; previous answers
  can be kept with Enter.

## Changing the configuration

**Repo → device:** change a file under `rootfs/` and bring the repo to the
device (`git pull` in a clone or via `scp`), then:

```bash
sudo ./scripts/install.sh
```

**Device → repo:** if something was changed directly on the device, fetch the
file with `scp` (example from Windows, in the repo folder):

```powershell
scp adguard@<IP>:/etc/<path>/<file> rootfs/etc/<path>/
```

**Which files were changed on a device?**

```bash
# Package config files that differ from the shipped state (regardless of date)
sudo dpkg --verify | grep ' c /etc'

# When was it installed?
ls -ld --time-style=full-iso /var/log/installer

# All files in /etc with modification time, chronologically
sudo find /etc -type f -printf '%TY-%Tm-%Td %TH:%TM  %p\n' | sort

# Only files changed within a time window (date + time)
sudo find /etc -type f -newermt '2026-03-01 14:30' ! -newermt '2026-03-01 18:00'
```

## Setting up a new device from a backup

Device broken or reinstalled? With a USB stick that `adguard-backup` saved to
(folder `AdGuard-Backup/`), everything is back as before within minutes:

1. Reinstall as in the [quick start](#quick-start) (steps 1–5).
2. **Do not go through the AdGuard setup wizard.**
3. Plug in the USB stick with the backup and log in. After changing the
   password you see:
   ```
   Found: Backup from 10/19/2026 03:30 + system settings, USB stick HP_TOOLS (vfat, 959M)
     1) restore AdGuard + system settings (recommended)
     2) restore AdGuard only
     3) restore nothing, set up from scratch
   ```
   If the backup contains no system settings (e.g. from an older version),
   there is only "restore AdGuard" and "restore nothing".
4. Choose **1**: AdGuard is restored immediately (filters, rules, clients,
   admin login). The following questions (hostname, reboot schedule, Cockpit,
   IP) are pre-filled with the old values; just confirm with Enter.

> **Static IP:** if the old device is still running, it must not have the same
> IP. Switch it off first or enter a different address when asked.

Later, a backup can be restored from the stick at any time with
`sudo adguard-backup` → **4** (AdGuard only).

## Maintenance & troubleshooting

| Task | Command |
|------|---------|
| **Show summary** (as after login) | `status` |
| Follow the initial setup | `journalctl -fu adguard-firstboot` |
| AdGuard status | `systemctl status AdGuardHome` |
| Restart AdGuard | `sudo systemctl restart AdGuardHome` |
| AdGuard update | web interface or `sudo /opt/AdGuardHome/AdGuardHome --update` |
| Firewall rules | `sudo ufw status verbose` |
| Close port 3000 (after the setup wizard) | `sudo ufw delete allow 3000/tcp` |
| fail2ban status / unban an IP | `sudo fail2ban-client status sshd` · `sudo fail2ban-client set sshd unbanip <IP>` |
| Disk space | `df -h /` · `sudo du -xh / --max-depth=2 \| sort -h \| tail` |
| Journal size | `journalctl --disk-usage` |
| Recent auto-updates | `less /var/log/unattended-upgrades/unattended-upgrades.log` |
| Port 53 in use? | `sudo ss -tulpn \| grep ':53'` |
| Check time / time sync | `timedatectl` (expected: "System clock synchronized: yes") |
| Show / change reboot schedule | `systemctl list-timers adguard-reboot.timer` · `sudo adguard-setup` |
| Watchdog active? | `sudo wdctl` |

About the nightly reboot: during it (about 1 minute) DNS is unavailable on the
network. Time and frequency can be changed with `sudo adguard-setup`.

## Tips for daily use

- **Update AdGuard Home itself:** the automatic updates only cover Debian,
  **not AdGuard Home**. When a new version is available, the AdGuard dashboard
  shows a notice at the top; the update is then one click. Just check the
  dashboard now and then.
- **Limit the query log:** by default AdGuard stores all DNS queries of the
  last 90 days. Over time this can exceed 1 GB, which is tight on the small
  eMMC. Recommendation: in AdGuard under
  *Settings → General settings → Logs* set the retention to **7 days** (or
  24 hours).
- **Mind IPv6:** many routers additionally announce themselves as DNS server
  via IPv6. Devices then bypass AdGuard. Fix: also enter the Wyse as DNS server
  for IPv6 in the router, or switch off the IPv6 DNS announcement. Check: all
  devices should show up in the AdGuard dashboard.
- **Backups of the AdGuard settings** run automatically: all settings
  (filters, own rules, clients, admin login) are in one file
  (`/opt/AdGuardHome/AdGuardHome.yaml`). It is **backed up daily at 03:30 if it
  has changed**; the **last 7 versions** are kept in `/var/backups/adguard/`.
  In addition, the current **system settings** from `adguard-setup` are saved
  (`adguard-setup.conf`). Manage them with:
  ```bash
  sudo adguard-backup
  ```
  This shows all versions and offers:
  1. **back up now**
  2. **restore a version**: the current state is backed up first; if AdGuard
     does not start with the old version, it is rolled back automatically.
  3. **copy to USB stick**: one version or all (Enter), into the folder
     `AdGuard-Backup/` on the stick
  4. **restore from USB stick**
  5. **provide a version for download** (for WinSCP/`scp`)

  USB sticks with FAT32, exFAT, NTFS or ext4 are recognized. With several
  sticks you are asked which one. The stick is only mounted while copying
  (protects against data loss on power failure); afterwards it can stay plugged
  in or be removed.

  Which stick is plugged in is shown on the **login screen** (updates when
  plugging in/removing) and in `status`, which also shows free/used space and
  the number of backups on it (the stick is mounted read-only for a moment).
  Log of all plug/unplug events: `sudo journalctl -t adguard-usb`

  **Leave the stick plugged in permanently:** if a plugged-in stick has the
  folder `AdGuard-Backup/` (created on the first copy with menu item **3**),
  the daily backup copies every new version to it automatically. The last 30
  versions are kept on the stick.

  **Also keep a copy outside the device now and then.** The automatic backups
  are on the same eMMC and do not help if it breaks. Easiest: plug in a USB
  stick, `sudo adguard-backup` → **3** → **Enter** for all. Alternatively use
  "provide for download" and [WinSCP](https://winscp.net) (graphical, same
  login as SSH) or PowerShell:
  ```powershell
  scp "adguard@<IP>:AdGuardHome-*.yaml" .
  ```

  **Restore after a reinstall:** see
  [new device from a backup](#setting-up-a-new-device-from-a-backup).

  The file contains the (hashed) admin login, so keep it safe.
- **Device names instead of IP addresses in the dashboard:** in AdGuard under
  *Settings → DNS settings → Private reverse DNS servers* enter the IP of your
  router (e.g. `192.168.1.1`) and enable "Use private reverse DNS resolvers".
  AdGuard then shows "Laptop" or "Phone" instead of `192.168.1.23`. Without this
  setting the log shows the harmless message `private rdns resolution failed`.
- **Port 3000** is no longer needed after the setup wizard:
  `sudo ufw delete allow 3000/tcp`.

## Hardware & BIOS

| Component | Dell Wyse 3040 |
|-----------|----------------|
| CPU       | Intel Atom x5-Z8350, 4 cores, 1.44 GHz |
| RAM       | 2 GB DDR3L (soldered) |
| Storage   | 8 GB or 16 GB eMMC (soldered) |
| Network   | 1 GbE |
| Power     | about 3–5 W |
| Boot      | UEFI only |

- **F2** at startup: BIOS setup · **F12**: boot menu
- Default BIOS password: `Fireport`
- Recommended for 24/7 use: *Power Management → AC Recovery = **Power On***,
  so the Wyse starts again by itself after a power failure.
- If the stick does not boot: disable *Secure Boot* and enable *USB Boot* in
  the BIOS.

## Other hardware

The project is not tied to the Wyse 3040. The USB installation runs on
practically any **64-bit PC (x86-64) with UEFI**, e.g. other thin clients
(Fujitsu Futro, HP t series), mini PCs or old laptops.

**Minimum:** 1 GB RAM, 8 GB storage, network cable.

What adapts to the hardware:

| What | Behavior |
|------|----------|
| Target disk | first internal disk: eMMC → NVMe → SATA. USB drives, removable media and SD cards are skipped. ⚠️ With several internal disks, the **first** one is erased. |
| Wyse fix | only applied on a detected Wyse 3040 ([`hardware/`](hardware/)) |
| Microcode | Intel or AMD, depending on the CPU |
| Watchdog | uses the existing watchdog chip; without a chip nothing happens |

**Not supported** by the USB installation:

- **Old PCs without UEFI** (legacy BIOS only): the stick boots there, but only
  shows the normal Debian menu. Install Debian manually and use `bootstrap.sh`
  ([alternative](#alternative-install-debian-yourself)).
- **Raspberry Pi / ARM:** there is no suitable ISO. Install Debian or Raspberry
  Pi OS and use `bootstrap.sh`. The script automatically downloads the ARM
  version of AdGuard (untested).

## Languages and regions

One USB stick for all languages: under `AdGuard Home: install / installieren`
the boot menu has one entry per country that states language, keyboard and
time zone explicitly:

```
English | Keyboard: English US (us) | Time zone: UTC
English | Keyboard: English UK (gb) | Time zone: Europe/London
Deutsch | Tastatur: Deutsch (de) | Zeitzone: Europe/Berlin
Deutsch | Tastatur: Deutsch (de) | Zeitzone: Europe/Vienna
Deutsch | Tastatur: Schweizerdeutsch (ch) | Zeitzone: Europe/Zurich
```

English (US, time zone UTC) is preselected. The choice determines:

| What | Source |
|------|--------|
| texts of all menus, messages, login banner, `status` | `lang/<language>.sh` – if a translation is missing, the English text is shown |
| keyboard, time zone, system locale | set by the Debian installer |
| date and number format, time servers (NTP) | `region/<country>.conf`, on the device `/etc/adguard-region.conf` |

AdGuard Home and Cockpit follow the language of your browser. **Backups**
contain no texts, only values; they can be moved between devices with
different languages.

**Changing it later** (language and region are deliberately not part of the
setup questions):

```bash
sudo dpkg-reconfigure keyboard-configuration   # keyboard
sudo timedatectl set-timezone Europe/London    # time zone (list: timedatectl list-timezones)
sudo /opt/adguard-setup/scripts/set-region.sh en_GB && sudo /opt/adguard-setup/scripts/install.sh
                                               # texts, date format, time servers
```

> The reboot (default 04:00) and the backup (03:30) run in the device's time
> zone. With UTC this may be during the day where you live – then set your time
> zone, or choose a different time in `sudo adguard-setup`.

**Adding a language or a country** (no code changes needed, pull requests
welcome):

- **Country:** create `region/<locale>.conf` (copy an existing file), e.g.
  `region/fr_FR.conf`. The boot menu gets an entry automatically at build time;
  `ORDER=` controls the position.
- **Language:** copy `lang/en.sh` to `lang/<language>.sh` and translate it (the
  rules are at the top of the file). `./scripts/check-lang.sh` lists missing
  texts and wrong placeholders.

## License & legal

- The scripts and configuration files in this repository are licensed under the
  [MIT license](LICENSE).
- The ISO is based on the **unmodified official Debian netinstall ISO**; only
  the files of this repo are added. Debian is free software and may be
  redistributed. The source code of all Debian packages is available from
  Debian ([cdimage.debian.org](https://cdimage.debian.org/cdimage/release/),
  [snapshot.debian.org](https://snapshot.debian.org/)).
- **AdGuard Home is not included in the ISO.** It is downloaded directly from
  the official AdGuard servers during installation and is licensed under the
  [GPL-3.0](https://github.com/AdguardTeam/AdGuardHome/blob/master/LICENSE.txt).
- This is a private hobby project with no affiliation to AdGuard Software Ltd.,
  Dell Technologies or the Debian project. All trademarks belong to their
  respective owners. Use at your own risk.
