#!/usr/bin/env bash
# ==============================================================================
# control-spotify.sh - Termux host media playback controller for SpotX Spotify
# Repository: https://github.com/CupoMeridio/spotx-termux
# ==============================================================================
set -euo pipefail

# Resolve SpotX-Termux project version (CalVer: YYYY.MM.DD)
SPOTX_TERMUX_VERSION=""
if [ -f "${HOME}/.spotx-termux-version" ]; then
    SPOTX_TERMUX_VERSION=$(cat "${HOME}/.spotx-termux-version" 2>/dev/null | tr -d '[:space:]')
fi
if [ -z "$SPOTX_TERMUX_VERSION" ] && [ -n "${BASH_SOURCE[0]:-}" ]; then
    _ctrl_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
    if [ -f "${_ctrl_dir}/../VERSION" ]; then
        SPOTX_TERMUX_VERSION=$(cat "${_ctrl_dir}/../VERSION" 2>/dev/null | tr -d '[:space:]')
    elif [ -f "${_ctrl_dir}/VERSION" ]; then
        SPOTX_TERMUX_VERSION=$(cat "${_ctrl_dir}/VERSION" 2>/dev/null | tr -d '[:space:]')
    fi
fi
: "${SPOTX_TERMUX_VERSION:=unknown}"

# ANSI colors
CLR='\033[0m'
BOLD='\033[1m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
RED='\033[0;31m'

TMP_DIR="${TMPDIR:-${PREFIX:-/data/data/com.termux/files/usr}/tmp}"
CONTROL_FIFO="${TMP_DIR}/spotx-control.fifo"
STATUS_FILE="${TMP_DIR}/spotx-media.status"

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
