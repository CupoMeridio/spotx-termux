#!/usr/bin/env bash
# ==============================================================================
# guest-setup.sh - Configuration script inside PRoot Ubuntu container
#
# Modes:
#   --probe             — print container state as KEY=VALUE lines and exit.
#                         Read-only and offline: the single source of truth used
#                         by spotify-doctor and spotify-update on the host.
#   (default)           — idempotent install / update, driven by environment:
#     SPOTX_ONLY=1      — skip Spotify client update, re-apply SpotX patch only
#     SPOTX_SKIP=1      — skip SpotX patch application
#     SPOTX_FORCE=1     — force full re-download and re-installation of Spotify and Box64
#
# A copy of this script is kept at GUEST_SETUP_INSTALLED so the host can run
# the probe without network access.
# ==============================================================================
set -euo pipefail

# Version of the --probe output format; the host refuses scripts without it.
SPOTX_PROBE_API=1

VERSION_MARKER="/usr/share/spotify/.spotx-termux-version"
SPOTIFY_DIR="/usr/share/spotify"
XPUI_SPA="${SPOTIFY_DIR}/Apps/xpui.spa"
GUEST_SETUP_INSTALLED="/usr/local/lib/spotx-termux/guest-setup.sh"

# ---------------------------------------------------------------------------
# Helper: resolve latest Spotify version and package path from APT metadata
# Sets: LATEST_VER, PKG_PATH, PKG_SHA256
# ---------------------------------------------------------------------------
resolve_latest_spotify() {
    # -f: treat HTTP errors as failures instead of parsing an error page.
    # On failure the variables stay empty; callers handle that (PKG_PATH check / "unknown").
    PACKAGES_DATA=$(curl -fsSL https://repository.spotify.com/dists/stable/non-free/binary-amd64/Packages 2>/dev/null || true)
    PKG_PATH=$(awk '/^Package: spotify-client$/{p=1} p && /^Filename:/{print $2; exit}' <<< "$PACKAGES_DATA")
    LATEST_VER=$(awk '/^Package: spotify-client$/{p=1} p && /^Version:/{print $2; exit}' <<< "$PACKAGES_DATA")
    PKG_SHA256=$(awk '/^Package: spotify-client$/{p=1} p && /^SHA256:/{print $2; exit}' <<< "$PACKAGES_DATA")
}

# ---------------------------------------------------------------------------
# Helper: read installed version (marker file, then package changelog, then dpkg)
# Sets: INSTALLED_VER
# ---------------------------------------------------------------------------
read_installed_version() {
    INSTALLED_VER=""
    if [ -f "$VERSION_MARKER" ]; then
        INSTALLED_VER=$(tr -d '[:space:]' < "$VERSION_MARKER" 2>/dev/null || true)
    fi
    if [ -z "$INSTALLED_VER" ] && [ -f /usr/share/doc/spotify-client/changelog.Debian.gz ]; then
        INSTALLED_VER=$(zcat /usr/share/doc/spotify-client/changelog.Debian.gz 2>/dev/null | awk '/^spotify-client \(/ { gsub(/[()]/,"",$2); print $2; exit }' || true)
        if [ -n "$INSTALLED_VER" ] && [ "${SPOTX_PROBE_MODE:-0}" != "1" ]; then
            mkdir -p "$(dirname "$VERSION_MARKER")" 2>/dev/null || true
            echo "$INSTALLED_VER" > "$VERSION_MARKER" 2>/dev/null || true
        fi
    fi
    if [ -z "$INSTALLED_VER" ] && command -v dpkg-query > /dev/null 2>&1; then
        INSTALLED_VER=$(dpkg-query -W -f='${Version}' spotify-client 2>/dev/null || true)
    fi
}

is_valid_elf() {
    [ -f "$1" ] && [ "$(head -c 4 "$1" 2>/dev/null)" = $'\x7fELF' ]
}

# ---------------------------------------------------------------------------
# Helper: SpotX patch state of xpui.spa -> applied | not_applied | missing_xpui | unknown
#
# SpotX-Bash marks a patched client by appending "//# SpotX was here" to xpui.js
# (xpui-snapshot.js on newer clients) inside xpui.spa. Its backups (Apps/xpui.bak,
# spotify.bak) are NOT a valid signal: they survive a Spotify update, after which
# xpui.spa is stock again. Process substitution keeps grep's status only, so an
# early 'grep -q' exit (SIGPIPE in unzip) is not misread under pipefail.
# ---------------------------------------------------------------------------
spotx_patch_state() {
    local member
    [ -f "$XPUI_SPA" ] || { echo "missing_xpui"; return 0; }
    command -v unzip >/dev/null 2>&1 || { echo "unknown"; return 0; }
    for member in xpui.js xpui-snapshot.js; do
        if grep -Fq "SpotX" < <(unzip -p "$XPUI_SPA" "$member" 2>/dev/null); then
            echo "applied"
            return 0
        fi
    done
    echo "not_applied"
}

is_spotx_applied() {
    [ "$(spotx_patch_state)" = "applied" ]
}

# ===========================================================================
# PROBE MODE: machine-readable container state, no side effects, no network
# ===========================================================================
if [ "${1:-}" = "--probe" ]; then
    SPOTX_PROBE_MODE=1
    echo "GUEST_PROBE_API=${SPOTX_PROBE_API}"
    echo "GUEST_RESPONSIVE=yes"

    if command -v box64 >/dev/null 2>&1; then
        echo "GUEST_BOX64_VER=$(box64 -v 2>&1 | head -1 || true)"
    else
        echo "GUEST_BOX64_VER="
    fi
    if grep -Eq "^BOX64_INPROCESSGPU=0" /etc/box64.box64rc /root/.box64rc 2>/dev/null; then
        echo "GUEST_BOX64_GPU=0"
    else
        echo "GUEST_BOX64_GPU=other"
    fi

    if command -v matchbox-window-manager >/dev/null 2>&1; then
        echo "GUEST_WM=matchbox"
    elif command -v openbox >/dev/null 2>&1; then
        echo "GUEST_WM=openbox"
    else
        echo "GUEST_WM=none"
    fi

    if [ ! -f "${SPOTIFY_DIR}/spotify" ]; then
        echo "GUEST_ELF=missing"
    elif is_valid_elf "${SPOTIFY_DIR}/spotify"; then
        echo "GUEST_ELF=valid_elf"
    else
        echo "GUEST_ELF=corrupted"
    fi

    read_installed_version
    echo "GUEST_VER=${INSTALLED_VER}"
    echo "GUEST_SPOTX=$(spotx_patch_state)"

    if [ -x /usr/local/bin/spotify-termux ]; then
        echo "GUEST_RUNNER=yes"
    else
        echo "GUEST_RUNNER=no"
    fi
    if command -v playerctl >/dev/null 2>&1; then
        echo "GUEST_PLAYERCTL=yes"
    else
        echo "GUEST_PLAYERCTL=no"
    fi
    exit 0
fi

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

echo -e "${CYAN}============================================${CLR}"
echo -e "${CYAN}${BOLD}   SpotX-Termux - Container Setup (PRoot)   ${CLR}"
echo -e "${CYAN}============================================${CLR}"

export DEBIAN_FRONTEND=noninteractive

ARCH="$(uname -m)"
info "Detected architecture inside container: ${ARCH}"

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

# 1. Update APT lists and install dependencies
# ---------------------------------------------------------------------------
# apt-get installs a package list all-or-nothing: one renamed or missing package
# (e.g. the Ubuntu 24.04 "t64" transition) makes the whole call fail. Packages are
# therefore split by importance and installed through apt_install_set, which:
#   - resolves alternatives written as "new|old" (first installable name wins);
#   - keeps the fast path (one apt-get call per group);
#   - on failure, isolates the unavailable packages and installs the rest;
#   - aborts for a missing REQUIRED package, only warns for an OPTIONAL one.
# ---------------------------------------------------------------------------
apt_installable() {
    # A dry run also resolves virtual packages provided by exactly one real package
    apt-get install -s -qq --no-install-recommends "$1" >/dev/null 2>&1
}

# apt_install_set <required|optional> <description> <package|alt1|alt2...>...
apt_install_set() {
    local mode="$1" what="$2"
    shift 2
    local entry alt chosen pkg
    local -a alts=() pkgs=() good=() missing=()

    for entry in "$@"; do
        if [[ "$entry" == *"|"* ]]; then
            chosen=""
            IFS='|' read -r -a alts <<< "$entry"
            for alt in "${alts[@]}"; do
                if apt_installable "$alt"; then
                    chosen="$alt"
                    break
                fi
            done
            if [ -n "$chosen" ]; then pkgs+=("$chosen"); else missing+=("${entry//|/ or }"); fi
        else
            pkgs+=("$entry")
        fi
    done

    info "Installing ${what}..."
    if [ ${#pkgs[@]} -gt 0 ] && ! apt-get install -y --no-install-recommends "${pkgs[@]}"; then
        warn "Installing ${what} as a group failed; isolating the problematic packages..."
        for pkg in "${pkgs[@]}"; do
            if apt_installable "$pkg"; then good+=("$pkg"); else missing+=("$pkg"); fi
        done
        if [ ${#good[@]} -gt 0 ] && ! apt-get install -y --no-install-recommends "${good[@]}"; then
            # Dependencies conflict only in combination: fall back to one package at a time
            for pkg in "${good[@]}"; do
                apt-get install -y --no-install-recommends "$pkg" || missing+=("$pkg")
            done
        fi
    fi

    if [ ${#missing[@]} -gt 0 ]; then
        if [ "$mode" = "required" ]; then
            error "Required packages could not be installed: ${missing[*]}"
            error "Spotify cannot run without them. Check the network / Ubuntu mirrors and retry."
            exit 1
        fi
        warn "Optional packages not installed: ${missing[*]}"
        warn "Spotify will still run; the related features may be unavailable."
    fi
}

info "Updating container package sources..."
apt-get update -y

# Tools used by this script (ar/tar/xz to unpack the .deb, curl/gpg for repositories)
# and by SpotX-Bash (perl, zip, unzip)
apt_install_set required "base utilities and unpack tools" \
    curl wget gpg tar xz-utils binutils perl zip unzip procps ca-certificates

# Libraries the Electron/Chromium runtime of Spotify cannot start without,
# plus fonts (no text otherwise) and the PulseAudio client library (no audio otherwise)
apt_install_set required "core GUI, audio and Electron runtime libraries" \
    libnss3 \
    libnspr4 \
    libgbm1 \
    libgl1 \
    libgl1-mesa-dri \
    libxkbcommon0 \
    libxss1 \
    libxtst6 \
    libxshmfence1 \
    libxcomposite1 \
    libxdamage1 \
    libxrandr2 \
    libdbus-1-3 \
    "libasound2t64|libasound2" \
    "libgtk-3-0t64|libgtk-3-0" \
    "libatk-bridge2.0-0t64|libatk-bridge2.0-0" \
    fonts-dejavu-core \
    pulseaudio-utils

# Features that degrade gracefully when missing
apt_install_set optional "optional integration libraries" \
    matchbox-window-manager \
    dbus-x11 \
    playerctl \
    libayatana-appindicator3-1 \
    libayatana-appindicator-glib2 \
    libnotify4 \
    libsecret-1-0 \
    libsm6 \
    libice6 \
    libatomic1 \
    libpci3 \
    libudev1 \
    libva2 \
    libva-drm2 \
    libva-x11-2 \
    libvulkan1 \
    mesa-vulkan-drivers \
    xdg-utils \
    "libcups2t64|libcups2"

# Ensure D-Bus machine ID exists (required for dbus-launch inside containers)
if command -v dbus-uuidgen >/dev/null 2>&1; then
    mkdir -p /var/lib/dbus /etc
    dbus-uuidgen --ensure 2>/dev/null || true
    if [ ! -f /etc/machine-id ] && [ -f /var/lib/dbus/machine-id ]; then
        ln -sf /var/lib/dbus/machine-id /etc/machine-id 2>/dev/null || true
    fi
fi

# 3. Handle architecture-specific Spotify setup
SPOTIFY_UPDATED=0
case "$ARCH" in
    x86_64|amd64)
        if [ "${SPOTX_ONLY:-}" = "1" ]; then
            info "SPOTX_ONLY mode: skipping Spotify client update."
        else
            info "Running on native x86_64. Configuring Spotify official APT repository..."
            mkdir -p /etc/apt/trusted.gpg.d /etc/apt/sources.list.d
            curl -fsS https://download.spotify.com/debian/pubkey_6224F9941A8AA6D1.gpg | \
                gpg --dearmor --yes -o /etc/apt/trusted.gpg.d/spotify.gpg
            echo "deb https://repository.spotify.com stable non-free" > /etc/apt/sources.list.d/spotify.list
            apt-get update -y
            read_installed_version
            OLD_VER="$INSTALLED_VER"
            if [ "${SPOTX_FORCE:-0}" = "1" ]; then
                info "Force mode enabled: reinstalling spotify-client..."
                apt-get install --reinstall -y --no-install-recommends spotify-client
                SPOTIFY_UPDATED=1
            else
                apt-get install -y --no-install-recommends spotify-client
                read_installed_version
                if [ -z "$OLD_VER" ] || [ "$OLD_VER" != "$INSTALLED_VER" ]; then
                    SPOTIFY_UPDATED=1
                fi
            fi
            if command -v dpkg-query > /dev/null 2>&1; then
                mkdir -p "$(dirname "$VERSION_MARKER")"
                dpkg-query -W -f='${Version}' spotify-client > "$VERSION_MARKER" 2>/dev/null || true
            fi
        fi
        ;;

    aarch64|arm64)
        # ---------------------------------------------------------------
        # 3a. Box64 — skip if already installed unless SPOTX_FORCE=1
        # ---------------------------------------------------------------
        if [ "${SPOTX_FORCE:-0}" != "1" ] && command -v box64 > /dev/null 2>&1; then
            success "Box64 already installed: $(box64 -v 2>&1 | head -1 || echo 'unknown version')"
        else
            if [ "${SPOTX_FORCE:-0}" = "1" ] && command -v box64 > /dev/null 2>&1; then
                info "Force mode enabled: reinstalling Box64 translation layer..."
            else
                info "Running on ARM64. Configuring Box64 translation layer..."
            fi
            mkdir -p /etc/apt/trusted.gpg.d /etc/apt/sources.list.d
            # Add Ryan Fortner's box64 repository
            wget -qO- https://ryanfortner.github.io/box64-debs/KEY.gpg | \
                gpg --dearmor --yes -o /etc/apt/trusted.gpg.d/box64-debs-archive-keyring.gpg
            echo "deb [signed-by=/etc/apt/trusted.gpg.d/box64-debs-archive-keyring.gpg] https://ryanfortner.github.io/box64-debs/debian ./ " \
                > /etc/apt/sources.list.d/box64.list

            apt-get update -y
            info "Installing Box64..."
            apt-get install --reinstall -y box64-android 2>/dev/null || apt-get install --reinstall -y box64 2>/dev/null || apt-get install -y box64-android 2>/dev/null || apt-get install -y box64
            success "Box64 configured successfully."
        fi

        # ---------------------------------------------------------------
        # 3b. Spotify client — skip download if version matches unless SPOTX_FORCE=1
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

            # is_valid_elf also catches a binary overwritten by a shell script through the
            # /usr/bin/spotify symlink (see the wrapper note below)
            if [ "${SPOTX_FORCE:-0}" != "1" ] && [ -n "$INSTALLED_VER" ] && [ "$INSTALLED_VER" = "$LATEST_VER" ] && is_valid_elf /usr/share/spotify/spotify; then
                success "Spotify ${INSTALLED_VER} is already installed, valid ELF binary, and up-to-date. Skipping download."
                SPOTIFY_UPDATED=0
            else
                SPOTIFY_UPDATED=1
                if [ "${SPOTX_FORCE:-0}" = "1" ]; then
                    info "Force mode enabled: re-downloading and re-installing Spotify ${LATEST_VER}..."
                elif [ -n "$INSTALLED_VER" ]; then
                    info "Updating Spotify: ${INSTALLED_VER} → ${LATEST_VER}"
                else
                    info "Installing Spotify ${LATEST_VER} (fresh install)"
                fi

                SPOTIFY_URL="https://repository.spotify.com/${PKG_PATH}"
                info "Downloading Spotify client: ${SPOTIFY_URL}"
                TEMP_DIR=$(mktemp -d)
                if ! curl -fsSL "$SPOTIFY_URL" -o "${TEMP_DIR}/spotify.deb"; then
                    error "Failed to download Spotify package from ${SPOTIFY_URL}"
                    rm -rf "$TEMP_DIR"
                    exit 1
                fi

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

                # No backup cleanup needed: SpotX-Bash keeps Apps/xpui.bak + spotify.bak and
                # refreshes them itself when it finds an unpatched binary (fresh extraction).

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
elif [ "${SPOTX_ONLY:-0}" != "1" ] && [ "${SPOTX_FORCE:-0}" != "1" ] && [ "$SPOTIFY_UPDATED" = "0" ] && is_spotx_applied; then
    success "Spotify is up-to-date and SpotX patch is already applied. Skipping patch."
    info "Use 'spotify-update --spotx-only' or '--force' to re-apply SpotX."
else
    info "Applying SpotX-Bash patch..."
    read_installed_version
    SPOTX_CLEAN_VER="${INSTALLED_VER:-${LATEST_VER:-}}"
    # Strip Debian epoch prefix like '1:' if present
    SPOTX_CLEAN_VER="${SPOTX_CLEAN_VER#*:}"
    # Strip git commit suffix like '.g0eeebbed' if present
    SPOTX_CLEAN_VER="${SPOTX_CLEAN_VER%%.g*}"

    SPOTX_SCRIPT_TMP=$(mktemp)
    # Download failures must not abort setup: the container runner below still has to be generated.
    if curl -fsSL https://raw.githubusercontent.com/SpotX-Official/SpotX-Bash/main/spotx.sh -o "$SPOTX_SCRIPT_TMP" 2>/dev/null \
        && [ "$(head -c 2 "$SPOTX_SCRIPT_TMP" 2>/dev/null)" = "#!" ]; then

        SPOTX_ARGS=(--noninteractive -f -c -P /usr/share/spotify)
        if [ -n "$SPOTX_CLEAN_VER" ]; then
            SPOTX_ARGS+=(-F "$SPOTX_CLEAN_VER")
        fi

        # Kill any lingering Spotify processes before patching.
        # Patterns must stay narrow: PRoot shares /proc with the Termux host, so a broad
        # 'pkill -f spotify' would also match and kill the host updater (update-spotify.sh)
        # that is running this very script.
        pkill -9 -f "/usr/share/spotify/spotify" 2>/dev/null || true
        pkill -9 -f "/usr/local/bin/spotify-termux" 2>/dev/null || true
        pkill -9 -x spotify 2>/dev/null || true

        # SPOTX_BUILD_MODE=1 prevents complex multi-user stagedInstall/chown/mktemp rollbacks
        # that fail inside rootless PRoot containers on Android
        SPOTX_BUILD_MODE=1 bash "$SPOTX_SCRIPT_TMP" "${SPOTX_ARGS[@]}" || {
            warn "SpotX non-interactive script returned non-zero. Checking patched files..."
        }

        if is_spotx_applied; then
            success "SpotX patch successfully applied to xpui.spa!"
        else
            warn "SpotX patch was not detected in xpui.spa. Spotify will run with stock UI."
        fi
    else
        warn "Could not download a valid SpotX-Bash script (network or GitHub error)."
        warn "Spotify will run with stock UI. Retry later with: spotify-update --spotx-only"
    fi
    rm -f "$SPOTX_SCRIPT_TMP"
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
export PULSE_LATENCY_MSEC="${PULSE_LATENCY_MSEC:-500}"
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

# Export D-Bus session bus address to shared tmp
if [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
    echo "$DBUS_SESSION_BUS_ADDRESS" > /tmp/spotx-dbus-address 2>/dev/null || true
    echo "export DBUS_SESSION_BUS_ADDRESS=\"$DBUS_SESSION_BUS_ADDRESS\"" > /tmp/spotx-dbus.env 2>/dev/null || true
fi

# Start background media control and metadata bridge if playerctl is present
BRIDGE_PID=""
META_PID=""
if command -v playerctl >/dev/null 2>&1; then
    # 1. Listen for host control commands (play, pause, next, previous) via FIFO
    (
        rm -f /tmp/spotx-control.fifo
        mkfifo /tmp/spotx-control.fifo 2>/dev/null || true
        if [ -p /tmp/spotx-control.fifo ]; then
            exec 3<> /tmp/spotx-control.fifo
            while read -r -u 3 cmd; do
                case "$cmd" in
                    play-pause) playerctl -p spotify play-pause 2>/dev/null || true ;;
                    play)       playerctl -p spotify play 2>/dev/null || true ;;
                    pause)      playerctl -p spotify pause 2>/dev/null || true ;;
                    next)       playerctl -p spotify next 2>/dev/null || true ;;
                    previous)   playerctl -p spotify previous 2>/dev/null || true ;;
                    quit|stop)  break ;;
                esac
            done
            exec 3>&-
        fi
    ) &
    BRIDGE_PID=$!

    # 2. Monitor Spotify MPRIS metadata and playback status changes
    (
        for ((i=1; i<=40; i++)); do
            if playerctl -p spotify status >/dev/null 2>&1; then
                break
            fi
            sleep 0.5
        done
        if playerctl -p spotify status >/dev/null 2>&1; then
            playerctl -p spotify metadata --format '{{status}}:::{{artist}}:::{{title}}' --follow 2>/dev/null | while IFS= read -r line; do
                [ -z "$line" ] && continue
                echo "$line" > /tmp/spotx-media.status.tmp 2>/dev/null && mv -f /tmp/spotx-media.status.tmp /tmp/spotx-media.status 2>/dev/null || true
                if [ -p /tmp/spotx-media.fifo ]; then
                    ( echo "$line" > /tmp/spotx-media.fifo 2>/dev/null & )
                fi
            done
        fi
    ) &
    META_PID=$!
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

# Terminate media bridge and window manager on exit
if [ -n "$BRIDGE_PID" ]; then
    kill "$BRIDGE_PID" 2>/dev/null || true
fi
if [ -n "$META_PID" ]; then
    kill "$META_PID" 2>/dev/null || true
fi
if [ -n "$WM_PID" ]; then
    kill "$WM_PID" 2>/dev/null || true
fi
rm -f /tmp/spotx-control.fifo /tmp/spotx-media.status /tmp/spotx-media.status.tmp /tmp/spotx-dbus-address /tmp/spotx-dbus.env 2>/dev/null || true

exit $SPOTIFY_EXIT_CODE
RUNNER

chmod +x /usr/local/bin/spotify-termux

# 7. Keep a copy of this script inside the container so the host can run
#    '--probe' (doctor / updater) without network access
mkdir -p "$(dirname "$GUEST_SETUP_INSTALLED")"
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ] && [ "${BASH_SOURCE[0]}" != "$GUEST_SETUP_INSTALLED" ]; then
    cp -f "${BASH_SOURCE[0]}" "$GUEST_SETUP_INSTALLED" 2>/dev/null || true
    chmod +x "$GUEST_SETUP_INSTALLED" 2>/dev/null || true
fi

success "Container setup finished completely and successfully!"
