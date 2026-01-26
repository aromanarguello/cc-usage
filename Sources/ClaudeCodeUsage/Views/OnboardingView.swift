import SwiftUI

struct OnboardingView: View {
    var onComplete: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            // Header icon
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.15))
                    .frame(width: 72, height: 72)
                Image(systemName: "key.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.blue)
            }

            // Title
            Text("Keychain Access")
                .font(.title3)
                .fontWeight(.bold)

            // Explanation
            Text("This app reads your Claude Code credentials to display usage data.")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            // Instructions card
            VStack(alignment: .leading, spacing: 12) {
                Text("When prompted:")
                    .font(.callout)
                    .fontWeight(.semibold)

                instructionRow(
                    number: "1",
                    text: "A macOS dialog will ask for keychain access"
                )

                instructionRow(
                    number: "2",
                    emphasis: "Click \"Always Allow\"",
                    detail: "(not just \"Allow\")"
                )

                instructionRow(
                    number: "3",
                    text: "Enter your Mac password if prompted"
                )
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.blue.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            // Important note
            HStack(spacing: 8) {
                Image(systemName: "info.circle.fill")
                    .foregroundColor(.orange)
                    .font(.caption)
                Text("\"Always Allow\" prevents repeated prompts")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
                .frame(height: 8)

            // Continue button
            Button(action: onComplete) {
                Text("Continue")
                    .fontWeight(.medium)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
        .padding(24)
        .frame(width: 320)
    }

    @ViewBuilder
    private func instructionRow(number: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(.white)
                .frame(width: 20, height: 20)
                .background(Color.blue)
                .clipShape(Circle())

            Text(text)
                .font(.callout)
        }
    }

    @ViewBuilder
    private func instructionRow(number: String, emphasis: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(.white)
                .frame(width: 20, height: 20)
                .background(Color.blue)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(emphasis)
                    .font(.callout)
                    .fontWeight(.semibold)
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

#Preview {
    OnboardingView(onComplete: {})
        .background(.ultraThinMaterial)
}
