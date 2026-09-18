#!/usr/bin/env bash
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

echo -e "${CYAN}======================================================${CLR}"
echo -e "${CYAN}${BOLD}   SpotX Termux - Updater Orchestrator               ${CLR}"
echo -e "${CYAN}   Version: ${SPOTX_TERMUX_VERSION}                              ${CLR}"
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

    info "Synchronizing host scripts and configuration..."
    mkdir -p "${HOME}/.spotx-termux"
    sync_host_script "common.sh" "src/common.sh" "${HOME}/.spotx-termux/common.sh"
    sync_host_script "start-spotify.sh" "src/start-spotify.sh" "${HOME}/start-spotify.sh"
    sync_host_script "update-spotify.sh" "src/update-spotify.sh" "${HOME}/update-spotify.sh"
    sync_host_script "uninstall.sh" "uninstall.sh" "${HOME}/uninstall-spotify.sh"
    sync_host_script "doctor.sh" "src/doctor.sh" "${HOME}/doctor-spotify.sh"
    sync_host_script "control-spotify.sh" "src/control-spotify.sh" "${HOME}/control-spotify.sh"

    # Update version marker file from local repo or GitHub remote
    NEW_SPOTX_VER=""
    if [ "$SCRIPT_DIR" != "$HOME" ] && [ -n "$SCRIPT_DIR" ]; then
        if [ -f "${SCRIPT_DIR}/../VERSION" ]; then
            NEW_SPOTX_VER=$(cat "${SCRIPT_DIR}/../VERSION" 2>/dev/null | tr -d '[:space:]')
        elif [ -f "${SCRIPT_DIR}/VERSION" ]; then
            NEW_SPOTX_VER=$(cat "${SCRIPT_DIR}/VERSION" 2>/dev/null | tr -d '[:space:]')
        fi
    fi
    if [ -z "$NEW_SPOTX_VER" ]; then
        NEW_SPOTX_VER=$(curl -sSL --connect-timeout 3 --max-time 5 "https://raw.githubusercontent.com/CupoMeridio/spotx-termux/main/VERSION?t=$(date +%s)" 2>/dev/null | tr -d '[:space:]' || true)
    fi
    if [ -n "$NEW_SPOTX_VER" ]; then
        echo "$NEW_SPOTX_VER" > "${HOME}/.spotx-termux-version"
        SPOTX_TERMUX_VERSION="$NEW_SPOTX_VER"
    fi

    # Ensure spotify-stop and spotify-doctor wrappers exist in $BIN_DIR
    HOST_BIN_DIR="${PREFIX:-/data/data/com.termux/files/usr}/bin"
    mkdir -p "$HOST_BIN_DIR"
    cat << 'STOP_CMD' > "${HOST_BIN_DIR}/spotify-stop"
#!/usr/bin/env bash
exec "$HOME/start-spotify.sh" --stop "$@"
STOP_CMD
    chmod +x "${HOST_BIN_DIR}/spotify-stop"

    cat << 'DOCTOR_CMD' > "${HOST_BIN_DIR}/spotify-doctor"
#!/usr/bin/env bash
exec "$HOME/doctor-spotify.sh" "$@"
DOCTOR_CMD
    chmod +x "${HOST_BIN_DIR}/spotify-doctor"

    cat << 'CONTROL_CMD' > "${HOST_BIN_DIR}/spotify-control"
#!/usr/bin/env bash
exec "$HOME/control-spotify.sh" "$@"
CONTROL_CMD
    chmod +x "${HOST_BIN_DIR}/spotify-control"

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
fi

# In check mode, query the latest available SpotX-Termux script version
SPOTX_TERMUX_LATEST_VERSION=""
if [ "$SPOTX_CHECK_ONLY" = "1" ]; then
    if [ "$SCRIPT_DIR" != "$HOME" ] && [ -n "$SCRIPT_DIR" ]; then
        if [ -f "${SCRIPT_DIR}/../VERSION" ]; then
            SPOTX_TERMUX_LATEST_VERSION=$(cat "${SCRIPT_DIR}/../VERSION" 2>/dev/null | tr -d '[:space:]')
        elif [ -f "${SCRIPT_DIR}/VERSION" ]; then
            SPOTX_TERMUX_LATEST_VERSION=$(cat "${SCRIPT_DIR}/VERSION" 2>/dev/null | tr -d '[:space:]')
        fi
    fi
    if [ -z "$SPOTX_TERMUX_LATEST_VERSION" ]; then
        SPOTX_TERMUX_LATEST_VERSION=$(curl -sSL --connect-timeout 3 --max-time 5 "https://raw.githubusercontent.com/CupoMeridio/spotx-termux/main/VERSION?t=$(date +%s)" 2>/dev/null | tr -d '[:space:]' || true)
    fi
fi

# Run inside PRoot container with appropriate flags
info "Running update inside container '${CONTAINER_NAME}'..."
proot-distro login "$CONTAINER_NAME" --shared-tmp -- \
    env SPOTX_CHECK_ONLY="$SPOTX_CHECK_ONLY" \
        SPOTX_ONLY="$SPOTX_ONLY" \
        SPOTX_SKIP="$SPOTX_SKIP" \
        SPOTX_FORCE="$SPOTX_FORCE" \
        SPOTX_TERMUX_VERSION="$SPOTX_TERMUX_VERSION" \
        SPOTX_TERMUX_LATEST_VERSION="$SPOTX_TERMUX_LATEST_VERSION" \
        bash /tmp/spotx-guest-setup.sh

if [ "$SPOTX_CHECK_ONLY" = "0" ]; then
    success "Update process finished! Log saved to ${LOG_FILE}"
    notify_user "SpotX-Termux" "Spotify update and SpotX patch completed successfully!" "check_circle"
else
    info "Check completed. Log saved to ${LOG_FILE}"
fi

