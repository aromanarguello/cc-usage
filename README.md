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

The built app will be at `.build/release/ClaudeUsageTracker`.

## Usage

1. Make sure you're logged into Claude Code (`claude` command)
2. Run the app
3. Click the percentage in the menu bar to see details

## Configuration

Access settings via the dropdown menu:
- **Refresh interval:** 30s / 60s / 120s
- **Launch at login:** Toggle

## License

MIT
