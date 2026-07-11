import Events
import SwiftUI

struct StatusStrip: View {
    @Bindable var app: AppModel

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 12) {
                stateDot
                if case .recording(let since) = app.recording {
                    Text(timerInterval: since...Date.distantFuture, countsDown: false)
                        .monospacedDigit()
                }
                LevelMeter(label: "mic", level: app.micLevel)
                LevelMeter(label: "sys", level: app.systemLevel)
                Spacer()
                if let live = app.live {
                    Text(counters(live))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            ForEach(app.issues) { issue in
                HStack {
                    Label(issue.kind.label + (issue.detail.map { " — \($0)" } ?? ""),
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .lineLimit(1)
                    Spacer()
                    Button("Dismiss") { app.dismissIssue(issue.id) }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var stateDot: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(dotColor)
                .frame(width: 9, height: 9)
            Text(stateText).font(.callout)
        }
    }

    private var dotColor: Color {
        switch app.recording {
        case .recording: .red
        case .starting, .finishing: .orange
        case .idle: .secondary.opacity(0.4)
        }
    }

    private var stateText: String {
        switch app.recording {
        case .idle: "idle"
        case .starting: "starting…"
        case .recording: "recording"
        case .finishing: "finishing…"
        }
    }

    private func counters(_ live: LiveSession) -> String {
        var parts = ["\(live.chunksClosed) chunks"]
        if live.windowsCut > 0 {
            parts.append("\(live.segments.count) segments")
            if live.backlog > 0 { parts.append("backlog \(live.backlog)") }
            if live.recheckPending > 0 { parts.append("\(live.recheckPending) re-checks pending") }
        }
        switch live.correctionState {
        case .idle, .done: break
        case .batching(let nextAt):
            parts.append("next batch \(nextAt.formatted(date: .omitted, time: .standard))")
        case .running: parts.append("correcting…")
        case .failed: parts.append("correction failed")
        }
        return parts.joined(separator: " · ")
    }
}
