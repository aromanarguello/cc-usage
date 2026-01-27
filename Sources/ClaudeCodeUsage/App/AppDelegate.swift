import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NotificationServiceDelegate {
    var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        for window in NSApp.windows {
            window.close()
        }

        // Setup notification service
        Task {
            await NotificationService.shared.requestAuthorization()
            await NotificationService.shared.setupDelegate()
            await MainActor.run {
                NotificationService.shared.delegate = self
            }
        }

        // Setup menu bar
        let credentialService = CredentialService()
        let apiService = UsageAPIService(credentialService: credentialService)
        let viewModel = UsageViewModel(apiService: apiService, credentialService: credentialService)
        menuBarController = MenuBarController(viewModel: viewModel, apiService: apiService)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        menuBarController?.showPopover()
        return false
    }

    // MARK: - NotificationServiceDelegate

    func notificationServiceDidRequestCleanup(pids: [Int]) {
        Task {
            _ = await menuBarController?.viewModel.killOrphanedSubagents()
        }
    }

    func notificationServiceDidRequestShowPopover() {
        menuBarController?.showPopover()
    }

    func applicationWillTerminate(_ notification: Notification) {
        menuBarController?.cleanup()
    }
}
