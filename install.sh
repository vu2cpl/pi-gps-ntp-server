#!/usr/bin/env bash
#
# install.sh — interactive installer for the Pi GPS NTP Server project.
#
# Auto-detects platform:
#   - Pi / Linux  →  configures kernel overlays, gpsd, chrony, and the
#                     MQTT publisher.  Run as a normal user; uses sudo.
#   - macOS       →  installs SwiftBar + mosquitto-clients + the menu-
#                     bar plugin.  Run as a normal user; uses brew.
#
# Usage:
#   git clone <this repo>
#   cd pi-gps-ntp-server
#   ./install.sh
#
# Safe to re-run.  Skips work that is already done.
#

set -euo pipefail

# ----- pretty output --------------------------------------------------------
if [ -t 1 ]; then
  GREEN=$'\e[32m'; CYAN=$'\e[36m'; YELLOW=$'\e[33m'
  RED=$'\e[31m';   DIM=$'\e[2m';   BOLD=$'\e[1m'; RESET=$'\e[0m'
else
  GREEN= CYAN= YELLOW= RED= DIM= BOLD= RESET=
fi

section() { printf "\n${BOLD}${CYAN}==>${RESET} ${BOLD}%s${RESET}\n" "$*"; }
ok()      { printf "${GREEN}  ✓${RESET} %s\n" "$*"; }
warn()    { printf "${YELLOW}  !${RESET} %s\n" "$*"; }
err()     { printf "${RED}  ✗${RESET} %s\n" "$*" >&2; }
info()    { printf "${DIM}    %s${RESET}\n" "$*"; }

ask() {
  # ask <prompt> <default> → echoes the answer
  local prompt="$1" default="${2:-}" reply
  if [ -n "$default" ]; then
    read -r -p "${YELLOW}?${RESET} ${prompt} ${DIM}[${default}]${RESET} " reply
    echo "${reply:-$default}"
  else
    read -r -p "${YELLOW}?${RESET} ${prompt} " reply
    echo "$reply"
  fi
}

ask_secret() {
  # ask_secret <prompt> → echoes the answer; typing is not shown
  local reply
  read -r -s -p "${YELLOW}?${RESET} $1 " reply
  echo >&2
  echo "$reply"
}

confirm() {
  # confirm <prompt> [default-yes|default-no] → returns 0 if yes
  local prompt="$1" default="${2:-default-yes}" reply
  if [ "$default" = "default-yes" ]; then
    read -r -p "${YELLOW}?${RESET} ${prompt} ${DIM}[Y/n]${RESET} " reply
    [[ -z "$reply" || "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]
  else
    read -r -p "${YELLOW}?${RESET} ${prompt} ${DIM}[y/N]${RESET} " reply
    [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]
  fi
}

# ----- locate the script and the repo --------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ----- platform detection --------------------------------------------------
case "$(uname -s)" in
  Linux*)  PLATFORM=pi ;;
  Darwin*) PLATFORM=mac ;;
  *)       err "Unsupported platform: $(uname -s)"; exit 1 ;;
esac

# ============================================================================
#  Pi installer
# ============================================================================
install_pi() {
  section "Pi GPS NTP Server — Pi-side installer"
  cat <<EOM

This will configure your Pi as a stratum-1 GPS-disciplined NTP server:

  • Install pps-tools, gpsd, gpsd-clients, chrony, mosquitto-clients, jq
  • Enable the PL011 UART on GPIO14/15 and kernel PPS on GPIO18
  • Disable the serial login console so gpsd owns the UART
  • Set up gpsd to feed NMEA from /dev/serial0 and PPS from /dev/pps0
  • Configure chrony with PPS-locked-to-NMEA refclocks + LAN allow
  • Install /usr/local/bin/gpsntp-mqtt-publish.sh + per-minute cron
  • Smoke-test everything at the end

Assumes your GPS module is wired to the Pi:
    Module TX  → Pi GPIO15 (header pin 10)
    Module PPS → Pi GPIO18 (header pin 12)
    Module GND → Pi GND    (header pin 6)
    Module VCC → 3.3 V (pin 1) or 5 V (pin 2) per your module

EOM

  if ! confirm "Proceed?"; then exit 0; fi

  # ----- gather config ------------------------------------------------------
  section "Configuration"
  MQTT_BROKER="$(ask 'MQTT broker IP (leave blank to skip publisher)' '192.168.1.169')"
  MQTT_TOPIC="$(ask 'MQTT topic' 'shack/gpsntp/chrony')"
  MQTT_USER="$(ask 'MQTT username (blank = anonymous)' '')"
  MQTT_PASS=""
  [ -n "$MQTT_USER" ] && MQTT_PASS="$(ask_secret 'MQTT password')"
  # TLS: a LAN listener such as 8883 plus the broker's CA certificate. A
  # broker on this same Pi can stay plain on a loopback-only listener
  # (broker 127.0.0.1) -- see dashboard/README.md "Broker with TLS".
  MQTT_PORT="$(ask 'MQTT port (blank = 1883)' '')"
  MQTT_CAFILE="$(ask 'Broker CA certificate file for TLS (blank = plain MQTT)' '')"
  # One CIDR per network that must be SERVED.  chrony answers only sources
  # inside an `allow` -- everything else is dropped silently, with no log
  # and no ICMP.  After the 2026-08-18 VLAN split the shack had three
  # networks and the Pi still allowed one: every Mac on VLAN 10 and every
  # ESP on VLAN 30 asked and got nothing, while the router's firewall rule
  # said Allow (found 2026-09-10).  List them all here.
  LAN_ALLOW="$(ask 'Subnet(s) to serve NTP to (CIDR, space-separated)' '192.168.1.0/24 192.168.10.0/24 192.168.30.0/24')"

  # ----- sanity check the Pi ----------------------------------------------
  section "Checking Pi"
  if [ ! -f /boot/firmware/config.txt ]; then
    err "/boot/firmware/config.txt not found."
    info "This installer targets Raspberry Pi OS Bookworm or Trixie."
    exit 1
  fi
  ok "Pi OS detected ($(uname -m))"

  if [ ! -f "$SCRIPT_DIR/dashboard/gpsntp-mqtt-publish.sh" ]; then
    err "Project files missing — run this from a checkout of pi-gps-ntp-server."
    exit 1
  fi
  ok "Project files present"

  if ! confirm "Is the GPS module wired as listed above?" default-no; then
    warn "Stop, wire the GPS, then re-run this installer."
    exit 0
  fi

  # ----- apt packages ------------------------------------------------------
  section "Installing packages"
  sudo apt update -qq
  sudo apt install -y pps-tools gpsd gpsd-clients chrony mosquitto-clients jq
  ok "Packages installed"

  # ----- boot config -------------------------------------------------------
  section "Configuring /boot/firmware/config.txt"
  CFG=/boot/firmware/config.txt
  REBOOT_NEEDED=no
  for line in \
      'enable_uart=1' \
      'dtoverlay=disable-bt' \
      'dtoverlay=pps-gpio,gpiopin=18'
  do
    if grep -qE "^${line//./\\.}\$" "$CFG"; then
      ok "$line — already present"
    else
      echo "$line" | sudo tee -a "$CFG" >/dev/null
      ok "$line — added"
      REBOOT_NEEDED=yes
    fi
  done

  # ----- serial console ----------------------------------------------------
  section "Disabling serial login console"
  if command -v raspi-config >/dev/null; then
    sudo raspi-config nonint do_serial_cons 1 || true
    ok "Serial console disabled"
  else
    warn "raspi-config not found — disable the serial console manually"
  fi

  # ----- gpsd --------------------------------------------------------------
  section "Configuring gpsd"
  sudo tee /etc/default/gpsd >/dev/null <<EOF
# /etc/default/gpsd — managed by install.sh
START_DAEMON="true"
USBAUTO="false"
DEVICES="/dev/serial0 /dev/pps0"
GPSD_OPTIONS="-n"
EOF
  ok "/etc/default/gpsd written"

  # ----- chrony ------------------------------------------------------------
  section "Configuring chrony"
  CHRONY_CONF=/etc/chrony/chrony.conf
  ALLOW_LINES=""
  for net in $LAN_ALLOW; do
    ALLOW_LINES="${ALLOW_LINES}allow ${net}
"
  done
  if grep -q '^refclock PPS /dev/pps0' "$CHRONY_CONF"; then
    ok "chrony refclocks already present"
    # Re-run on an existing Pi: make sure every requested subnet is served.
    # (This is how the VLAN-10/30 clients were silently cut off for three
    # weeks in 2026 -- the refclock check short-circuited the allow lines.)
    ADDED=0
    for net in $LAN_ALLOW; do
      if ! grep -q "^allow ${net}\$" "$CHRONY_CONF"; then
        echo "allow ${net}" | sudo tee -a "$CHRONY_CONF" >/dev/null
        ADDED=1
      fi
    done
    [ "$ADDED" = 1 ] && ok "chrony allow list extended to: ${LAN_ALLOW}" || ok "chrony allow list already covers: ${LAN_ALLOW}"
  else
    sudo tee -a "$CHRONY_CONF" >/dev/null <<EOF

# --- GPS-disciplined time source (added by install.sh) ---
refclock SHM 0 refid NMEA offset 0.0 delay 0.2 noselect
refclock PPS /dev/pps0 lock NMEA refid PPS

# Serve time to the LAN -- one line per network that must be served
${ALLOW_LINES}
EOF
    ok "chrony refclocks + allow added"
  fi

  # ----- MQTT publisher ----------------------------------------------------
  if [ -n "$MQTT_BROKER" ]; then
    section "Installing MQTT status publisher"
    sudo install -m 0755 \
      "$SCRIPT_DIR/dashboard/gpsntp-mqtt-publish.sh" \
      /usr/local/bin/gpsntp-mqtt-publish.sh
    ok "/usr/local/bin/gpsntp-mqtt-publish.sh installed"

    sudo tee /etc/cron.d/gpsntp-mqtt >/dev/null <<EOF
# /etc/cron.d/gpsntp-mqtt — managed by install.sh
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MQTT_BROKER=${MQTT_BROKER}
MQTT_TOPIC=${MQTT_TOPIC}
${MQTT_USER:+MQTT_USER=${MQTT_USER}}
${MQTT_PASS:+MQTT_PASS=${MQTT_PASS}}
${MQTT_PORT:+MQTT_PORT=${MQTT_PORT}}
${MQTT_CAFILE:+MQTT_CAFILE=${MQTT_CAFILE}}

* * * * * root /usr/local/bin/gpsntp-mqtt-publish.sh >/dev/null 2>&1
EOF
    sudo chmod 600 /etc/cron.d/gpsntp-mqtt
    ok "/etc/cron.d/gpsntp-mqtt installed (every minute)"
  else
    warn "Skipping MQTT publisher — no broker configured"
  fi

  # ----- reboot if needed --------------------------------------------------
  if [ "$REBOOT_NEEDED" = yes ]; then
    section "Reboot required"
    info "Kernel device-tree overlays only take effect at boot."
    if confirm "Reboot now?"; then
      info "Rebooting in 5 seconds — re-run this script after reboot to skip"
      info "to the verification step (it's idempotent)."
      sleep 5
      sudo reboot
    else
      warn "Reboot when ready, then verify with: chronyc tracking"
    fi
    return 0
  fi

  # ----- smoke test --------------------------------------------------------
  section "Smoke-testing"
  sleep 2
  if sudo systemctl restart gpsd chrony; then
    ok "gpsd and chrony restarted"
  fi
  sleep 5

  info "chronyc tracking:"
  chronyc tracking | sed 's/^/      /' || true

  echo
  info "chronyc sources -v:"
  chronyc sources -v 2>/dev/null | tail -10 | sed 's/^/      /' || true

  if [ -n "$MQTT_BROKER" ]; then
    echo
    info "Test-publishing one snapshot..."
    # Same env the cron job gets (broker, auth, TLS), read by root from the
    # chmod-600 cron file so the password never lands on a command line.
    if sudo bash -c 'set -a; . <(grep "^MQTT_" /etc/cron.d/gpsntp-mqtt); set +a
                     exec /usr/local/bin/gpsntp-mqtt-publish.sh'; then
      ok "MQTT publish succeeded"
      info "Subscribe sanity (warns if the ACL makes this account write-only):"
      SUB_ARGS=(-h "$MQTT_BROKER" -t "$MQTT_TOPIC" -C 1 -W 3)
      [ -n "$MQTT_USER" ]   && SUB_ARGS+=(-u "$MQTT_USER" -P "$MQTT_PASS")
      [ -n "$MQTT_PORT" ]   && SUB_ARGS+=(-p "$MQTT_PORT")
      [ -n "$MQTT_CAFILE" ] && SUB_ARGS+=(--cafile "$MQTT_CAFILE")
      mosquitto_sub "${SUB_ARGS[@]}" 2>/dev/null \
        | jq -c '{ref_name, stratum, fix_mode, sat_used, sat_seen}' 2>/dev/null \
        | sed 's/^/      /' || warn "Could not subscribe (broker reachable?)"
    fi
  fi

  section "Done"
  cat <<EOM
The Pi is now serving NTP on ${LAN_ALLOW}.  To point clients at it:
  macOS:   sudo systemsetup -setnetworktimeserver gpsntp.local
  Linux:   replace the server line in /etc/chrony/chrony.conf and restart
  Windows: w32tm /config /manualpeerlist:gpsntp.local /update

If you have a Mac on this LAN and want the SwiftBar status widget, run
this same install.sh on the Mac — it auto-detects platform.
EOM
}

# ============================================================================
#  Mac installer
# ============================================================================
install_mac() {
  section "Pi GPS NTP Server — Mac client installer"
  cat <<EOM

This installs the SwiftBar menu-bar widget that shows live chrony +
GPS status from the Pi's MQTT broadcast, plus the small dependencies:

  • Homebrew packages: mosquitto (for mosquitto_sub)
  • Cask: SwiftBar (the menu-bar app that hosts the plugin)
  • Python: Pillow (for the in-dropdown offset sparkline; optional)
  • Plugin: dashboard/swiftbar/gpsntp.30s.sh into SwiftBar's plugins folder

EOM

  if ! confirm "Proceed?"; then exit 0; fi

  # ----- prerequisites -----------------------------------------------------
  section "Checking prerequisites"
  if ! command -v brew >/dev/null; then
    err "Homebrew is required."
    info "Install from https://brew.sh and re-run this script."
    exit 1
  fi
  ok "Homebrew present ($(brew --version | head -1))"
  ok "Python: $(python3 --version 2>&1)"

  if [ ! -f "$SCRIPT_DIR/dashboard/swiftbar/gpsntp.30s.sh" ]; then
    err "Plugin file missing — run this from a checkout of pi-gps-ntp-server."
    exit 1
  fi

  # ----- config ------------------------------------------------------------
  section "Configuration"
  MQTT_BROKER="$(ask 'MQTT broker IP' '192.168.1.169')"
  MQTT_PORT="$(ask 'MQTT port (1883 plain, 8883 TLS)' '1883')"
  MQTT_CAFILE=""
  if [ "$MQTT_PORT" != 1883 ]; then
    MQTT_CAFILE="$(ask 'Broker CA certificate file (blank = plain MQTT)' "$HOME/.config/mqtt-ca.crt")"
  fi
  MQTT_USER="$(ask 'MQTT username (blank = anonymous)' '')"
  MQTT_PASS=""
  [ -n "$MQTT_USER" ] && MQTT_PASS="$(ask_secret 'MQTT password')"
  NODE_RED_URL="$(ask 'Node-RED dashboard URL (for the dropdown link)' \
                       "http://${MQTT_BROKER}:1880/ui")"

  if /usr/bin/nc -z -w 2 "$MQTT_BROKER" "$MQTT_PORT" 2>/dev/null; then
    ok "Broker $MQTT_BROKER:$MQTT_PORT is reachable"
  else
    warn "Broker $MQTT_BROKER:$MQTT_PORT unreachable — installing anyway"
    info "The widget will show '🛰 ??' until the broker comes up."
  fi

  # ----- brew packages -----------------------------------------------------
  section "Installing mosquitto"
  if brew list mosquitto >/dev/null 2>&1; then
    ok "mosquitto already installed"
  else
    brew install mosquitto
    ok "mosquitto installed"
  fi

  section "Installing SwiftBar"
  if [ -d /Applications/SwiftBar.app ]; then
    ok "SwiftBar already installed"
  else
    brew install --cask swiftbar
    ok "SwiftBar installed"
  fi

  section "Installing Pillow (optional, for sparkline)"
  if python3 -c "import PIL" 2>/dev/null; then
    ok "Pillow already importable"
  else
    if python3 -m pip install --user Pillow 2>/dev/null; then
      ok "Pillow installed"
    else
      warn "Pillow install failed — the widget will work, just without the sparkline"
    fi
  fi

  # ----- SwiftBar plugins folder -------------------------------------------
  section "Locating SwiftBar plugins folder"
  PLUGINS_DIR="$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || true)"
  if [ -z "$PLUGINS_DIR" ]; then
    warn "SwiftBar has no configured plugins folder yet."
    info "Launching SwiftBar — pick a folder in its first-launch wizard,"
    info "then re-run this script."
    open -a SwiftBar || true
    exit 0
  fi
  ok "Plugins folder: $PLUGINS_DIR"
  mkdir -p "$PLUGINS_DIR"

  # ----- install plugin ----------------------------------------------------
  section "Installing plugin"
  install -m 0755 \
    "$SCRIPT_DIR/dashboard/swiftbar/gpsntp.30s.sh" \
    "$PLUGINS_DIR/gpsntp.30s.sh"
  ok "Plugin copied to $PLUGINS_DIR/gpsntp.30s.sh"

  # Patch broker IP into the plugin if user chose a non-default
  if [ "$MQTT_BROKER" != "192.168.1.169" ] || \
     [ "$NODE_RED_URL" != "http://192.168.1.169:1880/ui" ]; then
    info "Customising plugin defaults..."
    /usr/bin/sed -i '' \
      -e "s|MQTT_BROKER:-192\\.168\\.1\\.169|MQTT_BROKER:-${MQTT_BROKER}|" \
      -e "s|NODE_RED_URL:-http://192\\.168\\.1\\.169:1880/ui|NODE_RED_URL:-${NODE_RED_URL}|" \
      "$PLUGINS_DIR/gpsntp.30s.sh"
    ok "Plugin patched"
  fi

  # ----- broker settings for the plugin --------------------------------------
  # SwiftBar doesn't inherit the shell env, so the plugin sources this file.
  # The file is shared with other shack scripts (HA_*, UNIFI_*, ...): only
  # our own MQTT_* keys are replaced, every other line is kept as it is.
  ENV_FILE="$HOME/.config/vu2cpl-shack.env"
  if [ -n "$MQTT_USER" ] || [ "$MQTT_PORT" != 1883 ]; then
    section "Writing broker settings"
    mkdir -p "$HOME/.config"
    if [ -s "$ENV_FILE" ]; then
      chmod 600 "$ENV_FILE"   # an old file keeps its mode, and its .bak copies it
      cp -p "$ENV_FILE" "$ENV_FILE.bak"
      info "Previous settings kept in $ENV_FILE.bak"
    fi
    ( umask 077; touch "$ENV_FILE" )
    tmp="$(mktemp "$ENV_FILE.XXXXXX")"   # same directory, so the mv below is atomic; mode 600
    # grep ends every kept line with a newline, so the appends never run
    # into an unterminated last line.
    grep -v -E '^[[:space:]]*(export[[:space:]]+)?(MQTT_BROKER|MQTT_PORT|MQTT_CAFILE|MQTT_USER|MQTT_PASS)=' \
      "$ENV_FILE" > "$tmp" || true
    {
      echo "MQTT_BROKER=$MQTT_BROKER"
      if [ "$MQTT_PORT" != 1883 ]; then echo "MQTT_PORT=$MQTT_PORT"; fi
      if [ -n "$MQTT_CAFILE" ]; then echo "MQTT_CAFILE=$MQTT_CAFILE"; fi
      if [ -n "$MQTT_USER" ]; then printf 'MQTT_USER=%s\nMQTT_PASS=%s\n' "$MQTT_USER" "$MQTT_PASS"; fi
    } >> "$tmp"
    chmod 600 "$tmp"
    mv "$tmp" "$ENV_FILE"
    ok "MQTT_* settings updated in $ENV_FILE (other keys kept, chmod 600)"
  fi

  # ----- test --------------------------------------------------------------
  section "Smoke test"
  if "$PLUGINS_DIR/gpsntp.30s.sh" | head -1 | grep -q '🛰\|⚠\|⏱'; then
    ok "Plugin produces SwiftBar output"
  else
    warn "Plugin output didn't include the menu-bar icon line"
  fi

  # ----- finish ------------------------------------------------------------
  open -a SwiftBar
  section "Done"
  cat <<EOM
The 🛰 icon should appear in your menu bar within ~30 s.
Click it for the live chrony status; click 'Refresh All' in SwiftBar's
menu to force an immediate update.

Optional next steps:
  • Set this Pi as your Mac's time server:
      sudo systemsetup -setnetworktimeserver gpsntp.local
  • Import the Node-RED flow at dashboard/node-red-flow.json into
    your fleet dashboard for a graphical view (see dashboard/README.md).
EOM
}

# ============================================================================
case "$PLATFORM" in
  pi)  install_pi ;;
  mac) install_mac ;;
esac
