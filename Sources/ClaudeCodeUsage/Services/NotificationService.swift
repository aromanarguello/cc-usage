import Foundation
@preconcurrency import UserNotifications

@MainActor
protocol NotificationServiceDelegate: AnyObject {
    func notificationServiceDidRequestCleanup(pids: [Int])
    func notificationServiceDidRequestShowPopover()
}

actor NotificationService: NSObject {
    static let shared = NotificationService()

    private var isAuthorized = false
    private var notifiedOrphanPIDs: Set<Int> = []

    // Notification identifiers
    private let orphanCategoryID = "ORPHAN_AGENTS"
    private let cleanUpActionID = "CLEAN_UP"
    private let ignoreActionID = "IGNORE"

    nonisolated(unsafe) weak var delegate: NotificationServiceDelegate?

    override init() {
        super.init()
    }

    func setupDelegate() async {
        guard Bundle.main.bundleIdentifier != nil else { return }
        await MainActor.run {
            UNUserNotificationCenter.current().delegate = self
        }
    }

    func requestAuthorization() async {
        // UNUserNotificationCenter requires a proper app bundle - skip if running from raw executable
        guard Bundle.main.bundleIdentifier != nil else {
            #if DEBUG
            print("[NotificationService] Skipping notifications - no bundle identifier (debug build)")
            #endif
            return
        }

        // UNUserNotificationCenter.current() must be called from main thread
        let center = await MainActor.run { UNUserNotificationCenter.current() }

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

        await MainActor.run {
            let center = UNUserNotificationCenter.current()
            center.setNotificationCategories([orphanCategory])
        }
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
            let center = await MainActor.run { UNUserNotificationCenter.current() }
            try await center.add(request)
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

// MARK: - UNUserNotificationCenterDelegate
extension NotificationService: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let pids = userInfo["pids"] as? [Int] ?? []
        let actionIdentifier = response.actionIdentifier

        Task { @MainActor in
            switch actionIdentifier {
            case "CLEAN_UP":
                self.delegate?.notificationServiceDidRequestCleanup(pids: pids)
            case UNNotificationDefaultActionIdentifier:
                // User tapped the notification body
                self.delegate?.notificationServiceDidRequestShowPopover()
            default:
                break
            }
            completionHandler()
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void
    ) {
        // Show notification even when app is in foreground
        completionHandler([.banner, .sound])
    }
}
