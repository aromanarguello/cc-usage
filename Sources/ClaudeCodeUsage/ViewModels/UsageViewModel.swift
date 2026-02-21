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

enum RefreshError: Error, LocalizedError {
    case timeout

    var errorDescription: String? {
        switch self {
        case .timeout:
            return "Request timed out. Tap to retry."
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
    private let wakeDelaySeconds: TimeInterval = 5
    private let refreshTimeoutSeconds: TimeInterval = 30
    private let maxRetryAttempts = 3
    private let initialRetryDelaySeconds: TimeInterval = 2
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
    private var currentRefreshTask: Task<Void, Never>?
    private var loadingStartTime: Date?
    private var lastPollingHeartbeat: Date?
    private var wakeTask: Task<Void, Never>?

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
        await refresh(userInitiated: true)
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
        Task { await refresh(userInitiated: true) }
    }

    /// Wraps an async operation with a timeout
    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
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

    /// Determines if an error is likely transient and worth retrying
    private func isTransientError(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .networkConnectionLost, .notConnectedToInternet,
                 .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return true
            default:
                return false
            }
        }
        if error is RefreshError {
            return true  // Our timeout is retryable
        }
        return false
    }

    func refresh(userInitiated: Bool = false) async {
        #if DEBUG
        print("[UsageViewModel] refresh called, userInitiated: \(userInitiated), refreshState: \(refreshState)")
        #endif

        // Cancel any stuck previous refresh if user-initiated
        if userInitiated {
            currentRefreshTask?.cancel()
            // Clear the keychain denial cooldown when user manually retries
            await credentialService.clearAccessDeniedState()
            #if DEBUG
            print("[UsageViewModel] Cleared access denied state for user-initiated refresh")
            #endif
        }

        // Safety valve: if loading state has been stuck for >45s, reset it.
        // This prevents the polling loop from permanently stalling due to a hung task.
        if case .loading = refreshState, let start = loadingStartTime,
           Date().timeIntervalSince(start) > 45 {
            #if DEBUG
            print("[UsageViewModel] Resetting stuck loading state (>\(Int(Date().timeIntervalSince(start)))s)")
            #endif
            currentRefreshTask?.cancel()
            refreshState = .idle
            loadingStartTime = nil
        }

        guard refreshState.canAutoRefresh || refreshState == .needsManualRefresh || userInitiated else {
            #if DEBUG
            print("[UsageViewModel] refresh blocked by guard: refreshState=\(refreshState), userInitiated=\(userInitiated)")
            #endif
            return
        }

        // Show onboarding on first run before keychain access
        if !hasCompletedOnboardingStorage && usageData == nil && !keychainAccessDenied {
            showOnboarding = true
            refreshState = .idle
            return
        }

        // Check for account switches by comparing cached token vs Claude's keychain.
        // Throttled internally to every 5 minutes. If a switch is detected, caches are
        // invalidated and the fetch below will pick up the new account's token.
        if await credentialService.syncWithSourceIfNeeded() {
            // Clear stale data so the old account's numbers don't show
            // while the new token is being fetched
            usageData = nil
            #if DEBUG
            print("[UsageViewModel] Account switch detected, caches invalidated")
            #endif
        }

        refreshState = .loading
        loadingStartTime = Date()
        errorMessage = nil

        currentRefreshTask = Task {
            var lastError: Error?
            var attemptCount = 0

            while attemptCount < maxRetryAttempts {
                do {
                    usageData = try await withTimeout(seconds: refreshTimeoutSeconds) {
                        try await self.apiService.fetchUsage(allowPrompt: userInitiated)
                    }
                    lastFetchTime = Date()
                    self.keychainAccessDenied = false
                    lastError = nil
                    #if DEBUG
                    print("[UsageViewModel] Successfully fetched usage data: \(usageData?.fiveHour.percentage ?? -1)%")
                    #endif
                    break  // Success, exit retry loop
                } catch let error as CredentialError {
                    // Credential errors are not retryable
                    lastError = error
                    errorMessage = error.localizedDescription
                    #if DEBUG
                    print("[UsageViewModel] Credential error: \(error)")
                    #endif
                    if error.isAccessDenied {
                        self.keychainAccessDenied = true
                        #if DEBUG
                        print("[UsageViewModel] Keychain access denied")
                        #endif
                    }
                    break  // Don't retry credential errors
                } catch let error as APIError where error.isUnauthorized {
                    // 401 with setup token: expired, revoked, or lacks required scopes — clear it
                    if await credentialService.hasSetupToken() {
                        await credentialService.clearSetupToken()
                        lastError = error
                        errorMessage = "Setup token expired. Re-run `claude setup-token` and paste a new token."
                        break
                    }
                    lastError = error
                    errorMessage = error.localizedDescription
                    break
                } catch {
                    lastError = error
                    attemptCount += 1

                    // Only retry transient errors
                    if isTransientError(error) && attemptCount < maxRetryAttempts {
                        let delay = initialRetryDelaySeconds * pow(2, Double(attemptCount - 1))
                        #if DEBUG
                        print("[UsageViewModel] Transient error, retrying in \(delay)s (attempt \(attemptCount)/\(maxRetryAttempts))")
                        #endif
                        try? await Task.sleep(for: .seconds(delay))
                        if Task.isCancelled { break }
                    } else {
                        errorMessage = error.localizedDescription
                        self.keychainAccessDenied = await credentialService.wasAccessDenied()
                        break
                    }
                }
            }

            // Set error message if all retries failed
            if let error = lastError, errorMessage == nil {
                errorMessage = error.localizedDescription
                self.keychainAccessDenied = await credentialService.wasAccessDenied()
            }

            refreshState = .idle
            loadingStartTime = nil
        }

        await currentRefreshTask?.value

        // Agent counting and orphan detection run AFTER refresh completes
        // as fire-and-forget tasks — they must never block the polling loop
        Task { @MainActor [agentCounter, notificationService, orphanNotificationsEnabled] in
            let count = await agentCounter.countAgents()
            self.agentCount = count

            if orphanNotificationsEnabled {
                let orphans = await agentCounter.detectOrphanedSubagents()
                if !orphans.isEmpty {
                    self.orphanedSubagents = orphans
                    await notificationService.notifyOrphansDetected(
                        count: orphans.count,
                        pids: orphans.map { $0.pid }
                    )
                } else {
                    self.orphanedSubagents = []
                }
            }
        }
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
                lastPollingHeartbeat = Date()
                #if DEBUG
                print("[UsageViewModel] Polling loop: starting refresh")
                #endif
                await refresh(userInitiated: false)
                #if DEBUG
                print("[UsageViewModel] Polling loop: refresh done, sleeping \(refreshInterval)s")
                #endif
                // Update check runs as fire-and-forget — must never block the loop
                Task { await self.checkForUpdateIfNeeded() }
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
            let result = try await withTimeout(seconds: 15) {
                try await self.updateChecker.checkForUpdates()
            }
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

    /// Watchdog: restarts polling if the loop has stalled.
    /// Called periodically from MenuBarController's title update loop.
    func ensurePolling() {
        // Don't restart during sleep/wake transitions
        if case .pausedForSleep = refreshState { return }
        if case .wakingUp = refreshState { return }

        let staleThreshold = max(refreshInterval * 3, 180)
        let isStalled: Bool
        if let heartbeat = lastPollingHeartbeat {
            isStalled = Date().timeIntervalSince(heartbeat) > staleThreshold
        } else {
            isStalled = pollingTask == nil
        }

        if isStalled {
            #if DEBUG
            print("[UsageViewModel] Polling watchdog: restarting stalled polling loop")
            #endif
            startPolling()
        }
    }

    /// Called when Mac is about to sleep - pauses all automatic refreshes
    /// and attempts to warm the credential cache
    func pauseForSleep() async {
        stopPolling()
        wakeTask?.cancel()
        wakeTask = nil

        // Warm credential cache before sleep
        // This ensures we have a fresh token when we wake
        _ = await credentialService.warmCacheForSleep()

        refreshState = .pausedForSleep
    }

    /// Called when Mac wakes - waits briefly for network to reconnect, then resumes polling
    func resumeAfterWake() {
        wakeTask?.cancel()
        wakeTask = Task {
            // Brief delay to let network reconnect after wake
            let resumeAt = Date().addingTimeInterval(wakeDelaySeconds)
            refreshState = .wakingUp(resumeAt: resumeAt)

            try? await Task.sleep(for: .seconds(wakeDelaySeconds))
            guard !Task.isCancelled, case .wakingUp = refreshState else { return }
            refreshState = .idle
            startPolling()
        }
    }

}
