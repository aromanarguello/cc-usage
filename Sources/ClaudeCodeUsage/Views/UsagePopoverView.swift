import SwiftUI
import AppKit

struct UsagePopoverView: View {
    @Bindable var viewModel: UsageViewModel
    let apiService: UsageAPIService
    @State private var isCheckingUpdate = false
    @State private var updateAlert: UpdateAlertType? = nil
    @State private var showKillConfirmation = false
    @State private var isKillingAgents = false
    @State private var showSettings = false
    @State private var showKillAllConfirmation = false
    @State private var isKillingAllAgents = false
    @State private var showTroubleshooting = false

    enum UpdateAlertType: Identifiable {
        case available(version: String, url: String?)
        case upToDate
        case error(String)

        var id: String {
            switch self {
            case .available: return "available"
            case .upToDate: return "upToDate"
            case .error: return "error"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.showOnboarding {
                OnboardingView(onComplete: {
                    viewModel.completeOnboarding()
                })
            } else {
            // Header
            HStack {
                Text("Claude Usage")
                    .font(.headline)

                Button(action: { showSettings = true }) {
                    Image(systemName: "gearshape")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Spacer()
                if let subscription = viewModel.usageData?.subscription {
                    Text(subscription)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.orange)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
            .padding()

            Divider()

            if viewModel.keychainAccessDenied && viewModel.usageData == nil {
                // Keychain access denied - show specific guidance
                keychainDeniedView()
            } else if let error = viewModel.errorMessage, viewModel.usageData == nil {
                // Error state - show API key configuration
                apiKeyConfigurationView(errorMessage: error)
            } else if let data = viewModel.usageData {
                // 5-Hour Window
                usageSection(
                    icon: "clock",
                    title: "5-Hour Window",
                    window: data.fiveHour,
                    color: Color(hex: "4ADE80"),
                    resetPrefix: "Resets in"
                )

                Divider()

                // Weekly
                usageSection(
                    icon: "calendar",
                    title: "Weekly",
                    window: data.sevenDay,
                    color: Color(hex: "F59E0B"),
                    resetPrefix: "Resets"
                )

                // Model-specific quotas
                if let sonnet = data.sevenDaySonnet {
                    Divider()

                    usageSection(
                        icon: "sparkles",
                        title: "Weekly (Sonnet)",
                        window: sonnet,
                        color: Color(hex: "A855F7"),
                        resetPrefix: "Resets"
                    )
                }

                if let opus = data.sevenDayOpus {
                    Divider()

                    usageSection(
                        icon: "star.fill",
                        title: "Weekly (Opus)",
                        window: opus,
                        color: Color(hex: "EC4899"),
                        resetPrefix: "Resets"
                    )
                }

                // Extra Usage (monthly spending)
                if let extraUsage = data.extraUsage, extraUsage.isEnabled {
                    Divider()

                    extraUsageSection(extraUsage: extraUsage)
                }

                // Active Agents
                if let agents = viewModel.agentCount, agents.total > 0 {
                    Divider()

                    agentSection(agents: agents)
                }

                // Hanging Agents Warning
                if let agents = viewModel.agentCount, !agents.hangingSubagents.isEmpty {
                    Divider()

                    hangingAgentsWarning(count: agents.hangingSubagents.count)
                }
            } else if viewModel.isLoading {
                ProgressView()
                    .padding(32)
            }

            Divider()

            // Footer
            HStack {
                if viewModel.errorMessage != nil, viewModel.usageData != nil {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }

                // Show state message or time since update
                if let stateMessage = viewModel.refreshState.statusMessage {
                    Text(stateMessage)
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text("Updated \(viewModel.timeSinceUpdate)")
                        .font(.caption)
                        .foregroundStyle(viewModel.isDataStale ? .orange : .secondary)
                }

                Spacer()

                Button(action: {
                    Task { await viewModel.refresh(userInitiated: true) }
                }) {
                    if viewModel.isLoading {
                        ProgressView()
                            .scaleEffect(0.6)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(viewModel.refreshState == .needsManualRefresh ? .orange : .secondary)
                    }
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isLoading)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            HStack {
                Button(action: checkForUpdates) {
                    if isCheckingUpdate {
                        ProgressView()
                            .scaleEffect(0.6)
                    } else {
                        Text("Check for Updates")
                    }
                }
                .buttonStyle(.plain)
                .disabled(isCheckingUpdate)
                Spacer()
                Button("Quit") {
                    Task { @MainActor in
                        // Set a fallback forced exit in case terminate hangs
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            exit(0)
                        }
                        NSApplication.shared.terminate(nil)
                    }
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            }  // end else (onboarding)
        }
        .frame(width: 320)
        .background(.ultraThinMaterial)
        .alert(item: $updateAlert) { alert in
            switch alert {
            case .available(let version, let url):
                return Alert(
                    title: Text("Update Available"),
                    message: Text("Version \(version) is available."),
                    primaryButton: .default(Text("Download")) {
                        if let url = url, let downloadURL = URL(string: url) {
                            NSWorkspace.shared.open(downloadURL)
                        }
                    },
                    secondaryButton: .cancel()
                )
            case .upToDate:
                return Alert(
                    title: Text("Up to Date"),
                    message: Text("You're running the latest version."),
                    dismissButton: .default(Text("OK"))
                )
            case .error(let message):
                return Alert(
                    title: Text("Update Check Failed"),
                    message: Text(message),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
        .alert("Kill Hanging Agents?", isPresented: $showKillConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Kill", role: .destructive) {
                Task {
                    isKillingAgents = true
                    _ = await viewModel.killHangingAgents()
                    isKillingAgents = false
                }
            }
        } message: {
            let count = viewModel.agentCount?.hangingSubagents.count ?? 0
            Text("This will terminate \(count) subagent process\(count == 1 ? "" : "es") that \(count == 1 ? "has" : "have") been running for over 3 hours.")
        }
        .alert("Kill All Subagents?", isPresented: $showKillAllConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Kill All", role: .destructive) {
                Task {
                    isKillingAllAgents = true
                    _ = await viewModel.killAllSubagents()
                    isKillingAllAgents = false
                }
            }
        } message: {
            let count = viewModel.agentCount?.subagents ?? 0
            Text("This will terminate all \(count) subagent process\(count == 1 ? "" : "es").")
        }
        .sheet(isPresented: $showSettings) {
            APIKeySettingsView(viewModel: viewModel, apiService: apiService)
        }
    }

    private func checkForUpdates() {
        // If we already have cached update info from background check, use it directly
        if let version = viewModel.latestVersion {
            updateAlert = .available(version: version, url: viewModel.downloadURL)
            return
        }

        // Otherwise, perform a fresh check
        isCheckingUpdate = true
        Task {
            do {
                let result = try await UpdateChecker().checkForUpdates()
                await MainActor.run {
                    if result.updateAvailable {
                        updateAlert = .available(version: result.latestVersion, url: result.downloadURL)
                    } else {
                        updateAlert = .upToDate
                    }
                    isCheckingUpdate = false
                }
            } catch {
                await MainActor.run {
                    updateAlert = .error(error.localizedDescription)
                    isCheckingUpdate = false
                }
            }
        }
    }

    private func openKeychainAccess() {
        // Use bundle identifier for reliability across macOS versions
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.keychainaccess") {
            NSWorkspace.shared.open(url)
        }
    }

    @ViewBuilder
    private func usageSection(
        icon: String,
        title: String,
        window: UsageData.UsageWindow,
        color: Color,
        resetPrefix: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                Text(title)
                Spacer()
                Text("\(window.percentage)%")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }

            UsageBarView(progress: window.utilization, color: color)

            Text("\(resetPrefix) \(window.timeUntilReset())")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    @ViewBuilder
    private func agentSection(agents: AgentCount) -> some View {
        let sessionColor = Color(hex: "06B6D4")  // Cyan
        let subagentColor = Color(hex: "8B5CF6") // Purple

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                Image(systemName: "bolt.horizontal.circle")
                    .foregroundStyle(.secondary)
                Text("Active Agents")
                Spacer()
                Text("\(agents.total)")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }

            // Segmented bar showing sessions vs subagents
            GeometryReader { geometry in
                let sessionRatio = agents.total > 0 ? CGFloat(agents.sessions) / CGFloat(agents.total) : 0

                HStack(spacing: 2) {
                    // Sessions segment
                    if agents.sessions > 0 {
                        Capsule()
                            .fill(sessionColor)
                            .frame(width: max(8, (geometry.size.width - 2) * sessionRatio))
                    }

                    // Subagents segment
                    if agents.subagents > 0 {
                        Capsule()
                            .fill(subagentColor)
                            .frame(width: max(8, (geometry.size.width - 2) * (1 - sessionRatio)))
                    }
                }
            }
            .frame(height: 8)

            // Legend, Memory, and Kill All
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(sessionColor)
                        .frame(width: 6, height: 6)
                    Text("\(agents.sessions) sessions")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 4) {
                    Circle()
                        .fill(subagentColor)
                        .frame(width: 6, height: 6)
                    Text("\(agents.subagents) subagents")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Memory usage
                HStack(spacing: 4) {
                    Image(systemName: "memorychip")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(formatMemory(agents.totalMemoryMB))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Kill All button (only when subagents > 0)
                if agents.subagents > 0 {
                    Button(action: { showKillAllConfirmation = true }) {
                        if isKillingAllAgents {
                            ProgressView()
                                .scaleEffect(0.5)
                        } else {
                            Text("Kill All")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isKillingAllAgents)
                }
            }
        }
        .padding()
    }

    private func formatMemory(_ mb: Int) -> String {
        if mb >= 1024 {
            let gb = Double(mb) / 1024.0
            return gb.formatted(.number.precision(.fractionLength(1))) + " GB"
        } else {
            return "\(mb) MB"
        }
    }

    @ViewBuilder
    private func hangingAgentsWarning(count: Int) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)

            Text("\(count) hanging agent\(count == 1 ? "" : "s") (>3h)")
                .font(.callout)

            Spacer()

            Button(action: { showKillConfirmation = true }) {
                if isKillingAgents {
                    ProgressView()
                        .scaleEffect(0.6)
                } else {
                    Text("Kill")
                        .foregroundStyle(.red)
                }
            }
            .buttonStyle(.plain)
            .disabled(isKillingAgents)
        }
        .padding()
        .background(Color.orange.opacity(0.15))
    }

    @ViewBuilder
    private func extraUsageSection(extraUsage: UsageData.ExtraUsage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                Image(systemName: "dollarsign.circle")
                    .foregroundStyle(.secondary)
                Text("Extra Usage")
                Spacer()
                Text("\(extraUsage.percentage)%")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }

            UsageBarView(progress: extraUsage.utilization / 100.0, color: Color(hex: "38BDF8"))

            Text("\(extraUsage.usedUSD) / \(extraUsage.limitUSD) this month")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    // MARK: - Keychain Access Denied

    @ViewBuilder
    private func keychainDeniedView() -> some View {
        VStack(spacing: 16) {
            // Icon with subtle background
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.15))
                    .frame(width: 56, height: 56)
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.orange)
            }

            // Title and explanation
            VStack(spacing: 6) {
                Text("Access Blocked")
                    .font(.callout)
                    .fontWeight(.semibold)

                Text("macOS denied access to your Claude Code credentials stored in Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Info box explaining what this means
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.blue)
                    Text("Why this happens")
                        .font(.caption)
                        .fontWeight(.medium)
                }

                Text("This app reads OAuth tokens from Claude Code CLI to show your usage. When you click \"Don't Allow\" on the keychain prompt, macOS blocks access.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.blue.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            // Primary action
            Button(action: {
                Task { await viewModel.retryKeychainAccess() }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                    Text("Retry Keychain Access")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.orange)
                .foregroundStyle(.white)
                .fontWeight(.medium)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)

            // Open Keychain Access button
            Button(action: openKeychainAccess) {
                HStack(spacing: 6) {
                    Image(systemName: "lock.rectangle")
                        .font(.caption)
                    Text("Open Keychain Access")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.secondary.opacity(0.15))
                .foregroundStyle(.primary)
                .fontWeight(.medium)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)

            // Alternative
            VStack(spacing: 4) {
                Text("Or re-authenticate in terminal:")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    Text("claude")
                        .font(.system(.caption, design: .monospaced))

                    Button(action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("claude", forType: .string)
                    }) {
                        Image(systemName: "doc.on.doc")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
        .padding(20)
    }

    // MARK: - Authentication Required

    @ViewBuilder
    private func apiKeyConfigurationView(errorMessage: String) -> some View {
        VStack(spacing: 16) {
            // Warning icon
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(.orange)

            // Message
            VStack(spacing: 8) {
                Text("Authentication Required")
                    .font(.callout)
                    .fontWeight(.medium)

                Text("Run Claude Code in terminal to authenticate with your Claude account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Terminal command
            VStack(spacing: 8) {
                Text("Run in terminal:")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Text("claude")
                        .font(.system(.body, design: .monospaced))

                    Spacer()

                    Button(action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("claude", forType: .string)
                    }) {
                        Image(systemName: "doc.on.doc")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(12)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            // Explanation
            VStack(spacing: 4) {
                Text("This app uses OAuth credentials from Claude Code CLI.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Retry button
            Button(action: {
                Task { await viewModel.refresh(userInitiated: true) }
            }) {
                Text("Retry")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.blue)
                    .foregroundStyle(.white)
                    .fontWeight(.medium)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)

            // Troubleshooting section
            DisclosureGroup(isExpanded: $showTroubleshooting) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("If you've already authenticated but still see this error, your credentials may exist but the app can't access them due to macOS keychain permissions.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Workaround: Set the token via environment variable before launching:")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    let workaroundCommand = "export CLAUDE_USAGE_OAUTH_TOKEN=$(security find-generic-password -s 'Claude Code-credentials' -w | jq -r '.claudeAiOauth.accessToken')"

                    HStack(alignment: .top) {
                        Text(workaroundCommand)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer()

                        Button(action: {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(workaroundCommand, forType: .string)
                        }) {
                            Image(systemName: "doc.on.doc")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                    Text("Then run the app from that terminal session, or add to your shell profile.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 8)
            } label: {
                Text("Having trouble?")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
    }
}

#Preview {
    let credentialService = CredentialService()
    let apiService = UsageAPIService(credentialService: credentialService)
    let viewModel = UsageViewModel(apiService: apiService, credentialService: credentialService)
    return UsagePopoverView(viewModel: viewModel, apiService: apiService)
}
