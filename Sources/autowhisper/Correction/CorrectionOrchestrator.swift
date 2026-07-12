import Events
import Foundation

/// Correction pass: re-checks flagged segments with the large model (using the
/// in-memory window audio — no chunk decoding), batches drafts every ~2 min,
/// sends them to the configured correction backend, and writes corrected.jsonl
/// + transcript.md. Best-effort by design: failures surface as issues and never
/// block drafting; transcript.md falls back to draft text for uncorrected segments.
actor CorrectionOrchestrator {
    /// How often flagged/uncorrected drafts are batched to the correction backend.
    /// User-tunable (Settings); lower = fresher corrections but more backend calls.
    static var batchSeconds: Double {
        let v = UserDefaults.standard.double(forKey: "correctionIntervalSeconds")
        return v > 0 ? v : 120
    }
    private static let slicePadding = 8_000            // 0.5 s @16k each side

    private let hub: EventHub
    private let dir: URL
    private let recheckLog: JSONLWriter
    private let correctedLog: JSONLWriter

    private var allSegments: [DraftSegment] = []       // session order, for transcript.md
    private var uncorrected: [DraftSegment] = []       // waiting for the next batch
    private var alternates: [Int: String] = [:]        // id → large-model hypothesis
    private var corrected: [Int: String] = [:]
    private var batchTask: Task<Void, Never>?
    private var finishing = false

    struct RecheckEntry: Codable {
        let id: Int
        let alt: String
    }

    struct CorrectedEntry: Codable {
        let id: Int
        let text: String
    }

    init(sessionDir: URL, hub: EventHub) {
        self.hub = hub
        self.dir = sessionDir
        self.recheckLog = JSONLWriter(url: sessionDir.appending(path: "recheck.jsonl"))
        self.correctedLog = JSONLWriter(url: sessionDir.appending(path: "corrected.jsonl"))
    }

    /// Called by the chunker after each window's draft lands. `window` is the
    /// window's 16 kHz PCM, used to slice flagged spans for the re-check.
    func enqueue(_ segments: [DraftSegment], window: [Float], windowOffsetMs: Int) async {
        allSegments.append(contentsOf: segments)
        uncorrected.append(contentsOf: segments)

        let flagged = segments.filter(\.flagged)
        if !flagged.isEmpty {
            var recheckedIDs: [Int] = []
            for segment in flagged {
                let start = max(0, (segment.t0_ms - windowOffsetMs) * 16 - Self.slicePadding)
                let end = min(window.count, (segment.t1_ms - windowOffsetMs) * 16 + Self.slicePadding)
                guard start < end else { continue }
                if let alt = await RecheckTranscriber.shared.hypothesis(for: Array(window[start..<end])) {
                    alternates[segment.id] = alt
                    try? recheckLog.append([RecheckEntry(id: segment.id, alt: alt)])
                }
                recheckedIDs.append(segment.id)
            }
            if !recheckedIDs.isEmpty {
                hub.emit(.rechecked(ids: recheckedIDs))
            }
        }

        if batchTask == nil && !finishing {
            let seconds = Self.batchSeconds
            let nextAt = Date.now.addingTimeInterval(seconds)
            hub.emit(.correction(.batching(nextAt: nextAt)))
            batchTask = Task {
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }
                await self.flushBatch()
            }
        }
    }

    /// Session end: final batch, transcript.md, summary, model unload.
    func finish() async {
        finishing = true
        batchTask?.cancel()
        batchTask = nil
        await flushBatch()
        writeTranscript()
        await summarize()
        await RecheckTranscriber.shared.unload()
        hub.emit(.correction(.done))
    }

    /// One claude call over the corrected transcript → summary.md + session.json.
    /// Best-effort: a failure leaves the session intact (no summary).
    private func summarize() async {
        guard !allSegments.isEmpty else { return }
        let transcript = allSegments.map { seg -> String in
            let who = seg.speaker.map { "\($0): " } ?? ""
            return who + (corrected[seg.id] ?? seg.text)
        }.joined(separator: "\n")
        do {
            let doc = try await Summarizer.summarize(transcript: transcript)
            SessionStore.setSummary(dir: dir, doc)
            var md = ["# \(doc.title)", "", doc.summary, ""]
            if !doc.actionItems.isEmpty {
                md.append("## Action items")
                md.append(contentsOf: doc.actionItems.map { "- [ ] \($0)" })
                md.append("")
            }
            if !doc.topics.isEmpty { md.append("Topics: " + doc.topics.joined(separator: ", ")) }
            try? md.joined(separator: "\n").write(to: dir.appending(path: "summary.md"),
                                                  atomically: true, encoding: .utf8)
            hub.emit(.transcriptWritten(dir.appending(path: "summary.md")))
        } catch {
            // Summary is optional; surface as an issue but don't fail the session.
            hub.emit(.failure(.correctionFailed, detail: "summary: \(error.localizedDescription)"))
        }
    }

    private func flushBatch() async {
        batchTask = nil
        guard !uncorrected.isEmpty else { return }
        let batch = uncorrected
        uncorrected.removeAll()
        hub.emit(.correction(.running))

        let payload = LLM.Payload(segments: batch.map {
            .init(id: $0.id, t0: $0.t0_ms, t1: $0.t1_ms, text: $0.text,
                  avg_p: $0.avg_p, no_speech_prob: $0.no_speech_prob,
                  alt_hypothesis: alternates[$0.id], speaker: $0.speaker)
        })
        do {
            let result = try await LLM.correct(payload)
            corrected.merge(result) { _, new in new }
            try? correctedLog.append(result.map { CorrectedEntry(id: $0.key, text: $0.value) }
                .sorted { $0.id < $1.id })
            hub.emit(.correctionApplied(result))
            hub.emit(.resolved(.correctionFailed))
            hub.emit(.correction(.idle))
        } catch {
            // Put the batch back so the next flush (or finish) retries it once more.
            uncorrected.insert(contentsOf: batch, at: 0)
            hub.emit(.failure(.correctionFailed, detail: error.localizedDescription))
            hub.emit(.correction(.failed(error.localizedDescription)))
        }
    }

    private func writeTranscript() {
        guard !allSegments.isEmpty else { return }
        let hasSpeakers = allSegments.contains { $0.speaker != nil }
        var lines = ["# Session \(dir.lastPathComponent)", ""]
        var lastSpeaker: String?
        for segment in allSegments {
            let s = segment.t0_ms / 1000
            let stamp = String(format: "[%d:%02d]", s / 60, s % 60)
            let text = corrected[segment.id] ?? segment.text
            if hasSpeakers {
                // Dialog form: name header when the speaker changes, then lines.
                let speaker = segment.speaker ?? "Unknown"
                if speaker != lastSpeaker {
                    lines.append("")
                    lines.append("**\(speaker)**")
                    lastSpeaker = speaker
                }
                lines.append("\(stamp) \(text)")
            } else {
                lines.append("\(stamp) \(text)")
            }
        }
        let url = dir.appending(path: "transcript.md")
        do {
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            hub.emit(.transcriptWritten(url))
        } catch {
            hub.emit(.failure(.diskWriteFailed, detail: "transcript: \(error.localizedDescription)"))
        }
    }
}
