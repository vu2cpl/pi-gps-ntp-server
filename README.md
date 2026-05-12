# Pi GPS NTP Server

Stratum-1 GPS-disciplined NTP server on a Raspberry Pi 3B with a
dedicated u-blox NEO-M8N GPS module feeding the shack LAN.

Performance after burn-in: **stratum 1, PPS error ±171 ns, system clock
20 ns fast of GPS truth, skew 0.004 ppm, root dispersion 22 µs**. Mac
client disciplined to within 1–4 ms over LAN (limited by macOS
scheduling jitter, not by the server).

The first build (2026-05-09) tapped an existing QRP Labs QLG1 that was
also feeding a U3S beacon, with voltage dividers; the GPS was swapped
to the dedicated NEO-M8N on 2026-05-11 when the U3S was retired (see
HANDOVER.md "GPS swap"). The QLG1 path remains valid — see git history
for that wiring if you want to rebuild it.

## Why this and not an ESP32?

Most "GPS NTP server" hobby projects target an ESP32 with custom
firmware. That works, but loses to a Raspberry Pi on every dimension
that matters once a Pi is on the table:

- `chrony` + `gpsd` + kernel PPS is what most public stratum-1 servers
  on the NTP pool actually run. Hobby ESP32 NTP code re-implements
  leap seconds, holdover, multi-source comparison, and stratum honesty —
  all already correct in chrony.
- Linux timestamps NTP packets at NIC level; ESP32 lwIP timestamps in
  userspace. Client-visible accuracy ends up better on the Pi.
- Wired Ethernet by default; Wi-Fi NTP jitter (100s of µs to ms)
  swamps any sub-µs local lock.
- Debug with SSH + `chronyc`, not a logic analyzer.

Full reasoning in [HANDOVER.md](HANDOVER.md).

## Hardware (current build)

- Raspberry Pi 3B (any 64-bit Pi with wired Ethernet works).
- **GY-NEO8MV2** breakout (u-blox NEO-M8N, ~30 ns RMS PPS). 3.3 V-native
  TX and PPS, so TX → Pi GPIO15 (pin 10) and PPS → Pi GPIO18 (pin 12)
  go direct, no level-shifting needed.
- Patch antenna on u.FL pigtail with sky view (ships with the GY-NEO8MV2).
- Wired Ethernet to the LAN.

Any GPS with 3.3 V or 5 V NMEA + PPS works in this role. For a 5 V
output (like the original QLG1), add 2 × 2.2 kΩ + 2 × 3.3 kΩ voltage
dividers on TX and PPS before the Pi (Pi GPIO is **not** 5 V tolerant).

## Software stack

- Raspberry Pi OS Lite, 64-bit (verified on Debian Trixie; Bookworm
  works the same).
- `gpsd` parsing NMEA from `/dev/serial0`, exporting PPS via SHM-2.
- Linux kernel `pps-gpio` overlay on GPIO18 → `/dev/pps0`.
- `chrony` with `refclock PPS lock NMEA refid PPS` and `allow` for the
  LAN subnet.

## Quick start

```sh
git clone https://github.com/vu2cpl/pi-gps-ntp-server.git
cd pi-gps-ntp-server
./install.sh
```

`install.sh` auto-detects platform:
- on the **Pi** it installs gpsd / chrony / mosquitto-clients, configures
  UART + PPS overlays, sets up the chrony refclocks and the MQTT
  publisher, and smoke-tests everything;
- on a **Mac** it installs SwiftBar + mosquitto + Pillow and drops the
  menu-bar plugin into your SwiftBar plugins folder.

Both halves are idempotent — safe to re-run. The script prompts for the
broker IP and a couple of other values, but you can hit return through
the defaults for the VU2CPL shack setup.

For a hand-built rebuild without the installer, see `BUILD.md`.

## Documentation

- **[BUILD.md](BUILD.md)** — step-by-step build procedure, verification
  at each stage, troubleshooting section.
- **[HANDOVER.md](HANDOVER.md)** — project context, decisions made
  along the way, operational checks for future maintenance.
- **[FUTURE.md](FUTURE.md)** — parked / completed extensions.
- **[dashboard/](dashboard/)** — optional MQTT status broadcast: a
  Pi-side cron publisher, an importable Node-RED dashboard flow, and
  a macOS SwiftBar menu-bar widget. All read off one retained topic.

## Status

Operational in the VU2CPL shack since 2026-05-09 (first on a QLG1 tap,
on a dedicated NEO-M8N since 2026-05-11). See HANDOVER.md "Operational
checks" for diagnosis commands.

## License

MIT — see [LICENSE](LICENSE).
