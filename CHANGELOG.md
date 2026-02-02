# Changelog

All notable changes to Posturr will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.5.4] - 2026-02-02

### Fixed
- Settings window being cut off on first open
- Cmd+W now properly closes Settings and Analytics windows

### Changed
- More compact Settings UI that fits better on smaller screens

## [1.5.3] - 2026-02-01

### Fixed
- Menu bar icon flickering between states during posture monitoring

### Changed
- Major code refactoring for improved testability and maintainability
- Added 44 unit tests covering core posture detection logic

## [1.5.2] - 2026-01-31

### Added
- Custom menu bar icons - seated figure icons that better represent posture states (good, bad, away, paused, calibrating)

### Changed
- Renamed "Statistics" to "Analytics" in menu
- Renamed "Enabled" to "Enable" with standard macOS shortcut display
- Disabled state now shows the paused icon for consistency

## [1.5.1] - 2026-01-31

### Added
- Forward-head posture detection (turtle neck) - tracks face size to detect when you move your head closer to the screen

### Acknowledgments
- Thanks to [@kimik-hyum](https://github.com/kimik-hyum) for implementing this feature!

## [1.5.0] - 2026-01-31

### Added
- AirPods motion tracking as an alternative to camera-based posture detection
  - Uses head motion sensors in AirPods Pro, Max, or 3rd generation+
  - Requires macOS 14.0 (Sonoma) or later
  - Automatically pauses when AirPods are removed from ears
- New onboarding flow to choose between Camera and AirPods tracking
- Switch tracking methods anytime from Settings without losing calibration data

### Fixed
- Leaning head backward no longer incorrectly triggers poor posture warning

### Acknowledgments
- Thanks to [@kimik-hyum](https://github.com/kimik-hyum) for contributing AirPods motion tracking!

## [1.4.8] - 2026-01-30

### Added
- Solid color warning style - fills the entire screen with a solid color overlay for a more aggressive visual cue

### Acknowledgments
- Thanks to [@karlmolina](https://github.com/karlmolina) for contributing this feature!

## [1.4.7] - 2026-01-29

### Added
- Detection mode slider to balance responsiveness vs battery life
  - **Responsive**: 10 fps (~14% CPU)
  - **Balanced**: 4 fps (~8% CPU) - new default
  - **Performance**: 2 fps (~7% CPU)
- Smart recovery: automatically boosts to 10 fps when slouching for instant feedback

### Changed
- All modes use optimized low resolution (352x288) for CPU efficiency
- Camera hardware frame rate is now configured directly (not just software throttling)

### Acknowledgments
- Thanks to [@cam-br0wn](https://github.com/cam-br0wn) for the original idea in [PR #24](https://github.com/tldev/posturr/pull/24)!

## [1.4.6] - 2026-01-29

### Fixed
- Pause-on-the-go no longer triggers incorrectly when using the keyboard shortcut to re-enable posture monitoring

## [1.4.5] - 2026-01-29

### Added
- Global keyboard shortcut to toggle Posturr on/off from anywhere (default: ⌃⌥P)
- Shortcut is fully customizable in Settings → Behavior
- Uses Carbon API - no Accessibility permission required

### Acknowledgments
- Thanks to [@gcanyon](https://github.com/gcanyon) for suggesting this feature!

## [1.4.4] - 2026-01-29

### Fixed
- Blur now clears when disabling Posturr while the screen is blurred

### Acknowledgments
- Thanks to [@omyno](https://github.com/omyno) for reporting this issue!

## [1.4.3] - 2026-01-27

### Changed
- Consistent styling across Settings and Analytics windows

## [1.4.2] - 2025-01-27

### Added
- "None" warning style - disable visual warnings while keeping posture detection and statistics active

### Fixed
- "Blur when away" privacy feature now works correctly when warning style is set to None

### Acknowledgments
- Thanks to [@danielroek](https://github.com/danielroek) for suggesting and implementing this feature!

## [1.4.1] - 2026-01-27

### Fixed
- Slouch event over-counting when warning delay is enabled - statistics now correctly record one event per slouch
- "Blur when away" now always uses actual blur for privacy, regardless of warning style (Border/Vignette)

### Changed
- Refactored warning system to cleanly separate privacy blur from posture warnings

### Acknowledgments
- Thanks to [@4elovel](https://github.com/4elovel) for reporting the statistics over-counting issue!
- Thanks to [@slaiyer](https://github.com/slaiyer) for reporting the blur-when-away behavior!

## [1.4.0] - 2026-01-26

### Added
- Analytics dashboard with posture statistics (Menu → Statistics)
- Daily posture score with visual ring chart
- 7-day trend bar chart showing improvement over time
- Detailed metrics: monitoring time, slouch duration, slouch count
- Persistent storage preserves history across app restarts

### Acknowledgments
- Thanks to [@javabudd](https://github.com/javabudd) for this contribution!

## [1.3.0] - 2026-01-26

### Added
- Configurable warning onset delay (0-30 seconds) - grace period before warning activates
- Allows brief glances at keyboard without triggering warning

### Acknowledgments
- Thanks to [@gcanyon](https://github.com/gcanyon) for suggesting this feature!

## [1.2.2] - 2026-01-26

### Added
- Auto-pause when screen locks - camera stops when Mac is locked, resumes on unlock
- Addresses privacy concern: webcam light now turns off when computer is locked

### Acknowledgments
- Thanks to [@ssisk](https://github.com/ssisk) for suggesting this privacy enhancement!

## [1.2.1] - 2026-01-26

### Changed
- Blur now starts at zero intensity at deadzone boundary for smoother entry
- Near-instant overlay fade-out when returning to good posture
- Widened deadzone range (0% to 40%) for more noticeable impact between settings
- Shifted intensity values gentler overall with wider spread

## [1.2.0] - 2026-01-26

### Added
- Alternative warning styles: Vignette and Border modes in addition to Blur
- Vignette mode: Red glow that creeps in from screen edges (like video game damage)
- Border mode: Red gradient borders on all four screen edges
- Customizable warning color picker for Vignette and Border modes
- Warning Style selector in Settings with Blur/Vignette/Border options

### Changed
- Refactored overlay system with new WarningOverlay.swift module
- Centralized warning color constant for consistency

### Acknowledgments
- Thanks to [@jonocairns](https://github.com/jonocairns) for suggesting the screen border alternative to blur!

## [1.1.1] - 2026-01-26

### Changed
- Redesigned posture settings with clearer "dead zone" and "intensity" controls
- Dead Zone (Strict → Relaxed): How much you can move before blur starts
- Intensity (Gentle → Aggressive): How quickly blur ramps up past the dead zone
- Added info icons with helpful tooltips explaining each setting

### Fixed
- Fixed backwards math where "high sensitivity" was actually less responsive

## [1.1.0] - 2026-01-26

### Added
- New dedicated Settings window with modern two-column layout
- Discrete sliders for Sensitivity and Dead Zone with 5 preset levels
- Info icons with helpful tooltips explaining each setting

### Changed
- Settings moved from menu bar submenus into Settings window
- Cleaner menu bar now shows only Status, Enable, Recalibrate, Settings, and Quit
- Refactored monolithic main.swift into modular source files

## [1.0.14] - 2026-01-26

### Added
- Optional Dock visibility toggle to show Posturr in Dock and Cmd+Tab switcher
- When enabled, Cmd+Tab to Posturr automatically opens the menu dropdown

### Changed
- Updated app icon with proper macOS formatting (rounded corners, padding)

### Acknowledgments
- Thanks to [@cam-br0wn](https://github.com/cam-br0wn) for this contribution!

## [1.0.13] - 2026-01-26

### Added
- Profile-based state machine with automatic profile restoration per display configuration
- Smart camera fallback when active camera disconnects
- Diagnostic console logging for debugging camera and state transitions
- Comprehensive PROFILES.md documentation

### Fixed
- "Pause on the Go" now only activates when transitioning to laptop-only mode
- Status shows "Paused (on the go - recalibrate)" to hint about recalibration option

## [1.0.12] - 2026-01-26

### Added
- "Blur When Away" feature for privacy protection when stepping away from desk

### Fixed
- Camera now properly stops when "Enabled" is unchecked

## [1.0.11] - 2026-01-26

### Changed
- Build script now always creates universal binaries regardless of build machine architecture
- Added Package.swift for building and debugging from Xcode via Swift Package Manager

### Acknowledgments
- Thanks to [@cam-br0wn](https://github.com/cam-br0wn) for the universal binary build improvement!
- Thanks to [@einsteinx2](https://github.com/einsteinx2) for adding SwiftPM/Xcode support!

## [1.0.10] - 2026-01-25

### Changed
- Faster blur recovery when returning to good posture while maintaining smooth transitions

## [1.0.9] - 2026-01-25

### Fixed
- Fixed blur transition hang when returning to good posture

### Changed
- Blur begins fading immediately when posture improves
- Smoother visual transitions in Compatibility Mode

## [1.0.8] - 2026-01-25

### Fixed
- Fixed camera permission issue where app would hang on "Requesting camera" without showing permission dialog
- Added required camera entitlement for hardened runtime

## [1.0.7] - 2026-01-25

### Added
- App is now signed and notarized by Apple - no more Gatekeeper warnings
- Just download, drag to Applications, and run!

## [1.0.6] - 2026-01-25

### Added
- Camera selection submenu to choose between available cameras
- External webcam support for USB webcams and other external cameras
- Auto-detection of all connected video devices
- Switching cameras automatically triggers recalibration

## [1.0.5] - 2026-01-25

### Changed
- Significantly reduced CPU usage with frame throttling (~10fps instead of ~30fps)
- Camera uses low resolution (sufficient for pose detection)
- Blur transitions reduced from 60fps to 30fps

## [1.0.4] - 2026-01-25

### Changed
- Inline descriptions for all Sensitivity and Dead Zone options
- Default settings now show as "Medium" in menus
- Added helpful hint text below Compatibility Mode

## [1.0.3] - 2026-01-25

### Added
- Compatibility Mode using NSVisualEffectView for systems where default blur doesn't appear
- Automatic fallback to NSVisualEffectView if private APIs are unavailable

### Acknowledgments
- Thanks to [@wklm](https://github.com/wklm) for the NSVisualEffectView compatibility implementation!

## [1.0.2] - 2026-01-25

### Changed
- Minor release with distribution improvements

## [1.0.1] - 2026-01-24

### Changed
- Minor release with distribution improvements

## [1.0.0] - 2026-01-24

### Added
- Initial release of Posturr
- Real-time posture monitoring using macOS Vision framework
- Screen blur effect that activates when poor posture is detected
- Multi-screen corner calibration for personalized detection
- Progressive blur that eases in gently
- Adjustable sensitivity and dead zone
- Multi-display support for blur overlay
- Camera permission handling with user-friendly prompt
- Universal binary (Apple Silicon + Intel)

### Technical Details
- Uses private CoreGraphics API for efficient window blur
- Runs as a background app (no dock icon by default)
- Supports macOS 13.0 (Ventura) and later
