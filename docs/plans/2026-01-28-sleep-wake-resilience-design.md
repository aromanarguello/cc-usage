# Sleep/Wake Resilience Design

**Date:** 2026-01-28
**Status:** Approved
**Problem:** App prompts for keychain access automatically after wake, refresh gets stuck, data goes stale

## Problem Summary

After the Mac wakes from sleep:
1. Polling resumes and automatically triggers keychain prompts (interrupts user)
2. Keychain/network operations may timeout or fail silently post-wake
3. Refresh button becomes unresponsive when stuck in loading state
4. Data shows "Updated 289 min ago" with no clear staleness indication

## Solution Overview

Four coordinated improvements:

### 1. Sleep/Wake Awareness

Observe `NSWorkspace` notifications in `MenuBarController`:
- `willSleepNotification` → pause polling, cancel pending requests
- `didWakeNotification` → start 45-second wake delay timer

During wake delay, show "Resuming after sleep..." status.

### 2. Never Auto-Prompt for Keychain

Before any **automatic** (polling) refresh:
1. Check cached token (memory or app keychain) → use if available
2. If not cached, call `preflightClaudeKeychainAccess()`
3. If result is `.interactionRequired` → set `needsManualRefresh` state, don't prompt
4. Only trigger keychain prompt when user **explicitly** clicks Refresh

Key distinction: **polling = silent only**, **user click = allowed to prompt**

### 3. Graceful Degradation with Stale Data

**Staleness tiers:**

| Age | Indicator | Color |
|-----|-----------|-------|
| < 2 min | "Updated X sec ago" | Green |
| 2-10 min | "Updated X min ago" | Default |
| 10-60 min | "Stale: X min ago" | Orange |
| > 60 min | "Stale: X hr ago" | Red + warning |

**Behavior:**
- Never clear `usageData` on refresh failure
- Show error message alongside stale data, not replacing it
- Add `isDataStale` and `dataAge` computed properties

### 4. Timeout Protection and Loading Recovery

**Timeouts:**
- Keychain operation: 10 seconds max
- API request: 30 seconds max

**Loading state recovery:**
- Track `loadingStartedAt` timestamp
- Auto-reset `isLoading` after 60 seconds if stuck
- Allow manual refresh to cancel stuck operation and start fresh

**Implementation:**
```swift
private var refreshTask: Task<Void, Never>?

func refresh() async {
    refreshTask?.cancel()  // Cancel any stuck previous refresh
    refreshTask = Task { /* actual refresh */ }
    await refreshTask?.value
}
```

### 5. Explicit State Machine

```swift
enum RefreshState {
    case idle                      // Normal, can refresh
    case loading                   // Refresh in progress
    case pausedForSleep            // Mac is sleeping
    case wakingUp(resumeAt: Date)  // Waiting 45s after wake
    case needsManualRefresh        // Keychain would prompt, waiting for user
    case error(String)             // Failed, showing error + stale data
}
```

**State transitions:**

```
                    ┌─────────────────────────────────────────┐
                    │                                         │
    willSleep       ▼          didWake                        │
   ──────────► pausedForSleep ──────────► wakingUp ───────────┤
                                              │               │
                                         45s elapsed          │
                                              │               │
                                              ▼               │
                              ┌──────────── idle ◄────────────┘
                              │               │
                     auto-refresh        auto-refresh
                  (preflight OK)    (preflight: needs interaction)
                              │               │
                              ▼               ▼
                          loading      needsManualRefresh
                              │               │
                         success/fail    user clicks
                              │               │
                              ▼               ▼
                       idle/error         loading
```

**Rules:**
1. Polling only runs in `idle` state
2. Polling only proceeds if preflight check passes
3. User can force refresh from any state except `pausedForSleep`
4. Stale data preserved across all state changes

## Files to Modify

1. **UsageViewModel.swift** - Add RefreshState, timeout handling, stale data logic
2. **MenuBarController.swift** - Add sleep/wake notification observers
3. **CredentialService.swift** - Add timeout wrapper for keychain operations
4. **UsagePopoverView.swift** - Update UI for staleness indicators and manual refresh prompts

## Testing Scenarios

1. Lock Mac, wait 5+ min, unlock → should NOT auto-prompt, should show "needs refresh"
2. Sleep Mac, wake → should wait 45s, show "resuming" status
3. Force refresh while loading → should cancel stuck operation
4. Network offline → should show stale data with error, not blank
5. Click refresh when `needsManualRefresh` → should trigger keychain prompt
