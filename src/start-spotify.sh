#!/usr/bin/env bash
# ==============================================================================
# start-spotify.sh - Termux host launcher for SpotX Spotify
# ==============================================================================
set -e

# ANSI colors
CLR='\033[0m'
BOLD='\033[1m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
RED='\033[0;31m'

echo -e "${CYAN}${BOLD}[*] Launching SpotX Spotify on Termux...${CLR}"

# 1. PulseAudio Audio Bridge
if ! pgrep -x "pulseaudio" > /dev/null 2>&1; then
    echo -e "${CYAN}[+] Starting PulseAudio audio daemon...${CLR}"
    pulseaudio --start \
        --load="module-native-protocol-tcp auth-ip-acl=127.0.0.1 auth-anonymous=1" \
        --exit-idle-time=-1 2>/dev/null || true
fi

# 2. Termux-X11 Display Server
if ! pgrep -f "termux-x11 :0" > /dev/null 2>&1; then
    echo -e "${CYAN}[+] Starting Termux-X11 display server (:0)...${CLR}"
    termux-x11 :0 -ac &
    sleep 1
fi

# 3. Bring Termux-X11 Android App to Foreground
echo -e "${CYAN}[+] Bringing Termux-X11 to foreground...${CLR}"
am start --user 0 -n com.termux.x11/com.termux.x11.MainActivity >/dev/null 2>&1 || true

# 4. Execute Spotify inside PRoot Ubuntu container
echo -e "${GREEN}${BOLD}[✔] Starting Spotify in Ubuntu PRoot container...${CLR}"
exec proot-distro login ubuntu --shared-tmp -- env DISPLAY=:0 PULSE_SERVER=127.0.0.1 /usr/local/bin/spotify-termux "$@"
