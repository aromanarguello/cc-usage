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
    let apiService: UsageAPIService

    init(viewModel: UsageViewModel, apiService: UsageAPIService) {
        self.viewModel = viewModel
        self.apiService = apiService
        setupStatusItem()
        setupPopover()
        setupEventMonitor()
        setupWorkspaceObservers()
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
            rootView: UsagePopoverView(viewModel: viewModel, apiService: apiService)
        )
    }

    private func setupEventMonitor() {
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            if let popover = self?.popover, popover.isShown {
                popover.performClose(nil)
            }
        }
    }

    private func setupWorkspaceObservers() {
        let nc = NSWorkspace.shared.notificationCenter

        // Handle screen wake (restore status item if lost)
        nc.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.ensureStatusItemExists()
            }
        }

        // Handle system sleep - pause polling
        nc.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                #if DEBUG
                print("[MenuBarController] System sleeping, pausing polling")
                #endif
                self?.viewModel.pauseForSleep()
            }
        }

        // Handle system wake - resume with delay
        nc.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                #if DEBUG
                print("[MenuBarController] System woke, resuming after delay")
                #endif
                self?.ensureStatusItemExists()
                self?.viewModel.resumeAfterWake()
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

    /// Recreates the status item if it was lost
    private func ensureStatusItemExists() {
        guard statusItem?.button == nil else { return }

        #if DEBUG
        print("[MenuBarController] Status item lost, recreating...")
        #endif

        setupStatusItem()
        setupPopover()
    }

    private func updateStatusItemTitle() {
        ensureStatusItemExists()
        guard let button = statusItem?.button else { return }

        var title: String

        if let data = viewModel.usageData {
            let percentage = data.fiveHour.percentage
            title = String(format: "%d%%", percentage)

            // Color coding based on usage
            if percentage >= 90 {
                button.contentTintColor = .systemRed
            } else if percentage >= 70 {
                button.contentTintColor = .systemOrange
            } else {
                button.contentTintColor = nil
            }
        } else if viewModel.isLoading {
            title = "..."
            button.contentTintColor = nil
        } else if viewModel.errorMessage != nil {
            title = "--"
            button.contentTintColor = .systemOrange
        } else {
            title = "--%"
            button.contentTintColor = nil
        }

        // Add stale indicator if data is old
        if viewModel.isDataStale {
            button.contentTintColor = .systemOrange
        }

        // Add wake status indicator
        if case .wakingUp = viewModel.refreshState {
            title = "..."
            button.contentTintColor = .systemBlue
        }

        if case .needsManualRefresh = viewModel.refreshState {
            title += " !"
            button.contentTintColor = .systemOrange
        }

        // Add update badge if available
        if viewModel.updateAvailable {
            title += " ⬆"
        }

        button.title = title
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button, let popover = popover else { return }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            // Clear update badge when user opens popover
            viewModel.acknowledgeUpdate()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // Refresh when opening popover
            Task { await viewModel.refresh() }
        }
    }

    func showPopover() {
        guard let button = statusItem?.button, let popover = popover else { return }

        if !popover.isShown {
            // Clear update badge when user opens popover
            viewModel.acknowledgeUpdate()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            Task { await viewModel.refresh() }
        }
    }

    /// Cleans up all resources before termination
    func cleanup() {
        // Cancel background tasks
        updateTask?.cancel()
        updateTask = nil
        viewModel.stopPolling()

        // Remove event monitor
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }

        // Close popover and release status item
        popover?.close()
        popover = nil

        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }
}
