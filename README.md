# Posturr

**A macOS app that blurs your screen when you slouch.**

Posturr uses your Mac's camera and Apple's Vision framework to monitor your posture in real-time. When it detects that you're slouching, it progressively blurs your screen to remind you to sit up straight. Maintain good posture, and the blur clears instantly.

[![Discord](https://img.shields.io/badge/Discord-Join%20Community-5865F2?style=for-the-badge&logo=discord&logoColor=white)](https://discord.gg/8VzX39fZ)

**Join our Discord** to share feedback, get help, suggest features, and connect with other Posturr users!

## Screenshots

<p align="center">
  <img src="assets/posturr_menubar.jpg" width="280" alt="Menu Bar">
  <img src="assets/posturr_settings.jpg" width="400" alt="Settings">
</p>

<p align="center">
  <img src="assets/posturr_analytics.jpg" width="500" alt="Analytics Dashboard">
</p>

## Features

- **Real-time posture detection** - Uses Apple's Vision framework for body pose and face tracking
- **Progressive screen blur** - Gentle visual reminder that intensifies with worse posture
- **Menu bar controls** - Easy access to settings, calibration, and status from the menu bar
- **Multi-display support** - Works across all connected monitors
- **Privacy-focused** - All processing happens locally on your Mac
- **Lightweight** - Runs as a background app with minimal resource usage
- **Optional Dock visibility** - Show in Dock and Cmd+Tab app switcher when preferred
- **No account required** - No signup, no cloud, no tracking

## Installation

### Homebrew (Recommended)

```bash
brew tap tldev/tap
brew install --cask posturr
```

### Manual Download

1. Download the latest `Posturr-vX.X.X.dmg` or `.zip` from the [Releases](../../releases) page
2. Open the DMG and drag `Posturr.app` to your Applications folder
3. Launch normally - no Gatekeeper warnings (app is signed and notarized)

### Camera Permission

Posturr requires camera access to monitor your posture. When you first launch the app, macOS will ask for permission. Click "OK" to grant access.

If you accidentally denied permission, you can grant it later:
1. Open **System Settings** > **Privacy & Security** > **Camera**
2. Find Posturr and enable the toggle

## Usage

Once launched, Posturr appears in your menu bar with a person icon. The app continuously monitors your posture and applies screen blur when slouching is detected.

### Menu Bar Controls

Click the menu bar icon to access:

- **Status** - Shows current state (Monitoring, Slouching, Good Posture, etc.)
- **Enabled** - Toggle posture monitoring on/off
- **Recalibrate** - Reset your baseline posture (sit up straight, then click)
- **Settings** - Open the settings window to configure all options
- **Quit** - Exit the application

### Settings Window

The Settings window (accessible from the menu bar) provides:

- **Sensitivity** - Adjust how sensitive the slouch detection is (5 levels from Low to Very High)
- **Dead Zone** - Set the tolerance before blur kicks in (5 levels from None to Very Large)
- **Blur when away** - Blur screen when you step away from camera
- **Show in dock** - Show app in Dock and Cmd+Tab app switcher
- **Pause on the go** - Auto-pause when laptop display becomes the only screen
- **Compatibility mode** - Use public macOS APIs for blur (try this if blur doesn't appear)

### Tips for Best Results

- Position your camera at eye level when possible
- Ensure adequate lighting on your face
- Sit at a consistent distance from your screen
- The app works best when your shoulders are visible

## How It Works

Posturr uses Apple's Vision framework to detect body pose landmarks:

1. **Body Pose Detection**: Tracks nose, shoulders, and their relative positions
2. **Face Detection Fallback**: When full body isn't visible, tracks face position
3. **Posture Analysis**: Measures the vertical distance between nose and shoulders
4. **Blur Response**: Applies screen blur proportional to posture deviation

The screen blur uses macOS's private CoreGraphics API by default for efficient, system-level blur. If the blur doesn't appear on your system, enable **Compatibility Mode** from the menu to use `NSVisualEffectView` instead.

## Building from Source

### Requirements

- macOS 13.0 (Ventura) or later
- Xcode Command Line Tools (`xcode-select --install`)

### Build

```bash
git clone https://github.com/tldev/posturr.git
cd posturr
./build.sh
```

The built app will be in `build/Posturr.app`.

### Build Options

```bash
# Standard build
./build.sh

# Build with release archive (.zip)
./build.sh --release
```

### Manual Build

```bash
swiftc -O \
    -framework AppKit \
    -framework AVFoundation \
    -framework Vision \
    -framework CoreImage \
    -o Posturr \
    Sources/*.swift
```

## Known Limitations

- **Camera dependency**: Requires a working camera with adequate lighting
- **Detection accuracy**: Works best with clear view of upper body/face

## Command Interface

Posturr exposes a file-based command interface for external control:

| Command | Description |
|---------|-------------|
| `capture` | Take a photo and analyze pose |
| `blur <0-64>` | Set blur level manually |
| `quit` | Exit the application |

Write commands to `/tmp/posturr-command`. Responses appear in `/tmp/posturr-response`.

## System Requirements

- macOS 13.0 (Ventura) or later
- Camera (built-in or external)
- Approximately 10MB disk space

## Privacy

Posturr processes all video data locally on your Mac. No images or data are ever sent to external servers. The camera feed is used solely for posture detection and is never stored or transmitted.

## License

MIT License - see [LICENSE](LICENSE) for details.

## Project Structure

```
posturr/
├── Sources/
│   ├── main.swift              # App entry point
│   ├── AppDelegate.swift       # Main app coordinator and state machine
│   ├── Models.swift            # Shared types (settings keys, profile data, app state)
│   ├── Persistence.swift       # Settings and profile storage
│   ├── DisplayManager.swift    # Display detection and configuration
│   ├── MenuBar.swift           # Menu bar setup and management
│   ├── SettingsWindow.swift    # SwiftUI settings window
│   ├── CalibrationWindow.swift # Calibration UI
│   └── BlurOverlay.swift       # Screen blur overlay management
├── build.sh                    # Build script
├── release.sh                  # Release automation
└── AppIcon.icns                # App icon
```

## Contributing

Contributions are welcome! Please feel free to submit issues and pull requests.

## Acknowledgments

- Built with Apple's Vision framework for body pose detection
- Uses private CoreGraphics API for blur, with NSVisualEffectView fallback
- Inspired by the need for better posture during long coding sessions

## Linux version

Want this on Linux? See [postured](https://github.com/vadi2/postured).

### Contributors

- [@wklm](https://github.com/wklm) - Compatibility mode implementation
- [@cam-br0wn](https://github.com/cam-br0wn) - Dock/App Switcher visibility toggle
- [@einsteinx2](https://github.com/einsteinx2) - SwiftPM/Xcode support
- [@ssisk](https://github.com/ssisk) - Screen lock pause feature suggestion
- [@gcanyon](https://github.com/gcanyon) - Warning onset delay feature suggestion
- [@javabudd](https://github.com/javabudd) - Analytics dashboard
- [@danielroek](https://github.com/danielroek) - "None" warning style option
