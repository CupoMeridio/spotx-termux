#!/usr/bin/env bash
# ==============================================================================
# common.sh - Shared runtime library for SpotX-Termux host scripts
# Repository: https://github.com/CupoMeridio/spotx-termux
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. Environment & Architecture Detection
# ------------------------------------------------------------------------------
IS_TERMUX=false
if [ -n "${TERMUX_VERSION:-}" ] || [ -d "/data/data/com.termux" ] || [[ "${PREFIX:-}" == *"com.termux"* ]]; then
    IS_TERMUX=true
fi
ARCH="$(uname -m 2>/dev/null || echo 'unknown')"

# ------------------------------------------------------------------------------
# 2. Shared Directory Paths & IPC Endpoints
# ------------------------------------------------------------------------------
SPOTX_DIR="${HOME}/.spotx-termux"
LOG_DIR="${SPOTX_DIR}/logs"
TERMUX_TMP="${TMPDIR:-${PREFIX:-/data/data/com.termux/files/usr}/tmp}"
CONTROL_FIFO="${TERMUX_TMP}/spotx-control.fifo"
MEDIA_FIFO="${TERMUX_TMP}/spotx-media.fifo"
STATUS_FILE="${TERMUX_TMP}/spotx-media.status"

# ------------------------------------------------------------------------------
# 3. Version Resolution (Single Source of Truth CalVer: YYYY.MM.DD[.N])
# ------------------------------------------------------------------------------
resolve_spotx_version() {
    local ver=""
    local dir=""
    if [ -n "${BASH_SOURCE[0]:-}" ]; then
        dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
    fi

    # Check local repository root
    if [ -n "$dir" ]; then
        if [ -f "${dir}/VERSION" ]; then
            ver=$(cat "${dir}/VERSION" 2>/dev/null | tr -d '[:space:]')
        elif [ -f "${dir}/../VERSION" ]; then
            ver=$(cat "${dir}/../VERSION" 2>/dev/null | tr -d '[:space:]')
        fi
    fi

    # Check installed version marker files in $HOME
    if [ -z "$ver" ] && [ -f "${SPOTX_DIR}/VERSION" ]; then
        ver=$(cat "${SPOTX_DIR}/VERSION" 2>/dev/null | tr -d '[:space:]')
    fi
    if [ -z "$ver" ] && [ -f "${HOME}/.spotx-termux-version" ]; then
        ver=$(cat "${HOME}/.spotx-termux-version" 2>/dev/null | tr -d '[:space:]')
    fi

    echo "${ver:-unknown}"
}

SPOTX_TERMUX_VERSION="$(resolve_spotx_version)"

# ------------------------------------------------------------------------------
# 4. ANSI Color Definitions
# ------------------------------------------------------------------------------
CLR='\033[0m'
BOLD='\033[1m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
DIM='\033[2m'

# ------------------------------------------------------------------------------
# 5. Logging Configuration and Functions
# ------------------------------------------------------------------------------
LOG_FILE=""

setup_logging() {
    local log_name="${1:-spotx.log}"
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    LOG_FILE="${LOG_DIR}/${log_name}"

    if [ -f "$LOG_FILE" ]; then
        mv -f "$LOG_FILE" "${LOG_FILE}.old" 2>/dev/null || true
    fi

    {
        echo "============================================================"
        echo "SpotX-Termux Log: $(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || true)"
        echo "Version: ${SPOTX_TERMUX_VERSION}"
        echo "Architecture: ${ARCH}"
        echo "Prefix: ${PREFIX:-/data/data/com.termux/files/usr}"
        echo "============================================================"
    } > "$LOG_FILE" 2>/dev/null || true
}

log_msg() {
    local level="$1"
    shift
    local msg="$*"
    if [ -n "${LOG_FILE:-}" ] && [ -f "${LOG_FILE:-}" ]; then
        local clean_msg
        clean_msg=$(sed -E 's/\x1B\[[0-9;]*[a-zA-Z]//g' <<< "$msg" 2>/dev/null || echo "$msg")
        local timestamp
        timestamp=$(date "+%Y-%m-%d %H:%M:%S" 2>/dev/null || true)
        echo "[$timestamp] [$level] $clean_msg" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

info()    { echo -e "${CYAN}${BOLD}[*]${CLR} $*"; log_msg "INFO" "$*"; }
success() { echo -e "${GREEN}${BOLD}[OK]${CLR} $*"; log_msg "OK" "$*"; }
warn()    { echo -e "${YELLOW}${BOLD}[! ]${CLR} $*"; log_msg "WARN" "$*"; }
error()   { echo -e "${RED}${BOLD}[X ]${CLR} $*" >&2; log_msg "ERROR" "$*"; }

# ------------------------------------------------------------------------------
# 6. Android System Notification Helper (via Termux:API)
# ------------------------------------------------------------------------------
notify_user() {
    local title="$1"
    local content="$2"
    local icon="${3:-terminal}"
    if command -v termux-notification >/dev/null 2>&1; then
        termux-notification \
            --title "$title" \
            --content "$content" \
            --id "spotx-status" \
            --priority "high" \
            --icon "$icon" >/dev/null 2>&1 || true
    fi
}
