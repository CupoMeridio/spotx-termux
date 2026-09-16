#!/usr/bin/env bash
# ==============================================================================
# control-spotify.sh - Termux host media playback controller for SpotX Spotify
# Repository: https://github.com/CupoMeridio/spotx-termux
# ==============================================================================
set -euo pipefail

# ------------------------------------------------------------------------------
# Load SpotX-Termux Shared Library
# ------------------------------------------------------------------------------
_SPOTX_LIB=""
if [ -n "${BASH_SOURCE[0]:-}" ]; then
    _SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
    if [ -f "${_SCRIPT_DIR}/common.sh" ]; then
        _SPOTX_LIB="${_SCRIPT_DIR}/common.sh"
    elif [ -f "${_SCRIPT_DIR}/src/common.sh" ]; then
        _SPOTX_LIB="${_SCRIPT_DIR}/src/common.sh"
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

show_help() {
    cat << EOF
SpotX-Termux Media Controller (v${SPOTX_TERMUX_VERSION})

Usage:
  spotify-control [COMMAND]

Commands:
  play-pause, toggle   Toggle playback (Play/Pause)
  play                 Start playback
  pause                Pause playback
  next                 Skip to next track
  prev, previous       Skip to previous track
  status               Display current playback status and track info
  --version, -V        Show version information
  --help, -h           Show this help message

Examples:
  spotify-control play-pause
  spotify-control next
  spotify-control status
EOF
}

# Handle version and help flags
if [ "${1:-}" = "--version" ] || [ "${1:-}" = "-V" ]; then
    echo "SpotX-Termux ${SPOTX_TERMUX_VERSION}"
    exit 0
fi

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    show_help
    exit 0
fi

CMD="${1:-play-pause}"

case "$CMD" in
    play-pause|toggle)
        DISPATCH="play-pause"
        ;;
    play)
        DISPATCH="play"
        ;;
    pause)
        DISPATCH="pause"
        ;;
    next)
        DISPATCH="next"
        ;;
    prev|previous)
        DISPATCH="previous"
        ;;
    status)
        if [ -f "$STATUS_FILE" ]; then
            line=$(head -n 1 "$STATUS_FILE" 2>/dev/null || true)
            if [ -n "$line" ]; then
                status="${line%%:::*}"
                rest="${line#*:::}"
                artist="${rest%%:::*}"
                title="${rest#*:::}"
                echo -e "${CYAN}${BOLD}Status:${CLR} ${status}"
                echo -e "${CYAN}${BOLD}Artist:${CLR} ${artist}"
                echo -e "${CYAN}${BOLD}Title:${CLR}  ${title}"
                exit 0
            fi
        fi
        echo -e "${YELLOW}[!] Playback status unavailable. Is Spotify playing?${CLR}"
        exit 0
        ;;
    *)
        echo -e "${RED}[X] Unknown command: ${CMD}${CLR}" >&2
        show_help
        exit 1
        ;;
esac

# Check if control FIFO exists and is a named pipe
if [ ! -p "$CONTROL_FIFO" ]; then
    echo -e "${YELLOW}[!] SpotX control bridge is not active.${CLR}"
    echo -e "${YELLOW}    Make sure Spotify is running: spotify${CLR}"
    exit 1
fi

# Send action to control FIFO without blocking
if echo "$DISPATCH" > "$CONTROL_FIFO" 2>/dev/null; then
    exit 0
else
    echo -e "${RED}[X] Failed to send command to SpotX control bridge.${CLR}" >&2
    exit 1
fi
