#!/bin/bash
#
# SwiftBar/xbar plugin — GPS NTP server live status from MQTT.
#
# Filename encodes refresh cadence (30s). Drop into the configured
# SwiftBar plugins folder:
#   defaults read com.ameba.SwiftBar PluginDirectory
# (default ~/Library/Application Support/SwiftBar/Plugins/, or
# whichever folder you chose during SwiftBar's first-launch wizard)
# or the equivalent xbar folder. chmod +x after copying.
#
# Optional environment overrides:
#   MQTT_BROKER=192.168.1.169                   # broker host
#   MQTT_TOPIC=shack/gpsntp/chrony              # topic
#   NODE_RED_URL=http://192.168.1.169:1880/ui   # dropdown link target
#
# Sparkline: the dropdown also shows a tiny 280x60 PNG sparkline of the
# last ~120 system_time_offset_s samples, rendered with Python + Pillow.
# History is stored at ~/.local/share/gpsntp/offset-history.tsv. The
# graph degrades gracefully — if Pillow isn't installed, the rest of
# the menu still renders. Install if missing:
#   pip3 install --user Pillow
#
# <swiftbar.title>GPS NTP Server</swiftbar.title>
# <swiftbar.author>Manoj VU2CPL</swiftbar.author>
# <swiftbar.desc>Live chrony + GPS status from shack MQTT broker, with offset sparkline</swiftbar.desc>
# <swiftbar.refreshOnClick>true</swiftbar.refreshOnClick>
#
set -u
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

BROKER="${MQTT_BROKER:-192.168.1.169}"
TOPIC="${MQTT_TOPIC:-shack/gpsntp/chrony}"
DASHBOARD_URL="${NODE_RED_URL:-http://192.168.1.169:1880/ui}"

DATA="$(mosquitto_sub -h "$BROKER" -t "$TOPIC" -C 1 -W 5 2>/dev/null || true)"

if [ -z "$DATA" ]; then
  echo "🛰 ?? | color=red"
  echo "---"
  echo "No MQTT data on $BROKER topic $TOPIC"
  echo "Refresh | refresh=true"
  exit 0
fi

ref=$(echo "$DATA" | jq -r '.ref_name // "?"')
stratum=$(echo "$DATA" | jq -r '.stratum // 16')
sys_off=$(echo "$DATA" | jq -r '.system_time_offset_s // 0')
rms=$(echo "$DATA" | jq -r '.rms_offset_s // 0')
skew=$(echo "$DATA" | jq -r '.skew_ppm // 0')
root_disp=$(echo "$DATA" | jq -r '.root_dispersion_s // 0')
fix_mode=$(echo "$DATA" | jq -r '.fix_mode // 0')
sat_used=$(echo "$DATA" | jq -r '.sat_used // 0')
sat_seen=$(echo "$DATA" | jq -r '.sat_seen // 0')
ts=$(echo "$DATA" | jq -r '.ts // 0')
host=$(echo "$DATA" | jq -r '.host // "unknown"')
leap=$(echo "$DATA" | jq -r '.leap // "?"')

# Format a seconds-quantity into ns / µs / ms with sign.
fmt_offset() {
  awk -v v="$1" 'BEGIN {
    a = v < 0 ? -v : v
    if (a < 1e-6)      printf "%+.0f ns", v * 1e9
    else if (a < 1e-3) printf "%+.1f µs", v * 1e6
    else if (a < 1)    printf "%+.2f ms", v * 1e3
    else               printf "%+.3f s",  v
  }'
}
fmt_secs_pos() {  # for root dispersion (always positive)
  awk -v v="$1" 'BEGIN {
    if (v < 1e-6)      printf "%.0f ns", v * 1e9
    else if (v < 1e-3) printf "%.1f µs", v * 1e6
    else if (v < 1)    printf "%.2f ms", v * 1e3
    else               printf "%.3f s",  v
  }'
}

sys_off_h=$(fmt_offset "$sys_off")
rms_h=$(fmt_secs_pos "$rms")
root_disp_h=$(fmt_secs_pos "$root_disp")

# ----- history + sparkline -------------------------------------------------
# Append (ts, system_time_offset_s) to a rolling TSV, then render a small
# sparkline PNG via gnuplot. ~120 points = ~1 h of 30 s ticks.
HIST_DIR="$HOME/.local/share/gpsntp"
HIST_FILE="$HIST_DIR/offset-history.tsv"
GRAPH_PNG="$HIST_DIR/offset-graph.png"
GRAPH_B64=""

if [ -n "${ts:-}" ] && [ "$ts" != "0" ] && [ "$sys_off" != "—" ]; then
  mkdir -p "$HIST_DIR" 2>/dev/null || true
  last_ts="$(tail -1 "$HIST_FILE" 2>/dev/null | cut -f1 || true)"
  if [ "${last_ts:-}" != "$ts" ]; then
    printf '%s\t%s\n' "$ts" "$sys_off" >> "$HIST_FILE"
  fi
  if [ -f "$HIST_FILE" ] && [ "$(wc -l < "$HIST_FILE" 2>/dev/null || echo 0)" -gt 120 ]; then
    tail -120 "$HIST_FILE" > "${HIST_FILE}.tmp" && mv "${HIST_FILE}.tmp" "$HIST_FILE"
  fi
fi

if command -v python3 >/dev/null 2>&1 \
   && [ -f "$HIST_FILE" ] \
   && [ "$(wc -l < "$HIST_FILE")" -ge 2 ]; then
  python3 - "$HIST_FILE" "$GRAPH_PNG" <<'PY' 2>/dev/null || true
import sys
try:
    from PIL import Image, ImageDraw
except ImportError:
    sys.exit(0)

src, dst = sys.argv[1], sys.argv[2]
data = []
with open(src) as f:
    for line in f:
        parts = line.strip().split('\t')
        if len(parts) == 2:
            try:
                data.append((float(parts[0]), float(parts[1])))
            except ValueError:
                pass
if len(data) < 2:
    sys.exit(0)

W, H = 180, 48
S = 2                                # supersample factor for AA
WS, HS = W * S, H * S
# Transparent background so the macOS menu's native chrome shows
# through — no visible rectangle around the sparkline.
img = Image.new('RGBA', (WS, HS), (0, 0, 0, 0))
draw = ImageDraw.Draw(img)

xs = [d[0] for d in data]; ys = [d[1] for d in data]

# Light 3-point moving average to suppress per-poll jitter while
# keeping spikes visible. Padded ends use the closest real sample.
if len(ys) >= 3:
    smoothed = [ys[0]]
    for i in range(1, len(ys) - 1):
        smoothed.append((ys[i-1] + ys[i] + ys[i+1]) / 3.0)
    smoothed.append(ys[-1])
    ys = smoothed

xmin, xmax = min(xs), max(xs)
ymin, ymax = min(ys + [0]), max(ys + [0])    # include zero in range
span = max(ymax - ymin, 1e-9)
ymin -= span * 0.10
ymax += span * 0.10

def sx(x):
    return (2 + (W - 4) * (x - xmin) / (xmax - xmin)) * S if xmax > xmin else WS / 2
def sy(y):
    return (H - 4 - (H - 8) * (y - ymin) / (ymax - ymin)) * S if ymax > ymin else HS / 2

# Zero baseline (subtle hairline)
if ymin <= 0 <= ymax:
    y0 = sy(0)
    draw.line([(2 * S, y0), ((W - 2) * S, y0)], fill='#3a4654', width=S)

# Attention threshold band at +/- 1 ms (dashed, faint orange).
# Drawn only when within the auto-scaled y range so it does not
# squash the trace when offsets are healthy and sub-microsecond.
def dashed(y, color):
    x = 2 * S
    end = (W - 2) * S
    dash, gap = 4 * S, 3 * S
    while x < end:
        x2 = min(x + dash, end)
        draw.line([(x, y), (x2, y)], fill=color, width=S)
        x += dash + gap
for threshold in (1e-3, -1e-3):
    if ymin <= threshold <= ymax:
        dashed(sy(threshold), '#7a4e1f')

# Sparkline (supersampled — line width 3*S downscales to ~1.5 px AA).
draw.line([(sx(x), sy(y)) for x, y in zip(xs, ys)], fill='#5cd0d6', width=int(1.5 * S))

# Downscale to target size with LANCZOS for smooth anti-aliasing.
img = img.resize((W, H), Image.LANCZOS)
img.save(dst)
PY
  if [ -f "$GRAPH_PNG" ]; then
    GRAPH_B64="$(base64 < "$GRAPH_PNG" | tr -d '\n')"
  fi
fi
# ---------------------------------------------------------------------------

# Pick icon + colour.
case "$ref" in
  PPS|PPS2)  icon="🛰"; color="#28a745" ;;
  NMEA|NMEB) icon="🛰"; color="#e6a700" ;;
  *)         icon="⚠";  color="#d83a3a" ;;
esac

# Stale-data guard.
now=$(date +%s)
age=$(( now - ts ))
if [ "$age" -gt 120 ]; then
  icon="⏱"; color="#d83a3a"
fi

# Fix mode label.
case "$fix_mode" in
  3) fix_str="3D fix" ;;
  2) fix_str="2D fix" ;;
  *) fix_str="no fix" ;;
esac

# ----- menu-bar line -----
echo "$icon S$stratum  $sys_off_h | color=$color"

# ----- dropdown -----
echo "---"
echo "$host · $ref · S$stratum | shell=/usr/bin/true terminal=false refresh=false"
if [ -n "$GRAPH_B64" ]; then
  echo "---"
  echo "  | image=$GRAPH_B64"
fi
echo "---"
echo "System offset: $sys_off_h | font=Menlo shell=/usr/bin/true terminal=false refresh=false"
echo "RMS offset:    $rms_h | font=Menlo shell=/usr/bin/true terminal=false refresh=false"
echo "Root disp.:    $root_disp_h | font=Menlo shell=/usr/bin/true terminal=false refresh=false"
echo "Skew:          $skew ppm | font=Menlo shell=/usr/bin/true terminal=false refresh=false"
echo "Leap:          $leap | font=Menlo shell=/usr/bin/true terminal=false refresh=false"
echo "---"
echo "GPS: $fix_str  🛰 $sat_used/$sat_seen | font=Menlo shell=/usr/bin/true terminal=false refresh=false"
echo "---"
echo "Updated ${age}s ago | size=11"
echo "---"
echo "Refresh | refresh=true"
echo "Dashboard | href=$DASHBOARD_URL"
echo "SSH | href=ssh://vu2cpl@gpsntp.local"
