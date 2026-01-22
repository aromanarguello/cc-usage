# Claude Usage Tracker - Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a native macOS menu bar app that displays Claude Code usage limits (5-hour and weekly) in real-time.

**Architecture:** Menu bar app using NSStatusItem with SwiftUI popover. Reads OAuth credentials from macOS Keychain (stored by Claude Code CLI), polls Anthropic API for usage data, displays in glass-morphic dropdown panel.

**Tech Stack:** Swift 6, SwiftUI, macOS 14.0+ (Sonoma), Keychain Services, URLSession

**Reference:** See `docs/plans/2026-01-22-claude-usage-tracker-design.md` for visual design specs.

---

## Task 1: Create Swift Package Structure

**Files:**
- Create: `Package.swift`
- Create: `Sources/ClaudeUsageTracker/App/ClaudeUsageTrackerApp.swift`

**Step 1: Create Package.swift**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeUsageTracker",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ClaudeUsageTracker",
            path: "Sources/ClaudeUsageTracker"
        )
    ]
)
```

**Step 2: Create minimal app entry point**

```swift
import SwiftUI

@main
struct ClaudeUsageTrackerApp: App {
    var body: some Scene {
        Settings {
            Text("Claude Usage Tracker")
        }
    }
}
```

**Step 3: Build to verify setup**

Run: `swift build`
Expected: Build Succeeded

**Step 4: Commit**

```bash
git add Package.swift Sources/
git commit -m "feat: initialize Swift package structure"
```

---

## Task 2: Add MenuBarController with Static Text

**Files:**
- Create: `Sources/ClaudeUsageTracker/MenuBar/MenuBarController.swift`
- Modify: `Sources/ClaudeUsageTracker/App/ClaudeUsageTrackerApp.swift`

**Step 1: Create MenuBarController**

```swift
import AppKit
import SwiftUI

@MainActor
final class MenuBarController: ObservableObject {
    private var statusItem: NSStatusItem?

    init() {
        setupStatusItem()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.title = "20%"
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        }
    }
}
```

**Step 2: Update app to use MenuBarController**

Replace `Sources/ClaudeUsageTracker/App/ClaudeUsageTrackerApp.swift`:

```swift
import SwiftUI

@main
struct ClaudeUsageTrackerApp: App {
    @StateObject private var menuBarController = MenuBarController()

    var body: some Scene {
        Settings {
            Text("Claude Usage Tracker")
        }
    }
}
```

**Step 3: Add Info.plist for menu bar only mode**

Create `Sources/ClaudeUsageTracker/Resources/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
```

**Step 4: Update Package.swift to include resources**

Replace `Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeUsageTracker",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ClaudeUsageTracker",
            path: "Sources/ClaudeUsageTracker",
            resources: [.process("Resources")]
        )
    ]
)
```

**Step 5: Build and run to verify menu bar icon appears**

Run: `swift build && .build/debug/ClaudeUsageTracker &`
Expected: "20%" appears in menu bar

Run: `pkill ClaudeUsageTracker` (to stop the app)

**Step 6: Commit**

```bash
git add -A
git commit -m "feat: add menu bar controller with static percentage display"
```

---

## Task 3: Add Popover with Hardcoded UI

**Files:**
- Create: `Sources/ClaudeUsageTracker/Views/UsagePopoverView.swift`
- Create: `Sources/ClaudeUsageTracker/Views/UsageBarView.swift`
- Modify: `Sources/ClaudeUsageTracker/MenuBar/MenuBarController.swift`

**Step 1: Create UsageBarView component**

```swift
import SwiftUI

struct UsageBarView: View {
    let progress: Double
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.gray.opacity(0.2))

                Capsule()
                    .fill(color)
                    .frame(width: geometry.size.width * min(max(progress, 0), 1))
            }
        }
        .frame(height: 8)
    }
}

#Preview {
    VStack(spacing: 20) {
        UsageBarView(progress: 0.2, color: Color(hex: "4ADE80"))
        UsageBarView(progress: 0.51, color: Color(hex: "F59E0B"))
    }
    .padding()
    .frame(width: 300)
}
```

**Step 2: Create Color extension for hex**

Create `Sources/ClaudeUsageTracker/Extensions/Color+Hex.swift`:

```swift
import SwiftUI

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
```

**Step 3: Create UsagePopoverView**

```swift
import SwiftUI

struct UsagePopoverView: View {
    private let fiveHourUsage: Double = 0.20
    private let weeklyUsage: Double = 0.51
    private let fiveHourResetTime: String = "4h 54m"
    private let weeklyResetTime: String = "Mon 2:59 PM"

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Claude Usage")
                    .font(.headline)
                Spacer()
                Text("Pro")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.orange)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .padding()

            Divider()

            // 5-Hour Window
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "clock")
                        .foregroundColor(.secondary)
                    Text("5-Hour Window")
                    Spacer()
                    Text("\(Int(fiveHourUsage * 100))%")
                        .fontWeight(.medium)
                        .monospacedDigit()
                }

                UsageBarView(progress: fiveHourUsage, color: Color(hex: "4ADE80"))

                Text("Resets in \(fiveHourResetTime)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()

            Divider()

            // Weekly
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "calendar")
                        .foregroundColor(.secondary)
                    Text("Weekly")
                    Spacer()
                    Text("\(Int(weeklyUsage * 100))%")
                        .fontWeight(.medium)
                        .monospacedDigit()
                }

                UsageBarView(progress: weeklyUsage, color: Color(hex: "F59E0B"))

                Text("Resets \(weeklyResetTime)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()

            Divider()

            // Footer
            HStack {
                Text("Updated 0 sec ago")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                Button(action: {}) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            HStack {
                Button("Settings") {}
                    .buttonStyle(.plain)
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .frame(width: 320)
        .background(.ultraThinMaterial)
    }
}

#Preview {
    UsagePopoverView()
}
```

**Step 4: Update MenuBarController to show popover**

Replace `Sources/ClaudeUsageTracker/MenuBar/MenuBarController.swift`:

```swift
import AppKit
import SwiftUI

@MainActor
final class MenuBarController: ObservableObject {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var eventMonitor: Any?

    init() {
        setupStatusItem()
        setupPopover()
        setupEventMonitor()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.title = "20%"
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            button.action = #selector(togglePopover)
            button.target = self
        }
    }

    private func setupPopover() {
        popover = NSPopover()
        popover?.contentSize = NSSize(width: 320, height: 340)
        popover?.behavior = .transient
        popover?.contentViewController = NSHostingController(rootView: UsagePopoverView())
    }

    private func setupEventMonitor() {
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            if let popover = self?.popover, popover.isShown {
                popover.performClose(nil)
            }
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button, let popover = popover else { return }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    deinit {
        if let eventMonitor = eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }
}
```

**Step 5: Build and run to verify popover**

Run: `swift build && .build/debug/ClaudeUsageTracker &`
Expected: Click "20%" in menu bar shows glass-morphic popover with hardcoded data

Run: `pkill ClaudeUsageTracker`

**Step 6: Commit**

```bash
git add -A
git commit -m "feat: add usage popover view with glass-morphic styling"
```

---

## Task 4: Create UsageData Model

**Files:**
- Create: `Sources/ClaudeUsageTracker/Models/UsageData.swift`

**Step 1: Create the model**

```swift
import Foundation

struct UsageData: Sendable {
    let fiveHour: UsageWindow
    let sevenDay: UsageWindow
    let subscription: String
    let lastUpdated: Date

    struct UsageWindow: Sendable {
        let utilization: Double
        let resetsAt: Date

        var percentage: Int {
            Int(utilization * 100)
        }

        func timeUntilReset(from now: Date = Date()) -> String {
            let interval = resetsAt.timeIntervalSince(now)
            guard interval > 0 else { return "Now" }

            let hours = Int(interval) / 3600
            let minutes = (Int(interval) % 3600) / 60

            if hours > 24 {
                let formatter = DateFormatter()
                formatter.dateFormat = "EEE h:mm a"
                return formatter.string(from: resetsAt)
            } else if hours > 0 {
                return "\(hours)h \(minutes)m"
            } else {
                return "\(minutes)m"
            }
        }
    }

    static let placeholder = UsageData(
        fiveHour: UsageWindow(utilization: 0.20, resetsAt: Date().addingTimeInterval(4 * 3600 + 54 * 60)),
        sevenDay: UsageWindow(utilization: 0.51, resetsAt: Date().addingTimeInterval(5 * 24 * 3600)),
        subscription: "Pro",
        lastUpdated: Date()
    )
}

// MARK: - API Response Decoding

struct UsageAPIResponse: Decodable {
    let shortTermUtilization: Double
    let shortTermResetsAt: Date
    let longTermUtilization: Double
    let longTermResetsAt: Date
    let subscription: String?

    enum CodingKeys: String, CodingKey {
        case shortTermUtilization = "short_term_utilization"
        case shortTermResetsAt = "short_term_resets_at"
        case longTermUtilization = "long_term_utilization"
        case longTermResetsAt = "long_term_resets_at"
        case subscription
    }

    func toUsageData() -> UsageData {
        UsageData(
            fiveHour: UsageData.UsageWindow(
                utilization: shortTermUtilization,
                resetsAt: shortTermResetsAt
            ),
            sevenDay: UsageData.UsageWindow(
                utilization: longTermUtilization,
                resetsAt: longTermResetsAt
            ),
            subscription: subscription ?? "Pro",
            lastUpdated: Date()
        )
    }
}
```

**Step 2: Build to verify**

Run: `swift build`
Expected: Build Succeeded

**Step 3: Commit**

```bash
git add -A
git commit -m "feat: add UsageData model with API response decoding"
```

---

## Task 5: Implement CredentialService (Keychain Reading)

**Files:**
- Create: `Sources/ClaudeUsageTracker/Services/CredentialService.swift`

**Step 1: Create CredentialService**

```swift
import Foundation
import Security

enum CredentialError: Error, LocalizedError {
    case notFound
    case invalidData
    case keychainError(OSStatus)
    case tokenNotFound

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "Claude Code credentials not found. Run `claude` to authenticate."
        case .invalidData:
            return "Invalid credential data format."
        case .keychainError(let status):
            return "Keychain error: \(status)"
        case .tokenNotFound:
            return "OAuth token not found in credentials."
        }
    }
}

actor CredentialService {
    private let serviceName = "Claude Code-credentials"

    func getAccessToken() throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                throw CredentialError.notFound
            }
            throw CredentialError.keychainError(status)
        }

        guard let data = result as? Data else {
            throw CredentialError.invalidData
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CredentialError.invalidData
        }

        // Navigate to claudeAiOauth.accessToken
        guard let oauthData = json["claudeAiOauth"] as? [String: Any],
              let accessToken = oauthData["accessToken"] as? String else {
            throw CredentialError.tokenNotFound
        }

        return accessToken
    }
}
```

**Step 2: Build to verify**

Run: `swift build`
Expected: Build Succeeded

**Step 3: Commit**

```bash
git add -A
git commit -m "feat: add CredentialService for Keychain access"
```

---

## Task 6: Implement UsageAPIService

**Files:**
- Create: `Sources/ClaudeUsageTracker/Services/UsageAPIService.swift`

**Step 1: Create UsageAPIService**

```swift
import Foundation

enum APIError: Error, LocalizedError {
    case invalidURL
    case unauthorized
    case networkError(Error)
    case decodingError(Error)
    case serverError(Int, String?)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid API URL"
        case .unauthorized:
            return "Session expired. Re-login to Claude Code."
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .decodingError(let error):
            return "Failed to parse response: \(error.localizedDescription)"
        case .serverError(let code, let message):
            return "Server error \(code): \(message ?? "Unknown")"
        }
    }
}

actor UsageAPIService {
    private let baseURL = "https://api.anthropic.com/api/oauth/usage"
    private let credentialService: CredentialService

    init(credentialService: CredentialService) {
        self.credentialService = credentialService
    }

    func fetchUsage() async throws -> UsageData {
        let accessToken = try await credentialService.getAccessToken()

        guard let url = URL(string: baseURL) else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        let (data, response) : (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw APIError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.networkError(URLError(.badServerResponse))
        }

        switch httpResponse.statusCode {
        case 200:
            break
        case 401:
            throw APIError.unauthorized
        default:
            let message = String(data: data, encoding: .utf8)
            throw APIError.serverError(httpResponse.statusCode, message)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        do {
            let apiResponse = try decoder.decode(UsageAPIResponse.self, from: data)
            return apiResponse.toUsageData()
        } catch {
            throw APIError.decodingError(error)
        }
    }
}
```

**Step 2: Build to verify**

Run: `swift build`
Expected: Build Succeeded

**Step 3: Commit**

```bash
git add -A
git commit -m "feat: add UsageAPIService for Anthropic API calls"
```

---

## Task 7: Create UsageViewModel to Wire Data

**Files:**
- Create: `Sources/ClaudeUsageTracker/ViewModels/UsageViewModel.swift`

**Step 1: Create UsageViewModel**

```swift
import Foundation
import SwiftUI

@MainActor
@Observable
final class UsageViewModel {
    private(set) var usageData: UsageData?
    private(set) var errorMessage: String?
    private(set) var isLoading = false
    private(set) var lastFetchTime: Date?

    private let apiService: UsageAPIService
    private var pollingTask: Task<Void, Never>?

    var timeSinceUpdate: String {
        guard let lastFetchTime else { return "Never" }
        let seconds = Int(Date().timeIntervalSince(lastFetchTime))
        if seconds < 60 {
            return "\(seconds) sec ago"
        } else {
            let minutes = seconds / 60
            return "\(minutes) min ago"
        }
    }

    init(apiService: UsageAPIService) {
        self.apiService = apiService
    }

    func refresh() async {
        guard !isLoading else { return }

        isLoading = true
        errorMessage = nil

        do {
            usageData = try await apiService.fetchUsage()
            lastFetchTime = Date()
        } catch {
            errorMessage = error.localizedDescription
            // Keep existing data on error
        }

        isLoading = false
    }

    func startPolling(interval: TimeInterval = 60) {
        stopPolling()

        pollingTask = Task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }
}
```

**Step 2: Build to verify**

Run: `swift build`
Expected: Build Succeeded

**Step 3: Commit**

```bash
git add -A
git commit -m "feat: add UsageViewModel with polling support"
```

---

## Task 8: Connect ViewModel to UI

**Files:**
- Modify: `Sources/ClaudeUsageTracker/Views/UsagePopoverView.swift`
- Modify: `Sources/ClaudeUsageTracker/MenuBar/MenuBarController.swift`
- Modify: `Sources/ClaudeUsageTracker/App/ClaudeUsageTrackerApp.swift`

**Step 1: Update UsagePopoverView to use ViewModel**

Replace `Sources/ClaudeUsageTracker/Views/UsagePopoverView.swift`:

```swift
import SwiftUI

struct UsagePopoverView: View {
    @Bindable var viewModel: UsageViewModel
    var onOpenSettings: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Claude Usage")
                    .font(.headline)
                Spacer()
                if let subscription = viewModel.usageData?.subscription {
                    Text(subscription)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.orange)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
            .padding()

            Divider()

            if let error = viewModel.errorMessage, viewModel.usageData == nil {
                // Error state (no cached data)
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(32)
            } else if let data = viewModel.usageData {
                // 5-Hour Window
                usageSection(
                    icon: "clock",
                    title: "5-Hour Window",
                    window: data.fiveHour,
                    color: Color(hex: "4ADE80"),
                    resetPrefix: "Resets in"
                )

                Divider()

                // Weekly
                usageSection(
                    icon: "calendar",
                    title: "Weekly",
                    window: data.sevenDay,
                    color: Color(hex: "F59E0B"),
                    resetPrefix: "Resets"
                )
            } else if viewModel.isLoading {
                ProgressView()
                    .padding(32)
            }

            Divider()

            // Footer
            HStack {
                if let error = viewModel.errorMessage, viewModel.usageData != nil {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundColor(.orange)
                        .font(.caption)
                }
                Text("Updated \(viewModel.timeSinceUpdate)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                Button(action: {
                    Task { await viewModel.refresh() }
                }) {
                    if viewModel.isLoading {
                        ProgressView()
                            .scaleEffect(0.6)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isLoading)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            HStack {
                Button("Settings") {
                    onOpenSettings()
                }
                .buttonStyle(.plain)
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .frame(width: 320)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private func usageSection(
        icon: String,
        title: String,
        window: UsageData.UsageWindow,
        color: Color,
        resetPrefix: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(.secondary)
                Text(title)
                Spacer()
                Text("\(window.percentage)%")
                    .fontWeight(.medium)
                    .monospacedDigit()
            }

            UsageBarView(progress: window.utilization, color: color)

            Text("\(resetPrefix) \(window.timeUntilReset())")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
    }
}

#Preview {
    let credentialService = CredentialService()
    let apiService = UsageAPIService(credentialService: credentialService)
    let viewModel = UsageViewModel(apiService: apiService)
    return UsagePopoverView(viewModel: viewModel)
}
```

**Step 2: Update MenuBarController**

Replace `Sources/ClaudeUsageTracker/MenuBar/MenuBarController.swift`:

```swift
import AppKit
import SwiftUI

@MainActor
final class MenuBarController: ObservableObject {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var eventMonitor: Any?

    let viewModel: UsageViewModel

    init(viewModel: UsageViewModel) {
        self.viewModel = viewModel
        setupStatusItem()
        setupPopover()
        setupEventMonitor()
        startPolling()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.title = "--%"
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            button.action = #selector(togglePopover)
            button.target = self
        }
    }

    private func setupPopover() {
        popover = NSPopover()
        popover?.contentSize = NSSize(width: 320, height: 340)
        popover?.behavior = .transient
        popover?.contentViewController = NSHostingController(
            rootView: UsagePopoverView(viewModel: viewModel)
        )
    }

    private func setupEventMonitor() {
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            if let popover = self?.popover, popover.isShown {
                popover.performClose(nil)
            }
        }
    }

    private func startPolling() {
        viewModel.startPolling()

        // Observe viewModel changes to update status item
        Task {
            while true {
                try? await Task.sleep(for: .seconds(1))
                updateStatusItemTitle()
            }
        }
    }

    private func updateStatusItemTitle() {
        guard let button = statusItem?.button else { return }

        if let data = viewModel.usageData {
            button.title = "\(data.fiveHour.percentage)%"
        } else if viewModel.errorMessage != nil {
            button.title = "--"
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button, let popover = popover else { return }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    deinit {
        if let eventMonitor = eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        viewModel.stopPolling()
    }
}
```

**Step 3: Update App entry point**

Replace `Sources/ClaudeUsageTracker/App/ClaudeUsageTrackerApp.swift`:

```swift
import SwiftUI

@main
struct ClaudeUsageTrackerApp: App {
    @State private var menuBarController: MenuBarController?

    init() {
        let credentialService = CredentialService()
        let apiService = UsageAPIService(credentialService: credentialService)
        let viewModel = UsageViewModel(apiService: apiService)
        _menuBarController = State(initialValue: MenuBarController(viewModel: viewModel))
    }

    var body: some Scene {
        Settings {
            Text("Claude Usage Tracker Settings")
                .frame(width: 300, height: 200)
        }
    }
}
```

**Step 4: Build and test**

Run: `swift build && .build/debug/ClaudeUsageTracker &`
Expected: App starts, shows "--%" initially, then fetches real data if Claude Code is authenticated

Run: `pkill ClaudeUsageTracker`

**Step 5: Commit**

```bash
git add -A
git commit -m "feat: wire up real data to UI with polling"
```

---

## Task 9: Add Settings View

**Files:**
- Create: `Sources/ClaudeUsageTracker/Views/SettingsView.swift`
- Modify: `Sources/ClaudeUsageTracker/App/ClaudeUsageTrackerApp.swift`

**Step 1: Create SettingsView**

```swift
import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @AppStorage("refreshInterval") private var refreshInterval: Double = 60
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
        }
        .formStyle(.grouped)
        .frame(width: 350, height: 150)
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

**Step 2: Update App to use SettingsView**

Replace `Sources/ClaudeUsageTracker/App/ClaudeUsageTrackerApp.swift`:

```swift
import SwiftUI

@main
struct ClaudeUsageTrackerApp: App {
    @State private var menuBarController: MenuBarController?

    init() {
        let credentialService = CredentialService()
        let apiService = UsageAPIService(credentialService: credentialService)
        let viewModel = UsageViewModel(apiService: apiService)
        _menuBarController = State(initialValue: MenuBarController(viewModel: viewModel))
    }

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}
```

**Step 3: Build and test**

Run: `swift build && .build/debug/ClaudeUsageTracker &`
Expected: Settings window opens from menu

Run: `pkill ClaudeUsageTracker`

**Step 4: Commit**

```bash
git add -A
git commit -m "feat: add settings view with refresh interval and launch at login"
```

---

## Task 10: Polish and Final Integration

**Files:**
- Modify: `Sources/ClaudeUsageTracker/ViewModels/UsageViewModel.swift`
- Modify: `Sources/ClaudeUsageTracker/MenuBar/MenuBarController.swift`

**Step 1: Update ViewModel to respect refresh interval**

Replace `Sources/ClaudeUsageTracker/ViewModels/UsageViewModel.swift`:

```swift
import Foundation
import SwiftUI

@MainActor
@Observable
final class UsageViewModel {
    private(set) var usageData: UsageData?
    private(set) var errorMessage: String?
    private(set) var isLoading = false
    private(set) var lastFetchTime: Date?

    private let apiService: UsageAPIService
    private var pollingTask: Task<Void, Never>?

    @ObservationIgnored
    @AppStorage("refreshInterval") private var refreshInterval: Double = 60

    var timeSinceUpdate: String {
        guard let lastFetchTime else { return "Never" }
        let seconds = Int(Date().timeIntervalSince(lastFetchTime))
        if seconds < 60 {
            return "\(seconds) sec ago"
        } else {
            let minutes = seconds / 60
            return "\(minutes) min ago"
        }
    }

    init(apiService: UsageAPIService) {
        self.apiService = apiService
    }

    func refresh() async {
        guard !isLoading else { return }

        isLoading = true
        errorMessage = nil

        do {
            usageData = try await apiService.fetchUsage()
            lastFetchTime = Date()
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func startPolling() {
        stopPolling()

        pollingTask = Task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(refreshInterval))
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }
}
```

**Step 2: Update MenuBarController with better status item updates**

Replace `Sources/ClaudeUsageTracker/MenuBar/MenuBarController.swift`:

```swift
import AppKit
import SwiftUI
import Combine

@MainActor
final class MenuBarController: ObservableObject {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var eventMonitor: Any?
    private var updateTask: Task<Void, Never>?

    let viewModel: UsageViewModel

    init(viewModel: UsageViewModel) {
        self.viewModel = viewModel
        setupStatusItem()
        setupPopover()
        setupEventMonitor()
        startPolling()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.title = "--%"
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            button.action = #selector(togglePopover)
            button.target = self
        }
    }

    private func setupPopover() {
        popover = NSPopover()
        popover?.contentSize = NSSize(width: 320, height: 340)
        popover?.behavior = .transient
        popover?.contentViewController = NSHostingController(
            rootView: UsagePopoverView(viewModel: viewModel) {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        )
    }

    private func setupEventMonitor() {
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            if let popover = self?.popover, popover.isShown {
                popover.performClose(nil)
            }
        }
    }

    private func startPolling() {
        viewModel.startPolling()

        updateTask = Task {
            while !Task.isCancelled {
                updateStatusItemTitle()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func updateStatusItemTitle() {
        guard let button = statusItem?.button else { return }

        if let data = viewModel.usageData {
            let percentage = data.fiveHour.percentage
            button.title = String(format: "%d%%", percentage)

            // Color coding based on usage
            if percentage >= 90 {
                button.contentTintColor = .systemRed
            } else if percentage >= 70 {
                button.contentTintColor = .systemOrange
            } else {
                button.contentTintColor = nil
            }
        } else if viewModel.isLoading {
            button.title = "..."
            button.contentTintColor = nil
        } else if viewModel.errorMessage != nil {
            button.title = "--"
            button.contentTintColor = .systemOrange
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button, let popover = popover else { return }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // Refresh when opening popover
            Task { await viewModel.refresh() }
        }
    }

    deinit {
        if let eventMonitor = eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        updateTask?.cancel()
        viewModel.stopPolling()
    }
}
```

**Step 3: Build final version**

Run: `swift build -c release`
Expected: Build Succeeded

**Step 4: Test the app**

Run: `.build/release/ClaudeUsageTracker &`
Expected: Full functionality working

Run: `pkill ClaudeUsageTracker`

**Step 5: Commit**

```bash
git add -A
git commit -m "feat: polish UI with color coding and settings integration"
```

---

## Task 11: Create README

**Files:**
- Create: `README.md`

**Step 1: Create README**

```markdown
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
```

**Step 2: Commit**

```bash
git add README.md
git commit -m "docs: add README with build and usage instructions"
```

---

## Summary

This plan creates a complete macOS menu bar app with:
- 11 tasks, each with bite-sized steps
- TDD approach where applicable
- Frequent commits after each task
- Complete code provided (no placeholders)

The app will read Claude Code OAuth credentials from macOS Keychain, poll the Anthropic API for usage data, and display it in a sleek glass-morphic menu bar dropdown.
