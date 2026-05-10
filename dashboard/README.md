# GPS NTP — MQTT status broadcast

Publishes a live snapshot of chrony + gpsd state from the Pi to the shack
MQTT broker (192.168.1.169) once a minute. Two consumers in this folder:

- a Node-RED dashboard tab (`node-red-flow.json`)
- a macOS menu-bar widget (`swiftbar/gpsntp.30s.sh`)

Both subscribe to the same retained topic `shack/gpsntp/chrony`, so they
get the latest snapshot the moment they connect.

## Topic / payload

`shack/gpsntp/chrony` — retained, JSON, e.g.:

```json
{
  "host": "gpsntp",
  "ts": 1747032600,
  "ref_id": "50505300",
  "ref_name": "PPS",
  "stratum": 1,
  "system_time_offset_s": -3.5e-08,
  "last_offset_s": 1.52e-07,
  "rms_offset_s": 2.1e-07,
  "freq_ppm": 0.142,
  "skew_ppm": 0.009,
  "root_delay_s": 0.0,
  "root_dispersion_s": 1.8e-05,
  "leap": "Normal",
  "fix_mode": 3,
  "sat_used": 9,
  "sat_seen": 12
}
```

## Configuration overrides

All three artifacts honour environment variables so you can move the
broker or topic without editing files:

| Variable | Used by | Default |
|---|---|---|
| `MQTT_BROKER` | publisher + plugin | `192.168.1.169` |
| `MQTT_TOPIC` | publisher + plugin | `shack/gpsntp/chrony` |
| `NODE_RED_URL` | plugin (dropdown link only) | `http://192.168.1.169:1880/ui` |

For the Pi-side cron job, set these as additional env lines at the top
of `/etc/cron.d/gpsntp-mqtt` (alongside the existing `SHELL=` and
`PATH=` lines). For SwiftBar, the plugin will pick up exported env
vars from your shell, or you can wrap the plugin in a parent script
that exports them.

## Pi-side install

Once SSH to `vu2cpl@gpsntp.local` works:

```sh
# from this repo on the Mac:
scp dashboard/gpsntp-mqtt-publish.sh vu2cpl@gpsntp.local:/tmp/
scp dashboard/cron.d-gpsntp-mqtt     vu2cpl@gpsntp.local:/tmp/

# on the Pi:
sudo apt install -y mosquitto-clients jq
sudo install -m 0755 /tmp/gpsntp-mqtt-publish.sh /usr/local/bin/
sudo install -m 0644 /tmp/cron.d-gpsntp-mqtt    /etc/cron.d/gpsntp-mqtt

# smoke test:
sudo /usr/local/bin/gpsntp-mqtt-publish.sh
mosquitto_sub -h 192.168.1.169 -t shack/gpsntp/chrony -C 1
```

The smoke-test should print the JSON payload immediately (because of the
retained flag).

### Verifying cron is firing

The manual smoke-test only proves the script works once. To confirm
cron is actually running it every minute, sample `ts` twice ~90s
apart:

```sh
mosquitto_sub -h 192.168.1.169 -t shack/gpsntp/chrony -C 1 | jq .ts
sleep 90
mosquitto_sub -h 192.168.1.169 -t shack/gpsntp/chrony -C 1 | jq .ts
```

If the second value is ~60 larger than the first, cron is firing as
expected. If it never advances, check `journalctl -u cron` on the Pi.

## Node-RED dashboard install

In the Node-RED editor at `http://192.168.1.169:1880`:

1. Hamburger menu → Import → paste the contents of
   `node-red-flow.json` → Import.
2. Deploy.
3. Open `http://192.168.1.169:1880/ui` — there is now a "GPS NTP" tab
   with reference + offset gauge + sat info.

Prereq: `node-red-dashboard` palette must be installed
(Manage palette → Install → `node-red-dashboard`).

> **Gotcha if you ever rebuild the flow by hand:** the core MQTT input
> node's type string is `"mqtt in"` (with a space), not `mqtt-in`.
> The shipped flow JSON has the right name; only the broker config
> node uses the hyphen (`mqtt-broker`). Get this wrong and Node-RED
> rejects the flow at import time as "unknown types".

## Mac menu-bar install

```sh
brew install mosquitto
brew install --cask swiftbar
```

Launch SwiftBar once and pick a plugins folder during the first-launch
wizard. Then install the plugin into **whichever folder you actually
chose** (the default and a custom folder are both fine — install where
SwiftBar is configured to look):

```sh
# Discover SwiftBar's configured plugins folder:
PLUGINS_DIR="$(defaults read com.ameba.SwiftBar PluginDirectory)"
echo "$PLUGINS_DIR"

# Install (quote the path — it may contain spaces):
install -m 0755 dashboard/swiftbar/gpsntp.30s.sh "$PLUGINS_DIR/"

# In SwiftBar's menu: "Refresh All".
```

If you used the default, that path is
`~/Library/Application Support/SwiftBar/Plugins`.

The menu bar should now show e.g. `🛰 S1  -35 ns`. Click for the full
dropdown (RMS, skew, root dispersion, leap, sat count, last update).
