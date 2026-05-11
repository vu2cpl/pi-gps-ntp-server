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
