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
                Button {
                    app.micMuted.toggle()
                } label: {
                    Image(systemName: app.micMuted ? "mic.slash.fill" : "mic.fill")
                        .foregroundStyle(app.micMuted ? .red : .secondary)
                }
                .buttonStyle(.borderless)
                .help(app.micMuted ? "Microphone muted — click to unmute" : "Mute microphone")
                LevelMeter(label: "mic", level: app.micMuted ? 0 : app.micLevel)
                LevelMeter(label: "sys", level: app.systemLevel)
                Spacer()
                if let live = app.live {
                    Text("\(live.chunksClosed) chunks · \(live.segments.count) segments")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            if case .recording = app.recording {
                HStack(spacing: 16) {
                    sourceBadge(active: true,
                                text: "System audio — \(app.systemDeviceName ?? "…")")
                    sourceBadge(active: app.micActive,
                                text: "Microphone — \(app.micDeviceName ?? "…")\(app.micActive ? "" : " (off)")")
                    Spacer()
                }
            }
            if let live = app.live, live.windowsCut > 0 {
                pipelineRow(live)
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

    private func sourceBadge(active: Bool, text: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(active ? Color.green : Color.secondary.opacity(0.35))
                .frame(width: 6, height: 6)
            Text(text)
                .font(.caption)
                .foregroundStyle(active ? .primary : .secondary)
        }
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
        case .idle: app.ambientMode ? "ambient — idle" : "idle"
        case .starting: "starting…"
        case .recording: app.ambientMode ? "ambient — listening" : "recording"
        case .finishing: "finishing…"
        }
    }

    /// Visualizes how far each pipeline stage is behind the audio: the whisper
    /// transcription backlog (windows cut vs transcribed) and the re-check queue
    /// (flagged segments vs re-checked). Bars go green when a stage is caught up.
    private func pipelineRow(_ live: LiveSession) -> some View {
        HStack(spacing: 16) {
            PipelineGauge(label: "transcribe", done: live.windowsTranscribed,
                          total: live.windowsCut, behind: live.backlog)
            if live.flagged > 0 {
                PipelineGauge(label: "re-check", done: live.recheckedIDs.count,
                              total: live.flagged, behind: live.recheckPending)
            }
            Spacer()
            correctionStatus(live)
        }
    }

    @ViewBuilder private func correctionStatus(_ live: LiveSession) -> some View {
        switch live.correctionState {
        case .idle, .done: EmptyView()
        case .batching(let nextAt):
            Label("next batch \(nextAt.formatted(date: .omitted, time: .standard))",
                  systemImage: "hourglass")
                .font(.caption2).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
        case .running:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("correcting…").font(.caption2).foregroundStyle(.secondary)
            }
        case .failed:
            Label("correction failed", systemImage: "exclamationmark.triangle")
                .font(.caption2).foregroundStyle(.orange)
        }
    }
}

/// A labeled capsule gauge (matching `LevelMeter`) for a draining work queue:
/// fills toward green as `done` approaches `total`; amber while `behind` > 0.
struct PipelineGauge: View {
    let label: String
    let done: Int
    let total: Int
    let behind: Int

    private var fraction: CGFloat {
        total > 0 ? CGFloat(done) / CGFloat(total) : 1
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(behind > 0 ? Color.orange : .green)
                        .frame(width: geo.size.width * min(1, fraction))
                }
            }
            .frame(width: 60, height: 6)
            Text(behind > 0 ? "\(behind) behind" : "\(done)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}
