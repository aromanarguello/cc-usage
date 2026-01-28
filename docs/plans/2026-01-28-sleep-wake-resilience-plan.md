# Sleep/Wake Resilience Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Prevent automatic keychain prompts after wake, handle stale data gracefully, and recover from stuck loading states.

**Architecture:** Add a `RefreshState` state machine to `UsageViewModel`, observe sleep/wake notifications in `MenuBarController`, use preflight keychain checks before automatic refreshes, and add timeout protection for all async operations.

**Tech Stack:** Swift 6.0, SwiftUI, AppKit (NSWorkspace notifications), Security framework

---

## Task 1: Add RefreshState Enum to UsageViewModel

**Files:**
- Modify: `Sources/ClaudeCodeUsage/ViewModels/UsageViewModel.swift:1-15`

**Step 1: Add the RefreshState enum**

Add after the imports, before the class declaration:

```swift
/// Represents the current state of the refresh cycle
enum RefreshState: Equatable {
    case idle                      // Normal, can refresh
    case loading                   // Refresh in progress
    case pausedForSleep            // Mac is sleeping
    case wakingUp(resumeAt: Date)  // Waiting after wake
    case needsManualRefresh        // Keychain would prompt, waiting for user

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    var canAutoRefresh: Bool {
        self == .idle
    }

    var statusMessage: String? {
        switch self {
        case .pausedForSleep:
            return "Paused (sleeping)"
        case .wakingUp(let resumeAt):
            let seconds = max(0, Int(resumeAt.timeIntervalSinceNow))
            return "Resuming in \(seconds)s..."
        case .needsManualRefresh:
            return "Tap to refresh"
        default:
            return nil
        }
    }
}
```

**Step 2: Verify syntax**

Run: `swift build 2>&1 | head -20`
Expected: No errors related to RefreshState

**Step 3: Commit**

```bash
git add Sources/ClaudeCodeUsage/ViewModels/UsageViewModel.swift
git commit -m "feat: add RefreshState enum for sleep/wake resilience"
```

---

## Task 2: Replace isLoading with RefreshState in UsageViewModel

**Files:**
- Modify: `Sources/ClaudeCodeUsage/ViewModels/UsageViewModel.swift:6-20`

**Step 1: Replace the isLoading property with refreshState**

Change:
```swift
private(set) var isLoading = false
```

To:
```swift
private(set) var refreshState: RefreshState = .idle
```

**Step 2: Add computed property for backward compatibility**

Add after `refreshState`:
```swift
var isLoading: Bool { refreshState.isLoading }
```

**Step 3: Update refresh() method loading state management**

In `refresh()` (around line 87-135), replace:
- `isLoading = true` with `refreshState = .loading`
- `isLoading = false` with `refreshState = .idle`

The guard should become:
```swift
guard refreshState.canAutoRefresh || refreshState == .needsManualRefresh else { return }
```

**Step 4: Verify build**

Run: `swift build 2>&1 | head -30`
Expected: Build succeeds

**Step 5: Commit**

```bash
git add Sources/ClaudeCodeUsage/ViewModels/UsageViewModel.swift
git commit -m "refactor: replace isLoading with refreshState state machine"
```

---

## Task 3: Add Sleep/Wake Handling to UsageViewModel

**Files:**
- Modify: `Sources/ClaudeCodeUsage/ViewModels/UsageViewModel.swift`

**Step 1: Add wake delay constant**

Add after the `updateCheckInterval` constant (around line 21):
```swift
private let wakeDelaySeconds: TimeInterval = 45
```

**Step 2: Add pauseForSleep method**

Add after `stopPolling()`:
```swift
/// Called when Mac is about to sleep - pauses all automatic refreshes
func pauseForSleep() {
    stopPolling()
    refreshState = .pausedForSleep
}
```

**Step 3: Add resumeAfterWake method**

Add after `pauseForSleep()`:
```swift
/// Called when Mac wakes - waits before resuming to let system stabilize
func resumeAfterWake() {
    let resumeAt = Date().addingTimeInterval(wakeDelaySeconds)
    refreshState = .wakingUp(resumeAt: resumeAt)

    Task {
        try? await Task.sleep(for: .seconds(wakeDelaySeconds))
        guard case .wakingUp = refreshState else { return }
        refreshState = .idle
        startPolling()
    }
}
```

**Step 4: Verify build**

Run: `swift build 2>&1 | head -20`
Expected: Build succeeds

**Step 5: Commit**

```bash
git add Sources/ClaudeCodeUsage/ViewModels/UsageViewModel.swift
git commit -m "feat: add pauseForSleep and resumeAfterWake methods"
```

---

## Task 4: Add Sleep/Wake Observers to MenuBarController

**Files:**
- Modify: `Sources/ClaudeCodeUsage/MenuBar/MenuBarController.swift:61-83`

**Step 1: Update setupWorkspaceObservers to handle sleep/wake**

Replace the entire `setupWorkspaceObservers()` method:

```swift
private func setupWorkspaceObservers() {
    let nc = NSWorkspace.shared.notificationCenter

    // Handle screen wake (restore status item if lost)
    nc.addObserver(
        forName: NSWorkspace.screensDidWakeNotification,
        object: nil,
        queue: .main
    ) { [weak self] _ in
        Task { @MainActor in
            self?.ensureStatusItemExists()
        }
    }

    // Handle system sleep - pause polling
    nc.addObserver(
        forName: NSWorkspace.willSleepNotification,
        object: nil,
        queue: .main
    ) { [weak self] _ in
        Task { @MainActor in
            #if DEBUG
            print("[MenuBarController] System sleeping, pausing polling")
            #endif
            self?.viewModel.pauseForSleep()
        }
    }

    // Handle system wake - resume with delay
    nc.addObserver(
        forName: NSWorkspace.didWakeNotification,
        object: nil,
        queue: .main
    ) { [weak self] _ in
        Task { @MainActor in
            #if DEBUG
            print("[MenuBarController] System woke, resuming after delay")
            #endif
            self?.ensureStatusItemExists()
            self?.viewModel.resumeAfterWake()
        }
    }
}
```

**Step 2: Verify build**

Run: `swift build 2>&1 | head -20`
Expected: Build succeeds

**Step 3: Commit**

```bash
git add Sources/ClaudeCodeUsage/MenuBar/MenuBarController.swift
git commit -m "feat: pause polling on sleep, resume with delay on wake"
```

---

## Task 5: Add Preflight Check Before Automatic Refresh

**Files:**
- Modify: `Sources/ClaudeCodeUsage/ViewModels/UsageViewModel.swift`

**Step 1: Add method to check if automatic refresh should proceed**

Add after `resumeAfterWake()`:

```swift
/// Checks if automatic refresh can proceed without user interaction
/// Returns false if keychain access would require user prompt
private func canRefreshSilently() async -> Bool {
    // If we have cached credentials, we can refresh silently
    if await credentialService.hasCachedToken() {
        return true
    }

    // Check if keychain access would require interaction
    let status = await credentialService.preflightClaudeKeychainAccess()
    switch status {
    case .allowed:
        return true
    case .interactionRequired:
        return false
    case .notFound, .failure:
        return true  // Let it fail naturally with proper error handling
    }
}
```

**Step 2: Update refresh() to use preflight check for automatic refreshes**

Add a parameter to distinguish manual vs automatic refresh. Update the method signature:

```swift
func refresh(userInitiated: Bool = false) async {
```

Then add at the start of the method, after the guard:
```swift
// For automatic refreshes, check if we can proceed without prompting
if !userInitiated && !await canRefreshSilently() {
    refreshState = .needsManualRefresh
    return
}
```

**Step 3: Update polling to pass userInitiated: false**

In `startPolling()`, the refresh call should explicitly pass `false`:
```swift
await refresh(userInitiated: false)
```

**Step 4: Verify build**

Run: `swift build 2>&1 | head -20`
Expected: Build succeeds

**Step 5: Commit**

```bash
git add Sources/ClaudeCodeUsage/ViewModels/UsageViewModel.swift
git commit -m "feat: add preflight keychain check for automatic refreshes"
```

---

## Task 6: Update View to Handle needsManualRefresh State

**Files:**
- Modify: `Sources/ClaudeCodeUsage/Views/UsagePopoverView.swift:144-172`

**Step 1: Update the footer to show refresh state message**

Replace the footer section (lines 144-172) with:

```swift
// Footer
HStack {
    if viewModel.errorMessage != nil, viewModel.usageData != nil {
        Image(systemName: "exclamationmark.circle")
            .foregroundStyle(.orange)
            .font(.caption)
    }

    // Show state message or time since update
    if let stateMessage = viewModel.refreshState.statusMessage {
        Text(stateMessage)
            .font(.caption)
            .foregroundStyle(.orange)
    } else {
        Text("Updated \(viewModel.timeSinceUpdate)")
            .font(.caption)
            .foregroundStyle(viewModel.isDataStale ? .orange : .secondary)
    }

    Spacer()

    Button(action: {
        Task { await viewModel.refresh(userInitiated: true) }
    }) {
        if viewModel.isLoading {
            ProgressView()
                .scaleEffect(0.6)
        } else {
            Image(systemName: "arrow.clockwise")
                .foregroundStyle(viewModel.refreshState == .needsManualRefresh ? .orange : .secondary)
        }
    }
    .buttonStyle(.plain)
    .disabled(viewModel.isLoading)
}
.padding(.horizontal)
.padding(.vertical, 8)
```

**Step 2: Verify build**

Run: `swift build 2>&1 | head -20`
Expected: Build succeeds (after Task 7 adds isDataStale)

**Step 3: Commit**

```bash
git add Sources/ClaudeCodeUsage/Views/UsagePopoverView.swift
git commit -m "feat: update footer to show refresh state and manual refresh prompt"
```

---

## Task 7: Add Staleness Tracking to UsageViewModel

**Files:**
- Modify: `Sources/ClaudeCodeUsage/ViewModels/UsageViewModel.swift`

**Step 1: Add staleness computed properties**

Add after `timeSinceUpdate`:

```swift
/// Time elapsed since last successful data fetch
var dataAge: TimeInterval {
    guard let lastFetchTime else { return .infinity }
    return Date().timeIntervalSince(lastFetchTime)
}

/// Whether data is considered stale (> 10 minutes old)
var isDataStale: Bool {
    dataAge > 600  // 10 minutes
}

/// Staleness tier for UI display
var stalenessTier: StalenessTier {
    let age = dataAge
    if age < 120 { return .fresh }      // < 2 min
    if age < 600 { return .recent }     // 2-10 min
    if age < 3600 { return .stale }     // 10-60 min
    return .veryStale                    // > 1 hour
}

enum StalenessTier {
    case fresh      // Green, normal
    case recent     // Default color
    case stale      // Orange
    case veryStale  // Red with warning

    var color: Color {
        switch self {
        case .fresh: return .green
        case .recent: return .secondary
        case .stale: return .orange
        case .veryStale: return .red
        }
    }
}
```

**Step 2: Update timeSinceUpdate to show staleness prefix**

Replace the `timeSinceUpdate` computed property:

```swift
var timeSinceUpdate: String {
    guard let lastFetchTime else { return "Never" }
    let seconds = Int(Date().timeIntervalSince(lastFetchTime))

    let timeString: String
    if seconds < 60 {
        timeString = "\(seconds) sec ago"
    } else if seconds < 3600 {
        let minutes = seconds / 60
        timeString = "\(minutes) min ago"
    } else {
        let hours = seconds / 3600
        timeString = "\(hours) hr ago"
    }

    // Add "Stale:" prefix for old data
    if isDataStale {
        return "Stale: \(timeString)"
    }
    return timeString
}
```

**Step 3: Ensure usageData is NOT cleared on refresh failure**

In `refresh()`, remove any line that sets `usageData = nil` on error. The data should persist.

**Step 4: Verify build**

Run: `swift build 2>&1 | head -20`
Expected: Build succeeds

**Step 5: Commit**

```bash
git add Sources/ClaudeCodeUsage/ViewModels/UsageViewModel.swift
git commit -m "feat: add staleness tracking with tiered display"
```

---

## Task 8: Add Timeout Protection for Refresh Operations

**Files:**
- Modify: `Sources/ClaudeCodeUsage/ViewModels/UsageViewModel.swift`

**Step 1: Add refresh timeout constant**

Add after `wakeDelaySeconds`:
```swift
private let refreshTimeoutSeconds: TimeInterval = 30
```

**Step 2: Add timeout wrapper method**

Add before `refresh()`:

```swift
/// Wraps an async operation with a timeout
private func withTimeout<T>(
    seconds: TimeInterval,
    operation: @escaping () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw RefreshError.timeout
        }

        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

enum RefreshError: Error, LocalizedError {
    case timeout

    var errorDescription: String? {
        switch self {
        case .timeout:
            return "Request timed out. Tap to retry."
        }
    }
}
```

**Step 3: Wrap API call in refresh() with timeout**

In `refresh()`, change:
```swift
usageData = try await apiService.fetchUsage()
```

To:
```swift
usageData = try await withTimeout(seconds: refreshTimeoutSeconds) {
    try await self.apiService.fetchUsage()
}
```

**Step 4: Verify build**

Run: `swift build 2>&1 | head -20`
Expected: Build succeeds

**Step 5: Commit**

```bash
git add Sources/ClaudeCodeUsage/ViewModels/UsageViewModel.swift
git commit -m "feat: add 30-second timeout protection for refresh operations"
```

---

## Task 9: Add Force Refresh That Cancels Stuck Operations

**Files:**
- Modify: `Sources/ClaudeCodeUsage/ViewModels/UsageViewModel.swift`

**Step 1: Track the current refresh task**

Add after `pollingTask`:
```swift
private var currentRefreshTask: Task<Void, Never>?
```

**Step 2: Update refresh() to use cancellable task**

Wrap the refresh logic in a task that can be cancelled:

```swift
func refresh(userInitiated: Bool = false) async {
    // Cancel any stuck previous refresh if user-initiated
    if userInitiated {
        currentRefreshTask?.cancel()
    }

    // Guard against concurrent automatic refreshes
    guard refreshState.canAutoRefresh || refreshState == .needsManualRefresh || userInitiated else { return }

    // For automatic refreshes, check if we can proceed without prompting
    if !userInitiated && !await canRefreshSilently() {
        refreshState = .needsManualRefresh
        return
    }

    refreshState = .loading
    errorMessage = nil

    currentRefreshTask = Task {
        // ... existing refresh logic ...
    }

    await currentRefreshTask?.value
}
```

**Step 3: Verify build**

Run: `swift build 2>&1 | head -20`
Expected: Build succeeds

**Step 4: Commit**

```bash
git add Sources/ClaudeCodeUsage/ViewModels/UsageViewModel.swift
git commit -m "feat: allow force refresh to cancel stuck operations"
```

---

## Task 10: Update togglePopover to Use userInitiated

**Files:**
- Modify: `Sources/ClaudeCodeUsage/MenuBar/MenuBarController.swift:145-157`

**Step 1: Update togglePopover refresh call**

Change:
```swift
Task { await viewModel.refresh() }
```

To:
```swift
Task { await viewModel.refresh(userInitiated: true) }
```

**Step 2: Update showPopover refresh call**

Similarly in `showPopover()`, change:
```swift
Task { await viewModel.refresh() }
```

To:
```swift
Task { await viewModel.refresh(userInitiated: true) }
```

**Step 3: Verify build**

Run: `swift build 2>&1 | head -20`
Expected: Build succeeds

**Step 4: Commit**

```bash
git add Sources/ClaudeCodeUsage/MenuBar/MenuBarController.swift
git commit -m "fix: mark popover refresh as user-initiated to allow keychain prompts"
```

---

## Task 11: Update Status Bar to Show Staleness

**Files:**
- Modify: `Sources/ClaudeCodeUsage/MenuBar/MenuBarController.swift:108-143`

**Step 1: Update updateStatusItemTitle to show stale indicator**

In `updateStatusItemTitle()`, after setting the title based on percentage, add staleness indicator:

```swift
// Add stale indicator if data is old
if viewModel.isDataStale {
    button.contentTintColor = .systemOrange
}

// Add wake status indicator
if case .wakingUp = viewModel.refreshState {
    title = "..."
    button.contentTintColor = .systemBlue
}

if case .needsManualRefresh = viewModel.refreshState {
    title += " !"
    button.contentTintColor = .systemOrange
}
```

**Step 2: Verify build**

Run: `swift build 2>&1 | head -20`
Expected: Build succeeds

**Step 3: Commit**

```bash
git add Sources/ClaudeCodeUsage/MenuBar/MenuBarController.swift
git commit -m "feat: show staleness and refresh-needed indicators in menu bar"
```

---

## Task 12: Final Integration Test and Version Bump

**Files:**
- Modify: `Makefile` or version constant

**Step 1: Build release**

Run: `make build`
Expected: Build succeeds with no warnings

**Step 2: Manual test checklist**

Test these scenarios:
- [ ] Launch app, verify normal refresh works
- [ ] Put Mac to sleep briefly, wake, verify 45s delay before refresh
- [ ] Observe that no keychain prompt appears automatically after wake
- [ ] Click refresh button manually, verify keychain prompt appears if needed
- [ ] Wait 10+ minutes without refresh, verify "Stale:" prefix appears
- [ ] Verify stale data persists and isn't cleared on refresh failure

**Step 3: Commit version bump**

```bash
git add -A
git commit -m "feat: sleep/wake resilience - prevent auto keychain prompts, handle stale data

- Add RefreshState state machine for explicit refresh lifecycle
- Pause polling on system sleep, resume with 45s delay on wake
- Preflight keychain check prevents automatic prompts
- User-initiated refreshes can still trigger keychain prompts
- Staleness tiers (fresh/recent/stale/veryStale) with color coding
- 30-second timeout protection for API calls
- Force refresh cancels stuck operations

Fixes: keychain prompts appearing after wake without user interaction
Fixes: refresh button unresponsive when stuck loading
Fixes: stale data not clearly indicated"
```

---

## Summary

This plan implements:
1. **RefreshState state machine** - Explicit states for the refresh lifecycle
2. **Sleep/wake awareness** - Pause on sleep, delay resume on wake
3. **Preflight keychain checks** - Never auto-prompt, only prompt on user action
4. **Staleness tracking** - Visual indicators for old data
5. **Timeout protection** - 30s timeout prevents hung operations
6. **Force refresh** - User can always unstick the app

Total: 12 tasks, approximately 45-60 minutes of implementation time.
