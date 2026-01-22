import SwiftUI

struct UsageBarView: View {
    let progress: Double
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.gray.opacity(0.2))

                Capsule()
                    .fill(color)
                    .frame(width: geometry.size.width * min(max(progress, 0), 1))
            }
        }
        .frame(height: 8)
    }
}

#Preview {
    VStack(spacing: 20) {
        UsageBarView(progress: 0.2, color: Color(hex: "4ADE80"))
        UsageBarView(progress: 0.51, color: Color(hex: "F59E0B"))
    }
    .padding()
    .frame(width: 300)
}
