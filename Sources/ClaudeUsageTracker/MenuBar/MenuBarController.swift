import AppKit
import SwiftUI

@MainActor
final class MenuBarController: ObservableObject {
    private var statusItem: NSStatusItem?

    init() {
        setupStatusItem()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.title = "20%"
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        }
    }
}
