import Foundation

/// A persistent, named voice identity. The centroid is a 256-d L2-normalized
/// running mean of the speaker's segment embeddings; enrolling more speech
/// strengthens it. Stored on-device only (biometric-adjacent — never synced).
struct VoiceProfile: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    var displayName: String
    var centroid: [Float]
    var sampleCount: Int
    var colorIndex: Int
    var createdAt: Date
    var updatedAt: Date
    var misidentifiedCount: Int?   // times the user flagged an auto-match as wrong (nil in older profiles)

    var misIDs: Int { misidentifiedCount ?? 0 }
}

/// On-disk store of enrolled voice profiles + cross-session matching.
/// JSON, not a database — brute-force cosine over tens–hundreds of profiles is
/// instant and matches the codebase's file-per-store pattern.
actor SpeakerStore {
    static let shared = SpeakerStore()

    /// Cross-session match gate (from the design/proposal): accept a profile
    /// only if cosine similarity ≥ matchThreshold AND it beats the runner-up by
    /// ≥ matchMargin — the margin is what stops two similar voices merging.
    /// Default biases toward leaving a voice as "Speaker N" over mislabeling it:
    /// an unlabeled speaker is a one-click tag, a wrong label must be noticed and
    /// corrected. Kept strict until real-world data lets us dial in a fixed value.
    static let defaultMatchThreshold: Float = 0.65
    static var matchThreshold: Float {
        let v = UserDefaults.standard.double(forKey: "sameVoiceThreshold")
        return v > 0 ? Float(v) : defaultMatchThreshold
    }
    /// The best profile must beat the runner-up by at least this cosine margin —
    /// the guard against merging two similar voices. User-tunable (Settings).
    static let defaultMatchMargin: Float = 0.06
    static var matchMargin: Float {
        let v = UserDefaults.standard.double(forKey: "voiceMatchMargin")
        return v > 0 ? Float(v) : defaultMatchMargin
    }

    private let url = SessionStore.root.appending(path: "speakers.json")
    private var profiles: [VoiceProfile] = []
    private var loaded = false

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([VoiceProfile].self, from: data) {
            profiles = decoded
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        try? encoder.encode(profiles).write(to: url)
    }

    func all() -> [VoiceProfile] {
        loadIfNeeded()
        return profiles
    }

    /// Enrolled profiles as FluidAudio "known speakers" seed data (id + centroid).
    func knownSpeakers() -> [(id: String, name: String, embedding: [Float])] {
        loadIfNeeded()
        return profiles.map { ($0.id.uuidString, $0.displayName, $0.centroid) }
    }

    /// Best cross-session match for an embedding, honoring the margin rule.
    /// Returns the matched profile's display name, or nil to leave it "Speaker N".
    func match(_ embedding: [Float]) -> VoiceProfile? {
        loadIfNeeded()
        guard !profiles.isEmpty else { return nil }
        let scored = profiles
            .map { (profile: $0, sim: SpeakerStore.cosine($0.centroid, embedding)) }
            .sorted { $0.sim > $1.sim }
        let best = scored[0]
        guard best.sim >= Self.matchThreshold else { return nil }
        if scored.count > 1, best.sim - scored[1].sim < Self.matchMargin { return nil }
        return best.profile
    }

    /// Create or update a named profile from a speaker's embedding (running mean).
    @discardableResult
    func enroll(name: String, embedding: [Float], addingSamples: Int = 1) -> VoiceProfile {
        loadIfNeeded()
        if let idx = profiles.firstIndex(where: { $0.displayName.caseInsensitiveCompare(name) == .orderedSame }) {
            var p = profiles[idx]
            let n = Float(p.sampleCount)
            var merged = zip(p.centroid, embedding).map { $0 * n + $1 }
            SpeakerStore.normalize(&merged)
            p.centroid = merged
            p.sampleCount += addingSamples
            p.updatedAt = .now
            profiles[idx] = p
            save()
            return p
        }
        var e = embedding
        SpeakerStore.normalize(&e)
        let p = VoiceProfile(id: UUID(), displayName: name, centroid: e, sampleCount: addingSamples,
                             colorIndex: profiles.count, createdAt: .now, updatedAt: .now,
                             misidentifiedCount: 0)
        profiles.append(p)
        save()
        return p
    }

    /// Record that the cross-session matcher wrongly labeled someone with this
    /// profile's name — the accuracy signal for deciding whether to tighten the
    /// threshold. No-ops if the name isn't enrolled (e.g. a raw "Speaker N").
    func markMisidentified(name: String) {
        loadIfNeeded()
        guard let idx = profiles.firstIndex(where: {
            $0.displayName.caseInsensitiveCompare(name) == .orderedSame
        }) else { return }
        profiles[idx].misidentifiedCount = profiles[idx].misIDs + 1
        profiles[idx].updatedAt = .now
        save()
    }

    func forget(_ id: UUID) {
        loadIfNeeded()
        profiles.removeAll { $0.id == id }
        save()
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        let denom = (na.squareRoot() * nb.squareRoot())
        return denom > 0 ? dot / denom : 0
    }

    static func normalize(_ v: inout [Float]) {
        let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0 else { return }
        for i in 0..<v.count { v[i] /= norm }
    }
}
