import Events
import Foundation
import whisper

/// Cuts the mixed PCM stream into speech-bounded windows using Silero VAD,
/// transcribes each window, appends to draft.jsonl (disk-first), then emits.
/// Session-length agnostic: silence is dropped, so ambient mode is a policy
/// change, not a re-architecture. Backlog lives in `pending` (in-memory;
/// ~230 MB/h worst case if whisper stalls completely — acceptable for v1).
actor VADChunker {
    private static let rate = 16_000
    private static let minWindow = 15 * rate          // consider cutting after 15 s
    private static let maxWindow = 30 * rate          // force cut at 30 s
    private static let tailSilence = 0.7              // seconds of quiet that closes a window

    private let hub: EventHub
    private let draftLog: JSONLWriter
    private let orchestrator: CorrectionOrchestrator
    private var vad: OpaquePointer?
    private var pending: [Float] = []
    private var baseSample = 0                        // session-absolute offset of pending[0]
    private var nextSegmentID = 0
    private var silenceRunSeconds = 0.0               // continuous silence since last speech

    init(sessionDir: URL, hub: EventHub, orchestrator: CorrectionOrchestrator) {
        self.hub = hub
        self.draftLog = JSONLWriter(url: sessionDir.appending(path: "draft.jsonl"))
        self.orchestrator = orchestrator
    }

    func run(_ stream: AsyncStream<[Float]>) async {
        for await block in stream {
            pending.append(contentsOf: block)
            while let cut = cutPoint() {
                await emitWindow(length: cut)
            }
        }
        // Session end: flush whatever remains if it contains speech.
        if !pending.isEmpty, speechSegments(in: pending)?.isEmpty == false {
            await emitWindow(length: pending.count)
        }
        if let vad { whisper_vad_free(vad) }
        vad = nil
    }

    /// Returns a window length to cut, or nil to keep accumulating.
    private func cutPoint() -> Int? {
        guard pending.count >= Self.minWindow else { return nil }
        guard let segments = speechSegments(in: pending) else { return nil }

        if segments.isEmpty {
            // Pure silence: drop it (this is what makes always-on cheap).
            silenceRunSeconds += Double(pending.count) / Double(Self.rate)
            hub.emit(.silence(seconds: silenceRunSeconds))
            baseSample += pending.count
            pending.removeAll(keepingCapacity: true)
            return nil
        }
        silenceRunSeconds = 0
        // Cut after the last speech end if enough trailing quiet has accrued.
        let lastEnd = Int(segments.last!.end * Double(Self.rate))
        if Double(pending.count - lastEnd) / Double(Self.rate) >= Self.tailSilence {
            return min(lastEnd + Int(Double(Self.rate) * 0.2), pending.count)
        }
        if pending.count >= Self.maxWindow {
            return Self.maxWindow
        }
        return nil
    }

    private func emitWindow(length: Int) async {
        let window = Array(pending[0..<length])
        let offsetMs = baseSample * 1000 / Self.rate
        pending.removeFirst(length)
        baseSample += length
        hub.emit(.windowCut)
        do {
            let segments = try await WhisperTranscriber.shared.transcribe(
                window: window, offsetMs: offsetMs, firstID: nextSegmentID)
            nextSegmentID += segments.count
            try draftLog.append(segments)               // disk first…
            hub.emit(.draftSegments(segments))          // …event second
            if !segments.isEmpty {
                await orchestrator.enqueue(segments, window: window, windowOffsetMs: offsetMs)
            }
        } catch {
            hub.emit(.failure(.diskWriteFailed, detail: "draft: \(error.localizedDescription)"))
            hub.emit(.draftSegments([]))                // keep windowsTranscribed counter honest
        }
    }

    private func speechSegments(in samples: [Float]) -> [(start: Double, end: Double)]? {
        if vad == nil {
            WhisperTranscriber.quietLogs()
            var params = whisper_vad_default_context_params()
            params.use_gpu = false
            vad = whisper_vad_init_from_file_with_params(ModelStore.Model.vad.url.path, params)
        }
        guard let vad else { return nil }
        let vparams = whisper_vad_default_params()
        guard let segs = samples.withUnsafeBufferPointer({
            whisper_vad_segments_from_samples(vad, vparams, $0.baseAddress, Int32($0.count))
        }) else { return nil }
        defer { whisper_vad_free_segments(segs) }
        return (0..<whisper_vad_segments_n_segments(segs)).map {
            (Double(whisper_vad_segments_get_segment_t0(segs, $0)) / 100,
             Double(whisper_vad_segments_get_segment_t1(segs, $0)) / 100)
        }
    }
}

/// Append-only JSONL file writer (one Encodable value per line).
final class JSONLWriter: Sendable {
    private let url: URL

    init(url: URL) {
        self.url = url
    }

    func append<T: Encodable>(_ values: [T]) throws {
        guard !values.isEmpty else { return }
        let encoder = JSONEncoder()
        var data = Data()
        for value in values {
            data.append(try encoder.encode(value))
            data.append(UInt8(ascii: "\n"))
        }
        if let handle = FileHandle(forWritingAtPath: url.path) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: url)
        }
    }
}
