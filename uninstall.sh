#!/usr/bin/env bash
# ==============================================================================
# SpotX-Termux Uninstaller & Cleanup Tool
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
WHITE='\033[1;37m'

info()    { echo -e "${CYAN}${BOLD}[*]${CLR} $*"; }
success() { echo -e "${GREEN}${BOLD}[✔]${CLR} $*"; }
warn()    { echo -e "${YELLOW}${BOLD}[!]${CLR} $*"; }
error()   { echo -e "${RED}${BOLD}[✘]${CLR} $*" >&2; }

CONTAINER_NAME="ubuntu"
PREFIX_DIR="${PREFIX:-/data/data/com.termux/files/usr}"
BIN_DIR="${PREFIX_DIR}/bin"
TMP_DIR="${PREFIX_DIR}/tmp"
SHORTCUTS_DIR="${HOME}/.shortcuts"

# Flags
AUTO_YES=0
PURGE_PKGS=0
SELECTED_ACTION=""

show_banner() {
    echo -e "${RED}${BOLD}"
    echo "  ____             _  __  __   _   _       _           _        _ _ "
    echo " / ___| _ __   ___| |_\ \/ /  | | | |_ __ (_)_ __  ___| |_ __ _| | |"
    echo " \___ \| '_ \ / _ \ __/\  /___| | | | '_ \| | '_ \/ __| __/ _\` | | |"
    echo "  ___) | |_) | (_) | |_/  \___| |_| | | | | | | | \__ \ || (_| | | |"
    echo " |____/| .__/ \___/ \__/_/\_\  \___/|_| |_|_|_| |_|___/\__\__,_|_|_|"
    echo "       |_|                                                          "
    echo -e "${CLR}"
    echo -e "${CYAN}SpotX-Termux - Modular Uninstaller & Cleanup Utility${CLR}"
    echo -e "${CYAN}----------------------------------------------------${CLR}\n"
}

show_help() {
    cat << EOF
SpotX-Termux Uninstaller & Cleanup Tool

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

# Read user input safely even when piped into bash
prompt_user() {
    local prompt_text="$1"
    local var_name="$2"
    local default_val="${3:-}"

    if [ "$AUTO_YES" -eq 1 ]; then
        eval "$var_name=\"${default_val:-y}\""
        return 0
    fi

    local reply=""
    if [ -t 0 ]; then
        read -rp "$prompt_text" reply
    elif [ -e /dev/tty ]; then
        read -rp "$prompt_text" reply < /dev/tty
    else
        # Non-interactive without tty and without -y: use default
        reply="$default_val"
    fi

    if [ -z "$reply" ]; then
        reply="$default_val"
    fi
    eval "$var_name=\"$reply\""
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

is_container_installed() {
    local name="$1"
    if [ -d "${PREFIX_DIR}/var/lib/proot-distro/containers/${name}" ] || \
       [ -d "${PREFIX_DIR}/var/lib/proot-distro/installed-rootfs/${name}" ] || \
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

kill_spotify_processes() {
    info "Terminating active Spotify, audio, and display processes..."
    # Terminate inside container if running
    if is_container_installed "$CONTAINER_NAME"; then
        proot-distro login "$CONTAINER_NAME" -- pkill -f spotify 2>/dev/null || true
    fi

    # Terminate host audio / X11
    pkill -f "termux.x11" 2>/dev/null || true
    pkill -f "termux-x11" 2>/dev/null || true
    if command -v pulseaudio >/dev/null 2>&1; then
        pulseaudio -k 2>/dev/null || true
    fi
    pkill -f "pulseaudio" 2>/dev/null || true

    # Clean temporary sockets and lock files
    rm -rf "${TMP_DIR}/.X11-unix" "${TMP_DIR}/.X0-lock" 2>/dev/null || true
}

remove_launchers() {
    info "Removing Termux launchers, wrappers, and shortcuts..."
    local files_to_remove=(
        "${BIN_DIR}/spotify"
        "${BIN_DIR}/spotify-update"
        "${BIN_DIR}/spotify-uninstall"
        "${HOME}/start-spotify.sh"
        "${HOME}/update-spotify.sh"
        "${HOME}/uninstall-spotify.sh"
        "${SHORTCUTS_DIR}/Spotify"
    )

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

    # Host temp cleanup
    rm -rf "${TMP_DIR}/.X11-unix" "${TMP_DIR}/.X0-lock" 2>/dev/null || true
    success "Cache and temporary files successfully cleaned!"
}

action_revert_spotx() {
    info "Reverting SpotX patch (restoring official unmodified Spotify)..."
    if ! is_container_installed "$CONTAINER_NAME"; then
        error "Container '${CONTAINER_NAME}' is not installed. Nothing to revert."
        return 1
    fi

    kill_spotify_processes

    info "Running SpotX uninstaller inside container..."
    proot-distro login "$CONTAINER_NAME" -- bash -c '
        if [ -f /usr/share/spotify/Apps/xpui.spa.bak ]; then
            echo "[*] Restoring xpui.spa from backup..."
            cp -f /usr/share/spotify/Apps/xpui.spa.bak /usr/share/spotify/Apps/xpui.spa
            rm -f /usr/share/spotify/Apps/xpui.spa.bak
            echo "[✔] xpui.spa successfully restored!"
        else
            echo "[*] Downloading SpotX-Bash official uninstaller..."
            curl -sSL https://raw.githubusercontent.com/SpotX-Official/SpotX-Bash/main/spotx.sh | bash -s -- --uninstall -P /usr/share/spotify || true
        fi
    '

    success "SpotX patch removed. Spotify restored to official stock state."
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
                   /etc/spotx-termux \
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
}

action_full_uninstall() {
    echo -e "${RED}${BOLD}======================================================${CLR}"
    echo -e "${RED}${BOLD}            FULL UNINSTALLATION CONFIRMATION          ${CLR}"
    echo -e "${RED}${BOLD}======================================================${CLR}"
    warn "This operation will completely remove:"
    echo -e "  - All running Spotify, PulseAudio, and Termux-X11 processes"
    echo -e "  - The entire PRoot container '${BOLD}${CONTAINER_NAME}${CLR}' (~1+ GB of storage freed)"
    echo -e "  - All Spotify launchers (${BOLD}spotify${CLR}, ${BOLD}spotify-update${CLR}, ${BOLD}spotify-uninstall${CLR})"
    echo -e "  - Home screen widget shortcut (${BOLD}~/.shortcuts/Spotify${CLR})"
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

    # 2. Remove launchers and shortcuts
    remove_launchers

    # 3. Optional: purge Termux companion packages if requested
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

    echo
    echo -e "${GREEN}${BOLD}======================================================${CLR}"
    echo -e "${GREEN}${BOLD}      Full Uninstallation Completed Successfully!     ${CLR}"
    echo -e "${GREEN}${BOLD}======================================================${CLR}"
    echo -e "${WHITE}All SpotX-Termux files and containers have been removed.${CLR}\n"
}

show_interactive_menu() {
    show_banner
    echo -e "${WHITE}${BOLD}Select a cleanup option:${CLR}\n"
    echo -e "  ${GREEN}${BOLD}1)${CLR} ${BOLD}Full Uninstallation${CLR} ${YELLOW}[Recommended to remove everything]${CLR}"
    echo -e "     - Deletes Ubuntu container (~1+ GB freed)"
    echo -e "     - Removes all commands ('spotify', 'spotify-update', 'spotify-uninstall')"
    echo -e "     - Removes home screen widget shortcut"
    echo
    echo -e "  ${CYAN}${BOLD}2)${CLR} ${BOLD}Remove Spotify & SpotX only${CLR} ${YELLOW}[Preserves Ubuntu container]${CLR}"
    echo -e "     - Removes Spotify, SpotX, and caches inside container"
    echo -e "     - Removes Termux launchers"
    echo -e "     - Keeps the Ubuntu container intact for other uses"
    echo
    echo -e "  ${CYAN}${BOLD}3)${CLR} ${BOLD}Revert SpotX patch only${CLR}"
    echo -e "     - Reverts Spotify Desktop back to official unmodified stock client"
    echo -e "     - Keeps Spotify, launchers, and container intact"
    echo
    echo -e "  ${CYAN}${BOLD}4)${CLR} ${BOLD}Clean Cache & Temporary Files${CLR}"
    echo -e "     - Cleans Spotify caches and APT archives to free disk space"
    echo -e "     - Does NOT uninstall anything"
    echo
    echo -e "  ${CYAN}${BOLD}5)${CLR} ${BOLD}Remove Termux Launchers & Shortcuts only${CLR}"
    echo -e "     - Removes 'spotify' wrapper commands and widget shortcuts"
    echo -e "     - Keeps container and Spotify intact"
    echo
    echo -e "  ${RED}${BOLD}0)${CLR} Cancel / Exit without making any changes"
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
