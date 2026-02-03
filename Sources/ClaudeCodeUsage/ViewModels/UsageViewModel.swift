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

        guard refreshState.canAutoRefresh || refreshState == .needsManualRefresh || userInitiated else {
            #if DEBUG
            print("[UsageViewModel] refresh blocked by guard: refreshState=\(refreshState), userInitiated=\(userInitiated)")
            #endif
            return
        }

        // Check for account switch before fetching
        // This detects when user ran `claude logout && claude login` with different account
        let accountSwitched = await credentialService.syncWithSourceIfNeeded()
        #if DEBUG
        if accountSwitched {
            print("[UsageViewModel] Account switch detected, caches invalidated")
        }
        #endif

        // For automatic refreshes, check if we can proceed without prompting
        // However, if we already have data, keep trying - don't block indefinitely
        if !userInitiated {
            let canRefresh = await canRefreshSilently()
            if !canRefresh {
                #if DEBUG
                print("[UsageViewModel] Auto-refresh blocked: canRefreshSilently() returned false")
                #endif
                // Check if the issue is that interaction is required
                let status = await credentialService.preflightClaudeKeychainAccess()

                // Only block if we have no data yet OR if interaction is required
                // For .notFound or .failure, let it fail naturally with proper error handling
                if usageData == nil || status == .interactionRequired {
                    refreshState = .needsManualRefresh
                    return
                } else {
                    #if DEBUG
                    print("[UsageViewModel] Allowing refresh attempt despite credential concerns (status: \(status), have existing data)")
                    #endif
                }
            }
        }

        // Show onboarding on first run before keychain access
        if !hasCompletedOnboardingStorage && usageData == nil && !keychainAccessDenied {
            showOnboarding = true
            refreshState = .idle
            return
        }

        refreshState = .loading
        errorMessage = nil

        currentRefreshTask = Task {
            var lastError: Error?
            var attemptCount = 0

            while attemptCount < maxRetryAttempts {
                do {
                    usageData = try await withTimeout(seconds: refreshTimeoutSeconds) {
                        try await self.apiService.fetchUsage()
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

        await currentRefreshTask?.value
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
            // Bootstrap: If onboarding is complete but we have no cached token,
            // do a user-initiated refresh to populate the cache.
            // This prevents getting stuck in needsManualRefresh on app launch.
            if hasCompletedOnboardingStorage {
                let canRefresh = await canRefreshSilently()
                if !canRefresh {
                    #if DEBUG
                    print("[UsageViewModel] Bootstrap refresh: no cached credentials, doing user-initiated refresh")
                    #endif
                    await refresh(userInitiated: true)
                }
            }

            while !Task.isCancelled {
                #if DEBUG
                print("[UsageViewModel] Auto-refresh triggered (interval: \(refreshInterval)s)")
                #endif
                await refresh(userInitiated: false)
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
    /// and attempts to warm the credential cache
    func pauseForSleep() async {
        stopPolling()

        // Warm credential cache before sleep
        // This ensures we have a fresh token when we wake
        _ = await credentialService.warmCacheForSleep()

        refreshState = .pausedForSleep
    }

    /// Called when Mac wakes - attempts immediate refresh if cache is warm,
    /// otherwise waits briefly before resuming
    func resumeAfterWake() {
        Task {
            // First, try an immediate refresh if we have cached credentials
            // This provides instant feedback when cache is warm
            let canRefresh = await canRefreshSilently()

            if canRefresh {
                // Cache is warm, try immediate refresh
                refreshState = .loading
                await refresh(userInitiated: false)
                startPolling()
            } else {
                // Cache cold or interaction required - wait briefly then resume
                let resumeAt = Date().addingTimeInterval(wakeDelaySeconds)
                refreshState = .wakingUp(resumeAt: resumeAt)

                try? await Task.sleep(for: .seconds(wakeDelaySeconds))
                guard case .wakingUp = refreshState else { return }
                refreshState = .idle
                startPolling()
            }
        }
    }

    /// Checks if automatic refresh can proceed without user interaction
    /// Returns false if keychain access would require user prompt
    private func canRefreshSilently() async -> Bool {
        // Environment variable always works
        if await credentialService.hasEnvironmentToken() {
            #if DEBUG
            print("[UsageViewModel] canRefreshSilently: true (environment token)")
            #endif
            return true
        }

        // If we have a warm cached token, we can definitely refresh
        if await credentialService.hasWarmCachedToken() {
            #if DEBUG
            print("[UsageViewModel] canRefreshSilently: true (warm cached token)")
            #endif
            return true
        }

        // If we have any cached token (memory or app keychain), try it
        if await credentialService.hasCachedToken() {
            #if DEBUG
            print("[UsageViewModel] canRefreshSilently: true (cached token)")
            #endif
            return true
        }

        // Check if keychain access would require interaction
        let status = await credentialService.preflightClaudeKeychainAccess()
        #if DEBUG
        print("[UsageViewModel] canRefreshSilently: preflight status = \(status)")
        #endif
        switch status {
        case .allowed:
            return true
        case .interactionRequired:
            return false
        case .notFound, .failure:
            return true  // Let it fail naturally with proper error handling
        }
    }
}
