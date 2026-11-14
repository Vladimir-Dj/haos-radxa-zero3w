# Home Assistant OS for Radxa ZERO 3W (community fork)

Unofficial board port based on the official **ODROID-M1S** board (same RK3566 SoC,
same mainline U-Boot and Linux kernel). Only the board specific parts differ:

| Item | Value |
|---|---|
| Board ID | `radxa-zero3w` (RAUC compatible `haos-radxa-zero3w`) |
| U-Boot defconfig | `radxa-zero-3-rk3566` (mainline) |
| Device tree | `rockchip/rk3566-radxa-zero-3w` (mainline) |
| Supervisor machine | `odroid-m1` (aarch64 RK356x containers) |
| Board files | `buildroot-external/board/radxa/zero3w/` |
| Defconfig | `buildroot-external/configs/radxa_zero3w_defconfig` |

## First-time setup without a keyboard

Everything below is read from the FAT **boot partition of the SD card**
(`hassos-boot`), which mounts on any PC. No USB stick is needed.

### WiFi

`wifi-setup` asks for a primary and an optional backup network, installs the
NetworkManager profiles and saves the answers to `/mnt/boot/wifi.conf`:

```
ha > login
# wifi-setup
```

The primary network gets `autoconnect-priority=100` and the backup `50`, so the
board prefers the primary and falls back on its own.

To change networks later without touching the board, put the card in a PC and
edit `wifi.conf` on the boot partition; `wifi-setup.service` re-applies it on
the next boot whenever the file has changed.  Files edited on Windows keep
their CRLF line endings, so the script strips them - a stray CR inside the PSK
is otherwise invisible and the access point simply rejects the key.

### SSH

Two ways in, both on port 22222.

**With a password.** `wifi-setup` offers to set a root password; afterwards
`wifi-setup --ssh-password` changes it.  A card can also be prepared entirely
from a PC by adding `ssh_password=...` to `wifi.conf`; it is applied on the
next boot and then removed from the file.

There is no default password.  Upstream runs dropbear with `-s`, which refuses
password logins outright, because the shipped root account has an empty
password - dropping the flag unconditionally would hand out a root shell.  So
`haos-dropbear` passes `-s` unless `/root/.ssh/.password-auth` exists, and only
`set_ssh_password` creates it.

`passwd` cannot be used: `/etc` is read-only, and busybox `passwd` writes a new
file and renames it over the old one, which touches the directory.  The script
rewrites the root record in place instead, through the `/etc/shadow` bind mount
(`etc-shadow.mount`), so the password survives reboots and OS updates.

**With a key.** Put your public key in `CONFIG/authorized_keys` on the boot
partition.  On the next boot `haos-config` installs it into `/root/.ssh`, which
is itself a bind mount from the overlay, then **deletes the whole `CONFIG`
folder**.  The key therefore only has to be copied once.

Two things to watch: `haos-config` wipes `/etc/NetworkManager/system-connections`
whenever `CONFIG/network/` exists, and it *removes* an installed SSH key when a
`CONFIG` folder is present without an `authorized_keys` in it.  Prefer
`wifi-setup` for WiFi and keep `CONFIG` for the SSH key alone.

## Known limitations

* **On-board WiFi (AICsemi AIC8800) is supported** - the out-of-tree driver is
  built from `buildroot-external/package/aic8800` and its firmware is installed
  into `/lib/firmware/aic8800_fw/SDIO/`. The board's RF switch is hogged to the
  on-board PCB antenna by a device tree patch (`patches/linux/0002-*`); without
  it the chip scans every channel and completes normally, but never receives a
  beacon, which looks exactly like a broken driver.
* **NetworkManager is patched not to offer SAE on WPA2 connections**
  (`patches/network-manager/0002-*`). For `key-mgmt=wpa-psk` NetworkManager
  also advertises SAE/FT-SAE; the AIC8800 firmware builds its own association
  request with plain WPA-PSK, the two no longer match, and the access point
  deauthenticates during the 4-way handshake with reason 17. wpa_supplicant
  reports that as "pre-shared key may be incorrect", which is misleading - the
  PSK is fine. Upstream means to suppress this when PMF is disabled, but the
  test is inverted and only takes effect in AP mode.
* **On-board Bluetooth** is driven through the ordinary mainline serdev
  binding. The AIC8800 is a combo part: WiFi over SDIO, Bluetooth as H4 on
  `uart1`. Mainline enables `uart1` and declares the three Bluetooth control
  pins, but attaches no device to them, so a device tree patch
  (`patches/linux/0003-*`) adds the `bluetooth` node - declared, as in Radxa's
  own vendor tree, with the `brcm,bcm43438-bt` compatible. No Broadcom
  firmware is downloaded: the AIC8800 speaks the same H4 dialect and its BT
  firmware arrives over SDIO from `aic8800_bsp`. That SDIO-side push is
  guarded upstream by `CONFIG_PLATFORM_ROCKCHIP`, which would also pull in
  `-DANDROID_PLATFORM`, so `patches/aic8800/0001-*` drops the guard instead.
  The vendor `aic8800_btlpm` module stays disabled - it only adds an rfkill
  switch around the same call.
* A **USB Ethernet adapter** (RTL8152/8153, ASIX AX88179, CDC-NCM - all
  included) on the USB 3.0 host port also works.
* OS updates are **not** delivered by the official Home Assistant servers (the OTA
  URL is per board). Home Assistant Core, Supervisor and add-ons update normally.
* Boot medium is the micro SD card. Use an A2 / "High Endurance" card.

## 1. One-time setup: RAUC signing key

Every image trusts only the certificate it was built with. **Generate it once and
never lose it** - without it you cannot sign further updates and must reflash.

```bash
./buildroot-external/scripts/generate-signing-key.sh cert.pem key.pem
```

Add both files as GitHub repository secrets (Settings > Secrets and variables > Actions):

* `RAUC_CERT_PEM` = full content of `cert.pem`
* `RAUC_KEY_PEM`  = full content of `key.pem`

Keep an offline backup of both files. `*.pem` is git-ignored.

## 2. Build

GitHub > Actions > **Build Radxa ZERO 3W** > Run workflow. The first build takes
2-4 hours (ccache makes the following ones faster). Artifacts:

* `haos_radxa-zero3w-<version>.img.xz` - SD card image
* `haos_radxa-zero3w-<version>.raucb` - signed OTA bundle

Publishing a GitHub release (tag e.g. `18.4-radxa1`) runs the same build and
attaches the files to the release.

## 3. Install

Flash the `.img.xz` to the SD card with balenaEtcher or Raspberry Pi Imager
("Use custom"), insert it, connect the USB Ethernet adapter and power on.
Open `http://homeassistant.local:8123` after a few minutes.

Debug console: UART2 on the GPIO header (pins 8 TX / 10 RX / 6 GND),
**1500000 baud**, 3.3 V.

## 4. OS updates

Install the signed bundle with RAUC on the host (A/B slots, automatic fallback to
the previous slot if the new one fails to boot 3 times):

```bash
# Host shell: SSH to port 22222 (enable via the "debug SSH" key on the
# CONFIG USB stick / hassos-boot partition), then:
rauc install https://github.com/<owner>/<repo>/releases/download/<tag>/haos_radxa-zero3w-<version>.raucb
reboot
```

## 5. Keeping the fork current

For every new official release `X.Y`:

```bash
git fetch upstream tag X.Y
git rebase --onto X.Y <previous-release-tag> radxa-zero3w
git push --force-with-lease origin radxa-zero3w
```

Then run `bash buildroot-external/board/radxa/zero3w/sync-defconfig.sh`
(CI also runs it before every build) so kernel / U-Boot / blob versions follow
the official ODROID-M1S, commit, and publish a release `X.Y-radxa1` from the
`radxa-zero3w` branch. Also compare `board/hardkernel/odroid-m1s/` with
`board/radxa/zero3w/` for upstream changes to `uboot-boot.ush` or `haos-hook.sh`.
