import SwiftUI
import AppKit

struct UsagePopoverView: View {
    @Bindable var viewModel: UsageViewModel
    @State private var isCheckingUpdate = false
    @State private var updateAlert: UpdateAlertType? = nil
    @State private var showKillConfirmation = false
    @State private var isKillingAgents = false

    // API Key configuration state
    @State private var apiKeyInput = ""
    @State private var isShowingKey = false
    @State private var isSavingKey = false
    @State private var keyError: String? = nil
    @State private var showKeySaved = false

    private let updateChecker = UpdateChecker()

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
            // Header
            HStack {
                Text("Claude Usage")
                    .font(.headline)
                Spacer()
                if let subscription = viewModel.usageData?.subscription {
                    Text(subscription)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.orange)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
            .padding()

            Divider()

            if let error = viewModel.errorMessage, viewModel.usageData == nil {
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
                        .foregroundColor(.orange)
                        .font(.caption)
                }
                Text("Updated \(viewModel.timeSinceUpdate)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                Button(action: {
                    Task { await viewModel.refresh() }
                }) {
                    if viewModel.isLoading {
                        ProgressView()
                            .scaleEffect(0.6)
                    } else {
                        Image(systemName: "arrow.clockwise")
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
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
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
    }

    private func checkForUpdates() {
        isCheckingUpdate = true
        Task {
            do {
                let result = try await updateChecker.checkForUpdates()
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
                    .foregroundColor(.secondary)
                Text(title)
                Spacer()
                Text("\(window.percentage)%")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }

            UsageBarView(progress: window.utilization, color: color)

            Text("\(resetPrefix) \(window.timeUntilReset())")
                .font(.caption)
                .foregroundColor(.secondary)
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
                    .foregroundColor(.secondary)
                Text("Active Agents")
                Spacer()
                Text("\(agents.total)")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .monospacedDigit()
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

            // Legend and Memory
            HStack(spacing: 16) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(sessionColor)
                        .frame(width: 6, height: 6)
                    Text("\(agents.sessions) sessions")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 4) {
                    Circle()
                        .fill(subagentColor)
                        .frame(width: 6, height: 6)
                    Text("\(agents.subagents) subagents")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Memory usage
                HStack(spacing: 4) {
                    Image(systemName: "memorychip")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(formatMemory(agents.totalMemoryMB))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
    }

    private func formatMemory(_ mb: Int) -> String {
        if mb >= 1024 {
            let gb = Double(mb) / 1024.0
            return String(format: "%.1f GB", gb)
        } else {
            return "\(mb) MB"
        }
    }

    @ViewBuilder
    private func hangingAgentsWarning(count: Int) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)

            Text("\(count) hanging agent\(count == 1 ? "" : "s") (>3h)")
                .font(.callout)

            Spacer()

            Button(action: { showKillConfirmation = true }) {
                if isKillingAgents {
                    ProgressView()
                        .scaleEffect(0.6)
                } else {
                    Text("Kill")
                        .foregroundColor(.red)
                }
            }
            .buttonStyle(.plain)
            .disabled(isKillingAgents)
        }
        .padding()
        .background(Color.orange.opacity(0.15))
    }

    // MARK: - API Key Configuration

    @ViewBuilder
    private func apiKeyConfigurationView(errorMessage: String) -> some View {
        VStack(spacing: 16) {
            // Warning icon
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundColor(.orange)

            // Message
            VStack(spacing: 4) {
                Text("Couldn't read Claude credentials")
                    .font(.callout)
                    .fontWeight(.medium)
                Text("Enter your Anthropic API key below")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // API Key input field
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Group {
                        if isShowingKey {
                            TextField("sk-ant-api03-...", text: $apiKeyInput)
                        } else {
                            SecureField("sk-ant-api03-...", text: $apiKeyInput)
                        }
                    }
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .monospaced))
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(keyError != nil ? Color.red.opacity(0.8) : Color.gray.opacity(0.3), lineWidth: 1)
                    )

                    // Reveal toggle
                    Button(action: { isShowingKey.toggle() }) {
                        Image(systemName: isShowingKey ? "eye.slash" : "eye")
                            .foregroundColor(.secondary)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                }

                // Error message
                if let error = keyError {
                    Text(error)
                        .font(.caption2)
                        .foregroundColor(.red)
                }
            }

            // Save button
            Button(action: saveAPIKey) {
                HStack(spacing: 6) {
                    if isSavingKey {
                        ProgressView()
                            .scaleEffect(0.6)
                    } else if showKeySaved {
                        Image(systemName: "checkmark")
                            .foregroundColor(.white)
                    }
                    Text(showKeySaved ? "Saved!" : "Save API Key")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(apiKeyInput.isEmpty ? Color.gray : Color.orange)
                .foregroundColor(.white)
                .fontWeight(.medium)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .disabled(apiKeyInput.isEmpty || isSavingKey)

            // Trust signal
            HStack(spacing: 4) {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                Text("Stored securely in Keychain")
                    .font(.caption2)
            }
            .foregroundColor(.secondary)
        }
        .padding(24)
    }

    private func saveAPIKey() {
        keyError = nil
        isSavingKey = true

        Task {
            do {
                try await viewModel.saveManualAPIKey(apiKeyInput)

                await MainActor.run {
                    showKeySaved = true
                    isSavingKey = false
                }

                try? await Task.sleep(nanoseconds: 800_000_000)

                await MainActor.run {
                    showKeySaved = false
                    apiKeyInput = ""
                }

                await viewModel.refresh()

            } catch CredentialError.invalidAPIKeyFormat {
                await MainActor.run {
                    keyError = "Invalid API key format. Keys start with sk-ant-"
                    isSavingKey = false
                }
            } catch {
                await MainActor.run {
                    keyError = "Failed to save: \(error.localizedDescription)"
                    isSavingKey = false
                }
            }
        }
    }
}

#Preview {
    let credentialService = CredentialService()
    let apiService = UsageAPIService(credentialService: credentialService)
    let viewModel = UsageViewModel(apiService: apiService, credentialService: credentialService)
    return UsagePopoverView(viewModel: viewModel)
}
