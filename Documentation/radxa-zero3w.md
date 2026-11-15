# Home Assistant OS for Radxa ZERO 3W (community fork)

Unofficial board port based on the official **ODROID-M1S** board (same RK3566 SoC,
same mainline U-Boot and Linux kernel). Only the board specific parts differ:

> **Why is any of this here?** Every deviation from upstream, the failure it
> fixes, and how to check it on a fresh install:
> [radxa-zero3w-changes.md](radxa-zero3w-changes.md).

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
* **On-board Bluetooth** is attached from userspace, not from the device tree.
  The AIC8800 is a combo part: WiFi over SDIO, Bluetooth as H4 on `uart1`.
  Two pieces are needed.

  First, the chip's Bluetooth core has to be powered and given its firmware over
  SDIO. Upstream only does that under `CONFIG_PLATFORM_ROCKCHIP`, a profile that
  also defines `ANDROID_PLATFORM` and hard-codes the upstream author's toolchain
  paths, so `patches/aic8800/0001-*` drops the guard instead. Confirmed on
  hardware: without it the boot log shows only
  `aicbsp_set_subsys, subsys: AIC_WIFI`, with it `AIC_BLUETOOTH` appears too.

  Second, something has to speak HCI on the UART. `aic8800-bt.service` runs
  `btattach -B /dev/ttyS1 -P h4 -S 1500000`. Plain H4, no vendor setup: the
  firmware has already configured its own UART from the patch table
  (`uart_baud 1500000`, `uart_flowctrl 1`, `btmode 5`), so there is nothing to
  negotiate.

  Do **not** declare a `bluetooth` child node under `&uart1` the way Radxa's
  vendor tree does, with `compatible = "brcm,bcm43438-bt"`. That was tried and
  fails on mainline: the kernel binds `btbcm`, which opens the link with the
  Broadcom vendor command `0xfc18` ("update baud rate"), the AIC8800 does not
  answer it, and `hci0` registers but stays `DOWN` with
  `BCM: Reset failed (-110)`. It presumably works on Radxa's 5.10 BSP because
  Rockchip carry a more permissive `hci_uart`. The node also consumes the serial
  port, so `/dev/ttyS1` disappears and `btattach` has nothing to attach to.

* **No Ethernet and no USB stick are needed for anything.** On-board WiFi is
  configured from `wifi.conf` on the boot partition, and SSH from
  `CONFIG/authorized_keys` next to it, so none of the procedures in the
  README involve either. Drivers for a USB Ethernet adapter (RTL8152/8153,
  ASIX AX88179, CDC-NCM) are built in, but only as an emergency way back if
  WiFi itself is broken - not as part of any normal install.
* OS updates are **not** delivered by the official Home Assistant servers (the OTA
  URL is per board). Home Assistant Core, Supervisor and add-ons update normally.
* Boot medium is the micro SD card. Use an A2 / "High Endurance" card.
* The **CPU frequency governor is `schedutil`**, set on the kernel command line
  (`cpufreq.default_governor=schedutil` in `cmdline.txt`). Upstream HAOS builds
  the kernel with `CONFIG_CPU_FREQ_DEFAULT_GOV_PERFORMANCE`, which pins all four
  cores at 1416 MHz permanently. Measured on an idle board, `schedutil` spends
  92 % of the time at 408 MHz and settles around 54 C, while still reaching full
  clock within milliseconds when work arrives; the first passive thermal trip
  point is 70 C. Setting this on the command line rather than from a
  `tmpfiles.d` rule avoids a race - the governor is in place when the cpufreq
  driver registers the policy, instead of some time after userspace has started.
  `cmdline.txt` lives on the `hassos-boot` partition, which **is** a RAUC slot
  (`[slot.boot.0]`), but an OS update does **not** overwrite it.
  `install_boot()` in `buildroot-external/ota/rauc-hook` copies every `*.txt`
  off the partition, unpacks the new `boot.vfat`, then copies them back - boot
  config is treated as user-editable and is preserved. The file's mtime still
  changes, which makes it look rewritten. Two consequences: a `cmdline.txt`
  change in the image only reaches a **freshly flashed** card, and to change the
  command line on a running board you edit `/mnt/boot/cmdline.txt` in place (it
  is vfat, mounted rw) - after which the same hook carries that edit through
  every later update. Verify with `cat /proc/cmdline` and
  `cat /sys/devices/system/cpu/cpufreq/policy0/stats/time_in_state`.
* The image **cannot ship a `modules-load.d` file.** `fix_rootfs()` in
  `buildroot-external/scripts/rootfs-layer.sh` deletes
  `${TARGET_DIR}/usr/lib/modules-load.d` after the packages install, so anything
  placed there is dropped during the build. Nothing on this board needs one:
  udev autoloads `aic8800_bsp`/`aic8800_fdrv` from the SDIO modalias, `btattach`
  pulls in `hci_uart` on demand, and `hidp` is loaded by `aic8800-bt.service`.
  To load modules on an already-installed board write `/etc/modules-load.d/*.conf`
  - that path is a bind mount from the overlay partition, so it survives reboots
  and OS updates alike - or ship them as `CONFIG/modules/*` for `haos-config`.

## Procedures live in the README

The step-by-step procedures used to live here and drifted out of date, so they
now have exactly one home: the [fork section of the root README](../README.md).

* installing on a new SD card and configuring the first boot
* taking a backup and restoring it after a fresh install
* building a new image, and the one-time RAUC signing key
* updating a board that is already running
* following a new official Home Assistant OS release

For what was changed in this fork, why, and how to verify a fresh install, see
[radxa-zero3w-changes.md](radxa-zero3w-changes.md).
