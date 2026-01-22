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
