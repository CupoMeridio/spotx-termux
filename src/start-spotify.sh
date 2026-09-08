#!/usr/bin/env bash
# ==============================================================================
# start-spotify.sh - Termux host launcher for SpotX Spotify on real Android hardware
# ==============================================================================
set -e

# ANSI colors
CLR='\033[0m'
BOLD='\033[1m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
RED='\033[0;31m'

echo -e "${CYAN}${BOLD}[*] Launching SpotX Spotify on Android Termux...${CLR}"

# 0. Acquire Termux Wake-Lock to prevent Android CPU sleep when screen is off
if command -v termux-wake-lock > /dev/null 2>&1; then
    termux-wake-lock 2>/dev/null || true
fi

TERMUX_TMP="${PREFIX:-/data/data/com.termux/files/usr}/tmp"

# 1. PulseAudio Audio Bridge (TCP 127.0.0.1 + OpenSL ES Android Sink)
if ! pgrep -x "pulseaudio" > /dev/null 2>&1; then
    echo -e "${CYAN}[+] Starting PulseAudio daemon with OpenSL ES sink...${CLR}"
    pulseaudio --start \
        --load="module-native-protocol-tcp auth-ip-acl=127.0.0.1 auth-anonymous=1" \
        --load="module-sles-sink" \
        --exit-idle-time=-1 2>/dev/null || true
else
    # Ensure SLES sink is loaded even if pulse was started earlier
    pactl load-module module-sles-sink 2>/dev/null || true
fi

# 2. Termux-X11 Display Server (:0)
if ! pgrep -f "termux.x11" > /dev/null 2>&1 && ! pgrep -f "termux-x11" > /dev/null 2>&1; then
    # Clear stale X11 sockets/locks only if server is not already running
    rm -f "${TERMUX_TMP}/.X0-lock" "${TERMUX_TMP}/.X11-unix/X0" 2>/dev/null || true
    echo -e "${CYAN}[+] Starting Termux-X11 display server (:0)...${CLR}"
    termux-x11 :0 -ac &
    sleep 1
fi

# 3. Bring Termux-X11 Android App to Foreground
echo -e "${CYAN}[+] Bringing Termux-X11 app to foreground...${CLR}"
am start --user 0 -n com.termux.x11/com.termux.x11.MainActivity >/dev/null 2>&1 || true

# 4. Execute Spotify inside PRoot Ubuntu container
echo -e "${GREEN}${BOLD}[✔] Starting Spotify in Ubuntu container...${CLR}"
exec proot-distro login ubuntu --shared-tmp -- env DISPLAY=:0 PULSE_SERVER=tcp:127.0.0.1:4713 /usr/local/bin/spotify-termux "$@"
