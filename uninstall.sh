#!/data/data/com.termux/files/usr/bin/bash
# ==============================================================================
# SpotX-Termux Uninstaller & Cleanup Tool
# Repository: https://github.com/CupoMeridio/spotx-termux
# ==============================================================================
set -euo pipefail

# ------------------------------------------------------------------------------
# Load SpotX-Termux Shared Library
# ------------------------------------------------------------------------------
# Sources, in order: repo checkout, installed copy, then a fresh bootstrap copy
# from GitHub (one-liner 'curl ... | bash', or an installed copy that is outdated).
_SPOTX_LIB=""
if [ -n "${BASH_SOURCE[0]:-}" ]; then
    _script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
    if [ -f "${_script_dir}/src/common.sh" ]; then
        _SPOTX_LIB="${_script_dir}/src/common.sh"
    fi
fi
if [ -z "$_SPOTX_LIB" ] && [ -f "${HOME}/.spotx-termux/common.sh" ]; then
    _SPOTX_LIB="${HOME}/.spotx-termux/common.sh"
fi
if [ -n "$_SPOTX_LIB" ]; then
    # shellcheck source=src/common.sh
    source "$_SPOTX_LIB"
fi
if [ "${SPOTX_LIB_API:-0}" -lt 2 ]; then
    _fresh_lib="${PREFIX:-/data/data/com.termux/files/usr}/tmp/spotx-common.uninstall.$$.sh"
    if curl -fsSL "https://raw.githubusercontent.com/CupoMeridio/spotx-termux/main/src/common.sh?t=$(date +%s)" -o "$_fresh_lib" 2>/dev/null \
        && [ "$(head -c 2 "$_fresh_lib" 2>/dev/null)" = "#!" ]; then
        # shellcheck source=src/common.sh
        source "$_fresh_lib"
        rm -f "$_fresh_lib"
    else
        rm -f "$_fresh_lib" 2>/dev/null || true
        echo "[X] Error: SpotX-Termux shared library not available (offline?)." >&2
        echo "    Connect to the internet and run the uninstaller again." >&2
        exit 1
    fi
    if [ "${SPOTX_LIB_API:-0}" -lt 2 ]; then
        echo "[X] Error: the SpotX-Termux library on GitHub is older than this uninstaller." >&2
        exit 1
    fi
fi
WHITE='\033[1;37m'

PREFIX_DIR="${PREFIX:-/data/data/com.termux/files/usr}"

# Flags
AUTO_YES=0
PURGE_PKGS=0
SELECTED_ACTION=""

show_banner() {
    setup_logging "uninstall.log"
    echo -e "${RED}${BOLD}============================================${CLR}"
    echo -e "${RED}${BOLD}     SpotX-Termux - Uninstaller Utility     ${CLR}"
    echo -e "${CYAN}     Version: ${SPOTX_TERMUX_VERSION}${CLR}"
    echo -e "${RED}${BOLD}============================================${CLR}\n"
}

show_help() {
    cat << EOF
SpotX-Termux Uninstaller & Cleanup Tool (v${SPOTX_TERMUX_VERSION})

Usage:
  spotify-uninstall [OPTIONS]
  bash uninstall.sh [OPTIONS]

Options:
  -f, --full            Full uninstallation (removes container, launchers, and shortcuts)
      --keep-ubuntu,
      --spotify-only    Remove Spotify, SpotX and configs inside Ubuntu, but keep the container
  -s, --spotx-only      Remove SpotX patch only (reverts to official unmodified Spotify client)
  -c, --clean-cache     Clean Spotify caches, temporary files, and apt cache to free space
  -l, --launchers-only  Remove only Termux launchers and shortcuts
  -p, --purge-pkgs      Also uninstall Termux companion packages (termux-x11, pulseaudio) during full removal
  -y, --yes             Automatic yes to confirmation prompts (non-interactive)
  -V, --version         Show version information
  -h, --help            Show this help message

Interactive Mode:
  Run without any options to display an interactive menu.

Examples:
  spotify-uninstall                 # Interactive cleanup menu
  spotify-uninstall --full          # Full uninstall with confirmation
  spotify-uninstall --full -y       # Full uninstall without confirmation
  spotify-uninstall --spotx-only    # Revert SpotX patch only
  spotify-uninstall --clean-cache   # Free disk space (cache cleanup)
EOF
}

# Read user input safely even when piped into bash (-y answers with the default, or 'y')
prompt_user() {
    local prompt_text="$1"
    local var_name="$2"
    local default_val="${3:-}"

    if [ "$AUTO_YES" -eq 1 ]; then
        printf -v "$var_name" '%s' "${default_val:-y}"
        return 0
    fi
    prompt_tty "$prompt_text" "$var_name" "$default_val"
}

confirm_action() {
    local question="$1"
    local default_ans="${2:-N}"

    if [ "$AUTO_YES" -eq 1 ]; then
        return 0
    fi

    local resp=""
    prompt_user "${question} [y/N]: " resp "$default_ans"
    case "$resp" in
        [yY]|[yY][eE][sS])
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}


kill_spotify_processes() {
    info "Terminating active Spotify, audio, and display processes..."
    stop_spotx_session
}

remove_launchers() {
    info "Removing Termux launchers, wrappers, and shortcuts..."
    # Built from the same tables install/update use, so nothing installed is forgotten.
    # ~/.spotx-termux (library + logs) is only removed by the full uninstall.
    local entry dest name files_to_remove=()
    for entry in "${SPOTX_WRAPPERS[@]}"; do
        files_to_remove+=("${TERMUX_BIN}/${entry%%|*}")
    done
    for entry in "${SPOTX_HOST_FILES[@]}"; do
        dest="${entry#*|}"
        [[ "$dest" == "${SPOTX_DIR}/"* ]] && continue
        files_to_remove+=("$dest")
    done
    for entry in "${SPOTX_SHORTCUTS[@]}"; do
        name="${entry%%|*}"
        files_to_remove+=("${SHORTCUTS_DIR}/${name}" "${SHORTCUTS_DIR}/icons/${name}.png")
    done
    files_to_remove+=("${HOME}/.spotx-termux-version")

    for file in "${files_to_remove[@]}"; do
        if [ -e "$file" ] || [ -L "$file" ]; then
            rm -f "$file"
            info "Removed: ${file}"
        fi
    done
    success "Termux launchers and shortcuts removed."
}

action_clean_cache() {
    info "Starting cache and temporary files cleanup..."
    kill_spotify_processes

    if is_container_installed "$CONTAINER_NAME"; then
        info "Cleaning Spotify user cache and APT packages inside Ubuntu..."
        proot-distro login "$CONTAINER_NAME" -- bash -c '
            rm -rf /root/.cache/spotify \
                   /home/*/.cache/spotify \
                   /tmp/* \
                   /var/tmp/* 2>/dev/null || true
            apt-get clean 2>/dev/null || true
        '
    else
        warn "PRoot container '${CONTAINER_NAME}' not found. Skipping container cache cleanup."
    fi

    # Host temp and log cleanup
    rm -rf "${TERMUX_TMP}/.X11-unix" "${TERMUX_TMP}/.X0-lock" 2>/dev/null || true
    if [ -d "$LOG_DIR" ]; then
        info "Cleaning old rotated logs in ${LOG_DIR}..."
        rm -f "${LOG_DIR}"/*.old 2>/dev/null || true
    fi
    success "Cache and temporary files successfully cleaned!"
    info "Cleanup log saved to ${LOG_FILE}"
}

action_revert_spotx() {
    info "Reverting SpotX patch (restoring official unmodified Spotify)..."
    if ! is_container_installed "$CONTAINER_NAME"; then
        error "Container '${CONTAINER_NAME}' is not installed. Nothing to revert."
        return 1
    fi

    kill_spotify_processes

    # SpotX-Bash backs up the client as Apps/xpui.bak + spotify.bak (both are needed:
    # it patches the binary too). Its own --uninstall is authoritative; the local
    # restore below mirrors it and is used when SpotX-Bash cannot be downloaded.
    info "Running SpotX uninstaller inside container..."
    if ! proot-distro login "$CONTAINER_NAME" -- bash -c '
        dir=/usr/share/spotify
        if [ ! -f "$dir/Apps/xpui.bak" ] || [ ! -f "$dir/spotify.bak" ]; then
            echo "[X] No SpotX backup found (Apps/xpui.bak + spotify.bak): nothing to restore." >&2
            exit 2
        fi
        tmp=$(mktemp)
        if curl -fsSL https://raw.githubusercontent.com/SpotX-Official/SpotX-Bash/main/spotx.sh -o "$tmp" 2>/dev/null \
            && [ "$(head -c 2 "$tmp")" = "#!" ] \
            && SPOTX_BUILD_MODE=1 bash "$tmp" --uninstall --noninteractive -P "$dir"; then
            rm -f "$tmp"
            exit 0
        fi
        rm -f "$tmp"
        echo "[*] Official uninstaller unavailable: restoring SpotX backups locally..."
        cp -f "$dir/spotify.bak" "$dir/spotify" && cp -f "$dir/Apps/xpui.bak" "$dir/Apps/xpui.spa" || exit 1
        rm -f "$dir/spotify.bak" "$dir/Apps/xpui.bak"
        rm -rf "$dir/Apps/xpui"
    '; then
        error "SpotX could not be reverted. To get a clean client, run: spotify-update --force --skip-spotx"
        return 1
    fi

    success "SpotX patch removed. Spotify restored to official stock state."
    info "Log saved to ${LOG_FILE}"
}

action_remove_spotify_only() {
    warn "This will remove Spotify, SpotX, and its configuration from the Ubuntu container."
    warn "The Ubuntu container itself will be PRESERVED for your other applications."
    if ! confirm_action "Are you sure you want to remove Spotify & SpotX?"; then
        info "Operation cancelled by user."
        return 0
    fi

    kill_spotify_processes

    if is_container_installed "$CONTAINER_NAME"; then
        info "Removing Spotify binaries and configs inside Ubuntu container..."
        proot-distro login "$CONTAINER_NAME" -- bash -c '
            rm -rf /usr/share/spotify \
                   /usr/bin/spotify \
                   /usr/local/bin/spotify-termux \
                   /usr/local/lib/spotx-termux \
                   /etc/apt/sources.list.d/spotify.list \
                   /etc/apt/trusted.gpg.d/spotify.gpg \
                   /root/.config/spotify \
                   /root/.cache/spotify \
                   /home/*/.config/spotify \
                   /home/*/.cache/spotify 2>/dev/null || true
            apt-get remove -y spotify-client 2>/dev/null || true
            apt-get autoremove -y 2>/dev/null || true
            apt-get clean 2>/dev/null || true
        '
    fi

    remove_launchers
    success "Spotify and SpotX removed. Ubuntu container is intact."
    info "Log saved to ${LOG_FILE}"
}

action_full_uninstall() {
    echo -e "${RED}${BOLD}============================================${CLR}"
    echo -e "${RED}${BOLD}        FULL UNINSTALLATION CONFIRM         ${CLR}"
    echo -e "${RED}${BOLD}============================================${CLR}"
    warn "This operation will completely remove:"
    echo -e "  - All running Spotify, PulseAudio, and Termux-X11 processes"
    echo -e "  - The entire PRoot container '${BOLD}${CONTAINER_NAME}${CLR}' (~1+ GB of storage freed)"
    echo -e "  - All Spotify commands (${BOLD}spotify${CLR}, ${BOLD}spotify-stop${CLR}, ${BOLD}spotify-update${CLR}, ${BOLD}spotify-doctor${CLR}, ${BOLD}spotify-uninstall${CLR})"
    echo -e "  - Home screen widget shortcuts (${BOLD}Spotify${CLR}, ${BOLD}Spotify-Stop${CLR})"
    echo

    if ! confirm_action "Do you want to proceed with FULL removal?"; then
        info "Operation cancelled by user."
        return 0
    fi

    kill_spotify_processes

    # 1. Remove Ubuntu container
    if is_container_installed "$CONTAINER_NAME"; then
        info "Removing PRoot container '${CONTAINER_NAME}' via proot-distro..."
        if command -v proot-distro >/dev/null 2>&1; then
            proot-distro remove "$CONTAINER_NAME" || {
                warn "proot-distro remove failed. Attempting manual directory cleanup..."
                rm -rf "${PREFIX_DIR}/var/lib/proot-distro/containers/${CONTAINER_NAME}" 2>/dev/null || true
                rm -rf "${PREFIX_DIR}/var/lib/proot-distro/installed-rootfs/${CONTAINER_NAME}" 2>/dev/null || true
            }
        fi
        success "PRoot container '${CONTAINER_NAME}' removed."
    else
        info "PRoot container '${CONTAINER_NAME}' not found."
    fi

    # 2. Optional: purge Termux companion packages if requested
    local do_purge_pkgs=0
    if [ "$PURGE_PKGS" -eq 1 ]; then
        do_purge_pkgs=1
    elif [ "$AUTO_YES" -eq 0 ]; then
        echo
        if confirm_action "Do you also want to uninstall Termux packages (termux-x11-nightly, pulseaudio)?"; then
            do_purge_pkgs=1
        fi
    fi

    if [ "$do_purge_pkgs" -eq 1 ]; then
        info "Uninstalling Termux companion packages..."
        pkg uninstall -y termux-x11-nightly pulseaudio 2>/dev/null || true
        success "Termux packages uninstalled."
    else
        info "Keeping Termux packages intact (may be used by other tools)."
    fi

    # 3. Remove launchers and shortcuts
    remove_launchers

    # 4. Remove .spotx-termux directory
    if [ -d "${HOME}/.spotx-termux" ]; then
        rm -rf "${HOME}/.spotx-termux" 2>/dev/null || true
        info "Removed: ${HOME}/.spotx-termux directory"
    fi

    echo
    echo -e "${GREEN}${BOLD}============================================${CLR}"
    echo -e "${GREEN}${BOLD}    Full Uninstallation Completed!          ${CLR}"
    echo -e "${GREEN}${BOLD}============================================${CLR}"
    echo -e "${WHITE}All SpotX-Termux files and containers have been removed.${CLR}\n"
}

show_interactive_menu() {
    show_banner
    echo -e "${WHITE}${BOLD}Select a cleanup option:${CLR}\n"
    echo -e "  ${GREEN}${BOLD}1)${CLR} ${BOLD}Full Uninstallation${CLR} ${YELLOW}[Recommended]${CLR}"
    echo -e "     - Deletes Ubuntu container (~1+ GB freed)"
    echo -e "     - Removes commands & widget shortcuts"
    echo
    echo -e "  ${CYAN}${BOLD}2)${CLR} ${BOLD}Remove Spotify & SpotX only${CLR}"
    echo -e "     - Removes Spotify, SpotX & caches"
    echo -e "     - Keeps Ubuntu container intact"
    echo
    echo -e "  ${CYAN}${BOLD}3)${CLR} ${BOLD}Revert SpotX patch only${CLR}"
    echo -e "     - Restores unmodified official Spotify"
    echo
    echo -e "  ${CYAN}${BOLD}4)${CLR} ${BOLD}Clean Cache & Temporary Files${CLR}"
    echo -e "     - Frees disk space without uninstalling"
    echo
    echo -e "  ${CYAN}${BOLD}5)${CLR} ${BOLD}Remove Launchers & Shortcuts only${CLR}"
    echo -e "     - Removes bin wrappers and widgets"
    echo
    echo -e "  ${RED}${BOLD}0)${CLR} Cancel / Exit without changes"
    echo

    local choice=""
    prompt_user "Enter choice [0-5]: " choice "0"

    case "$choice" in
        1)
            action_full_uninstall
            ;;
        2)
            action_remove_spotify_only
            ;;
        3)
            action_revert_spotx
            ;;
        4)
            action_clean_cache
            ;;
        5)
            kill_spotify_processes
            remove_launchers
            ;;
        0|q|Q)
            info "No changes made. Exiting."
            exit 0
            ;;
        *)
            error "Invalid choice: '$choice'"
            exit 1
            ;;
    esac
}

# Parse CLI arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -f|--full)
            SELECTED_ACTION="full"
            shift
            ;;
        --keep-ubuntu|--spotify-only)
            SELECTED_ACTION="spotify-only"
            shift
            ;;
        -s|--spotx-only)
            SELECTED_ACTION="spotx-only"
            shift
            ;;
        -c|--clean-cache)
            SELECTED_ACTION="clean-cache"
            shift
            ;;
        -l|--launchers-only)
            SELECTED_ACTION="launchers-only"
            shift
            ;;
        -p|--purge-pkgs)
            PURGE_PKGS=1
            shift
            ;;
        -y|--yes)
            AUTO_YES=1
            shift
            ;;
        -V|--version)
            echo "SpotX-Termux ${SPOTX_TERMUX_VERSION}"
            exit 0
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Main entry point
if [ -n "$SELECTED_ACTION" ]; then
    show_banner
    case "$SELECTED_ACTION" in
        full)
            action_full_uninstall
            ;;
        spotify-only)
            action_remove_spotify_only
            ;;
        spotx-only)
            action_revert_spotx
            ;;
        clean-cache)
            action_clean_cache
            ;;
        launchers-only)
            kill_spotify_processes
            remove_launchers
            ;;
    esac
else
    show_interactive_menu
fi
