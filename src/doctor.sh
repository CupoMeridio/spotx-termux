#!/usr/bin/env bash
# ==============================================================================
# doctor.sh - Diagnostic & Health-Check Utility for SpotX-Termux
# Repository: https://github.com/CupoMeridio/spotx-termux
# ==============================================================================
set -u

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

# Status Indicators (Text-based symbols, no emojis)
SYM_PASS="${GREEN}${BOLD}[OK]${CLR}"
SYM_WARN="${YELLOW}${BOLD}[! ]${CLR}"
SYM_FAIL="${RED}${BOLD}[X ]${CLR}"
SYM_INFO="${CYAN}${BOLD}[* ]${CLR}"

# Counters
CHECKS_PASSED=0
CHECKS_WARNED=0
CHECKS_FAILED=0
FIXES=()

record_pass() {
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
}

record_warn() {
    local message="$1"
    local fix="${2:-}"
    CHECKS_WARNED=$((CHECKS_WARNED + 1))
    if [ -n "$fix" ]; then
        FIXES+=("[!] ${message}: ${fix}")
    fi
}

record_fail() {
    local message="$1"
    local fix="${2:-}"
    CHECKS_FAILED=$((CHECKS_FAILED + 1))
    if [ -n "$fix" ]; then
        FIXES+=("[X] ${message}: ${fix}")
    fi
}

show_help() {
    cat << EOF
SpotX-Termux Doctor (v${SPOTX_TERMUX_VERSION})

Usage:
  spotify-doctor [OPTIONS]
  spotify --doctor

Options:
  --help, -h       Show this help message
  --version, -V    Show version information

Description:
  Performs an automated multi-layer health inspection of SpotX-Termux:
    1. Host Environment (Termux, architecture, storage, packages)
    2. Android & Companion Apps (Termux-X11 APK, shortcuts)
    3. Runtime Services (PulseAudio daemon, X11 display server)
    4. Ubuntu PRoot Container (Box64, Spotify binary ELF, SpotX patch)
EOF
}

# ------------------------------------------------------------------------------
# Argument Parsing
# ------------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            show_help
            exit 0
            ;;
        --version|-V)
            echo "SpotX-Termux ${SPOTX_TERMUX_VERSION}"
            exit 0
            ;;
        *)
            echo -e "${RED}[X] Unknown argument: $1${CLR}" >&2
            show_help
            exit 1
            ;;
    esac
done

echo -e "${CYAN}======================================================${CLR}"
echo -e "${CYAN}${BOLD}   SpotX-Termux Doctor - System Diagnostics          ${CLR}"
echo -e "${CYAN}   Version: ${SPOTX_TERMUX_VERSION}${CLR}"
echo -e "${CYAN}======================================================${CLR}\n"

# ==============================================================================
# LAYER 1: Host Environment (Termux)
# ==============================================================================
echo -e "${BOLD}[1/4] Checking Termux Host Environment...${CLR}"

# Check 1.1: Termux Detection
IS_TERMUX=false
if [ -n "${TERMUX_VERSION:-}" ] || [ -d "/data/data/com.termux" ] || [[ "${PREFIX:-}" == *"com.termux"* ]]; then
    IS_TERMUX=true
fi

if [ "$IS_TERMUX" = true ]; then
    echo -e "  ${SYM_PASS} Termux Environment:         ${GREEN}detected${CLR} ${DIM}(${TERMUX_VERSION:-v0.118+})${CLR}"
    record_pass
else
    echo -e "  ${SYM_WARN} Termux Environment:         ${YELLOW}non-Termux Linux host${CLR}"
    record_warn "Non-Termux Host" "Running on standard Linux; Android integrations will be skipped."
fi

# Check 1.2: Architecture
ARCH="$(uname -m)"
case "$ARCH" in
    aarch64|arm64)
        echo -e "  ${SYM_PASS} CPU Architecture:           ${GREEN}${ARCH}${CLR} ${DIM}(ARM64, Box64 translation supported)${CLR}"
        record_pass
        ;;
    x86_64|amd64)
        echo -e "  ${SYM_PASS} CPU Architecture:           ${GREEN}${ARCH}${CLR} ${DIM}(x86_64, native execution supported)${CLR}"
        record_pass
        ;;
    *)
        echo -e "  ${SYM_FAIL} CPU Architecture:           ${RED}${ARCH} (unsupported)${CLR}"
        record_fail "Unsupported CPU Architecture" "Spotify Desktop requires 64-bit CPU (aarch64 or x86_64). Architecture '${ARCH}' is not supported."
        ;;
esac

# Check 1.3: Available Disk Space
FREE_KB=0
if command -v df >/dev/null 2>&1; then
    TARGET_DIR="${HOME}"
    [ -d "$TARGET_DIR" ] || TARGET_DIR="/"
    FREE_KB=$(df -k "$TARGET_DIR" 2>/dev/null | awk 'NR==2 {print $4}')
fi
if [ -n "$FREE_KB" ] && [ "$FREE_KB" -gt 0 ] 2>/dev/null; then
    FREE_MB=$((FREE_KB / 1024))
    FREE_GB=$((FREE_MB / 1024))
    if [ "$FREE_MB" -gt 2048 ]; then
        echo -e "  ${SYM_PASS} Available Storage:          ${GREEN}${FREE_GB} GB free${CLR} ${DIM}(>2 GB required)${CLR}"
        record_pass
    elif [ "$FREE_MB" -gt 1024 ]; then
        echo -e "  ${SYM_WARN} Available Storage:          ${YELLOW}${FREE_MB} MB free${CLR} ${DIM}(low disk space, >=2 GB recommended)${CLR}"
        record_warn "Low Disk Space" "Run 'spotify-uninstall --clean-cache' or free up space in Termux."
    else
        echo -e "  ${SYM_FAIL} Available Storage:          ${RED}${FREE_MB} MB free${CLR} ${DIM}(critical: container setup needs ~2 GB)${CLR}"
        record_fail "Critically Low Disk Space" "Free at least 2 GB of internal storage before running or updating Spotify."
    fi
else
    echo -e "  ${SYM_INFO} Available Storage:          unable to calculate"
fi

# Check 1.4: Required Termux Packages
REQUIRED_HOST_PKGS=("proot-distro" "pulseaudio" "wget" "curl" "jq")
MISSING_PKGS=()
for pkg_name in "${REQUIRED_HOST_PKGS[@]}"; do
    if ! command -v "$pkg_name" >/dev/null 2>&1; then
        MISSING_PKGS+=("$pkg_name")
    fi
done

if [ ${#MISSING_PKGS[@]} -eq 0 ]; then
    echo -e "  ${SYM_PASS} Required Packages:          ${GREEN}all installed${CLR} ${DIM}(proot-distro, pulseaudio, wget, curl, jq)${CLR}"
    record_pass
else
    echo -e "  ${SYM_FAIL} Required Packages:          ${RED}missing: ${MISSING_PKGS[*]}${CLR}"
    record_fail "Missing Host Packages" "Run 'pkg install -y ${MISSING_PKGS[*]}'"
fi

# Check 1.5: allow-external-apps in termux.properties
TERMUX_PROPS="${HOME}/.termux/termux.properties"
if [ "$IS_TERMUX" = true ]; then
    if [ -f "$TERMUX_PROPS" ] && grep -q "^[[:space:]]*allow-external-apps[[:space:]]*=[[:space:]]*true" "$TERMUX_PROPS" 2>/dev/null; then
        echo -e "  ${SYM_PASS} allow-external-apps:        ${GREEN}enabled${CLR} ${DIM}(termux.properties)${CLR}"
        record_pass
    else
        echo -e "  ${SYM_WARN} allow-external-apps:        ${YELLOW}not enabled${CLR} ${DIM}(Termux-X11 app interaction may be blocked)${CLR}"
        record_warn "allow-external-apps Disabled" "Run 'mkdir -p ~/.termux && echo \"allow-external-apps = true\" >> ~/.termux/termux.properties && termux-reload-settings'"
    fi
fi

# Check 1.6: SpotX-Termux CLI commands
BIN_DIR="${PREFIX:-/data/data/com.termux/files/usr}/bin"
SPOTX_COMMANDS=("spotify" "spotify-stop" "spotify-control" "spotify-update" "spotify-uninstall" "spotify-doctor")
MISSING_CMDS=()
for cmd in "${SPOTX_COMMANDS[@]}"; do
    if [ ! -x "${BIN_DIR}/${cmd}" ]; then
        MISSING_CMDS+=("$cmd")
    fi
done

if [ ${#MISSING_CMDS[@]} -eq 0 ]; then
    echo -e "  ${SYM_PASS} SpotX Command Wrappers:     ${GREEN}ready${CLR} ${DIM}(spotify, stop, control, update, uninstall, doctor)${CLR}"
    record_pass
else
    echo -e "  ${SYM_WARN} SpotX Command Wrappers:     ${YELLOW}missing: ${MISSING_CMDS[*]}${CLR}"
    record_warn "Missing Command Wrappers" "Re-run 'bash install.sh' to restore wrapper scripts in ${BIN_DIR}."
fi

# Check 1.7: SpotX-Termux Shared Core Library
if [ -f "${HOME}/.spotx-termux/common.sh" ]; then
    echo -e "  ${SYM_PASS} Shared Core Library:        ${GREEN}installed${CLR} ${DIM}(~/.spotx-termux/common.sh)${CLR}"
    record_pass
else
    echo -e "  ${SYM_WARN} Shared Core Library:        ${YELLOW}missing${CLR}"
    record_warn "Missing Core Library" "Run 'spotify-update' to synchronize ~/.spotx-termux/common.sh."
fi

# Check 1.8: SpotX-Termux Log Directory & Diagnostic Logs
LOG_DIR="${HOME}/.spotx-termux/logs"
if [ -d "$LOG_DIR" ]; then
    FOUND_LOGS=()
    [ -f "${LOG_DIR}/install.log" ] && FOUND_LOGS+=("install.log")
    [ -f "${LOG_DIR}/update.log" ] && FOUND_LOGS+=("update.log")
    [ -f "${LOG_DIR}/uninstall.log" ] && FOUND_LOGS+=("uninstall.log")
    if [ ${#FOUND_LOGS[@]} -gt 0 ]; then
        echo -e "  ${SYM_PASS} Diagnostics & Logs:        ${GREEN}${LOG_DIR}${CLR} ${DIM}(${FOUND_LOGS[*]})${CLR}"
        record_pass
    else
        echo -e "  ${SYM_INFO} Diagnostics & Logs:        ${LOG_DIR} ${DIM}(ready, no logs yet)${CLR}"
    fi
else
    echo -e "  ${SYM_INFO} Diagnostics & Logs:        not initialized ${DIM}(created on first run)${CLR}"
fi

echo

# ==============================================================================
# LAYER 2: Android & Display Integration
# ==============================================================================
echo -e "${BOLD}[2/4] Checking Android & Companion Integration...${CLR}"

# Check 2.1: Termux-X11 Host Package
if command -v termux-x11 >/dev/null 2>&1; then
    echo -e "  ${SYM_PASS} Termux-X11 Package:         ${GREEN}installed${CLR} ${DIM}(termux-x11 binary found)${CLR}"
    record_pass
else
    echo -e "  ${SYM_FAIL} Termux-X11 Package:         ${RED}not found${CLR}"
    record_fail "Termux-X11 Not Installed" "Run 'pkg install -y x11-repo && pkg install -y termux-x11-nightly'"
fi

# Check 2.2: Termux-X11 Android APK detection
if [ "$IS_TERMUX" = true ]; then
    X11_APP_FOUND=false
    if command -v pm >/dev/null 2>&1; then
        if pm list packages com.termux.x11 2>/dev/null | grep -q "com.termux.x11"; then
            X11_APP_FOUND=true
        fi
    elif [ -d "/data/data/com.termux.x11" ]; then
        X11_APP_FOUND=true
    fi

    if [ "$X11_APP_FOUND" = true ]; then
        echo -e "  ${SYM_PASS} Termux-X11 Android App:     ${GREEN}detected${CLR} ${DIM}(com.termux.x11)${CLR}"
        record_pass
    else
        echo -e "  ${SYM_WARN} Termux-X11 Android App:     ${YELLOW}not detected via pm${CLR}"
        record_warn "Termux-X11 APK Not Detected" "Download and install the APK from https://github.com/termux/termux-x11/releases"
    fi
fi

# Check 2.3: Termux:Widget Shortcuts
SHORTCUTS_DIR="${HOME}/.shortcuts"
if [ -f "${SHORTCUTS_DIR}/Spotify" ] && [ -f "${SHORTCUTS_DIR}/Spotify-Stop" ]; then
    echo -e "  ${SYM_PASS} Termux:Widget Shortcuts:    ${GREEN}configured${CLR} ${DIM}(Spotify, Spotify-Stop)${CLR}"
    record_pass
else
    echo -e "  ${SYM_INFO} Termux:Widget Shortcuts:    ${DIM}not found in ~/.shortcuts (optional)${CLR}"
fi

# Check 2.4: Termux:API Companion & System Notifications
API_PKG_FOUND=false
API_APP_FOUND=false

if command -v termux-notification >/dev/null 2>&1; then
    API_PKG_FOUND=true
fi

if [ "$IS_TERMUX" = true ]; then
    if command -v pm >/dev/null 2>&1; then
        if pm list packages com.termux.api 2>/dev/null | grep -q "com.termux.api"; then
            API_APP_FOUND=true
        fi
    elif [ -d "/data/data/com.termux.api" ]; then
        API_APP_FOUND=true
    fi
fi

if [ "$API_PKG_FOUND" = true ] && [ "$API_APP_FOUND" = true ]; then
    echo -e "  ${SYM_PASS} Termux:API Companion:       ${GREEN}ready${CLR} ${DIM}(package & com.termux.api APK detected)${CLR}"
    record_pass
elif [ "$API_PKG_FOUND" = true ] && [ "$API_APP_FOUND" = false ]; then
    echo -e "  ${SYM_WARN} Termux:API Companion:       ${YELLOW}package installed, APK missing${CLR}"
    record_warn "Termux:API APK Not Found" "Install Termux:API app from GitHub/F-Droid to enable Android system notifications."
elif [ "$API_PKG_FOUND" = false ] && [ "$API_APP_FOUND" = true ]; then
    echo -e "  ${SYM_WARN} Termux:API Companion:       ${YELLOW}APK detected, CLI package missing${CLR}"
    record_warn "Termux:API Package Missing" "Run 'pkg install -y termux-api' to enable system notification support."
else
    echo -e "  ${SYM_INFO} Termux:API Companion:       ${DIM}not installed (optional, needed for Android notifications)${CLR}"
fi

echo

# ==============================================================================
# LAYER 3: Audio & Display Runtime Services
# ==============================================================================
echo -e "${BOLD}[3/4] Checking Audio & Display Runtime Status...${CLR}"

# Check 3.1: PulseAudio Configuration
PULSE_CONF="${HOME}/.config/pulse/daemon.conf"
if [ -f "$PULSE_CONF" ] && grep -q "speex-float-1" "$PULSE_CONF" 2>/dev/null && grep -q "48000" "$PULSE_CONF" 2>/dev/null; then
    echo -e "  ${SYM_PASS} PulseAudio Config:          ${GREEN}optimized${CLR} ${DIM}(speex-float-1, 48000Hz, OpenSL ES)${CLR}"
    record_pass
elif [ -f "$PULSE_CONF" ]; then
    echo -e "  ${SYM_WARN} PulseAudio Config:          ${YELLOW}present but not tuned${CLR}"
    record_warn "PulseAudio Config Untuned" "Re-run 'bash install.sh' or update ~/.config/pulse/daemon.conf for optimal performance."
else
    echo -e "  ${SYM_WARN} PulseAudio Config:          ${YELLOW}default / missing${CLR} ${DIM}(~/.config/pulse/daemon.conf)${CLR}"
    record_warn "Missing PulseAudio Config" "Re-run 'bash install.sh' to write recommended audio daemon settings."
fi

# Check 3.2: PulseAudio Daemon Runtime Status
if pgrep -x "pulseaudio" >/dev/null 2>&1; then
    PULSE_PID=$(pgrep -x "pulseaudio" | head -1)
    echo -e "  ${SYM_INFO} PulseAudio Daemon:          ${GREEN}running${CLR} ${DIM}(PID ${PULSE_PID})${CLR}"
else
    echo -e "  ${SYM_INFO} PulseAudio Daemon:          ${DIM}idle / not running (starts automatically on launch)${CLR}"
fi

# Check 3.3: Termux-X11 Display Server Runtime Status
TERMUX_TMP="${PREFIX:-/data/data/com.termux/files/usr}/tmp"
if pgrep -f "termux.x11" >/dev/null 2>&1 || pgrep -f "termux-x11" >/dev/null 2>&1; then
    echo -e "  ${SYM_INFO} Termux-X11 Server:          ${GREEN}running${CLR} ${DIM}(Display :0 active)${CLR}"
else
    echo -e "  ${SYM_INFO} Termux-X11 Server:          ${DIM}idle / not running (starts automatically on launch)${CLR}"
fi

echo

# ==============================================================================
# LAYER 4: Ubuntu PRoot Container (Guest)
# ==============================================================================
echo -e "${BOLD}[4/4] Checking Ubuntu PRoot Container & Spotify...${CLR}"

CONTAINER_NAME="ubuntu"
is_container_installed() {
    local name="$1"
    local prefix="${PREFIX:-/data/data/com.termux/files/usr}"
    if [ -d "${prefix}/var/lib/proot-distro/containers/${name}" ] || \
       [ -d "${prefix}/var/lib/proot-distro/installed-rootfs/${name}" ] || \
       [ -d "/usr/var/lib/proot-distro/containers/${name}" ] || \
       [ -d "/usr/var/lib/proot-distro/installed-rootfs/${name}" ]; then
        return 0
    fi
    return 1
}

if ! command -v proot-distro >/dev/null 2>&1; then
    echo -e "  ${SYM_FAIL} PRoot Container:            ${RED}proot-distro not installed${CLR}"
    record_fail "proot-distro Missing" "Run 'pkg install -y proot-distro && bash install.sh'"
elif ! is_container_installed "$CONTAINER_NAME"; then
    echo -e "  ${SYM_FAIL} Container '${CONTAINER_NAME}':         ${RED}not installed${CLR}"
    record_fail "Container Not Installed" "Run 'bash install.sh' to install Ubuntu and Spotify."
else
    echo -e "  ${SYM_PASS} Container '${CONTAINER_NAME}':         ${GREEN}installed${CLR}"
    record_pass

    # Single-pass container probe to eliminate multi-login PRoot overhead
    CONTAINER_PROBE_OUTPUT=$(proot-distro login "$CONTAINER_NAME" -- bash -c '
        echo "GUEST_RESPONSIVE=yes"

        # Box64 check
        if command -v box64 >/dev/null 2>&1; then
            echo "GUEST_BOX64_VER=$(box64 -v 2>&1 | head -1)"
        else
            echo "GUEST_BOX64_VER="
        fi
        if grep -E "^BOX64_INPROCESSGPU=0" /etc/box64.box64rc /root/.box64rc >/dev/null 2>&1; then
            echo "GUEST_BOX64_GPU=0"
        else
            echo "GUEST_BOX64_GPU=other"
        fi

        # Window Manager check
        if command -v matchbox-window-manager >/dev/null 2>&1; then
            echo "GUEST_WM=matchbox"
        elif command -v openbox >/dev/null 2>&1; then
            echo "GUEST_WM=openbox"
        else
            echo "GUEST_WM=none"
        fi

        # Spotify ELF check
        if [ ! -f /usr/share/spotify/spotify ]; then
            echo "GUEST_ELF=missing"
        elif [ "$(head -c 4 /usr/share/spotify/spotify 2>/dev/null)" = $'"'"'\x7fELF'"'"' ]; then
            echo "GUEST_ELF=valid_elf"
        else
            echo "GUEST_ELF=corrupted"
        fi

        # Installed Version check
        if [ -f /root/.spotify-installed-version ]; then
            echo "GUEST_VER=$(cat /root/.spotify-installed-version 2>/dev/null | tr -d "[:space:]")"
        elif command -v dpkg-query >/dev/null 2>&1; then
            echo "GUEST_VER=$(dpkg-query -W -f='"'"'${Version}'"'"' spotify-client 2>/dev/null | tr -d "[:space:]")"
        else
            echo "GUEST_VER="
        fi

        # SpotX Patch check
        if [ -f /usr/share/spotify/Apps/xpui.spa ]; then
            if unzip -p /usr/share/spotify/Apps/xpui.spa xpui.js 2>/dev/null | grep -Fq "SpotX"; then
                echo "GUEST_SPOTX=applied"
            else
                echo "GUEST_SPOTX=not_applied"
            fi
        else
            echo "GUEST_SPOTX=missing_xpui"
        fi

        # Runner script check
        if [ -x /usr/local/bin/spotify-termux ]; then
            echo "GUEST_RUNNER=yes"
        else
            echo "GUEST_RUNNER=no"
        fi

        # Playerctl media controls check
        if command -v playerctl >/dev/null 2>&1; then
            echo "GUEST_PLAYERCTL=yes"
        else
            echo "GUEST_PLAYERCTL=no"
        fi
    ' 2>/dev/null || true)

    GUEST_RESPONSIVE=""
    GUEST_BOX64_VER=""
    GUEST_BOX64_GPU=""
    GUEST_WM=""
    GUEST_ELF=""
    GUEST_VER=""
    GUEST_SPOTX=""
    GUEST_RUNNER=""
    GUEST_PLAYERCTL=""

    if [ -n "$CONTAINER_PROBE_OUTPUT" ]; then
        while IFS='=' read -r key val; do
            case "$key" in
                GUEST_RESPONSIVE) GUEST_RESPONSIVE="$val" ;;
                GUEST_BOX64_VER)   GUEST_BOX64_VER="$val" ;;
                GUEST_BOX64_GPU)   GUEST_BOX64_GPU="$val" ;;
                GUEST_WM)          GUEST_WM="$val" ;;
                GUEST_ELF)         GUEST_ELF="$val" ;;
                GUEST_VER)         GUEST_VER="$val" ;;
                GUEST_SPOTX)       GUEST_SPOTX="$val" ;;
                GUEST_RUNNER)      GUEST_RUNNER="$val" ;;
                GUEST_PLAYERCTL)   GUEST_PLAYERCTL="$val" ;;
            esac
        done <<< "$CONTAINER_PROBE_OUTPUT"
    fi

    if [ "$GUEST_RESPONSIVE" = "yes" ]; then
        echo -e "  ${SYM_PASS} Container Login:            ${GREEN}responsive${CLR}"
        record_pass
    else
        echo -e "  ${SYM_FAIL} Container Login:            ${RED}failed to login into ${CONTAINER_NAME}${CLR}"
        record_fail "Container Login Failed" "PRoot container is corrupted or busy. Run 'spotify-uninstall --full' and reinstall."
    fi

    # Box64 (on ARM64)
    if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
        if [ -n "$GUEST_BOX64_VER" ]; then
            echo -e "  ${SYM_PASS} Box64 Translation Layer:   ${GREEN}${GUEST_BOX64_VER}${CLR}"
            record_pass
        else
            echo -e "  ${SYM_FAIL} Box64 Translation Layer:   ${RED}box64 not found in container${CLR}"
            record_fail "Box64 Missing" "Run 'spotify-update' to install or repair Box64 inside Ubuntu."
        fi

        if [ "$GUEST_BOX64_GPU" = "0" ]; then
            echo -e "  ${SYM_PASS} Box64 In-Process GPU:       ${GREEN}disabled${CLR} ${DIM}(BOX64_INPROCESSGPU=0, crash-resistant)${CLR}"
            record_pass
        else
            echo -e "  ${SYM_WARN} Box64 In-Process GPU:       ${YELLOW}not configured to 0${CLR}"
            record_warn "Box64 In-Process GPU" "Run 'spotify-update' to configure /etc/box64.box64rc"
        fi
    fi

    # Window Manager
    if [ "$GUEST_WM" = "matchbox" ]; then
        echo -e "  ${SYM_PASS} Window Manager:             ${GREEN}matchbox-window-manager${CLR} ${DIM}(auto-fullscreen active)${CLR}"
        record_pass
    elif [ "$GUEST_WM" = "openbox" ]; then
        echo -e "  ${SYM_PASS} Window Manager:             ${GREEN}openbox${CLR}"
        record_pass
    else
        echo -e "  ${SYM_WARN} Window Manager:             ${YELLOW}none found${CLR} ${DIM}(Spotify might not auto-fullscreen)${CLR}"
        record_warn "Window Manager Missing" "Run 'proot-distro login ubuntu -- apt-get install -y matchbox-window-manager'"
    fi

    # Spotify Binary & ELF integrity
    case "$GUEST_ELF" in
        valid_elf)
            echo -e "  ${SYM_PASS} Spotify Desktop Binary:     ${GREEN}present and valid ELF${CLR} ${DIM}(/usr/share/spotify/spotify)${CLR}"
            record_pass
            ;;
        missing)
            echo -e "  ${SYM_FAIL} Spotify Desktop Binary:     ${RED}missing${CLR} ${DIM}(/usr/share/spotify/spotify)${CLR}"
            record_fail "Spotify Binary Missing" "Run 'spotify-update' to download and install Spotify Desktop."
            ;;
        *)
            echo -e "  ${SYM_FAIL} Spotify Desktop Binary:     ${RED}corrupted or non-ELF file${CLR}"
            record_fail "Corrupted Spotify Binary" "Run 'spotify-update' to re-download the clean Spotify package."
            ;;
    esac

    # Spotify Version
    if [ -n "$GUEST_VER" ]; then
        echo -e "  ${SYM_PASS} Installed Spotify Version:  ${GREEN}${GUEST_VER}${CLR}"
        record_pass
    else
        echo -e "  ${SYM_WARN} Installed Spotify Version:  ${YELLOW}unable to determine${CLR}"
    fi

    # SpotX Patch
    case "$GUEST_SPOTX" in
        applied)
            echo -e "  ${SYM_PASS} SpotX Patch Status:         ${GREEN}applied [OK]${CLR} ${DIM}(xpui.spa modified)${CLR}"
            record_pass
            ;;
        not_applied)
            echo -e "  ${SYM_WARN} SpotX Patch Status:         ${YELLOW}stock Spotify (patch not applied)${CLR}"
            record_warn "SpotX Patch Not Applied" "Run 'spotify-update --spotx-only' to apply SpotX modifications."
            ;;
        missing_xpui)
            echo -e "  ${SYM_WARN} SpotX Patch Status:         ${YELLOW}xpui.spa not found${CLR}"
            record_warn "Missing xpui.spa" "Run 'spotify-update' to reinstall Spotify and apply SpotX."
            ;;
        *)
            echo -e "  ${SYM_INFO} SpotX Patch Status:         ${DIM}unable to inspect xpui.spa${CLR}"
            ;;
    esac

    # Container Runner
    if [ "$GUEST_RUNNER" = "yes" ]; then
        echo -e "  ${SYM_PASS} Container Runner:           ${GREEN}ready${CLR} ${DIM}(/usr/local/bin/spotify-termux)${CLR}"
        record_pass
    else
        echo -e "  ${SYM_FAIL} Container Runner:           ${RED}missing${CLR} ${DIM}(/usr/local/bin/spotify-termux)${CLR}"
        record_fail "Missing Container Runner" "Run 'spotify-update' to regenerate /usr/local/bin/spotify-termux."
    fi

    # MPRIS Media Controls (playerctl)
    if [ "$GUEST_PLAYERCTL" = "yes" ]; then
        echo -e "  ${SYM_PASS} MPRIS Media Controls:       ${GREEN}playerctl ready${CLR} ${DIM}(notification controls active)${CLR}"
        record_pass
    else
        echo -e "  ${SYM_WARN} MPRIS Media Controls:       ${YELLOW}playerctl not installed${CLR} ${DIM}(notification controls unavailable)${CLR}"
        record_warn "MPRIS Media Controls Missing" "Run 'spotify-update' to install playerctl inside Ubuntu."
    fi
fi

echo

# ==============================================================================
# SUMMARY & ACTIONABLE FIXES
# ==============================================================================
TOTAL_CHECKS=$((CHECKS_PASSED + CHECKS_WARNED + CHECKS_FAILED))
echo -e "${CYAN}======================================================${CLR}"
echo -e "${CYAN}${BOLD}   Doctor Diagnostic Summary                         ${CLR}"
echo -e "${CYAN}======================================================${CLR}"
echo -e "  Checks Passed:   ${GREEN}${BOLD}${CHECKS_PASSED}${CLR} / ${TOTAL_CHECKS}"
[ "$CHECKS_WARNED" -gt 0 ] && echo -e "  Warnings:        ${YELLOW}${BOLD}${CHECKS_WARNED}${CLR}"
[ "$CHECKS_FAILED" -gt 0 ] && echo -e "  Failures:        ${RED}${BOLD}${CHECKS_FAILED}${CLR}"
echo

if [ "$CHECKS_FAILED" -eq 0 ] && [ "$CHECKS_WARNED" -eq 0 ]; then
    echo -e "${GREEN}${BOLD}[OK] All checks passed! Everything is configured properly.${CLR}"
    echo -e "  Launch Spotify anytime with: ${BOLD}${CYAN}spotify${CLR}\n"
    exit 0
elif [ "$CHECKS_FAILED" -eq 0 ]; then
    echo -e "${YELLOW}${BOLD}[!] System is functional with minor warnings.${CLR}"
    echo -e "${YELLOW}Suggested improvements:${CLR}"
    if [ ${#FIXES[@]} -gt 0 ]; then
        for fix in "${FIXES[@]}"; do
            echo -e "  ${fix}"
        done
    fi
    echo
    exit 0
else
    echo -e "${RED}${BOLD}[X] Problems detected that may prevent Spotify from working correctly.${CLR}"
    echo -e "${RED}Recommended fixes:${CLR}"
    if [ ${#FIXES[@]} -gt 0 ]; then
        for fix in "${FIXES[@]}"; do
            echo -e "  ${fix}"
        done
    fi
    echo
    exit 1
fi
