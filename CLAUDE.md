# Claude Code Instructions for Posturr

## Releasing

### GitHub Release (Direct Distribution)
Always use the release script for GitHub releases:
```bash
./release.sh 1.0.X
```

This script handles:
- Building the app
- Code signing with Developer ID
- Apple notarization
- DMG creation with drag-to-Applications
- ZIP archive
- Git tagging
- GitHub release creation

**Never manually create GitHub releases** - the script ensures proper signing and notarization.

### After Running release.sh
The script creates generic release notes. **You must update them** with specific changes using:
```bash
gh release edit vX.Y.Z --notes "$(cat <<'EOF'
## What's New

### Bug Fix (or Feature, Improvement, etc.)
- **Short title** - Description of what changed and why it matters.

### Also in this release
- Any other notable points

## Installation

1. Download `Posturr-vX.Y.Z.dmg` or `Posturr-vX.Y.Z.zip`
2. Drag `Posturr.app` to Applications
3. Launch normally - no warnings!
4. Grant camera permission and complete calibration

## Requirements
- macOS 13.0 (Ventura) or later
EOF
)"
```

**Writing good release notes:**
- Keep it simple and user-focused - describe the benefit, not the implementation
- Avoid technical jargon (e.g., "brandCyan color" → "consistent styling")
- Don't repeat commit messages verbatim - synthesize changes into what users care about
- One clear sentence is better than a list of technical details
- Example: "Consistent styling across Settings and Analytics windows" instead of "Redesigned analytics window with brand-consistent styling, replaced shadows with borders, updated color scheme"

### Acknowledgments
When implementing features or fixes from GitHub issues, always give credit to the person who suggested it:
- In the GitHub release notes: "Thanks to @username for suggesting this!"
- In CHANGELOG.md: Add an `### Acknowledgments` section with a link to their GitHub profile
- In README.md: Add them to the Contributors section with a brief description of their contribution
- Comment on the issue thanking them and linking to the release

Note: Issues auto-close when referenced with "Closes #N" in commit messages. If you try to close an issue and it's already closed, just add a thank-you comment instead.

### Update CHANGELOG.md
After updating the GitHub release notes, also update `CHANGELOG.md` with a new entry:
- Add the new version section at the top (after the header)
- Use Keep a Changelog format with `### Added`, `### Changed`, `### Fixed` sections as appropriate
- Include the release date in YYYY-MM-DD format
- Commit and push the changelog update

### Update Homebrew Cask
After each GitHub release, update the Homebrew tap at https://github.com/tldev/homebrew-tap:

```bash
# Get the SHA256 of the new release ZIP
gh release view vX.Y.Z --repo tldev/posturr --json assets --jq '.assets[] | select(.name | endswith(".zip")) | .digest'

# Clone via SSH (required for push), update, and push
cd /tmp && rm -rf homebrew-tap && git clone git@github.com:tldev/homebrew-tap.git
cd homebrew-tap

# Edit Casks/posturr.rb - update version and sha256
# version "X.Y.Z"
# sha256 "<new-sha256-without-sha256:-prefix>"

git add . && git commit -m "Update Posturr to vX.Y.Z" && git push
```

### App Store Release
For App Store submissions, run these steps after the GitHub release:

```bash
cd /Users/tjohnell/projects/posturr

# 1. Build for App Store (excludes private APIs)
./build.sh --appstore

# 2. Copy to appstore folder and sign
rm -rf build-appstore/Posturr.app
cp -r build/Posturr.app build-appstore/
cd build-appstore

codesign --force --options runtime \
    --entitlements Posturr.entitlements \
    --sign "Apple Distribution: Thomas Johnell (KBF2YGT2KP)" \
    --timestamp \
    Posturr.app

# 3. Create installer package
rm -f Posturr.pkg
productbuild \
    --component Posturr.app /Applications \
    --sign "3rd Party Mac Developer Installer: Thomas Johnell (KBF2YGT2KP)" \
    Posturr.pkg

# 4. Upload (ask user for app-specific password)
xcrun altool --upload-app -f Posturr.pkg -t macos -u tjohnell@gmail.com -p APP_SPECIFIC_PASSWORD
```

**Important:** The upload requires an app-specific password from appleid.apple.com. Ask the user to provide it when uploading - do not store it in files.

After upload:
1. Go to App Store Connect → App Store tab
2. Select the version (e.g., "1.0 Prepare for Submission")
3. Scroll to Build section → click + → select the new build
4. Answer Export Compliance: "No" (no encryption)
5. Save → Add for Review → Submit to App Review

## Build Configurations

- `./build.sh` - Regular build with private APIs (for GitHub/direct distribution)
- `./build.sh --appstore` - App Store build without private APIs
- `./build.sh --release` - Regular build + creates ZIP archive

## Installing During Development

**Always kill the existing process and remove old app before installing:**
```bash
pkill -x Posturr; rm -rf /Applications/Posturr.app && cp -r build/Posturr.app /Applications/
```

This prevents file locking issues and permission errors from code signing.

## Workflow for Bug Fixes and Features

**IMPORTANT: Never commit or push until the user explicitly asks you to.** After making changes:
1. Build and install the app
2. Wait for the user to test
3. Only commit when the user confirms it works or explicitly asks to commit

**Never comment on GitHub issues** until the user explicitly asks you to. The user will handle acknowledgments and issue comments.

## Version Bumping

Update version in `build.sh` (VERSION variable) before releasing.

## Key Files

### Source Code (in `Sources/`)
- `main.swift` - App entry point
- `AppDelegate.swift` - Main app coordinator, state machine, camera capture, posture detection
- `Models.swift` - Shared types (SettingsKeys, ProfileData, PauseReason, AppState)
- `Persistence.swift` - SettingsStorage and ProfileStorage classes
- `DisplayManager.swift` - Display UUID detection and configuration change handling
- `MenuBar.swift` - MenuBarManager for status bar setup
- `SettingsWindow.swift` - SwiftUI settings window with SettingsWindowController
- `CalibrationWindow.swift` - Calibration UI with pulsing ring animation
- `BlurOverlay.swift` - Private API loading and BlurOverlayManager

### Build & Release
- `build.sh` - Build script with App Store support
- `release.sh` - Full GitHub release automation
- `PRIVACY.md` - Privacy policy for App Store

## UI/UX Branding Guidelines

### Brand Colors
```swift
extension Color {
    static let brandCyan = Color(red: 0.31, green: 0.82, blue: 0.77)  // #4fd1c5 - from app icon
    static let brandNavy = Color(red: 0.10, green: 0.15, blue: 0.27)  // #1a2744 - from app icon
}
```

### Design Principles
- **Brand connection**: Use `brandCyan` for accents (sliders, toggles, selected states, buttons)
- **No system blue**: Replace default macOS blue with brand cyan
- **Subtle, not loud**: Use `.opacity(0.1)` to `.opacity(0.3)` for backgrounds/borders

### Window Layout
- Use `sizeThatFits` for auto-sizing windows to content
- Fixed width with auto height: `.frame(width: 640).fixedSize(horizontal: false, vertical: true)`
- Standard padding: `.padding(24)`

### Section Cards (SectionCard component)
- Rounded containers: `cornerRadius: 10`
- Background: `Color(NSColor.controlBackgroundColor)`
- Subtle border: `Color.primary.opacity(0.06)`
- Section header: Icon (brandCyan) + title (12pt semibold)
- Internal spacing: 12-14pt between items

### Typography
- Window title: 22pt semibold
- Section headers: 12pt semibold with SF Symbol icon
- Labels: 13pt regular
- Help text: 12pt in popovers
- Slider labels: 10-11pt secondary color

### Controls
- **Segmented pickers**: Custom `WarningStylePicker` with brandCyan selected state
- **Toggles**: `.tint(.brandCyan)`
- **Sliders**: `.tint(.brandCyan)` with value badge (pill with cyan background at 12% opacity)
- **Buttons**: brandCyan text/icon with 10% cyan background, 30% cyan border
- **Help icons**: `questionmark.circle` at 11pt, secondary color at 60% opacity

### Value Badges (for sliders)
```swift
Text(value)
    .font(.system(size: 12, weight: .medium))
    .foregroundColor(.brandCyan)
    .padding(.horizontal, 10)
    .padding(.vertical, 3)
    .background(Capsule().fill(Color.brandCyan.opacity(0.12)))
```

### Dividers
Use `SubtleDivider`: `Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)`

### Header Pattern
- App icon (52x52 with subtle shadow)
- App name (22pt semibold) + tagline (12pt secondary)
- Social links (GitHub/Discord icons, 16x16, secondary color at 70% opacity)
- Version badge (11pt medium in capsule with 5% primary background)

### Social Icons
- Use official SVG paths from Simple Icons (GitHubIcon, DiscordIcon structs in SettingsWindow.swift)
- Add `.onHover` with `NSCursor.pointingHand` for pointer cursor
- Wrap in Link with `.contentShape(Rectangle())` for larger hit area

### Reference Implementation
See `SettingsWindow.swift` for the complete branded implementation.
