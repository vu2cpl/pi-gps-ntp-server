# Pi GPS NTP Server

Stratum-1 GPS-disciplined NTP server on a Raspberry Pi 3B, sharing the
QRP Labs QLG1 GPS receiver that already feeds a U3S beacon transmitter
so no extra GPS hardware is needed.

Achieved at first run: **stratum 1, PPS error ±152 ns, system clock 35 ns
slow of GPS truth, skew 0.009 ppm**. Mac client disciplined to within
1–4 ms over LAN (limited by macOS scheduling jitter, not by the server).

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

## Hardware

- Raspberry Pi 3B (any 64-bit Pi with wired Ethernet works).
- QRP Labs **QLG1** GPS receiver (MediaTek chipset, 10 ns RMS PPS).
  This build taps the unused **6-way** header so the existing 4-way
  connection to a U3S is left untouched. If you don't run a U3S, any
  5 V- or 3.3 V-output GPS with NMEA + PPS works.
- 2 × 2.2 kΩ + 2 × 3.3 kΩ resistors as voltage dividers — the QLG1
  outputs 5 V logic and the Pi GPIO is **not 5 V tolerant**. Skip the
  dividers if your GPS is 3.3 V native.
- Active GPS antenna with sky view.
- Wired Ethernet to the LAN.

## Software stack

- Raspberry Pi OS Lite, 64-bit (verified on Debian Trixie; Bookworm
  works the same).
- `gpsd` parsing NMEA from `/dev/serial0`, exporting PPS via SHM-2.
- Linux kernel `pps-gpio` overlay on GPIO18 → `/dev/pps0`.
- `chrony` with `refclock PPS lock NMEA refid PPS` and `allow` for the
  LAN subnet.

## Documentation

- **[BUILD.md](BUILD.md)** — step-by-step build procedure, verification
  at each stage, troubleshooting section.
- **[HANDOVER.md](HANDOVER.md)** — project context, decisions made
  along the way, operational checks for future maintenance.
- **[FUTURE.md](FUTURE.md)** — parked tasks, including a fleshed-out
  NEO-M8N redundant-GPS plan that's ready to pick up.
- **[dashboard/](dashboard/)** — optional MQTT status broadcast: a
  Pi-side cron publisher, an importable Node-RED dashboard flow, and
  a macOS SwiftBar menu-bar widget. All read off one retained topic.

## Status

Operational since 2026-05-09 in the VU2CPL shack. See HANDOVER.md
"Operational checks" for diagnosis commands.

## License

MIT — see [LICENSE](LICENSE).
