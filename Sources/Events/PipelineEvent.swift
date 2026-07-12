import Foundation

public struct DraftSegment: Codable, Identifiable, Sendable, Equatable {
    public let id: Int
    public let t0_ms: Int
    public let t1_ms: Int
    public let text: String
    public let avg_p: Float
    public let no_speech_prob: Float
    public let flagged: Bool
    public var speaker: String?   // resolved label ("Ben", "Speaker 1"); nil until attributed

    public init(id: Int, t0_ms: Int, t1_ms: Int, text: String, avg_p: Float,
                no_speech_prob: Float, flagged: Bool, speaker: String? = nil) {
        self.id = id
        self.t0_ms = t0_ms
        self.t1_ms = t1_ms
        self.text = text
        self.avg_p = avg_p
        self.no_speech_prob = no_speech_prob
        self.flagged = flagged
        self.speaker = speaker
    }
}

public enum IssueKind: Hashable, CaseIterable, Sendable {
    case micPermissionDenied
    case audioTapPermissionDenied
    case tapInvalidated
    case modelMissing
    case correctionFailed
    case diskWriteFailed
}

public struct Issue: Identifiable, Sendable {
    public let kind: IssueKind
    public let detail: String?
    public let at: Date
    public let id = UUID()

    public init(kind: IssueKind, detail: String?, at: Date = .now) {
        self.kind = kind
        self.detail = detail
        self.at = at
    }
}

public enum CorrectionState: Sendable, Equatable {
    case idle
    case batching(nextAt: Date)
    case running
    case failed(String)
    case done
}

public struct SessionSummary: Identifiable, Sendable, Equatable {
    public let id: String
    public let dir: URL
    public let startedAt: Date
    public let endedAt: Date?
    public let status: SessionStatus
    public let title: String?

    public init(id: String, dir: URL, startedAt: Date, endedAt: Date?, status: SessionStatus,
                title: String? = nil) {
        self.id = id
        self.dir = dir
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.status = status
        self.title = title
    }
}

public enum SessionStatus: String, Codable, Sendable {
    case recording, finished, interrupted
}

public struct Artifact: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable {
        case transcript, jsonl, audioChunk
    }

    public let name: String
    public let url: URL
    public let kind: Kind
    public var id: URL { url }

    public init(name: String, url: URL, kind: Kind) {
        self.name = name
        self.url = url
        self.kind = kind
    }
}

public enum PipelineEvent: Sendable {
    case sessionStarted(id: String, dir: URL)
    case captureState(systemDevice: String, micDevice: String?, micActive: Bool)
    case levels(mic: Float, system: Float)      // ≤10 Hz, throttled at source
    case chunkClosed(index: Int)                // after AVAudioFile finalized
    case windowCut                              // VAD window handed to transcriber
    case silence(seconds: Double)               // running continuous-silence duration (ambient segmentation)
    case draftSegments([DraftSegment])          // one VAD window's batch, post-JSONL-append
    case rechecked(ids: [Int])                  // after recheck.jsonl append
    case speakersAttributed([Int: String])      // segment id → speaker label (per-window diarization)
    case correctionApplied([Int: String])       // segment id → corrected text, post-jsonl-append
    case correction(CorrectionState)
    case transcriptWritten(URL)
    case sessionEnded(SessionSummary)           // from the last stage to finish
    case failure(IssueKind, detail: String?)
    case resolved(IssueKind)
}

public struct EventHub: Sendable {
    public let stream: AsyncStream<PipelineEvent>
    private let cont: AsyncStream<PipelineEvent>.Continuation

    public init() {
        (stream, cont) = AsyncStream.makeStream()   // unbounded: UI can never back-pressure the pipeline
    }

    public func emit(_ e: PipelineEvent) {
        cont.yield(e)
    }
}
