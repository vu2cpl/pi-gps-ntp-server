# Future Work

Parked tasks for this project. Not in scope for the current build, but
captured in enough detail to pick up later without re-deriving anything.

## Add a second GPS (NEO-M8N) as a redundant chrony refclock

**Status:** parked. Original motivation (U3S TX desensing the shared
QLG1) is dissolving as the U3S is being replaced. Keep this on the list
as general redundancy / hot-spare against any single QLG1 failure.

**Pick:** generic `GY-NEO8MV2` u-blox NEO-M8N breakout. ~30 ns RMS PPS,
gpsd+chrony support is well-trodden. Includes a ceramic patch antenna
on a u.FL pigtail.

### Before ordering, confirm on the listing

1. PPS pad is broken out and labeled (most boards have it + a 1 Hz
   blue LED tied to PPS).
2. Whether TX idles at 3.3 V or 5 V at the pin — most GY-NEO8MV2
   variants output 3.3 V TTL (onboard LDO), but verify with a meter on
   arrival before wiring to Pi GPIO. Add 2.2 kΩ + 3.3 kΩ dividers only
   if the output is 5 V.

### Wiring

The QLG1 already owns PL011 (GPIO14/15) and GPIO18 (PPS). For the M8N:

| M8N pin | Pi connection                         | Notes                                          |
|---------|---------------------------------------|------------------------------------------------|
| VCC     | Pi 5V                                 | Onboard 3.3 V LDO on the breakout              |
| GND     | Pi GND                                | Common ground                                  |
| TX      | USB-serial dongle RX → Pi USB         | Avoids Pi 3B's flaky mini-UART                 |
| RX      | USB-serial dongle TX                  | Only needed for u-center config                |
| PPS     | Pi GPIO4 (header pin 7), direct       | 3.3 V native — no divider                      |

**Why USB-serial for NMEA:** Pi 3B's only good UART (PL011) is in use
by the QLG1; the mini-UART is jittery and awkward to remap to free
GPIO once `disable-bt` is in place. NMEA jitter is irrelevant for time
(PPS does the work), so USB-serial is the simplest and cleanest path.

### `/boot/firmware/config.txt` — append

```
dtoverlay=pps-gpio,gpiopin=4    # M8N PPS → /dev/pps1
```

The existing `pps-gpio,gpiopin=18` line for the QLG1 stays.

### `/etc/default/gpsd`

```
DEVICES="/dev/serial0 /dev/pps0 /dev/serial/by-id/usb-XXX-if00 /dev/pps1"
GPSD_OPTIONS="-n"
```

- Use the `/dev/serial/by-id/...` symlink, not `/dev/ttyUSB0` — the
  latter is not stable across reboots if other USB-serial devices
  appear.
- Order matters: device 0 = QLG1 (gpsd SHM 0/1), device 1 = M8N
  (gpsd SHM 2/3).

### `/etc/chrony/chrony.conf` — add

```
# Existing — QLG1
refclock SHM 0 refid NMEA offset 0.0 delay 0.2 noselect
refclock PPS /dev/pps0 lock NMEA refid PPS

# New — NEO-M8N
refclock SHM 2 refid NMEB offset 0.0 delay 0.2 noselect
refclock PPS /dev/pps1 lock NMEB refid PPS2
```

Notes:
- gpsd allocates two SHM slots per device, so the second GPS lands on
  SHM 2 (not SHM 1).
- Refids must be unique 4-char strings.
- Optionally add `prefer` to the QLG1 PPS line if the M8N should be a
  strict hot spare rather than co-equal.

### Validation

```sh
sudo ppstest /dev/pps1            # one line/sec, fractional µs
gpspipe -w | grep -E '"device":'  # both devices reporting TPV
chronyc sources -v                # PPS and PPS2 both visible, one starred
```

### Expected chrony behaviour

Both PPS refclocks become candidates. Chrony picks the lower-jitter
one as `*` (system reference) and the other as `+` (combined) or `-`
(not combined). On QLG1 fix loss, chrony silently fails over to the
M8N — that's the point.
