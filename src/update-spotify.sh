#!/data/data/com.termux/files/usr/bin/bash
# ==============================================================================
# update-spotify.sh - Termux host script to update Spotify and SpotX
# Repository: https://github.com/CupoMeridio/spotx-termux
# ==============================================================================
set -euo pipefail

# ------------------------------------------------------------------------------
# Load SpotX-Termux Shared Library
# ------------------------------------------------------------------------------
_SPOTX_LIB=""
SCRIPT_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
    if [ -f "${SCRIPT_DIR}/common.sh" ]; then
        _SPOTX_LIB="${SCRIPT_DIR}/common.sh"
    elif [ -f "${SCRIPT_DIR}/src/common.sh" ]; then
        _SPOTX_LIB="${SCRIPT_DIR}/src/common.sh"
    fi
fi
if [ -z "$_SPOTX_LIB" ] && [ -f "${HOME}/.spotx-termux/common.sh" ]; then
    _SPOTX_LIB="${HOME}/.spotx-termux/common.sh"
fi

if [ -z "$_SPOTX_LIB" ] || [ ! -f "$_SPOTX_LIB" ]; then
    echo "[X] Error: SpotX-Termux shared library not found (~/.spotx-termux/common.sh)" >&2
    echo "    Please run 'bash ~/update-spotify.sh' or 'bash install.sh' to repair." >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$_SPOTX_LIB"



show_help() {
    cat << EOF
SpotX-Termux Updater (v${SPOTX_TERMUX_VERSION})

Usage:
  spotify-update [OPTIONS]

Options:
  --check, -c       Check for updates without installing (prints installed & latest version)
  --doctor, -d      Run health check and diagnostics tool
  --force, -f       Force re-download and re-installation of Spotify and SpotX
  --spotx-only, -s  Re-apply SpotX patch only (skips Spotify client update/download)
  --skip-spotx      Update Spotify client only (skips SpotX patching)
  --version, -V     Show version information
  --help, -h        Show this help message

Examples:
  spotify-update              Check and update Spotify + apply SpotX patch
  spotify-update --check      Check if an update is available
  spotify-update --force      Force re-download and clean re-installation
  spotify-update --doctor     Run system diagnostic health check
  spotify-update --spotx-only Re-patch xpui.spa without re-downloading Spotify
EOF
}

SPOTX_CHECK_ONLY=0
SPOTX_ONLY=0
SPOTX_SKIP=0
SPOTX_FORCE=0

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --check|-c)
            SPOTX_CHECK_ONLY=1
            shift
            ;;
        --doctor|-d)
            shift
            if [ -x "${HOME}/doctor-spotify.sh" ]; then
                exec "$HOME/doctor-spotify.sh" "$@"
            elif [ -n "${SCRIPT_DIR:-}" ] && [ -f "${SCRIPT_DIR}/doctor.sh" ]; then
                exec bash "${SCRIPT_DIR}/doctor.sh" "$@"
            elif command -v spotify-doctor >/dev/null 2>&1; then
                exec spotify-doctor "$@"
            else
                error "spotify-doctor not found. Please re-run: bash install.sh"
                exit 1
            fi
            ;;
        --force|-f)
            SPOTX_FORCE=1
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
        --version|-V)
            echo "SpotX-Termux ${SPOTX_TERMUX_VERSION}"
            exit 0
            ;;
        *)
            error "Unknown argument: $1"
            show_help
            exit 1
            ;;
    esac
done

# Initialize logging for the update run
setup_logging "update.log"

if [ -z "${SPOTX_TERMUX_VERSION:-}" ] || [ "${SPOTX_TERMUX_VERSION}" = "unknown" ]; then
    SPOTX_TERMUX_VERSION="$(resolve_spotx_version)"
fi

CONTAINER_NAME="ubuntu"

# Verify proot-distro is installed
if ! command -v proot-distro > /dev/null 2>&1; then
    error "proot-distro command not found."
    error "Please ensure Termux dependencies are installed or run install.sh."
    exit 1
fi

# Verify container exists
if ! is_container_installed "$CONTAINER_NAME"; then
    error "PRoot container '${CONTAINER_NAME}' is not installed."
    error "Please run the full installer first: bash install.sh"
    exit 1
fi

# Helper: fetch latest SpotX-Termux script version from local repo or GitHub
get_latest_spotx_version() {
    local ver=""
    if [ "$SCRIPT_DIR" != "$HOME" ] && [ -n "$SCRIPT_DIR" ]; then
        if [ -f "${SCRIPT_DIR}/../VERSION" ]; then
            ver=$(cat "${SCRIPT_DIR}/../VERSION" 2>/dev/null | tr -d '[:space:]')
        elif [ -f "${SCRIPT_DIR}/VERSION" ]; then
            ver=$(cat "${SCRIPT_DIR}/VERSION" 2>/dev/null | tr -d '[:space:]')
        fi
    fi
    if [ -z "$ver" ] || [ "$ver" = "unknown" ]; then
        ver=$(curl -sSL --connect-timeout 2 --max-time 4 "https://raw.githubusercontent.com/CupoMeridio/spotx-termux/main/VERSION?t=$(date +%s)" 2>/dev/null | tr -d '[:space:]' || true)
    fi
    echo "${ver:-unknown}"
}

# Helper: read installed Spotify version from container rootfs or changelog
get_installed_spotify_version() {
    local direct_marker="${PREFIX:-/data/data/com.termux/files/usr}/var/lib/proot-distro/installed-rootfs/${CONTAINER_NAME}/usr/share/spotify/.spotx-termux-version"
    local direct_doc="${PREFIX:-/data/data/com.termux/files/usr}/var/lib/proot-distro/installed-rootfs/${CONTAINER_NAME}/usr/share/doc/spotify-client/changelog.Debian.gz"
    local direct_bin="${PREFIX:-/data/data/com.termux/files/usr}/var/lib/proot-distro/installed-rootfs/${CONTAINER_NAME}/usr/share/spotify/spotify"
    local ver=""

    if [ -f "$direct_marker" ]; then
        ver=$(cat "$direct_marker" 2>/dev/null | tr -d '[:space:]' || true)
    fi
    if [ -z "$ver" ] && [ -f "$direct_doc" ]; then
        ver=$(gzip -dc "$direct_doc" 2>/dev/null | awk '/^spotify-client \(/ { gsub(/[()]/,"",$2); print $2; exit }' || true)
    fi
    if [ -z "$ver" ] && command -v proot-distro >/dev/null 2>&1; then
        ver=$(proot-distro login "$CONTAINER_NAME" -- bash -c 'cat /usr/share/spotify/.spotx-termux-version 2>/dev/null || (gzip -dc /usr/share/doc/spotify-client/changelog.Debian.gz 2>/dev/null | awk '\''/^spotify-client \(/ { gsub(/[()]/,"",$2); print $2; exit }'\'')' 2>/dev/null | tr -d '[:space:]' || true)
    fi
    if [ -z "$ver" ] && [ -f "$direct_bin" ]; then
        ver="installed (unversioned)"
    fi
    echo "${ver:-not installed}"
}

# Helper: fetch latest Spotify client version from Debian repository metadata
get_latest_spotify_version() {
    local ver=""
    ver=$(curl -sSL --connect-timeout 3 --max-time 6 https://repository.spotify.com/dists/stable/non-free/binary-amd64/Packages 2>/dev/null | \
        awk '/^Package: spotify-client$/{p=1} p && /^Version:/{print $2; exit}' || true)
    echo "${ver:-unknown}"
}

# Helper: check SpotX patch status on xpui.spa
get_spotx_patch_status() {
    local direct_spa="${PREFIX:-/data/data/com.termux/files/usr}/var/lib/proot-distro/installed-rootfs/${CONTAINER_NAME}/usr/share/spotify/Apps/xpui.spa"
    if [ -f "$direct_spa" ]; then
        if grep -Fq "SpotX" "$direct_spa" 2>/dev/null; then
            echo "applied"
            return 0
        elif command -v unzip >/dev/null 2>&1 && unzip -p "$direct_spa" xpui.js 2>/dev/null | grep -Fq "SpotX"; then
            echo "applied"
            return 0
        else
            echo "not_applied"
            return 0
        fi
    fi
    if command -v proot-distro >/dev/null 2>&1; then
        if proot-distro login "$CONTAINER_NAME" -- bash -c 'grep -Fq "SpotX" /usr/share/spotify/Apps/xpui.spa 2>/dev/null' 2>/dev/null; then
            echo "applied"
            return 0
        fi
    fi
    echo "missing"
}

echo -e "${CYAN}============================================${CLR}"
echo -e "${CYAN}${BOLD}     SpotX-Termux - Updater Utility         ${CLR}"
echo -e "${CYAN}============================================${CLR}"

info "Checking component versions..."

SPOTX_TERMUX_LATEST_VERSION="$(get_latest_spotx_version)"
SPOTIFY_INSTALLED_VER="$(get_installed_spotify_version)"
SPOTIFY_LATEST_VER="$(get_latest_spotify_version)"
SPOTX_PATCH_STATUS="$(get_spotx_patch_status)"

# Evaluate Host Scripts Status
HOST_UPDATE_AVAIL=0
if [ -z "$SPOTX_TERMUX_LATEST_VERSION" ] || [ "$SPOTX_TERMUX_LATEST_VERSION" = "unknown" ]; then
    HOST_STATUS="${DIM}Check skipped (offline/unreachable)${CLR}"
elif [ "$SPOTX_TERMUX_VERSION" != "$SPOTX_TERMUX_LATEST_VERSION" ]; then
    HOST_STATUS="${YELLOW}${BOLD}Update available${CLR}"
    HOST_UPDATE_AVAIL=1
else
    HOST_STATUS="${GREEN}${BOLD}Up-to-date [OK]${CLR}"
fi

# Evaluate Spotify Desktop Client Status
SPOTIFY_UPDATE_AVAIL=0
if [ "$SPOTIFY_INSTALLED_VER" = "not installed" ]; then
    SPOTIFY_STATUS="${RED}${BOLD}Not installed${CLR}"
    SPOTIFY_UPDATE_AVAIL=1
elif [ -z "$SPOTIFY_LATEST_VER" ] || [ "$SPOTIFY_LATEST_VER" = "unknown" ]; then
    SPOTIFY_STATUS="${DIM}Check skipped (offline/unreachable)${CLR}"
elif [ "$SPOTIFY_INSTALLED_VER" != "$SPOTIFY_LATEST_VER" ]; then
    SPOTIFY_STATUS="${YELLOW}${BOLD}Update available${CLR}"
    SPOTIFY_UPDATE_AVAIL=1
else
    SPOTIFY_STATUS="${GREEN}${BOLD}Up-to-date [OK]${CLR}"
fi

# Evaluate SpotX Patch Status
PATCH_STATUS_STR="${GREEN}${BOLD}Applied [OK]${CLR}"
PATCH_UPDATE_AVAIL=0
if [ "$SPOTX_PATCH_STATUS" = "not_applied" ]; then
    PATCH_STATUS_STR="${YELLOW}${BOLD}Not applied (needs patch)${CLR}"
    PATCH_UPDATE_AVAIL=1
elif [ "$SPOTX_PATCH_STATUS" = "missing" ]; then
    PATCH_STATUS_STR="${RED}${BOLD}Missing (Spotify not installed)${CLR}"
    PATCH_UPDATE_AVAIL=1
fi

if [ "$SPOTIFY_INSTALLED_VER" = "not installed" ]; then
    PATCH_STATUS_STR="${YELLOW}${BOLD}Will be applied after install${CLR}"
    PATCH_UPDATE_AVAIL=1
elif [ "$SPOTIFY_UPDATE_AVAIL" = "1" ]; then
    PATCH_STATUS_STR="${CYAN}${BOLD}Pending re-patch after update${CLR}"
    PATCH_UPDATE_AVAIL=1
fi

echo
echo -e "  ${BOLD}Host Scripts & Utilities:${CLR}"
echo -e "    Current:     ${SPOTX_TERMUX_VERSION}"
echo -e "    Available:   ${SPOTX_TERMUX_LATEST_VERSION}"
echo -e "    Status:      ${HOST_STATUS}"
echo
echo -e "  ${BOLD}Spotify Desktop (Linux x86_64):${CLR}"
echo -e "    Installed:   ${SPOTIFY_INSTALLED_VER}"
echo -e "    Available:   ${SPOTIFY_LATEST_VER}"
echo -e "    Status:      ${SPOTIFY_STATUS}"
echo
echo -e "  ${BOLD}SpotX Ad-block & Feature Patch:${CLR}"
echo -e "    Status:      ${PATCH_STATUS_STR}"
echo

echo -e "${CYAN}============================================${CLR}"
echo -e "${CYAN}${BOLD}       Affected Components & Files          ${CLR}"
echo -e "${CYAN}============================================${CLR}"
echo -e "  ${BOLD}1. Host Scripts & Launchers:${CLR}"
echo -e "     • Directory: ~/.spotx-termux/"
echo -e "     • Files:     ~/start-spotify.sh"
echo -e "                  ~/update-spotify.sh"
echo -e "                  ~/doctor-spotify.sh"
echo -e "                  ~/control-spotify.sh"
echo -e "                  ~/.shortcuts/Spotify*"
echo -e "     • Commands:  \$PREFIX/bin/spotify*"
echo -e "     • Action:    Sync latest scripts from repo"
echo
echo -e "  ${BOLD}2. Spotify Desktop Client:${CLR}"
echo -e "     • Directory: /usr/share/spotify/"
echo -e "     • Source:    repository.spotify.com (.deb)"
echo -e "     • Action:    Download deb & unpack binary"
echo
echo -e "  ${BOLD}3. SpotX XPUI Patch:${CLR}"
echo -e "     • Target:    /usr/share/spotify/Apps/xpui.spa"
echo -e "     • Action:    Patch audio & unlock interface"
echo
echo -e "  ${BOLD}4. PRoot Container Environment:${CLR}"
echo -e "     • Config:    /root/.box64rc"
echo -e "     • Runner:    /usr/local/bin/spotify-termux"
echo -e "     • Action:    Verify audio/X11 runtime deps"
echo -e "${CYAN}============================================${CLR}"

# Calculate total pending changes
CHANGES_COUNT=0
[ "$HOST_UPDATE_AVAIL" = "1" ] && CHANGES_COUNT=$((CHANGES_COUNT + 1))
[ "$SPOTIFY_UPDATE_AVAIL" = "1" ] && CHANGES_COUNT=$((CHANGES_COUNT + 1))
if [ "$SPOTX_SKIP" = "0" ] && [ "$PATCH_UPDATE_AVAIL" = "1" ]; then
    CHANGES_COUNT=$((CHANGES_COUNT + 1))
fi

echo
echo -e "${BOLD}Update Plan for this run:${CLR}"
if [ "$SPOTX_FORCE" = "1" ]; then
    echo -e "  • ${YELLOW}Force mode active: all components will be re-downloaded & reinstalled.${CLR}"
elif [ "$SPOTX_ONLY" = "1" ]; then
    echo -e "  • ${CYAN}SpotX-only mode: re-applying SpotX patch to xpui.spa only.${CLR}"
elif [ "$SPOTX_SKIP" = "1" ]; then
    echo -e "  • ${CYAN}Skip-SpotX mode: updating client only without patch.${CLR}"
else
    if [ "$HOST_UPDATE_AVAIL" = "1" ]; then
        echo -e "  • Host Scripts:   ${YELLOW}Update available (→ v${SPOTX_TERMUX_LATEST_VERSION})${CLR}"
    else
        echo -e "  • Host Scripts:   ${GREEN}Up-to-date (no changes needed)${CLR}"
    fi

    if [ "$SPOTIFY_INSTALLED_VER" = "not installed" ]; then
        echo -e "  • Spotify Client: ${YELLOW}Fresh install (→ v${SPOTIFY_LATEST_VER})${CLR}"
    elif [ "$SPOTIFY_UPDATE_AVAIL" = "1" ]; then
        echo -e "  • Spotify Client: ${YELLOW}Update available (→ v${SPOTIFY_LATEST_VER})${CLR}"
    else
        echo -e "  • Spotify Client: ${GREEN}Up-to-date (download will be skipped)${CLR}"
    fi

    if [ "$PATCH_UPDATE_AVAIL" = "1" ]; then
        echo -e "  • SpotX Patch:    ${YELLOW}Will be applied/re-applied${CLR}"
    else
        echo -e "  • SpotX Patch:    ${GREEN}Already applied (patching will be skipped)${CLR}"
    fi

    if [ "$CHANGES_COUNT" = "0" ]; then
        echo
        success "All components are already up-to-date!"
        echo -e "  No modifications are required."
        echo -e "  Use ${BOLD}spotify-update --force${CLR} to reinstall anyway."
    fi
fi
echo

# If check-only mode requested, terminate cleanly without applying changes
if [ "$SPOTX_CHECK_ONLY" = "1" ]; then
    info "Check mode completed. No files were modified."
    info "To apply pending updates, run: spotify-update"
    exit 0
fi

# If all components are up-to-date and user didn't request --force, --spotx-only, or --skip-spotx,
# ensure wrappers exist, refresh shortcuts cleanly, and exit early
if [ "$SPOTX_FORCE" = "0" ] && [ "$SPOTX_ONLY" = "0" ] && [ "$SPOTX_SKIP" = "0" ] && [ "$CHANGES_COUNT" = "0" ]; then
    info "Refreshing host shortcuts and wrapper commands..."
    mkdir -p "$TERMUX_BIN" "${HOME}/.shortcuts"
    [ -f "${HOME}/start-spotify.sh" ] && cp "${HOME}/start-spotify.sh" "${HOME}/.shortcuts/Spotify" 2>/dev/null || true
    chmod +x "${HOME}/.shortcuts/Spotify" 2>/dev/null || true

    cat << 'STOP_CMD' > "${TERMUX_BIN}/spotify-stop"
#!/data/data/com.termux/files/usr/bin/bash
exec "$HOME/start-spotify.sh" --stop "$@"
STOP_CMD
    chmod +x "${TERMUX_BIN}/spotify-stop" 2>/dev/null || true

    cat << 'DOCTOR_CMD' > "${TERMUX_BIN}/spotify-doctor"
#!/data/data/com.termux/files/usr/bin/bash
exec "$HOME/doctor-spotify.sh" "$@"
DOCTOR_CMD
    chmod +x "${TERMUX_BIN}/spotify-doctor" 2>/dev/null || true

    cat << 'CONTROL_CMD' > "${TERMUX_BIN}/spotify-control"
#!/data/data/com.termux/files/usr/bin/bash
exec "$HOME/control-spotify.sh" "$@"
CONTROL_CMD
    chmod +x "${TERMUX_BIN}/spotify-control" 2>/dev/null || true

    success "System is verified and fully up-to-date."
    exit 0
fi

# Stage guest-setup.sh for container execution
GUEST_SETUP_LOCAL=""
if [ -n "$SCRIPT_DIR" ] && [ -f "${SCRIPT_DIR}/guest-setup.sh" ]; then
    GUEST_SETUP_LOCAL="${SCRIPT_DIR}/guest-setup.sh"
elif [ -n "$SCRIPT_DIR" ] && [ -f "${SCRIPT_DIR}/src/guest-setup.sh" ]; then
    GUEST_SETUP_LOCAL="${SCRIPT_DIR}/src/guest-setup.sh"
fi

REMOTE_REPO_RAW="https://raw.githubusercontent.com/CupoMeridio/spotx-termux/main/src/guest-setup.sh"

mkdir -p "$TERMUX_TMP"
CONTAINER_SETUP_STAGING="${TERMUX_TMP}/spotx-guest-setup.sh"

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

# Auto-detect and install any newly required host packages (e.g. termux-api, jq, etc.)
if [ "$IS_TERMUX" = true ] && command -v pkg >/dev/null 2>&1; then
    MISSING_HOST_PKGS=()
    command -v proot-distro >/dev/null 2>&1 || MISSING_HOST_PKGS+=("proot-distro")
    command -v pulseaudio >/dev/null 2>&1 || MISSING_HOST_PKGS+=("pulseaudio")
    command -v wget >/dev/null 2>&1 || MISSING_HOST_PKGS+=("wget")
    command -v curl >/dev/null 2>&1 || MISSING_HOST_PKGS+=("curl")
    command -v jq >/dev/null 2>&1 || MISSING_HOST_PKGS+=("jq")
    command -v termux-notification >/dev/null 2>&1 || MISSING_HOST_PKGS+=("termux-api")

    if [ ${#MISSING_HOST_PKGS[@]} -gt 0 ]; then
        info "Installing newly required host packages: ${MISSING_HOST_PKGS[*]}..."
        pkg install -y "${MISSING_HOST_PKGS[@]}" 2>/dev/null || warn "Failed to auto-install some host packages: ${MISSING_HOST_PKGS[*]}"
    fi
fi

# Ensure Termux allows external apps
mkdir -p "${HOME}/.termux"
if grep -q "^[[:space:]]*allow-external-apps" "${HOME}/.termux/termux.properties" 2>/dev/null; then
    sed -i 's/^[[:space:]]*allow-external-apps[[:space:]]*=.*/allow-external-apps = true/' "${HOME}/.termux/termux.properties"
else
    echo "allow-external-apps = true" >> "${HOME}/.termux/termux.properties"
fi
termux-reload-settings >/dev/null 2>&1 || true

# Helper function to refresh a host script from local repo or remote GitHub
# Uses an atomic rename (mv -f) to prevent self-modifying script buffer corruption
sync_host_script() {
    local local_rel="$1"
    local remote_rel="$2"
    local dest_file="$3"
    local local_file=""
    local tmp_file="${dest_file}.tmp.$$"

    # Prevent falsely identifying the installed $HOME directory as a local git repository.
    if [ "$SCRIPT_DIR" != "$HOME" ]; then
        if [ -n "$SCRIPT_DIR" ] && [ -f "${SCRIPT_DIR}/${local_rel}" ]; then
            local_file="${SCRIPT_DIR}/${local_rel}"
        elif [ -n "$SCRIPT_DIR" ] && [ -f "${SCRIPT_DIR}/src/${local_rel}" ]; then
            local_file="${SCRIPT_DIR}/src/${local_rel}"
        fi
    fi

    if [ -n "$local_file" ] && [ -f "$local_file" ]; then
        cp "$local_file" "$tmp_file"
    else
        curl -sSL "https://raw.githubusercontent.com/CupoMeridio/spotx-termux/main/${remote_rel}?t=$(date +%s)" -o "$tmp_file" 2>/dev/null || true
    fi

    if [ -s "$tmp_file" ]; then
        chmod +x "$tmp_file" 2>/dev/null || true
        mv -f "$tmp_file" "$dest_file"
    else
        rm -f "$tmp_file" 2>/dev/null || true
    fi
}

info "[1/3] Synchronizing host scripts and configuration..."
mkdir -p "${HOME}/.spotx-termux"
sync_host_script "common.sh" "src/common.sh" "${HOME}/.spotx-termux/common.sh"
sync_host_script "start-spotify.sh" "src/start-spotify.sh" "${HOME}/start-spotify.sh"
sync_host_script "update-spotify.sh" "src/update-spotify.sh" "${HOME}/update-spotify.sh"
sync_host_script "uninstall.sh" "uninstall.sh" "${HOME}/uninstall-spotify.sh"
sync_host_script "doctor.sh" "src/doctor.sh" "${HOME}/doctor-spotify.sh"
sync_host_script "control-spotify.sh" "src/control-spotify.sh" "${HOME}/control-spotify.sh"
sed -i '1s|.*|#!/data/data/com.termux/files/usr/bin/bash|' "${HOME}/control-spotify.sh" 2>/dev/null || true
chmod +x "${HOME}/control-spotify.sh" 2>/dev/null || true

# Update version marker file from local repo or GitHub remote
if [ -n "$SPOTX_TERMUX_LATEST_VERSION" ] && [ "$SPOTX_TERMUX_LATEST_VERSION" != "unknown" ]; then
    echo "$SPOTX_TERMUX_LATEST_VERSION" > "${HOME}/.spotx-termux-version"
    echo "$SPOTX_TERMUX_LATEST_VERSION" > "${HOME}/.spotx-termux/VERSION" 2>/dev/null || true
    SPOTX_TERMUX_VERSION="$SPOTX_TERMUX_LATEST_VERSION"
fi

# Ensure spotify-stop, spotify-doctor, and spotify-control wrappers exist in $BIN_DIR
mkdir -p "$TERMUX_BIN"
cat << 'STOP_CMD' > "${TERMUX_BIN}/spotify-stop"
#!/data/data/com.termux/files/usr/bin/bash
exec "$HOME/start-spotify.sh" --stop "$@"
STOP_CMD
chmod +x "${TERMUX_BIN}/spotify-stop"

cat << 'DOCTOR_CMD' > "${TERMUX_BIN}/spotify-doctor"
#!/data/data/com.termux/files/usr/bin/bash
exec "$HOME/doctor-spotify.sh" "$@"
DOCTOR_CMD
chmod +x "${TERMUX_BIN}/spotify-doctor"

cat << 'CONTROL_CMD' > "${TERMUX_BIN}/spotify-control"
#!/data/data/com.termux/files/usr/bin/bash
exec "$HOME/control-spotify.sh" "$@"
CONTROL_CMD
chmod +x "${TERMUX_BIN}/spotify-control"

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

# Terminate running Spotify, background media bridge, and PulseAudio processes to avoid conflicts
info "[2/3] Preparing PRoot environment and stopping active instances..."
pkill -x spotify 2>/dev/null || true
pkill -f "spotx-media.fifo" 2>/dev/null || true
if command -v termux-notification-remove >/dev/null 2>&1; then
    termux-notification-remove "spotx-player" 2>/dev/null || true
fi
if command -v pulseaudio >/dev/null 2>&1; then
    pulseaudio -k 2>/dev/null || true
fi
pkill -x pulseaudio 2>/dev/null || true
rm -f "${PREFIX:-/data/data/com.termux/files/usr}/tmp/pulse-socket" 2>/dev/null || true

# Run inside PRoot container with appropriate flags
info "[3/3] Updating Spotify and SpotX inside container '${CONTAINER_NAME}'..."
proot-distro login "$CONTAINER_NAME" --shared-tmp -- \
    env SPOTX_CHECK_ONLY="0" \
        SPOTX_ONLY="$SPOTX_ONLY" \
        SPOTX_SKIP="$SPOTX_SKIP" \
        SPOTX_FORCE="$SPOTX_FORCE" \
        SPOTX_TERMUX_VERSION="$SPOTX_TERMUX_VERSION" \
        SPOTX_TERMUX_LATEST_VERSION="$SPOTX_TERMUX_LATEST_VERSION" \
        bash /tmp/spotx-guest-setup.sh

success "Update process finished! Log saved to ${LOG_FILE}"
notify_user "SpotX-Termux" "Spotify update and SpotX patch completed successfully!" "check_circle"

