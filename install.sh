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

info()    { echo -e "${CYAN}${BOLD}[*]${CLR} $*"; }
success() { echo -e "${GREEN}${BOLD}[✔]${CLR} $*"; }
warn()    { echo -e "${YELLOW}${BOLD}[!]${CLR} $*"; }
error()   { echo -e "${RED}${BOLD}[✘]${CLR} $*" >&2; }

echo -e "${GREEN}${BOLD}"
echo "  ____             _  __  __   _____                                "
echo " / ___| _ __   ___| |_\ \/ /  |_   _|__ _ __ _ __ ___  _   ___  __ "
echo " \___ \| '_ \ / _ \ __/\  /_____| |/ _ \ '__| '_ \` _ \| | | \ \/ / "
echo "  ___) | |_) | (_) | |_/  \_____| |  __/ |  | | | | | | |_| |>  <  "
echo " |____/| .__/ \___/ \__/_/\_\   |_|\___|_|  |_| |_| |_|\__,_/_/\_\ "
echo "       |_|                                                         "
echo -e "${CLR}"
echo -e "${CYAN}Automatic setup of Spotify Desktop + SpotX inside Termux PRoot${CLR}"
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

    info "Installing required Termux packages (proot-distro, pulseaudio, etc.)..."
    pkg install -y proot-distro pulseaudio wget curl jq

    info "Installing Termux-X11 companion package..."
    pkg install -y termux-x11-nightly || {
        warn "Could not install termux-x11-nightly from repository."
        warn "Please ensure x11-repo is enabled or install termux-x11 companion manually."
    }
fi

# 3. Setup Ubuntu container via proot-distro
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

SCRIPT_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
fi

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
proot-distro login "$CONTAINER_NAME" --shared-tmp -- bash /tmp/spotx-guest-setup.sh
rm -f "$CONTAINER_SETUP_STAGING"

# 5. Install launcher scripts on Termux host
info "Installing launcher scripts on Termux..."

BIN_DIR="${PREFIX:-/usr}/bin"
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

# Termux:Widget shortcut support (pre-creates ~/.shortcuts directory)
SHORTCUTS_DIR="${HOME}/.shortcuts"
mkdir -p "$SHORTCUTS_DIR"
cp "$START_SCRIPT_DEST" "${SHORTCUTS_DIR}/Spotify"
chmod +x "${SHORTCUTS_DIR}/Spotify"
success "Termux:Widget shortcut created at ${SHORTCUTS_DIR}/Spotify"

# 6. Summary and Instructions
echo
echo -e "${GREEN}${BOLD}======================================================${CLR}"
echo -e "${GREEN}${BOLD}      Installation Completed Successfully!           ${CLR}"
echo -e "${GREEN}${BOLD}======================================================${CLR}"
echo
echo -e "${CYAN}How to run Spotify SpotX:${CLR}"
echo -e "  1. Make sure you have installed the ${BOLD}Termux-X11 APK${CLR} on your Android device."
echo -e "     (Download: https://github.com/termux/termux-x11/releases)"
echo -e "  2. In Termux, simply type:"
echo -e "     ${BOLD}${GREEN}spotify${CLR}         - Avvia Spotify SpotX"
echo -e "     ${BOLD}${GREEN}spotify-update${CLR}  - Aggiorna Spotify o ri-applica la patch SpotX"
echo -e "  3. Or tap the ${BOLD}Spotify${CLR} widget on your home screen via Termux:Widget."
echo
echo -e "${YELLOW}Tips for the best experience:${CLR}"
echo -e "  * Disable Android battery optimization for Termux so audio playback is not paused."
echo -e "  * In Termux-X11 preferences, enable fullscreen and Touchpad mouse mode."
echo
