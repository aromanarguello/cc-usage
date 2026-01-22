# Claude Code Usage Tracker - Design Document

A native macOS menu bar app for tracking Claude Code usage limits in real-time.

## Overview

**Goal:** Display 5-hour window and weekly usage percentages in a sleek menu bar dropdown with glass-morphic aesthetic.

**Stack:** Swift 5.9+, SwiftUI, macOS 14.0+ (Sonoma)

**Data Source:** Claude Code CLI credentials from macOS Keychain + Anthropic API

---

## Architecture

```
ClaudeUsageTracker/
├── App/
│   └── ClaudeUsageTrackerApp.swift    # @main entry, NSApplicationDelegateAdaptor
├── MenuBar/
│   ├── MenuBarController.swift         # NSStatusItem setup, percentage in icon
│   └── UsagePopoverView.swift          # The dropdown panel (SwiftUI)
├── Services/
│   ├── CredentialService.swift         # Read from Keychain
│   ├── UsageAPIService.swift           # Fetch from Anthropic API
│   └── UsagePollingService.swift       # Timer-based refresh
├── Models/
│   └── UsageData.swift                 # Response types
└── Views/
    ├── UsageBarView.swift              # Reusable progress bar component
    └── SettingsView.swift              # Minimal settings (refresh interval)
```

---

## Visual Design

### Menu Bar Icon
- Shows current 5-hour usage as text (e.g., "20%")
- Monospace font to prevent width jumping

### Popover Panel (~320pt wide)

```
┌─────────────────────────────────────────┐
│  Claude Usage                     Pro   │  ← Header + subscription badge
├─────────────────────────────────────────┤
│  ⏱  5-Hour Window              20%     │
│  ████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░  │  ← Green progress bar
│  Resets in 4h 54m                       │
├─────────────────────────────────────────┤
│  📅  Weekly                      51%    │
│  ████████████████░░░░░░░░░░░░░░░░░░░░  │  ← Amber progress bar
│  Resets Mon 2:59 PM                     │
├─────────────────────────────────────────┤
│  Updated 0 sec ago                 ↻    │
│  Settings                       Quit    │
└─────────────────────────────────────────┘
```

### Styling
- Background: `.ultraThinMaterial` for glass-morphic blur
- Corner radius: ~16pt
- Progress bars: rounded capsule, ~8pt height
- 5-hour bar color: green (`#4ADE80`)
- Weekly bar color: amber (`#F59E0B`)
- "Pro" badge: orange rounded rect with white text
- Icons: SF Symbols (`clock`, `calendar`)

---

## Data Flow

### 1. Credential Reading

Read Claude Code credentials from macOS Keychain:

```swift
let query: [String: Any] = [
    kSecClass: kSecClassGenericPassword,
    kSecAttrService: "Claude Code-credentials",
    kSecReturnData: true
]
```

Parse JSON to extract `claudeAiOauth.accessToken`.

### 2. API Call

```
GET https://api.anthropic.com/api/oauth/usage

Headers:
  Authorization: Bearer {accessToken}
  Content-Type: application/json
  anthropic-beta: oauth-2025-04-20
```

### 3. Response Structure

```swift
struct UsageResponse: Codable {
    let fiveHour: UsageWindow
    let sevenDay: UsageWindow

    struct UsageWindow: Codable {
        let utilization: Double  // 0.0 to 1.0
        let resetsAt: Date       // ISO8601
    }
}
```

### 4. Polling Strategy

- Default refresh: every 60 seconds
- Manual refresh button available
- Show "Updated X sec ago" timestamp
- Pause polling when popover closed (optional)

---

## Error Handling

| Condition | UI Response |
|-----------|-------------|
| No credentials | "Not logged in - run `claude` to authenticate" |
| Token expired | "Session expired - re-login to Claude Code" |
| Network error | Show last known data + "Offline" indicator |
| API error | Show error message, retry on next poll |

---

## Settings

Minimal settings panel:
- **Refresh interval:** 30s / 60s / 120s dropdown
- **Launch at login:** toggle

---

## Project Configuration

### Requirements
- macOS 14.0+ (Sonoma)
- Swift 5.9+
- Xcode 15+

### Entitlements

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "...">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.network.client</key>
    <true/>
    <key>keychain-access-groups</key>
    <array>
        <string>$(AppIdentifierPrefix)com.ale.ClaudeUsageTracker</string>
    </array>
</dict>
</plist>
```

### Info.plist Keys

```xml
<key>LSUIElement</key>
<true/>  <!-- Menu bar only, no dock icon -->
```

---

## Distribution

1. **Build from source** - Clone, open in Xcode, build
2. **GitHub releases** - Notarized .dmg download
3. **Homebrew cask** - Future option for public sharing

---

## Implementation Order

1. Create Xcode project with correct settings
2. Implement MenuBarController with static "20%" text
3. Add UsagePopoverView with hardcoded UI
4. Implement CredentialService (Keychain reading)
5. Implement UsageAPIService (API calls)
6. Wire up real data to UI
7. Add polling with UsagePollingService
8. Add Settings view
9. Polish animations and edge cases
