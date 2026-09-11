#!/data/data/com.termux/files/usr/bin/bash
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

TERMUX_TMP="${PREFIX:-/data/data/com.termux/files/usr}/tmp"

# ------------------------------------------------------------------------------
# Handle Stop / Kill invocation (e.g. 'spotify --stop' or 'spotify-stop')
# ------------------------------------------------------------------------------
if [ "${1:-}" = "--stop" ] || [ "${1:-}" = "stop" ] || [ "${1:-}" = "-k" ] || [ "${1:-}" = "--kill" ]; then
    echo -e "${YELLOW}${BOLD}[*] Stopping SpotX Spotify and background services...${CLR}"

    # Terminate Spotify and window manager processes
    pkill -x spotify 2>/dev/null || true
    pkill -f "/usr/share/spotify/spotify" 2>/dev/null || true
    pkill -f "/usr/local/bin/spotify-termux" 2>/dev/null || true
    pkill -x matchbox-window-manager 2>/dev/null || true
    pkill -x openbox 2>/dev/null || true
    sleep 0.2
    pkill -9 -x spotify 2>/dev/null || true
    pkill -9 -f "/usr/share/spotify/spotify" 2>/dev/null || true

    # Terminate Termux-X11 display server and close Android app
    am broadcast -a com.termux.x11.ACTION_STOP -p com.termux.x11 > /dev/null 2>&1 || true
    pkill -f "termux.x11" 2>/dev/null || true
    pkill -f "termux-x11" 2>/dev/null || true
    rm -f "${TERMUX_TMP}/.X0-lock" "${TERMUX_TMP}/.X11-unix/X0" 2>/dev/null || true

    # Stop PulseAudio to close audio hardware device and save battery
    if command -v pulseaudio >/dev/null 2>&1; then
        pulseaudio -k 2>/dev/null || true
    fi
    pkill -x pulseaudio 2>/dev/null || true

    # Release Android CPU wake-lock
    if command -v termux-wake-unlock > /dev/null 2>&1; then
        termux-wake-unlock 2>/dev/null || true
    fi

    # Restore terminal mode
    stty sane 2>/dev/null || true

    echo -e "${GREEN}${BOLD}[✔] SpotX Spotify stopped successfully.${CLR}"
    exit 0
fi

# ------------------------------------------------------------------------------
# Check prerequisites
# ------------------------------------------------------------------------------
if ! command -v proot-distro > /dev/null 2>&1; then
    echo -e "${RED}${BOLD}[✘] Error: proot-distro is not installed!${CLR}"
    echo -e "${YELLOW}Please run the installer first: bash install.sh${CLR}"
    exit 1
fi

echo -e "${CYAN}${BOLD}[*] Launching SpotX Spotify on Android Termux...${CLR}"

# 0. Acquire Termux Wake-Lock to prevent Android CPU sleep when screen is off
if command -v termux-wake-lock > /dev/null 2>&1; then
    termux-wake-lock 2>/dev/null || true
fi

# 1. PulseAudio Audio Bridge (UNIX Domain Socket + TCP Fallback + OpenSL ES Android Sink)
PULSE_CONFIG_DIR="${HOME}/.config/pulse"
mkdir -p "$PULSE_CONFIG_DIR"
cat << 'PULSE_CONF' > "${PULSE_CONFIG_DIR}/daemon.conf"
exit-idle-time = -1
default-fragments = 8
default-fragment-size-msec = 25
resample-method = speex-float-0
default-sample-rate = 44100
alternate-sample-rate = 48000
default-sample-channels = 2
high-priority = yes
realtime-scheduling = no
PULSE_CONF

PULSE_SOCK_DIR="${PREFIX:-/data/data/com.termux/files/usr}/tmp"
mkdir -p "$PULSE_SOCK_DIR"
PULSE_SOCK_PATH="${PULSE_SOCK_DIR}/pulse-socket"

# If Spotify is not actively running, ensure PulseAudio daemon is reloaded with optimal configuration
if ! pgrep -x "spotify" > /dev/null 2>&1 && ! pgrep -f "/usr/share/spotify/spotify" > /dev/null 2>&1; then
    pulseaudio -k 2>/dev/null || pkill -x pulseaudio 2>/dev/null || true
    for ((k=1; k<=10; k++)); do
        if ! pgrep -x pulseaudio >/dev/null 2>&1; then
            break
        fi
        sleep 0.1
    done
    pkill -9 -x pulseaudio 2>/dev/null || true
    rm -f "$PULSE_SOCK_PATH" 2>/dev/null || true
fi

if ! pgrep -x "pulseaudio" > /dev/null 2>&1; then
    echo -e "${CYAN}[+] Starting PulseAudio daemon with OpenSL ES sink...${CLR}"
    pulseaudio --start \
        --load="module-native-protocol-unix auth-anonymous=1 socket=${PULSE_SOCK_PATH}" \
        --load="module-native-protocol-tcp auth-ip-acl=127.0.0.1 auth-anonymous=1" \
        --load="module-sles-sink" \
        --exit-idle-time=-1 2>/dev/null || true
else
    # Ensure SLES sink and protocol modules are loaded even if pulse was started earlier
    pactl load-module module-native-protocol-unix auth-anonymous=1 socket="${PULSE_SOCK_PATH}" 2>/dev/null || true
    pactl load-module module-native-protocol-tcp auth-ip-acl=127.0.0.1 auth-anonymous=1 2>/dev/null || true
    pactl load-module module-sles-sink 2>/dev/null || true
fi

# 2. Termux-X11 Display Server (:0)
# If Spotify is not actively running, ensure any stale/frozen Termux-X11 instance is cleared
if ! pgrep -x "spotify" > /dev/null 2>&1 && ! pgrep -f "/usr/share/spotify/spotify" > /dev/null 2>&1; then
    pkill -f "termux.x11" 2>/dev/null || true
    pkill -f "termux-x11" 2>/dev/null || true
    sleep 0.2
fi

if ! pgrep -f "termux.x11" > /dev/null 2>&1 && ! pgrep -f "termux-x11" > /dev/null 2>&1; then
    # Clear stale X11 sockets/locks only if server is not already running
    rm -f "${TERMUX_TMP}/.X0-lock" "${TERMUX_TMP}/.X11-unix/X0" 2>/dev/null || true
    echo -e "${CYAN}[+] Starting Termux-X11 display server (:0)...${CLR}"
    termux-x11 :0 -legacy-drawing -ac &
    for ((i=1; i<=30; i++)); do
        if [ -S "${TERMUX_TMP}/.X11-unix/X0" ] || [ -f "${TERMUX_TMP}/.X0-lock" ]; then
            break
        fi
        sleep 0.1
    done
    sleep 0.5
fi

# 3. Bring Termux-X11 Android App to Foreground
echo -e "${CYAN}[+] Bringing Termux-X11 app to foreground...${CLR}"
am start --user 0 -n com.termux.x11/com.termux.x11.MainActivity >/dev/null 2>&1 || true
sleep 1

# 4. Define cleanup handler for signals and exit
cleanup() {
    # Remove traps to prevent loops
    trap - EXIT INT TERM HUP

    echo -e "\n${YELLOW}[*] Shutting down SpotX Spotify and background services...${CLR}"

    # Terminate container Spotify and window manager processes
    pkill -x spotify 2>/dev/null || true
    pkill -f "/usr/share/spotify/spotify" 2>/dev/null || true
    pkill -f "/usr/local/bin/spotify-termux" 2>/dev/null || true
    pkill -x matchbox-window-manager 2>/dev/null || true
    pkill -x openbox 2>/dev/null || true
    
    # Suppress bash job control output by disowning before kill
    if [ -n "${SPOTIFY_PID:-}" ]; then
        disown "$SPOTIFY_PID" 2>/dev/null || true
        kill -9 "$SPOTIFY_PID" 2>/dev/null || true
    fi

    # Close Termux-X11 Android app window
    am broadcast -a com.termux.x11.ACTION_STOP -p com.termux.x11 > /dev/null 2>&1 || true

    # Terminate Termux-X11 server and remove sockets
    pkill -f "termux.x11" 2>/dev/null || true
    pkill -f "termux-x11" 2>/dev/null || true
    rm -f "${TERMUX_TMP}/.X0-lock" "${TERMUX_TMP}/.X11-unix/X0" 2>/dev/null || true

    # Stop PulseAudio to save battery when not in use
    if command -v pulseaudio >/dev/null 2>&1; then
        pulseaudio -k 2>/dev/null || true
    fi
    pkill -x pulseaudio 2>/dev/null || true
    rm -f "${PULSE_SOCK_PATH}" 2>/dev/null || true

    # Release Android CPU wake-lock
    if command -v termux-wake-unlock > /dev/null 2>&1; then
        termux-wake-unlock 2>/dev/null || true
    fi

    # Restore terminal mode
    stty sane 2>/dev/null || true

    echo -e "${GREEN}${BOLD}[✔] SpotX Spotify closed cleanly.${CLR}"
    exit 0
}

# Trap signals: Ctrl+C (INT), SIGTERM (TERM), SIGHUP (HUP), and normal script exit (EXIT)
trap cleanup EXIT INT TERM HUP

# 5. Execute Spotify inside PRoot Ubuntu container in background
echo -e "${GREEN}${BOLD}[✔] Starting Spotify in Ubuntu container...${CLR}"

# Determine optimal audio transport: UNIX domain socket (fastest, zero jitter) with TCP fallback
PULSE_TARGET_SERVER="tcp:127.0.0.1:4713"
if [ -S "${PULSE_SOCK_PATH}" ]; then
    PULSE_TARGET_SERVER="unix:/tmp/pulse-socket"
fi

# Filter known PRoot futex warnings that occur when threads are killed
proot-distro login ubuntu --shared-tmp -- env DISPLAY=:0 PULSE_SERVER="${PULSE_TARGET_SERVER}" /usr/local/bin/spotify-termux "$@" 2> >(grep -v "The futex facility returned an unexpected error code" >&2) &
SPOTIFY_PID=$!

# Wait for Spotify process to finish
wait "$SPOTIFY_PID" 2>/dev/null || true
