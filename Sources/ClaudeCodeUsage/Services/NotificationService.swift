import Foundation
import UserNotifications

actor NotificationService: NSObject {
    static let shared = NotificationService()

    private var isAuthorized = false
    private var notifiedOrphanPIDs: Set<Int> = []

    // Notification identifiers
    private let orphanCategoryID = "ORPHAN_AGENTS"
    private let cleanUpActionID = "CLEAN_UP"
    private let ignoreActionID = "IGNORE"

    override init() {
        super.init()
    }

    func requestAuthorization() async {
        let center = UNUserNotificationCenter.current()

        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            isAuthorized = granted

            if granted {
                await setupNotificationCategories()
            }
        } catch {
            print("Notification authorization failed: \(error)")
        }
    }

    private func setupNotificationCategories() async {
        let cleanUpAction = UNNotificationAction(
            identifier: cleanUpActionID,
            title: "Clean Up",
            options: [.foreground]
        )

        let ignoreAction = UNNotificationAction(
            identifier: ignoreActionID,
            title: "Ignore",
            options: []
        )

        let orphanCategory = UNNotificationCategory(
            identifier: orphanCategoryID,
            actions: [cleanUpAction, ignoreAction],
            intentIdentifiers: [],
            options: []
        )

        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories([orphanCategory])
    }

    func notifyOrphansDetected(count: Int, pids: [Int]) async {
        guard isAuthorized else { return }

        // Don't re-notify for same orphans
        let newPIDs = Set(pids).subtracting(notifiedOrphanPIDs)
        guard !newPIDs.isEmpty else { return }

        notifiedOrphanPIDs.formUnion(newPIDs)

        let content = UNMutableNotificationContent()
        content.title = "ClaudeCodeUsage"
        content.body = "\(count) orphaned subagent\(count == 1 ? "" : "s") detected"
        content.subtitle = "Parent session ended"
        content.sound = .default
        content.categoryIdentifier = orphanCategoryID
        content.userInfo = ["pids": pids]

        let request = UNNotificationRequest(
            identifier: "orphan-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            print("Failed to send notification: \(error)")
        }
    }

    func clearOrphanNotifications(pids: [Int]) {
        notifiedOrphanPIDs.subtract(pids)
    }

    func resetNotificationState() {
        notifiedOrphanPIDs.removeAll()
    }
}
