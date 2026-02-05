# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Claude Usage Tracker is a native macOS menu bar app for tracking Claude Code usage limits. It displays 5-hour and 7-day usage window percentages and provides detailed usage information via a glass-morphic popover.

**Tech Stack:** Swift 6.0, SwiftUI, AppKit (NSStatusBar/NSPopover), macOS 14+

**Zero external dependencies** - uses only Swift stdlib and system frameworks (Security, UserNotifications, ServiceManagement).

## Build Commands

```bash
# Development
make build          # Debug build
make run            # Build and run debug version
make clean          # Remove build artifacts

# Release (outputs to release/)
make release        # Unsigned app bundle
make sign           # Code-signed app
make all            # Full distribution: sign + notarize + DMG

# Open built app
make open-app
```

For notarization, set environment variables:
```bash
export APPLE_ID='your@email.com'
export APPLE_TEAM_ID='YOURTEAMID'
export APPLE_APP_PASSWORD='xxxx-xxxx-xxxx-xxxx'
```

## Credential Troubleshooting

If experiencing keychain access issues (permission prompts, access denied errors), you can temporarily bypass the keychain by setting the OAuth token directly.

**Security note:** Avoid storing tokens in shell history. Use a space prefix (with `histcontrol=ignorespace`) or pipe the command:

```bash
# macOS: Extract token from keychain (recommended)
export CLAUDE_USAGE_OAUTH_TOKEN=$(security find-generic-password -s 'Claude Code-credentials' -w | jq -r '.claudeAiOauth.accessToken')

# Linux: Extract from credentials file (if it exists)
export CLAUDE_USAGE_OAUTH_TOKEN=$(jq -r '.claudeAiOauth.accessToken' ~/.claude/.credentials.json)

# Then launch the app
open /Applications/ClaudeCodeUsage.app
```

To find your OAuth token manually:
1. Use Keychain Access app to view "Claude Code-credentials"
2. Or check `~/.claude/.credentials.json` if it exists (Linux)

The environment variable has highest priority, bypassing all keychain access. This is a temporary workaround - resolve the underlying keychain permissions issue when possible.

## Architecture

```
Views (SwiftUI)
    ↓
UsageViewModel (@Observable, @MainActor)
    ↓
Services (Actors - thread-safe)
    ↓
Models (Data structures)
```

### Key Components

**App Layer (`App/`):**
- `ClaudeUsageTrackerApp.swift` - SwiftUI @main entry point
- `AppDelegate.swift` - Lifecycle, notification delegate, launch-to-popover handling

**MenuBar (`MenuBar/`):**
- `MenuBarController.swift` - NSStatusBar setup, popover management, event monitoring

**Services (`Services/`)** - All implemented as Swift Actors for thread safety:
- `UsageAPIService` - Anthropic OAuth API calls (`/api/oauth/usage`)
- `CredentialService` - Keychain access for OAuth tokens and manual API keys
- `AgentCounter` - Process detection via `ps` command, orphan identification
- `NotificationService` - macOS notifications for orphan alerts

**ViewModel (`ViewModels/`):**
- `UsageViewModel` - Main state management, polling loop, coordinates all services

**Views (`Views/`):**
- `UsagePopoverView.swift` - Main popover UI with usage display
- `SettingsView.swift` - Settings sheet (refresh interval, launch at login, notifications)
- `APIKeySettingsView.swift` - Manual API key configuration

### Data Flow

1. `MenuBarController` shows popover → creates `UsagePopoverView` with `UsageViewModel`
2. `UsageViewModel.startPolling()` triggers periodic `refresh()` calls
3. `refresh()` fetches usage via `UsageAPIService`, counts agents via `AgentCounter`
4. On 401 error, `UsageAPIService` spawns Claude CLI to refresh OAuth token
5. Views observe `@Observable` ViewModel properties and update automatically

### Credential Priority

Order (highest to lowest):
1. `CLAUDE_USAGE_OAUTH_TOKEN` environment variable
2. In-memory cache (valid for current session)
3. App's keychain cache (`ClaudeCodeUsage-oauth`)
4. Claude Code's keychain (`Claude Code-credentials`) - authoritative on macOS
5. App's file cache (`~/.config/claudecodeusage/oauth-cache.json`)
6. File credentials (`~/.claude/.credentials.json`)
7. Manual API key fallback

**Gotcha:** Claude CLI updates keychain but may leave file credentials stale. Keychain is preferred over file sources to avoid using expired tokens.

### Account Switch Detection

The app automatically detects when you switch Claude accounts (`claude logout` → `claude login`). On each refresh cycle, it compares the cached token against Claude's keychain. If different, caches are invalidated and the new account's credentials are used.

No manual intervention required - just switch accounts in Claude Code and the app picks it up within 60 seconds.

## Code Patterns

**Concurrency:** All services are Actors. ViewModel is `@MainActor` for UI updates. Use `async/await` throughout.

**Settings persistence:** Use `@AppStorage` for user preferences (refresh interval, notification toggles).

**Process detection:** `AgentCounter` uses `ps aux` with grep patterns to identify Claude sessions vs subagents. Orphan detection checks: parentPID = 1, no active sessions, CPU < 1%.

## Release Convention

**DMG naming:** Always use `ClaudeCodeUsage.dmg` (no version number in filename). The version is tracked in the git tag and release title, not the asset name. This keeps download URLs stable across releases.

## Release Process

1. Bump version in `Resources/Info.plist` (CFBundleShortVersionString)
2. Ask user to build, sign, notarize, and create DMG:
   ```bash
   make all
   ```
3. Commit and push:
   ```bash
   git add -A && git commit -m "fix/feat: description"
   git push
   ```
4. Tag and release:
   ```bash
   git tag v1.x.x && git push origin v1.x.x
   gh release create v1.x.x release/ClaudeCodeUsage.dmg --title "v1.x.x" --notes "Release notes"
   ```

## Notes

- App is LSUIElement (menu bar only, no dock icon)
- App sandbox disabled to access Claude Code's Keychain entries
- Menu bar icon color-codes: red at ≥90%, orange at ≥70%
