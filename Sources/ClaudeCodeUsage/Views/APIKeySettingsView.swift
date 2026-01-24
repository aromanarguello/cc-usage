import SwiftUI

struct APIKeySettingsView: View {
    @Bindable var viewModel: UsageViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteConfirmation = false
    @State private var isDeleting = false
    @AppStorage("orphanNotificationsEnabled") private var orphanNotificationsEnabled: Bool = true

    var body: some View {
        VStack(spacing: 16) {
            // Header
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

            Divider()

            // Auth method section
            VStack(alignment: .leading, spacing: 8) {
                Text("Authentication")
                    .font(.subheadline)
                    .fontWeight(.medium)

                HStack {
                    if viewModel.usingManualKey {
                        Image(systemName: "key.fill")
                            .foregroundColor(.orange)
                        Text("Using Manual API Key")
                            .font(.callout)
                        Spacer()
                        Button(action: { showDeleteConfirmation = true }) {
                            if isDeleting {
                                ProgressView()
                                    .scaleEffect(0.6)
                            } else {
                                Text("Delete")
                                    .foregroundColor(.red)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(isDeleting)
                    } else {
                        Image(systemName: "person.badge.key.fill")
                            .foregroundColor(.green)
                        Text("Using Claude Code OAuth")
                            .font(.callout)
                        Spacer()
                    }
                }
                .padding(12)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
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

            Spacer()
        }
        .padding()
        .frame(width: 300, height: 260)
        .alert("Delete API Key?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                Task {
                    isDeleting = true
                    try? await viewModel.deleteManualAPIKey()
                    isDeleting = false
                    await viewModel.refresh()
                }
            }
        } message: {
            Text("The app will try to use Claude Code OAuth credentials instead.")
        }
    }
}

#Preview {
    let credentialService = CredentialService()
    let apiService = UsageAPIService(credentialService: credentialService)
    let viewModel = UsageViewModel(apiService: apiService, credentialService: credentialService)
    return APIKeySettingsView(viewModel: viewModel)
}
