import Events
import SwiftUI

struct SessionSidebar: View {
    @Bindable var app: AppModel
    @Binding var selection: String?

    var body: some View {
        List(selection: $selection) {
            if let live = app.live {
                Section("Live") {
                    Label(liveTitle(live), systemImage: "record.circle")
                        .foregroundStyle(.red)
                        .tag(live.id)
                }
            }
            Section("Sessions") {
                ForEach(app.summaries.filter { $0.id != app.live?.id }) { summary in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(summary.startedAt.formatted(date: .abbreviated, time: .shortened))
                        Text(subtitle(summary))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(summary.id)
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 220)
    }

    private func liveTitle(_ live: LiveSession) -> String {
        "Live — " + (app.summaries.first { $0.id == live.id }?.startedAt ?? .now)
            .formatted(date: .omitted, time: .shortened)
    }

    private func subtitle(_ summary: SessionSummary) -> String {
        var parts: [String] = []
        if let ended = summary.endedAt {
            let minutes = Int(ended.timeIntervalSince(summary.startedAt) / 60)
            parts.append(minutes > 0 ? "\(minutes) min" : "<1 min")
        }
        if summary.status == .interrupted { parts.append("interrupted") }
        return parts.joined(separator: " · ")
    }
}
