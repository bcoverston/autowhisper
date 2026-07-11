import SwiftUI

/// Collapsible summary card above the transcript: Claude's title, summary,
/// action items, and topic chips.
struct SummaryCard: View {
    let summary: SessionSummaryDoc
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(summary.title, systemImage: "sparkles")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button(expanded ? "Hide" : "Show") { withAnimation { expanded.toggle() } }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            if expanded {
                Text(summary.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if !summary.actionItems.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(summary.actionItems, id: \.self) { item in
                            Label(item, systemImage: "square")
                                .font(.caption)
                        }
                    }
                }
                if !summary.topics.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(summary.topics, id: \.self) { topic in
                            Text(topic)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.25))
    }
}
