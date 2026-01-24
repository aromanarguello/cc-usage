import Foundation
import SwiftUI

@MainActor
@Observable
final class UsageViewModel {
    private(set) var usageData: UsageData?
    private(set) var errorMessage: String?
    private(set) var isLoading = false
    private(set) var lastFetchTime: Date?
    private(set) var agentCount: AgentCount?
    private(set) var usingManualKey: Bool = false
    private(set) var orphanedSubagents: [ProcessInfo] = []
    private let notificationService = NotificationService.shared

    @ObservationIgnored
    @AppStorage("orphanNotificationsEnabled") private var orphanNotificationsEnabled: Bool = true

    private let apiService: UsageAPIService
    private let credentialService: CredentialService
    private let agentCounter = AgentCounter()
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

    init(apiService: UsageAPIService, credentialService: CredentialService) {
        self.apiService = apiService
        self.credentialService = credentialService
    }

    // MARK: - Credential Management

    var isUsingManualAPIKey: Bool {
        get async {
            return await credentialService.hasManualAPIKey()
        }
    }

    func saveManualAPIKey(_ key: String) async throws {
        try await credentialService.saveManualAPIKey(key)
    }

    func deleteManualAPIKey() async throws {
        try await credentialService.deleteManualAPIKey()
    }

    func validateAPIKeyFormat(_ key: String) async -> Bool {
        return await credentialService.validateAPIKeyFormat(key)
    }

    func refresh() async {
        guard !isLoading else { return }

        isLoading = true
        errorMessage = nil

        do {
            usageData = try await apiService.fetchUsage()
            lastFetchTime = Date()
            // Check auth method
            self.usingManualKey = await credentialService.hasManualAPIKey()
        } catch {
            errorMessage = error.localizedDescription
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

        isLoading = false
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
                try? await Task.sleep(for: .seconds(refreshInterval))
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }
}
