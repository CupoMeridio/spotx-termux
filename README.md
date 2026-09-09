# SpotX-Termux 🎧📱

[![Italiano](https://img.shields.io/badge/lang-it-blue.svg)](README.it.md)

> **Run Spotify Linux Desktop client with SpotX patch on Android via Termux, PRoot, Box64, and Termux-X11.**  
> *Developed for educational and research purposes exploring user-space emulation and containerization on ARM64 architecture.*

---

## 📖 Project Overview

Spotify for Linux is officially distributed only for **x86_64** architectures.  
This project provides an automated pipeline to run the desktop client patched with [SpotX-Bash](https://github.com/SpotX-Official/SpotX-Bash) directly on an Android device:

```
┌────────────────────────────────────────────────────────┐
│                   Android OS (ARM64)                   │
├──────────────────────────┬─────────────────────────────┤
│   Termux-X11 (.apk)      │     Android Audio           │
│   GUI Display Server     │     (OpenSL / AAudio)       │
└────────────▲─────────────┴──────────────▲──────────────┘
             │                            │
             │ Display :0                 │ PulseAudio TCP
             │                            │ (127.0.0.1:4713)
┌────────────┴────────────────────────────┴──────────────┐
│                  Termux (User Space)                   │
│   pulseaudio daemon + termux-x11 display bridge        │
│   └── proot-distro (Ubuntu 24.04 LTS Noble)            │
│         │                                              │
│         ├── Box64 (CPU Emulator x86_64 -> ARM64)       │
│         ├── Spotify Desktop Linux (x86_64)             │
│         └── SpotX-Bash (Frontend ad-block patch)       │
└────────────────────────────────────────────────────────┘
```

---

## ⚡ Quick Install (One-Liner)

### 1. Android Prerequisites
Before running the installer in Termux, install the required applications:

- **Required:**
  1. **Termux**: Download the APK from [F-Droid](https://f-droid.org/packages/com.termux/) or [GitHub Releases](https://github.com/termux/termux-app/releases) *(DO NOT use the obsolete Google Play Store version)*.
  2. **Termux-X11**: Download the companion APK from [GitHub Releases](https://github.com/termux/termux-x11/releases) (recommended: `termux-x11-universal-debug.apk`).

- **Optional (recommended for convenience):**
  3. **Termux:Widget**: Download the APK from [F-Droid](https://f-droid.org/packages/com.termux.widget/) or [GitHub Releases](https://github.com/termux/termux-widget/releases). Adds a home-screen widget to launch Spotify with a single tap.  
     > ⚠️ **Important**: You must download Termux:Widget from the **exact same source** as Termux (both from F-Droid or both from GitHub Releases). If installed from different sources, Android will block installation due to signature incompatibility. (This restriction does not apply to Termux-X11, which is a standalone app).

---

### 2. Installation Command
Open Termux and paste the following commands:

#### Recommended option (inspect script before running):
```bash
curl -sSL https://raw.githubusercontent.com/CupoMeridio/spotx-termux/main/install.sh -o install.sh
less install.sh   # Review script contents
bash install.sh
```

#### Direct execution (one-liner):
```bash
curl -sSL https://raw.githubusercontent.com/CupoMeridio/spotx-termux/main/install.sh | bash
```

The script will automatically:
- Install required Termux packages (`proot-distro`, `pulseaudio`, `x11-repo`, `termux-x11-nightly`).
- Create an **Ubuntu 24.04 LTS** container.
- Configure **Box64** (on ARM64 CPUs) or use native execution (on x86_64).
- Download and extract the official Spotify client.
- Apply the **SpotX** patch in non-interactive mode.
- Set up launchers and the audio bridge.

---

## 🚀 Launching the App

Once installation completes, launch Spotify anytime with a single command:

```bash
spotify
```
*(or `./start-spotify.sh`)*

### Under the hood:
1. Starts the PulseAudio daemon bridging audio to Android drivers.
2. Initializes the Termux-X11 display server.
3. Brings the Termux-X11 app automatically to fullscreen foreground.
4. Launches Spotify inside Ubuntu PRoot with sandboxing flags adjusted for user-space (`--no-sandbox`).

### Launch via Home Screen Widget (Termux:Widget)
If you installed the **Termux:Widget** plugin, add a Termux widget to your phone's home screen: you will find the `Spotify` shortcut to launch the entire stack with a single tap, as well as `Spotify-Stop` to cleanly terminate everything without opening the terminal.

---

## 🛑 Closing Spotify & Lifecycle Management

To provide an experience as close as possible to native Android applications, closing Spotify automatically shuts down audio drivers, display bridges, and background container processes to prevent battery drain:

You can close Spotify using any of the following convenient methods:

1. **Home Screen Widget (Termux:Widget) - One Tap**:
   Tap the **`Spotify-Stop`** widget shortcut on your Android home screen. It immediately terminates Spotify, closes the Termux-X11 window, stops PulseAudio, releases the Android CPU wake-lock, and restores the terminal state.
2. **Dedicated Terminal Command**:
   Run anywhere in Termux:
   ```bash
   spotify-stop
   ```
   *(or `spotify --stop`)*
3. **Android Notification ("Exit")**:
   When Termux-X11 is running, pull down the Android notification shade and tap **Exit** on the persistent Termux-X11 notification. A background watchdog immediately detects the exit and closes all container Spotify processes and audio hardware bridges.
4. **Spotify Window Close (GUI)**:
   Closing Spotify from inside the UI (e.g. window close button or menu exit) automatically triggers a graceful teardown of PulseAudio and Termux-X11.
5. **Keyboard Interrupt in Termux (`Ctrl+C`)**:
   Pressing `Ctrl+C` in Termux cleanly intercepts the signal, terminates emulated Spotify processes, releases audio sinks, and restores the terminal prompt (`stty sane`) without freezing or locking up your shell.

---

## 🔄 Updating & Maintenance

Spotify, SpotX, and the entire runtime environment (Box64 configs, native libraries, and Termux launchers) can be kept up to date anytime without reinstalling or losing data:

```bash
spotify-update
```

### What gets updated:
1. **Container & Environment:** Automatically fetches the latest environment configuration, installs any newly added libraries (`libpci3`, `mesa-vulkan-drivers`, etc.), syncs `/etc/box64.box64rc`, and updates `/usr/local/bin/spotify-termux`.
2. **Host Launchers:** Refreshes `~/start-spotify.sh`, `~/update-spotify.sh`, `~/uninstall-spotify.sh`, and Termux properties.
3. **Spotify & SpotX:** Checks your installed version against the latest package in the Spotify APT repository:
   - If Spotify is up to date, it **skips downloading (~150 MB saved)** and reapplies the latest SpotX patch.
   - If a new Spotify version is available, it downloads the deb package, verifies SHA256 integrity, unpacks it, and applies SpotX.

> 💡 **Tip:** You can also re-run the main inline installation command at any time (`curl -sSL https://raw.githubusercontent.com/CupoMeridio/spotx-termux/main/install.sh | bash`). The installer is **completely idempotent**: it detects your existing Ubuntu container without wiping it, skips downloading existing packages, and quickly brings all scripts and configurations up to date in seconds.

### Command Options:
- **Check versions only** (no changes made):
  ```bash
  spotify-update --check
  ```
- **Reapply SpotX patch only** (useful to refresh SpotX filters without touching the Spotify client):
  ```bash
  spotify-update --spotx-only
  ```
- **Update Spotify client only** (skip SpotX patching):
  ```bash
  spotify-update --skip-spotx
  ```

---

## 🗑️ Uninstallation & Cleanup

If you want to clean up or uninstall SpotX-Termux, you can use the built-in modular cleanup utility:

```bash
spotify-uninstall
```

*(or `bash uninstall.sh`, or via one-liner `curl -sSL https://raw.githubusercontent.com/CupoMeridio/spotx-termux/main/uninstall.sh | bash`)*

### Interactive Cleanup Options:
1. **Full Uninstallation (`--full` / `-f`)**:
   - Stops all running Spotify, Termux-X11, and PulseAudio background processes.
   - Completely removes the PRoot Ubuntu container (**freeing ~1+ GB of storage**).
   - Deletes all command launchers (`spotify`, `spotify-update`, `spotify-uninstall`) and Termux:Widget shortcuts.
   - Optionally asks if you also want to remove unused Termux packages (`termux-x11-nightly`, `pulseaudio`).
2. **Remove Spotify & SpotX only (`--keep-ubuntu` / `--spotify-only`)**:
   - Uninstalls Spotify, Box64, SpotX, and user cache/config files inside the container.
   - Removes Spotify Termux launchers.
   - **Preserves the Ubuntu container intact** for your other projects and tools.
3. **Revert SpotX patch only (`--spotx-only` / `-s`)**:
   - Restores the official unmodified desktop Spotify client.
   - Keeps Spotify and the container intact.
4. **Clean Cache & Temporary Files (`--clean-cache` / `-c`)**:
   - Cleans Spotify user caches and APT archives to free disk space without uninstalling anything.
5. **Remove Termux launchers only (`--launchers-only` / `-l`)**:
   - Removes Termux command wrappers and home screen widgets while keeping the container intact.

### Non-Interactive & Automation:
```bash
spotify-uninstall --full -y        # Completely remove everything without prompting
spotify-uninstall --clean-cache    # Free disk space (cache cleanup)
spotify-uninstall --spotx-only     # Revert to official stock Spotify
```

---

## ⚙️ Repository Structure

```
spotx-termux/
├── install.sh              # Main installation script
├── uninstall.sh            # Modular cleanup & uninstallation script
├── README.md               # Official documentation (English)
├── README.it.md            # Documentation (Italian)
└── src/
    ├── guest-setup.sh      # Container configuration script (Box64, Spotify, SpotX)
    ├── start-spotify.sh    # Host launcher (PulseAudio, X11, Spotify)
    └── update-spotify.sh   # Host updater orchestrator
```

---

## 🛠️ Troubleshooting & Tips

* **Recommended Login Method (QR Code):**  
  When logging into Spotify for the first time, **strongly prefer the QR Code login option**.  
  *Why:* The standard web-based "Log In" button attempts to launch a desktop web browser via `xdg-open` to complete an external OAuth authentication flow. Because the minimal PRoot Ubuntu container does not have a desktop browser installed, clicking that button will fail silently or hang.
* **Audio cuts out in background:**  
  Android applies aggressive battery optimizations. Go to *Android Settings > Apps > Termux > Battery* and set it to **Unrestricted**.
* **Touch controls in Termux-X11:**  
  In the Termux-X11 in-app preferences (accessible from notification panel or 4-finger swipe), enable virtual touchpad mode for precise mouse control.
* **Black screen or launch crashes:**  
  Ensure the Termux-X11 APK is installed and granted necessary permissions.

---

## ⚖️ Disclaimer
This repository is intended solely for educational and research purposes investigating POSIX runtimes, dynamic binary translation (Box64), and user-space containerization on Android. Spotify is a registered trademark of Spotify AB. Use of third-party modification scripts is at your own discretion and responsibility.
