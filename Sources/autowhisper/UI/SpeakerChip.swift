import SwiftUI

/// Speaker color system from the Converge design (docs/design/DESIGN.md):
/// unmatched speakers cycle blue/orange/purple/cyan; a matched *named* speaker
/// is green with a subtle glow. Unknown is muted gray.
enum SpeakerColor {
    static let palette: [Color] = [
        Color(red: 0.345, green: 0.651, blue: 1.0),    // #58a6ff blue
        Color(red: 0.941, green: 0.533, blue: 0.243),  // #f0883e orange
        Color(red: 0.667, green: 0.475, blue: 1.0),    // purple
        Color(red: 0.224, green: 0.773, blue: 0.812),  // #39c5cf cyan
    ]
    static let matched = Color(red: 0.247, green: 0.725, blue: 0.314)   // #3fb950 green
    static let unknown = Color(red: 0.318, green: 0.373, blue: 0.431)   // #515f6e

    /// A named speaker (no "Speaker N" pattern) is treated as matched → green.
    static func color(for label: String) -> Color {
        if label == "Unknown" { return unknown }
        if label.hasPrefix("Speaker ") {
            let n = Int(label.dropFirst("Speaker ".count)) ?? 1
            return palette[(n - 1) % palette.count]
        }
        return matched   // an enrolled name
    }

    static func isMatched(_ label: String) -> Bool {
        label != "Unknown" && !label.hasPrefix("Speaker ")
    }
}

struct SpeakerChip: View {
    let label: String

    var body: some View {
        let color = SpeakerColor.color(for: label)
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 8, height: 8)
                .shadow(color: SpeakerColor.isMatched(label) ? color.opacity(0.6) : .clear, radius: 3)
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(color)
        }
    }
}
