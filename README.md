# Claude Usage Tracker

A native macOS menu bar app for tracking Claude Code usage limits in real-time.

## Features

- Shows 5-hour usage window percentage in menu bar
- Glass-morphic dropdown with detailed usage breakdown
- Weekly usage tracking
- Automatic polling with configurable intervals
- Launch at login support

## Requirements

- macOS 14.0+ (Sonoma)
- Claude Code CLI installed and authenticated

## Building

```bash
swift build -c release
```

The built app will be at `.build/release/ClaudeCodeUsage`.

## Usage

1. Make sure you're logged into Claude Code (`claude` command)
2. Run the app
3. Click the percentage in the menu bar to see details

## Configuration

Access settings via the dropdown menu:
- **Refresh interval:** 30s / 60s / 120s
- **Launch at login:** Toggle

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
| `make release` | `release/ClaudeCodeUsage.app` (unsigned) |
| `make sign` | `release/ClaudeCodeUsage.app` (signed) |
| `make all` | `release/ClaudeCodeUsage.app` + `release/ClaudeCodeUsage-1.0.0.dmg` (notarized) |

## License

MIT
