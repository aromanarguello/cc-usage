import SwiftUI

@main
struct ClaudeUsageTrackerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var menuBarController = MenuBarController()

    var body: some Scene {
        Settings {
            Text("Claude Usage Tracker")
        }
    }
}
