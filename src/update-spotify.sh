#!/usr/bin/env bash
# ==============================================================================
# update-spotify.sh - Termux host script to update Spotify and SpotX
# Repository: https://github.com/CupoMeridio/spotx-termux
# ==============================================================================
set -euo pipefail

# ANSI color codes
CLR='\033[0m'
BOLD='\033[1m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
RED='\033[0;31m'

info()    { echo -e "${CYAN}${BOLD}[*]${CLR} $*"; }
success() { echo -e "${GREEN}${BOLD}[✔]${CLR} $*"; }
warn()    { echo -e "${YELLOW}${BOLD}[!]${CLR} $*"; }
error()   { echo -e "${RED}${BOLD}[✘]${CLR} $*" >&2; }

show_help() {
    cat << EOF
SpotX-Termux Updater

Usage:
  spotify-update [OPTIONS]

Options:
  --check, -c       Check for updates without installing (prints installed & latest version)
  --spotx-only, -s  Re-apply SpotX patch only (skips Spotify client update/download)
  --skip-spotx      Update Spotify client only (skips SpotX patching)
  --help, -h        Show this help message

Examples:
  spotify-update              Check and update Spotify + apply SpotX patch
  spotify-update --check      Check if an update is available
  spotify-update --spotx-only Re-patch xpui.spa without re-downloading Spotify
EOF
}

SPOTX_CHECK_ONLY=0
SPOTX_ONLY=0
SPOTX_SKIP=0

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --check|-c)
            SPOTX_CHECK_ONLY=1
            shift
            ;;
        --spotx-only|-s)
            SPOTX_ONLY=1
            shift
            ;;
        --skip-spotx)
            SPOTX_SKIP=1
            shift
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        *)
            error "Unknown argument: $1"
            show_help
            exit 1
            ;;
    esac
done

echo -e "${CYAN}======================================================${CLR}"
echo -e "${CYAN}${BOLD}   SpotX Termux - Updater Orchestrator               ${CLR}"
echo -e "${CYAN}======================================================${CLR}"

CONTAINER_NAME="ubuntu"

# Verify proot-distro is installed
if ! command -v proot-distro > /dev/null 2>&1; then
    error "proot-distro command not found."
    error "Please ensure Termux dependencies are installed or run install.sh."
    exit 1
fi

is_container_installed() {
    local name="$1"
    local prefix="${PREFIX:-/data/data/com.termux/files/usr}"
    if [ -d "${prefix}/var/lib/proot-distro/containers/${name}" ] || \
       [ -d "${prefix}/var/lib/proot-distro/installed-rootfs/${name}" ] || \
       [ -d "/usr/var/lib/proot-distro/containers/${name}" ] || \
       [ -d "/usr/var/lib/proot-distro/installed-rootfs/${name}" ]; then
        return 0
    fi
    if proot-distro login "$name" -- true >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

# Verify container exists
if ! is_container_installed "$CONTAINER_NAME"; then
    error "PRoot container '${CONTAINER_NAME}' is not installed."
    error "Please run the full installer first: bash install.sh"
    exit 1
fi

# Stage guest-setup.sh
SCRIPT_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
fi

GUEST_SETUP_LOCAL=""
if [ -n "$SCRIPT_DIR" ] && [ -f "${SCRIPT_DIR}/guest-setup.sh" ]; then
    GUEST_SETUP_LOCAL="${SCRIPT_DIR}/guest-setup.sh"
elif [ -n "$SCRIPT_DIR" ] && [ -f "${SCRIPT_DIR}/src/guest-setup.sh" ]; then
    GUEST_SETUP_LOCAL="${SCRIPT_DIR}/src/guest-setup.sh"
fi

REMOTE_REPO_RAW="https://raw.githubusercontent.com/CupoMeridio/spotx-termux/main/src/guest-setup.sh"

TMP_DIR="${PREFIX:-/usr}/tmp"
mkdir -p "$TMP_DIR"
CONTAINER_SETUP_STAGING="${TMP_DIR}/spotx-guest-setup.sh"

# Ensure cleanup on exit
trap 'rm -f "$CONTAINER_SETUP_STAGING"' EXIT

if [ -n "$GUEST_SETUP_LOCAL" ] && [ -f "$GUEST_SETUP_LOCAL" ]; then
    info "Using local guest setup script: ${GUEST_SETUP_LOCAL}"
    cp "$GUEST_SETUP_LOCAL" "$CONTAINER_SETUP_STAGING"
else
    info "Fetching latest guest setup script from repository..."
    curl -sSL "${REMOTE_REPO_RAW}?t=$(date +%s)" -o "$CONTAINER_SETUP_STAGING"
fi
chmod +x "$CONTAINER_SETUP_STAGING"

if [ "$SPOTX_CHECK_ONLY" = "0" ]; then
    # Ensure Termux allows external apps
    mkdir -p "${HOME}/.termux"
    if grep -q "^[[:space:]]*allow-external-apps" "${HOME}/.termux/termux.properties" 2>/dev/null; then
        sed -i 's/^[[:space:]]*allow-external-apps[[:space:]]*=.*/allow-external-apps = true/' "${HOME}/.termux/termux.properties"
    else
        echo "allow-external-apps = true" >> "${HOME}/.termux/termux.properties"
    fi
    termux-reload-settings >/dev/null 2>&1 || true

    # Helper function to refresh a host script from local repo or remote GitHub
    sync_host_script() {
        local local_rel="$1"
        local remote_rel="$2"
        local dest_file="$3"
        local local_file=""

        # Prevent falsely identifying the installed $HOME directory as a local git repository.
        if [ "$SCRIPT_DIR" != "$HOME" ]; then
            if [ -n "$SCRIPT_DIR" ] && [ -f "${SCRIPT_DIR}/${local_rel}" ]; then
                local_file="${SCRIPT_DIR}/${local_rel}"
            elif [ -n "$SCRIPT_DIR" ] && [ -f "${SCRIPT_DIR}/src/${local_rel}" ]; then
                local_file="${SCRIPT_DIR}/src/${local_rel}"
            fi
        fi

        if [ -n "$local_file" ] && [ -f "$local_file" ]; then
            cp "$local_file" "$dest_file"
        else
            curl -sSL "https://raw.githubusercontent.com/CupoMeridio/spotx-termux/main/${remote_rel}?t=$(date +%s)" -o "$dest_file" 2>/dev/null || true
        fi
        chmod +x "$dest_file" 2>/dev/null || true
    }

    info "Synchronizing host scripts and configuration..."
    sync_host_script "start-spotify.sh" "src/start-spotify.sh" "${HOME}/start-spotify.sh"
    sync_host_script "update-spotify.sh" "src/update-spotify.sh" "${HOME}/update-spotify.sh"
    sync_host_script "uninstall.sh" "uninstall.sh" "${HOME}/uninstall-spotify.sh"

    # Ensure spotify-stop wrapper exists in $BIN_DIR
    HOST_BIN_DIR="${PREFIX:-/data/data/com.termux/files/usr}/bin"
    mkdir -p "$HOST_BIN_DIR"
    cat << 'STOP_CMD' > "${HOST_BIN_DIR}/spotify-stop"
#!/usr/bin/env bash
exec "$HOME/start-spotify.sh" --stop "$@"
STOP_CMD
    chmod +x "${HOST_BIN_DIR}/spotify-stop"

    # Ensure Termux:Widget shortcuts are kept up to date
    SHORTCUTS_DIR="${HOME}/.shortcuts"
    if [ -d "$SHORTCUTS_DIR" ]; then
        cp "${HOME}/start-spotify.sh" "${SHORTCUTS_DIR}/Spotify" 2>/dev/null || true
        chmod +x "${SHORTCUTS_DIR}/Spotify" 2>/dev/null || true
        cat << 'WIDGET_STOP' > "${SHORTCUTS_DIR}/Spotify-Stop"
#!/data/data/com.termux/files/usr/bin/bash
exec "$HOME/start-spotify.sh" --stop
WIDGET_STOP
        chmod +x "${SHORTCUTS_DIR}/Spotify-Stop" 2>/dev/null || true
    fi

    # Terminate running Spotify processes to avoid file conflicts during update
    pkill -x spotify 2>/dev/null || true
fi

# Run inside PRoot container with appropriate flags
info "Running update inside container '${CONTAINER_NAME}'..."
proot-distro login "$CONTAINER_NAME" --shared-tmp -- \
    env SPOTX_CHECK_ONLY="$SPOTX_CHECK_ONLY" \
        SPOTX_ONLY="$SPOTX_ONLY" \
        SPOTX_SKIP="$SPOTX_SKIP" \
        bash /tmp/spotx-guest-setup.sh

if [ "$SPOTX_CHECK_ONLY" = "0" ]; then
    success "Update process finished!"
fi
