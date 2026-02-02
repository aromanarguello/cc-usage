import Foundation

struct UsageData: Sendable {
    let fiveHour: UsageWindow
    let sevenDay: UsageWindow
    let sevenDaySonnet: UsageWindow?
    let sevenDayOpus: UsageWindow?
    let extraUsage: ExtraUsage?
    let subscription: String?
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

    // MARK: - Menu Bar Display Logic

    /// Included limits are maxed but extra usage budget remains
    var isUsingExtraUsage: Bool {
        guard let extra = extraUsage, extra.isEnabled, extra.utilization < 100 else {
            return false
        }
        return fiveHour.percentage >= 100 || sevenDay.percentage >= 100
    }

    /// No capacity left anywhere - user is fully blocked
    var isFullyBlocked: Bool {
        let includedMaxed = fiveHour.percentage >= 100 || sevenDay.percentage >= 100
        guard includedMaxed else { return false }
        if let extra = extraUsage, extra.isEnabled {
            return extra.utilization >= 100
        }
        return true
    }

    /// The text to show in the menu bar
    var menuBarDisplay: String {
        if isUsingExtraUsage, let extra = extraUsage {
            return extra.usedUSD
        }
        if isFullyBlocked {
            if let extra = extraUsage, extra.isEnabled {
                return extra.usedUSD
            }
            return "100%"
        }
        return String(format: "%d%%", fiveHour.percentage)
    }

    static let placeholder = UsageData(
        fiveHour: UsageWindow(utilization: 0.20, resetsAt: Date().addingTimeInterval(4 * 3600 + 54 * 60)),
        sevenDay: UsageWindow(utilization: 0.51, resetsAt: Date().addingTimeInterval(5 * 24 * 3600)),
        sevenDaySonnet: UsageWindow(utilization: 0.25, resetsAt: Date().addingTimeInterval(5 * 24 * 3600)),
        sevenDayOpus: nil,
        extraUsage: ExtraUsage(utilization: 44.9, usedCredits: 898, monthlyLimit: 2000, isEnabled: true),
        subscription: nil,  // No longer hardcoded - reflects reality
        lastUpdated: Date()
    )
}

// MARK: - API Response Decoding

struct UsageAPIResponse: Decodable {
    let fiveHour: UsageWindowResponse
    let sevenDay: UsageWindowResponse
    let sevenDaySonnet: UsageWindowResponse?
    let sevenDayOpus: UsageWindowResponse?
    let extraUsage: ExtraUsageResponse?

    struct UsageWindowResponse: Decodable {
        let utilization: Double
        let resetsAt: Date?  // API returns null when utilization is 0%

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }
    }

    struct ExtraUsageResponse: Decodable {
        let utilization: Double?
        let monthlyLimit: Int?
        let usedCredits: Int?
        let isEnabled: Bool

        enum CodingKeys: String, CodingKey {
            case utilization
            case monthlyLimit = "monthly_limit"
            case usedCredits = "used_credits"
            case isEnabled = "is_enabled"
        }
    }

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDaySonnet = "seven_day_sonnet"
        case sevenDayOpus = "seven_day_opus"
        case extraUsage = "extra_usage"
    }

    func toUsageData() -> UsageData {
        // Default reset time when API returns null (e.g., when utilization is 0%)
        let defaultResetTime = Date().addingTimeInterval(5 * 3600) // 5 hours from now

        return UsageData(
            fiveHour: UsageData.UsageWindow(
                utilization: fiveHour.utilization / 100.0,  // API returns percentage, convert to decimal
                resetsAt: fiveHour.resetsAt ?? defaultResetTime
            ),
            sevenDay: UsageData.UsageWindow(
                utilization: sevenDay.utilization / 100.0,  // API returns percentage, convert to decimal
                resetsAt: sevenDay.resetsAt ?? Date().addingTimeInterval(7 * 24 * 3600) // 7 days default
            ),
            sevenDaySonnet: sevenDaySonnet.flatMap { response in
                // Only include if we have a valid reset time
                guard let resetTime = response.resetsAt else { return nil }
                return UsageData.UsageWindow(
                    utilization: response.utilization / 100.0,
                    resetsAt: resetTime
                )
            },
            sevenDayOpus: sevenDayOpus.flatMap { response in
                guard let resetTime = response.resetsAt else { return nil }
                return UsageData.UsageWindow(
                    utilization: response.utilization / 100.0,
                    resetsAt: resetTime
                )
            },
            extraUsage: extraUsage.flatMap { response in
                // Only create ExtraUsage if we have the required values
                guard let utilization = response.utilization,
                      let usedCredits = response.usedCredits,
                      let monthlyLimit = response.monthlyLimit else {
                    return nil
                }
                return UsageData.ExtraUsage(
                    utilization: utilization,
                    usedCredits: usedCredits,
                    monthlyLimit: monthlyLimit,
                    isEnabled: response.isEnabled
                )
            },
            subscription: nil,  // API doesn't provide subscription info
            lastUpdated: Date()
        )
    }
}
