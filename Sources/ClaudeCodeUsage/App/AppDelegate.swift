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

        // Setup menu bar
        let credentialService = CredentialService()
        let apiService = UsageAPIService(credentialService: credentialService)
        let viewModel = UsageViewModel(apiService: apiService)
        menuBarController = MenuBarController(viewModel: viewModel)
    }
}
