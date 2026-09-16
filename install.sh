#!/usr/bin/env bash
# ==============================================================================
# SpotX-Termux: Automated installer for Spotify + SpotX on Android via Termux
# Repository: https://github.com/CupoMeridio/spotx-termux
# ==============================================================================
set -euo pipefail

# ANSI color styles
CLR='\033[0m'
BOLD='\033[1m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
RED='\033[0;31m'

# Logging configuration (~/.spotx-termux/logs/install.log with .old rotation)
LOG_DIR="${HOME}/.spotx-termux/logs"
LOG_FILE="${LOG_DIR}/install.log"

setup_logging() {
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    if [ -f "$LOG_FILE" ]; then
        mv -f "$LOG_FILE" "${LOG_FILE}.old" 2>/dev/null || true
    fi
    {
        echo "============================================================"
        echo "SpotX-Termux Installer Log: $(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || true)"
        echo "Version: ${SPOTX_TERMUX_VERSION:-unknown}"
        echo "Architecture: $(uname -m 2>/dev/null || echo 'unknown')"
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

notify_user() {
    local title="$1"
    local content="$2"
    if command -v termux-notification >/dev/null 2>&1; then
        termux-notification \
            --title "$title" \
            --content "$content" \
            --id "spotx-status" \
            --priority "high" 2>/dev/null || true
    fi
}

# Resolve script directory early
SCRIPT_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
fi

# Resolve SpotX-Termux project version (CalVer: YYYY.MM.DD)
# Priority: local repo VERSION file → GitHub remote → installed marker → "unknown"
SPOTX_TERMUX_VERSION=""
if [ -n "$SCRIPT_DIR" ] && [ -f "${SCRIPT_DIR}/VERSION" ]; then
    SPOTX_TERMUX_VERSION=$(cat "${SCRIPT_DIR}/VERSION" 2>/dev/null | tr -d '[:space:]')
fi
if [ -z "$SPOTX_TERMUX_VERSION" ]; then
    SPOTX_TERMUX_VERSION=$(curl -sSL --connect-timeout 3 --max-time 5 "https://raw.githubusercontent.com/CupoMeridio/spotx-termux/main/VERSION?t=$(date +%s)" 2>/dev/null | tr -d '[:space:]' || true)
fi
if [ -z "$SPOTX_TERMUX_VERSION" ] && [ -f "${HOME}/.spotx-termux-version" ]; then
    SPOTX_TERMUX_VERSION=$(cat "${HOME}/.spotx-termux-version" 2>/dev/null | tr -d '[:space:]')
fi
: "${SPOTX_TERMUX_VERSION:=unknown}"

# Delegate to uninstaller if requested
if [ "${1:-}" = "--uninstall" ] || [ "${1:-}" = "-u" ]; then
    shift
    if [ -n "$SCRIPT_DIR" ] && [ -f "${SCRIPT_DIR}/uninstall.sh" ]; then
        exec bash "${SCRIPT_DIR}/uninstall.sh" "$@"
    else
        exec bash <(curl -sSL "https://raw.githubusercontent.com/CupoMeridio/spotx-termux/main/uninstall.sh?t=$(date +%s)") "$@"
    fi
fi

# Delegate to doctor if requested
if [ "${1:-}" = "--doctor" ] || [ "${1:-}" = "-d" ] || [ "${1:-}" = "doctor" ]; then
    shift
    if [ -n "$SCRIPT_DIR" ] && [ -f "${SCRIPT_DIR}/src/doctor.sh" ]; then
        exec bash "${SCRIPT_DIR}/src/doctor.sh" "$@"
    elif [ -f "${HOME}/doctor-spotify.sh" ]; then
        exec "$HOME/doctor-spotify.sh" "$@"
    else
        exec bash -c "$(curl -fsSL https://raw.githubusercontent.com/CupoMeridio/spotx-termux/main/src/doctor.sh)" bash "$@"
    fi
fi

if [ "${1:-}" = "--version" ] || [ "${1:-}" = "-V" ]; then
    echo "SpotX-Termux ${SPOTX_TERMUX_VERSION}"
    exit 0
fi

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    echo "SpotX-Termux Installer (v${SPOTX_TERMUX_VERSION})"
    echo
    echo "Usage:"
    echo "  bash install.sh [OPTIONS]"
    echo
    echo "Options:"
    echo "  --doctor, -d             Run system health check & diagnostics"
    echo "  --force, -f              Force re-download and re-installation of Spotify and SpotX"
    echo "  --uninstall, -u [ARGS]   Launch the uninstaller & cleanup utility"
    echo "  --version, -V            Show version information"
    echo "  --help, -h               Show this help message"
    exit 0
fi

SPOTX_FORCE=0
for arg in "$@"; do
    case "$arg" in
        --force|-f)
            SPOTX_FORCE=1
            ;;
    esac
done

# Initialize logging for the installation run
setup_logging

echo -e "${GREEN}${BOLD}"
echo "  ____             _  __  __   _____                                "
echo " / ___| _ __   ___| |_\ \/ /  |_   _|__ _ __ _ __ ___  _   ___  __ "
echo " \___ \| '_ \ / _ \ __/\  /_____| |/ _ \ '__| '_ \` _ \| | | \ \/ / "
echo "  ___) | |_) | (_) | |_/  \_____| |  __/ |  | | | | | | |_| |>  <  "
echo " |____/| .__/ \___/ \__/_/\_\   |_|\___|_|  |_| |_| |_|\__,_/_/\_\ "
echo "       |_|                                                         "
echo -e "${CLR}"
echo -e "${CYAN}Automatic setup of Spotify Desktop + SpotX inside Termux PRoot${CLR}"
echo -e "${CYAN}Version: ${BOLD}${SPOTX_TERMUX_VERSION}${CLR}"
echo -e "${CYAN}---------------------------------------------------------------${CLR}\n"

# 1. Environment check
IS_TERMUX=false
if [ -n "${TERMUX_VERSION:-}" ] || [ -d "/data/data/com.termux" ] || [[ "${PREFIX:-}" == *"com.termux"* ]]; then
    IS_TERMUX=true
fi

ARCH="$(uname -m)"
info "Detected architecture: ${ARCH}"

if [ "$IS_TERMUX" = false ]; then
    warn "This installer is designed for Termux on Android."
    warn "You are currently running on a standard Linux host (${ARCH})."
    read -rp "Do you want to proceed with a dry-run / container test? [y/N]: " RESP
    case "$RESP" in
        [yY]|[yY][eE][sS])
            info "Proceeding..."
            ;;
        *)
            info "Aborting installer."
            exit 0
            ;;
    esac
fi

# Container definitions and storage validation
CONTAINER_NAME="ubuntu"

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

check_disk_space() {
    info "Checking available storage space..."
    local target_dir="${HOME}"
    [ -d "$target_dir" ] || target_dir="/"

    if ! command -v df >/dev/null 2>&1; then
        warn "Storage check: 'df' command not found, skipping check."
        return 0
    fi

    local free_kb=""
    free_kb=$(df -P -k "$target_dir" 2>/dev/null | awk 'NR==2 {print $4}' || true)
    if [ -z "$free_kb" ] || ! [ "$free_kb" -gt 0 ] 2>/dev/null; then
        free_kb=$(df -k "$target_dir" 2>/dev/null | awk 'NR==2 {print $4}' || true)
    fi

    if [ -n "$free_kb" ] && [ "$free_kb" -gt 0 ] 2>/dev/null; then
        local free_mb=$((free_kb / 1024))
        local free_gb=$((free_mb / 1024))

        if is_container_installed "$CONTAINER_NAME"; then
            info "Container '${CONTAINER_NAME}' already exists. Reusing allocated storage."
            if [ "$free_mb" -lt 300 ]; then
                error "Critically low storage space: only ${free_mb} MB available."
                error "Please free up storage space before running the installer."
                exit 1
            else
                success "Storage check passed: ${free_mb} MB free."
            fi
            return 0
        fi

        if [ "$free_mb" -ge 2048 ]; then
            success "Storage check passed: ${free_gb} GB free (${free_mb} MB available)."
        elif [ "$free_mb" -ge 1024 ]; then
            warn "Low storage space: only ${free_mb} MB free."
            warn "SpotX-Termux installation requires ~1.2 GB of temporary extraction space."
            warn "Audio and Spotify cache will require additional storage."
            local resp=""
            if [ -t 0 ]; then
                read -rp "Do you want to proceed anyway? [y/N]: " resp
            elif [ -e /dev/tty ]; then
                read -rp "Do you want to proceed anyway? [y/N]: " resp < /dev/tty
            else
                resp="y"
            fi
            case "$resp" in
                [yY]|[yY][eE][sS])
                    info "Proceeding with installation despite low storage warning..."
                    ;;
                *)
                    info "Installation aborted by user to free up storage space."
                    exit 0
                    ;;
            esac
        else
            error "Insufficient storage space: only ${free_mb} MB free!"
            error "SpotX-Termux requires at least 1024 MB (1 GB) to unpack Ubuntu, Box64, and Spotify."
            error "Please free up storage space on your device and run the installer again."
            exit 1
        fi
    else
        warn "Storage check: unable to calculate available space. Continuing..."
    fi
}

check_disk_space


# 2. Update Termux repositories and install host dependencies
if [ "$IS_TERMUX" = true ]; then
    info "Enabling Termux X11 repository..."
    pkg install -y x11-repo || {
        warn "Could not install x11-repo directly, trying update first..."
    }

    info "Updating Termux package lists..."
    pkg update -y || {
        warn "pkg update returned a warning. Continuing..."
    }

    info "Installing required Termux packages (proot-distro, pulseaudio, termux-api, etc.)..."
    pkg install -y proot-distro pulseaudio wget curl jq termux-api

    info "Installing Termux-X11 companion package..."
    pkg install -y termux-x11-nightly || {
        warn "Could not install termux-x11-nightly from repository."
        warn "Please ensure x11-repo is enabled or install termux-x11 companion manually."
    }

    # Ensure Termux allows external apps (required for Termux-X11 interaction)
    mkdir -p "${HOME}/.termux"
    if grep -q "^[[:space:]]*allow-external-apps" "${HOME}/.termux/termux.properties" 2>/dev/null; then
        sed -i 's/^[[:space:]]*allow-external-apps[[:space:]]*=.*/allow-external-apps = true/' "${HOME}/.termux/termux.properties"
    else
        echo "allow-external-apps = true" >> "${HOME}/.termux/termux.properties"
    fi
    termux-reload-settings >/dev/null 2>&1 || true

    # Pre-configure PulseAudio daemon settings for optimal Android latency and CPU performance
    mkdir -p "${HOME}/.config/pulse"
    cat << 'PULSE_CONF' > "${HOME}/.config/pulse/daemon.conf"
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
fi

# 3. Setup Ubuntu container via proot-distro
info "Checking PRoot container '${CONTAINER_NAME}'..."
if is_container_installed "$CONTAINER_NAME"; then
    success "Container '${CONTAINER_NAME}' already installed."
else
    info "Installing Ubuntu container via proot-distro (Ubuntu 24.04 LTS)..."
    INSTALL_OUTPUT=""
    if ! INSTALL_OUTPUT=$(proot-distro install "$CONTAINER_NAME" 2>&1); then
        echo "$INSTALL_OUTPUT"
        if [[ "$INSTALL_OUTPUT" == *"already exists"* ]] || is_container_installed "$CONTAINER_NAME"; then
            warn "Container '${CONTAINER_NAME}' already exists. Continuing..."
        else
            error "Failed to install PRoot container '${CONTAINER_NAME}'."
            exit 1
        fi
    else
        echo "$INSTALL_OUTPUT"
        success "Container '${CONTAINER_NAME}' created."
    fi
fi

# 4. Resolve and run guest-setup.sh inside container via shared tmp
info "Configuring container environment, dependencies, Box64, Spotify, and SpotX..."

GUEST_SETUP_LOCAL=""
if [ -n "$SCRIPT_DIR" ] && [ -f "${SCRIPT_DIR}/src/guest-setup.sh" ]; then
    GUEST_SETUP_LOCAL="${SCRIPT_DIR}/src/guest-setup.sh"
fi

REMOTE_REPO_RAW="https://raw.githubusercontent.com/CupoMeridio/spotx-termux/main/src/guest-setup.sh"

TMP_DIR="${PREFIX:-/usr}/tmp"
mkdir -p "$TMP_DIR"
CONTAINER_SETUP_STAGING="${TMP_DIR}/spotx-guest-setup.sh"

if [ -n "$GUEST_SETUP_LOCAL" ] && [ -f "$GUEST_SETUP_LOCAL" ]; then
    info "Staging local guest setup script: ${GUEST_SETUP_LOCAL}"
    cp "$GUEST_SETUP_LOCAL" "$CONTAINER_SETUP_STAGING"
else
    info "Fetching guest setup script from repository: ${REMOTE_REPO_RAW}"
    curl -sSL "${REMOTE_REPO_RAW}?t=$(date +%s)" -o "$CONTAINER_SETUP_STAGING"
fi
chmod +x "$CONTAINER_SETUP_STAGING"

info "Executing container guest configuration..."
proot-distro login "$CONTAINER_NAME" --shared-tmp -- \
    env SPOTX_FORCE="$SPOTX_FORCE" \
        SPOTX_TERMUX_VERSION="$SPOTX_TERMUX_VERSION" \
        bash /tmp/spotx-guest-setup.sh
rm -f "$CONTAINER_SETUP_STAGING"

# 5. Install launcher scripts on Termux host
info "Installing launcher scripts on Termux..."

BIN_DIR="${PREFIX:-/data/data/com.termux/files/usr}/bin"
mkdir -p "$BIN_DIR"

START_SCRIPT_LOCAL=""
if [ -n "$SCRIPT_DIR" ] && [ -f "${SCRIPT_DIR}/src/start-spotify.sh" ]; then
    START_SCRIPT_LOCAL="${SCRIPT_DIR}/src/start-spotify.sh"
fi
START_SCRIPT_DEST="${HOME}/start-spotify.sh"
COMMAND_BIN="${BIN_DIR}/spotify"

if [ -n "$START_SCRIPT_LOCAL" ] && [ -f "$START_SCRIPT_LOCAL" ]; then
    cp "$START_SCRIPT_LOCAL" "$START_SCRIPT_DEST"
else
    curl -sSL "https://raw.githubusercontent.com/CupoMeridio/spotx-termux/main/src/start-spotify.sh?t=$(date +%s)" -o "$START_SCRIPT_DEST"
fi
chmod +x "$START_SCRIPT_DEST"

# Create wrapper in $PREFIX/bin so user can just type 'spotify' anywhere
cat << 'RUN_CMD' > "$COMMAND_BIN"
#!/usr/bin/env bash
exec "$HOME/start-spotify.sh" "$@"
RUN_CMD
chmod +x "$COMMAND_BIN"

# Create stop wrapper in $PREFIX/bin so user can just type 'spotify-stop'
STOP_BIN="${BIN_DIR}/spotify-stop"
cat << 'STOP_CMD' > "$STOP_BIN"
#!/usr/bin/env bash
exec "$HOME/start-spotify.sh" --stop "$@"
STOP_CMD
chmod +x "$STOP_BIN"

# Install updater script and wrapper
UPDATE_SCRIPT_LOCAL=""
if [ -n "$SCRIPT_DIR" ] && [ -f "${SCRIPT_DIR}/src/update-spotify.sh" ]; then
    UPDATE_SCRIPT_LOCAL="${SCRIPT_DIR}/src/update-spotify.sh"
fi
UPDATE_SCRIPT_DEST="${HOME}/update-spotify.sh"
UPDATE_BIN="${BIN_DIR}/spotify-update"

if [ -n "$UPDATE_SCRIPT_LOCAL" ] && [ -f "$UPDATE_SCRIPT_LOCAL" ]; then
    cp "$UPDATE_SCRIPT_LOCAL" "$UPDATE_SCRIPT_DEST"
else
    curl -sSL "https://raw.githubusercontent.com/CupoMeridio/spotx-termux/main/src/update-spotify.sh?t=$(date +%s)" -o "$UPDATE_SCRIPT_DEST"
fi
chmod +x "$UPDATE_SCRIPT_DEST"

cat << 'UPDATE_CMD' > "$UPDATE_BIN"
#!/usr/bin/env bash
exec "$HOME/update-spotify.sh" "$@"
UPDATE_CMD
chmod +x "$UPDATE_BIN"

# Install uninstaller script and wrapper
UNINSTALL_SCRIPT_LOCAL=""
if [ -n "$SCRIPT_DIR" ] && [ -f "${SCRIPT_DIR}/uninstall.sh" ]; then
    UNINSTALL_SCRIPT_LOCAL="${SCRIPT_DIR}/uninstall.sh"
fi
UNINSTALL_SCRIPT_DEST="${HOME}/uninstall-spotify.sh"
UNINSTALL_BIN="${BIN_DIR}/spotify-uninstall"

if [ -n "$UNINSTALL_SCRIPT_LOCAL" ] && [ -f "$UNINSTALL_SCRIPT_LOCAL" ]; then
    cp "$UNINSTALL_SCRIPT_LOCAL" "$UNINSTALL_SCRIPT_DEST"
else
    curl -sSL "https://raw.githubusercontent.com/CupoMeridio/spotx-termux/main/uninstall.sh?t=$(date +%s)" -o "$UNINSTALL_SCRIPT_DEST"
fi
chmod +x "$UNINSTALL_SCRIPT_DEST"

cat << 'UNINSTALL_CMD' > "$UNINSTALL_BIN"
#!/usr/bin/env bash
exec "$HOME/uninstall-spotify.sh" "$@"
UNINSTALL_CMD
chmod +x "$UNINSTALL_BIN"

# Install doctor script and wrapper
DOCTOR_SCRIPT_LOCAL=""
if [ -n "$SCRIPT_DIR" ] && [ -f "${SCRIPT_DIR}/src/doctor.sh" ]; then
    DOCTOR_SCRIPT_LOCAL="${SCRIPT_DIR}/src/doctor.sh"
fi
DOCTOR_SCRIPT_DEST="${HOME}/doctor-spotify.sh"
DOCTOR_BIN="${BIN_DIR}/spotify-doctor"

if [ -n "$DOCTOR_SCRIPT_LOCAL" ] && [ -f "$DOCTOR_SCRIPT_LOCAL" ]; then
    cp "$DOCTOR_SCRIPT_LOCAL" "$DOCTOR_SCRIPT_DEST"
else
    curl -sSL "https://raw.githubusercontent.com/CupoMeridio/spotx-termux/main/src/doctor.sh?t=$(date +%s)" -o "$DOCTOR_SCRIPT_DEST"
fi
chmod +x "$DOCTOR_SCRIPT_DEST"

cat << 'DOCTOR_CMD' > "$DOCTOR_BIN"
#!/usr/bin/env bash
exec "$HOME/doctor-spotify.sh" "$@"
DOCTOR_CMD
chmod +x "$DOCTOR_BIN"

# Termux:Widget shortcut support (pre-creates ~/.shortcuts directory)
SHORTCUTS_DIR="${HOME}/.shortcuts"
ICONS_DIR="${SHORTCUTS_DIR}/icons"
mkdir -p "$SHORTCUTS_DIR" "$ICONS_DIR"

# Create Spotify shortcut
cp "$START_SCRIPT_DEST" "${SHORTCUTS_DIR}/Spotify"
chmod +x "${SHORTCUTS_DIR}/Spotify"

# Create Spotify-Stop shortcut
cat << 'WIDGET_STOP' > "${SHORTCUTS_DIR}/Spotify-Stop"
#!/data/data/com.termux/files/usr/bin/bash
exec "$HOME/start-spotify.sh" --stop
WIDGET_STOP
chmod +x "${SHORTCUTS_DIR}/Spotify-Stop"

# Download Spotify icon for Termux:Widget from the project repository
info "Downloading icon for Termux:Widget..."
curl -sSL "https://raw.githubusercontent.com/CupoMeridio/spotx-termux/main/src/spotify-icon.png?t=$(date +%s)" -o "${ICONS_DIR}/Spotify.png" 2>/dev/null || true
cp "${ICONS_DIR}/Spotify.png" "${ICONS_DIR}/Spotify-Stop.png" 2>/dev/null || true
success "Termux:Widget shortcuts created: 'Spotify' and 'Spotify-Stop'"

# Save SpotX-Termux version marker for runtime version detection
echo "$SPOTX_TERMUX_VERSION" > "${HOME}/.spotx-termux-version"

# Send system notification on completion if termux-api is available
notify_user "SpotX-Termux" "Installation completed successfully! Launch Spotify with 'spotify'."

# 6. Summary and Instructions
echo
echo -e "${GREEN}${BOLD}======================================================${CLR}"
echo -e "${GREEN}${BOLD}      Installation Completed Successfully!           ${CLR}"
echo -e "${GREEN}${BOLD}======================================================${CLR}"
echo
echo -e "${CYAN}How to manage Spotify SpotX:${CLR}"
echo -e "  1. Make sure you have installed the ${BOLD}Termux-X11 APK${CLR} on your Android device."
echo -e "     (Download: https://github.com/termux/termux-x11/releases)"
echo -e "  2. In Termux, simply type:"
echo -e "     ${BOLD}${GREEN}spotify${CLR}           - Launch Spotify SpotX"
echo -e "     ${BOLD}${GREEN}spotify-stop${CLR}      - Stop Spotify and all background processes"
echo -e "     ${BOLD}${GREEN}spotify-update${CLR}    - Update Spotify or re-apply SpotX patch"
echo -e "     ${BOLD}${GREEN}spotify-doctor${CLR}    - Run health check and diagnostic tool"
echo -e "     ${BOLD}${GREEN}spotify-uninstall${CLR} - Uninstall or clean up"
echo -e "  3. Or tap ${BOLD}Spotify${CLR} / ${BOLD}Spotify-Stop${CLR} on your home screen via Termux:Widget."
echo
echo -e "${YELLOW}Tips for the best experience:${CLR}"
echo -e "  * Disable Android battery optimization for Termux so audio playback is not paused."
echo -e "  * In Termux-X11 preferences, enable fullscreen and Touchpad mouse mode."
echo -e "  * Installation log available at: ${BOLD}${CYAN}${LOG_FILE}${CLR}"
echo
