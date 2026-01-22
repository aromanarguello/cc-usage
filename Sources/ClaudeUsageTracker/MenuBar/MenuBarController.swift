import AppKit
import SwiftUI

@MainActor
final class MenuBarController: ObservableObject {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private nonisolated(unsafe) var eventMonitor: Any?
    private var updateTask: Task<Void, Never>?

    let viewModel: UsageViewModel

    init(viewModel: UsageViewModel) {
        self.viewModel = viewModel
        setupStatusItem()
        setupPopover()
        setupEventMonitor()
        startPolling()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.title = "--%"
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            button.action = #selector(togglePopover)
            button.target = self
        }
    }

    private func setupPopover() {
        popover = NSPopover()
        popover?.contentSize = NSSize(width: 320, height: 340)
        popover?.behavior = .transient
        popover?.contentViewController = NSHostingController(
            rootView: UsagePopoverView(viewModel: viewModel)
        )
    }

    private func setupEventMonitor() {
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            if let popover = self?.popover, popover.isShown {
                popover.performClose(nil)
            }
        }
    }

    private func startPolling() {
        viewModel.startPolling()

        // Observe viewModel changes to update status item
        updateTask = Task {
            while !Task.isCancelled {
                updateStatusItemTitle()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func updateStatusItemTitle() {
        guard let button = statusItem?.button else { return }

        if let data = viewModel.usageData {
            button.title = "\(data.fiveHour.percentage)%"
        } else if viewModel.errorMessage != nil {
            button.title = "--"
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button, let popover = popover else { return }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    deinit {
        updateTask?.cancel()
        if let eventMonitor = eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }
}
