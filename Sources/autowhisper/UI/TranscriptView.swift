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

    @State private var hoveredID: Int?

    private var visible: [(segment: DraftSegment, paragraphBreak: Bool)] {
        let matching = searchText.isEmpty
            ? segments
            : segments.filter {
                displayText(for: $0).localizedCaseInsensitiveContains(searchText)
            }
        return matching.enumerated().map { index, segment in
            let gap = index > 0 && segment.t0_ms - matching[index - 1].t1_ms > 2_000
            return (segment, gap)
        }
    }

    var body: some View {
        if segments.isEmpty {
            ContentUnavailableView(
                isLive ? "Waiting for speech…" : "No transcript",
                systemImage: "text.quote",
                description: Text(isLive ? "Draft segments appear here as they are transcribed."
                                         : "This session has no draft transcript."))
        } else if visible.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(visible, id: \.segment.id) { entry in
                        SegmentRow(segment: entry.segment,
                                   text: displayText(for: entry.segment),
                                   isCorrected: corrections[entry.segment.id].map { $0 != entry.segment.text } ?? false,
                                   rechecked: recheckedIDs.contains(entry.segment.id),
                                   showDraftMarkers: mode == .draft,
                                   searchText: searchText,
                                   hovered: hoveredID == entry.segment.id)
                            .padding(.top, entry.paragraphBreak ? 14 : 0)
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
}

struct SegmentRow: View {
    let segment: DraftSegment
    let text: String
    let isCorrected: Bool
    let rechecked: Bool
    let showDraftMarkers: Bool
    let searchText: String
    let hovered: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Rectangle()
                .fill(showDraftMarkers && segment.flagged ? Color.orange : .clear)
                .frame(width: 3)
            Text(timestamp)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 44, alignment: .trailing)
            Text(highlighted)
                .font(.body)
                .lineSpacing(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing
                .frame(width: 60, alignment: .trailing)
        }
        .padding(.vertical, 3)
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
