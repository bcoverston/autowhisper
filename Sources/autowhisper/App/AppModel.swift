import Events
import Foundation
import Observation

enum RecordingState: Equatable {
    case idle
    case starting
    case recording(since: Date)
    case finishing
}

struct LiveSession {
    let id: String
    let dir: URL
    var chunksClosed = 0
    var windowsCut = 0
    var windowsTranscribed = 0
    var segments: [DraftSegment] = []
    var recheckedIDs: Set<Int> = []
    var corrections: [Int: String] = [:]
    var correctionState: CorrectionState = .idle
    var closedArtifacts: [Artifact] = []

    // Derived — never stored, can't drift.
    var flagged: Int { segments.count(where: \.flagged) }
    var recheckPending: Int { flagged - recheckedIDs.count }
    var backlog: Int { windowsCut - windowsTranscribed }
}

@Observable @MainActor
final class AppModel {
    var recording: RecordingState = .idle
    var micLevel: Float = 0
    var systemLevel: Float = 0
    var live: LiveSession?
    var issues: [Issue] = []
    var summaries: [SessionSummary] = []

    var menuGlyph: String {
        if !issues.isEmpty { return "exclamationmark.triangle" }
        if case .recording = recording { return "waveform.circle.fill" }
        return "waveform.circle"
    }

    private let hub = EventHub()
    private var pipeline: Pipeline?

    init() {
        // Process-lifetime event loop: the single mutation site for pipeline state.
        let stream = hub.stream
        Task { [weak self] in
            for await event in stream {
                self?.apply(event)
            }
        }
        Task.detached {
            SessionStore.sweepInterrupted()
            let list = SessionStore.listSessions()
            await MainActor.run { [weak self] in self?.summaries = list }
        }
    }

    // MARK: - Recording control

    func startRecording() {
        guard recording == .idle else { return }
        recording = .starting
        let hub = self.hub
        Task {
            do {
                let pipeline = try await Pipeline.start(hub: hub)
                self.pipeline = pipeline
                self.recording = .recording(since: .now)
            } catch {
                self.recording = .idle
                hub.emit(.failure(.tapInvalidated, detail: "\(error)"))
            }
        }
    }

    func stopRecording() {
        guard case .recording = recording, let pipeline else { return }
        recording = .finishing
        Task {
            await pipeline.stop()
            self.pipeline = nil
        }
    }

    func refreshSummaries() {
        Task.detached {
            let list = SessionStore.listSessions()
            await MainActor.run { self.summaries = list }
        }
    }

    func dismissIssue(_ id: UUID) {
        issues.removeAll { $0.id == id }
    }

    // MARK: - Event application (only mutation site for counters)

    private func apply(_ event: PipelineEvent) {
        switch event {
        case .sessionStarted(let id, let dir):
            live = LiveSession(id: id, dir: dir)

        case .levels(let mic, let system):
            micLevel = mic
            systemLevel = system

        case .chunkClosed:
            live?.chunksClosed += 1
            if let dir = live?.dir {
                live?.closedArtifacts = SessionStore.artifacts(dir: dir)
            }

        case .windowCut:
            live?.windowsCut += 1

        case .draftSegments(let batch):
            live?.windowsTranscribed += 1
            live?.segments.append(contentsOf: batch)

        case .rechecked(let ids):
            live?.recheckedIDs.formUnion(ids)

        case .correction(let state):
            live?.correctionState = state

        case .transcriptWritten:
            if let dir = live?.dir {
                live?.closedArtifacts = SessionStore.artifacts(dir: dir)
            }

        case .sessionEnded(let summary):
            live = nil
            micLevel = 0
            systemLevel = 0
            recording = .idle
            summaries.removeAll { $0.id == summary.id }
            summaries.insert(summary, at: 0)

        case .failure(let kind, let detail):
            guard !issues.contains(where: { $0.kind == kind }) else { return }
            issues.append(Issue(kind: kind, detail: detail))

        case .resolved(let kind):
            issues.removeAll { $0.kind == kind }
        }
    }
}

/// One recording session's running stages. Construction starts capture;
/// `stop()` drains every stage, finalizes session.json, and emits sessionEnded.
final class Pipeline: Sendable {
    private let engine: CaptureEngine
    private let archiveTask: Task<Void, Never>
    private let hub: EventHub
    private let id: String
    private let dir: URL
    private let startedAt: Date

    static func start(hub: EventHub) async throws -> Pipeline {
        let (id, dir) = try SessionStore.createSession()
        let engine = CaptureEngine(hub: hub)
        try engine.start()
        let archive = try ArchiveWriter(sessionDir: dir, hub: hub)
        let pcm = engine.pcm
        let archiveTask = Task { await archive.run(pcm) }
        hub.emit(.sessionStarted(id: id, dir: dir))
        return Pipeline(engine: engine, archiveTask: archiveTask, hub: hub, id: id, dir: dir)
    }

    private init(engine: CaptureEngine, archiveTask: Task<Void, Never>, hub: EventHub,
                 id: String, dir: URL) {
        self.engine = engine
        self.archiveTask = archiveTask
        self.hub = hub
        self.id = id
        self.dir = dir
        self.startedAt = .now
    }

    func stop() async {
        engine.stop()                  // finishes the PCM stream
        await archiveTask.value        // archive drains + closes last chunk
        SessionStore.finalize(dir: dir, status: .finished)
        hub.emit(.sessionEnded(SessionSummary(
            id: id, dir: dir, startedAt: startedAt, endedAt: .now, status: .finished)))
    }
}
