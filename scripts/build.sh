#!/bin/bash
set -e

# Configuration
APP_NAME="ClaudeCodeUsage"
BUNDLE_ID="com.claudecodeusage.app"
VERSION="1.10.4"

# Paths
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/.build"
RELEASE_DIR="$PROJECT_DIR/release"
APP_BUNDLE="$RELEASE_DIR/$APP_NAME.app"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Parse arguments
SIGN=false
NOTARIZE=false
DMG=false
DEBUG=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --sign)
            SIGN=true
            shift
            ;;
        --notarize)
            NOTARIZE=true
            SIGN=true  # Notarization requires signing
            shift
            ;;
        --dmg)
            DMG=true
            shift
            ;;
        --all)
            SIGN=true
            NOTARIZE=true
            DMG=true
            shift
            ;;
        --debug)
            DEBUG=true
            SIGN=true
            shift
            ;;
        *)
            echo "Usage: $0 [--sign] [--notarize] [--dmg] [--all] [--debug]"
            exit 1
            ;;
    esac
done

# Clean and create release directory
log_info "Cleaning release directory..."
rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"

# Build binary
cd "$PROJECT_DIR"

if [ "$DEBUG" = true ]; then
    log_info "Building debug binary for ARM64..."
    swift build -c debug --arch arm64
    BUILD_CONFIG="debug"
else
    log_info "Building release binary..."
    log_info "Building for ARM64..."
    swift build -c release --arch arm64

    log_info "Building for x86_64..."
    swift build -c release --arch x86_64
    BUILD_CONFIG="release"
fi

# Create app bundle structure
log_info "Creating app bundle..."
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

if [ "$DEBUG" = true ]; then
    # Debug: single architecture only (faster builds)
    log_info "Copying debug binary..."
    cp "$BUILD_DIR/arm64-apple-macosx/debug/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
else
    # Release: universal binary
    log_info "Creating universal binary..."
    lipo -create \
        "$BUILD_DIR/arm64-apple-macosx/release/$APP_NAME" \
        "$BUILD_DIR/x86_64-apple-macosx/release/$APP_NAME" \
        -output "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
fi

# Copy Info.plist
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/"

# Copy icon if exists
if [ -f "$PROJECT_DIR/Resources/AppIcon.icns" ]; then
    cp "$PROJECT_DIR/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/"
    log_info "App icon copied"
else
    log_warn "No app icon found at Resources/AppIcon.icns"
fi

# Create PkgInfo
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

log_info "App bundle created at: $APP_BUNDLE"

# Code signing
if [ "$SIGN" = true ]; then
    log_info "Looking for Developer ID certificate..."

    # Find Developer ID Application certificate
    IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)".*/\1/')

    if [ -z "$IDENTITY" ]; then
        log_error "No 'Developer ID Application' certificate found!"
        log_error "Please create one at: https://developer.apple.com/account/resources/certificates/list"
        exit 1
    fi

    log_info "Signing with: $IDENTITY"

    codesign --force --sign "$IDENTITY" \
        --options runtime \
        --entitlements "$PROJECT_DIR/Resources/ClaudeCodeUsage.entitlements" \
        --timestamp \
        "$APP_BUNDLE"

    # Verify signature
    log_info "Verifying signature..."
    codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

    log_info "Code signing complete!"
fi

# Notarization
if [ "$NOTARIZE" = true ]; then
    log_info "Starting notarization..."

    # Check for required environment variables
    if [ -z "$APPLE_ID" ] || [ -z "$APPLE_TEAM_ID" ] || [ -z "$APPLE_APP_PASSWORD" ]; then
        log_error "Notarization requires environment variables:"
        log_error "  APPLE_ID - Your Apple ID email"
        log_error "  APPLE_TEAM_ID - Your Team ID (from developer.apple.com)"
        log_error "  APPLE_APP_PASSWORD - App-specific password"
        log_error ""
        log_error "Example:"
        log_error "  export APPLE_ID='you@email.com'"
        log_error "  export APPLE_TEAM_ID='ABCD1234'"
        log_error "  export APPLE_APP_PASSWORD='xxxx-xxxx-xxxx-xxxx'"
        exit 1
    fi

    # Create zip for notarization
    log_info "Creating zip for notarization..."
    ZIP_PATH="$RELEASE_DIR/$APP_NAME.zip"
    ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"

    # Submit for notarization
    log_info "Submitting to Apple for notarization (this may take a few minutes)..."
    xcrun notarytool submit "$ZIP_PATH" \
        --apple-id "$APPLE_ID" \
        --team-id "$APPLE_TEAM_ID" \
        --password "$APPLE_APP_PASSWORD" \
        --wait

    # Staple the ticket
    log_info "Stapling notarization ticket..."
    xcrun stapler staple "$APP_BUNDLE"

    # Clean up zip
    rm "$ZIP_PATH"

    log_info "Notarization complete!"
fi

# Create DMG
if [ "$DMG" = true ]; then
    log_info "Creating DMG..."

    DMG_PATH="$RELEASE_DIR/$APP_NAME.dmg"
    DMG_TEMP_RW="$RELEASE_DIR/temp_rw.dmg"
    DMG_MOUNT="/tmp/dmg_mount_$$"

    # Calculate size needed (app size + 5MB buffer)
    APP_SIZE=$(du -sm "$APP_BUNDLE" | cut -f1)
    DMG_SIZE=$((APP_SIZE + 5))

    # Create empty read-write DMG (avoids /Volumes permission issues)
    log_info "Creating temporary DMG..."
    hdiutil create -size "${DMG_SIZE}m" -fs HFS+ -volname "$APP_NAME" "$DMG_TEMP_RW"

    # Mount to /tmp (more permissive than /Volumes)
    log_info "Mounting DMG..."
    hdiutil attach "$DMG_TEMP_RW" -mountpoint "$DMG_MOUNT"

    # Copy app and create Applications symlink
    log_info "Copying files..."
    cp -R "$APP_BUNDLE" "$DMG_MOUNT/"
    ln -s /Applications "$DMG_MOUNT/Applications"

    # Unmount
    hdiutil detach "$DMG_MOUNT"

    # Convert to compressed read-only DMG
    log_info "Compressing DMG..."
    hdiutil convert "$DMG_TEMP_RW" -format UDZO -o "$DMG_PATH"

    # Clean up temp DMG
    rm -f "$DMG_TEMP_RW"

    # Sign DMG if we have a certificate
    if [ "$SIGN" = true ]; then
        log_info "Signing DMG..."
        codesign --force --sign "$IDENTITY" "$DMG_PATH"
    fi

    # Notarize DMG if requested
    if [ "$NOTARIZE" = true ]; then
        log_info "Notarizing DMG..."
        xcrun notarytool submit "$DMG_PATH" \
            --apple-id "$APPLE_ID" \
            --team-id "$APPLE_TEAM_ID" \
            --password "$APPLE_APP_PASSWORD" \
            --wait

        xcrun stapler staple "$DMG_PATH"
    fi

    log_info "DMG created at: $DMG_PATH"
fi

# Summary
echo ""
log_info "========== Build Complete =========="
log_info "App Bundle: $APP_BUNDLE"
[ "$SIGN" = true ] && log_info "Signed: Yes"
[ "$NOTARIZE" = true ] && log_info "Notarized: Yes"
[ "$DMG" = true ] && log_info "DMG: $RELEASE_DIR/$APP_NAME.dmg"
echo ""
log_info "To run the app:"
log_info "  open $APP_BUNDLE"
echo ""
