import AppKit
import Events
import SwiftUI

struct SessionSidebar: View {
    @Bindable var app: AppModel
    @Binding var selection: String?

    @State private var filter = ""
    @State private var matchingIDs: Set<String>?     // nil = no filter active
    @State private var pendingDelete: SessionSummary?

    private var groups: [(day: Date, sessions: [SessionSummary])] {
        let past = app.summaries.filter { summary in
            summary.id != app.live?.id && (matchingIDs?.contains(summary.id) ?? true)
        }
        return Dictionary(grouping: past) { Calendar.current.startOfDay(for: $0.startedAt) }
            .sorted { $0.key > $1.key }
            .map { ($0.key, $0.value) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search sessions", text: $filter)
                    .textFieldStyle(.plain)
                if !filter.isEmpty {
                    Button { filter = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                }
            }
            .padding(6)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 8)
            .padding(.top, 8)

            List(selection: $selection) {
                if let live = app.live {
                    Section("Live") {
                        Label(liveTitle(live), systemImage: "record.circle")
                            .foregroundStyle(.red)
                            .tag(live.id)
                    }
                }
                ForEach(groups, id: \.day) { group in
                    Section(dayLabel(group.day)) {
                        ForEach(group.sessions) { summary in
                            row(summary)
                                .tag(summary.id)
                                .contextMenu {
                                    Button("Reveal in Finder") {
                                        NSWorkspace.shared.activateFileViewerSelecting([summary.dir])
                                    }
                                    Divider()
                                    Button("Delete…", role: .destructive) {
                                        pendingDelete = summary
                                    }
                                }
                        }
                    }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 190, ideal: 235)
        .task(id: filter) {
            guard !filter.isEmpty else {
                matchingIDs = nil
                return
            }
            try? await Task.sleep(for: .milliseconds(250))   // debounce typing
            guard !Task.isCancelled else { return }
            let query = filter
            matchingIDs = await Task.detached { SessionStore.sessionsMatching(query) }.value
        }
        .confirmationDialog("Delete this session?", isPresented: .init(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Delete audio and transcripts", role: .destructive) {
                if let pendingDelete {
                    if selection == pendingDelete.id { selection = nil }
                    app.deleteSession(pendingDelete)
                }
                pendingDelete = nil
            }
        } message: {
            Text("Permanently removes \(pendingDelete?.title ?? pendingDelete?.id ?? "") — audio chunks and all transcript files.")
        }
    }

    private func row(_ summary: SessionSummary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(summary.title ?? summary.startedAt.formatted(date: .omitted, time: .shortened))
            HStack(spacing: 4) {
                if summary.status == .interrupted {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Text(subtitle(summary))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func liveTitle(_ live: LiveSession) -> String {
        "Live — " + (app.summaries.first { $0.id == live.id }?.startedAt ?? .now)
            .formatted(date: .omitted, time: .shortened)
    }

    private func dayLabel(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(date: .abbreviated, time: .omitted)
    }

    private func subtitle(_ summary: SessionSummary) -> String {
        var parts: [String] = []
        if summary.title != nil {
            parts.append(summary.startedAt.formatted(date: .omitted, time: .shortened))
        }
        if let ended = summary.endedAt {
            let minutes = Int(ended.timeIntervalSince(summary.startedAt) / 60)
            parts.append(minutes > 0 ? "\(minutes) min" : "<1 min")
        }
        if summary.status == .interrupted { parts.append("interrupted") }
        return parts.joined(separator: " · ")
    }
}
