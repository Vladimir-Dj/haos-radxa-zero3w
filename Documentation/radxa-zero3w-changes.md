# Radxa ZERO 3W fork: what was changed, why, and how to verify it

This file is the record of every deliberate deviation from upstream Home
Assistant OS in this fork, why it exists, and what it is supposed to do on a
**freshly flashed** card. Read it before changing or removing anything here:
several of these changes look redundant until you know which failure they
prevent, and three earlier attempts were reverted because they could never have
worked.

The board is a Radxa ZERO 3W (Rockchip RK3566, 2 GB RAM, SD-card boot only, no
Ethernet, on-board AICsemi AIC8800 WiFi + Bluetooth). There is no official HAOS
image for it. The closest official board is ODROID-M1S, the same SoC, so
`radxa_zero3w_defconfig` is generated from `odroid_m1s_defconfig` by
`buildroot-external/board/radxa/zero3w/sync-defconfig.sh`, which runs at the
start of every CI build.

## The baseline: Friday 13 Nov

Commits `09ea2e764`, `80051526d`, `e07f903bb`, `a2a824bc5` added the board and
its CI workflow. That image booted on real hardware and ran Home Assistant, but
it had **no network at all**: the AIC8800 driver is not in the HAOS kernel, and
the board has no Ethernet port. Everything below exists to close the gap between
"boots" and "usable with no keyboard, no monitor and no USB adapter".

Each section states the goal, the commits, and - most importantly - the
observable failure that made the change necessary.

## 1. WiFi

**Goal:** the on-board AIC8800 joins the house WPA2 network by itself at boot.

Three separate problems had to be solved, in this order. Each one completely hid
the next, which is why this took three rounds rather than one.

### 1a. The driver is missing - `47965778b`, `f52c158d1`

The AIC8800 SDIO driver is out of tree. Added as a Buildroot package in
`buildroot-external/package/aic8800/`, built from `radxa-pkg/aic8800` with that
project's own `debian/patches` quilt series applied the way the Debian package
applies it. `CONFIG_PWRSEQ_SIMPLE=y` was added to the board `kernel.config` for
the SDIO power sequencing the device tree asks for.

Two files in the upstream source are stored with CRLF line endings and the patch
series fails on them, so `AIC8800_CRLF_FILES` strips the CRs before the series is
applied. Do not remove that: without it the build fails about an hour in.

### 1b. The antenna switch - `ab59ff6b0`

**Symptom:** the driver loaded, the chip was detected (AIC8800D80), firmware
loaded, `ieee80211 phy0` registered with HT/VHT/HE, NetworkManager saw `wlan0` -
and every scan returned **zero** networks. Not a weak signal: zero. The firmware
scanned, reported completion, and heard nothing.

**Cause:** the board has two antenna paths and a GPIO selects between them.
Radxa's vendor device tree carries a `/board-antenna` node - a
`regulator-fixed` with `regulator-always-on` and `enable-active-low` on
`gpio3 RK_PD3` - which drives **GPIO3_D3 low at boot to select the on-board
antenna**. Mainline `rk3566-radxa-zero-3w.dts` has no such node, so the pin
floats and the chip transmits into the empty external U.FL socket.

**Fix:** `patches/linux/0002-arm64-dts-rockchip-Select-on-board-WiFi-antenna-on-Radxa-ZERO-3W.patch`
adds a GPIO hog holding the pin low. Proven first by hand on the running board -
`echo 0 > /sys/class/gpio/gpio123/value` made six networks appear instantly -
and only then written as the patch.

Ruled out before finding this, so nobody repeats the search: regulatory domain
(the driver uses its own permissive `regdom_00`), the 32 kHz clock
(`COMMON_CLK_RK808=y`, `rk817-clkout2` enabled with the sdio-pwrseq consumer),
and module parameters (Radxa's own config package turned out to be empty).

### 1c. NetworkManager offers SAE and the AP rejects the association - `88459c889`

**Symptom:** with the antenna fixed, scanning found every network and the chip
associated - then the 4-way handshake failed with
`CTRL-EVENT-DISCONNECTED reason=17` and "pre-shared key may be incorrect". The
key was correct. Reason 17 is *IE in 4-Way Handshake different from
(Re)Association Request/Beacon*: an RSN IE mismatch, not a wrong password.

**Cause:** NetworkManager hands wpa_supplicant five AKMs
(`WPA-PSK WPA-PSK-SHA256 FT-PSK SAE FT-SAE`), so the RSN IE advertises SAE, but
the AIC8800 is a fullmac chip whose firmware builds an association request with
plain WPA-PSK only. The AP sees the two differ and deauthenticates. Proven by
running `wpa_supplicant` by hand with `key_mgmt=WPA-PSK`: it connects
immediately on the same kernel, driver and firmware. Narrowed further -
`key_mgmt=WPA-PSK WPA-PSK-SHA256 FT-PSK` also connects, so **only SAE and
FT-SAE break it**.

This is a NetworkManager bug. In `src/core/supplicant/nm-supplicant-config.c`
(1.50.2) the `key-mgmt=wpa-psk` branch appends SAE/FT-SAE guarded by
`(!is_ap || pmf != NM_SETTING_WIRELESS_SECURITY_PMF_DISABLE)`. Its own comment
says not to do this when PMF is disabled, but `!is_ap` is true for every
station, so SAE is always offered and the PMF setting only ever matters in AP
mode. That is why no amount of PMF configuration helped.

**Fix:** `patches/network-manager/0002-supplicant-no-SAE-on-wpa-psk-station.patch`
requires `is_ap` in that guard.

One unrelated trap found alongside, on the router rather than the board: on
RouterOS, unticking `WPA PSK` in a security profile clears the pre-shared key
field, so re-ticking it leaves WPA1 advertised with an empty key and the AP
answers every client with `ASSOC-REJECT status_code=1`. Leave such a profile at
`WPA2 PSK` only.

## 2. Bluetooth

**Goal:** the Bluetooth half of the same chip comes up as `hci0` at boot.

### 2a. The BT core is never powered - `298f0fa92`

**Symptom:** `dmesg` showed `aicbt_patch_table_load` and a BT patch version at
boot, which looks like success but is only the combined firmware upload. The
decisive line is `aicbsp: aicbsp_set_subsys, subsys: AIC_WIFI, state to: 1` with
**no `AIC_BLUETOOTH` counterpart** - the BT subsystem is never powered on.

**Fix:** `patches/aic8800/0001-bsp-power-on-the-Bluetooth-subsystem-at-init.patch`
removes a `CONFIG_PLATFORM_ROCKCHIP` guard so `aic8800_bsp` powers the BT core
and pushes its firmware over SDIO. Confirmed by `AIC_BLUETOOTH` then appearing
in the same log.

### 2b. Attach from userspace, not from the device tree - `f01797914`

The first attempt declared a `bluetooth` child node under `&uart1` with
`compatible = "brcm,bcm43438-bt"`, the way Radxa's vendor tree does. **That was
reverted.** On mainline the kernel binds `btbcm`, which opens the link with the
Broadcom vendor command `0xfc18` ("update baud rate"); the AIC8800 never
answers, so `hci0` registers but stays `DOWN` with `BCM: Reset failed (-110)`.
The node also consumes the serial port, so `/dev/ttyS1` disappears and
unbinding the driver does not bring it back - only a device tree without the
node does.

**Fix:** no device tree node at all. `uart1` stays a plain serial port and
`aic8800-bt.service` runs `btattach -B /dev/ttyS1 -P h4 -S 1500000`. Plain H4
with no vendor setup is correct here because the firmware has already configured
its own UART from its patch table (`uart_baud 1500000`, `uart_flowctrl 1`,
`btmode 5`), so there is no baud rate to negotiate.

## 3. First-time setup with no keyboard and no USB stick

**Goal:** a freshly flashed card joins WiFi and accepts SSH with nothing but
files copied onto the boot partition from a laptop.

### 3a. `wifi-setup` - `9a5ef3eca`

`usr/sbin/wifi-setup` plus `wifi-setup.service`. The service has
`ConditionPathExists=/mnt/boot/wifi.conf` and `After=haos-config.service`,
because `haos-config` may rewrite `/etc/NetworkManager/system-connections`
wholesale and would otherwise undo the profile.

Why a custom script rather than upstream's `CONFIG/network/` import: HAOS's own
mechanism does copy NetworkManager keyfiles into place, but their inline `psk=`
is **not** honoured - activation fails with "Secrets were required, but not
provided", because the Supervisor owns the secret as the NetworkManager agent.
`wifi-setup` creates the profile through the `ha` network path instead, which
stores the secret where the Supervisor expects it. The profile it creates ends
up named after the SSID, while the Supervisor's own is called
`Supervisor wlan0` - worth knowing when reading `nmcli c`.

The script strips CRLF from `wifi.conf`, so the file can be written on Windows.

### 3b. SSH with a password - `7c1cfcd44`, `f01797914`

`wifi-setup --ssh-password` hashes the password with `cryptpw` and rewrites the
root record in `/etc/shadow` in place through a bind mount, then drops a marker.
`haos-dropbear` reads the marker and starts dropbear offering
`publickey,password` on port 22222. `etc-shadow.mount` is what makes the
password persist, including across OS updates.

Two bugs from this work are worth keeping in mind, because both cost a full
build cycle:

* The first `haos-dropbear` shipped **without its options**, because a nested
  shell heredoc lost its quoting and `${VAR}` expanded to nothing at write
  time - dropbear ended up listening on port 22 with password authentication
  on. Always read back any file written through a heredoc.
* systemd `Condition*` directives are ANDed, **even several of the same type**.
  Only conditions prefixed with `|` are ORed among themselves. Getting this
  wrong left dropbear skipped entirely on a key-only install.

## 4. Bluetooth HID (keyboards, mice) - `22802446a`, then `cd8469c55`

**Symptom:** pairing a Bluetooth keyboard succeeded, but every HID connection
failed with `org.bluez.Error.Failed br-connection-create-socket`. `hidp` is not
loaded at boot, and bluetoothd's input plugin probes for HIDP when it starts, so
loading it afterwards is too late - bluetoothd has to be restarted as well.

The first fix added `hidp` to `aic8800.conf`, which `aic8800.mk` installed into
`/usr/lib/modules-load.d/`. **That never worked and has been removed.**
`fix_rootfs()` in `buildroot-external/scripts/rootfs-layer.sh` deletes
`${TARGET_DIR}/usr/lib/modules-load.d` after the packages install, so the file
has never shipped in any image. What made this hard to see is that the firmware
installed by the *same* hook does survive: firmware present and the conf absent
is the proof that the hook ran and something else removed the file.

**Fix:** `aic8800-bt.service` carries `ExecStartPre=-/usr/sbin/modprobe hidp`.
The ordering is guaranteed by something non-obvious: `bluetooth.target` is
`WantedBy` the **`hci0` device unit**, so bluetoothd starts only once `btattach`
has created `hci0`. An `ExecStartPre` in that same service is therefore always
early enough. The `-` prefix means a missing `hidp` still leaves plain
Bluetooth working.

The rest of the old conf was redundant anyway: udev autoloads `aic8800_bsp` and
`aic8800_fdrv` from the SDIO modalias, and `btattach` pulls in `hci_uart` on
demand. The file was deleted along with its install line.

**If you ever need a module list on a board that is already installed**, write
`/etc/modules-load.d/*.conf`. That path is a bind mount from the overlay
partition, so it survives reboots *and* OS updates. The image cannot provide it.

Note also that `modprobe -r` on either aic8800 module is a one-way trip: see the
dead ends table.

## 5. CPU frequency governor - `62f7a7d07`

Upstream HAOS builds the kernel with `CONFIG_CPU_FREQ_DEFAULT_GOV_PERFORMANCE`,
which pins all four cores at 1416 MHz permanently. `cmdline.txt` therefore
carries `cpufreq.default_governor=schedutil`. Measured on an idle board,
`schedutil` spends most of its time at 408 MHz and settles around 50 C while
still reaching full clock within milliseconds; the first passive thermal trip
point is 70 C.

The board `kernel.config` still says `PERFORMANCE` on purpose. The command line
overrides it at boot, and leaving the config as the synced defconfig generates
it avoids a needless diff.

Setting this on the command line rather than from a `tmpfiles.d` rule avoids a
race: the governor is in place when the cpufreq driver registers the policy,
instead of some time after userspace has started.

**Important, and originally documented the wrong way round:** an OS update does
**not** deliver a changed `cmdline.txt`. `install_boot()` in
`buildroot-external/ota/rauc-hook` copies every `*.txt` off `hassos-boot`,
unpacks the new `boot.vfat`, then copies them back - boot config is treated as
user-editable and is preserved. Its mtime still changes, which makes it look
rewritten. Two consequences:

* a `cmdline.txt` change in the image only ever reaches a **freshly flashed**
  card;
* to change the kernel command line on a running board, edit
  `/mnt/boot/cmdline.txt` in place (vfat, mounted rw) - after which the same
  hook carries that edit through every later update.

## Dead ends - do not retry these

| Attempt | Commits | Why it cannot work |
|---|---|---|
| `wifi.pmf=1` NetworkManager drop-in, to stop SAE being offered | added `48346e435`, removed `88459c889` | The NM bug's guard is `!is_ap`, true for every station, so the PMF setting is ignored outside AP mode. Verified in the built image with `cat`: the drop-in was present and `key_mgmt` still listed SAE. `wifi.pmf` and `802-11-wireless-security.pmf` are also rejected as config keys; `wifi-sec.pmf` is accepted but has no effect. |
| `brcm,bcm43438-bt` device tree node for Bluetooth | added `298f0fa92`, fixed `9619c7123`, removed `f01797914` | Mainline binds `btbcm`, which sends vendor command `0xfc18`; the AIC8800 never answers. `hci0` stays DOWN and `/dev/ttyS1` is consumed. |
| `hidp` via a `modules-load.d` file in the image | added `22802446a`, removed `cd8469c55` | `rootfs-layer.sh` deletes `/usr/lib/modules-load.d` during the rootfs build. |
| Masquerading as `odroid-m1s` to get official OTA bundles | never committed | The OTA URL is per board and the official server has no entry for this one; using the M1S id would flash the wrong DTB and U-Boot. OS updates must come from this fork's own CI, signed with its own RAUC key. |
| `modprobe -r aic8800_fdrv` to test module parameters | never committed | Unloading `fdrv` makes `bsp` power the chip down and it never re-probes (`fail to set AIC_WIFI power state to 1`, SDIO error -123). Only a reboot recovers it. Set writable parameters through sysfs instead, or bake a modprobe.d file into the image. |
| Disabling driver power save (`ps_on=N`) | never committed | The parameter is read-only at runtime, and the official Radxa image ships no modprobe.d entry for it either, so they run with power save on too. It costs some ping jitter (avg ~5 ms, occasional 60 ms) and nothing else. |

## What a freshly flashed card must do

Write `haos_radxa-zero3w-<version>.img.xz` to the card, then on the
`hassos-boot` partition - it appears as a drive on Windows - create:

* `wifi.conf` - SSID, PSK, and optionally `ssh_password=`
* `CONFIG/authorized_keys` - your public key, LF line endings

Do **not** add a `CONFIG/network/` folder next to it: `haos-config` wipes
`/etc/NetworkManager/system-connections` whenever that folder exists. A `CONFIG`
folder *without* `authorized_keys` removes an already-installed key.
`haos-config` deletes the whole `CONFIG` folder after importing it.

Then, with no keyboard and no monitor attached, the board should:

1. boot and select the on-board WiFi antenna
2. load the AIC8800 driver and associate with the WPA2 network
3. take an address over DHCP and answer on port 80 with Home Assistant onboarding
4. accept SSH on port 22222 with your key, and with the password if you set one
5. bring up `hci0`, with `hidp` already loaded
6. run all four cores on `schedutil`

## Acceptance checklist

Run after a fresh install, over SSH on port 22222. Each line states what to
expect; every one of these has been verified on hardware.

```sh
# 1. Right image, right slot, and the slot was accepted
rauc status | head -5
#   Compatible: haos-radxa-zero3w
#   Booted from: kernel.0 (A) on a fresh flash, boot status: good

# 2. The governor came from the command line, not from a later tweak
tr ' ' '\n' < /proc/cmdline | grep cpufreq
#   cpufreq.default_governor=schedutil
cat /sys/devices/system/cpu/cpu[0-9]/cpufreq/scaling_governor
#   schedutil, four times
cat /sys/devices/system/cpu/cpufreq/policy0/stats/time_in_state
#   most ticks at 408000, not everything at 1416000

# 3. The antenna hog is in effect
grep -i antenna /sys/kernel/debug/gpio
#   gpio-27 (wifi-antenna-onboard) out lo

# 4. WiFi driver and link
lsmod | grep aic8800
#   aic8800_fdrv and aic8800_bsp
nmcli -t -f GENERAL.CONNECTION,IP4.ADDRESS d show wlan0
#   a connection name and an address

# 5. The NetworkManager patch is in the image: no SAE on WPA2
journalctl -u NetworkManager | grep -o "added 'key_mgmt' value '[^']*'" | tail -1
#   WPA-PSK WPA-PSK-SHA256 FT-PSK   - and NO SAE / FT-SAE

# 6. Bluetooth, including HID
systemctl is-active aic8800-bt
#   active
hciconfig hci0 | head -3
#   UP RUNNING, with a BD address
lsmod | grep hidp
#   hidp present, and loaded before bluetoothd started
dmesg | grep -i "aicbsp_set_subsys"
#   both AIC_WIFI and AIC_BLUETOOTH set to state 1

# 7. SSH offers what you configured
grep -c '^root:[$]6[$]' /etc/shadow
#   1 if you set a password with wifi-setup --ssh-password

# 8. Home Assistant itself
ha core info | grep -E 'version|port'
#   port: 80   - NOT 8123 on this install
```

Three notes that have cost time before:

* Home Assistant on this install serves on **port 80**, not 8123.
* Right after a reboot, `ha apps info <slug>` reporting `state: stopped` is
  normal. The Supervisor starts add-ons only in its `application` phase, which
  comes *after* Core reaches `RUNNING`.
* The host OS shell has no `iw`, `wpa_cli`, `rfkill`, `strings` or
  `systemd-analyze`. Diagnose with `nmcli`, `journalctl` and `dmesg`; verify
  unit files on a normal Linux box instead.

## What is NOT in the image

The image carries the operating system only. Everything below lives on the data
partition, which a fresh flash erases, and none of it can be baked in:

* the Home Assistant onboarding account
* configured integrations (currently 33 config entries - Shelly, SoundTouch,
  DLNA, Android TV, Cast, Music Assistant and the rest)
* installed add-ons and their configuration, including Music Assistant's
  Spotify login and its volume-normalization setting
* `automations.yaml`

**So take a Home Assistant backup and copy it off the board before reflashing.**
A backup sitting on the same SD card is worthless the moment you rewrite that
card. With a backup, a fresh install is: flash, drop `wifi.conf` and
`CONFIG/authorized_keys` on the boot partition, boot, restore.

An OS update over RAUC is a different matter: it leaves the data partition
untouched, so add-ons, integrations and configuration all survive. That has been
exercised three times now, in both slots.

## Outside this repository

Three things that are part of the working house but deliberately not part of
the image, recorded here so the reasoning is not lost:

* **Home Assistant serves HTTPS with a trusted Let's Encrypt certificate for
  `ha.artofme.eu`, since 15 Nov 2026.** None of this is in the image - it is
  Home Assistant configuration plus two router settings - but it took three
  separate obstacles to get working, and each one is worth knowing about.

  | | |
  |---|---|
  | URL | `https://ha.artofme.eu` - port 443 |
  | Certificate | `/ssl/fullchain.pem`, key `/ssl/privkey.pem` |
  | Issuer | Let's Encrypt, ECDSA, ~90 days |
  | Challenge | DNS-01 through the Cloudflare API - **no port is opened** |
  | Add-on | `core_letsencrypt`, `challenge: dns`, `provider: dns-cloudflare` |
  | Verified | `curl` with no `-k` returns `ssl_verify_result=0` |

  A self-signed certificate was set up first and then replaced. Its files are
  kept as `/ssl/fullchain.pem.selfsigned` and `/ssl/privkey.pem.selfsigned`, and
  `Documentation/tools/gencert.py` still generates that kind if it is ever
  needed again. The trusted certificate removed the one real drawback of the
  self-signed one: **a Chromecast cannot accept a certificate**, so TTS and
  local media pushed from Home Assistant to a Cast device failed. That now
  works.

  **The Cloudflare API token is for the add-on, not for a person.** The add-on
  runs on the board and calls Cloudflare itself at every renewal, unattended, so
  a connector or a browser session cannot stand in for it. Scope it narrowly:
  **Zone:DNS:Edit plus Zone:Zone:Read, on that one zone only**, no expiration.
  Both permissions are needed - DNS:Edit alone fails, because certbot first has
  to look up the zone id. No expiration is deliberate: renewal is unattended,
  and an expired token would fail silently until the certificate itself ran out.

  **Renewal is not automatic.** The add-on is a one-shot: it runs certbot and
  exits. The automation `letsencrypt_renew_certificate` starts it on the first
  of each month and then restarts Core. The restart is the part that is easy to
  forget - certbot writes the new files, but Home Assistant read the certificate
  into memory when its web server started and serves the old one until it
  restarts. certbot only renews inside the last 30 days, so running monthly is
  idempotent; most months it checks and does nothing.

  ### Why a DNS record was not enough

  The certificate only needs the TXT record that the add-on creates and deletes
  by itself. An `A` record is needed separately, so that the name resolves to
  the board. `ha.artofme.eu A 192.168.5.51`, **DNS only** - Cloudflare detects
  the private address and labels it `DNS only - reserved IP`, refusing to proxy
  it, which is the wanted behaviour.

  That record alone did not work, and the reason is worth remembering:
  **AdGuard DNS refuses to return a private address for a public domain.** That
  is DNS rebinding protection, a real security feature, not a fault. The router
  was handing out `94.140.14.14` / `94.140.15.15` to every device, so nothing in
  the house could resolve the name. Measured at the time:

  | Resolver | `ha.artofme.eu` | `doubleclick.net` |
  |---|---|---|
  | AdGuard `94.140.14.14` | NXDOMAIN | `0.0.0.0` (blocked) |
  | ISP `212.39.90.52` | 192.168.5.51 | three real addresses |
  | Router `192.168.5.1` (after the work below) | 192.168.5.51 | `::` (still blocked) |

  Dropping AdGuard would have fixed resolution in one step and was rejected on
  purpose: it filters ads and trackers for every device in the house, including
  the televisions, where no blocker can be installed. The router keeps that
  intact and overrides exactly one name.

  ### The MikroTik changes

  Three settings on the hAP ac (RouterOS 6.48.6, `192.168.5.1`):

  1. **IP > DNS > Static**: `ha.artofme.eu` -> `192.168.5.51`.
  2. **IP > DNS**: `Servers` = `94.140.14.14`, `94.140.15.15` and
     **Allow Remote Requests** on. Setting the upstream servers explicitly is
     what preserves AdGuard filtering - without it the router would have fallen
     back to its dynamic ISP servers (`212.39.90.52/53`), which filter nothing,
     and pointing the house at the router would have silently disabled ad
     blocking everywhere.
  3. **IP > DHCP Server > Networks**: `DNS Servers` = `192.168.5.1`, so clients
     ask the router instead of AdGuard directly.

  **A missing firewall rule had to be fixed first.** After step 2 the router
  answered the static entry but timed out on everything else. The filter list
  had no rule accepting `established,related`, and rule `drop input !LAN` at the
  end discarded the replies to the router's *own* queries. It had never shown up
  because the router had never needed to resolve anything for itself - the
  clients were talking to AdGuard directly. Added as an `input` chain rule,
  `action=accept connection-state=established,related`, placed **above** the
  drop. That is the canonical first rule of a stateful firewall and its absence
  was a gap, not a deliberate choice.

  ### internal_url, and the repair that complains about it

  Settings > System > Network > Home Assistant URL > Local network must be set
  to `https://ha.artofme.eu` with *Automatic* turned off. With a certificate
  configured and no URL set, Home Assistant raises the repair
  `ssl_configured_without_configured_urls`. The condition, in
  `components/http/__init__.py`, is:

  ```python
  ssl_certificate is not None
  and (hass.config.external_url or hass.config.internal_url) is None
  ```

  so setting the internal URL alone satisfies it - the external URL may stay
  empty, which is right for a LAN-only setup. The check runs once, on
  `EVENT_HOMEASSISTANT_START`, so the repair clears on the next restart rather
  than immediately. The entry lingers in `.storage/repairs.issue_registry` as
  history even after the UI stops showing it; trust the UI, not that file.

  ### Two UI traps in this flow

  Both cost time and both look like the setting simply did not save:

  * Under **HTTP server**, *Save* only opens a confirmation dialog. Nothing is
    written until **Save and restart** is clicked.
  * Under **Home Assistant URL**, the orange "Invalid local network URL" warning
    disappears the moment a valid URL is typed, and the card shrinks - so the
    *Save* button moves up by about 90 px. A click aimed at where it used to be
    lands on empty space and nothing happens, silently.

  There is also a safety net worth knowing: a changed HTTP setting is written to
  `pending` in `.storage/http`, not to `stable`, and is **discarded after five
  minutes** unless Home Assistant is confirmed reachable on the new port by a
  browser actually loading the UI. A successful `curl` does not count.

* **The bathroom Shelly pair is linked device-to-device, not through Home
  Assistant.** `192.168.5.10` (Shelly Plus 1, sink light, wall button) and
  `192.168.5.71` (Shelly Plus 2PM, main light, two PIR sensors) each hold
  webhooks pointing at the other's `/relay/0?turn=on|off`. That lives on the
  devices, so it keeps working while Home Assistant is down, updating, or being
  reflashed. There is no runaway loop, because a webhook that sets an already-on
  relay produces no state change and therefore no new event.
* **`media_player.turn_off` must target the SoundTouch entity.** One speaker
  appears as three entities - `music_assistant`, `soundtouch` and `dlna_dmr` -
  and only the `soundtouch` one supports `turn_off`. Pointed at the Music
  Assistant entity it raises
  `Entity ... does not support action media_player.turn_off` on every call, and
  `continue_on_error: true` does **not** suppress that.
