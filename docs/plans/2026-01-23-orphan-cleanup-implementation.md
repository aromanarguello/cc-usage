# Orphan Cleanup & Launch-to-Popover Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add orphan subagent detection/cleanup with notifications, plus launch-to-popover functionality.

**Architecture:** Extend existing AgentCounter with orphan detection (multi-signal: PPID=1, no sessions, low CPU). Add NotificationService for macOS notifications with actions. UI additions are minimal - one "Kill All" button in the existing agent section.

**Tech Stack:** Swift 6, SwiftUI, AppKit, UserNotifications framework

---

## Task 1: Launch-to-Popover

**Files:**
- Modify: `Sources/ClaudeCodeUsage/App/AppDelegate.swift`
- Modify: `Sources/ClaudeCodeUsage/MenuBar/MenuBarController.swift`

**Step 1: Add showPopover method to MenuBarController**

In `MenuBarController.swift`, add a public method that can be called from AppDelegate:

```swift
func showPopover() {
    guard let button = statusItem?.button, let popover = popover else { return }

    if !popover.isShown {
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        Task { await viewModel.refresh() }
    }
}
```

**Step 2: Add applicationShouldHandleReopen to AppDelegate**

In `AppDelegate.swift`, add the delegate method:

```swift
func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    menuBarController?.showPopover()
    return false
}
```

**Step 3: Verify**

Run the app, then:
1. Open Spotlight (Cmd+Space)
2. Type "ClaudeCodeUsage"
3. Press Enter
4. Verify popover appears

**Step 4: Commit**

```bash
git add Sources/ClaudeCodeUsage/App/AppDelegate.swift Sources/ClaudeCodeUsage/MenuBar/MenuBarController.swift
git commit -m "feat: open popover when app launched via Spotlight/Raycast"
```

---

## Task 2: Extend ProcessInfo with Orphan Detection Fields

**Files:**
- Modify: `Sources/ClaudeCodeUsage/Services/AgentCounter.swift`

**Step 1: Add new fields to ProcessInfo**

Update the ProcessInfo struct:

```swift
struct ProcessInfo: Sendable {
    let pid: Int
    let parentPID: Int         // NEW: Parent process ID
    let elapsedSeconds: Int
    let memoryKB: Int
    let cpuPercent: Double     // NEW: CPU percentage
    let isSubagent: Bool

    var isOrphaned: Bool {     // NEW: Computed property
        parentPID == 1 && isSubagent
    }
}
```

**Step 2: Update ps command to include ppid and %cpu**

In `getClaudeProcesses()`, update the ps command:

```swift
task.arguments = ["-c", "ps -eo pid,ppid,etime,rss,%cpu,command | grep -E '( |/)claude( |$)' | grep -v grep | grep -v ClaudeCodeUsage"]
```

**Step 3: Update parsing logic**

Update the parsing in `getClaudeProcesses()`:

```swift
return output.split(separator: "\n").compactMap { line -> ProcessInfo? in
    let parts = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
    guard parts.count >= 6,
          let pid = Int(parts[0]),
          let parentPID = Int(parts[1]),
          let memoryKB = Int(parts[3]),
          let cpuPercent = Double(parts[4]) else { return nil }

    let etime = String(parts[2])
    let command = String(parts[5])

    let elapsedSeconds = parseEtime(etime)
    let isSubagent = command.contains("--output-format")

    return ProcessInfo(
        pid: pid,
        parentPID: parentPID,
        elapsedSeconds: elapsedSeconds,
        memoryKB: memoryKB,
        cpuPercent: cpuPercent,
        isSubagent: isSubagent
    )
}
```

**Step 4: Build and verify**

```bash
swift build
```

**Step 5: Commit**

```bash
git add Sources/ClaudeCodeUsage/Services/AgentCounter.swift
git commit -m "feat: add parentPID and cpuPercent to ProcessInfo for orphan detection"
```

---

## Task 3: Add Orphan Detection Method to AgentCounter

**Files:**
- Modify: `Sources/ClaudeCodeUsage/Services/AgentCounter.swift`

**Step 1: Add orphan detection method**

Add this method to AgentCounter:

```swift
func detectOrphanedSubagents() async -> [ProcessInfo] {
    let processes = getClaudeProcesses()
    let sessions = processes.filter { !$0.isSubagent }
    let subagents = processes.filter { $0.isSubagent }

    // Multi-signal orphan detection:
    // 1. Parent PID = 1 (reparented to init)
    // 2. No active sessions OR session count is 0
    // 3. Low CPU activity (< 1%)
    let orphans = subagents.filter { subagent in
        let parentGone = subagent.parentPID == 1
        let noSessions = sessions.isEmpty
        let lowCPU = subagent.cpuPercent < 1.0

        return parentGone && noSessions && lowCPU
    }

    return orphans
}
```

**Step 2: Add method to kill specific processes**

Add this method to AgentCounter:

```swift
func killProcesses(_ processes: [ProcessInfo]) async -> Int {
    var killedCount = 0

    for process in processes {
        let termResult = sendSignal(SIGTERM, to: process.pid)
        if termResult {
            try? await Task.sleep(for: .milliseconds(500))

            if isProcessRunning(process.pid) {
                _ = sendSignal(SIGKILL, to: process.pid)
            }
            killedCount += 1
        }
    }

    return killedCount
}
```

**Step 3: Build and verify**

```bash
swift build
```

**Step 4: Commit**

```bash
git add Sources/ClaudeCodeUsage/Services/AgentCounter.swift
git commit -m "feat: add detectOrphanedSubagents and killProcesses methods"
```

---

## Task 4: Add Kill All Button to Popover UI

**Files:**
- Modify: `Sources/ClaudeCodeUsage/Views/UsagePopoverView.swift`
- Modify: `Sources/ClaudeCodeUsage/ViewModels/UsageViewModel.swift`

**Step 1: Add killAllSubagents to ViewModel**

In `UsageViewModel.swift`, add:

```swift
func killAllSubagents() async -> Int {
    guard let agents = agentCount, agents.subagents > 0 else { return 0 }
    let subagents = await agentCounter.getAllSubagents()
    let killed = await agentCounter.killProcesses(subagents)
    await refreshAgentCount()
    return killed
}
```

**Step 2: Add getAllSubagents to AgentCounter**

In `AgentCounter.swift`, add:

```swift
func getAllSubagents() async -> [ProcessInfo] {
    let processes = getClaudeProcesses()
    return processes.filter { $0.isSubagent }
}
```

**Step 3: Add state variables to UsagePopoverView**

In `UsagePopoverView.swift`, add these state variables near the existing ones:

```swift
@State private var showKillAllConfirmation = false
@State private var isKillingAllAgents = false
```

**Step 4: Update agentSection to include Kill All button**

Replace the `agentSection` function's legend HStack with:

```swift
// Legend, Memory, and Kill All
HStack(spacing: 12) {
    HStack(spacing: 4) {
        Circle()
            .fill(sessionColor)
            .frame(width: 6, height: 6)
        Text("\(agents.sessions) sessions")
            .font(.caption)
            .foregroundColor(.secondary)
    }

    HStack(spacing: 4) {
        Circle()
            .fill(subagentColor)
            .frame(width: 6, height: 6)
        Text("\(agents.subagents) subagents")
            .font(.caption)
            .foregroundColor(.secondary)
    }

    Spacer()

    // Memory usage
    HStack(spacing: 4) {
        Image(systemName: "memorychip")
            .font(.caption2)
            .foregroundColor(.secondary)
        Text(formatMemory(agents.totalMemoryMB))
            .font(.caption)
            .foregroundColor(.secondary)
    }

    // Kill All button (only when subagents > 0)
    if agents.subagents > 0 {
        Button(action: { showKillAllConfirmation = true }) {
            if isKillingAllAgents {
                ProgressView()
                    .scaleEffect(0.5)
            } else {
                Text("Kill All")
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
        .buttonStyle(.plain)
        .disabled(isKillingAllAgents)
    }
}
```

**Step 5: Add confirmation alert**

Add this alert modifier after the existing `.alert("Kill Hanging Agents?"...)`:

```swift
.alert("Kill All Subagents?", isPresented: $showKillAllConfirmation) {
    Button("Cancel", role: .cancel) { }
    Button("Kill All", role: .destructive) {
        Task {
            isKillingAllAgents = true
            _ = await viewModel.killAllSubagents()
            isKillingAllAgents = false
        }
    }
} message: {
    let count = viewModel.agentCount?.subagents ?? 0
    Text("This will terminate all \(count) subagent process\(count == 1 ? "" : "es").")
}
```

**Step 6: Build and verify**

```bash
swift build
```

**Step 7: Commit**

```bash
git add Sources/ClaudeCodeUsage/Views/UsagePopoverView.swift Sources/ClaudeCodeUsage/ViewModels/UsageViewModel.swift Sources/ClaudeCodeUsage/Services/AgentCounter.swift
git commit -m "feat: add Kill All button to terminate all subagents"
```

---

## Task 5: Create NotificationService

**Files:**
- Create: `Sources/ClaudeCodeUsage/Services/NotificationService.swift`

**Step 1: Create the NotificationService file**

Create `Sources/ClaudeCodeUsage/Services/NotificationService.swift`:

```swift
import Foundation
import UserNotifications

actor NotificationService: NSObject {
    static let shared = NotificationService()

    private var isAuthorized = false
    private var notifiedOrphanPIDs: Set<Int> = []

    // Notification identifiers
    private let orphanCategoryID = "ORPHAN_AGENTS"
    private let cleanUpActionID = "CLEAN_UP"
    private let ignoreActionID = "IGNORE"

    override init() {
        super.init()
    }

    func requestAuthorization() async {
        let center = UNUserNotificationCenter.current()

        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            isAuthorized = granted

            if granted {
                await setupNotificationCategories()
            }
        } catch {
            print("Notification authorization failed: \(error)")
        }
    }

    private func setupNotificationCategories() async {
        let cleanUpAction = UNNotificationAction(
            identifier: cleanUpActionID,
            title: "Clean Up",
            options: [.foreground]
        )

        let ignoreAction = UNNotificationAction(
            identifier: ignoreActionID,
            title: "Ignore",
            options: []
        )

        let orphanCategory = UNNotificationCategory(
            identifier: orphanCategoryID,
            actions: [cleanUpAction, ignoreAction],
            intentIdentifiers: [],
            options: []
        )

        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories([orphanCategory])
    }

    func notifyOrphansDetected(count: Int, pids: [Int]) async {
        guard isAuthorized else { return }

        // Don't re-notify for same orphans
        let newPIDs = Set(pids).subtracting(notifiedOrphanPIDs)
        guard !newPIDs.isEmpty else { return }

        notifiedOrphanPIDs.formUnion(newPIDs)

        let content = UNMutableNotificationContent()
        content.title = "ClaudeCodeUsage"
        content.body = "\(count) orphaned subagent\(count == 1 ? "" : "s") detected"
        content.subtitle = "Parent session ended"
        content.sound = .default
        content.categoryIdentifier = orphanCategoryID
        content.userInfo = ["pids": pids]

        let request = UNNotificationRequest(
            identifier: "orphan-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            print("Failed to send notification: \(error)")
        }
    }

    func clearOrphanNotifications(pids: [Int]) {
        notifiedOrphanPIDs.subtract(pids)
    }

    func resetNotificationState() {
        notifiedOrphanPIDs.removeAll()
    }
}
```

**Step 2: Build and verify**

```bash
swift build
```

**Step 3: Commit**

```bash
git add Sources/ClaudeCodeUsage/Services/NotificationService.swift
git commit -m "feat: add NotificationService for orphan alerts"
```

---

## Task 6: Wire Up Orphan Detection to Notifications

**Files:**
- Modify: `Sources/ClaudeCodeUsage/ViewModels/UsageViewModel.swift`
- Modify: `Sources/ClaudeCodeUsage/App/AppDelegate.swift`

**Step 1: Add orphan tracking to UsageViewModel**

In `UsageViewModel.swift`, add properties:

```swift
private(set) var orphanedSubagents: [ProcessInfo] = []
private let notificationService = NotificationService.shared

@ObservationIgnored
@AppStorage("orphanNotificationsEnabled") private var orphanNotificationsEnabled: Bool = true
```

**Step 2: Update refresh() to detect orphans**

In `UsageViewModel.swift`, update `refresh()` to add orphan detection after the agent count refresh:

```swift
func refresh() async {
    guard !isLoading else { return }

    isLoading = true
    errorMessage = nil

    do {
        usageData = try await apiService.fetchUsage()
        lastFetchTime = Date()
        self.usingManualKey = await credentialService.hasManualAPIKey()
    } catch {
        errorMessage = error.localizedDescription
    }

    // Refresh agent count
    agentCount = await agentCounter.countAgents()

    // Detect orphans and notify if enabled
    if orphanNotificationsEnabled {
        let orphans = await agentCounter.detectOrphanedSubagents()
        if !orphans.isEmpty {
            orphanedSubagents = orphans
            await notificationService.notifyOrphansDetected(
                count: orphans.count,
                pids: orphans.map { $0.pid }
            )
        } else {
            orphanedSubagents = []
        }
    }

    isLoading = false
}
```

**Step 3: Add method to kill orphans**

In `UsageViewModel.swift`, add:

```swift
func killOrphanedSubagents() async -> Int {
    guard !orphanedSubagents.isEmpty else { return 0 }
    let pids = orphanedSubagents.map { $0.pid }
    let killed = await agentCounter.killProcesses(orphanedSubagents)
    await notificationService.clearOrphanNotifications(pids: pids)
    orphanedSubagents = []
    await refreshAgentCount()
    return killed
}
```

**Step 4: Request notification permission in AppDelegate**

In `AppDelegate.swift`, update `applicationDidFinishLaunching`:

```swift
func applicationDidFinishLaunching(_ notification: Notification) {
    // Hide from Dock, only show in menu bar
    NSApp.setActivationPolicy(.accessory)

    // Close any windows that might have opened
    for window in NSApp.windows {
        window.close()
    }

    // Request notification permission
    Task {
        await NotificationService.shared.requestAuthorization()
    }

    // Setup menu bar
    let credentialService = CredentialService()
    let apiService = UsageAPIService(credentialService: credentialService)
    let viewModel = UsageViewModel(apiService: apiService, credentialService: credentialService)
    menuBarController = MenuBarController(viewModel: viewModel)
}
```

**Step 5: Build and verify**

```bash
swift build
```

**Step 6: Commit**

```bash
git add Sources/ClaudeCodeUsage/ViewModels/UsageViewModel.swift Sources/ClaudeCodeUsage/App/AppDelegate.swift
git commit -m "feat: wire up orphan detection to notification service"
```

---

## Task 7: Handle Notification Actions

**Files:**
- Modify: `Sources/ClaudeCodeUsage/Services/NotificationService.swift`
- Modify: `Sources/ClaudeCodeUsage/App/AppDelegate.swift`

**Step 1: Add delegate protocol to NotificationService**

In `NotificationService.swift`, add at the top of the file:

```swift
protocol NotificationServiceDelegate: AnyObject {
    func notificationServiceDidRequestCleanup(pids: [Int])
    func notificationServiceDidRequestShowPopover()
}
```

**Step 2: Update NotificationService to handle responses**

In `NotificationService.swift`, add delegate and make it conform to UNUserNotificationCenterDelegate:

```swift
actor NotificationService: NSObject {
    static let shared = NotificationService()

    weak var delegate: NotificationServiceDelegate?

    // ... existing properties ...

    func setupDelegate() async {
        await MainActor.run {
            UNUserNotificationCenter.current().delegate = self
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate
extension NotificationService: @preconcurrency UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let pids = userInfo["pids"] as? [Int] ?? []

        Task { @MainActor in
            switch response.actionIdentifier {
            case "CLEAN_UP":
                await self.delegate?.notificationServiceDidRequestCleanup(pids: pids)
            case UNNotificationDefaultActionIdentifier:
                // User tapped the notification body
                await self.delegate?.notificationServiceDidRequestShowPopover()
            default:
                break
            }
            completionHandler()
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show notification even when app is in foreground
        completionHandler([.banner, .sound])
    }
}
```

**Step 3: Make AppDelegate conform to NotificationServiceDelegate**

In `AppDelegate.swift`, update to handle notification actions:

```swift
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NotificationServiceDelegate {
    var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        for window in NSApp.windows {
            window.close()
        }

        // Setup notification service
        Task {
            await NotificationService.shared.requestAuthorization()
            await NotificationService.shared.setupDelegate()
            await MainActor.run {
                NotificationService.shared.delegate = self
            }
        }

        // Setup menu bar
        let credentialService = CredentialService()
        let apiService = UsageAPIService(credentialService: credentialService)
        let viewModel = UsageViewModel(apiService: apiService, credentialService: credentialService)
        menuBarController = MenuBarController(viewModel: viewModel)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        menuBarController?.showPopover()
        return false
    }

    // MARK: - NotificationServiceDelegate

    func notificationServiceDidRequestCleanup(pids: [Int]) {
        Task {
            _ = await menuBarController?.viewModel.killOrphanedSubagents()
        }
    }

    func notificationServiceDidRequestShowPopover() {
        menuBarController?.showPopover()
    }
}
```

**Step 4: Build and verify**

```bash
swift build
```

**Step 5: Commit**

```bash
git add Sources/ClaudeCodeUsage/Services/NotificationService.swift Sources/ClaudeCodeUsage/App/AppDelegate.swift
git commit -m "feat: handle notification actions for orphan cleanup"
```

---

## Task 8: Add Notification Toggle to Settings

**Files:**
- Modify: `Sources/ClaudeCodeUsage/Views/SettingsView.swift`
- Modify: `Sources/ClaudeCodeUsage/Views/APIKeySettingsView.swift`

**Step 1: Update SettingsView with notification toggle**

Replace the entire `SettingsView.swift`:

```swift
import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @AppStorage("refreshInterval") private var refreshInterval: Double = 60
    @AppStorage("orphanNotificationsEnabled") private var orphanNotificationsEnabled: Bool = true
    @State private var launchAtLogin = false

    var body: some View {
        Form {
            Section {
                Picker("Refresh interval", selection: $refreshInterval) {
                    Text("30 seconds").tag(30.0)
                    Text("60 seconds").tag(60.0)
                    Text("120 seconds").tag(120.0)
                }
            }

            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        setLaunchAtLogin(newValue)
                    }
            }

            Section {
                Toggle("Orphan notifications", isOn: $orphanNotificationsEnabled)
            } footer: {
                Text("Notify when subagents are left running after their parent session ends")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 350, height: 200)
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("Failed to update launch at login: \(error)")
        }
    }
}

#Preview {
    SettingsView()
}
```

**Step 2: Update APIKeySettingsView to include general settings**

In `APIKeySettingsView.swift`, add a tab or section for general settings. For now, we'll keep them separate - the gear icon opens APIKeySettingsView which is API key focused. The main Settings window (accessible via menu) will have the full SettingsView.

Actually, looking at the current design, the gear icon in the popover opens APIKeySettingsView as a sheet. Let's add the orphan notification toggle there too for discoverability.

Update `APIKeySettingsView.swift` to include the toggle:

```swift
import SwiftUI

struct APIKeySettingsView: View {
    @Bindable var viewModel: UsageViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteConfirmation = false
    @State private var isDeleting = false
    @AppStorage("orphanNotificationsEnabled") private var orphanNotificationsEnabled: Bool = true

    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                Text("Settings")
                    .font(.headline)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            Divider()

            // Auth method section
            VStack(alignment: .leading, spacing: 8) {
                Text("Authentication")
                    .font(.subheadline)
                    .fontWeight(.medium)

                HStack {
                    if viewModel.usingManualKey {
                        Image(systemName: "key.fill")
                            .foregroundColor(.orange)
                        Text("Using Manual API Key")
                            .font(.callout)
                        Spacer()
                        Button(action: { showDeleteConfirmation = true }) {
                            if isDeleting {
                                ProgressView()
                                    .scaleEffect(0.6)
                            } else {
                                Text("Delete")
                                    .foregroundColor(.red)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(isDeleting)
                    } else {
                        Image(systemName: "person.badge.key.fill")
                            .foregroundColor(.green)
                        Text("Using Claude Code OAuth")
                            .font(.callout)
                        Spacer()
                    }
                }
                .padding(12)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            Divider()

            // Notifications section
            VStack(alignment: .leading, spacing: 8) {
                Text("Notifications")
                    .font(.subheadline)
                    .fontWeight(.medium)

                Toggle("Orphan agent alerts", isOn: $orphanNotificationsEnabled)
                    .toggleStyle(.switch)

                Text("Notify when subagents outlive their parent session")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding()
        .frame(width: 300, height: 260)
        .alert("Delete API Key?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                Task {
                    isDeleting = true
                    try? await viewModel.deleteManualAPIKey()
                    isDeleting = false
                    await viewModel.refresh()
                }
            }
        } message: {
            Text("The app will try to use Claude Code OAuth credentials instead.")
        }
    }
}

#Preview {
    let credentialService = CredentialService()
    let apiService = UsageAPIService(credentialService: credentialService)
    let viewModel = UsageViewModel(apiService: apiService, credentialService: credentialService)
    return APIKeySettingsView(viewModel: viewModel)
}
```

**Step 3: Build and verify**

```bash
swift build
```

**Step 4: Commit**

```bash
git add Sources/ClaudeCodeUsage/Views/SettingsView.swift Sources/ClaudeCodeUsage/Views/APIKeySettingsView.swift
git commit -m "feat: add orphan notification toggle to settings"
```

---

## Task 9: Final Testing and Polish

**Files:**
- All modified files

**Step 1: Build release**

```bash
swift build -c release
```

**Step 2: Manual testing checklist**

1. **Launch-to-popover:**
   - [ ] Close popover
   - [ ] Open Spotlight, type app name, press Enter
   - [ ] Verify popover opens

2. **Kill All button:**
   - [ ] Have at least 1 subagent running
   - [ ] Open popover
   - [ ] Verify "Kill All" button appears in agent section
   - [ ] Click Kill All
   - [ ] Verify confirmation dialog appears
   - [ ] Confirm and verify subagents are killed

3. **Orphan notifications:**
   - [ ] Open Settings, verify "Orphan agent alerts" toggle exists
   - [ ] Toggle it on
   - [ ] (If possible) Create orphan scenario
   - [ ] Verify notification appears
   - [ ] Click "Clean Up" and verify orphans are killed

4. **Settings persistence:**
   - [ ] Toggle orphan notifications off
   - [ ] Quit and reopen app
   - [ ] Verify setting is still off

**Step 3: Commit any final fixes**

If any issues found, fix and commit.

**Step 4: Final commit**

```bash
git add -A
git commit -m "chore: final polish and testing"
```

---

## Summary

| Task | Description | Files |
|------|-------------|-------|
| 1 | Launch-to-popover | AppDelegate, MenuBarController |
| 2 | ProcessInfo orphan fields | AgentCounter |
| 3 | Orphan detection method | AgentCounter |
| 4 | Kill All button | UsagePopoverView, UsageViewModel, AgentCounter |
| 5 | NotificationService | New file |
| 6 | Wire up orphan detection | UsageViewModel, AppDelegate |
| 7 | Handle notification actions | NotificationService, AppDelegate |
| 8 | Settings toggle | SettingsView, APIKeySettingsView |
| 9 | Testing and polish | All |
