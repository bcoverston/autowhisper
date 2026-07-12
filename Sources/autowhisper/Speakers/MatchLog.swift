import Foundation

/// One auto-match decision, captured at the moment the attributor chose a label.
/// `threshold`/`marginGate` are recorded because the user can retune them later —
/// calibration must know which gate was in force when each decision was made.
struct MatchDecision: Codable, Sendable {
    var ts: Date
    var session: String
    var assignedLabel: String     // "Ben" (matched) or "Speaker 3" (left unmatched)
    var candidate: String         // best profile considered, matched or not
    var topSim: Float             // cosine similarity to the best profile
    var runnerUpSim: Float?       // second-best, for the margin gate
    var matched: Bool             // true → auto-labeled to the candidate's name
    var threshold: Float
    var marginGate: Float
}

/// A user correction — the ground-truth label for a prior decision. Joins to a
/// `MatchDecision` on (session, label): a "misidentified" says the matched name
/// was wrong (false positive); a "tagged" says a "Speaker N" was really someone
/// (a false negative if that someone was the rejected candidate).
struct MatchCorrection: Codable, Sendable {
    var ts: Date
    var session: String
    var fromLabel: String
    var toLabel: String
    var action: String            // "misidentified" | "tagged" | "reassigned"
}

/// Append-only calibration log. Deliberately does NOT feed back into the live
/// thresholds — that would overfit to recent corrections and drift. It just
/// accumulates data so a threshold can eventually be computed, not guessed.
actor MatchLog {
    static let shared = MatchLog()
    static var directory: URL { SessionStore.root }

    func record(_ decision: MatchDecision) { append(decision, to: "match-decisions.jsonl") }
    func record(_ correction: MatchCorrection) { append(correction, to: "match-corrections.jsonl") }

    /// Labels currently flagged as misidentified in a session, replayed from the
    /// correction log: a `misidentified` flags its new label; a later `tagged` /
    /// `reassigned` of a label clears it. Single source of truth for the badge —
    /// so marks made before the badge existed still surface.
    static func misidentifiedLabels(session: String) -> Set<String> {
        guard let data = try? Data(contentsOf: SessionStore.root.appending(path: "match-corrections.jsonl"))
        else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let corrections = data.split(separator: 0x0a)
            .compactMap { try? decoder.decode(MatchCorrection.self, from: $0) }
            .filter { $0.session == session }
            .sorted { $0.ts < $1.ts }
        var flagged: Set<String> = []
        for c in corrections {
            if c.action == "misidentified" { flagged.insert(c.toLabel) }
            else { flagged.remove(c.fromLabel) }   // tagged / reassigned clears it
        }
        return flagged
    }

    private func append<T: Encodable>(_ value: T, to name: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var data = try? encoder.encode(value) else { return }
        data.append(0x0a)
        let url = SessionStore.root.appending(path: name)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
