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

1. **Get the image.** The repository is
   <https://github.com/Vladimir-Dj/haos-radxa-zero3w>. Take the image from a
   GitHub release, or from the artifacts of a green **Build Radxa ZERO 3W** run
   under Actions. The file is `haos_radxa-zero3w-<version>.img.xz`, where
   `<version>` is upstream's, currently `18.4`. Artifact downloads need a
   GitHub login, and **artifacts are deleted after 30 days** - after that only
   published releases still have the image.
2. **Check it.** The artifact also contains `SHA256SUMS.radxa-zero3w`. On
   Windows, where you will be flashing from:

   ```powershell
   Get-FileHash .\haos_radxa-zero3w-18.4.img.xz -Algorithm SHA256
   ```

   and compare the hash with the matching line of that file by eye.
3. **Flash** the `.img.xz` with balenaEtcher or Raspberry Pi Imager ("Use
   custom"). Use an A2 or "High Endurance" micro SD card, 32 GB or more. The
   board boots **only** from SD.
4. **Configure the first boot.** Re-insert the card in the laptop. The FAT
   partition `hassos-boot` appears as a drive. Create, in its root:

   `wifi.conf`
   ```ini
   ssid=YourNetwork
   psk=YourPassword
   # optional - a second network it falls back to on its own. The primary
   # gets autoconnect-priority 100, the backup 50.
   ssid_backup=OtherNetwork
   psk_backup=OtherPassword
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

**The RAUC signing key already exists. Do not generate a new one.** It is at
**WSL `~/haos-keys/`** (`cert.pem` and `key.pem`), deliberately outside the
repository, and the same pair is already stored as the GitHub secrets
`RAUC_CERT_PEM` and `RAUC_KEY_PEM`. Every image trusts only the certificate it
was built with, so signing a bundle with a *new* key produces one that the
running board refuses to install - and the only way back from that is a
reflash, which costs the data partition. Keep an offline copy of both files.

Only if the key is ever genuinely lost, generate a replacement - and accept
that every board already running this fork must then be reflashed:

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
release - and unlike run artifacts, release assets do not expire.

A push that touches `buildroot-external/package/aic8800/**` starts a second
workflow as well, **Test AIC8800 driver build**, which compiles just that
driver in about 15 minutes. That is why some commits show two runs and most
show one. It is also the right thing to run by hand after an upstream kernel
bump, before committing to a full build.

After a build, work through
[the acceptance checklist](Documentation/radxa-zero3w-changes.md#acceptance-checklist).

## 4. Update a board that is already running

Official Home Assistant servers do **not** serve OS updates for this board -
the OTA URL is per board and there is no entry for `radxa-zero3w`. So
`ha os update` finds nothing and `version_latest` stays empty. Updates are
installed by hand from a bundle this repository built. This path has been
exercised three times, in both A and B slots.

```sh
# 0. On the board, FIRST: write down which slot is running and how much room
#    there is. You need both afterwards, and the bundle is ~210 MB.
ssh -p 22222 root@<board-ip>
rauc status | grep "Booted from"      # e.g. "Booted from: kernel.0 (A)"
ha os info | grep version             # the version you are coming from
df -h /mnt/data | tail -1             # needs a few hundred MB free

# 1. On the laptop: download the artifact zip from the build run (GitHub needs
#    a login, so do this in a browser), unpack it, and check the bundle.
#    Note: `sha256sum -c` fails unless BOTH listed files were unpacked, so
#    check the one file instead and compare the hash by eye.
sha256sum haos_radxa-zero3w-<version>.raucb
grep raucb SHA256SUMS.radxa-zero3w

# 2. Copy the bundle to the board. scp does not work: HAOS has no sftp-server.
cat haos_radxa-zero3w-<version>.raucb   | ssh -p 22222 root@<board-ip> 'cat > /mnt/data/haos-update.raucb'

# 3. On the board: confirm it arrived whole and is signed by your key. The
#    file was renamed in step 2, so compare the hash itself, not the name.
sha256sum /mnt/data/haos-update.raucb
rauc info /mnt/data/haos-update.raucb     # Compatible: haos-radxa-zero3w,
                                          # and your certificate in the chain

# 4. Install into the inactive slot and reboot.
rauc install /mnt/data/haos-update.raucb  # ~80 s
ha host reboot                            # tears Docker down first, give it
                                          # a few minutes

# 5. After it comes back: confirm the slot actually changed, then reclaim the
#    space. Leaving the bundle costs ~210 MB on every update.
rauc status | grep "Booted from"      # must be the OTHER slot than step 0
ha os info | grep version
rm -f /mnt/data/haos-update.raucb
```

**If the new image is bad.** RAUC falls back on its own only when the slot
fails to *boot* three times. The failure that actually happens with this board
is different: the system boots fine and something above it is broken - WiFi
does not associate, `hci0` stays down, Core will not start. Nothing falls back
automatically then. Mark the bad slot and go back to the other one, from the
host shell:

```sh
rauc status mark-bad                  # marks the slot you are running
reboot                                # comes up on the previous slot
```

If WiFi itself is what broke, SSH is gone too and the only way in is the serial
console - UART2 on the GPIO header, 1500000 baud. That is the real reason to
keep the previous slot good and to read the acceptance checklist after every
update rather than assuming.


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

**Where this runs.** The clone is in **WSL Debian at `~/haos`**, not in a
Windows folder. A Windows checkout of this repository fails outright, because
upstream has filenames containing `\x2d` which Windows will not create. The
RAUC signing key lives outside the repo at **WSL `~/haos-keys`**. Pushing from
WSL sometimes fails because the credential helper is a Windows `.exe`; push
with Windows git against the UNC path instead:

```bash
git -c safe.directory=* -C "\\\\wsl.localhost\\Debian\\home\\administrator\\haos" push origin radxa-zero3w
```

**The fork is currently based on upstream tag `18.5`.** Confirm with
`git describe --tags --abbrev=0`. Keep that sentence, and the one in
`Documentation/radxa-zero3w-changes.md`, updated when you rebase - nothing else
records it.

Then, for a new upstream release `X.Y`:

```bash
cd ~/haos
git checkout radxa-zero3w
git status --porcelain          # must be empty before starting
git tag -a pre-rebase-18.5 -m "fork tip before rebasing onto X.Y"
git fetch upstream --tags
git rebase --onto X.Y 18.5 radxa-zero3w
```

`18.5` there is the **current** base, not the new one. Getting it wrong
replays the wrong range of commits. The tag in the line above keeps the old
history reachable afterwards, which matters because the rebase rewrites every
commit hash that `radxa-zero3w-changes.md` quotes.

**Expect conflicts, and know where.** Eleven files are shared with upstream;
they are listed with their purpose in
[radxa-zero3w-changes.md](Documentation/radxa-zero3w-changes.md#every-file-this-fork-touches).
Two of them fail *silently* if a hunk is lost:

* `buildroot-external/rootfs-overlay/usr/lib/systemd/system-preset/70-haos.preset`
  must still contain `enable wifi-setup.service`, `enable etc-shadow.mount` and
  `enable aic8800-bt.service`. Without them the image builds, boots, and has no
  WiFi - on a board with no Ethernet.
* `buildroot-external/busybox.config` must still enable `cryptpw`, or SSH by
  password stops working.

Check both by eye after the rebase, before building:

```bash
grep -E "wifi-setup|etc-shadow|aic8800-bt" buildroot-external/rootfs-overlay/usr/lib/systemd/system-preset/70-haos.preset
grep -E "CRYPTPW|BB_CRYPT" buildroot-external/busybox.config
```

**Then regenerate the defconfig and commit it** - `sync-defconfig.sh` writes the
file but does not commit, and prints a `NOTE:` with a diff when upstream changed
the ODROID-M1S defconfig. Read that diff: it is how kernel, U-Boot and blob
version bumps reach this board.

```bash
bash buildroot-external/board/radxa/zero3w/sync-defconfig.sh
git add buildroot-external/configs/radxa_zero3w_defconfig
git commit -m "Sync defconfig with upstream X.Y"
```

**Test the risky part before spending hours on it.** The out-of-tree aic8800
driver is pinned to a fixed commit and upstream bumps the kernel between
releases, so the driver is the most likely thing to break. Actions >
**Test AIC8800 driver build** > Run workflow compiles just that module against
the new kernel in about 15 minutes, instead of discovering the failure an hour
into a full build. If it fails, look for a newer commit of `radxa-pkg/aic8800`
and update `AIC8800_VERSION` in `buildroot-external/package/aic8800/aic8800.mk`.

Also compare the two board directories for upstream changes worth adopting -
`sync-defconfig.sh` touches neither:

```bash
diff -r buildroot-external/board/hardkernel/odroid-m1s buildroot-external/board/radxa/zero3w
```

Everything that differs there is either a deliberate fork change (the inventory
says which) or something upstream improved for the M1S that this board may want
too.

**Finally** push, let the build run, and work through
[the acceptance checklist](Documentation/radxa-zero3w-changes.md#acceptance-checklist)
on real hardware before trusting the image:

```bash
git push --force-with-lease origin radxa-zero3w
```

Publish a release `X.Y-radxa1` from the branch. That matters more than it
looks: **build artifacts are deleted after 30 days** (`retention-days: 30` in
the workflow), so a release is the only durable copy of an image.

One naming trap. The image and bundle are named from
`buildroot-external/meta`, which carries **upstream's** version - so they are
`haos_radxa-zero3w-18.4.img.xz` and `.raucb` regardless of the release tag. A
second fork build of the same upstream release produces a file with an
identical name and an identical internal version, and `rauc info` cannot tell
them apart. Keep `SHA256SUMS.radxa-zero3w` next to any image you store, and
rename the files to include the release tag if you keep more than one.

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
