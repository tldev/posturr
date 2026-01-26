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

The release notes should describe what changed since the previous version, not generic feature lists.

### Update Homebrew Cask
After each GitHub release, update the Homebrew tap at https://github.com/tldev/homebrew-tap:

```bash
# Get the SHA256 of the new release ZIP
gh release view vX.Y.Z --repo tldev/posturr --json assets --jq '.assets[] | select(.name | endswith(".zip")) | .digest'

# Clone, update, and push
cd /tmp && rm -rf homebrew-tap && gh repo clone tldev/homebrew-tap
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

## Version Bumping

Update version in `build.sh` (VERSION variable) before releasing.

## Key Files

- `main.swift` - All application code
- `build.sh` - Build script with App Store support
- `release.sh` - Full GitHub release automation
- `PRIVACY.md` - Privacy policy for App Store
