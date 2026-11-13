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

## Known limitations

* **On-board WiFi (AICsemi AIC8800) is supported** - the out-of-tree driver is
  built from `buildroot-external/package/aic8800` and its firmware is installed
  into `/lib/firmware/aic8800_fw/SDIO/`. The board's RF switch is hogged to the
  on-board PCB antenna by a device tree patch (`patches/linux/0002-*`); without
  it the chip scans every channel and completes normally, but never receives a
  beacon, which looks exactly like a broken driver.
* **On-board Bluetooth is not supported** - only the WiFi modules
  (`aic8800_bsp`, `aic8800_fdrv`) are built, `aic8800_btlpm` is disabled.
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
