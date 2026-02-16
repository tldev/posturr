#!/bin/bash

# Dorso Build Script
# Compiles the app and creates the app bundle
#
# Usage:
#   ./build.sh              # Build with private APIs (GitHub release)
#   ./build.sh --appstore   # Build for App Store (no private APIs)
#   ./build.sh --release    # Build with private APIs and create release archive

set -e

# Configuration
APP_NAME="Dorso"
BUNDLE_ID="com.thelazydeveloper.posturr"
VERSION="1.9.0"
BUILD_NUMBER="1"
MIN_MACOS="13.0"

# Check for App Store build flag
APP_STORE_BUILD=false
SWIFT_FLAGS=""
if [[ "$*" == *"--appstore"* ]]; then
    APP_STORE_BUILD=true
    SWIFT_FLAGS="-D APP_STORE"
    echo "Building for App Store (no private APIs)..."
fi

# Directories
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}Building $APP_NAME v$VERSION${NC}"
echo ""

# Clean previous build
if [ -d "$BUILD_DIR" ]; then
    echo "Cleaning previous build..."
    rm -rf "$BUILD_DIR"
fi

# Create directory structure
echo "Creating app bundle structure..."
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

# Compile Swift code
echo "Compiling Swift sources..."
echo "Building universal binary (arm64 + x86_64)..."

# Get all Swift source files
SOURCES_DIR="$SCRIPT_DIR/Sources"
SWIFT_FILES=$(find "$SOURCES_DIR" -name "*.swift" -type f | sort)

echo "Source files:"
for f in $SWIFT_FILES; do
    echo "  - $(basename "$f")"
done
echo ""

swiftc \
    -O \
    -whole-module-optimization \
    $SWIFT_FLAGS \
    -target arm64-apple-macos$MIN_MACOS \
    -sdk $(xcrun --show-sdk-path) \
    -framework AppKit \
    -framework AVFoundation \
    -framework Vision \
    -framework CoreImage \
    -framework CoreMotion \
    -framework IOBluetooth \
    -o "$MACOS_DIR/${APP_NAME}_arm64" \
    $SWIFT_FILES

swiftc \
    -O \
    -whole-module-optimization \
    $SWIFT_FLAGS \
    -target x86_64-apple-macos$MIN_MACOS \
    -sdk $(xcrun --show-sdk-path) \
    -framework AppKit \
    -framework AVFoundation \
    -framework Vision \
    -framework CoreImage \
    -framework CoreMotion \
    -framework IOBluetooth \
    -o "$MACOS_DIR/${APP_NAME}_x86" \
    $SWIFT_FILES

# Create universal binary
lipo -create -output "$MACOS_DIR/$APP_NAME" \
    "$MACOS_DIR/${APP_NAME}_arm64" \
    "$MACOS_DIR/${APP_NAME}_x86"

# Clean up
rm "$MACOS_DIR/${APP_NAME}_arm64" "$MACOS_DIR/${APP_NAME}_x86"

# Create Info.plist
echo "Creating Info.plist..."
cat > "$CONTENTS/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>$MIN_MACOS</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.healthcare-fitness</string>
    <key>NSCameraUsageDescription</key>
    <string>Dorso needs camera access to monitor your posture and blur the screen when you slouch.</string>
    <key>NSMotionUsageDescription</key>
    <string>Dorso needs access to motion data to monitor your posture using AirPods.</string>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>Dorso uses Bluetooth to detect paired AirPods for head motion tracking.</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>es</string>
        <string>fr</string>
        <string>de</string>
        <string>ja</string>
        <string>zh-Hans</string>
    </array>
</dict>
</plist>
EOF

# Compile app icon
# Priority: .icon file (Icon Composer) > .icns file > .iconset folder
if [ -f "$SCRIPT_DIR/AppIcon.icon/icon.json" ]; then
    echo "Compiling Icon Composer icon..."
    xcrun actool "$SCRIPT_DIR/AppIcon.icon" \
        --compile "$RESOURCES_DIR" \
        --app-icon AppIcon \
        --platform macosx \
        --minimum-deployment-target 13.0 \
        --include-all-app-icons \
        --output-partial-info-plist /dev/null \
        --output-format human-readable-text > /dev/null 2>&1
elif [ -f "$SCRIPT_DIR/AppIcon.icns" ]; then
    echo "Copying app icon..."
    cp "$SCRIPT_DIR/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
elif [ -d "$SCRIPT_DIR/Dorso.iconset" ]; then
    echo "Converting iconset to icns..."
    iconutil -c icns -o "$RESOURCES_DIR/AppIcon.icns" "$SCRIPT_DIR/Dorso.iconset"
else
    echo -e "${YELLOW}Warning: No app icon found. The app will use default icon.${NC}"
fi

# Copy custom menu bar icons if they exist
if [ -d "$SOURCES_DIR/Icons" ]; then
    echo "Copying custom menu bar icons..."
    mkdir -p "$RESOURCES_DIR/Icons"
    cp "$SOURCES_DIR/Icons"/*.pdf "$RESOURCES_DIR/Icons/" 2>/dev/null || true
fi

# Copy localization resources
if [ -d "$SOURCES_DIR/Resources" ]; then
    echo "Copying localization resources..."
    for lproj in "$SOURCES_DIR/Resources"/*.lproj; do
        if [ -d "$lproj" ]; then
            cp -r "$lproj" "$RESOURCES_DIR/"
        fi
    done
fi

# Embed provisioning profile for App Store builds
if [ "$APP_STORE_BUILD" = true ]; then
    PROFILE_PATH="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/ee9bedd9-b6fa-4db7-b698-21a632a945e9.provisionprofile"
    if [ -f "$PROFILE_PATH" ]; then
        echo "Embedding provisioning profile..."
        cp "$PROFILE_PATH" "$CONTENTS/embedded.provisionprofile"
    else
        echo -e "${RED}Error: App Store provisioning profile not found at:${NC}"
        echo "  $PROFILE_PATH"
        echo "Download it from the Apple Developer portal."
        exit 1
    fi
fi

# Create entitlements file
echo "Creating entitlements..."
if [ "$APP_STORE_BUILD" = true ]; then
    # App Store entitlements (requires App Sandbox)
    cat > "$BUILD_DIR/Dorso.entitlements" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.device.camera</key>
    <true/>
    <key>com.apple.security.device.bluetooth</key>
    <true/>
    <key>com.apple.application-identifier</key>
    <string>KBF2YGT2KP.$BUNDLE_ID</string>
    <key>com.apple.developer.team-identifier</key>
    <string>KBF2YGT2KP</string>
</dict>
</plist>
EOF
else
    # Direct distribution entitlements (hardened runtime, no sandbox)
    cat > "$BUILD_DIR/Dorso.entitlements" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.camera</key>
    <true/>
</dict>
</plist>
EOF
fi

# Set executable permission
chmod +x "$MACOS_DIR/$APP_NAME"

# Ad-hoc sign the app bundle for macOS Gatekeeper compatibility
echo "Signing app bundle..."
codesign --force --deep --sign - "$APP_BUNDLE"

# Verify the build
echo ""
echo "Verifying build..."
if [ -f "$MACOS_DIR/$APP_NAME" ]; then
    echo -e "${GREEN}Build successful!${NC}"
    echo ""
    echo "App bundle: $APP_BUNDLE"
    echo "Size: $(du -sh "$APP_BUNDLE" | cut -f1)"

    # Show architecture info
    echo "Architectures: $(lipo -archs "$MACOS_DIR/$APP_NAME")"
    echo ""

    # Optional: create release zip
    if [ "$1" == "--release" ]; then
        echo "Creating release archive..."
        RELEASE_NAME="$APP_NAME-v$VERSION.zip"
        cd "$BUILD_DIR"
        zip -r -q "$RELEASE_NAME" "$APP_NAME.app"
        echo -e "${GREEN}Release archive created: $BUILD_DIR/$RELEASE_NAME${NC}"
    fi
else
    echo -e "${RED}Build failed!${NC}"
    exit 1
fi

echo ""
echo "To run the app:"
echo "  open $APP_BUNDLE"
echo ""
echo "To install:"
echo "  cp -r $APP_BUNDLE /Applications/"
