import AppKit
import Events
import SwiftUI

/// Transcript pane: draft or corrected text, live-streaming or loaded from disk,
/// with search filtering, paragraph gaps at speech pauses, and hover actions.
struct TranscriptView: View {
    let segments: [DraftSegment]
    let recheckedIDs: Set<Int>
    let corrections: [Int: String]
    let isLive: Bool
    let mode: TranscriptMode
    let searchText: String
    var onTagSpeaker: ((String) -> Void)?
    var onAssignSpeaker: ((String, String) -> Void)?
    var onMarkMisidentified: ((String) -> Void)?
    var knownVoices: [String] = []
    var player: SegmentPlayer?
    var sessionDir: URL?

    @State private var hoveredID: Int?

    private var visible: [(segment: DraftSegment, paragraphBreak: Bool, speakerHeader: String?)] {
        let matching = searchText.isEmpty
            ? segments
            : segments.filter {
                displayText(for: $0).localizedCaseInsensitiveContains(searchText)
            }
        return matching.enumerated().map { index, segment in
            let prev = index > 0 ? matching[index - 1] : nil
            let gap = prev != nil && segment.t0_ms - prev!.t1_ms > 2_000
            // Show a speaker header when the speaker changes.
            let header = segment.speaker != nil && segment.speaker != prev?.speaker ? segment.speaker : nil
            return (segment, gap, header)
        }
    }

    var body: some View {
        if segments.isEmpty {
            ContentUnavailableView(
                isLive ? "Waiting for speech…" : "No transcript",
                systemImage: "text.quote",
                description: Text(isLive ? "Draft segments appear here as they are transcribed."
                                         : "This session has no draft transcript."))
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 64)
        } else if visible.isEmpty {
            ContentUnavailableView.search(text: searchText)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 64)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(visible, id: \.segment.id) { entry in
                        if let header = entry.speakerHeader {
                            speakerHeader(header)
                                .padding(.top, entry.paragraphBreak ? 14 : 8)
                        }
                        SegmentRow(segment: entry.segment,
                                   text: displayText(for: entry.segment),
                                   isCorrected: corrections[entry.segment.id].map { $0 != entry.segment.text } ?? false,
                                   rechecked: recheckedIDs.contains(entry.segment.id),
                                   showDraftMarkers: mode == .draft,
                                   searchText: searchText,
                                   hovered: hoveredID == entry.segment.id,
                                   canPlay: sessionDir != nil,
                                   isPlaying: player?.playingID == entry.segment.id,
                                   onPlay: { if let dir = sessionDir { player?.toggle(entry.segment, sessionDir: dir) } })
                            .padding(.top, entry.speakerHeader == nil && entry.paragraphBreak ? 14 : 0)
                            .onHover { hoveredID = $0 ? entry.segment.id : nil }
                    }
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
                .frame(maxWidth: 780, alignment: .leading)
            }
            .defaultScrollAnchor(isLive && searchText.isEmpty ? .bottom : .top)
        }
    }

    private func displayText(for segment: DraftSegment) -> String {
        mode == .corrected ? (corrections[segment.id] ?? segment.text) : segment.text
    }

    private func speakerHeader(_ label: String) -> some View {
        let matched = SpeakerColor.isMatched(label)
        return HStack(spacing: 6) {
            SpeakerChip(label: label)
            if onTagSpeaker != nil {
                Menu {
                    Button(matched ? "Reassign (not \(label))…" : "Tag as…") {
                        onTagSpeaker?(label)
                    }
                    let others = knownVoices.filter { $0.caseInsensitiveCompare(label) != .orderedSame }
                    if !others.isEmpty {
                        Menu("Assign to") {
                            ForEach(others, id: \.self) { name in
                                Button(name) { onAssignSpeaker?(label, name) }
                            }
                        }
                    }
                    if matched {
                        Divider()
                        Button("Mark misidentified", role: .destructive) {
                            onMarkMisidentified?(label)
                        }
                    }
                } label: {
                    Image(systemName: matched ? "pencil.circle" : "person.crop.circle.badge.plus")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(.secondary)
                .help(matched ? "Correct this speaker" : "Tag this speaker")
            }
            Spacer()
        }
        .padding(.leading, 55)
    }
}

struct SegmentRow: View {
    let segment: DraftSegment
    let text: String
    let isCorrected: Bool
    let rechecked: Bool
    let showDraftMarkers: Bool
    let searchText: String
    let hovered: Bool
    var canPlay = false
    var isPlaying = false
    var onPlay: (() -> Void)?

    var body: some View {
        // .top alignment (not .firstTextBaseline): the wrapping transcript text
        // determines the row height, so multi-line segments can't overlap the
        // next row. Fixed-width gutters sit at the first line via a small top pad.
        HStack(alignment: .top, spacing: 8) {
            Rectangle()
                .fill(showDraftMarkers && segment.flagged ? Color.orange : .clear)
                .frame(width: 3)
            // Play control appears on hover (or while playing); reserves gutter width.
            Group {
                if canPlay, hovered || isPlaying {
                    Button { onPlay?() } label: {
                        Image(systemName: isPlaying ? "stop.fill" : "play.fill").font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .help(isPlaying ? "Stop" : "Play this segment")
                } else {
                    Color.clear
                }
            }
            .frame(width: 14, height: 16)
            Text(timestamp)
                .font(.caption.monospacedDigit())
                .foregroundStyle(isPlaying ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                .frame(width: 44, alignment: .trailing)
                .padding(.top, 2)
            Text(highlighted)
                .font(.body)
                .lineSpacing(2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing
                .frame(width: 60, alignment: .trailing)
                .padding(.top, 2)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .background(hovered ? Color.primary.opacity(0.05) : .clear,
                    in: RoundedRectangle(cornerRadius: 5))
    }

    private var timestamp: String {
        let s = segment.t0_ms / 1000
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private var highlighted: AttributedString {
        var attributed = AttributedString(text)
        guard !searchText.isEmpty else { return attributed }
        var searchStart = attributed.startIndex
        while let range = attributed[searchStart...].range(of: searchText, options: .caseInsensitive) {
            attributed[range].backgroundColor = .yellow.opacity(0.4)
            searchStart = range.upperBound
        }
        return attributed
    }

    @ViewBuilder private var trailing: some View {
        HStack(spacing: 5) {
            if hovered {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc").font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Copy segment")
            }
            if hovered && segment.flagged {
                Text(String(format: "p %.2f", segment.avg_p))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.orange)
            } else if isCorrected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .help(showDraftMarkers ? "Corrected by Claude" : "Differs from draft")
            } else if showDraftMarkers && segment.flagged && !rechecked {
                ProgressView().controlSize(.mini)
            }
        }
    }
}
