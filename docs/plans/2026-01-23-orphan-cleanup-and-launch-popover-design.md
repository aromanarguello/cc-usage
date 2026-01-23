# Design: Orphan Cleanup & Launch-to-Popover

**Date:** 2026-01-23
**Status:** Approved

## Overview

Two features to add:

1. **Orphan Agent Cleanup** - Detect and clean up subagents that outlive their parent sessions, with both manual (quick kill-all button) and automatic (smart detection + notification) options.

2. **Launch-to-Open-Popover** - When the app is launched while already running (via Spotlight, Raycast, or any method), show the menu bar popover instead of doing nothing.

**Design principles:**
- Keep existing UI consistent - no redesign, just additions
- Native macOS aesthetic (glass-morphic, SF Symbols, system colors)
- Conservative orphan detection to avoid false positives
- Non-intrusive notifications that respect user attention

---

## Orphan Detection Logic

**Multi-signal detection (conservative approach):**

A subagent is considered orphaned when **all** of these are true:
1. **Parent PID = 1** - The subagent's parent process no longer exists (reparented to init)
2. **No matching session** - Session count is 0, or the subagent can't be traced to an active session
3. **Low CPU activity** - Less than 1% CPU for 10+ seconds (not actively working)

**Detection timing:**
- Check for orphans on each polling interval (existing 30/60/120s refresh)
- Also check immediately when session count drops (e.g., went from 2 sessions to 1)

**Data changes to `AgentCounter`:**
- Add `parentPID` and `cpuPercent` to `ProcessInfo`
- New method: `detectOrphanedSubagents() -> [ProcessInfo]`
- Update `ps` command to include `ppid` and `%cpu` columns

---

## UI Changes - Quick Kill-All Button

**Placement in existing popover:**

In the "Active Agents" section, add a "Kill All" button that appears when subagents exist:

```
┌─────────────────────────────────────┐
│ ◎ Active Agents                   9 │
│ ▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬ │
│ ● 1 sessions  ● 8 subagents  🖥 2.4GB │
│                         [Kill All] │  ← New button, right-aligned
└─────────────────────────────────────┘
```

**Button behavior:**
- Only visible when `subagents > 0`
- Subtle styling (secondary/text button style, not prominent)
- Tap shows confirmation alert: "Kill all 8 subagents?" with Cancel/Kill options
- After kill: brief "Killed 8 subagents" inline feedback, then refresh agent count

**Existing hanging agents warning unchanged:**
- The ">3 hour" hanging agent warning and kill button remain as-is
- Kill All is a separate, broader action

---

## macOS Notification for Orphan Detection

**When notification triggers:**
- Orphans detected (using multi-signal logic above)
- Only notify once per "orphan event" - don't spam if user ignores it
- Reset notification state when orphans are cleaned up or user dismisses

**Notification content:**
```
┌─────────────────────────────────────┐
│ ClaudeCodeUsage              [icon] │
│ 5 orphaned subagents detected       │
│ Parent session ended                │
│                                     │
│              [Ignore]  [Clean Up]   │
└─────────────────────────────────────┘
```

**Actions:**
- **Clean Up** - Kills the orphaned subagents, shows brief confirmation
- **Ignore** - Dismisses notification, won't re-notify for these same orphans
- **Click notification body** - Opens the popover

**Implementation:**
- Use `UNUserNotificationCenter` for actionable notifications
- Request notification permission on first orphan detection (or at app startup)
- App icon automatically appears in macOS notifications

**Settings toggle:**
- Add "Orphan notifications" toggle in the Settings sheet
- Users can also disable via System Settings > Notifications

---

## Launch-to-Open-Popover

**Current behavior:**
- App runs as accessory (`.accessory` activation policy)
- Launching while already running does nothing visible

**New behavior:**
- Detect when app is "re-launched" while already running
- Show the popover (same as clicking the menu bar icon)

**Implementation:**

In `AppDelegate`, handle the `applicationShouldHandleReopen` delegate method:

```swift
func applicationShouldHandleReopen(_ sender: NSApplication,
                                    hasVisibleWindows flag: Bool) -> Bool {
    menuBarController.showPopover()
    return false
}
```

This fires when:
- User clicks app in Spotlight/Raycast results
- User double-clicks the app in Finder
- Any other "open" action while app is running

**No UI changes needed** - just behavioral.

---

## Implementation Summary

**Files to modify:**

| File | Changes |
|------|---------|
| `Services/AgentCounter.swift` | Add `ppid`, `cpuPercent` to `ProcessInfo`; add `detectOrphanedSubagents()` method; update `ps` command |
| `ViewModels/UsageViewModel.swift` | Track orphan state; add `killAllSubagents()` method; notification logic; orphan detection on poll |
| `Views/UsagePopoverView.swift` | Add "Kill All" button in Active Agents section with confirmation |
| `Views/SettingsView.swift` | Add "Orphan notifications" toggle |
| `App/AppDelegate.swift` | Add `applicationShouldHandleReopen` handler; setup `UNUserNotificationCenter` |
| `Services/NotificationService.swift` | **New file** - Handle notification permissions, sending, and action responses |

**New user preferences (@AppStorage):**
- `orphanNotificationsEnabled: Bool` (default: true)

**Implementation order:**
1. Launch-to-popover (quick win, isolated change)
2. Extend `ProcessInfo` and `AgentCounter` with orphan detection
3. Add "Kill All" button with confirmation
4. Build notification service
5. Wire up orphan detection → notification flow
6. Add settings toggle

---

## Notes

- Use `frontend-design` skill when implementing UI changes to maintain Apple-like aesthetics
- Keep existing glass-morphic design consistent
- Conservative orphan detection avoids killing legitimate subagents
