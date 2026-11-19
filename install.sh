#!/data/data/com.termux/files/usr/bin/bash
# ==============================================================================
# SpotX-Termux: Automated installer for Spotify + SpotX on Android via Termux
# Repository: https://github.com/CupoMeridio/spotx-termux
# ==============================================================================
set -euo pipefail

# ------------------------------------------------------------------------------
# Load SpotX-Termux Shared Library (local repo checkout, or remote bootstrap copy
# when run as 'curl ... | bash')
# ------------------------------------------------------------------------------
_SPOTX_LIB=""
if [ -n "${BASH_SOURCE[0]:-}" ]; then
    _script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
    if [ -f "${_script_dir}/src/common.sh" ]; then
        _SPOTX_LIB="${_script_dir}/src/common.sh"
    fi
fi
if [ -z "$_SPOTX_LIB" ]; then
    _bootstrap_dir="${PREFIX:-/data/data/com.termux/files/usr}/tmp"
    _bootstrap_raw="https://raw.githubusercontent.com/CupoMeridio/spotx-termux/main"
    mkdir -p "$_bootstrap_dir" 2>/dev/null || true
    _SPOTX_LIB="${_bootstrap_dir}/spotx-common.sh"
    rm -f "$_SPOTX_LIB" "${_bootstrap_dir}/VERSION" 2>/dev/null || true
    # -f: never save an HTTP error page as the library. Validation can't use common.sh yet.
    if ! curl -fsSL "${_bootstrap_raw}/src/common.sh?t=$(date +%s)" -o "$_SPOTX_LIB" 2>/dev/null \
        || [ "$(head -c 2 "$_SPOTX_LIB" 2>/dev/null)" != "#!" ]; then
        rm -f "$_SPOTX_LIB" 2>/dev/null || true
    fi
    # VERSION next to the bootstrap library is what resolve_spotx_version reads first
    curl -fsSL "${_bootstrap_raw}/VERSION?t=$(date +%s)" -o "${_bootstrap_dir}/VERSION" 2>/dev/null \
        || rm -f "${_bootstrap_dir}/VERSION" 2>/dev/null || true
fi
# Offline fallback: the installed library is enough for --uninstall / --doctor. It is
# used only when the download failed: an installation always needs the fresh copy.
_SPOTX_LIB_OFFLINE=0
if [ ! -f "$_SPOTX_LIB" ] && [ -f "${HOME:-/data/data/com.termux/files/home}/.spotx-termux/common.sh" ]; then
    _SPOTX_LIB="${HOME:-/data/data/com.termux/files/home}/.spotx-termux/common.sh"
    _SPOTX_LIB_OFFLINE=1
fi

if [ -f "$_SPOTX_LIB" ]; then
    # shellcheck source=src/common.sh
    source "$_SPOTX_LIB"
else
    echo "[X] Error: Could not load SpotX-Termux core library (network or GitHub error)." >&2
    exit 1
fi

# ------------------------------------------------------------------------------
# Sub-command delegation & informational flags
# ------------------------------------------------------------------------------
if [ "${1:-}" = "--uninstall" ] || [ "${1:-}" = "-u" ]; then
    shift
    # Same order as --doctor: repo checkout, installed copy (works offline), GitHub
    if [ -n "$SPOTX_REPO_ROOT" ]; then
        exec bash "${SPOTX_REPO_ROOT}/uninstall.sh" "$@"
    elif [ -f "${HOME}/uninstall-spotify.sh" ]; then
        exec bash "${HOME}/uninstall-spotify.sh" "$@"
    else
        exec bash <(curl -fsSL "${SPOTX_REPO_RAW}/uninstall.sh?t=$(date +%s)") "$@"
    fi
fi

if [ "${1:-}" = "--doctor" ] || [ "${1:-}" = "-d" ] || [ "${1:-}" = "doctor" ]; then
    shift
    if [ -n "$SPOTX_REPO_ROOT" ]; then
        exec bash "${SPOTX_REPO_ROOT}/src/doctor.sh" "$@"
    elif [ -f "${HOME}/doctor-spotify.sh" ]; then
        exec "$HOME/doctor-spotify.sh" "$@"
    else
        exec bash -c "$(curl -fsSL "${SPOTX_REPO_RAW}/src/doctor.sh")" bash "$@"
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

if [ "$_SPOTX_LIB_OFFLINE" = "1" ] || [ "${SPOTX_LIB_API:-0}" -lt 6 ]; then
    echo "[X] Error: Could not download the SpotX-Termux core library (network or GitHub error)." >&2
    echo "    Check your connection and run the installer again." >&2
    exit 1
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
setup_logging "install.log"

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

# ------------------------------------------------------------------------------
# 0. Fetch every project file now, right after the library and VERSION: the setup
# takes minutes, and fetching later could mix files from different pushes to main.
# Staged files are installed at the end (guest bundle in step 4, host scripts in 5).
# ------------------------------------------------------------------------------
info "Downloading SpotX-Termux scripts..."
cleanup_staged_files() {
    remove_guest_bundle
    discard_staged_host_scripts
}
trap cleanup_staged_files EXIT
if ! stage_guest_bundle || ! stage_host_scripts; then
    error "Could not download the SpotX-Termux scripts (network or GitHub error)."
    error "Nothing was changed. Please check your connection and run the installer again."
    exit 1
fi

# ------------------------------------------------------------------------------
# 1. Environment & storage checks
# ------------------------------------------------------------------------------
info "Detected architecture: ${ARCH}"

if [ "$IS_TERMUX" = false ]; then
    warn "This installer is designed for Termux on Android."
    warn "You are currently running on a standard Linux host (${ARCH})."
    RESP=""
    prompt_tty "Do you want to proceed with a dry-run / container test? [y/N]: " RESP "N"
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
            # Interactive: an empty answer aborts. Unattended (no terminal): proceed.
            local resp="y"
            if has_tty; then
                prompt_tty "Do you want to proceed anyway? [y/N]: " resp "N"
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

# ------------------------------------------------------------------------------
# 2. Termux repositories, host dependencies and host configuration
# ------------------------------------------------------------------------------
if [ "$IS_TERMUX" = true ]; then
    info "Enabling Termux X11 repository..."
    pkg install -y x11-repo || {
        warn "Could not install x11-repo directly, trying update first..."
    }

    info "Updating Termux package lists..."
    pkg update -y || {
        warn "pkg update returned a warning. Continuing..."
    }

    HOST_PKGS=()
    for entry in "${SPOTX_CORE_PKGS[@]}" "${SPOTX_OPTIONAL_PKGS[@]}"; do
        HOST_PKGS+=("${entry%%|*}")
    done
    info "Installing required Termux packages (${HOST_PKGS[*]})..."
    pkg install -y "${HOST_PKGS[@]}"

    info "Installing Termux-X11 companion package..."
    pkg install -y termux-x11-nightly || {
        warn "Could not install termux-x11-nightly from repository."
        warn "Please ensure x11-repo is enabled or install termux-x11 companion manually."
    }

    ensure_allow_external_apps
    write_pulse_config
fi

# ------------------------------------------------------------------------------
# 3. Ubuntu container via proot-distro
# ------------------------------------------------------------------------------
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

# ------------------------------------------------------------------------------
# 4. Run guest-setup.sh inside the container (staged through the shared /tmp)
# ------------------------------------------------------------------------------
info "Configuring container environment, dependencies, Box64, Spotify, and SpotX..."
proot-distro login "$CONTAINER_NAME" --shared-tmp -- \
    env SPOTX_FORCE="$SPOTX_FORCE" \
        SPOTX_TERMUX_VERSION="$SPOTX_TERMUX_VERSION" \
        bash "$GUEST_STAGING_IN_CONTAINER"
remove_guest_bundle

# ------------------------------------------------------------------------------
# 5. Host scripts, command wrappers and Termux:Widget shortcuts
# ------------------------------------------------------------------------------
info "Installing launcher scripts on Termux..."
if ! install_staged_host_scripts; then
    error "Host scripts could not be installed. The container is ready:"
    error "re-run the installer (it will be quick)."
    exit 1
fi
install_wrappers

info "Creating Termux:Widget shortcuts..."
install_widget_shortcuts
success "Termux:Widget shortcuts created: 'Spotify' and 'Spotify-Stop'"

# Version marker for runtime version detection of the installed scripts
write_version_markers "$SPOTX_TERMUX_VERSION"

# Send system notification on completion if termux-api is available
notify_user "SpotX-Termux" "Installation completed successfully! Launch Spotify with 'spotify'." "check_circle"

# ------------------------------------------------------------------------------
# 6. Summary and Instructions
# ------------------------------------------------------------------------------
echo
echo -e "${GREEN}${BOLD}============================================${CLR}"
echo -e "${GREEN}${BOLD}    Installation Completed Successfully!    ${CLR}"
echo -e "${GREEN}${BOLD}============================================${CLR}"
echo
echo -e "${CYAN}How to manage Spotify SpotX:${CLR}"
echo -e "  1. Install ${BOLD}Termux-X11 APK${CLR} on Android"
echo -e "     (github.com/termux/termux-x11/releases)"
echo -e "  2. Quick commands in Termux:"
echo -e "     ${BOLD}${GREEN}spotify${CLR}           - Launch Spotify SpotX"
echo -e "     ${BOLD}${GREEN}spotify-stop${CLR}      - Stop all processes"
echo -e "     ${BOLD}${GREEN}spotify-control${CLR}   - Media controls"
echo -e "     ${BOLD}${GREEN}spotify-update${CLR}    - Update Spotify/SpotX"
echo -e "     ${BOLD}${GREEN}spotify-doctor${CLR}    - Health check tool"
echo -e "     ${BOLD}${GREEN}spotify-uninstall${CLR} - Cleanup/uninstall"
echo -e "  3. Home screen shortcuts via Termux:Widget"
echo
echo -e "${YELLOW}Tips for the best experience:${CLR}"
echo -e "  * Set Battery to 'Unrestricted' for:"
echo -e "    ${BOLD}Termux${CLR}, ${BOLD}Termux-X11${CLR}, and ${BOLD}Termux:API${CLR}."
echo -e "  * In Termux-X11 preferences, enable"
echo -e "    fullscreen and Touchpad mouse mode."
echo -e "  * Log: ${BOLD}${CYAN}${LOG_FILE}${CLR}"
echo
