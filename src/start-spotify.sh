#!/data/data/com.termux/files/usr/bin/bash
# ==============================================================================
# start-spotify.sh - Termux host launcher for SpotX Spotify on real Android hardware
# ==============================================================================
set -euo pipefail

# ------------------------------------------------------------------------------
# Load SpotX-Termux Shared Library
# ------------------------------------------------------------------------------
_SPOTX_LIB=""
_start_script_dir=""
if [ -n "${BASH_SOURCE[0]:-}" ]; then
    _start_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
    if [ -f "${_start_script_dir}/common.sh" ]; then
        _SPOTX_LIB="${_start_script_dir}/common.sh"
    elif [ -f "${_start_script_dir}/src/common.sh" ]; then
        _SPOTX_LIB="${_start_script_dir}/src/common.sh"
    fi
fi
if [ -z "$_SPOTX_LIB" ] && [ -f "${HOME}/.spotx-termux/common.sh" ]; then
    _SPOTX_LIB="${HOME}/.spotx-termux/common.sh"
fi

if [ -z "$_SPOTX_LIB" ] || [ ! -f "$_SPOTX_LIB" ]; then
    echo "[X] Error: SpotX-Termux shared library not found (~/.spotx-termux/common.sh)" >&2
    echo "    Please run 'bash ~/update-spotify.sh' or 'bash install.sh' to repair." >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$_SPOTX_LIB"

# ------------------------------------------------------------------------------
# Handle --version flag
# ------------------------------------------------------------------------------
if [ "${1:-}" = "--version" ] || [ "${1:-}" = "-V" ]; then
    echo "SpotX-Termux ${SPOTX_TERMUX_VERSION}"
    exit 0
fi

# ------------------------------------------------------------------------------
# Handle --doctor / --status flag
# ------------------------------------------------------------------------------
if [ "${1:-}" = "--doctor" ] || [ "${1:-}" = "doctor" ] || [ "${1:-}" = "--status" ] || [ "${1:-}" = "status" ]; then
    shift
    if [ -x "${HOME}/doctor-spotify.sh" ]; then
        exec "$HOME/doctor-spotify.sh" "$@"
    elif [ -n "${_start_script_dir:-}" ] && [ -f "${_start_script_dir}/doctor.sh" ]; then
        exec bash "${_start_script_dir}/doctor.sh" "$@"
    elif command -v spotify-doctor >/dev/null 2>&1; then
        exec spotify-doctor "$@"
    else
        echo -e "${RED}${BOLD}[X] spotify-doctor not found.${CLR} Please run: ${CYAN}bash install.sh${CLR}" >&2
        exit 1
    fi
fi

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

    echo -e "${GREEN}${BOLD}[OK] SpotX Spotify stopped successfully.${CLR}"
    exit 0
fi

# ------------------------------------------------------------------------------
# Check prerequisites
# ------------------------------------------------------------------------------
if ! command -v proot-distro > /dev/null 2>&1; then
    echo -e "${RED}${BOLD}[X ] Error: proot-distro is not installed!${CLR}"
    echo -e "${YELLOW}Please run the installer first: bash install.sh${CLR}"
    exit 1
fi

echo -e "${CYAN}${BOLD}[*] Launching SpotX Spotify on Android Termux...${CLR}"

# 0. Acquire Termux Wake-Lock to prevent Android CPU sleep when screen is off
if command -v termux-wake-lock > /dev/null 2>&1; then
    termux-wake-lock 2>/dev/null || true
fi

# 1. PulseAudio Audio Bridge (TCP 127.0.0.1 + OpenSL ES Android Sink)
PULSE_CONFIG_DIR="${HOME}/.config/pulse"
mkdir -p "$PULSE_CONFIG_DIR"
cat << 'PULSE_CONF' > "${PULSE_CONFIG_DIR}/daemon.conf"
exit-idle-time = -1
default-fragments = 8
default-fragment-size-msec = 25
resample-method = speex-float-1
default-sample-rate = 48000
alternate-sample-rate = 44100
default-sample-channels = 2
high-priority = yes
realtime-scheduling = no
PULSE_CONF

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
fi

if ! pgrep -x "pulseaudio" > /dev/null 2>&1; then
    echo -e "${CYAN}[+] Starting PulseAudio daemon with OpenSL ES sink...${CLR}"
    pulseaudio --start \
        --load="module-native-protocol-tcp auth-ip-acl=127.0.0.1 auth-anonymous=1" \
        --load="module-sles-sink" \
        --exit-idle-time=-1 2>/dev/null || true
else
    # Ensure SLES sink and TCP protocol modules are loaded even if pulse was started earlier
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

    # Remove Android media notification first (before killing the bridge)
    if command -v termux-notification-remove >/dev/null 2>&1; then
        termux-notification-remove "spotx-player" 2>/dev/null || true
    fi

    # Stop Android notification media bridge
    if [ -n "${NOTIFY_BRIDGE_PID:-}" ]; then
        kill "$NOTIFY_BRIDGE_PID" 2>/dev/null || true
    fi
    pkill -f "spotx-media.fifo" 2>/dev/null || true
    rm -f "${TERMUX_TMP}/spotx-media.fifo" "${TERMUX_TMP}/spotx-control.fifo" "${TERMUX_TMP}/spotx-media.status" "${TERMUX_TMP}/spotx-media.status.tmp" 2>/dev/null || true

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

    # Release Android CPU wake-lock
    if command -v termux-wake-unlock > /dev/null 2>&1; then
        termux-wake-unlock 2>/dev/null || true
    fi

    # Restore terminal mode
    stty sane 2>/dev/null || true

    echo -e "${GREEN}${BOLD}[OK] SpotX Spotify closed cleanly.${CLR}"
    exit 0
}

# Trap signals: Ctrl+C (INT), SIGTERM (TERM), SIGHUP (HUP), and normal script exit (EXIT)
trap cleanup EXIT INT TERM HUP

# 5. Start Android Media Notification Bridge if termux-notification is available
NOTIFY_BRIDGE_PID=""
if command -v termux-notification >/dev/null 2>&1; then
    # Cleanup any orphan notification left by a previous session killed with SIGKILL
    # (trap cleanup is not called on SIGKILL, so we clean up proactively here)
    if command -v termux-notification-remove >/dev/null 2>&1; then
        termux-notification-remove "spotx-player" 2>/dev/null || true
    fi

    mkdir -p "${TERMUX_TMP}"
    rm -f "${TERMUX_TMP}/spotx-media.fifo"
    mkfifo "${TERMUX_TMP}/spotx-media.fifo" 2>/dev/null || true

    if [ -p "${TERMUX_TMP}/spotx-media.fifo" ]; then
        (
            while [ -p "${TERMUX_TMP}/spotx-media.fifo" ]; do
                while read -r line; do
                    [ -z "$line" ] && continue
                    status="${line%%:::*}"
                    rest="${line#*:::}"
                    artist="${rest%%:::*}"
                    title="${rest#*:::}"

                    title="${title:-SpotX Spotify}"
                    artist="${artist:-Termux PRoot}"

                    local_title="$title"
                    if [ "$status" = "Paused" ]; then
                        local_title="[Paused] $title"
                    fi

                    # Resolve the control script path directly so that termux-api can execute it.
                    # We MUST bypass the $PREFIX/bin wrappers because termux-api drops the $HOME 
                    # variable, which the wrappers rely on. The target script itself exports it safely.
                    ctrl_bin="${HOME:-/data/data/com.termux/files/home}/control-spotify.sh"

                    notification_args=(
                        --id "spotx-player"
                        --title "$local_title"
                        --content "$artist"
                        --icon "audiotrack"
                        --alert-once
                        --priority max
                        --type media
                        --media-previous "${ctrl_bin} previous"
                        --media-next "${ctrl_bin} next"
                    )

                    if [ "$status" = "Paused" ]; then
                        notification_args+=(--media-play "${ctrl_bin} play-pause")
                    else
                        notification_args+=(--media-pause "${ctrl_bin} play-pause")
                    fi

                    termux-notification "${notification_args[@]}" >/dev/null 2>&1 || true
                done < "${TERMUX_TMP}/spotx-media.fifo" 2>/dev/null || true
                sleep 0.2
            done
        ) &
        NOTIFY_BRIDGE_PID=$!
    fi
fi

# 6. Execute Spotify inside PRoot Ubuntu container in background
echo -e "${GREEN}${BOLD}[OK] Starting Spotify in Ubuntu container...${CLR}"
# Filter known PRoot futex warnings that occur when threads are killed
proot-distro login ubuntu --shared-tmp -- env DISPLAY=:0 PULSE_SERVER=tcp:127.0.0.1:4713 /usr/local/bin/spotify-termux "$@" 2> >(grep -v "The futex facility returned an unexpected error code" >&2) &
SPOTIFY_PID=$!

# Wait for Spotify process to finish
wait "$SPOTIFY_PID" 2>/dev/null || true
