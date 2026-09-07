#!/usr/bin/env bash
# ==============================================================================
# guest-setup.sh - Configuration script inside PRoot Ubuntu container
# ==============================================================================
set -euo pipefail

# ANSI color codes for friendly terminal output
CLR='\033[0m'
BOLD='\033[1m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
RED='\033[0;31m'

info()    { echo -e "${CYAN}${BOLD}[INFO]${CLR} $*"; }
success() { echo -e "${GREEN}${BOLD}[SUCCESS]${CLR} $*"; }
warn()    { echo -e "${YELLOW}${BOLD}[WARNING]${CLR} $*"; }
error()   { echo -e "${RED}${BOLD}[ERROR]${CLR} $*" >&2; }

echo -e "${CYAN}======================================================${CLR}"
echo -e "${CYAN}${BOLD}   SpotX Termux - Container Guest Setup (PRoot)       ${CLR}"
echo -e "${CYAN}======================================================${CLR}"

export DEBIAN_FRONTEND=noninteractive

ARCH="$(uname -m)"
info "Detected architecture inside container: ${ARCH}"

# 1. Update APT lists and install fundamental utilities
info "Updating container package sources..."
apt-get update -y

info "Installing base utilities and build/unpack tools..."
apt-get install -y --no-install-recommends \
    curl \
    wget \
    gpg \
    tar \
    xz-utils \
    binutils \
    perl \
    zip \
    unzip \
    procps \
    ca-certificates

# 2. Install shared GUI, audio, and Electron runtime dependencies
info "Installing GUI, audio, and Electron compatibility libraries..."
apt-get install -y --no-install-recommends \
    libgl1-mesa-dri \
    libgl1 \
    libnss3 \
    libatk-bridge2.0-0 \
    libxss1 \
    libxtst6 \
    libsecret-1-0 \
    libatomic1 \
    libgbm1 \
    libayatana-appindicator3-1 \
    xdg-utils \
    pulseaudio-utils || true

# Try installing libasound2 and libgtk-3 (names vary between noble and earlier distros)
apt-get install -y --no-install-recommends libasound2t64 libgtk-3-0t64 2>/dev/null || \
apt-get install -y --no-install-recommends libasound2 libgtk-3-0 2>/dev/null || true

# 3. Handle architecture-specific Spotify setup
case "$ARCH" in
    x86_64|amd64)
        info "Running on native x86_64. Configuring Spotify official APT repository..."
        curl -sS https://download.spotify.com/debian/pubkey_6224F9941A8AA6D1.gpg | \
            gpg --dearmor --yes -o /etc/apt/trusted.gpg.d/spotify.gpg
        echo "deb http://repository.spotify.com stable non-free" > /etc/apt/sources.list.d/spotify.list
        apt-get update -y
        apt-get install -y --no-install-recommends spotify-client
        ;;

    aarch64|arm64)
        info "Running on ARM64. Configuring Box64 translation layer..."
        # Add Ryan Fortner's box64 repository
        wget -qO- https://ryanfortner.github.io/box64-debs/KEY.gpg | \
            gpg --dearmor --yes -o /etc/apt/trusted.gpg.d/box64-debs-archive-keyring.gpg
        echo "deb [signed-by=/etc/apt/trusted.gpg.d/box64-debs-archive-keyring.gpg] https://ryanfortner.github.io/box64-debs/debian ./ " \
            > /etc/apt/sources.list.d/box64.list

        apt-get update -y
        info "Installing Box64..."
        apt-get install -y box64-android 2>/dev/null || apt-get install -y box64

        info "Downloading Spotify x86_64 package from Spotify repository..."
        PKG_PATH=$(curl -sL http://repository.spotify.com/dists/stable/non-free/binary-amd64/Packages | \
            awk '/^Package: spotify-client$/{p=1} p && /^Filename:/{print $2; exit}')

        if [ -z "$PKG_PATH" ]; then
            error "Could not resolve latest spotify-client deb package URL from repository."
            exit 1
        fi

        SPOTIFY_URL="http://repository.spotify.com/${PKG_PATH}"
        info "Fetching: ${SPOTIFY_URL}"
        TEMP_DIR=$(mktemp -d)
        curl -sSL "$SPOTIFY_URL" -o "${TEMP_DIR}/spotify.deb"

        info "Extracting Spotify desktop client files..."
        (
            cd "$TEMP_DIR"
            ar -x spotify.deb
            if [ -f data.tar.gz ]; then
                tar -xzf data.tar.gz -C /
            elif [ -f data.tar.xz ]; then
                tar -xJf data.tar.xz -C /
            elif [ -f data.tar.zst ]; then
                tar --zstd -xf data.tar.zst -C /
            else
                tar -xf data.tar.* -C /
            fi
        )
        rm -rf "$TEMP_DIR"

        # Create wrapper script for box64 execution
        info "Creating Box64 wrapper for Spotify executable..."
        cat << 'WRAPPER' > /usr/bin/spotify
#!/bin/sh
# Wrapper to execute x86_64 Spotify via Box64 on ARM64
exec box64 /usr/share/spotify/spotify "$@"
WRAPPER
        chmod +x /usr/bin/spotify
        ;;

    *)
        error "Unsupported architecture: ${ARCH}. Supported architectures: aarch64, x86_64."
        exit 1
        ;;
esac

# 4. Verify Spotify installation
if [ ! -f /usr/share/spotify/spotify ] && [ ! -f /usr/bin/spotify ]; then
    error "Spotify binary not found after installation step!"
    exit 1
fi
success "Spotify client successfully installed."

# 5. Apply SpotX-Bash patch (non-interactive mode)
info "Applying SpotX-Bash patch..."
bash <(curl -sSL https://raw.githubusercontent.com/SpotX-Official/SpotX-Bash/main/spotx.sh) \
    --noninteractive -f -c || {
    warn "SpotX non-interactive script returned non-zero. Verifying patched files..."
}

if [ -f /usr/share/spotify/Apps/xpui.spa ]; then
    success "SpotX patch successfully processed!"
else
    warn "Spotify xpui.spa not found at standard path. Please check SpotX logs."
fi

# 6. Create custom runner inside container (/usr/local/bin/spotify-termux)
info "Generating container runner script /usr/local/bin/spotify-termux..."
cat << 'RUNNER' > /usr/local/bin/spotify-termux
#!/usr/bin/env bash
# ==============================================================================
# spotify-termux - Environment and flags runner for Spotify inside PRoot
# ==============================================================================
export DISPLAY="${DISPLAY:-:0}"
export PULSE_SERVER="${PULSE_SERVER:-127.0.0.1}"

# Flags required for Chromium / Electron inside PRoot user-space:
FLAGS=(
    --no-sandbox
    --disable-dev-shm-usage
    --disable-gpu
    --in-process-gpu
    --disable-software-rasterizer
    --disable-accelerated-2d-canvas
    --ozone-platform=x11
)

exec /usr/bin/spotify "${FLAGS[@]}" "$@"
RUNNER

chmod +x /usr/local/bin/spotify-termux
success "Guest setup finished completely and successfully!"
