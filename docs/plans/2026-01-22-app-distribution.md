# App Distribution Setup Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Package ClaudeUsageTracker as a properly signed and notarized .app bundle for distribution outside the Mac App Store.

**Architecture:** Create a build script that compiles the Swift package, generates a proper .app bundle with Info.plist and icon, signs it with Developer ID, notarizes with Apple, and optionally creates a DMG for distribution.

**Tech Stack:** Swift Package Manager, codesign, notarytool, hdiutil

---

## Prerequisites (Manual - Do Once)

Before running the build script, you need a "Developer ID Application" certificate:

1. Go to https://developer.apple.com/account/resources/certificates/list
2. Click "+" to create a new certificate
3. Select "Developer ID Application"
4. Follow the instructions to create and download the certificate
5. Double-click the downloaded .cer file to install in Keychain

After installation, verify with:
```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

You should see something like:
```
"Developer ID Application: Your Name (TEAMID)"
```

Also create an app-specific password for notarization:
1. Go to https://appleid.apple.com/account/manage
2. Sign In → App-Specific Passwords → Generate
3. Save the password securely

---

### Task 1: Create App Icon

**Files:**
- Create: `Resources/AppIcon.icns`

**Step 1: Create the Resources directory**

```bash
mkdir -p Resources
```

**Step 2: Create a simple icon using built-in tools**

We'll create a minimal icon. For a professional icon, replace this later with a designed one.

Create a 1024x1024 PNG first (we'll use a simple SF Symbol export or placeholder):

```bash
# Create iconset directory
mkdir -p Resources/AppIcon.iconset

# Create a simple icon using sips (macOS built-in)
# First, create a base 1024x1024 image with text
cat > /tmp/create_icon.py << 'EOF'
from AppKit import NSImage, NSColor, NSFont, NSMakeRect, NSGraphicsContext
from AppKit import NSBitmapImageRep, NSPNGFileType, NSString, NSFontAttributeName
from AppKit import NSForegroundColorAttributeName, NSCenterTextAlignment
from Foundation import NSDictionary
import os

size = 1024
image = NSImage.alloc().initWithSize_((size, size))
image.lockFocus()

# Background - dark rounded rect
NSColor.colorWithRed_green_blue_alpha_(0.1, 0.1, 0.12, 1.0).setFill()
path = NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius_(
    NSMakeRect(0, 0, size, size), size * 0.2, size * 0.2
)
path.fill()

# Text "CC" in orange
attrs = {
    NSFontAttributeName: NSFont.boldSystemFontOfSize_(size * 0.45),
    NSForegroundColorAttributeName: NSColor.orangeColor()
}
text = NSString.stringWithString_("CC")
text_size = text.sizeWithAttributes_(attrs)
x = (size - text_size.width) / 2
y = (size - text_size.height) / 2
text.drawAtPoint_withAttributes_((x, y), attrs)

image.unlockFocus()

# Save as PNG
tiff_data = image.TIFFRepresentation()
bitmap = NSBitmapImageRep.imageRepWithData_(tiff_data)
png_data = bitmap.representationUsingType_properties_(NSPNGFileType, None)
png_data.writeToFile_atomically_("Resources/AppIcon.iconset/icon_512x512@2x.png", True)
print("Created icon_512x512@2x.png")
EOF

python3 /tmp/create_icon.py 2>/dev/null || echo "Python icon creation failed, using fallback"
```

If the Python script fails, create a simple placeholder:

```bash
# Fallback: Download a placeholder or create manually
# For now, we'll handle missing icon gracefully in the build script
```

**Step 3: Generate iconset sizes**

```bash
cd Resources/AppIcon.iconset

# If we have the 1024px icon, generate all sizes
if [ -f icon_512x512@2x.png ]; then
    sips -z 512 512   icon_512x512@2x.png --out icon_512x512.png
    sips -z 256 256   icon_512x512@2x.png --out icon_256x256@2x.png
    sips -z 256 256   icon_512x512@2x.png --out icon_256x256.png
    sips -z 128 128   icon_512x512@2x.png --out icon_128x128@2x.png
    sips -z 128 128   icon_512x512@2x.png --out icon_128x128.png
    sips -z 64 64     icon_512x512@2x.png --out icon_32x32@2x.png
    sips -z 32 32     icon_512x512@2x.png --out icon_32x32.png
    sips -z 32 32     icon_512x512@2x.png --out icon_16x16@2x.png
    sips -z 16 16     icon_512x512@2x.png --out icon_16x16.png
fi

cd ../..
```

**Step 4: Convert iconset to icns**

```bash
iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
```

**Step 5: Commit**

```bash
git add Resources/
git commit -m "feat: add app icon resources"
```

---

### Task 2: Create Entitlements File

**Files:**
- Create: `Resources/ClaudeUsageTracker.entitlements`

**Step 1: Create the entitlements file**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- Allow network access for API calls -->
    <key>com.apple.security.network.client</key>
    <true/>

    <!-- Hardened runtime exceptions for notarization -->
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
    <false/>

    <!-- Note: We do NOT enable app-sandbox because we need cross-app Keychain access -->
</dict>
</plist>
```

**Step 2: Commit**

```bash
git add Resources/ClaudeUsageTracker.entitlements
git commit -m "feat: add entitlements for code signing"
```

---

### Task 3: Create Info.plist Template

**Files:**
- Create: `Resources/Info.plist`

**Step 1: Create Info.plist**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>

    <key>CFBundleExecutable</key>
    <string>ClaudeUsageTracker</string>

    <key>CFBundleIconFile</key>
    <string>AppIcon</string>

    <key>CFBundleIdentifier</key>
    <string>com.yourname.ClaudeUsageTracker</string>

    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>

    <key>CFBundleName</key>
    <string>Claude Usage Tracker</string>

    <key>CFBundleDisplayName</key>
    <string>Claude Usage Tracker</string>

    <key>CFBundlePackageType</key>
    <string>APPL</string>

    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>

    <key>CFBundleVersion</key>
    <string>1</string>

    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>

    <key>LSUIElement</key>
    <true/>

    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026. All rights reserved.</string>

    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
```

**Step 2: Commit**

```bash
git add Resources/Info.plist
git commit -m "feat: add Info.plist for app bundle"
```

---

### Task 4: Create Build Script

**Files:**
- Create: `scripts/build.sh`

**Step 1: Create scripts directory and build script**

```bash
#!/bin/bash
set -e

# Configuration
APP_NAME="ClaudeUsageTracker"
BUNDLE_ID="com.yourname.ClaudeUsageTracker"
VERSION="1.0.0"

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
        --entitlements "$PROJECT_DIR/Resources/ClaudeUsageTracker.entitlements" \
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
```

**Step 2: Make script executable**

```bash
mkdir -p scripts
chmod +x scripts/build.sh
```

**Step 3: Commit**

```bash
git add scripts/
git commit -m "feat: add build script for app distribution"
```

---

### Task 5: Create Makefile for Convenience

**Files:**
- Create: `Makefile`

**Step 1: Create Makefile**

```makefile
.PHONY: build run clean release sign notarize dmg all

# Development
build:
	swift build

run: build
	.build/debug/ClaudeUsageTracker

clean:
	rm -rf .build release

# Release
release:
	./scripts/build.sh

sign:
	./scripts/build.sh --sign

notarize:
	./scripts/build.sh --notarize

dmg:
	./scripts/build.sh --sign --dmg

# Full distribution build (sign + notarize + dmg)
all:
	./scripts/build.sh --all

# Open the built app
open-app:
	open release/ClaudeUsageTracker.app

# Help
help:
	@echo "Available targets:"
	@echo "  make build     - Build debug version"
	@echo "  make run       - Build and run debug version"
	@echo "  make clean     - Remove build artifacts"
	@echo "  make release   - Build release .app bundle (unsigned)"
	@echo "  make sign      - Build and sign .app bundle"
	@echo "  make notarize  - Build, sign, and notarize .app bundle"
	@echo "  make dmg       - Build signed .app and create DMG"
	@echo "  make all       - Full distribution build (sign + notarize + dmg)"
	@echo ""
	@echo "For notarization, set these environment variables:"
	@echo "  export APPLE_ID='your@email.com'"
	@echo "  export APPLE_TEAM_ID='YOURTEAMID'"
	@echo "  export APPLE_APP_PASSWORD='xxxx-xxxx-xxxx-xxxx'"
```

**Step 2: Commit**

```bash
git add Makefile
git commit -m "feat: add Makefile for build convenience"
```

---

### Task 6: Update .gitignore

**Files:**
- Modify: `.gitignore`

**Step 1: Add release directory to gitignore**

Append to `.gitignore`:

```
# Release artifacts
release/
*.dmg

# Icon generation temp files
*.iconset/
```

**Step 2: Commit**

```bash
git add .gitignore
git commit -m "chore: update gitignore for release artifacts"
```

---

### Task 7: Update README with Distribution Instructions

**Files:**
- Modify: `README.md`

**Step 1: Add distribution section to README**

Add at the end of README.md:

```markdown
## Distribution

### Building for Release

```bash
# Simple release build (unsigned)
make release

# Signed build (requires Developer ID certificate)
make sign

# Full distribution with notarization
export APPLE_ID='your@email.com'
export APPLE_TEAM_ID='YOUR_TEAM_ID'
export APPLE_APP_PASSWORD='xxxx-xxxx-xxxx-xxxx'
make all
```

### Prerequisites for Signing

1. **Developer ID Application certificate** from [Apple Developer](https://developer.apple.com/account/resources/certificates/list)
2. **App-specific password** from [Apple ID](https://appleid.apple.com/account/manage) (for notarization)

### Build Outputs

| Command | Output |
|---------|--------|
| `make release` | `release/ClaudeUsageTracker.app` (unsigned) |
| `make sign` | `release/ClaudeUsageTracker.app` (signed) |
| `make all` | `release/ClaudeUsageTracker.app` + `release/ClaudeUsageTracker-1.0.0.dmg` (notarized) |
```

**Step 2: Commit**

```bash
git add README.md
git commit -m "docs: add distribution instructions to README"
```

---

## Summary

After completing all tasks, you'll have:

```
cc-usage/
├── Makefile                    # Easy build commands
├── Resources/
│   ├── AppIcon.icns           # App icon
│   ├── AppIcon.iconset/       # Icon source files
│   ├── ClaudeUsageTracker.entitlements
│   └── Info.plist
├── scripts/
│   └── build.sh               # Main build script
└── release/                   # Build output (gitignored)
    ├── ClaudeUsageTracker.app
    └── ClaudeUsageTracker-1.0.0.dmg
```

**Quick Commands:**
- `make run` - Build and run locally
- `make sign` - Create signed .app
- `make all` - Full notarized DMG for distribution
