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
        } catch {
            errorMessage = error.localizedDescription
        }

        // Also refresh agent count
        agentCount = await agentCounter.countAgents()

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
