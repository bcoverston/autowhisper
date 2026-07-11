import Events
import SwiftUI

/// RAW pane: draft segments as rows, live-streaming or loaded from disk.
struct TranscriptView: View {
    let segments: [DraftSegment]
    let recheckedIDs: Set<Int>
    let corrections: [Int: String]
    let isLive: Bool

    var body: some View {
        if segments.isEmpty {
            ContentUnavailableView(
                isLive ? "Waiting for speech…" : "No transcript",
                systemImage: "text.quote",
                description: Text(isLive ? "Draft segments appear here as they are transcribed."
                                         : "This session has no draft transcript."))
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(segments) { segment in
                        SegmentRow(segment: segment,
                                   rechecked: recheckedIDs.contains(segment.id),
                                   corrected: corrections[segment.id])
                    }
                }
                .padding(10)
            }
            .defaultScrollAnchor(isLive ? .bottom : .top)
        }
    }
}

struct SegmentRow: View {
    let segment: DraftSegment
    let rechecked: Bool
    let corrected: String?

    @State private var showCorrection = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Rectangle()
                .fill(segment.flagged ? Color.orange : .clear)
                .frame(width: 3)
            Text(timestamp)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 60, alignment: .trailing)
            Text(segment.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            gutter
        }
        .help(segment.flagged
              ? String(format: "avg_p %.2f · no_speech %.2f", segment.avg_p, segment.no_speech_prob)
              : "")
    }

    private var timestamp: String {
        let s = segment.t0_ms / 1000
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    @ViewBuilder private var gutter: some View {
        if let corrected {
            Button {
                showCorrection.toggle()
            } label: {
                Image(systemName: corrected != segment.text ? "checkmark.circle.fill" : "checkmark.circle")
                    .foregroundStyle(.green)
            }
            .buttonStyle(.borderless)
            .popover(isPresented: $showCorrection) {
                Text(corrected).padding().frame(maxWidth: 360)
            }
        } else if segment.flagged && !rechecked {
            ProgressView().controlSize(.mini)
        }
    }
}
