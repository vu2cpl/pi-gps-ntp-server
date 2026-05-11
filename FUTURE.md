# Future Work

Parked and completed extensions for this project. Done items are kept
here (struck-through with a short summary) so the file doubles as a
record of where each idea landed.

## ~~Add a second GPS (NEO-M8N) as a redundant chrony refclock~~ — obsolete

**Status:** obsolete. The plan was to add a NEO-M8N as a *second*
refclock alongside the QLG1, on USB-serial + GPIO4 PPS, so chrony
could fail over if the QLG1 desensed under U3S TX. The 2026-05-11
hardware swap retired the U3S and promoted the M8N to **primary** GPS
(replacing the QLG1 on the same UART + GPIO18 PPS pins), so this
"second refclock" task no longer makes sense.

If hot-spare redundancy is wanted again later, the stand-alone QLG1 or
any other NMEA+PPS GPS can be wired as a second refclock — the wiring
table, gpsd `DEVICES` line, and chrony `SHM 2` + `refclock PPS
/dev/pps1 lock NMEB` skeleton are preserved in git history (look at
any commit prior to 0d198f2 for the full sketch).

## ~~Restyle the chrony dashboard tile as an HTML card~~ — done

**Status:** done. `dashboard/node-red-flow.json` now ships a single
`ui_template` carrying one self-contained card. The aesthetic ended
up matching the user's existing fleet dashboard (dark `#0e151e`
panels, cyan section dividers, off-white values with orange reserved
for attention thresholds) rather than the GitHub Primer look that
was originally proposed — see `dashboard/preview/chrony-card.html`
for the live preview that drove the design, and
`dashboard/chrony-card-template.html` for the bare template body
ready to paste into a ui_template node.

### Approach sketch

- Replace the `function` + 7 widget nodes with one `function` → one
  `ui_template` node, dropped into a group on the **existing fleet
  dashboard tab** (not a new tab). The template receives the parsed
  JSON payload via `msg`.
- Card layout (HTML):
  - Header row: hostname on the left, a coloured "S1 / S2 / —" chip
    right-justified (green / amber / red by stratum).
  - Two-column key/value table for the metrics (system offset, RMS,
    root dispersion, skew, leap).
  - GPS row: fix mode + sat ratio.
  - Footer: muted "Updated Ns ago" with a `setInterval` to keep the
    relative time fresh without re-rendering the whole card.
- Styling: `font-family: ui-monospace, SFMono-Regular, Menlo;`
  `border: 1px solid var(--nr-dashboard-widget-border);`
  `border-radius: 6px; padding: 12px;`. Use Node-RED's CSS variables
  so the card picks up the user's dashboard theme automatically.
- The same ns / µs / ms picker used by `swiftbar/gpsntp.30s.sh`
  (`fmt_offset`) moves into the template; the upstream `function`
  node just hands raw fields through.

### Where to drop it in the main dashboard

The fleet dashboard already has per-host groups carrying rpi-agent
telemetry. The cleanest placement is a new "Time" tile under the
same tab/group as the gpsntp host's other widgets, sized to match
the dashboard's existing grid.

### Acceptance

- One tile, one MQTT subscription, no separate "GPS NTP" tab.
- Reads the same `shack/gpsntp/chrony` retained topic — no Pi-side
  changes needed.
- Visually consistent with the rest of the fleet dashboard, both
  light and dark mode.
- Relative "Updated Ns ago" advances client-side without flicker.
