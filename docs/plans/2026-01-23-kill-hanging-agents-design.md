# Kill Hanging Sub-Agents

## Overview

Add the ability to detect and kill Claude Code sub-agents that have been running for more than 3 hours, indicating they are likely hung or orphaned.

## User Experience

- When hanging agents are detected, a warning section appears in the popover
- Warning shows count of hanging agents with a "Kill" button
- Clicking "Kill" shows a confirmation dialog before terminating processes
- After killing, the agent count refreshes automatically

## Technical Design

### Process Age Detection

Enhance `AgentCounter` to capture process elapsed time using `ps` with the `etime` field.

**New struct:**
```swift
struct ProcessInfo: Sendable {
    let pid: Int
    let elapsedSeconds: Int
    let isSubagent: Bool
}
```

**Updated AgentCount:**
```swift
struct AgentCount: Sendable {
    let sessions: Int
    let subagents: Int
    let hangingSubagents: [ProcessInfo]  // Subagents running > 3 hours
    var total: Int { sessions + subagents }
}
```

### Kill Mechanism

New function in `AgentCounter`:
```swift
func killHangingAgents(_ processes: [ProcessInfo]) async -> Int
```

- Sends SIGTERM to each PID
- If process doesn't exit after brief delay, escalates to SIGKILL
- Returns count of successfully killed processes
- Continues if individual kills fail (process already exited, permission denied)

### UI Changes

**Warning section in UsagePopoverView:**
- Yellow/orange warning styling
- Text: "N hanging agents (>3h)"
- "Kill" button

**Confirmation dialog:**
- Native macOS alert
- Title: "Kill Hanging Agents?"
- Message: "This will terminate N subagent processes that have been running for over 3 hours."
- Buttons: Cancel (default), Kill (destructive)

## Files to Modify

1. **AgentCounter.swift**
   - Add `ProcessInfo` struct
   - Update `countAgents()` to parse elapsed time
   - Add `killHangingAgents()` function

2. **UsagePopoverView.swift**
   - Add conditional warning section with kill button
   - Add confirmation alert state and handler

3. **UsageViewModel.swift**
   - Add `killHangingAgents()` method

## Constants

- Hanging threshold: 3 hours (fixed, not configurable)
- No changes to menu bar icon - warning only in popover
