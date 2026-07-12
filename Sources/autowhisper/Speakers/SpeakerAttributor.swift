import Events
import FluidAudio
import Foundation

/// Per-session speaker attribution. Holds one FluidAudio `DiarizerManager`
/// (its `SpeakerManager` state persists across windows, so a voice keeps the
/// same FluidAudio id all session). Each VAD window is diarized; FluidAudio
/// speaker ids are resolved to display labels — an enrolled profile's name if
/// the embedding matches (margin rule), otherwise a stable "Speaker N".
/// Best-effort: if models can't load, attribution is skipped and speakers stay nil.
actor SpeakerAttributor {
    private let session: String                        // session id, for the calibration log
    private var diarizer: DiarizerManager?
    private var ready = false
    private var failed = false
    private var labelForFluidID: [String: String] = [:]
    private var embeddingForLabel: [String: [Float]] = [:]
    private var nextSpeakerN = 1

    init(session: String) { self.session = session }

    /// Lazily load models and seed enrolled profiles as known speakers.
    private func prepare() async -> Bool {
        if ready { return true }
        if failed { return false }
        do {
            let models = try await DiarizerModels.downloadIfNeeded()
            let manager = DiarizerManager()
            manager.initialize(models: models)
            cachedProfiles = await SpeakerStore.shared.all()
            let known = await SpeakerStore.shared.knownSpeakers()
            if !known.isEmpty {
                manager.speakerManager.initializeKnownSpeakers(known.map {
                    Speaker(id: $0.id, name: $0.name, currentEmbedding: $0.embedding, duration: 0)
                })
                for k in known {
                    labelForFluidID[k.id] = k.name
                    embeddingForLabel[k.name] = k.embedding
                }
            }
            diarizer = manager
            ready = true
            return true
        } catch {
            failed = true
            return false
        }
    }

    /// Diarize one window and return segment id → speaker label for the
    /// DraftSegments that fall within it.
    func attribute(window: [Float], offsetMs: Int, segments: [DraftSegment]) async -> [Int: String] {
        guard await prepare(), let diarizer, !segments.isEmpty else { return [:] }
        guard let result = try? diarizer.performCompleteDiarization(window) else { return [:] }

        // FluidAudio segment times are window-relative seconds → absolute ms.
        let diarized = result.segments.map {
            (t0: offsetMs + Int($0.startTimeSeconds * 1000),
             t1: offsetMs + Int($0.endTimeSeconds * 1000),
             fluidID: $0.speakerId)
        }
        guard !diarized.isEmpty else { return [:] }

        var out: [Int: String] = [:]
        for seg in segments {
            // Pick the diarized span with the most time overlap.
            var bestID: String?
            var bestOverlap = 0
            for d in diarized {
                let overlap = min(seg.t1_ms, d.t1) - max(seg.t0_ms, d.t0)
                if overlap > bestOverlap { bestOverlap = overlap; bestID = d.fluidID }
            }
            if let fluidID = bestID {
                out[seg.id] = resolveLabel(fluidID, diarizer: diarizer)
            }
        }
        return out
    }

    /// Map a FluidAudio speaker id to a persistent display label.
    private func resolveLabel(_ fluidID: String, diarizer: DiarizerManager) -> String {
        if let existing = labelForFluidID[fluidID] { return existing }
        let embedding = diarizer.speakerManager.getSpeaker(for: fluidID)?.currentEmbedding
        var label: String
        if let embedding {
            let d = matchDecision(embedding)
            if let name = d.name {
                label = name
            } else {
                label = "Speaker \(nextSpeakerN)"
                nextSpeakerN += 1
            }
            // Record the decision (only when there was something to match against)
            // so the threshold/margin can be calibrated from real outcomes later.
            if let candidate = d.candidate {
                let entry = MatchDecision(
                    ts: .now, session: session, assignedLabel: label, candidate: candidate,
                    topSim: d.top, runnerUpSim: d.runnerUp, matched: d.name != nil,
                    threshold: SpeakerStore.matchThreshold, marginGate: SpeakerStore.matchMargin)
                Task { await MatchLog.shared.record(entry) }
            }
        } else {
            label = "Speaker \(nextSpeakerN)"
            nextSpeakerN += 1
        }
        labelForFluidID[fluidID] = label
        if let embedding { embeddingForLabel[label] = embedding }
        return label
    }

    // Synchronous match against a snapshot of profiles cached at prepare(),
    // applying the same threshold + margin rule as SpeakerStore.match. Returns
    // the accepted name (or nil) plus the raw scores for the calibration log.
    private var cachedProfiles: [VoiceProfile] = []
    private func matchDecision(_ embedding: [Float])
        -> (name: String?, top: Float, runnerUp: Float?, candidate: String?) {
        guard !cachedProfiles.isEmpty else { return (nil, 0, nil, nil) }
        let scored = cachedProfiles
            .map { (name: $0.displayName, sim: SpeakerStore.cosine($0.centroid, embedding)) }
            .sorted { $0.sim > $1.sim }
        let top = scored[0]
        let runnerUp = scored.count > 1 ? scored[1].sim : nil
        let passesThreshold = top.sim >= SpeakerStore.matchThreshold
        let passesMargin = runnerUp == nil || (top.sim - runnerUp!) >= SpeakerStore.matchMargin
        return ((passesThreshold && passesMargin) ? top.name : nil, top.sim, runnerUp, top.name)
    }

    /// Keep labeling a voice as `to` for the rest of the session — used when the
    /// user tags or corrects it, so new speech doesn't revert to the old label.
    func relabelLive(from: String, to: String) {
        for (fluidID, label) in labelForFluidID where label == from {
            labelForFluidID[fluidID] = to
        }
        if let embedding = embeddingForLabel.removeValue(forKey: from) {
            embeddingForLabel[to] = embedding
        }
    }

    /// The user rejected an auto-match to `name`: relabel that voice to `fresh`
    /// (the same "Speaker N" the past segments were moved to, so it stays
    /// consistent) and drop the wrong profile from the match candidates.
    func reject(name: String, relabelTo fresh: String) {
        cachedProfiles.removeAll { $0.displayName == name }
        relabelLive(from: name, to: fresh)
    }

    /// The embedding last seen for a display label — used when the user tags it.
    func embedding(for label: String) -> [Float]? { embeddingForLabel[label] }

    /// All (label → embedding) seen this session, for the tagging UI.
    func sessionSpeakers() -> [String: [Float]] { embeddingForLabel }
}
