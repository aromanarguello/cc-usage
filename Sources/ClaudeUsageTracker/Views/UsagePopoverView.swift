import SwiftUI

struct UsagePopoverView: View {
    private let fiveHourUsage: Double = 0.20
    private let weeklyUsage: Double = 0.51
    private let fiveHourResetTime: String = "4h 54m"
    private let weeklyResetTime: String = "Mon 2:59 PM"

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Claude Usage")
                    .font(.headline)
                Spacer()
                Text("Pro")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.orange)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .padding()

            Divider()

            // 5-Hour Window
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "clock")
                        .foregroundColor(.secondary)
                    Text("5-Hour Window")
                    Spacer()
                    Text("\(Int(fiveHourUsage * 100))%")
                        .fontWeight(.medium)
                        .monospacedDigit()
                }

                UsageBarView(progress: fiveHourUsage, color: Color(hex: "4ADE80"))

                Text("Resets in \(fiveHourResetTime)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()

            Divider()

            // Weekly
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "calendar")
                        .foregroundColor(.secondary)
                    Text("Weekly")
                    Spacer()
                    Text("\(Int(weeklyUsage * 100))%")
                        .fontWeight(.medium)
                        .monospacedDigit()
                }

                UsageBarView(progress: weeklyUsage, color: Color(hex: "F59E0B"))

                Text("Resets \(weeklyResetTime)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()

            Divider()

            // Footer
            HStack {
                Text("Updated 0 sec ago")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                Button(action: {}) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            HStack {
                Button("Settings") {}
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
}

#Preview {
    UsagePopoverView()
}
