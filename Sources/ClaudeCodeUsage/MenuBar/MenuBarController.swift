import AppKit
import SwiftUI
import Combine

@MainActor
final class MenuBarController: ObservableObject {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    nonisolated(unsafe) private var eventMonitor: Any?
    private var updateTask: Task<Void, Never>?

    let viewModel: UsageViewModel
    let apiService: UsageAPIService
    let credentialService: CredentialService

    init(viewModel: UsageViewModel, apiService: UsageAPIService, credentialService: CredentialService) {
        self.viewModel = viewModel
        self.apiService = apiService
        self.credentialService = credentialService
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
        // Note: updateTask will be canceled automatically via MainActor isolation
        // when MenuBarController is deallocated. We also explicitly clean up via
        // cleanup() in AppDelegate.applicationWillTerminate()
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
            rootView: UsagePopoverView(viewModel: viewModel, apiService: apiService, credentialService: credentialService)
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

        // Handle system sleep - pause polling and warm cache
        nc.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                #if DEBUG
                print("[MenuBarController] System sleeping, warming cache and pausing polling")
                #endif
                await self?.viewModel.pauseForSleep()
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

        updateTask = Task { @MainActor in
            var tickCount = 0
            while !Task.isCancelled {
                updateStatusItemTitle()
                tickCount += 1
                // Every 30 seconds, verify the polling loop is alive
                if tickCount % 30 == 0 {
                    viewModel.ensurePolling()
                }
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
        var textColor: NSColor? = nil  // nil = system default (white on dark menu bar)

        if let data = viewModel.usageData {
            title = data.menuBarDisplay
            #if DEBUG
            print("[MenuBarController] Updating menu bar title to: \(title)")
            #endif

            // Clear any previous image
            button.image = nil

            if data.isFullyBlocked {
                // Fully blocked - red with hourglass icon
                textColor = .systemRed
                let image = NSImage(systemSymbolName: "hourglass.circle", accessibilityDescription: "Rate limited")
                image?.isTemplate = true  // Adopts system appearance (white on dark menu bars)
                image?.size = NSSize(width: 14, height: 14)
                button.image = image
                button.imagePosition = .imageLeading
            } else if data.isUsingExtraUsage {
                // Using extra budget - cyan to indicate spending
                textColor = .systemCyan
            } else {
                // Normal usage - color code by percentage
                let percentage = data.fiveHour.percentage
                if percentage >= 90 {
                    textColor = .systemRed
                } else if percentage >= 70 {
                    textColor = .systemOrange
                }
            }
        } else if viewModel.isLoading {
            title = "..."
        } else if viewModel.errorMessage != nil {
            title = "--"
            textColor = .systemOrange
        } else {
            title = "--%"
        }

        // Add stale indicator if data is old
        if viewModel.isDataStale {
            textColor = .systemOrange
        }

        // Add wake status indicator
        if case .wakingUp = viewModel.refreshState {
            title = "..."
            textColor = .systemBlue
        }

        if case .needsManualRefresh = viewModel.refreshState {
            title += " !"
            textColor = .systemOrange
        }

        // Add update badge if available
        if viewModel.updateAvailable {
            title += " ⬆"
        }

        // Apply title with color via attributed string
        // For menu bar, use controlTextColor as the default (adapts to menu bar appearance)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: textColor ?? NSColor.controlTextColor
        ]
        button.attributedTitle = NSAttributedString(string: title, attributes: attributes)
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button, let popover = popover else { return }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            // Clear update badge when user opens popover
            viewModel.acknowledgeUpdate()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // Refresh when opening popover — but don't allow keychain prompts.
            // The user clicked the icon to see data, not to authorize keychain access.
            // If credentials need a prompt, the explicit "Retry" button handles that.
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
