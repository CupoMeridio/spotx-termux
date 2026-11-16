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
if [ -n "${BASH_SOURCE[0]:-}" ]; then
    _script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
    if [ -f "${_script_dir}/common.sh" ]; then
        _SPOTX_LIB="${_script_dir}/common.sh"
    elif [ -f "${_script_dir}/src/common.sh" ]; then
        _SPOTX_LIB="${_script_dir}/src/common.sh"
    fi
fi
if [ -z "$_SPOTX_LIB" ] && [ -f "${HOME}/.spotx-termux/common.sh" ]; then
    _SPOTX_LIB="${HOME}/.spotx-termux/common.sh"
fi
if [ -n "$_SPOTX_LIB" ] && [ -f "$_SPOTX_LIB" ]; then
    # shellcheck source=/dev/null
    source "$_SPOTX_LIB"
fi

# Self-repair: the updater is the tool users run to fix their installation, so it
# must also work when the installed library is missing or older than this script
# (e.g. a previous update replaced the scripts but not common.sh). In that case
# load a fresh copy of the library from the repository for this run.
if [ "${SPOTX_LIB_API:-0}" -lt 4 ]; then
    _fresh_lib="${PREFIX:-/data/data/com.termux/files/usr}/tmp/spotx-common.update.$$.sh"
    if curl -fsSL "https://raw.githubusercontent.com/CupoMeridio/spotx-termux/main/src/common.sh?t=$(date +%s)" -o "$_fresh_lib" 2>/dev/null \
        && [ "$(head -c 2 "$_fresh_lib" 2>/dev/null)" = "#!" ]; then
        # shellcheck source=/dev/null
        source "$_fresh_lib"
        rm -f "$_fresh_lib"
    else
        rm -f "$_fresh_lib" 2>/dev/null || true
        echo "[X] Error: SpotX-Termux shared library is missing or outdated, and a fresh" >&2
        echo "    copy could not be downloaded. Check your connection and retry." >&2
        exit 1
    fi
    if [ "${SPOTX_LIB_API:-0}" -lt 4 ]; then
        echo "[X] Error: the SpotX-Termux library on GitHub is older than this updater." >&2
        exit 1
    fi
fi

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
            elif [ -n "$SPOTX_REPO_ROOT" ]; then
                exec bash "${SPOTX_REPO_ROOT}/src/doctor.sh" "$@"
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

# Helper: latest SpotX-Termux script version (local checkout when running from one, else GitHub)
get_latest_spotx_version() {
    local ver=""
    if [ -n "$SPOTX_REPO_ROOT" ] && [ -f "${SPOTX_REPO_ROOT}/VERSION" ]; then
        ver=$(tr -d '[:space:]' < "${SPOTX_REPO_ROOT}/VERSION" 2>/dev/null || true)
    else
        ver=$(curl -fsSL --connect-timeout 2 --max-time 4 "${SPOTX_REPO_RAW}/VERSION?t=$(date +%s)" 2>/dev/null | tr -d '[:space:]' || true)
    fi
    # Reject anything that is not CalVer (e.g. an error body like "404:NotFound")
    is_valid_version "$ver" || ver=""
    echo "${ver:-unknown}"
}

# Helper: fetch latest Spotify client version from Debian repository metadata
get_latest_spotify_version() {
    local ver=""
    ver=$(curl -fsSL --connect-timeout 3 --max-time 6 https://repository.spotify.com/dists/stable/non-free/binary-amd64/Packages 2>/dev/null | \
        awk '/^Package: spotify-client$/{p=1} p && /^Version:/{print $2; exit}' || true)
    echo "${ver:-unknown}"
}

echo -e "${CYAN}============================================${CLR}"
echo -e "${CYAN}${BOLD}     SpotX-Termux - Updater Utility         ${CLR}"
echo -e "${CYAN}============================================${CLR}"

info "Checking component versions..."

SPOTX_TERMUX_LATEST_VERSION="$(get_latest_spotx_version)"
# Container state comes from the guest probe: single source of truth, one PRoot login
if ! probe_container; then
    warn "Could not inspect the container; Spotify will be treated as not installed."
fi
if [ -n "$GUEST_VER" ]; then
    SPOTIFY_INSTALLED_VER="$GUEST_VER"
elif [ "$GUEST_ELF" = "valid_elf" ] || [ "$GUEST_ELF" = "corrupted" ]; then
    SPOTIFY_INSTALLED_VER="installed (unversioned)"
else
    SPOTIFY_INSTALLED_VER="not installed"
fi
case "$GUEST_SPOTX" in
    applied)               SPOTX_PATCH_STATUS="applied" ;;
    not_applied|unknown)   SPOTX_PATCH_STATUS="not_applied" ;;
    *)                     SPOTX_PATCH_STATUS="missing" ;;
esac
SPOTIFY_LATEST_VER="$(get_latest_spotify_version)"

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
elif [ "$GUEST_ELF" = "corrupted" ]; then
    # Same version but a broken binary: without this the updater would report
    # "up-to-date" and never repair it (guest-setup re-downloads on a non-ELF binary)
    SPOTIFY_STATUS="${RED}${BOLD}Corrupted binary (will be re-downloaded)${CLR}"
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
# ensure wrappers and shortcuts exist, then exit early
if [ "$SPOTX_FORCE" = "0" ] && [ "$SPOTX_ONLY" = "0" ] && [ "$SPOTX_SKIP" = "0" ] && [ "$CHANGES_COUNT" = "0" ]; then
    info "Refreshing host shortcuts and wrapper commands..."
    install_wrappers
    install_widget_shortcuts
    success "System is verified and fully up-to-date."
    exit 0
fi

# Stage the guest bundle (guest-setup.sh + src/guest/*) for the container, through the shared /tmp
trap remove_guest_bundle EXIT

info "Fetching guest setup script..."
if ! stage_guest_bundle; then
    error "Could not obtain a valid guest setup script (network or GitHub error)."
    error "No changes were made. Please retry later: spotify-update"
    exit 1
fi

# Auto-detect and install any newly required host packages (e.g. termux-api)
if [ "$IS_TERMUX" = true ] && command -v pkg >/dev/null 2>&1; then
    read -r -a MISSING_HOST_PKGS <<< "$(missing_pkgs "${SPOTX_CORE_PKGS[@]}" "${SPOTX_OPTIONAL_PKGS[@]}")"
    if [ ${#MISSING_HOST_PKGS[@]} -gt 0 ]; then
        info "Installing newly required host packages: ${MISSING_HOST_PKGS[*]}..."
        pkg install -y "${MISSING_HOST_PKGS[@]}" 2>/dev/null || warn "Failed to auto-install some host packages: ${MISSING_HOST_PKGS[*]}"
    fi
fi

ensure_allow_external_apps

info "[1/3] Synchronizing host scripts and configuration..."
if sync_host_scripts; then
    # Scripts and version marker move together, so the marker never claims a
    # version whose scripts were not actually installed
    if [ "$SPOTX_TERMUX_LATEST_VERSION" != "unknown" ]; then
        write_version_markers "$SPOTX_TERMUX_LATEST_VERSION"
        SPOTX_TERMUX_VERSION="$SPOTX_TERMUX_LATEST_VERSION"
    fi
else
    warn "Continuing with the currently installed host scripts."
fi
install_wrappers
install_widget_shortcuts

# Terminate the running session (Spotify, media bridge, display, audio) to avoid conflicts
info "[2/3] Preparing PRoot environment and stopping active instances..."
stop_spotx_session

# Run inside PRoot container with appropriate flags
info "[3/3] Updating Spotify and SpotX inside container '${CONTAINER_NAME}'..."
proot-distro login "$CONTAINER_NAME" --shared-tmp -- \
    env SPOTX_ONLY="$SPOTX_ONLY" \
        SPOTX_SKIP="$SPOTX_SKIP" \
        SPOTX_FORCE="$SPOTX_FORCE" \
        SPOTX_TERMUX_VERSION="$SPOTX_TERMUX_VERSION" \
        bash "$GUEST_STAGING_IN_CONTAINER"

success "Update process finished! Log saved to ${LOG_FILE}"
notify_user "SpotX-Termux" "Spotify update and SpotX patch completed successfully!" "check_circle"
