import AppKit
import Events
import SwiftUI

enum TranscriptMode: String, CaseIterable {
    case draft = "Draft"
    case corrected = "Corrected"
}

struct SessionView: View {
    @Bindable var app: AppModel
    let sessionID: String?

    @State private var loaded: LoadedSession?
    @State private var mode: TranscriptMode = .corrected
    @State private var searchText = ""

    struct LoadedSession {
        let id: String
        let segments: [DraftSegment]
        let recheckedIDs: Set<Int>
        let corrections: [Int: String]
        let artifacts: [Artifact]
        let audioExpired: Bool
    }

    var body: some View {
        Group {
            if let live = app.live, live.id == sessionID {
                content(segments: live.segments, recheckedIDs: live.recheckedIDs,
                        corrections: live.corrections, artifacts: live.closedArtifacts,
                        audioExpired: false, isLive: true)
            } else if let loaded, loaded.id == sessionID {
                content(segments: loaded.segments, recheckedIDs: loaded.recheckedIDs,
                        corrections: loaded.corrections, artifacts: loaded.artifacts,
                        audioExpired: loaded.audioExpired, isLive: false)
            } else if sessionID != nil {
                ProgressView()
            } else {
                ContentUnavailableView("No session selected", systemImage: "waveform",
                                       description: Text("Pick a session, or start recording from the menu bar."))
            }
        }
        .task(id: sessionID) {
            guard let sessionID, app.live?.id != sessionID,
                  let summary = app.summaries.first(where: { $0.id == sessionID }) else { return }
            loaded = nil
            let dir = summary.dir
            let result = await Task.detached {
                LoadedSession(id: sessionID,
                              segments: SessionStore.loadDraftSegments(dir: dir),
                              recheckedIDs: SessionStore.loadRecheckedIDs(dir: dir),
                              corrections: SessionStore.loadCorrections(dir: dir),
                              artifacts: SessionStore.artifacts(dir: dir),
                              audioExpired: SessionStore.audioExpired(dir: dir))
            }.value
            loaded = result
        }
    }

    private func content(segments: [DraftSegment], recheckedIDs: Set<Int>,
                         corrections: [Int: String], artifacts: [Artifact],
                         audioExpired: Bool, isLive: Bool) -> some View {
        VStack(spacing: 0) {
            SessionHeader(app: app, sessionID: sessionID, segments: segments,
                          corrections: corrections, isLive: isLive,
                          mode: $mode, searchText: $searchText)
            Divider()
            TranscriptView(segments: segments, recheckedIDs: recheckedIDs,
                           corrections: corrections, isLive: isLive,
                           mode: mode, searchText: searchText)
            Divider()
            ArtifactBar(artifacts: artifacts, audioExpired: audioExpired)
        }
    }
}

struct SessionHeader: View {
    @Bindable var app: AppModel
    let sessionID: String?
    let segments: [DraftSegment]
    let corrections: [Int: String]
    let isLive: Bool
    @Binding var mode: TranscriptMode
    @Binding var searchText: String

    @State private var editedTitle = ""

    private var summary: SessionSummary? {
        app.summaries.first { $0.id == sessionID }
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if isLive {
                    Text("Live session").font(.headline)
                } else {
                    TextField(summary?.startedAt.formatted(date: .abbreviated, time: .shortened) ?? "Untitled",
                              text: $editedTitle)
                        .textFieldStyle(.plain)
                        .font(.headline)
                        .onSubmit {
                            if let summary { app.renameSession(summary, to: editedTitle) }
                        }
                }
                Text(statsLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: $mode) {
                ForEach(TranscriptMode.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .help("Draft shows raw whisper output; Corrected applies Claude's fixes.")
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find in transcript", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            .frame(width: 190)
            Button {
                copyTranscript()
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .help("Copy transcript (current view)")
            .disabled(segments.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onChange(of: sessionID) { _, _ in
            editedTitle = summary?.title ?? ""
        }
        .onAppear { editedTitle = summary?.title ?? "" }
    }

    private var statsLine: String {
        var parts: [String] = []
        if let summary {
            parts.append(summary.startedAt.formatted(date: .abbreviated, time: .shortened))
            if let ended = summary.endedAt {
                let minutes = Int(ended.timeIntervalSince(summary.startedAt) / 60)
                parts.append(minutes > 0 ? "\(minutes) min" : "<1 min")
            }
            if summary.status == .interrupted { parts.append("interrupted") }
        }
        let words = segments.reduce(0) { $0 + $1.text.split(separator: " ").count }
        parts.append("\(segments.count) segments")
        parts.append("\(words) words")
        let flagged = segments.count(where: \.flagged)
        if flagged > 0 { parts.append("\(flagged) flagged") }
        if !corrections.isEmpty { parts.append("\(corrections.count) corrected") }
        return parts.joined(separator: " · ")
    }

    private func copyTranscript() {
        let text = segments.map { segment in
            let s = segment.t0_ms / 1000
            let body = mode == .corrected ? (corrections[segment.id] ?? segment.text) : segment.text
            return String(format: "[%d:%02d] %@", s / 60, s % 60, body)
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
