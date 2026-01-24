import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide from Dock, only show in menu bar
        NSApp.setActivationPolicy(.accessory)

        // Close any windows that might have opened
        for window in NSApp.windows {
            window.close()
        }

        // Request notification permission
        Task {
            await NotificationService.shared.requestAuthorization()
        }

        // Setup menu bar
        let credentialService = CredentialService()
        let apiService = UsageAPIService(credentialService: credentialService)
        let viewModel = UsageViewModel(apiService: apiService, credentialService: credentialService)
        menuBarController = MenuBarController(viewModel: viewModel)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        menuBarController?.showPopover()
        return false
    }
}
