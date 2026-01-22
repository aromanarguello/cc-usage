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
