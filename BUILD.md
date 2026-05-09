# GPS-disciplined NTP server — build procedure

**Hardware:** Raspberry Pi 3 Model B + QRP Labs QLG1 (tapped from the U3S
beacon) + chrony + gpsd.

**Target:** Stratum 1, sub-microsecond local clock, microsecond-class
accuracy delivered to LAN clients over Ethernet.

See `HANDOVER.md` for project context (who, why, decisions made). This
file is the procedure.

Follow the stages top-to-bottom. Each stage ends with a verification step.
Don't move on until verification passes — chasing a problem two stages
later is much harder than fixing it where it appears.

---

## What you need on hand

**Already owned:**
- Raspberry Pi 3 Model B
- microSD card, 16 GB or larger, decent quality (Samsung Evo / SanDisk Ultra)
- Pi 5 V 2.5 A micro-USB power supply
- Ethernet cable to your LAN switch
- QRP Labs U3S with QLG1 attached, working, with sky-view antenna

**To buy / scrounge (cheap):**
- 2 × 2.2 kΩ resistors (series — between QLG1 outputs and Pi GPIOs)
- 2 × 3.3 kΩ resistors (pulldown — to GND)
- (1.8 kΩ + 3.3 kΩ also works if that's what you have — gives 3.24 V instead
  of 3.00 V, both are Pi-safe.)
- Small piece of perfboard or a mini-breadboard
- 6 jumper wires (3 from QLG1 to perfboard, 3 from perfboard to Pi GPIO)
- (Optional) heat-shrink tubing if you make permanent solder joints

That's it. No SDR, no logic analyzer, no oscilloscope required. A
multimeter is nice for sanity-checking the divider voltages but not
mandatory.

---

## Stage 1 — Flash the SD card

1. Install the official **Raspberry Pi Imager** from
   https://www.raspberrypi.com/software/ (Mac: `brew install --cask raspberry-pi-imager`).
2. Insert the SD card.
3. **Choose Device:** Raspberry Pi 3.
4. **Choose OS:** Raspberry Pi OS (other) → **Raspberry Pi OS Lite (64-bit)**.
   Bookworm. No desktop.
5. **Choose Storage:** the SD card.
6. Click **Next** → "Would you like to apply OS customisation settings?" → **Edit Settings**.

**General tab:**
- **Set hostname:** `gpsntp` (gives you `gpsntp.local` via mDNS)
- **Set username and password:** username `vu2cpl`, strong-ish password —
  you'll rarely use it but `sudo` needs one
- **Configure wireless LAN:** leave blank — we want Ethernet
- **Set locale settings:** your timezone (UTC is conventional for time
  servers but regional time is fine; this only affects log timestamps)

**Services tab:**
- **Enable SSH:** yes → **Allow public-key authentication only**
- Paste your public key. From a Mac terminal: `pbcopy < ~/.ssh/id_ed25519.pub`,
  then Cmd-V into the box.

**Save** → "Yes" to apply customisations → confirm SD overwrite.

When the Imager finishes ("write successful, you may now remove..."), eject
and put the SD card in the Pi.

---

## Stage 2 — First boot and login

1. Plug the Ethernet cable in.
2. Plug the power in. The green LED should flicker as it boots.
3. Wait ~60 seconds for first-boot setup.

From your Mac:

```sh
ssh vu2cpl@gpsntp.local
```

If that fails for more than 2 minutes, find the Pi's IP from your router's
DHCP lease list and `ssh vu2cpl@<ip>`.

Once logged in:

```sh
sudo apt update && sudo apt full-upgrade -y
sudo apt install -y pps-tools gpsd gpsd-clients chrony
sudo reboot
```

Reconnect after reboot.

**Verification:** `uname -a` reports an `aarch64` (64-bit) kernel.
`hostname` returns `gpsntp`.

---

## Stage 3 — Wire the QLG1 tap

**Power off the Pi (`sudo poweroff`, wait for green LED to stop, then unplug)
and the U3S before touching anything.**

### What we're tapping

The QLG1 has two output connectors. **Tap the 6-way, not the 4-way.**
The 4-way is already in use feeding the U3S — leave that cable alone.
The 6-way connector exposes the same signals on independent pads and is
typically unused.

| 6-way pin | Label   | What we do with it                       |
|-----------|---------|------------------------------------------|
| 1         | +5V     | **Don't touch**                          |
| 2         | +V Batt | **Don't touch**                          |
| 3         | TXD (5V)| Solder wire → divider → Pi UART RX       |
| 4         | RXD     | **Don't touch** (not used by us)         |
| 5         | 1PPS (5V)| Solder wire → divider → Pi PPS GPIO     |
| 6         | GND     | Solder wire → common ground              |

### Why dividers

QLG1 outputs are buffered to **5 V** by the on-board 74ACT08. Pi GPIO is
**not 5 V tolerant** — direct connection can damage the SoC. A simple
two-resistor divider drops 5 V to a Pi-safe ~3.24 V. Resistor values aren't
critical; anything that lands the divided voltage between 2.7 V and 3.3 V
is fine.

### The divider (build twice — one for TXD, one for PPS)

```
QLG1 5V signal ──[2.2 kΩ]──┬── to Pi GPIO (≈3.00 V)
                            │
                          [3.3 kΩ]
                            │
                           GND (shared with QLG1 and Pi)
```

**Orientation matters.** 2.2 kΩ in series (top), 3.3 kΩ as pulldown
(bottom). Reversing them gives 2.0 V at the Pi pin, which is below the
~2.3 V input-high threshold and the signal becomes unreliable.

### Pi 3B GPIO header (looking at the board with the SD card slot at top)

We need three Pi pins:

| Pi physical pin | BCM name | Used for         |
|-----------------|----------|------------------|
| 6               | GND      | Common ground    |
| 10              | GPIO15   | UART RX (NMEA in)|
| 12              | GPIO18   | PPS interrupt    |

(Pin 1 is the corner nearest the SD card slot, with even pins on the side
nearest the board edge. Many tutorials and `pinout.xyz` show this clearly.)

### Wiring summary

```
QLG1 6-way pin 6 (GND) ─────────────────────────── Pi pin 6 (GND)
QLG1 6-way pin 3 (TXD) ──[2.2k]──┬── Pi pin 10 (GPIO15 / UART RX)
                                  └─[3.3k]── GND
QLG1 6-way pin 5 (PPS) ──[2.2k]──┬── Pi pin 12 (GPIO18)
                                  └─[3.3k]── GND
```

Build it on perfboard or a tiny breadboard sitting between the U3S and the
Pi. Keep wires short — under 30 cm total — to keep the PPS edge clean.

### Sanity check before powering the Pi

With the QLG1 powered (U3S on) but Pi still off:

- Multimeter, DC volts, between Pi pin 10 and Pi pin 6 (GND): should read
  somewhere between 2.5 and 3.3 V most of the time (TXD idles high) with
  brief dips during NMEA bursts.
- Multimeter between Pi pin 12 and Pi pin 6: mostly near 0 V, with a brief
  ~3 V pulse once per second once the QLG1 has a fix (look at the green
  PPS LED on the QLG1 — it pulses on the same edge).

If you ever read above 3.6 V on either, **stop** — your divider isn't
working. Don't power the Pi until it's fixed.

Once the readings look right, power the Pi.

---

## Stage 4 — Configure UART and PPS

SSH back in. Edit `/boot/firmware/config.txt` (note: Bookworm path; older
guides say `/boot/config.txt` — that's wrong now):

```sh
sudo nano /boot/firmware/config.txt
```

At the end of the file (or anywhere outside the `[pi4]`-style sections),
add:

```ini
# GPS NTP server config

# Enable the primary UART on GPIO14/15
enable_uart=1

# Free the PL011 hardware UART from Bluetooth so NMEA gets a stable clock
dtoverlay=disable-bt

# Kernel PPS on GPIO18 (BCM) = physical pin 12
dtoverlay=pps-gpio,gpiopin=18
```

Save (Ctrl-O, Enter, Ctrl-X).

Now disable the serial login console so it stops fighting with the GPS for
the UART:

```sh
sudo raspi-config
```

→ **3 Interface Options** → **I6 Serial Port**
→ "Would you like a login shell to be accessible over serial?" → **No**
→ "Would you like the serial port hardware to be enabled?" → **Yes**
→ Finish → reboot when prompted.

Also disable the now-unused Bluetooth UART helper:

```sh
sudo systemctl disable hciuart
```

Reboot if it didn't already:

```sh
sudo reboot
```

**Verification (after reconnecting):**

```sh
ls -l /dev/serial0 /dev/pps0
lsmod | grep pps
```

`/dev/serial0` should be a symlink to `ttyAMA0` (the real PL011 UART, now
freed from Bluetooth). `/dev/pps0` should exist. `lsmod` should show
`pps_gpio`.

If `/dev/pps0` is missing, the overlay didn't load — re-check
`/boot/firmware/config.txt` and reboot.

---

## Stage 5 — Verify NMEA arriving

```sh
sudo cat /dev/serial0
```

You should see NMEA sentences scrolling once per second:

```
$GPRMC,123519,A,4807.038,N,01131.000,E,022.4,084.4,230394,003.1,W*6A
$GPGGA,...
$GPGSV,...
$GPGLL,...
```

`A` in the third field of `$GPRMC` means "active fix". `V` means "no fix
yet" — wait a few minutes if you're inside or just powered up.

If you see **garbage characters** (random bytes, mojibake): baud rate is
wrong, or the mini-UART is being used instead of PL011 — re-check
`disable-bt` in config.txt.

If you see **nothing**: wiring problem (TXD, GND, or divider). Check the
multimeter readings from Stage 3.

Ctrl-C to stop.

---

## Stage 6 — Verify PPS arriving

```sh
sudo ppstest /dev/pps0
```

Once the QLG1 has a fix (the green PPS LED on the QLG1 board is flashing),
you should see one line per second:

```
trying PPS source "/dev/pps0"
found PPS source "/dev/pps0"
ok, found 1 source(s), now start fetching data...
source 0 - assert 1715234567.000000123, sequence: 42 - clear  1715234567.099876543, sequence: 42
source 0 - assert 1715234568.000000119, sequence: 43 - clear  1715234568.099876612, sequence: 43
```

The `assert` timestamp's fractional part (the `.000000xxx` bit) should be
small — single-digit microseconds typically. That's your kernel-level PPS
edge timestamp.

If you see "found PPS source" but no per-second lines: PPS isn't reaching
the GPIO. Check the divider, the GPIO18 wire, and that the QLG1's green
PPS LED is actually pulsing (no GPS fix → no PPS).

Ctrl-C to stop.

**Both Stage 5 and Stage 6 must pass before continuing.** They prove the
hardware is good.

---

## Stage 7 — Configure gpsd

gpsd parses NMEA so chrony doesn't have to.

```sh
sudo nano /etc/default/gpsd
```

Replace the file contents with:

```sh
START_DAEMON="true"
USBAUTO="false"
DEVICES="/dev/serial0 /dev/pps0"
GPSD_OPTIONS="-n"
```

The `-n` flag is critical — it tells gpsd to start polling the GPS
immediately, rather than waiting for a client to connect. Without it,
chrony never gets data because chrony reads gpsd's shared memory passively.

Restart gpsd:

```sh
sudo systemctl restart gpsd.socket gpsd.service
sudo systemctl enable gpsd.socket gpsd.service
```

**Verification:**

```sh
gpsmon
```

Should show a live status panel: time, sat count, fix status, NMEA
sentences scrolling at the bottom. Press `q` to exit.

Or:

```sh
cgps -s
```

Same data, different layout. `q` to exit.

---

## Stage 8 — Configure chrony

```sh
sudo nano /etc/chrony/chrony.conf
```

The Debian default has a `pool 2.debian.pool.ntp.org iburst` line. **Comment
that line out** (prefix with `#`) and add at the bottom of the file:

```conf
# --- GPS-disciplined time source ---

# Pool servers, kept only as a sanity cross-check, not used for time
pool 2.debian.pool.ntp.org iburst maxsources 4 noselect

# NMEA from gpsd via shared memory — provides "which second" context.
# Coarse (~100 ms), so noselect — PPS does the actual fine timing.
refclock SHM 0 refid NMEA offset 0.0 delay 0.2 noselect

# Kernel PPS — sub-microsecond. Locked to NMEA for second-numbering.
refclock PPS /dev/pps0 lock NMEA refid PPS

# Serve time to the LAN. Adjust to your subnet.
allow 192.168.1.0/24

# Don't serve to the internet
deny all
```

Adjust the `allow` line to match your LAN. Run `ip addr show eth0` and look
at the `inet` line — if it's `192.168.0.42/24`, then `allow 192.168.0.0/24`.

Restart chrony:

```sh
sudo systemctl restart chrony
```

---

## Stage 9 — Verify stratum 1

Wait ~2 minutes for chrony to acquire and discipline against PPS.

```sh
chronyc sources -v
```

You're looking for output like this:

```
MS Name/IP address         Stratum Poll Reach LastRx Last sample
===============================================================================
#? NMEA                          0   4   377     6   +123ms[+123ms] +/- 100ms
#* PPS                           0   4   377     6    -45ns[ -120ns] +/- 1.2us
^? 2.debian.pool.ntp.org         2   6    37    32   +1.2ms[+1.2ms] +/- 23ms
```

The key things:

- A line for `PPS` with `#*` (current best source) and a `+/-` of microseconds.
- A line for `NMEA` with `#?` (locked to PPS, not selected — correct).
- Pool servers showing larger offsets — they should agree with the GPS to
  within a few ms. If they disagree by seconds, *something is wrong with the
  GPS-disciplined time*, not with the pool.

```sh
chronyc tracking
```

Look for:

```
Reference ID    : 50505300 (PPS)
Stratum         : 1
...
Last offset     : +0.000000234 seconds
RMS offset      : 0.000000412 seconds
...
Leap status     : Normal
```

**Stratum 1, RMS offset in the microseconds, Reference ID = PPS.** Done.

If `Stratum: 0`, chrony hasn't accepted the PPS source yet — wait another
minute, re-check. If it stays at 0, see the Troubleshooting section.

---

## Stage 10 — Point your Mac at it

From the Mac, first sanity-check that the Pi answers NTP queries:

```sh
sntp gpsntp.local
```

Should print something like:

```
+0.000123 +/- 0.000456 gpsntp.local 192.168.1.42
```

A small offset and small dispersion — good.

Then in macOS:

**System Settings → General → Date & Time** →
**Set time and date automatically** ON →
**Source:** click the drop-down (or "Set..." button) and enter `gpsntp.local`.

Verify:

```sh
sudo sntp -sS gpsntp.local
```

(One-shot sync from the new server. The Mac's `timed` will keep it
disciplined from now on.)

---

## Optional — Reduce SD card wear

A 24/7 NTP server writes logs and chrony state continuously. SD cards
handle this fine for a year or two but eventually wear out. Two options:

### log2ram (simpler)

Mounts `/var/log` as tmpfs, writes back to SD hourly:

```sh
echo "deb http://packages.azlux.fr/debian/ bookworm main" | sudo tee /etc/apt/sources.list.d/azlux.list
sudo wget -O /etc/apt/trusted.gpg.d/azlux.gpg https://azlux.fr/repo.gpg
sudo apt update
sudo apt install -y log2ram
sudo systemctl enable --now log2ram
```

### Boot from USB SSD (better long-term)

The Pi 3B can boot from USB. Burn the same OS to a USB stick or small SSD
instead of the SD card. Has been documented to death — search "Pi 3B USB
boot" if you want to go this route. Not necessary on day one.

---

## Troubleshooting

### `/dev/pps0` doesn't exist

`dtoverlay=pps-gpio,gpiopin=18` line missing or in the wrong file. Check
`/boot/firmware/config.txt` (not `/boot/config.txt`). Reboot.

### NMEA shows up as garbage

The mini-UART is being used instead of the PL011. `disable-bt` overlay
isn't taking effect. Verify with `dmesg | grep -i uart` after reboot — you
want to see `ttyAMA0` on the GPIO pins.

### `chronyc sources -v` shows PPS but stratum stays at 0

PPS is arriving but chrony isn't promoting it. Causes:

- gpsd isn't running with `-n`, so NMEA SHM is empty → PPS has no
  second-number context to lock to. Run `cgps -s` to confirm gpsd has a
  fix; check `GPSD_OPTIONS="-n"` in `/etc/default/gpsd`.
- Time isn't roughly correct yet. PPS only labels the sub-second part —
  chrony needs to know the right second from somewhere. The pool servers
  (even `noselect`) provide this. If the Pi is offline, manually set the
  clock first with `sudo date -s "..."`.

### U3S stops working after the tap

Almost certainly a wiring mistake (you accidentally bridged a divider
output back to the QLG1 side, or shorted something). Disconnect the tap
entirely; if the U3S recovers, your tap has a fault. Re-check with the
multimeter that nothing on the tap rises above ~3.3 V.

### GPS keeps losing fix when the U3S transmits

RFI from the U3S desensitizing the QLG1 — the patch antenna sits right
next to a transmitter. Mitigations: relocate the QLG1 antenna further from
the U3S RF output, add ferrite beads to the tap cable, or buy a separate
NEO-M8N + antenna for the Pi and stop tapping. The handover document
flagged this as a known risk.

### Mac shows offset of ~1 second instead of microseconds

You're hitting `chronyc tracking` from the Pi (correct) but seeing the
*Mac's* drift, not the Pi's. macOS `timed` only steps the clock occasionally;
that's normal. The Pi *itself* is the stratum-1 source. If you point WSJT-X
or any application that reads system time at the Mac, that's what gets the
microsecond-class time, modulo macOS scheduling jitter.

---

## What "done" looks like

- `chronyc tracking` on the Pi: Stratum 1, Reference ID = PPS, RMS offset < 10 µs.
- `sntp gpsntp.local` from the Mac: small offset and dispersion.
- Pulling the Ethernet cable, waiting a minute, plugging back in: chrony
  recovers without a step, log shows brief `unreachable` then resync.
- Power-cycling the QLG1: the Pi falls back to the pool servers (with a
  warning in the chrony log), then re-locks to PPS within a minute of GPS
  fix returning.
- The Pi has been up for a week and `chronyc tracking` still says stratum 1.
