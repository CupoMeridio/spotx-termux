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
# shellcheck source=common.sh
source "$_SPOTX_LIB"
if [ "${SPOTX_LIB_API:-1}" -lt 2 ]; then
    echo "[X] Error: the installed SpotX-Termux library is outdated (${_SPOTX_LIB})." >&2
    echo "    Please repair the installation with:" >&2
    echo "    curl -fsSL https://raw.githubusercontent.com/CupoMeridio/spotx-termux/main/install.sh | bash" >&2
    exit 1
fi

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
    # A running launcher notices Spotify exiting and runs its own (idempotent) cleanup
    stop_spotx_session
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

# ------------------------------------------------------------------------------
# Single-session guard
# A second launch (e.g. a double tap on the widget) must not start another
# instance: the duplicate Spotify would exit immediately and this script's EXIT
# trap would then tear down the session that is already playing.
# ------------------------------------------------------------------------------
session_owner_alive() {
    local pid=""
    pid="$(cat "$SESSION_LOCK" 2>/dev/null || true)"
    [ -n "$pid" ] && [ "$pid" != "$$" ] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    # Guard against PID reuse: the owner must still be a SpotX launcher
    tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null | grep -qi "spotify"
}

acquire_session_lock() {
    mkdir -p "$TERMUX_TMP"
    # noclobber makes the create atomic: only one concurrent launcher can win
    if ( set -o noclobber; echo "$$" > "$SESSION_LOCK" ) 2>/dev/null; then
        return 0
    fi
    session_owner_alive && return 1
    # Stale lock left by a launcher killed with SIGKILL: take it over
    rm -f "$SESSION_LOCK"
    ( set -o noclobber; echo "$$" > "$SESSION_LOCK" ) 2>/dev/null
}

release_session_lock() {
    if [ "$(cat "$SESSION_LOCK" 2>/dev/null || true)" = "$$" ]; then
        rm -f "$SESSION_LOCK"
    fi
}

spotify_process_running() {
    pgrep -x "spotify" > /dev/null 2>&1 || pgrep -f "/usr/share/spotify/spotify" > /dev/null 2>&1
}

focus_running_session() {
    echo -e "${CYAN}${BOLD}[*] Spotify is already running: bringing Termux-X11 to foreground.${CLR}"
    echo -e "${DIM}    To restart it cleanly, run: spotify-stop && spotify${CLR}"
    am start --user 0 -n com.termux.x11/com.termux.x11.MainActivity >/dev/null 2>&1 || true
    exit 0
}

if ! acquire_session_lock; then
    focus_running_session
fi
# Spotify still alive without a live launcher (e.g. launcher was SIGKILLed): do not
# start a duplicate either, just show the existing window.
if spotify_process_running; then
    release_session_lock
    focus_running_session
fi

echo -e "${CYAN}${BOLD}[*] Launching SpotX Spotify on Android Termux...${CLR}"

# 0. Acquire Termux Wake-Lock to prevent Android CPU sleep when screen is off
if command -v termux-wake-lock > /dev/null 2>&1; then
    termux-wake-lock 2>/dev/null || true
fi

# 1. PulseAudio Audio Bridge (TCP 127.0.0.1 + OpenSL ES Android Sink)
write_pulse_config

# Spotify is guaranteed not to be running here (single-session guard above), so
# reload the PulseAudio daemon to pick up the optimal configuration
pulseaudio -k 2>/dev/null || pkill -x pulseaudio 2>/dev/null || true
for ((k=1; k<=10; k++)); do
    if ! pgrep -x pulseaudio >/dev/null 2>&1; then
        break
    fi
    sleep 0.1
done
pkill -9 -x pulseaudio 2>/dev/null || true

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
# Spotify is not running (single-session guard), so clear any stale/frozen Termux-X11 instance
pkill -f "termux.x11" 2>/dev/null || true
pkill -f "termux-x11" 2>/dev/null || true
sleep 0.2

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

    # Stop the host side of the notification bridge before tearing everything down
    if [ -n "${NOTIFY_BRIDGE_PID:-}" ]; then
        kill "$NOTIFY_BRIDGE_PID" 2>/dev/null || true
    fi

    stop_spotx_session

    # Suppress bash job control output by disowning before kill
    if [ -n "${SPOTIFY_PID:-}" ]; then
        disown "$SPOTIFY_PID" 2>/dev/null || true
        kill -9 "$SPOTIFY_PID" 2>/dev/null || true
    fi

    # Restore terminal mode
    stty sane 2>/dev/null || true

    release_session_lock

    echo -e "${GREEN}${BOLD}[OK] SpotX Spotify closed cleanly.${CLR}"
    exit 0
}

# Trap signals: Ctrl+C (INT), SIGTERM (TERM), SIGHUP (HUP), and normal script exit (EXIT)
trap cleanup EXIT INT TERM HUP

# 5. Start Android Media Notification Bridge if Termux:API is available
NOTIFY_BRIDGE_PID=""
if has_termux_api; then
    # Cleanup any orphan notification left by a previous session killed with SIGKILL
    # (trap cleanup is not called on SIGKILL, so we clean up proactively here)
    remove_notification "$PLAYER_NOTIFICATION_ID"

    mkdir -p "${TERMUX_TMP}"
    rm -f "$MEDIA_FIFO"
    mkfifo "$MEDIA_FIFO" 2>/dev/null || true

    if [ -p "$MEDIA_FIFO" ]; then
        (
            while [ -p "$MEDIA_FIFO" ]; do
                while read -r line; do
                    [ -z "$line" ] && continue
                    status="${line%%:::*}"
                    rest="${line#*:::}"
                    artist="${rest%%:::*}"
                    title="${rest#*:::}"

                    title="${title:-SpotX Spotify}"
                    artist="${artist:-Termux PRoot}"

                    local_title="$title"
                    play_btn="❙❙ Pause"
                    if [ "$status" = "Paused" ]; then
                        local_title="[Paused] $title"
                        play_btn="▶ Play"
                    fi

                    # Resolve the control script path directly so that termux-api can execute it.
                    # We MUST bypass the $PREFIX/bin wrappers because termux-api drops the $HOME
                    # variable, which the wrappers rely on. The target script itself exports it safely.
                    ctrl_bin="${HOME:-/data/data/com.termux/files/home}/control-spotify.sh"

                    run_with_timeout 2 termux-notification \
                        --id "$PLAYER_NOTIFICATION_ID" \
                        --title "$local_title" \
                        --content "$artist" \
                        --icon "audiotrack" \
                        --alert-once \
                        --priority max \
                        --button1 "⏮ Prev" \
                        --button1-action "${ctrl_bin} previous" \
                        --button2 "$play_btn" \
                        --button2-action "${ctrl_bin} play-pause" \
                        --button3 "⏭ Next" \
                        --button3-action "${ctrl_bin} next" >/dev/null 2>&1 || true
                done < "$MEDIA_FIFO" 2>/dev/null || true
                sleep 0.2
            done
        ) &
        NOTIFY_BRIDGE_PID=$!
    fi
fi

# 6. Execute Spotify inside PRoot Ubuntu container in background
echo -e "${GREEN}${BOLD}[OK] Starting Spotify in Ubuntu container...${CLR}"
# Filter known PRoot futex warnings that occur when threads are killed
proot-distro login "$CONTAINER_NAME" --shared-tmp -- env DISPLAY=:0 PULSE_SERVER=tcp:127.0.0.1:4713 /usr/local/bin/spotify-termux "$@" 2> >(grep -v "The futex facility returned an unexpected error code" >&2) &
SPOTIFY_PID=$!

# Wait for Spotify process to finish
wait "$SPOTIFY_PID" 2>/dev/null || true
