#!/bin/bash
set -e

# Configuration
APP_NAME="ClaudeCodeUsage"
BUNDLE_ID="com.claudeusagetracker.app"
VERSION="1.5.0"

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
        *)
            echo "Usage: $0 [--sign] [--notarize] [--dmg] [--all]"
            exit 1
            ;;
    esac
done

# Clean and create release directory
log_info "Cleaning release directory..."
rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"

# Build release binary
log_info "Building release binary..."
cd "$PROJECT_DIR"
swift build -c release

# Create app bundle structure
log_info "Creating app bundle..."
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy binary
cp "$BUILD_DIR/release/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/"

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

    DMG_PATH="$RELEASE_DIR/$APP_NAME-$VERSION.dmg"
    DMG_TEMP="$RELEASE_DIR/dmg_temp"

    # Create temp directory for DMG contents
    mkdir -p "$DMG_TEMP"
    cp -R "$APP_BUNDLE" "$DMG_TEMP/"

    # Create symlink to Applications
    ln -s /Applications "$DMG_TEMP/Applications"

    # Create DMG
    hdiutil create -volname "$APP_NAME" \
        -srcfolder "$DMG_TEMP" \
        -ov -format UDZO \
        "$DMG_PATH"

    # Clean up
    rm -rf "$DMG_TEMP"

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
[ "$DMG" = true ] && log_info "DMG: $RELEASE_DIR/$APP_NAME-$VERSION.dmg"
echo ""
log_info "To run the app:"
log_info "  open $APP_BUNDLE"
echo ""
