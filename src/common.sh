#!/usr/bin/env bash
# ==============================================================================
# common.sh - Shared runtime library for SpotX-Termux host scripts
# Repository: https://github.com/CupoMeridio/spotx-termux
#
# Sourced by every host script (install, start, stop, update, doctor, control,
# uninstall). It must stay free of side effects other than defining variables
# and functions. guest-setup.sh runs inside the container and does NOT use it.
# ==============================================================================

# Bumped whenever scripts start relying on new functions from this library, so a
# script loaded together with an older installed copy can detect the mismatch.
# Each script checks the minimum it needs:
#   2 - shared tables, fetch/sync helpers, stop_spotx_session (start, uninstall)
#   3 - probe_container (doctor)
#   4 - stage_guest_bundle (update)
SPOTX_LIB_API=4

# ------------------------------------------------------------------------------
# 1. Environment & Architecture Detection
# ------------------------------------------------------------------------------
IS_TERMUX=false
if [ -n "${TERMUX_VERSION:-}" ] || [ -d "/data/data/com.termux" ] || [[ "${PREFIX:-}" == *"com.termux"* ]]; then
    IS_TERMUX=true
fi
ARCH="$(uname -m 2>/dev/null || echo 'unknown')"

# ------------------------------------------------------------------------------
# 2. Project Constants, Shared Paths & IPC Endpoints
# ------------------------------------------------------------------------------
SPOTX_REPO_RAW="https://raw.githubusercontent.com/CupoMeridio/spotx-termux/main"
CONTAINER_NAME="ubuntu"
TERMUX_SHEBANG="#!/data/data/com.termux/files/usr/bin/bash"

SPOTX_DIR="${HOME}/.spotx-termux"
LOG_DIR="${SPOTX_DIR}/logs"
SHORTCUTS_DIR="${HOME}/.shortcuts"
TERMUX_TMP="${TMPDIR:-${PREFIX:-/data/data/com.termux/files/usr}/tmp}"
TERMUX_BIN="${PREFIX:-/data/data/com.termux/files/usr}/bin"
CONTROL_FIFO="${TERMUX_TMP}/spotx-control.fifo"
MEDIA_FIFO="${TERMUX_TMP}/spotx-media.fifo"
STATUS_FILE="${TERMUX_TMP}/spotx-media.status"
SESSION_LOCK="${TERMUX_TMP}/spotx-session.pid"
PLAYER_NOTIFICATION_ID="spotx-player"

# Directory holding this library, and the repository checkout it belongs to (if any).
# SPOTX_REPO_ROOT is set only when running from a git checkout (<root>/src/common.sh);
# installed copies (~/.spotx-termux/common.sh) and bootstrap copies leave it empty,
# which makes fetch_repo_file download from GitHub instead.
SPOTX_LIB_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ]; then
    SPOTX_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
fi
SPOTX_REPO_ROOT=""
if [ -n "$SPOTX_LIB_DIR" ] && [ "$(basename "$SPOTX_LIB_DIR")" = "src" ] && \
   [ -f "${SPOTX_LIB_DIR}/../VERSION" ] && [ -f "${SPOTX_LIB_DIR}/../install.sh" ]; then
    SPOTX_REPO_ROOT="$(cd "${SPOTX_LIB_DIR}/.." && pwd)"
fi

# ------------------------------------------------------------------------------
# 3. Validation Helpers
# A fetched file must pass these checks before it replaces anything installed,
# so that an HTTP error page (404 / rate limit) is never installed as a script.
# ------------------------------------------------------------------------------
is_valid_script() {
    [ -s "$1" ] && [ "$(head -c 2 "$1" 2>/dev/null)" = "#!" ]
}

is_nonempty_file() {
    [ -s "$1" ]
}

is_valid_version() {
    [[ "${1:-}" =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]{2}(\.[0-9]+)?$ ]]
}

# ------------------------------------------------------------------------------
# 4. Version Resolution (Single Source of Truth CalVer: YYYY.MM.DD[.N])
# Order matters: the copy shipped next to this library (repo checkout or freshly
# bootstrapped tmp copy) wins over the markers of a previous installation.
# ------------------------------------------------------------------------------
_read_version_file() {
    local ver=""
    [ -f "$1" ] || return 1
    ver="$(tr -d '[:space:]' < "$1" 2>/dev/null || true)"
    is_valid_version "$ver" || return 1
    echo "$ver"
}

resolve_spotx_version() {
    local candidate
    for candidate in \
        "${SPOTX_LIB_DIR:+${SPOTX_LIB_DIR}/VERSION}" \
        "${SPOTX_LIB_DIR:+${SPOTX_LIB_DIR}/../VERSION}" \
        "${SPOTX_DIR}/VERSION" \
        "${HOME}/.spotx-termux-version" \
        "${TERMUX_TMP}/VERSION"; do
        [ -n "$candidate" ] || continue
        if _read_version_file "$candidate"; then
            return 0
        fi
    done
    echo "unknown"
}

SPOTX_TERMUX_VERSION="$(resolve_spotx_version)"

write_version_markers() {
    local ver="$1"
    is_valid_version "$ver" || return 0
    mkdir -p "$SPOTX_DIR" 2>/dev/null || true
    echo "$ver" > "${HOME}/.spotx-termux-version" 2>/dev/null || true
    echo "$ver" > "${SPOTX_DIR}/VERSION" 2>/dev/null || true
}

# ------------------------------------------------------------------------------
# 5. ANSI Color Definitions
# ------------------------------------------------------------------------------
CLR='\033[0m'
BOLD='\033[1m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
DIM='\033[2m'

# ------------------------------------------------------------------------------
# 6. Logging Configuration and Functions
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
# 7. Process & Terminal Helpers
# ------------------------------------------------------------------------------
# run_with_timeout <seconds> <command...>
# Termux:API calls can hang forever when the companion APK is missing or blocked
# (Android 14+); bound them whenever coreutils 'timeout' is available.
run_with_timeout() {
    local secs="$1"
    shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        "$@"
    fi
}

# True when the user can be asked something (stdin is a terminal, or a controlling
# terminal can be opened even though stdin is a pipe, as with 'curl ... | bash').
has_tty() {
    [ -t 0 ] || { : < /dev/tty; } 2>/dev/null
}

# prompt_tty <prompt> <var_name> [default]
# Reads an answer from the terminal, never from stdin when stdin is the piped
# script itself. An empty answer, or no terminal at all, yields the default.
# printf -v assigns without eval, so the answer is never executed.
prompt_tty() {
    local prompt_text="$1"
    local var_name="$2"
    local default_val="${3:-}"
    local reply=""
    if [ -t 0 ]; then
        read -rp "$prompt_text" reply || true
    elif has_tty; then
        read -rp "$prompt_text" reply < /dev/tty || true
    fi
    printf -v "$var_name" '%s' "${reply:-$default_val}"
}

# ------------------------------------------------------------------------------
# 8. Android System Notification Helpers (via Termux:API)
# ------------------------------------------------------------------------------
has_termux_api() {
    [ "${IS_TERMUX:-true}" = true ] || return 1
    command -v termux-notification >/dev/null 2>&1 || return 1
    return 0
}

notify_user() {
    local title="$1"
    local content="$2"
    local icon="${3:-code}"
    if has_termux_api; then
        (
            run_with_timeout 2 termux-notification \
                --title "$title" \
                --content "$content" \
                --id "spotx-status" \
                --priority "high" \
                --icon "$icon" >/dev/null 2>&1 || true
        ) &
    fi
}

remove_notification() {
    local id="$1"
    if has_termux_api && command -v termux-notification-remove >/dev/null 2>&1; then
        run_with_timeout 2 termux-notification-remove "$id" >/dev/null 2>&1 || true
    fi
}

# ------------------------------------------------------------------------------
# 9. PRoot Container Helpers
# ------------------------------------------------------------------------------
is_container_installed() {
    local name="$1"
    local prefix="${PREFIX:-/data/data/com.termux/files/usr}"
    if [ -d "${prefix}/var/lib/proot-distro/containers/${name}" ] || \
       [ -d "${prefix}/var/lib/proot-distro/installed-rootfs/${name}" ] || \
       [ -d "/usr/var/lib/proot-distro/containers/${name}" ] || \
       [ -d "/usr/var/lib/proot-distro/installed-rootfs/${name}" ]; then
        return 0
    fi
    if command -v proot-distro >/dev/null 2>&1; then
        if proot-distro login "$name" -- true >/dev/null 2>&1; then
            return 0
        fi
    fi
    return 1
}

# Copy of guest-setup.sh that guest-setup keeps inside the container (see its --probe mode)
GUEST_SETUP_INSTALLED="/usr/local/lib/spotx-termux/guest-setup.sh"
GUEST_PROBE_KEYS=(GUEST_PROBE_API GUEST_RESPONSIVE GUEST_BOX64_VER GUEST_BOX64_GPU GUEST_WM
                  GUEST_ELF GUEST_VER GUEST_SPOTX GUEST_RUNNER GUEST_PLAYERCTL)

# probe_container
# Runs 'guest-setup.sh --probe' inside the container and sets the GUEST_* variables
# (all empty if the container cannot be probed). This is the only place where the
# host learns the container state: version, ELF integrity, SpotX patch, runner...
# Script source, in order: repo checkout (development), the copy installed inside
# the container (offline), a fresh copy from GitHub (installs predating the probe).
probe_container() {
    local key out="" staged=""
    for key in "${GUEST_PROBE_KEYS[@]}"; do
        printf -v "$key" '%s' ""
    done

    if [ -z "$SPOTX_REPO_ROOT" ]; then
        out=$(proot-distro login "$CONTAINER_NAME" -- bash "$GUEST_SETUP_INSTALLED" --probe 2>/dev/null || true)
    fi
    if [[ "$out" != *"GUEST_PROBE_API="* ]]; then
        out=""
        staged="${TERMUX_TMP}/spotx-guest-probe.$$.sh"
        mkdir -p "$TERMUX_TMP" 2>/dev/null || true
        # Run a staged copy only if it really supports --probe: an older guest-setup.sh
        # would ignore the flag and start a full installation instead.
        if fetch_repo_file "src/guest-setup.sh" "$staged" && grep -q "SPOTX_PROBE_API=" "$staged"; then
            out=$(proot-distro login "$CONTAINER_NAME" --shared-tmp -- bash "/tmp/${staged##*/}" --probe 2>/dev/null || true)
        fi
        rm -f "$staged" 2>/dev/null || true
    fi

    local line val k
    while IFS= read -r line; do
        key="${line%%=*}"
        val="${line#*=}"
        for k in "${GUEST_PROBE_KEYS[@]}"; do
            if [ "$key" = "$k" ]; then
                printf -v "$key" '%s' "$val"
                break
            fi
        done
    done <<< "$out"

    [ "$GUEST_RESPONSIVE" = "yes" ]
}

# Guest bundle staged through the shared tmp: visible in the container as
# /tmp/spotx-guest/guest-setup.sh + /tmp/spotx-guest/guest/* (repo layout of src/)
SPOTX_GUEST_FILES=(spotify-termux.sh spotify-box64-wrapper.sh box64-spotify.rc)
GUEST_STAGING_DIR="${TERMUX_TMP}/spotx-guest"
GUEST_STAGING_IN_CONTAINER="/tmp/spotx-guest/guest-setup.sh"

# stage_guest_bundle: fails only if guest-setup.sh itself cannot be obtained.
# A missing extra file is not fatal: guest-setup.sh downloads it on its own.
stage_guest_bundle() {
    local name validator
    rm -rf "$GUEST_STAGING_DIR"
    mkdir -p "${GUEST_STAGING_DIR}/guest"
    fetch_repo_file "src/guest-setup.sh" "${GUEST_STAGING_DIR}/guest-setup.sh" || return 1
    for name in "${SPOTX_GUEST_FILES[@]}"; do
        case "$name" in
            *.sh) validator=is_valid_script ;;
            *)    validator=is_nonempty_file ;;
        esac
        fetch_repo_file "src/guest/${name}" "${GUEST_STAGING_DIR}/guest/${name}" "$validator" || \
            warn "Could not stage ${name}; the container setup will download it."
    done
    chmod +x "${GUEST_STAGING_DIR}/guest-setup.sh"
}

remove_guest_bundle() {
    rm -rf "$GUEST_STAGING_DIR" 2>/dev/null || true
}

# ------------------------------------------------------------------------------
# 10. Session Shutdown
# Single implementation used by 'spotify --stop', the launcher's exit trap, the
# updater and the uninstaller. Every step is idempotent and best-effort.
# Patterns stay narrow on purpose: 'pkill -f spotify' would also match
# update-spotify.sh / uninstall-spotify.sh and kill the caller itself.
# ------------------------------------------------------------------------------
stop_spotify_processes() {
    pkill -x spotify 2>/dev/null || true
    pkill -f "/usr/share/spotify/spotify" 2>/dev/null || true
    pkill -f "/usr/local/bin/spotify-termux" 2>/dev/null || true
    pkill -x matchbox-window-manager 2>/dev/null || true
    pkill -x openbox 2>/dev/null || true
    sleep 0.3
    pkill -9 -x spotify 2>/dev/null || true
    pkill -9 -f "/usr/share/spotify/spotify" 2>/dev/null || true
    pkill -9 -f "/usr/local/bin/spotify-termux" 2>/dev/null || true
}

stop_display_server() {
    am broadcast -a com.termux.x11.ACTION_STOP -p com.termux.x11 >/dev/null 2>&1 || true
    pkill -f "termux.x11" 2>/dev/null || true
    pkill -f "termux-x11" 2>/dev/null || true
    rm -f "${TERMUX_TMP}/.X0-lock" "${TERMUX_TMP}/.X11-unix/X0" 2>/dev/null || true
}

stop_audio_server() {
    if command -v pulseaudio >/dev/null 2>&1; then
        pulseaudio -k 2>/dev/null || true
    fi
    pkill -x pulseaudio 2>/dev/null || true
    rm -f "${TERMUX_TMP}/pulse-socket" 2>/dev/null || true
}

stop_media_bridge() {
    # Notification removal can take ~1s through Termux:API: don't block shutdown on it
    ( remove_notification "$PLAYER_NOTIFICATION_ID" ) &
    pkill -f "spotx-media.fifo" 2>/dev/null || true
    rm -f "$MEDIA_FIFO" "$CONTROL_FIFO" "$STATUS_FILE" "${STATUS_FILE}.tmp" 2>/dev/null || true
}

stop_spotx_session() {
    stop_media_bridge
    stop_spotify_processes
    stop_display_server
    stop_audio_server
    if command -v termux-wake-unlock >/dev/null 2>&1; then
        termux-wake-unlock 2>/dev/null || true
    fi
}

# ------------------------------------------------------------------------------
# 11. Host Installation Helpers (shared by install.sh and update-spotify.sh)
# ------------------------------------------------------------------------------
# Repository file -> installed location
SPOTX_HOST_FILES=(
    "src/common.sh|${SPOTX_DIR}/common.sh"
    "src/start-spotify.sh|${HOME}/start-spotify.sh"
    "src/update-spotify.sh|${HOME}/update-spotify.sh"
    "src/doctor.sh|${HOME}/doctor-spotify.sh"
    "src/control-spotify.sh|${HOME}/control-spotify.sh"
    "uninstall.sh|${HOME}/uninstall-spotify.sh"
)

# Command in $PREFIX/bin -> installed script and fixed arguments
SPOTX_WRAPPERS=(
    "spotify|start-spotify.sh|"
    "spotify-stop|start-spotify.sh|--stop"
    "spotify-control|control-spotify.sh|"
    "spotify-update|update-spotify.sh|"
    "spotify-doctor|doctor-spotify.sh|"
    "spotify-uninstall|uninstall-spotify.sh|"
)

# Termux:Widget shortcut name -> installed script and fixed arguments
SPOTX_SHORTCUTS=(
    "Spotify|start-spotify.sh|"
    "Spotify-Stop|start-spotify.sh|--stop"
)

# Termux packages providing the commands the scripts need ("package|command")
SPOTX_CORE_PKGS=(
    "proot-distro|proot-distro"
    "pulseaudio|pulseaudio"
    "wget|wget"
    "curl|curl"
    "jq|jq"
)
SPOTX_OPTIONAL_PKGS=(
    "termux-api|termux-notification"
)

# Prints (space separated) the packages of the given "package|command" list whose command is missing
missing_pkgs() {
    local entry pkg cmd missing=()
    for entry in "$@"; do
        pkg="${entry%%|*}"
        cmd="${entry#*|}"
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$pkg")
    done
    echo "${missing[*]}"
}

# fetch_repo_file <repo-relative path> <destination> [validator]
# Copies the file from the local checkout when running from one, otherwise
# downloads it from GitHub. The destination is replaced atomically and only if
# the new content passes the validator (default: is_valid_script).
fetch_repo_file() {
    local rel="$1"
    local dest="$2"
    local validator="${3:-is_valid_script}"
    local tmp="${dest}.tmp.$$"

    mkdir -p "$(dirname "$dest")" 2>/dev/null || true
    if [ -n "$SPOTX_REPO_ROOT" ] && [ -f "${SPOTX_REPO_ROOT}/${rel}" ]; then
        cp "${SPOTX_REPO_ROOT}/${rel}" "$tmp" 2>/dev/null || true
    else
        curl -fsSL "${SPOTX_REPO_RAW}/${rel}?t=$(date +%s)" -o "$tmp" 2>/dev/null || true
    fi

    if "$validator" "$tmp"; then
        mv -f "$tmp" "$dest"
        return 0
    fi
    rm -f "$tmp" 2>/dev/null || true
    return 1
}

# Installs all host scripts as one unit: everything is fetched and validated
# first, and nothing is replaced unless every file is valid. A half-updated set
# (e.g. new scripts with an old common.sh) would otherwise break every command.
sync_host_scripts() {
    local entry rel dest staged=() failed=()
    for entry in "${SPOTX_HOST_FILES[@]}"; do
        rel="${entry%%|*}"
        dest="${entry#*|}"
        if fetch_repo_file "$rel" "${dest}.staged.$$"; then
            staged+=("$dest")
        else
            failed+=("$rel")
        fi
    done

    if [ ${#failed[@]} -gt 0 ]; then
        for dest in "${staged[@]}"; do
            rm -f "${dest}.staged.$$" 2>/dev/null || true
        done
        warn "Could not fetch a valid copy of: ${failed[*]}"
        warn "Installed scripts were left unchanged."
        return 1
    fi

    for dest in "${staged[@]}"; do
        chmod +x "${dest}.staged.$$" 2>/dev/null || true
        mv -f "${dest}.staged.$$" "$dest"
    done
    return 0
}

# write_launcher <file> <installed script> [fixed args]
# Small exec wrapper. $HOME has a fallback because some Android launch contexts
# (Termux:Widget, Termux:API actions) do not always export it.
write_launcher() {
    local file="$1"
    local script="$2"
    local args="${3:-}"
    mkdir -p "$(dirname "$file")" 2>/dev/null || true
    printf '%s\nexec "${HOME:-/data/data/com.termux/files/home}/%s" %s"$@"\n' \
        "$TERMUX_SHEBANG" "$script" "${args:+$args }" > "$file"
    chmod +x "$file"
}

install_wrappers() {
    local entry name rest script args
    for entry in "${SPOTX_WRAPPERS[@]}"; do
        name="${entry%%|*}"; rest="${entry#*|}"
        script="${rest%%|*}"; args="${rest#*|}"
        write_launcher "${TERMUX_BIN}/${name}" "$script" "$args"
    done
}

install_widget_shortcuts() {
    local entry name rest script args
    local icons_dir="${SHORTCUTS_DIR}/icons"
    for entry in "${SPOTX_SHORTCUTS[@]}"; do
        name="${entry%%|*}"; rest="${entry#*|}"
        script="${rest%%|*}"; args="${rest#*|}"
        write_launcher "${SHORTCUTS_DIR}/${name}" "$script" "$args"
    done

    mkdir -p "$icons_dir" 2>/dev/null || true
    fetch_repo_file "src/spotify-icon.png" "${icons_dir}/Spotify.png" is_nonempty_file || true
    if [ -f "${icons_dir}/Spotify.png" ]; then
        cp -f "${icons_dir}/Spotify.png" "${icons_dir}/Spotify-Stop.png" 2>/dev/null || true
    fi
}

# Termux must allow external apps for Termux-X11 / Termux:Widget interaction
ensure_allow_external_apps() {
    local props="${HOME}/.termux/termux.properties"
    mkdir -p "${HOME}/.termux"
    if grep -q "^[[:space:]]*allow-external-apps" "$props" 2>/dev/null; then
        sed -i 's/^[[:space:]]*allow-external-apps[[:space:]]*=.*/allow-external-apps = true/' "$props"
    else
        echo "allow-external-apps = true" >> "$props"
    fi
    termux-reload-settings >/dev/null 2>&1 || true
}

# PulseAudio daemon settings tuned for Android latency and CPU usage
write_pulse_config() {
    mkdir -p "${HOME}/.config/pulse"
    cat << 'PULSE_CONF' > "${HOME}/.config/pulse/daemon.conf"
exit-idle-time = -1
default-fragments = 12
default-fragment-size-msec = 40
resample-method = speex-float-1
default-sample-rate = 48000
alternate-sample-rate = 44100
default-sample-channels = 2
high-priority = yes
realtime-scheduling = no
PULSE_CONF
}
