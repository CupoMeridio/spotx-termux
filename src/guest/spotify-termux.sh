#!/usr/bin/env bash
# ==============================================================================
# spotify-termux - Environment and flags runner for Spotify inside PRoot
# Installed by guest-setup.sh as /usr/local/bin/spotify-termux and launched by
# the host's start-spotify.sh through 'proot-distro login --shared-tmp'.
# ==============================================================================
export DISPLAY="${DISPLAY:-:0}"
export PULSE_SERVER="${PULSE_SERVER:-tcp:127.0.0.1:4713}"
export PULSE_LATENCY_MSEC="${PULSE_LATENCY_MSEC:-500}"
export LIBGL_ALWAYS_SOFTWARE=1
export GDK_BACKEND=x11

# Clear stale GPU cache which causes black screen on restarted sessions
rm -rf "${HOME:-/root}/.cache/spotify/GPUCache" "${HOME:-/root}/.config/spotify/GPUCache" /root/.cache/spotify/GPUCache 2>/dev/null || true

# Initialize D-Bus session bus if needed
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] || [ "${DBUS_SESSION_BUS_ADDRESS}" = "disabled:" ]; then
    if command -v dbus-launch >/dev/null 2>&1; then
        dbus-uuidgen --ensure 2>/dev/null || true
        eval "$(dbus-launch --sh-syntax 2>/dev/null)" || true
    fi
fi

# Export D-Bus session bus address to shared tmp
if [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
    echo "$DBUS_SESSION_BUS_ADDRESS" > /tmp/spotx-dbus-address 2>/dev/null || true
    echo "export DBUS_SESSION_BUS_ADDRESS=\"$DBUS_SESSION_BUS_ADDRESS\"" > /tmp/spotx-dbus.env 2>/dev/null || true
fi

# Start background media control and metadata bridge if playerctl is present
BRIDGE_PID=""
META_PID=""
if command -v playerctl >/dev/null 2>&1; then
    # 1. Listen for host control commands (play, pause, next, previous) via FIFO
    (
        rm -f /tmp/spotx-control.fifo
        mkfifo /tmp/spotx-control.fifo 2>/dev/null || true
        if [ -p /tmp/spotx-control.fifo ]; then
            exec 3<> /tmp/spotx-control.fifo
            while read -r -u 3 cmd; do
                case "$cmd" in
                    play-pause) playerctl -p spotify play-pause 2>/dev/null || true ;;
                    play)       playerctl -p spotify play 2>/dev/null || true ;;
                    pause)      playerctl -p spotify pause 2>/dev/null || true ;;
                    next)       playerctl -p spotify next 2>/dev/null || true ;;
                    previous)   playerctl -p spotify previous 2>/dev/null || true ;;
                    quit|stop)  break ;;
                esac
            done
            exec 3>&-
        fi
    ) &
    BRIDGE_PID=$!

    # 2. Monitor Spotify MPRIS metadata and playback status changes
    (
        for ((i=1; i<=40; i++)); do
            if playerctl -p spotify status >/dev/null 2>&1; then
                break
            fi
            sleep 0.5
        done
        if playerctl -p spotify status >/dev/null 2>&1; then
            WRITER_PID=""
            playerctl -p spotify metadata --format '{{status}}:::{{artist}}:::{{title}}' --follow 2>/dev/null | while IFS= read -r line; do
                [ -z "$line" ] && continue
                echo "$line" > /tmp/spotx-media.status.tmp 2>/dev/null && mv -f /tmp/spotx-media.status.tmp /tmp/spotx-media.status 2>/dev/null || true
                if [ -p /tmp/spotx-media.fifo ]; then
                    # Opening a FIFO blocks until a reader appears. At most one writer is
                    # pending: a newer update replaces the previous one (its metadata is
                    # stale anyway; timeout forwards the TERM to its child), and the 5s
                    # bound means a missing host bridge never leaves processes behind.
                    if [ -n "$WRITER_PID" ]; then
                        kill "$WRITER_PID" 2>/dev/null || true
                    fi
                    timeout 5 sh -c 'echo "$1" > /tmp/spotx-media.fifo' _ "$line" 2>/dev/null &
                    WRITER_PID=$!
                fi
            done
        fi
    ) &
    META_PID=$!
fi

# Launch Matchbox window manager to automatically adapt Spotify to full screen
WM_PID=""
if command -v matchbox-window-manager >/dev/null 2>&1; then
    matchbox-window-manager -use_titlebar no &
    WM_PID=$!
elif command -v openbox >/dev/null 2>&1; then
    openbox &
    WM_PID=$!
fi

# Configure UI scaling factor for high-DPI smartphone touch screens (default: 1.5)
SCALE_FACTOR="${SPOTIFY_SCALE:-1.5}"

# Filter known benign warnings from stderr that are harmless on PRoot/Android:
#   - libayatana-appindicator: deprecation notice emitted by the library at load time;
#     the tray icon still works normally.
#   - cannot open /proc/bus/pci/devices: libpci3 tries to scan the PCI bus for GPU
#     detection; /proc/bus/pci does not exist on Android and libpci falls back safely.
_SPOTX_FILTER='libayatana-appindicator is deprecated|cannot open /proc/bus/pci/devices'
/usr/bin/spotify \
    --start-maximized \
    --force-device-scale-factor="$SCALE_FACTOR" \
    --disable-gpu \
    --disable-dev-shm-usage \
    "$@" 2> >(grep -vE "$_SPOTX_FILTER" >&2)
SPOTIFY_EXIT_CODE=$?

# Terminate media bridge and window manager on exit
if [ -n "$BRIDGE_PID" ]; then
    kill "$BRIDGE_PID" 2>/dev/null || true
fi
if [ -n "$META_PID" ]; then
    kill "$META_PID" 2>/dev/null || true
fi
if [ -n "$WM_PID" ]; then
    kill "$WM_PID" 2>/dev/null || true
fi
rm -f /tmp/spotx-control.fifo /tmp/spotx-media.status /tmp/spotx-media.status.tmp /tmp/spotx-dbus-address /tmp/spotx-dbus.env 2>/dev/null || true

exit $SPOTIFY_EXIT_CODE
