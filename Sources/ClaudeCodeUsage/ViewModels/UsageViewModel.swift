import Foundation
import SwiftUI

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

/// Indicates how stale the usage data is
enum StalenessTier {
    case fresh      // < 2 min - Green, normal
    case recent     // 2-10 min - Default color
    case stale      // 10-60 min - Orange
    case veryStale  // > 1 hour - Red with warning

    var color: Color {
        switch self {
        case .fresh: return .green
        case .recent: return .secondary
        case .stale: return .orange
        case .veryStale: return .red
        }
    }
}

@MainActor
@Observable
final class UsageViewModel {
    private(set) var usageData: UsageData?
    private(set) var errorMessage: String?
    private(set) var refreshState: RefreshState = .idle
    var isLoading: Bool { refreshState.isLoading }
    private(set) var lastFetchTime: Date?
    private(set) var agentCount: AgentCount?
    private(set) var orphanedSubagents: [ProcessInfo] = []
    private(set) var keychainAccessDenied: Bool = false
    private let notificationService = NotificationService.shared

    // Update checking state
    var updateAvailable: Bool = false
    private(set) var latestVersion: String?
    private(set) var downloadURL: String?
    private var lastUpdateCheck: Date?
    private let updateCheckInterval: TimeInterval = 2 * 60 * 60 // 2 hours
    private let wakeDelaySeconds: TimeInterval = 45
    private let updateChecker = UpdateChecker()

    @ObservationIgnored
    @AppStorage("orphanNotificationsEnabled") private var orphanNotificationsEnabled: Bool = true

    @ObservationIgnored
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboardingStorage: Bool = false

    private(set) var showOnboarding: Bool = false

    private let apiService: UsageAPIService
    private let credentialService: CredentialService
    private let agentCounter = AgentCounter()
    private var pollingTask: Task<Void, Never>?

    @ObservationIgnored
    @AppStorage("refreshInterval") private var refreshInterval: Double = 60

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

    init(apiService: UsageAPIService, credentialService: CredentialService) {
        self.apiService = apiService
        self.credentialService = credentialService
    }

    // MARK: - Credential Management

    /// Force a fresh credential fetch by invalidating the cache
    func forceRefresh() async {
        await credentialService.invalidateCache()
        await refresh()
    }

    /// Clears keychain access denied state and retries
    func retryKeychainAccess() async {
        await credentialService.clearAccessDeniedState()
        await credentialService.invalidateCache()
        self.keychainAccessDenied = false
        await refresh()
    }

    /// Clears all OAuth caches and triggers re-authentication
    func clearTokenCache() async {
        await credentialService.clearTokenCache()
        self.keychainAccessDenied = false
        self.usageData = nil  // Clear old data so view transitions correctly on denial
        await refresh()  // Triggers keychain access prompt
    }

    /// Marks onboarding as complete and triggers first refresh
    func completeOnboarding() {
        hasCompletedOnboardingStorage = true
        showOnboarding = false
        Task { await refresh() }
    }

    func refresh() async {
        guard refreshState.canAutoRefresh || refreshState == .needsManualRefresh else { return }

        // Show onboarding on first run before keychain access
        if !hasCompletedOnboardingStorage && usageData == nil && !keychainAccessDenied {
            showOnboarding = true
            refreshState = .idle
            return
        }

        refreshState = .loading
        errorMessage = nil

        do {
            usageData = try await apiService.fetchUsage()
            lastFetchTime = Date()
            // Clear access denied state on success
            self.keychainAccessDenied = false
        } catch let error as CredentialError {
            errorMessage = error.localizedDescription
            // Track if keychain access was denied
            if error.isAccessDenied {
                self.keychainAccessDenied = true
            }
        } catch {
            errorMessage = error.localizedDescription
            // Also check credential service for access denied state
            self.keychainAccessDenied = await credentialService.wasAccessDenied()
        }

        // Also refresh agent count
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

        refreshState = .idle
    }

    func refreshAgentCount() async {
        agentCount = await agentCounter.countAgents()
    }

    func killHangingAgents() async -> Int {
        guard let hanging = agentCount?.hangingSubagents, !hanging.isEmpty else { return 0 }
        let killed = await agentCounter.killHangingAgents(hanging)
        await refreshAgentCount()
        return killed
    }

    func killAllSubagents() async -> Int {
        guard let agents = agentCount, agents.subagents > 0 else { return 0 }
        let subagents = await agentCounter.getAllSubagents()
        let killed = await agentCounter.killProcesses(subagents)
        await refreshAgentCount()
        return killed
    }

    func killOrphanedSubagents() async -> Int {
        guard !orphanedSubagents.isEmpty else { return 0 }
        let pids = orphanedSubagents.map { $0.pid }
        let killed = await agentCounter.killProcesses(orphanedSubagents)
        await notificationService.clearOrphanNotifications(pids: pids)
        orphanedSubagents = []
        await refreshAgentCount()
        return killed
    }

    func startPolling() {
        stopPolling()

        pollingTask = Task {
            while !Task.isCancelled {
                await refresh()
                await checkForUpdateIfNeeded()
                try? await Task.sleep(for: .seconds(refreshInterval))
            }
        }
    }

    /// Background update check - only runs if enough time has passed since last check
    private func checkForUpdateIfNeeded() async {
        // Skip if checked recently
        if let lastCheck = lastUpdateCheck,
           Date().timeIntervalSince(lastCheck) < updateCheckInterval {
            return
        }

        lastUpdateCheck = Date()

        do {
            let result = try await updateChecker.checkForUpdates()
            if result.updateAvailable {
                updateAvailable = true
                latestVersion = result.latestVersion
                downloadURL = result.downloadURL
            }
        } catch {
            // Silent failure for background checks - don't disrupt user
        }
    }

    /// Clears the update available badge (called when popover opens)
    func acknowledgeUpdate() {
        updateAvailable = false
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    /// Called when Mac is about to sleep - pauses all automatic refreshes
    func pauseForSleep() {
        stopPolling()
        refreshState = .pausedForSleep
    }

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
}
