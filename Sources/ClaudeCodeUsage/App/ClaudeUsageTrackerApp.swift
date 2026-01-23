import SwiftUI

@main
struct ClaudeUsageTrackerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Menu bar only app - use Settings instead of WindowGroup to avoid empty window
        Settings {
            EmptyView()
        }
    }
}
