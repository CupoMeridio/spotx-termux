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
CONTAINER_ROOTFS="${PREFIX:-/usr}/var/lib/proot-distro/installed-rootfs/${CONTAINER_NAME}"

# Verify proot-distro is installed
if ! command -v proot-distro > /dev/null 2>&1; then
    error "proot-distro command not found."
    error "Please ensure Termux dependencies are installed or run install.sh."
    exit 1
fi

# Verify container exists
if [ ! -d "$CONTAINER_ROOTFS" ]; then
    error "PRoot container '${CONTAINER_NAME}' is not installed at ${CONTAINER_ROOTFS}."
    error "Please run the full installer first: bash install.sh"
    exit 1
fi

# Stage guest-setup.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUEST_SETUP_LOCAL="${SCRIPT_DIR}/guest-setup.sh"
REMOTE_REPO_RAW="https://raw.githubusercontent.com/CupoMeridio/spotx-termux/main/src/guest-setup.sh"

TMP_DIR="${PREFIX:-/usr}/tmp"
mkdir -p "$TMP_DIR"
CONTAINER_SETUP_STAGING="${TMP_DIR}/spotx-guest-setup.sh"

# Ensure cleanup on exit
trap 'rm -f "$CONTAINER_SETUP_STAGING"' EXIT

if [ -f "$GUEST_SETUP_LOCAL" ]; then
    info "Using local guest setup script: ${GUEST_SETUP_LOCAL}"
    cp "$GUEST_SETUP_LOCAL" "$CONTAINER_SETUP_STAGING"
else
    info "Fetching latest guest setup script from repository..."
    curl -sSL "$REMOTE_REPO_RAW" -o "$CONTAINER_SETUP_STAGING"
fi
chmod +x "$CONTAINER_SETUP_STAGING"

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
