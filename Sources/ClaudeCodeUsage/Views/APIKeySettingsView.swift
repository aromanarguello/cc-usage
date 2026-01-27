import SwiftUI

struct APIKeySettingsView: View {
    @Bindable var viewModel: UsageViewModel
    let apiService: UsageAPIService
    @Environment(\.dismiss) private var dismiss
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
                        .foregroundColor(.secondary)
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

                        HStack {
                            Image(systemName: "person.badge.key.fill")
                                .foregroundColor(.green)
                            Text("Claude Code OAuth")
                                .font(.callout)
                            Spacer()
                        }
                        .padding(12)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                        Text("Credentials are read from Claude Code CLI")
                            .font(.caption)
                            .foregroundColor(.secondary)
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
                            .foregroundColor(.secondary)
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
                                        .foregroundColor(.green)
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
                            .foregroundColor(.secondary)

                    }

                    Divider()

                    // Version
                    HStack {
                        Text("Version")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.top, 12)
            }
        }
        .padding()
        .frame(width: 300, height: 300)
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
    return APIKeySettingsView(viewModel: viewModel, apiService: apiService)
}
