import Foundation

struct UsageData: Sendable {
    let fiveHour: UsageWindow
    let sevenDay: UsageWindow
    let sevenDaySonnet: UsageWindow?
    let sevenDayOpus: UsageWindow?
    let extraUsage: ExtraUsage?
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

    struct ExtraUsage: Sendable {
        let utilization: Double      // 0-100 percentage
        let usedCredits: Int         // in cents
        let monthlyLimit: Int        // in cents
        let isEnabled: Bool

        var percentage: Int {
            Int(utilization)
        }

        var usedUSD: String {
            let dollars = Double(usedCredits) / 100.0
            return String(format: "$%.2f", dollars)
        }

        var limitUSD: String {
            let dollars = Double(monthlyLimit) / 100.0
            return String(format: "$%.2f", dollars)
        }
    }

    static let placeholder = UsageData(
        fiveHour: UsageWindow(utilization: 0.20, resetsAt: Date().addingTimeInterval(4 * 3600 + 54 * 60)),
        sevenDay: UsageWindow(utilization: 0.51, resetsAt: Date().addingTimeInterval(5 * 24 * 3600)),
        sevenDaySonnet: UsageWindow(utilization: 0.25, resetsAt: Date().addingTimeInterval(5 * 24 * 3600)),
        sevenDayOpus: nil,
        extraUsage: ExtraUsage(utilization: 44.9, usedCredits: 898, monthlyLimit: 2000, isEnabled: true),
        subscription: "Pro",
        lastUpdated: Date()
    )
}

// MARK: - API Response Decoding

struct UsageAPIResponse: Decodable {
    let fiveHour: UsageWindowResponse
    let sevenDay: UsageWindowResponse

    struct UsageWindowResponse: Decodable {
        let utilization: Double
        let resetsAt: Date

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }
    }

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }

    func toUsageData() -> UsageData {
        UsageData(
            fiveHour: UsageData.UsageWindow(
                utilization: fiveHour.utilization / 100.0,  // API returns percentage, convert to decimal
                resetsAt: fiveHour.resetsAt
            ),
            sevenDay: UsageData.UsageWindow(
                utilization: sevenDay.utilization / 100.0,  // API returns percentage, convert to decimal
                resetsAt: sevenDay.resetsAt
            ),
            subscription: "Max",  // Could be read from keychain if needed
            lastUpdated: Date()
        )
    }
}
