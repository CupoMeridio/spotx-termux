#!/usr/bin/env bash
# ==============================================================================
# guest-setup.sh - Configuration script inside PRoot Ubuntu container
# Supports idempotent re-execution and environment-driven modes:
#   SPOTX_CHECK_ONLY=1  — print version info and exit without changes
#   SPOTX_ONLY=1        — skip Spotify client update, re-apply SpotX patch only
#   SPOTX_SKIP=1        — skip SpotX patch application
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

VERSION_MARKER="/usr/share/spotify/.spotx-termux-version"

echo -e "${CYAN}======================================================${CLR}"
echo -e "${CYAN}${BOLD}   SpotX Termux - Container Guest Setup (PRoot)       ${CLR}"
echo -e "${CYAN}======================================================${CLR}"

export DEBIAN_FRONTEND=noninteractive

ARCH="$(uname -m)"
info "Detected architecture inside container: ${ARCH}"

# ---------------------------------------------------------------------------
# Helper: resolve latest Spotify version and package path from APT metadata
# Sets: LATEST_VER, PKG_PATH, PKG_SHA256
# ---------------------------------------------------------------------------
resolve_latest_spotify() {
    PACKAGES_DATA=$(curl -sSL https://repository.spotify.com/dists/stable/non-free/binary-amd64/Packages)
    PKG_PATH=$(awk '/^Package: spotify-client$/{p=1} p && /^Filename:/{print $2; exit}' <<< "$PACKAGES_DATA")
    LATEST_VER=$(awk '/^Package: spotify-client$/{p=1} p && /^Version:/{print $2; exit}' <<< "$PACKAGES_DATA")
    PKG_SHA256=$(awk '/^Package: spotify-client$/{p=1} p && /^SHA256:/{print $2; exit}' <<< "$PACKAGES_DATA")
}

# ---------------------------------------------------------------------------
# Helper: read installed version from marker file
# Sets: INSTALLED_VER
# ---------------------------------------------------------------------------
read_installed_version() {
    INSTALLED_VER=""
    if [ -f "$VERSION_MARKER" ]; then
        INSTALLED_VER=$(cat "$VERSION_MARKER" 2>/dev/null || true)
    elif command -v dpkg-query > /dev/null 2>&1; then
        INSTALLED_VER=$(dpkg-query -W -f='${Version}' spotify-client 2>/dev/null || true)
    fi
}

# ===========================================================================
# CHECK-ONLY MODE: print versions and exit
# ===========================================================================
if [ "${SPOTX_CHECK_ONLY:-}" = "1" ]; then
    read_installed_version
    resolve_latest_spotify

    echo
    if [ -n "$INSTALLED_VER" ]; then
        echo -e "  Installed Spotify version: ${GREEN}${BOLD}${INSTALLED_VER}${CLR}"
    else
        echo -e "  Installed Spotify version: ${RED}${BOLD}not installed${CLR}"
    fi
    echo -e "  Latest available version:  ${CYAN}${BOLD}${LATEST_VER:-unknown}${CLR}"

    if [ -n "$INSTALLED_VER" ] && [ "$INSTALLED_VER" = "${LATEST_VER:-}" ]; then
        echo -e "  Status: ${GREEN}${BOLD}up-to-date ✔${CLR}"
    else
        echo -e "  Status: ${YELLOW}${BOLD}update available${CLR}"
    fi

    SPOTX_APPLIED="no"
    if [ -f /usr/share/spotify/Apps/xpui.spa ]; then
        # Check for SpotX marker inside xpui.spa
        if unzip -p /usr/share/spotify/Apps/xpui.spa xpui.js 2>/dev/null | grep -Fq "SpotX"; then
            SPOTX_APPLIED="yes"
        fi
    fi
    echo -e "  SpotX patch applied:       ${BOLD}${SPOTX_APPLIED}${CLR}"
    echo
    exit 0
fi

# ===========================================================================
# FULL / UPDATE INSTALLATION
# ===========================================================================

# ---------------------------------------------------------------------------
# Configure container environment policies for PRoot
# (Suppresses systemd/daemon reload warnings in containers lacking PID 1 systemd)
# ---------------------------------------------------------------------------
# 1. Instruct invoke-rc.d not to start/restart daemons (standard Debian/Ubuntu container policy)
if [ ! -f /usr/sbin/policy-rc.d ]; then
    cat << 'POLICY' > /usr/sbin/policy-rc.d
#!/bin/sh
exit 101
POLICY
    chmod +x /usr/sbin/policy-rc.d
fi

# 2. Provide a clean systemctl stub so package triggers do not output:
# "System has not been booted with systemd as init system (PID 1). Can't operate."
mkdir -p /usr/local/bin
cat << 'STUB' > /usr/local/bin/systemctl
#!/bin/sh
case "${1:-}" in
    is-active|is-failed) exit 3 ;;
    status) exit 3 ;;
    *) exit 0 ;;
esac
STUB
chmod +x /usr/local/bin/systemctl

# Also divert /usr/bin/systemctl to guarantee absolute path invocations use stub
if command -v dpkg-divert >/dev/null 2>&1; then
    if ! dpkg-divert --list 2>/dev/null | grep -q "/usr/bin/systemctl"; then
        dpkg-divert --divert /usr/bin/systemctl.original --rename --add /usr/bin/systemctl 2>/dev/null || true
    fi
    cp /usr/local/bin/systemctl /usr/bin/systemctl 2>/dev/null || true
    chmod +x /usr/bin/systemctl 2>/dev/null || true
fi

# 1. Update APT lists and install fundamental utilities
# (apt-get install is inherently idempotent — fast if packages exist)
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

# 2. Install shared GUI, audio, and Electron/Chromium runtime dependencies
info "Installing GUI, audio, and Electron runtime dependencies..."
apt-get install -y --no-install-recommends \
    libgl1-mesa-dri \
    libgl1 \
    libnss3 \
    libnspr4 \
    libatk-bridge2.0-0 \
    libsm6 \
    libice6 \
    libxss1 \
    libxtst6 \
    libxshmfence1 \
    libxcomposite1 \
    libxdamage1 \
    libxrandr2 \
    libsecret-1-0 \
    libatomic1 \
    libgbm1 \
    libayatana-appindicator3-1 \
    libayatana-appindicator-glib2 \
    libdbus-1-3 \
    dbus-x11 \
    libva2 \
    libva-drm2 \
    libva-x11-2 \
    libnotify4 \
    libpci3 \
    libvulkan1 \
    mesa-vulkan-drivers \
    libxkbcommon0 \
    xdg-utils \
    fonts-dejavu-core \
    matchbox-window-manager \
    pulseaudio-utils || true

# Install transitional/architecture libraries (handling Ubuntu 24.04 64-bit time_t suffix)
apt-get install -y --no-install-recommends \
    libasound2t64 libgtk-3-0t64 libcups2t64 2>/dev/null || \
apt-get install -y --no-install-recommends \
    libasound2 libgtk-3-0 libcups2 2>/dev/null || true

apt-get install -y --no-install-recommends libudev1 2>/dev/null || true

# Ensure D-Bus machine ID exists (required for dbus-launch inside containers)
if command -v dbus-uuidgen >/dev/null 2>&1; then
    mkdir -p /var/lib/dbus /etc
    dbus-uuidgen --ensure 2>/dev/null || true
    if [ ! -f /etc/machine-id ] && [ -f /var/lib/dbus/machine-id ]; then
        ln -sf /var/lib/dbus/machine-id /etc/machine-id 2>/dev/null || true
    fi
fi

# 3. Handle architecture-specific Spotify setup
case "$ARCH" in
    x86_64|amd64)
        if [ "${SPOTX_ONLY:-}" = "1" ]; then
            info "SPOTX_ONLY mode: skipping Spotify client update."
        else
            info "Running on native x86_64. Configuring Spotify official APT repository..."
            mkdir -p /etc/apt/trusted.gpg.d /etc/apt/sources.list.d
            curl -sS https://download.spotify.com/debian/pubkey_6224F9941A8AA6D1.gpg | \
                gpg --dearmor --yes -o /etc/apt/trusted.gpg.d/spotify.gpg
            echo "deb https://repository.spotify.com stable non-free" > /etc/apt/sources.list.d/spotify.list
            apt-get update -y
            apt-get install -y --no-install-recommends spotify-client
            if command -v dpkg-query > /dev/null 2>&1; then
                mkdir -p "$(dirname "$VERSION_MARKER")"
                dpkg-query -W -f='${Version}' spotify-client > "$VERSION_MARKER" 2>/dev/null || true
            fi
        fi
        ;;

    aarch64|arm64)
        # ---------------------------------------------------------------
        # 3a. Box64 — skip if already installed
        # ---------------------------------------------------------------
        if command -v box64 > /dev/null 2>&1; then
            success "Box64 already installed: $(box64 --version 2>&1 | head -1 || echo 'unknown version')"
        else
            info "Running on ARM64. Configuring Box64 translation layer..."
            mkdir -p /etc/apt/trusted.gpg.d /etc/apt/sources.list.d
            # Add Ryan Fortner's box64 repository
            wget -qO- https://ryanfortner.github.io/box64-debs/KEY.gpg | \
                gpg --dearmor --yes -o /etc/apt/trusted.gpg.d/box64-debs-archive-keyring.gpg
            echo "deb [signed-by=/etc/apt/trusted.gpg.d/box64-debs-archive-keyring.gpg] https://ryanfortner.github.io/box64-debs/debian ./ " \
                > /etc/apt/sources.list.d/box64.list

            apt-get update -y
            info "Installing Box64..."
            apt-get install -y box64-android 2>/dev/null || apt-get install -y box64
            success "Box64 installed successfully."
        fi

        # ---------------------------------------------------------------
        # 3b. Spotify client — skip download if version matches
        # ---------------------------------------------------------------
        if [ "${SPOTX_ONLY:-}" = "1" ]; then
            info "SPOTX_ONLY mode: skipping Spotify client update."
        else
            resolve_latest_spotify
            read_installed_version

            if [ -z "$PKG_PATH" ]; then
                error "Could not resolve latest spotify-client deb package URL from repository."
                exit 1
            fi

            # Helper to check if a file is a valid ELF binary (not a shell script from symlink overwrite)
            is_valid_elf() {
                local f="$1"
                [ -f "$f" ] && [ "$(head -c 4 "$f" 2>/dev/null)" = $'\x7fELF' ]
            }

            if [ -n "$INSTALLED_VER" ] && [ "$INSTALLED_VER" = "$LATEST_VER" ] && is_valid_elf /usr/share/spotify/spotify; then
                success "Spotify ${INSTALLED_VER} is already installed, valid ELF binary, and up-to-date. Skipping download."
            else
                if [ -n "$INSTALLED_VER" ]; then
                    info "Updating Spotify: ${INSTALLED_VER} → ${LATEST_VER}"
                else
                    info "Installing Spotify ${LATEST_VER} (fresh install)"
                fi

                SPOTIFY_URL="https://repository.spotify.com/${PKG_PATH}"
                info "Downloading Spotify client: ${SPOTIFY_URL}"
                TEMP_DIR=$(mktemp -d)
                curl -sSL "$SPOTIFY_URL" -o "${TEMP_DIR}/spotify.deb"

                # Verify package integrity using SHA256 from repository metadata
                if [ -n "${PKG_SHA256:-}" ]; then
                    info "Verifying SHA256 integrity of downloaded package..."
                    ACTUAL_SHA256=$(sha256sum "${TEMP_DIR}/spotify.deb" | awk '{print $1}')
                    if [ "$ACTUAL_SHA256" != "$PKG_SHA256" ]; then
                        error "SHA256 mismatch! Expected: ${PKG_SHA256}"
                        error "                Got:      ${ACTUAL_SHA256}"
                        error "The downloaded file may be corrupted or tampered with. Aborting."
                        rm -rf "$TEMP_DIR"
                        exit 1
                    fi
                    success "SHA256 integrity verified: ${PKG_SHA256:0:16}..."
                else
                    warn "Could not extract SHA256 from repository metadata. Skipping integrity check."
                fi

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

                # Crucial: Debian package extracts /usr/bin/spotify as a symlink to ../share/spotify/spotify.
                # Remove it now so our Box64 wrapper does not follow the symlink and overwrite /usr/share/spotify/spotify!
                rm -f /usr/bin/spotify

                # Save installed version marker
                mkdir -p "$(dirname "$VERSION_MARKER")"
                echo "$LATEST_VER" > "$VERSION_MARKER"
                success "Spotify ${LATEST_VER} installed and version marker saved."
            fi
        fi

        # Configure Box64 settings specifically for Spotify
        # We must set BOX64_INPROCESSGPU=0 because injecting --in-process-gpu
        # crashes Spotify's zygote process ("Try 'spotify --help' for more information")
        info "Configuring Box64 Spotify settings..."
        mkdir -p /etc /root
        cat << 'BOX64RC' > /root/.box64rc
[spotify]
BOX64_NOBANNER=1
BOX64_LOG=0
BOX64_DYNAREC=1
BOX64_NOSANDBOX=1
BOX64_INPROCESSGPU=0
BOX64_MALLOC_HACK=2
BOX64_DYNAREC_STRONGMEM=1
BOX64_DYNAREC_BIGBLOCK=1
BOX64_DYNAREC_FASTNAN=1
BOX64_DYNAREC_FASTROUND=1
BOX64_DYNAREC_SAFEFLAGS=1
BOX64RC
        # Fix /etc/box64.box64rc (installed by box64 package) to ensure BOX64_INPROCESSGPU is 0
        if [ -f /etc/box64.box64rc ]; then
            sed -i 's/BOX64_INPROCESSGPU[[:space:]]*=[[:space:]]*1/BOX64_INPROCESSGPU=0/g' /etc/box64.box64rc 2>/dev/null || true
            if ! grep -q "^\[spotify\]" /etc/box64.box64rc 2>/dev/null; then
                cat /root/.box64rc >> /etc/box64.box64rc
            fi
        else
            cp /root/.box64rc /etc/box64.box64rc 2>/dev/null || true
        fi

        # Create wrapper script for Box64 execution
        info "Configuring Box64 Spotify wrapper..."
        rm -f /usr/bin/spotify
        cat << 'WRAPPER' > /usr/bin/spotify
#!/bin/sh
# Box64 wrapper for Spotify Desktop Client on ARM64
export BOX64_NOBANNER=1
export BOX64_LOG=0
export BOX64_DYNAREC=1
export BOX64_NOSANDBOX=1
export BOX64_INPROCESSGPU=0
export BOX64_MALLOC_HACK=2
export BOX64_DYNAREC_STRONGMEM=1
export BOX64_DYNAREC_BIGBLOCK=1
export BOX64_DYNAREC_FASTNAN=1
export BOX64_DYNAREC_FASTROUND=1
export BOX64_DYNAREC_SAFEFLAGS=1
export BOX64_LD_LIBRARY_PATH="/usr/share/spotify:${BOX64_LD_LIBRARY_PATH:-}"
export LD_LIBRARY_PATH="/usr/share/spotify:${LD_LIBRARY_PATH:-}"
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
if [ "${SPOTX_SKIP:-}" = "1" ]; then
    info "SPOTX_SKIP is set: skipping SpotX patch application."
else
    info "Applying SpotX-Bash patch..."
    SPOTX_SCRIPT_TMP=$(mktemp)
    curl -sSL https://raw.githubusercontent.com/SpotX-Official/SpotX-Bash/main/spotx.sh -o "$SPOTX_SCRIPT_TMP"
    bash "$SPOTX_SCRIPT_TMP" --noninteractive -f -c -P /usr/share/spotify || {
        warn "SpotX non-interactive script returned non-zero. Checking patched files..."
    }
    rm -f "$SPOTX_SCRIPT_TMP"

    if [ -f /usr/share/spotify/Apps/xpui.spa ]; then
        success "SpotX patch successfully applied to xpui.spa!"
    else
        warn "Spotify xpui.spa not found at standard path. Please check SpotX logs."
    fi
fi

# 6. Create custom runner inside container (/usr/local/bin/spotify-termux)
info "Generating container runner script /usr/local/bin/spotify-termux..."
cat << 'RUNNER' > /usr/local/bin/spotify-termux
#!/usr/bin/env bash
# ==============================================================================
# spotify-termux - Environment and flags runner for Spotify inside PRoot
# ==============================================================================
export DISPLAY="${DISPLAY:-:0}"
export PULSE_SERVER="${PULSE_SERVER:-tcp:127.0.0.1:4713}"
export PULSE_LATENCY_MSEC="${PULSE_LATENCY_MSEC:-200}"
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

# Terminate window manager on exit
if [ -n "$WM_PID" ]; then
    kill "$WM_PID" 2>/dev/null || true
fi

exit $SPOTIFY_EXIT_CODE
RUNNER

chmod +x /usr/local/bin/spotify-termux
success "Container setup finished completely and successfully!"
