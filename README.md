# Home Assistant OS for Radxa ZERO 3W - community fork

> Unofficial port of Home Assistant OS to the **Radxa ZERO 3W** (Rockchip
> RK3566), based on the official **ODROID-M1S** board. Not affiliated with
> Home Assistant.

This fork exists because there is no official HAOS image for this board, and
because the board has **no Ethernet port** - its only network interface is an
on-board AICsemi AIC8800 WiFi/Bluetooth chip whose driver is not in the HAOS
kernel. Getting that chip to work took three separate fixes; getting the board
usable with no keyboard and no monitor took a few more.

**If you are reading this because you no longer remember what was done or why,
start here:**

| Question | Where |
|---|---|
| What was changed, what problem each change solves, and why | [Documentation/radxa-zero3w-changes.md](Documentation/radxa-zero3w-changes.md) |
| How to check a fresh install really works | [the acceptance checklist](Documentation/radxa-zero3w-changes.md#acceptance-checklist) |
| Things already tried that cannot work - do not retry | [dead ends](Documentation/radxa-zero3w-changes.md#dead-ends---do-not-retry-these) |
| Board reference: IDs, paths, limitations, serial console | [Documentation/radxa-zero3w.md](Documentation/radxa-zero3w.md) |

Everything in the five sections below is a procedure that has been carried out
on real hardware, not a plan.

---

## 1. Install on a new SD card

You need the image, a card, and a laptop. **No USB Ethernet adapter and no
keyboard are required** - that is the whole point of the `wifi-setup` work.

1. **Get the image.** Either from a GitHub release of this repository, or from
   the artifacts of a green **Build Radxa ZERO 3W** run under Actions. The file
   is `haos_radxa-zero3w-<version>.img.xz`. Artifact downloads require being
   logged in to GitHub.
2. **Check it.** The artifact also contains `SHA256SUMS.radxa-zero3w`; compare
   before flashing.
3. **Flash** the `.img.xz` with balenaEtcher or Raspberry Pi Imager ("Use
   custom"). Use an A2 or "High Endurance" micro SD card, 32 GB or more. The
   board boots **only** from SD.
4. **Configure the first boot.** Re-insert the card in the laptop. The FAT
   partition `hassos-boot` appears as a drive. Create, in its root:

   `wifi.conf`
   ```ini
   ssid=YourNetwork
   psk=YourPassword
   # optional - sets the root password for SSH on port 22222
   ssh_password=something
   ```

   `CONFIG/authorized_keys` - your SSH public key, one per line.

   Both files may be written on Windows; CRLF line endings are stripped for
   you. `wifi.conf` is re-applied whenever it changes, so you can fix a typo
   later by editing it on the card.

   > **Two traps.** Do **not** create a `CONFIG/network/` folder: `haos-config`
   > wipes `/etc/NetworkManager/system-connections` whenever that folder
   > exists. And a `CONFIG` folder *without* `authorized_keys` **removes** an
   > already-installed key. `haos-config` deletes the whole `CONFIG` folder
   > after importing it, and `wifi-setup` removes the `ssh_password=` line once
   > it has been applied.

5. **Boot it.** Insert the card, power on. Give it a few minutes.
6. **Open Home Assistant** at `http://<board-ip>` - **port 80, not 8123** on
   this install. Find the address in your router's lease list, or over SSH.

   > The board currently in service does not answer there: it serves **HTTPS on
   > port 443** with a trusted Let's Encrypt certificate and is reached at
   > `https://ha.artofme.eu`. That is Home Assistant configuration plus two
   > router settings rather than part of the image, so a fresh card starts on
   > plain HTTP again. How it is set up, why a DNS record alone was not enough,
   > and how renewal works are in
   > [the changes document](Documentation/radxa-zero3w-changes.md#outside-this-repository).
7. **SSH** reaches the host shell on port **22222**:
   `ssh -i <your-key> -p 22222 root@<board-ip>`. That is the OS shell, not the
   `ha >` CLI.

Then either onboard from scratch, or restore a backup - see the next section.

Debug console if it does not come up at all: UART2 on the GPIO header
(pin 8 TX, pin 10 RX, pin 6 GND), **1500000 baud**, 3.3 V adapter.

## 2. Backup and restore

**The image contains the operating system only.** Your Home Assistant account,
integrations, add-ons and automations all live on the data partition, which a
fresh flash erases. An OS update over RAUC does *not* erase it - only
reflashing the card does.

So before you ever reflash:

**Make a backup**

* In the UI: Settings > System > Backups > *Create backup* > full backup.
* Or over SSH: `ha backups new`, which prints a `slug`.

**Copy it off the board.** This is the step that is easy to forget and makes
the difference. A backup sitting on the card you are about to rewrite is
worthless.

* In the UI: Settings > System > Backups, open the backup, *Download*.
* Or over SSH, from your laptop:
  ```sh
  ssh -p 22222 root@<board-ip> 'cat /mnt/data/supervisor/backup/<slug>.tar' > backup.tar
  ```
  (`scp` does not work - HAOS ships no `sftp-server`.)

**Restore after a fresh install**

Flash and configure the card as in section 1, boot, then at the Home Assistant
onboarding screen choose to restore from a backup and upload the `.tar`. If
you have already onboarded, use Settings > System > Backups > upload instead.
Add-ons, integrations and configuration come back with it.

A full backup also carries `.storage/http` and the `ssl` folder, so the HTTPS
settings and the certificate come back too - meaning the restored board will
again answer on `https://ha.artofme.eu` and port 443, not on plain HTTP. The
name only resolves because of a static DNS entry on the router, which is not
in the backup; see the changes document if it ever stops resolving.

## 3. Build a new image

Builds run in GitHub Actions; a local Buildroot build needs far more disk than
a typical laptop has.

**One-time setup - the RAUC signing key.** Every image trusts only the
certificate it was built with. Generate it once and **never lose it**: without
it you cannot sign further OS updates for boards already running this fork, and
your only way back is to reflash the card.

```sh
./buildroot-external/scripts/generate-signing-key.sh cert.pem key.pem
```

Add both as repository secrets under Settings > Secrets and variables >
Actions: `RAUC_CERT_PEM` and `RAUC_KEY_PEM`. Keep an offline copy of both.
`*.pem` is git-ignored.

**Then build.** A push to `radxa-zero3w` that touches `buildroot-external/**`
or the workflow file builds automatically; otherwise Actions > *Build Radxa
ZERO 3W* > Run workflow. The first build takes 2-4 hours, later ones are
faster thanks to the object-file cache. Each run produces:

* `haos_radxa-zero3w-<version>.img.xz` - SD card image
* `haos_radxa-zero3w-<version>.raucb` - signed OTA bundle
* `SHA256SUMS.radxa-zero3w`

Publishing a GitHub release runs the same build and attaches the files to the
release. Note that two workflows trigger per push, so each commit produces two
run numbers for the same commit.

After a build, work through
[the acceptance checklist](Documentation/radxa-zero3w-changes.md#acceptance-checklist).

## 4. Update a board that is already running

Official Home Assistant servers do **not** serve OS updates for this board -
the OTA URL is per board and there is no entry for `radxa-zero3w`. So
`ha os update` finds nothing and `version_latest` stays empty. Updates are
installed by hand from a bundle this repository built. This path has been
exercised three times, in both A and B slots.

```sh
# 1. On the laptop: download the artifact zip from the build run (GitHub needs
#    a login, so do this in a browser), then unpack and verify.
sha256sum -c SHA256SUMS.radxa-zero3w

# 2. Copy the bundle to the board. scp does not work: no sftp-server.
cat haos_radxa-zero3w-<version>.raucb \
  | ssh -p 22222 root@<board-ip> 'cat > /mnt/data/haos-update.raucb'

# 3. On the board: confirm it arrived whole and is signed by your key.
ssh -p 22222 root@<board-ip>
sha256sum /mnt/data/haos-update.raucb     # must match SHA256SUMS
rauc info /mnt/data/haos-update.raucb     # Compatible: haos-radxa-zero3w,
                                          # and your certificate in the chain

# 4. Install into the inactive slot and reboot.
rauc install /mnt/data/haos-update.raucb  # ~80 s
ha host reboot                            # tears Docker down first
```

RAUC keeps two slots and falls back to the previous one if the new slot fails
to boot three times. After the reboot, `rauc status` should show
`Booted from: kernel.1 (B)` if it was on A before, and the Supervisor marks the
new slot `good`. The data partition is untouched.

Two things an OS update does **not** change, both deliberate upstream
behaviour:

* **`/mnt/boot/cmdline.txt` and every other `*.txt` on the boot partition are
  preserved**, because the RAUC install hook copies them off and back. A change
  to `cmdline.txt` in the image therefore only reaches a freshly flashed card.
  To change the kernel command line on a running board, edit the file in place.
* `/etc/modules-load.d/` lives on the overlay partition, so anything you put
  there survives too.

## 5. Follow a new official Home Assistant OS release

When upstream publishes release `X.Y`:

```sh
git fetch upstream tag X.Y
git rebase --onto X.Y <previous-release-tag> radxa-zero3w
bash buildroot-external/board/radxa/zero3w/sync-defconfig.sh
git push --force-with-lease origin radxa-zero3w
```

`sync-defconfig.sh` regenerates `radxa_zero3w_defconfig` from the official
`odroid_m1s_defconfig`, so kernel, U-Boot and blob versions follow upstream.
CI runs it before every build as well, and fails the build if any ODROID-M1S
reference is left behind.

Then:

* Re-check the fork's own patches still apply. Upstream moves, and a patch that
  no longer applies fails the build about an hour in. Dry-run new or edited
  patches against the real upstream source before pushing - a wrong line count
  in a hunk header makes `patch` reject the whole file.
* Compare `buildroot-external/board/hardkernel/odroid-m1s/` with
  `buildroot-external/board/radxa/zero3w/` for upstream changes to
  `uboot-boot.ush` or `haos-hook.sh`, which `sync-defconfig.sh` does not touch.
* Publish a release `X.Y-radxa1` from the `radxa-zero3w` branch.
* Work through
  [the acceptance checklist](Documentation/radxa-zero3w-changes.md#acceptance-checklist)
  on real hardware before trusting the image.

---

Everything below this line is the upstream Home Assistant OS README.

# Home Assistant Operating System

Home Assistant Operating System (formerly HassOS) is a Linux based operating system optimized to host [Home Assistant](https://www.home-assistant.io) and its [Apps](https://www.home-assistant.io/apps/).

Home Assistant Operating System uses Docker as its container engine. By default it deploys the Home Assistant Supervisor as a container. Home Assistant Supervisor in turn uses the Docker container engine to control Home Assistant Core and Apps in separate containers. Home Assistant Operating System is **not** based on a regular Linux distribution like Ubuntu. It is built using [Buildroot](https://buildroot.org/) and it is optimized to run Home Assistant. It targets single board compute (SBC) devices like the Raspberry Pi or ODROID but also supports x86-64 systems with UEFI.

[![Home Assistant - A project from the Open Home Foundation](https://www.openhomefoundation.org/badges/home-assistant.png)](https://www.openhomefoundation.org/)

## Features

- Lightweight and memory-efficient
- Minimized I/O
- Over The Air (OTA) updates
- Offline updates
- Modular using Docker container engine

## Supported hardware

The list of supported hardware is defined by [ADR-0015](https://github.com/home-assistant/architecture/blob/master/adr/0015-home-assistant-os.md).
Every new hardware addition must meet at least requirements defined in [ADR-0017](https://github.com/home-assistant/architecture/blob/master/adr/0017-hardware-screening-os.md) and pass through an architecture design proposal.

For documentation explaining details of the individual supported boards, see [Board support](https://contributors.home-assistant.io/os/operating-system/boards/) section of the Home Assistant contributor docs.

## Getting Started

If you just want to use Home Assistant the official [getting started guide](https://www.home-assistant.io/getting-started/) and [installation instructions](https://www.home-assistant.io/hassio/installation/) take you through how to download Home Assistant Operating System and get it running on your machine.

If you're interested in finding out more about Home Assistant Operating System and how it works read on...

## Development

If you don't have experience with embedded systems, Buildroot or the build process for Linux distributions it is recommended to read up on these topics first (e.g. [Bootlin](https://bootlin.com/docs/) has excellent resources).

The Home Assistant Operating System documentation can be found on the [Home Assistant contributors website](https://contributors.home-assistant.io/os/operating-system/).

### Components

- **Bootloader:**
  - [GRUB](https://www.gnu.org/software/grub/) for devices that support UEFI
  - [U-Boot](https://www.denx.de/wiki/U-Boot) for devices that don't support UEFI
- **Operating System:**
  - [Buildroot](https://buildroot.org/) LTS Linux
- **File Systems:**
  - [SquashFS](https://www.kernel.org/doc/Documentation/filesystems/squashfs.txt) for read-only file systems (using LZ4 compression)
  - [ZRAM](https://www.kernel.org/doc/Documentation/blockdev/zram.txt) for `/tmp`, `/var` and swap (using LZ4 compression)
- **Container Platform:**
  - [Docker Engine](https://docs.docker.com/engine/) for running Home Assistant components in containers
- **Updates:**
  - [RAUC](https://rauc.io/) for Over The Air (OTA) and USB updates
- **Security:**
  - [AppArmor](https://apparmor.net/) Linux kernel security module

### Development builds

The Development build GitHub Action Workflow is a manually triggered workflow
which creates Home Assistant OS development builds. The development builds are
available at [https://os-artifacts.home-assistant.io/index.html](https://os-artifacts.home-assistant.io/index.html).
