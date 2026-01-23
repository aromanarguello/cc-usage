import AppKit
import SwiftUI
import Combine

@MainActor
final class MenuBarController: ObservableObject {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    nonisolated(unsafe) private var eventMonitor: Any?
    nonisolated(unsafe) private var updateTask: Task<Void, Never>?

    let viewModel: UsageViewModel

    init(viewModel: UsageViewModel) {
        self.viewModel = viewModel
        setupStatusItem()
        setupPopover()
        setupEventMonitor()
        startPolling()
    }

    nonisolated deinit {
        if let eventMonitor = eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        updateTask?.cancel()
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
        // Match UsagePopoverView's fixed width of 320pt
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
            let percentage = data.fiveHour.percentage
            button.title = String(format: "%d%%", percentage)

            // Color coding based on usage
            if percentage >= 90 {
                button.contentTintColor = .systemRed
            } else if percentage >= 70 {
                button.contentTintColor = .systemOrange
            } else {
                button.contentTintColor = nil
            }
        } else if viewModel.isLoading {
            button.title = "..."
            button.contentTintColor = nil
        } else if viewModel.errorMessage != nil {
            button.title = "--"
            button.contentTintColor = .systemOrange
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button, let popover = popover else { return }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // Refresh when opening popover
            Task { await viewModel.refresh() }
        }
    }
}
