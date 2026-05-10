#!/bin/bash
#
# gpsntp-mqtt-publish.sh
#
# Snapshots chrony tracking and gpsd fix info, publishes a single retained
# JSON message to the shack MQTT broker so the Node-RED dashboard and the
# Mac SwiftBar plugin can pick it up.
#
# Install:
#   sudo cp dashboard/gpsntp-mqtt-publish.sh /usr/local/bin/
#   sudo chmod +x /usr/local/bin/gpsntp-mqtt-publish.sh
#   sudo cp dashboard/cron.d-gpsntp-mqtt /etc/cron.d/gpsntp-mqtt
#
# Dependencies on the Pi:
#   apt install mosquitto-clients jq
#   (gpsd + chrony already installed by BUILD.md)
#
set -u

BROKER="${MQTT_BROKER:-192.168.1.169}"
TOPIC="${MQTT_TOPIC:-shack/gpsntp/chrony}"
HOST="$(hostname)"
TS="$(date +%s)"

# ----- chrony tracking (CSV: 14 fields) ----------------------------------
# Fields: ref_id, ref_name, stratum, ref_time, sys_time, last_off, rms_off,
#         freq, resid_freq, skew, root_delay, root_disp, upd_int, leap
IFS=, read -r ref_id ref_name stratum ref_time sys_time last_off rms_off \
              freq resid_freq skew root_delay root_disp upd_int leap \
              < <(chronyc -c tracking 2>/dev/null) || true

# ----- gpsd snapshot (best effort) ---------------------------------------
fix_mode=0
sat_used=0
sat_seen=0
if command -v gpspipe >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  # Larger window so we're likely to catch a "fat" SKY record (the thin
  # ones gpsd emits between full updates have no nSat / satellites array).
  GPS_DATA="$(timeout 5 gpspipe -w -n 40 2>/dev/null || true)"
  if [ -n "$GPS_DATA" ]; then
    fix_mode=$(printf '%s\n' "$GPS_DATA" \
      | jq -rs '[.[]|select(.class=="TPV")|.mode] | last // 0' 2>/dev/null || echo 0)
    # Take max across all SKY records in the window — robust against
    # thin records that don't carry uSat / nSat / satellites.
    sat_used=$(printf '%s\n' "$GPS_DATA" \
      | jq -rs '[.[]|select(.class=="SKY")|.uSat // 0] | max // 0' 2>/dev/null || echo 0)
    sat_seen=$(printf '%s\n' "$GPS_DATA" \
      | jq -rs '[.[]|select(.class=="SKY")|((.nSat) // ((.satellites // []) | length))] | max // 0' 2>/dev/null || echo 0)
  fi
fi

# ----- compose JSON (no quoting on numeric chrony values; they are valid JSON floats) -----
JSON=$(cat <<EOF
{"host":"$HOST","ts":$TS,"ref_id":"${ref_id:-}","ref_name":"${ref_name:-unknown}","stratum":${stratum:-16},"system_time_offset_s":${sys_time:-0},"last_offset_s":${last_off:-0},"rms_offset_s":${rms_off:-0},"freq_ppm":${freq:-0},"skew_ppm":${skew:-0},"root_delay_s":${root_delay:-0},"root_dispersion_s":${root_disp:-0},"leap":"${leap:-Unknown}","fix_mode":${fix_mode:-0},"sat_used":${sat_used:-0},"sat_seen":${sat_seen:-0}}
EOF
)

# ----- publish (retained, so subscribers get the latest snapshot on connect) -----
mosquitto_pub -h "$BROKER" -t "$TOPIC" -m "$JSON" -r
