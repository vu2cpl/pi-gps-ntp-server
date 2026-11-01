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
| `MQTT_USER` | publisher + plugin (auth) | *(empty = anonymous)* |
| `MQTT_PASS` | publisher + plugin (auth) | *(empty)* |
| `MQTT_PORT` | publisher + plugin | *(empty = 1883)* |
| `MQTT_CAFILE` | publisher + plugin (TLS) | *(empty = plain MQTT)* |
| `NODE_RED_URL` | plugin (dropdown link only) | `http://192.168.1.169:1880/ui` |

If the broker requires auth, set `MQTT_USER` / `MQTT_PASS` (empty user ⇒
anonymous connect). Because they go in `/etc/cron.d/gpsntp-mqtt` with the
password in the clear, `install.sh` sets that file to `chmod 600`.

For the Pi-side cron job, set these as additional env lines at the top
of `/etc/cron.d/gpsntp-mqtt` (alongside the existing `SHELL=` and
`PATH=` lines). **For the SwiftBar plugin**, SwiftBar doesn't inherit
the shell env reliably, so the plugin sources
`~/.config/vu2cpl-shack.env` (chmod 600) for `MQTT_USER`/`MQTT_PASS`
(and optionally `MQTT_BROKER`/`MQTT_TOPIC`). The plugin reads with the
`svc` account since the shack broker requires auth:

```bash
mkdir -p ~/.config
printf 'MQTT_BROKER=192.168.1.169\nMQTT_USER=svc\nMQTT_PASS=<svc-password>\n' > ~/.config/vu2cpl-shack.env
chmod 600 ~/.config/vu2cpl-shack.env
```

`install.sh` asks for all of these on both the Pi and the Mac, and writes
the cron env for you. On the Mac it updates only the `MQTT_*` lines of
`~/.config/vu2cpl-shack.env`. Other keys in that shared file (`HA_*`,
`UNIFI_*`, ...) are kept, and the previous file is saved as `.bak`.

## Broker with TLS (optional)

MQTT passwords over plain port 1883 cross the LAN in clear. If the broker
is yours to configure, a reference setup lives in
[`mosquitto/`](mosquitto/):

- [`shack-tls.conf`](mosquitto/shack-tls.conf): anonymous off, a
  loopback-only plain listener for a publisher on the broker's own Pi,
  and **8883 with TLS** for everything on the LAN.
- [`acl.example`](mosquitto/acl.example): one account per client, the
  publisher write-only and the SwiftBar plugin read-only.

A private CA plus a server certificate for the broker's addresses (put
every IP / name clients use in `subjectAltName`):

```bash
cd /etc/mosquitto/certs
sudo openssl ecparam -name prime256v1 -genkey -noout -out ca.key
sudo openssl req -x509 -new -key ca.key -sha256 -days 3650 -subj "/CN=Shack MQTT CA" \
  -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" -out ca.crt
sudo openssl ecparam -name prime256v1 -genkey -noout -out server.key
sudo openssl req -new -key server.key -subj "/CN=broker" -out server.csr
printf 'basicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\nsubjectAltName=IP:192.168.1.169,DNS:mqttbroker.shack\n' | \
  sudo openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 1825 -sha256 -extfile /dev/stdin -out server.crt
sudo chown mosquitto:mosquitto server.key && sudo chmod 600 server.key ca.key
```

Accounts: `sudo mosquitto_passwd -c /etc/mosquitto/passwd gpsntp-pub` (it
prompts; drop `-c` for the second user), then `chown mosquitto:mosquitto`
and `chmod 600`. Copy `ca.crt` to each LAN client and set `MQTT_PORT=8883`
and `MQTT_CAFILE=<path to ca.crt>`.

Check from a client: `openssl s_client -connect <broker>:8883 -CAfile ca.crt`
should end in `Verify return code: 0 (ok)`.

**Keeping passwords off the process list.** `MQTT_PASS` ends up on
`mosquitto_pub` / `mosquitto_sub`'s command line, where `ps` can see it
for a moment. The clients also read default options from a per-user file,
`~/.config/mosquitto_pub` and `~/.config/mosquitto_sub` (root's for the
cron job), one option per line. Leave `MQTT_USER` / `MQTT_PASS` /
`MQTT_PORT` / `MQTT_CAFILE` empty and put them there instead (chmod 600):

```
-p 8883
--cafile /Users/you/.config/mqtt-ca.crt
-u swiftbar
-P <password>
```

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

### Dashboard theme

The `chrony-card-template.html` and the `node-red-flow.json` snippet
target the **GitHub-dark palette** used across the rest of the VU2CPL
shack dashboard (`vu2cpl-shack` repo):

| Token | Value |
|-------|-------|
| Page / app background | `#0d1117` |
| Card background       | `#161b22` |
| Border / row divider  | `#30363d` |
| Foreground text       | `#c9d1d9` |
| Muted / secondary     | `#8b949e` |
| Accent (info)         | `#58a6ff` |
| LED green (good)      | `#3fb950` |
| LED amber (warn)      | `#e3b341` |
| LED red (bad)         | `#f85149` |

The card uses vanilla JS DOM updates (`getElementById` +
`scope.$watch('msg', …)` — no AngularJS interpolation bindings),
matching the convention used by other custom widgets in
`vu2cpl-shack`. The bundled `ui_group` has `disp: false` (the
template provides its own title) and is sized to width 10.

### Upgrading an existing chrony card

If you already have the older (teal `#5cd0d6`) version deployed and
just want the new palette without re-importing the whole flow:

1. Open the existing `Chrony status card` ui_template node in the
   Node-RED editor.
2. Select-all in the Template body and paste in the full contents of
   `dashboard/chrony-card-template.html`. Done → Deploy.
3. *(Optional)* Open the hosting `ui_group` properties — set Display
   = false (the template carries its own title) and Width = 10 to
   match the shipped snippet.

Position / group membership are preserved by the in-place template
edit — only the rendering style changes.

## Mac menu-bar install

```sh
brew install mosquitto
brew install --cask swiftbar
# For the in-dropdown offset sparkline (optional — plugin works without it):
python3 -m pip install --user Pillow
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
