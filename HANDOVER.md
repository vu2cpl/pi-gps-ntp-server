# Pi GPS NTP Server — Handover

## Status

**Operational.** Stratum-1 GPS-disciplined NTP server running on a
Raspberry Pi 3B at `gpsntp.local` (192.168.1.158), serving the shack LAN.
First brought up 2026-05-09 on a QLG1 tap; GPS source swapped to a
dedicated **u-blox NEO-M8N** on 2026-05-11 (see "GPS swap" below).

Performance after burn-in (M8N):
- Reference ID: PPS, **Stratum 1**.
- PPS error **±171 ns**, system clock **20 ns** fast of GPS truth.
- Skew **0.004 ppm**. Root dispersion **22 µs**.
- macOS Mac mini disciplined against this server, observed offset
  ~1–4 ms over the LAN (limited by macOS scheduling jitter, not the
  Pi or the network).

For the build procedure that produced this state, see **BUILD.md**.
This file is for context: who, why, what was considered, and what was
decided.

## Clients on the new VLANs were silently dropped — FIXED 2026-09-10

**Symptom.** From the Mac mini (now 192.168.10.226 on the Trusted VLAN
since the 2026-08-18 split) `sntp 192.168.1.158` timed out and Apple's
`timed` logged "NTP failed 4 times" against `gpsntp.local`, although the
name resolved, ping was 0.8 ms and the UniFi zone policy for Trusted is
"Allow anywhere". Noticed while checking a clock-adjustment theory in an
unrelated MSHV thread.

**Cause.** `/etc/chrony/chrony.conf` still had only `allow 192.168.1.0/24`
(+ `allow fd00::/8`). chronyd does not answer sources outside `allow` and
says nothing about it. `sudo chronyc clients` listed only 192.168.1.x
hosts — so for three weeks **no Mac on VLAN 10 and no ESP on VLAN 30 got
GPS time**, whatever the router permitted (`vlan-setup`'s rule "IoT →
.158 udp/123 Allow" was in place; its migration checks tested the mDNS
name, not an NTP reply). The installer's re-run path also skipped the
allow block whenever the refclock lines already existed.

**Fix (on the Pi, 14:01 IST, Manoj's go).** Backup
`/etc/chrony/chrony.conf.bak-20260910-140141`, then `allow
192.168.10.0/24` and `allow 192.168.30.0/24` inserted after the existing
line, `systemctl restart chrony`. Verified: a raw NTP packet from the Mac
answered within 1.2 ms, `sntp` offset −2.5 ms, and `192.168.10.226`
appeared in `chronyc clients` within a minute. PPS re-lock after the
restart takes a few minutes (stratum shows 4 via the pool until then).

**Made persistent here:** `install.sh` now takes a space-separated list
(default = the three shack subnets), writes one `allow` per network, and
on a re-run extends an existing config instead of skipping it; `BUILD.md`
carries the same three lines and the warning; `README.md` says one line
per VLAN.

**Left for Manoj:** the Mac mini runs its own chrony (TimeSync project)
against pool servers AND Apple `timed` against `gpsntp.local` — now that
the Pi answers, both steer the same clock; pick one. And confirm an ESP
on VLAN 30 actually syncs (e.g. `esp8266-gps-ntp` logs) — the allow line
is in, the end-to-end check on the IoT side is not done.

## Health check 2026-11-22 — gpshealth enabled, avahi log spam stopped

Uptime 4 d 11 h (boot 2026-11-17 13:11 IST). chrony and gpsd started
38 s after boot, 0 restarts. Stratum 1 on PPS, offset −1.4 µs,
±443 ns. 45 °C, not throttled. Found and fixed on the Pi (Manoj's go):

1. **`gpshealth.service` was disabled.** The unit and script were in
   place, but `systemctl enable` had never been run, so the monitor did
   not start after a reboot. There were no journal lines and no
   `/tmp/gpshealth.log`. Fixed with `sudo systemctl enable --now gpshealth`.
2. **avahi wrote ~700 warnings per hour.** The journal is RAM-only and
   capped at ~18 MB, so it reached back only ~22 h. Fixed with
   `publish-workstation=no`. See Known gotchas.
3. **The docs said the journal survives reboots.** It doesn't, because
   Pi OS ships `Storage=volatile`. Corrected here and in README.md.

**`NetworkManager-wait-online.service` failed at the 2026-11-17 boot.**
Diagnosed 2026-11-22: it was a power cut, and the router was still booting.
NTP was not affected. The wait limit is now 300 s instead of 60 s. See
Known gotchas.

**gpsntp now runs on a suspect power cable (10:15 IST).** The idle Pi 3B+
(`openwebrxplus`, `.142`) shares gpsntp's 5 V supply and showed constant
under-voltage, while gpsntp did not. To find out whether the 3B+'s cable was
the cause, Manoj swapped the micro-USB cables of the two Pis. gpsntp restarted
at 10:15:29 and came back clean: `throttled=0x0`, PPS at stratum 1,
gpshealth started by itself at boot, and the network wait passed in 10 s. The
3B+ is clean on gpsntp's old cable. **Open item:** check that gpsntp stays at
`throttled=0x0` (`vcgencmd get_throttled`). If it shows under-voltage, the cable
it now has is bad: replace it. The daily shack-health check reports it either
way.

## GPS swap — 2026-05-11

Originally the Pi tapped the QRP Labs **QLG1** that was already feeding
the U3S beacon, via voltage dividers on the QLG1's unused 6-way header
(see Decision #5 below). On 2026-05-11 the GPS was swapped to a
dedicated **u-blox NEO-M8N** (GY-NEO8MV2 breakout) for two reasons:

1. The U3S is being retired, so the "share the QLG1 to avoid buying
   another GPS" rationale evaporated.
2. A dedicated 3.3 V-native GPS gives the Pi clean signal lines without
   the voltage-divider stack, and removes any future RFI-vs-U3S risk
   entirely.

The Pi-side software stack didn't change. The M8N's TX feeds the same
PL011 RX on GPIO15, and its PPS feeds the same GPIO18, so the existing
`pps-gpio,gpiopin=18` overlay, `/etc/default/gpsd`, and chrony refclock
config all just kept working — the swap was a pure hardware change.

## Who the user is

- Manoj (VU2CPL), ham radio operator, Mac-based shack.
- Runs **SkimServer Mac** (separate project) — a native macOS replacement
  for CW Skimmer Server, decoding CW + FT8/FT4 from a Red Pitaya HPSDR
  receiver and uploading spots to RBN and PSK Reporter.
- Used to run a **QRP Labs U3S** WSPR/QRSS beacon transmitter with a
  **QLG1** GPS feeding it (MediaTek chipset, 10 ns RMS PPS, sky-view
  antenna). The U3S is being retired and as of the 2026-05-11 swap the
  QLG1 no longer feeds the Pi either — the Pi now has its own dedicated
  NEO-M8N GPS.
- This project gives the shack a **good local time source** for
  SkimServer, the U3S, the Red Pitaya, and any other shack PCs.

## Goal (achieved)

A small, always-on GPS-disciplined NTP server that serves time to the
whole shack LAN. Microsecond-class accuracy on the LAN; sub-µs locally
on the Pi.

## Decisions made (and why), in order

### 1. Mac menu-bar GPS app — rejected
USB GPS stack jitter caps accuracy at ~100–500 ms; can't easily get PPS
into macOS userspace; only fixes one machine.

### 2. Trusting macOS NTP against pool servers — rejected
Fine for FT8 (<2 s) but not LAN-wide and not independent of internet.

### 3. ESP32 + NEO-M8N firmware project — rejected (originally chosen)
Sound on its own merits — bare-metal PPS interrupt is deterministic —
but loses to a Pi on every dimension that matters once a Pi is on the
table:
- Software stack maturity: chrony + gpsd + kernel PPS is what most
  public stratum-1 servers run. Hobby-grade ESP32 NTP code re-implements
  leap seconds, holdover, multi-source comparison, and stratum honesty —
  all already correct in chrony.
- Network timestamping: Linux kernel timestamps NTP packets at NIC
  level; ESP32 lwIP timestamps in userspace. Client-visible accuracy
  ends up better on the Pi.
- Wired Ethernet by default on every Pi.
- Debuggability: SSH + `chronyc` + `gpsmon` vs serial console + logic
  analyzer.

ESP32 remains the right answer if the goal is "learn embedded firmware";
not the right answer for "best LAN time source with least custom code."

### 4. Raspberry Pi 3B + chrony + gpsd — chosen
User had an unused Pi 3B on hand. No purchase needed.

### 5. Tap the QLG1 already feeding the U3S — chosen (initially)
Instead of buying a separate GPS, the first build tapped TXD, PPS, and
GND off the QLG1's unused **6-way connector** (the 4-way was already in
use to the U3S; we left that alone). Both U3S and Pi consumed the GPS
in parallel; one antenna, one GPS module.

**Wiring trap solved:** QLG1 outputs are 5 V logic (74ACT08 buffers
from +5 V rail). Pi GPIO is not 5 V tolerant. Solution: 2.2 kΩ + 3.3 kΩ
voltage dividers on TXD and PPS, dropping 5 V → 3.0 V.

This decision was reversed two days later — see Decision #6.

### 6. Swap to dedicated NEO-M8N — chosen (2026-05-11)
The U3S is being retired; once it's gone the QLG1 isn't holding anything
together. Rather than leave the Pi hanging off the QLG1 (and the
voltage-divider breadboard), the GPS was swapped to a dedicated
**GY-NEO8MV2** (u-blox NEO-M8N) breakout. The M8N is 3.3 V-native, so
the dividers came out; TX goes directly to GPIO15, PPS directly to
GPIO18 — same Pi-side pinout, no software changes. The QLG1 has been
retained as a stand-alone unit on its old antenna in case the U3S's
replacement wants a GPS source later, but it's no longer wired to the
Pi or to anything actively transmitting.

## Hardware summary (as built)

| Item                  | Detail                                          |
|-----------------------|-------------------------------------------------|
| Raspberry Pi 3 Model B | Repurposed, was unused                         |
| microSD card          | 16 GB+, Pi OS Lite 64-bit Trixie                |
| Pi PSU                | 5 V 2.5 A micro-USB                             |
| Ethernet              | Wired into LAN switch, DHCP-assigned 192.168.1.158 |
| **GY-NEO8MV2 (NEO-M8N)** | Dedicated GPS for the Pi (since 2026-05-11). 3.3 V-native TX and PPS, direct to GPIO15/GPIO18. Patch antenna on u.FL pigtail with sky view. |

## OS / software stack (as built)

- **Raspberry Pi OS Lite, 64-bit, Trixie** (Debian 13). Headless install
  via Imager with hostname `gpsntp` and SSH public-key auth.
- `/boot/firmware/config.txt`: `enable_uart=1`, `dtoverlay=disable-bt`
  (frees PL011 from BT for GPIO14/15 use), `dtoverlay=pps-gpio,gpiopin=18`.
- Serial login console disabled via `raspi-config`.
- **gpsd 3.25** parses NMEA from `/dev/serial0` and exports PPS via
  SHM-2. `GPSD_OPTIONS="-n"` so it polls without waiting for clients.
- **Kernel PPS** via `pps-gpio` overlay on GPIO18 → `/dev/pps0`.
- **chrony** with:
  - `refclock SHM 0 refid NMEA offset 0.0 delay 0.2 noselect` — gpsd's
    coarse second-of-time, used only to label which integer second the
    PPS edge belongs to.
  - `refclock PPS /dev/pps0 lock NMEA refid PPS` — the kernel PPS
    device, locked to NMEA's second-numbering. This is the actual time
    source.
  - `allow 192.168.1.0/24` and `allow fd00::/8` — IPv4 LAN + IPv6 ULA.
  - Default Debian pool servers retained for sanity cross-check; once
    PPS is locked, chrony marks them `^-` (not combined).

## Integration with the shack

- **macOS Mac mini (`MiniM4-Pro`):** time server set to `gpsntp.local`
  via `systemsetup -setnetworktimeserver`. `timed` continuously
  disciplines against the Pi.
- **SkimServer Mac:** no code changes. Uses system clock, which `timed`
  is now disciplining against the Pi.
- **U3S:** being retired. Was originally on its own QLG1 connection
  (4-way header), with the Pi sharing via the 6-way tap. After the
  2026-05-11 GPS swap the Pi no longer shares the QLG1 with the U3S —
  the two systems are now electrically independent.
- **rpi-agent monitor:** also installed on this Pi (separate concern,
  part of the wider Node-RED RPi Fleet Monitor). Publishes
  cpu/temp/mem/disk/uptime/ip/status to MQTT broker at 192.168.1.169
  every minute via cron, plus an HTTP endpoint on :7799 for
  reboot/shutdown from the dashboard. Not strictly part of this project
  but lives on the same Pi.
- **chrony status broadcast:** a separate cron job
  (`/usr/local/bin/gpsntp-mqtt-publish.sh`, every minute) snapshots
  `chronyc -c tracking` plus the latest gpsd TPV/SKY and publishes a
  retained JSON message to `shack/gpsntp/chrony` on the same broker.
  **MQTT auth (2026-08-21):** the shack broker now requires
  authentication; this publisher uses the `svc` account, with
  `MQTT_USER`/`MQTT_PASS` set as env lines in `/etc/cron.d/gpsntp-mqtt`
  (chmod 600). `install.sh` prompts for them. Empty ⇒ anonymous.
  **Optional TLS (2026-11-01, PR #1 by Vinod VU3ESV):** the publisher
  and the SwiftBar plugin also take `MQTT_PORT` and `MQTT_CAFILE`
  (e.g. `8883` + the broker's `ca.crt`). Both empty ⇒ plain MQTT on
  1883, exactly as before. A reference TLS broker config is in
  `dashboard/mosquitto/` (`shack-tls.conf`, `acl.example`). On the
  Mac, `install.sh` now rewrites only the `MQTT_*` lines of the shared
  `~/.config/vu2cpl-shack.env` and keeps every other key (`HA_*`,
  `UNIFI_*`, …), with the old file saved as `.bak`. Nothing already
  installed changes until `install.sh` is re-run.
  Two consumers: a "GPS NTP" tab in the Node-RED dashboard, and a
  macOS SwiftBar menu-bar widget that shows live stratum / offset /
  sat count and is one click away from the dashboard. Scripts, flow
  JSON, and install steps live in **`dashboard/`**.

## Operational checks (if something seems wrong)

```sh
# On the Pi
chronyc tracking          # Reference ID = PPS, Stratum 1, small offset
chronyc sources -v        # PPS should be #*, NMEA #?
gpspipe -w | head -10     # Should see TPV mode 3 + PPS lines
sudo ppstest /dev/pps0    # Should print one line/sec, fractional µs
journalctl -u chrony -n 50
journalctl -u gpsd -n 50

# From the Mac
sntp gpsntp.local                    # Small offset, small dispersion
sudo systemsetup -getnetworktimeserver  # Should report gpsntp.local
```

### `gpshealth` — one-line rolling health monitor

Installed 2026-07-31 at `/home/vu2cpl/bin/gpshealth`, started at boot by
`gpshealth.service` (systemd unit at `/etc/systemd/system/gpshealth.service`,
runs as user `vu2cpl` after `chrony.service` and `gpsd.service`). The unit
was not enabled until 2026-11-22, so before that it did not run after a
reboot. On a rebuild, copy both files and run
`sudo systemctl enable --now gpshealth`. Samples `gpspipe` +
`chronyc tracking` every 30 s, prints one coloured line, and appends it
to `/tmp/gpshealth.log`. systemd also captures stdout to the journal.
Both are RAM-only: `/tmp` is tmpfs, and Pi OS sets the journal to
`Storage=volatile` (capped at ~18 MB, 10 % of `/run`). Both are cleared
on reboot.

```
12:00:18 OK   SVs= 6 mode=3 TDOP=1.54 stratum=1 refid=PPS off=42ns rms=7ns
```

Verdict thresholds:
- **OK** — mode 3, ≥5 SVs, TDOP ≤ 5, `refid=PPS`, stratum 1.
- **WARN** — mode 3 but degraded (few SVs or TDOP > 5).
- **CRIT** — no 3D fix, or chrony has fallen off PPS discipline (refid
  not `PPS`, or stratum > 1).

**Fixed 2026-11-22:** `rms=` used to read field 6 of
`chronyc -c tracking`. That field is *Last offset* (signed), so older log
lines show values like `rms=-2031ns`. The `rms=` line now reads field 7
(RMS offset). Backup of the old script: `~/bin/gpshealth.bak-2026-11-22`.
For reference, the `-c` fields are: 2 refid, 3 stratum, 5 system time
offset, 6 last offset, 7 RMS offset.

Watch live:

```sh
journalctl -u gpshealth -f          # RAM journal, cleared on reboot
tail -f /tmp/gpshealth.log          # tmpfs, cleared on reboot
```

Both the script (`~/bin/gpshealth`) and the systemd unit are Pi-local —
not (yet) checked into this repo. Recreate from HANDOVER + the earlier
Claude session if the Pi is rebuilt.

## Known gotchas

### u.FL antenna joint drifts intermittent

Late July 2026 the Pi went through a two-day period of losing fix
several times a day; each recovery took bringing the antenna outside.
Investigation (`chronyc sources`, per-SV SNR from `$GPGSV`, and DOP)
showed the antenna was uniformly ~10 dB down on mid-elevation SVs and
another ~15 dB down at zenith — RF-path attenuation, not a receiver
problem. Root cause was the **u.FL pigtail-to-antenna micro-connector**
getting flaky (monsoon humidity likely). The fix was to unplug and
re-seat the u.FL — jiggling it during an antenna swap counted as a
reseat too, which is why the symptom kept "coming back" every time the
antenna was moved. When SNRs go soft again in future, reseat the u.FL
first before assuming the module has failed. A dab of self-fusing
silicone tape or a properly-terminated SMA-only run to a rooftop
antenna would make the joint failure-proof.

### `log2ram` will overflow if chrony logs everything

`/var/log` is on **log2ram** (128 MB tmpfs), so any process writing to
`/var/log/*` gets `ENOSPC` once that RAM disk fills — even though the
SD card itself has 24 GB free. `df -h` will look normal for `/`; look
at the `log2ram` row.

During the antenna investigation the chrony config was expanded to
`log measurements statistics tracking refclocks`. The two per-second
streams (`measurements.log`, `refclocks.log`) grow at ~15 MB/day and,
combined with weekly logrotate keeping several generations, filled
log2ram to 100 % in about 3 weeks (2026-07-07 → 2026-07-31).

**Steady-state config** is:

- `chrony.conf`: `log tracking` only (one line every ~16 s, ~1 MB/week).
- `/etc/logrotate.d/chrony`: weekly, `rotate 2`, `compress`,
  `delaycompress`, `maxsize 10M`, `copytruncate`. Caps total chrony
  log footprint at ~20 MB uncompressed, few MB compressed.

If a future incident needs the per-second detail back, enable the fuller
`log measurements statistics tracking refclocks` line, but *also* drop
`rotate 2` to `rotate 1` (or bump log2ram's `SIZE=` in
`/etc/log2ram.conf` to 256 MB) so log2ram doesn't fill in a week. And
remember to revert to `log tracking` when the investigation is done.

Rescue procedure if it fills again: `sudo rm /var/log/chrony/*.log.[123]`
frees the rotated generations immediately.

### avahi floods the journal when the router scans mDNS

**Symptom.** About 700 lines per hour of `avahi-daemon: Record [...] not
fitting in legacy unicast packet, dropping.` As a result, the RAM-only
journal reached back only ~22 h.

**Cause.** The UniFi gateway (`192.168.1.1`; the same queries also come
from `.10.1` and `.30.1`) sends mDNS queries every ~11 s from a random
source port. mDNS calls this "legacy unicast". One query asks about 32
service types and is 867 bytes long. A legacy-unicast answer must repeat
the questions and fit in 512 bytes, so avahi can never fit a reply. It
logs one warning per record it drops. The records were the Pi's only
advertised service, `_workstation._tcp`, plus the A/AAAA records that
go with it. Found 2026-11-22 with a short `AF_PACKET` Python sniffer
(tcpdump is not installed on the Pi).

**Fix (2026-11-22).** Set `publish-workstation=no` in
`/etc/avahi/avahi-daemon.conf` (backup at
`/etc/avahi/avahi-daemon.conf.bak-2026-11-22`) and ran
`systemctl restart avahi-daemon`. The Pi now advertises no services, so
avahi has nothing to try to answer with. `gpsntp.local` still resolves,
because that uses the host A/AAAA records, not the workstation service.
If a service is ever added under `/etc/avahi/services/`, the warnings
may come back for it. In that case, change the gateway's mDNS settings
(see `vlan-setup`).

### After a power cut, `NetworkManager-wait-online` shows `failed`

The 2026-11-17 13:11 boot came after a power cut: noderedpi4 booted 3 s
after gpsntp. The journal from that boot was gone, but these facts
survive in systemd and the kernel log:

- `eth0` link came up 44 s after boot (`dmesg`).
- `nm-online -s` ran from 42 s to 102 s, reached its 60 s limit
  (`NM_ONLINE_TIMEOUT=60`) and exited with code 1 (timed out).

eth0 uses DHCP, so NetworkManager does not count the network as up until
DHCP answers. The router and switches most likely lost power too and
were still booting. The Pi got its lease from `192.168.1.1` later.

**Impact: none on NTP.** chrony does not wait for the network. Only
cloud-init's `cloud-config` and `cloud-final`, and gpshealth (by
`After=`), are ordered after `network-online.target`. They start anyway
when the wait times out. The `failed` mark stays until the next boot, so
health checks list it.

**Fix (2026-11-22, Manoj's go).** The limit is now 300 s, set by the
drop-in `/etc/systemd/system/NetworkManager-wait-online.service.d/timeout.conf`
(`Environment=NM_ONLINE_TIMEOUT=300`). systemd's own start timeout is
already disabled for this oneshot unit, so nm-online's limit is the one
that counts. A normal boot is not slower: the wait ends as soon as DHCP
answers. After a power cut, gpshealth, cloud-init's last stages and the
apt jobs can start up to 5 min late. chrony and the cron-driven MQTT
publisher (`~/monitor.sh`) are not affected. If the unit still fails,
the router took more than 5 min to answer, or DHCP is broken:
investigate.

**Power cuts also lose logs.** log2ram writes `/var/log` to the SD card
only at its daily 23:55 save and at a clean shutdown. chrony's
`tracking.log` has gaps that start at 23:55 and end at a boot on
2026-11-07 22:51, 2026-11-16 15:26 and 2026-11-17 13:12 IST. So the Pi
lost power (or crashed) three times in ten days. Each time it lost up to
a day of `/var/log`.

### systemd says services started "2026-05-09" after every boot

The Pi has no RTC and no `fake-hwclock`. At boot, systemd sets the clock
to the date of `/var/lib/systemd/timesync/clock`. Nothing updates that
file, because chrony replaced `systemd-timesyncd`, so it is stuck at
2026-05-09 19:30. Anything that starts before chrony steps the clock gets
that date. For example, `systemctl status chrony` reads "active since Sat
2026-05-09". The wrong date is only cosmetic. For true uptime use
`uptime -s`. For how long a service has run, use
`systemctl show <unit> -p ActiveEnterTimestampMonotonic` (µs since boot).

## Things explicitly *not* in scope

- Any embedded-firmware development (the ESP32 path was dropped).
- Mac menu-bar **GPS** app — i.e. a Mac app that drives a USB GPS
  itself. The status-display widget under `dashboard/swiftbar/` is
  fine and intentional: it only subscribes to the Pi's MQTT
  broadcast, reading *time-server health*, not GPS data.
- Changes to the SkimServer Mac codebase.
- Feeding PPS into macOS directly — the Pi is the abstraction layer.

## Suggested next steps if reopening this project

1. **First, check operational status** — run the operational-checks block
   above. If everything is green, there's nothing to do; ask the user
   what they want to extend.
2. **Common extension requests:**
   - ~~Add chrony metrics to the Node-RED RPi Fleet dashboard~~ —
     **done.** See `dashboard/` and the "chrony status broadcast"
     entry under "Integration with the shack" above.
   - Install `log2ram` if the Pi has been running for many months and
     SD-card wear is a concern (BUILD.md "Optional" section).
   - ~~Add a second GPS for redundancy under chrony as a second
     refclock~~ — originally written up in FUTURE.md when the M8N
     was meant to back up the QLG1. The 2026-05-11 swap promoted the
     M8N to *primary*, so this task is obsolete in its original form.
     If hot-spare redundancy is wanted again, the now-stand-alone
     QLG1 (or any other GPS with NMEA+PPS) is a reasonable second
     refclock — the wiring/config pattern is in git history (any
     commit prior to the swap will show the second-refclock skeleton).
   - OLED status display showing fix/sat-count/offset.
3. **Don't re-litigate ESP32 vs Pi** — that decision is made and the
   build is operational. If the user wants to redo it, they'll say so.
