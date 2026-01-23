import SwiftUI

struct UsagePopoverView: View {
    @Bindable var viewModel: UsageViewModel
    var onOpenSettings: () -> Void = {}

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
                // Error state (no cached data)
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(32)
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
                Button("Settings") {
                    onOpenSettings()
                }
                .buttonStyle(.plain)
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
}

#Preview {
    let credentialService = CredentialService()
    let apiService = UsageAPIService(credentialService: credentialService)
    let viewModel = UsageViewModel(apiService: apiService)
    return UsagePopoverView(viewModel: viewModel)
}
