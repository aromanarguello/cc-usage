import SwiftUI

struct APIKeySettingsView: View {
    @Bindable var viewModel: UsageViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var hasManualKey = false
    @State private var isDeleting = false
    @State private var showDeleteConfirmation = false
    @State private var deleteError: String? = nil

    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                Text("API Key Settings")
                    .font(.headline)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            Divider()

            if hasManualKey {
                // Manual key is configured
                VStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "key.fill")
                            .foregroundColor(.orange)
                        Text("Manual API Key")
                            .fontWeight(.medium)
                        Spacer()
                        Text("Active")
                            .font(.caption)
                            .foregroundColor(.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.2))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }

                    Text("You're using a manually configured Anthropic API key stored in Keychain.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if let error = deleteError {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                    }

                    Button(action: { showDeleteConfirmation = true }) {
                        HStack {
                            if isDeleting {
                                ProgressView()
                                    .scaleEffect(0.6)
                            } else {
                                Image(systemName: "trash")
                            }
                            Text("Remove API Key")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.red.opacity(0.15))
                        .foregroundColor(.red)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .disabled(isDeleting)
                }
            } else {
                // Using OAuth
                VStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "person.badge.key.fill")
                            .foregroundColor(.blue)
                        Text("Claude Code OAuth")
                            .fontWeight(.medium)
                        Spacer()
                        Text("Active")
                            .font(.caption)
                            .foregroundColor(.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.2))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }

                    Text("Using credentials from Claude Code. No manual configuration needed.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Spacer()
        }
        .padding()
        .frame(width: 280, height: 200)
        .background(.ultraThinMaterial)
        .task {
            hasManualKey = await viewModel.isUsingManualAPIKey
        }
        .alert("Remove API Key?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Remove", role: .destructive) {
                deleteAPIKey()
            }
        } message: {
            Text("This will remove your manual API key. The app will try to use Claude Code OAuth credentials instead.")
        }
    }

    private func deleteAPIKey() {
        isDeleting = true
        deleteError = nil

        Task {
            do {
                try await viewModel.deleteManualAPIKey()
                await MainActor.run {
                    hasManualKey = false
                    isDeleting = false
                }
                // Refresh to attempt OAuth
                await viewModel.refresh()
            } catch {
                await MainActor.run {
                    deleteError = "Failed to remove: \(error.localizedDescription)"
                    isDeleting = false
                }
            }
        }
    }
}
