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
If you installed the **Termux:Widget** plugin, add a Termux widget to your phone's home screen: you will find the `Spotify` shortcut to launch the entire stack with a single tap without opening the terminal.

---

## 🔄 Updating & Maintenance

Spotify and SpotX can be updated anytime without reinstalling the entire container:

```bash
spotify-update
```

The script checks your installed version against the latest package in the Spotify APT repository:
- If Spotify is up to date, it **skips downloading (~150 MB saved)** and only reapplies the SpotX patch if needed.
- If a new version is available, it downloads the deb package, verifies its SHA256 integrity, unpacks it, and applies SpotX.

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

## ⚙️ Repository Structure

```
spotx-termux/
├── install.sh              # Main installation script
├── README.md               # Official documentation (English)
├── README.it.md            # Documentation (Italian)
└── src/
    ├── guest-setup.sh      # Container configuration script (Box64, Spotify, SpotX)
    ├── start-spotify.sh    # Host launcher (PulseAudio, X11, Spotify)
    └── update-spotify.sh   # Host updater orchestrator
```

---

## 🛠️ Troubleshooting & Tips

* **Audio cuts out in background:**  
  Android applies aggressive battery optimizations. Go to *Android Settings > Apps > Termux > Battery* and set it to **Unrestricted**.
* **Touch controls in Termux-X11:**  
  In the Termux-X11 in-app preferences (accessible from notification panel or 4-finger swipe), enable virtual touchpad mode for precise mouse control.
* **Black screen or launch crashes:**  
  Ensure the Termux-X11 APK is installed and granted necessary permissions.

---

## ⚖️ Disclaimer
This repository is intended solely for educational and research purposes investigating POSIX runtimes, dynamic binary translation (Box64), and user-space containerization on Android. Spotify is a registered trademark of Spotify AB. Use of third-party modification scripts is at your own discretion and responsibility.
