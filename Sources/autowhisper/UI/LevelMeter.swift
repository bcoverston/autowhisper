import SwiftUI

struct LevelMeter: View {
    let label: String
    let level: Float

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(level > 0.85 ? Color.red : .green)
                        .frame(width: geo.size.width * CGFloat(min(1, level)))
                }
            }
            .frame(width: 60, height: 6)
        }
    }
}
