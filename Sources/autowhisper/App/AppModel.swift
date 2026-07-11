import AVFoundation
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
    var micMuted = false {
        didSet { pipeline?.setMicEnabled(!micMuted) }
    }
    var systemDeviceName: String?
    var micDeviceName: String?
    var micActive = false
    var ambientMode = UserDefaults.standard.bool(forKey: "ambientMode") {
        didSet {
            UserDefaults.standard.set(ambientMode, forKey: "ambientMode")
            if ambientMode, recording == .idle { startRecording() }
            else if !ambientMode, case .recording = recording { stopRecording() }
        }
    }

    var menuGlyph: String {
        if !issues.isEmpty { return "exclamationmark.triangle" }
        if case .recording = recording { return "waveform.circle.fill" }
        if ambientMode { return "waveform.circle" }
        return "waveform.circle"
    }

    private let hub = EventHub()
    private var pipeline: Pipeline?
    private var retentionTask: Task<Void, Never>?
    private var restartAfterStop = false      // set when an ambient rollover closes a session
    private var rolloverTimer: Timer?         // fires the length/day caps independent of silence

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
        retentionTask = RetentionManager.schedule()

        // Ambient mode auto-resumes listening at launch (user-chosen behavior).
        if ambientMode {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                if self.recording == .idle { self.startRecording() }
            }
        }
    }

    // MARK: - Recording control

    func startRecording() {
        guard recording == .idle else { return }
        if ambientMode, !AmbientPolicy.hasFreeSpace() {
            recording = .idle
            hub.emit(.failure(.diskWriteFailed, detail: "less than 5 GB free — ambient capture paused"))
            return
        }
        recording = .starting
        let hub = self.hub
        Task {
            guard await Self.micAuthorized() else {
                self.recording = .idle
                hub.emit(.failure(.micPermissionDenied, detail: "grant access in System Settings → Privacy & Security → Microphone"))
                return
            }
            hub.emit(.resolved(.micPermissionDenied))
            do {
                let pipeline = try await Pipeline.start(hub: hub, micOn: !self.micMuted)
                self.pipeline = pipeline
                self.recording = .recording(since: .now)
                self.startRolloverTimer()
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

    /// Evaluates the ambient rollover policy. The silence case is driven by
    /// `.silence` events; the length/day caps are driven by `rolloverTimer`
    /// (which fires regardless of audio, so continuous speech still rolls over
    /// at the 4 h / day boundary).
    private func checkRollover(silenceRunSeconds: Double) {
        guard ambientMode, case .recording(let since) = recording else { return }
        let verdict = AmbientPolicy.rollover(
            sessionStart: since, silenceRunSeconds: silenceRunSeconds, now: .now,
            startOfToday: Calendar.current.startOfDay(for: .now))
        guard verdict != .none else { return }
        restartAfterStop = true
        stopRecording()
    }

    private func startRolloverTimer() {
        rolloverTimer?.invalidate()
        guard ambientMode else { return }
        let override = UserDefaults.standard.double(forKey: "rolloverTickOverride")
        let interval = override > 0 ? override : 60
        rolloverTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkRollover(silenceRunSeconds: 0) }
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

    func deleteSession(_ summary: SessionSummary) {
        guard summary.id != live?.id else { return }
        summaries.removeAll { $0.id == summary.id }
        Task.detached {
            SessionStore.delete(dir: summary.dir)
        }
    }

    func renameSession(_ summary: SessionSummary, to title: String) {
        Task.detached {
            SessionStore.setTitle(dir: summary.dir, title: title)
            let list = SessionStore.listSessions()
            await MainActor.run { self.summaries = list }
        }
    }

    private static func micAuthorized() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }

    // MARK: - Event application (only mutation site for counters)

    private func apply(_ event: PipelineEvent) {
        switch event {
        case .sessionStarted(let id, let dir):
            live = LiveSession(id: id, dir: dir)

        case .captureState(let systemDevice, let micDevice, let micActive):
            self.systemDeviceName = systemDevice
            self.micDeviceName = micDevice
            self.micActive = micActive

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

        case .silence(let seconds):
            checkRollover(silenceRunSeconds: seconds)   // silence-triggered path

        case .draftSegments(let batch):
            live?.windowsTranscribed += 1
            live?.segments.append(contentsOf: batch)

        case .rechecked(let ids):
            live?.recheckedIDs.formUnion(ids)

        case .correctionApplied(let map):
            live?.corrections.merge(map) { _, new in new }

        case .correction(let state):
            live?.correctionState = state

        case .transcriptWritten:
            if let dir = live?.dir {
                live?.closedArtifacts = SessionStore.artifacts(dir: dir)
            }

        case .sessionEnded(let summary):
            // Ambient generates many empty sessions during quiet stretches —
            // suppress ones with no transcribed speech instead of listing them.
            let empty = (live?.segments.isEmpty ?? false)
            live = nil
            micLevel = 0
            systemLevel = 0
            micActive = false
            systemDeviceName = nil
            recording = .idle
            rolloverTimer?.invalidate()
            rolloverTimer = nil
            summaries.removeAll { $0.id == summary.id }
            if empty {
                let dir = summary.dir
                Task.detached { SessionStore.delete(dir: dir) }
            } else {
                summaries.insert(summary, at: 0)
            }
            if restartAfterStop {
                restartAfterStop = false
                if ambientMode { startRecording() }
            }

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
    private let chunkerTask: Task<Void, Never>
    private let orchestrator: CorrectionOrchestrator
    private let hub: EventHub
    private let id: String
    private let dir: URL
    private let startedAt: Date

    static func start(hub: EventHub, micOn: Bool) async throws -> Pipeline {
        guard await ModelStore.ensure(.baseEN, hub: hub),
              await ModelStore.ensure(.vad, hub: hub) else {
            throw NSError(domain: "autowhisper", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "whisper models unavailable"])
        }
        let (id, dir) = try SessionStore.createSession()
        let engine = CaptureEngine(hub: hub)
        let archive = try ArchiveWriter(sessionDir: dir, hub: hub)
        let orchestrator = CorrectionOrchestrator(sessionDir: dir, hub: hub)
        let chunker = VADChunker(sessionDir: dir, hub: hub, orchestrator: orchestrator)
        let archivePCM = engine.makePCMStream()
        let chunkerPCM = engine.makePCMStream()
        try engine.start(micOn: micOn)
        let archiveTask = Task { await archive.run(archivePCM) }
        let chunkerTask = Task { await chunker.run(chunkerPCM) }
        hub.emit(.sessionStarted(id: id, dir: dir))
        return Pipeline(engine: engine, archiveTask: archiveTask, chunkerTask: chunkerTask,
                        orchestrator: orchestrator, hub: hub, id: id, dir: dir)
    }

    private init(engine: CaptureEngine, archiveTask: Task<Void, Never>,
                 chunkerTask: Task<Void, Never>, orchestrator: CorrectionOrchestrator,
                 hub: EventHub, id: String, dir: URL) {
        self.engine = engine
        self.archiveTask = archiveTask
        self.chunkerTask = chunkerTask
        self.orchestrator = orchestrator
        self.hub = hub
        self.id = id
        self.dir = dir
        self.startedAt = .now
    }

    func setMicEnabled(_ enabled: Bool) {
        engine.setMicEnabled(enabled)
    }

    func stop() async {
        engine.stop()                  // finishes every PCM stream
        await archiveTask.value        // archive drains + closes last chunk
        await chunkerTask.value        // chunker flushes + last window transcribed
        await orchestrator.finish()    // final claude batch + transcript.md
        SessionStore.finalize(dir: dir, status: .finished)
        hub.emit(.sessionEnded(SessionSummary(
            id: id, dir: dir, startedAt: startedAt, endedAt: .now, status: .finished)))
    }
}
