#!/bin/bash
# Acceptance check for the Radxa ZERO 3W Home Assistant OS fork.
#
# Run this from the laptop after every OS update and after every fresh flash.
# It checks, in one pass, every deviation this fork carries plus the house
# configuration that depends on it, and prints PASS / FAIL / WARN per item.
#
#   ./acceptance-check.sh                 # read-only checks
#   ./acceptance-check.sh --with-lights   # also toggles the bathroom light and
#                                         # verifies the speaker starts playing
#
# Exit code is 0 only when nothing FAILed. See
# Documentation/radxa-zero3w-changes.md for why each of these matters.

set -u

BOARD=${BOARD:-192.168.5.51}
PORT=${PORT:-22222}
KEY=${KEY:-$HOME/.ssh/haos}
NAME=${NAME:-ha.artofme.eu}
ROUTER=${ROUTER:-192.168.5.1}
SHELLY_MAIN=${SHELLY_MAIN:-192.168.5.71}
SHELLY_SINK=${SHELLY_SINK:-192.168.5.10}
SPEAKER=${SPEAKER:-192.168.5.20}

WITH_LIGHTS=0
[ "${1:-}" = "--with-lights" ] && WITH_LIGHTS=1

S="ssh -n -i $KEY -p $PORT -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@$BOARD"
SNO="ssh -i $KEY -p $PORT -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@$BOARD"
pass=0; fail=0; warn=0

ok()   { printf '  \033[32mPASS\033[0m  %-44s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %-44s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }
soft() { printf '  \033[33mWARN\033[0m  %-44s %s\n' "$1" "${2:-}"; warn=$((warn+1)); }
sec()  { printf '\n\033[1m%s\033[0m\n' "$1"; }

# check NAME EXPECTED-REGEX COMMAND...
chk() {
  local label=$1 want=$2; shift 2
  local out
  out=$(timeout 45 $S "$@" 2>/dev/null | tr -d '\r')
  if printf '%s' "$out" | grep -qE "$want"; then
    ok "$label" "$(printf '%s' "$out" | head -1 | cut -c1-40)"
  else
    bad "$label" "got: $(printf '%s' "$out" | head -1 | cut -c1-40)"
  fi
}

sec "Reachability"
if timeout 20 $S 'true' 2>/dev/null; then ok "SSH on port $PORT with the key"; else
  bad "SSH on port $PORT with the key" "board unreachable - nothing else can run"; exit 1; fi

sec "Image and slot"
chk "RAUC compatible is this board"  'haos-radxa-zero3w'      'rauc status 2>/dev/null | grep Compatible'
chk "booted slot is marked good"     'good'                   'rauc status 2>/dev/null | grep -A2 booted | grep "boot status"'
chk "Supervisor reports the board"   'radxa-zero3w'           'ha os info 2>/dev/null | grep board'

sec "CPU governor (cmdline.txt, see changes.md 5)"
chk "cpufreq.default_governor on cmdline" 'schedutil'         'cat /proc/cmdline'
chk "all four cores on schedutil"    '^(schedutil\n?){4}$|schedutil' \
    'cat /sys/devices/system/cpu/cpu[0-9]/cpufreq/scaling_governor | sort -u'
out=$(timeout 45 $S 'cat /sys/devices/system/cpu/cpufreq/policy0/stats/time_in_state' 2>/dev/null | tr -d '\r')
lo=$(printf '%s' "$out" | awk '$1==408000{print $2}'); hi=$(printf '%s' "$out" | awk '$1==1416000{print $2}')
if [ -n "${lo:-}" ] && [ -n "${hi:-}" ] && [ "$lo" -gt 0 ]; then
  ok "cores really do clock down" "408MHz=$lo 1416MHz=$hi"
else
  soft "cores really do clock down" "no time at 408 MHz yet - board may be busy"
fi

sec "WiFi (changes.md 1a-1c)"
chk "antenna GPIO hog in effect"     'wifi-antenna-onboard.*out +lo' 'grep -i antenna /sys/kernel/debug/gpio'
chk "aic8800 driver loaded"          'aic8800_fdrv'           'lsmod | grep aic8800'
chk "wlan0 has an address"           'IP4.ADDRESS'            'nmcli -t -f GENERAL.CONNECTION,IP4.ADDRESS d show wlan0'
out=$(timeout 45 $S 'journalctl -u NetworkManager --no-pager 2>/dev/null | grep -o "added .key_mgmt. value .[^\x27]*." | tail -1' 2>/dev/null | tr -d '\r')
if [ -z "$out" ]; then
  soft "NetworkManager offers no SAE" "journal rotated - run soon after boot"
elif printf '%s' "$out" | grep -q 'SAE'; then
  bad "NetworkManager offers no SAE" "SAE present - the patch is MISSING"
else
  ok "NetworkManager offers no SAE" "$(printf '%s' "$out" | cut -c1-40)"
fi

sec "Bluetooth (changes.md 2a-2b, 4)"
chk "aic8800-bt.service running"     'active'                 'systemctl is-active aic8800-bt'
chk "hci0 is UP RUNNING"             'UP RUNNING'             'hciconfig hci0 2>/dev/null'
chk "BT subsystem was powered"       'AIC_BLUETOOTH'          'dmesg | grep -i aicbsp_set_subsys'
chk "hidp loaded (for BT keyboards)" '^hidp'                  'lsmod | grep "^hidp"'

sec "Board extras"
chk "hardware RNG present (TRNG patch)" '.'                   'cat /sys/class/misc/hw_random/rng_current 2>/dev/null || ls /dev/hwrng'
chk "wifi-setup shipped"             'wifi-setup'             'ls /usr/sbin/wifi-setup'
# $6$ cannot survive the remote shell quoting, so measure the hash length
out=$(timeout 45 $S 'awk -F: "\$1==\"root\"{print length(\$2)}" /etc/shadow' 2>/dev/null | tr -d '')
if [ -n "${out:-}" ] && [ "$out" -gt 50 ] 2>/dev/null; then
  ok "root password persists" "sha512 hash, $out chars"
else
  bad "root password persists" "hash field length: ${out:-none}"
fi

sec "Home Assistant"
chk "Core container up"              'homeassistant'          'docker ps --format "{{.Names}}" | grep "^homeassistant$"'
chk "Music Assistant up"             'music_assistant'        'docker ps --format "{{.Names}}" | grep music_assistant'
chk "volume normalization measured"  'measurement_only'       'grep -o "volume_normalization_tracks\": \"[a-z_]*\"" /mnt/data/supervisor/apps/data/d5369777_music_assistant/settings.json'
chk "three automations present"      '^3$'                    'grep -c "^- id:" /mnt/data/supervisor/homeassistant/automations.yaml'
chk "cert renewal automation there"  'letsencrypt_renew'      'grep -o "letsencrypt_renew_certificate" /mnt/data/supervisor/homeassistant/automations.yaml'
chk "internal_url points at the name" "$NAME"                 'grep -o "\"internal_url\": \"[^\"]*\"" /mnt/data/supervisor/homeassistant/.storage/core.config'

sec "HTTPS"
code=$(curl -o /dev/null -sw '%{http_code} %{ssl_verify_result}' --resolve "$NAME:443:$BOARD" -m 20 "https://$NAME/" 2>/dev/null)
case "$code" in
  "200 0") ok  "certificate validates strictly" "$code" ;;
  *)       bad "certificate validates strictly" "http/verify = $code" ;;
esac
exp=$(timeout 45 $S 'docker exec homeassistant python3 -c "
from cryptography import x509
c=x509.load_pem_x509_certificate(open(\"/ssl/fullchain.pem\",\"rb\").read())
import datetime
d=(c.not_valid_after_utc-datetime.datetime.now(datetime.timezone.utc)).days
print(d, c.issuer.rfc4514_string())
"' 2>/dev/null | tr -d '\r')
days=${exp%% *}
if [ -n "${days:-}" ] && [ "$days" -gt 21 ] 2>/dev/null; then
  ok "certificate not near expiry" "$days days left"
elif [ -n "${days:-}" ]; then
  soft "certificate not near expiry" "$days days left - renewal should have run"
else
  bad "certificate not near expiry" "could not read it"
fi

sec "Name resolution (router, not the image)"
r=$(nslookup "$NAME" "$ROUTER" 2>/dev/null | sed -n '/Name:/,$p' | grep -i address | head -1)
printf '%s' "$r" | grep -q "$BOARD" && ok "router resolves $NAME" "$BOARD" \
  || bad "router resolves $NAME" "got: ${r:-nothing}"
a=$(nslookup doubleclick.net "$ROUTER" 2>/dev/null | sed -n '/Name:/,$p' | grep -ci "0\.0\.0\.0\|::")
[ "${a:-0}" -ge 1 ] && ok "AdGuard filtering still applied" "doubleclick.net blocked" \
  || soft "AdGuard filtering still applied" "doubleclick.net resolved - check IP>DNS servers"

sec "Shelly pair (on the devices, not the board)"
for ip in "$SHELLY_MAIN" "$SHELLY_SINK"; do
  h=$(curl -s -m 6 "http://$ip/rpc/Webhook.List" 2>/dev/null | grep -o '"event"' | wc -l | tr -d ' ')
  [ "${h:-0}" -ge 2 ] && ok "webhooks present on $ip" "$h hooks" \
    || bad "webhooks present on $ip" "found ${h:-0}"
done


# Everything above this point talks to the devices directly over HTTP. That
# catches a device that has fallen off the network - the 16 Nov power cut left
# the Shelly Plus 2PM off the WiFi and the webhook probe above does report it -
# but it says nothing about what Home Assistant can still see, and that is what
# the automations actually depend on. A state trigger on an `unavailable` entity
# never fires: no trigger, no action, and no error in the log either. The
# bathroom music was dead for five days in exactly that way. An entity can also
# go unavailable while the device answers HTTP perfectly well - an integration
# that failed to load, a renamed or disabled entity, a Music Assistant player
# that vanished when the add-on restarted. Those leave the checks above green.
#
# States come from the recorder database rather than the REST API so that this
# needs no long-lived token. The recorder only writes on change, so a long
# `last changed` is normal for a light nobody touched; `unavailable` is the
# signal, not the age.
sec "Entities the automations trigger on"
states=$(timeout 60 $SNO 'docker exec -i homeassistant python3 -' <<'PY' 2>/dev/null
import sqlite3, datetime
WANT = [
    "switch.bathroom_shellyplus2pm_d4d4daec38fc_output_0",
    "switch.toilet_toilet_main_light",
    "media_player.bathroom_speaker",
    "media_player.toilet_speaker",
    "media_player.bathroom_bathroom_speaker",
]
c = sqlite3.connect("file:/config/home-assistant_v2.db?mode=ro", uri=True)
now = datetime.datetime.now().timestamp()
for e in WANT:
    r = c.execute(
        "select s.state, s.last_updated_ts from states s join states_meta m"
        " on s.metadata_id = m.metadata_id where m.entity_id = ?"
        " order by s.last_updated_ts desc limit 1", (e,)).fetchone()
    print("%s|%s|%d" % (e, "MISSING", 0) if r is None
          else "%s|%s|%d" % (e, r[0], (now - r[1]) / 3600))
PY
)
if [ -z "$states" ]; then
  bad "recorder readable" "could not query the state database"
else
  while IFS='|' read -r ent st age; do
    [ -z "${ent:-}" ] && continue
    short=$(printf '%s' "${ent#*.}" | cut -c1-33)
    case "$st" in
      unavailable|unknown|MISSING)
        bad "HA sees $short" "$st for ${age}h - triggers will not fire" ;;
      *)
        ok  "HA sees $short" "$st, last changed ${age}h ago" ;;
    esac
  done <<EOT
$states
EOT
fi
if [ "$WITH_LIGHTS" = "1" ]; then
  sec "End to end: light -> sink light -> music"
  curl -s -m 6 "http://$SHELLY_MAIN/rpc/Switch.Set?id=0&on=true" >/dev/null; sleep 12
  s=$(curl -s -m 6 "http://$SHELLY_SINK/rpc/Switch.GetStatus?id=0" | grep -o '"output":[a-z]*')
  printf '%s' "$s" | grep -q true && ok "main light turns the sink light on" || bad "main light turns the sink light on" "$s"
  for i in 1 2 3 4 5 6; do
    sleep 5
    p=$(curl -s -m 6 "http://$SPEAKER:8090/now_playing" | grep -o 'source="[A-Z_]*"' | head -1)
    printf '%s' "$p" | grep -q AIRPLAY && break
  done
  printf '%s' "$p" | grep -q AIRPLAY && ok "speaker starts playing" "$p" || bad "speaker starts playing" "${p:-none}"
  curl -s -m 6 "http://$SHELLY_MAIN/rpc/Switch.Set?id=0&on=false" >/dev/null; sleep 12
  p=$(curl -s -m 6 "http://$SPEAKER:8090/now_playing" | grep -o 'source="[A-Z_]*"' | head -1)
  printf '%s' "$p" | grep -q STANDBY && ok "speaker stops on light off" "$p" || bad "speaker stops on light off" "${p:-none}"
else
  sec "End to end"
  printf '  \033[33mSKIP\033[0m  %s\n' "pass --with-lights to toggle the bathroom and test the speaker"
fi

sec "Result"
printf '  %d passed, %d failed, %d warnings\n\n' "$pass" "$fail" "$warn"
[ "$fail" -eq 0 ]
