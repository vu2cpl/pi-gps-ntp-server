#!/bin/bash
#
# SwiftBar/xbar plugin — GPS NTP server live status from MQTT.
#
# Filename encodes refresh cadence (30s). Drop into:
#   ~/Library/Application Support/SwiftBar/Plugins/  (SwiftBar)
#   ~/Library/Application Support/xbar/plugins/      (xbar)
# and chmod +x.
#
# <swiftbar.title>GPS NTP Server</swiftbar.title>
# <swiftbar.author>Manoj VU2CPL</swiftbar.author>
# <swiftbar.desc>Live chrony + GPS status from shack MQTT broker</swiftbar.desc>
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
echo "$host  ($ref, stratum $stratum) | color=black,white"
echo "---"
echo "System offset: $sys_off_h | font=Menlo color=black,white"
echo "RMS offset:    $rms_h | font=Menlo color=black,white"
echo "Root disp.:    $root_disp_h | font=Menlo color=black,white"
echo "Skew:          $skew ppm | font=Menlo color=black,white"
echo "Leap:          $leap | font=Menlo color=black,white"
echo "---"
echo "GPS: $fix_str — $sat_used / $sat_seen sats used | font=Menlo color=black,white"
echo "---"
echo "Updated ${age}s ago | size=11"
echo "---"
echo "Refresh | refresh=true"
echo "Open Node-RED dashboard | href=$DASHBOARD_URL"
echo "SSH to gpsntp | href=ssh://vu2cpl@gpsntp.local"
