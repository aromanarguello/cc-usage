import SwiftUI

@main
struct ClaudeUsageTrackerApp: App {
    @State private var menuBarController: MenuBarController?

    init() {
        let credentialService = CredentialService()
        let apiService = UsageAPIService(credentialService: credentialService)
        let viewModel = UsageViewModel(apiService: apiService)
        _menuBarController = State(initialValue: MenuBarController(viewModel: viewModel))
    }

    var body: some Scene {
        // Menu bar only app - no main window
        WindowGroup {
            EmptyView()
        }
        .windowResizability(.contentSize)
    }
}
