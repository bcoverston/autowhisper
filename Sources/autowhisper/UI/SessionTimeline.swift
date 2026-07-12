import Events
import SwiftUI

/// A horizontal "waterfall" of the session over time: a slim top lane of audio
/// chunks (5-min archive blocks) and a segment skyline below it (each speech
/// segment a bar whose height is its transcription confidence, colored by
/// state). Faint guides mark chunk boundaries; a red playhead tracks "now" while
/// live. The whole session is fit to the pane width, so it grows left→right as
/// speech accrues. Tap a segment to play it.
struct SessionTimeline: View {
    let segments: [DraftSegment]
    let chunksClosed: Int
    let corrections: [Int: String]
    let isLive: Bool
    var playingID: Int?
    var onSeek: ((DraftSegment) -> Void)?

    private static let chunkMs = 300_000

    private var durationMs: CGFloat {
        CGFloat(max(segments.last?.t1_ms ?? 0, chunksClosed * Self.chunkMs, 1))
    }

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in draw(ctx, size) }
                .contentShape(Rectangle())
                .onTapGesture { location in seek(x: location.x, width: geo.size.width) }
        }
        .frame(height: 46)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .help("Session timeline — chunks on top, speech segments below (height = confidence). Tap to play.")
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        let scale = size.width / durationMs
        let chunkLaneH: CGFloat = 6
        let segTop = chunkLaneH + 4
        let segH = size.height - segTop

        // Chunk lane: one cell per archive block; filled = closed, faint = in-flight.
        let derived = Int((durationMs / CGFloat(Self.chunkMs)).rounded(.up))
        let cells = max(isLive ? chunksClosed + 1 : max(chunksClosed, derived), 1)
        for c in 0..<cells {
            let x = CGFloat(c * Self.chunkMs) * scale
            let w = min(max(1, CGFloat(Self.chunkMs) * scale - 1), size.width - x)
            guard w > 0 else { continue }
            let closed = c < chunksClosed
            ctx.fill(Path(roundedRect: CGRect(x: x, y: 0, width: w, height: chunkLaneH),
                          cornerRadius: 1),
                     with: .color(.secondary.opacity(closed ? 0.5 : 0.15)))
        }

        // Chunk-boundary guides through the segment lane.
        var b = Self.chunkMs
        while CGFloat(b) < durationMs {
            let x = CGFloat(b) * scale
            var p = Path()
            p.move(to: CGPoint(x: x, y: segTop))
            p.addLine(to: CGPoint(x: x, y: size.height))
            ctx.stroke(p, with: .color(.secondary.opacity(0.12)), lineWidth: 0.5)
            b += Self.chunkMs
        }

        // Segment skyline: height ∝ confidence, color ∝ state.
        for seg in segments {
            let x = CGFloat(seg.t0_ms) * scale
            let w = min(max(1.5, CGFloat(seg.t1_ms - seg.t0_ms) * scale), size.width - x)
            guard w > 0 else { continue }
            let conf = max(0, min(1, CGFloat(seg.avg_p)))
            let h = segH * (0.35 + 0.65 * conf)
            let rect = CGRect(x: x, y: size.height - h, width: w, height: h)
            let base: Color = seg.flagged ? .orange
                : (corrections[seg.id] != nil ? .green : .accentColor)
            let color = seg.id == playingID ? Color.primary : base.opacity(0.8)
            ctx.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color))
        }

        // Live playhead at the current time.
        if isLive {
            let x = min(durationMs * scale, size.width) - 0.5
            var p = Path()
            p.move(to: CGPoint(x: x, y: 0))
            p.addLine(to: CGPoint(x: x, y: size.height))
            ctx.stroke(p, with: .color(.red.opacity(0.7)), lineWidth: 1)
        }
    }

    /// Map a tap to the segment under it (or the nearest) and play it.
    private func seek(x: CGFloat, width: CGFloat) {
        guard let onSeek, !segments.isEmpty, width > 0 else { return }
        let tMs = Int(x / width * durationMs)
        let hit = segments.first { $0.t0_ms <= tMs && tMs <= $0.t1_ms }
            ?? segments.min { abs($0.t0_ms - tMs) < abs($1.t0_ms - tMs) }
        if let hit { onSeek(hit) }
    }
}
