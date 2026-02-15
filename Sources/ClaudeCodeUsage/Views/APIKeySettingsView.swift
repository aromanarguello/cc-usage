import SwiftUI

struct APIKeySettingsView: View {
    @Bindable var viewModel: UsageViewModel
    let apiService: UsageAPIService
    let credentialService: CredentialService
    @Environment(\.dismiss) private var dismiss
    @State private var setupTokenInput: String = ""
    @State private var hasSetupToken: Bool = false
    @State private var setupTokenError: String?
    @State private var showClearConfirmation: Bool = false
    @State private var isFetchingDebug = false
    @State private var debugCopied = false
    @AppStorage("orphanNotificationsEnabled") private var orphanNotificationsEnabled: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            // Header - always visible at top
            HStack {
                Text("Settings")
                    .font(.headline)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 12)

            Divider()

            // Scrollable content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Auth method section
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Authentication")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        if hasSetupToken {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text("Setup token configured")
                                    .font(.callout)
                                Spacer()
                                Button("Clear") {
                                    showClearConfirmation = true
                                }
                                .foregroundStyle(.red)
                                .font(.callout)
                            }
                            .padding(12)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .confirmationDialog("Remove setup token?", isPresented: $showClearConfirmation) {
                                Button("Remove", role: .destructive) {
                                    Task {
                                        await credentialService.clearSetupToken()
                                        hasSetupToken = false
                                    }
                                }
                            } message: {
                                Text("The app will revert to reading credentials from Claude Code's keychain, which may prompt for permission.")
                            }

                            Text("Using long-lived token from `claude setup-token`")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            HStack {
                                Image(systemName: "person.badge.key.fill")
                                    .foregroundStyle(.green)
                                Text("Claude Code OAuth")
                                    .font(.callout)
                                Spacer()
                            }
                            .padding(12)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                            Text("To avoid keychain prompts, paste a token from `claude setup-token`:")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            HStack(spacing: 8) {
                                SecureField("Setup token", text: $setupTokenInput)
                                    .textFieldStyle(.roundedBorder)
                                Button("Save") {
                                    Task {
                                        do {
                                            try await credentialService.saveSetupToken(setupTokenInput)
                                            hasSetupToken = true
                                            setupTokenInput = ""
                                            setupTokenError = nil
                                        } catch {
                                            setupTokenError = "Invalid token format"
                                        }
                                    }
                                }
                                .disabled(setupTokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }

                            if let error = setupTokenError {
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                    }

                    Divider()

                    // Notifications section
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Notifications")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        Toggle("Orphan agent alerts", isOn: $orphanNotificationsEnabled)
                            .toggleStyle(.switch)

                        Text("Notify when subagents outlive their parent session")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Divider()

                    // Debug section
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Debug")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        Button(action: fetchAndCopyRawResponse) {
                            HStack {
                                if isFetchingDebug {
                                    ProgressView()
                                        .scaleEffect(0.6)
                                } else if debugCopied {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.green)
                                } else {
                                    Image(systemName: "doc.on.clipboard")
                                }
                                Text(debugCopied ? "Copied to Clipboard!" : "Copy Raw API Response")
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .disabled(isFetchingDebug)

                        Text("Copies full JSON from /api/oauth/usage")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                    }

                    Divider()

                    // Version
                    HStack {
                        Text("Version")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 12)
            }
        }
        .padding()
        .frame(width: 300, height: 350)
        .onAppear {
            Task {
                hasSetupToken = await credentialService.hasSetupToken()
            }
        }
    }

    private func fetchAndCopyRawResponse() {
        isFetchingDebug = true
        debugCopied = false

        Task {
            do {
                let rawJSON = try await apiService.fetchRawResponse()
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(rawJSON, forType: .string)

                await MainActor.run {
                    debugCopied = true
                    isFetchingDebug = false
                }

                try? await Task.sleep(nanoseconds: 2_000_000_000)

                await MainActor.run {
                    debugCopied = false
                }
            } catch {
                await MainActor.run {
                    isFetchingDebug = false
                }
            }
        }
    }

}

#Preview {
    let credentialService = CredentialService()
    let apiService = UsageAPIService(credentialService: credentialService)
    let viewModel = UsageViewModel(apiService: apiService, credentialService: credentialService)
    return APIKeySettingsView(viewModel: viewModel, apiService: apiService, credentialService: credentialService)
}
