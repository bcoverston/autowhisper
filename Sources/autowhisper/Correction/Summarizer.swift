import Foundation

/// A session's Claude-generated summary. Persisted in session.json and summary.md.
struct SessionSummaryDoc: Codable, Sendable, Equatable {
    var title: String
    var summary: String
    var actionItems: [String]
    var topics: [String]
}

/// Post-session intelligence: one `claude -p` call turning the corrected
/// transcript into a title, summary, action items, and topics. Best-effort —
/// a failure leaves the session intact with no summary.
enum Summarizer {
    private static let prompt = """
    You are given a meeting/conversation transcript (optionally with speaker \
    labels). Produce a concise title (≤ 8 words), a 2–4 sentence summary, a list \
    of concrete action items (empty if none), and up to 5 topic tags. Base \
    everything only on the transcript; do not invent details.
    """

    private static let schema = """
    {"type":"object","additionalProperties":false,\
    "required":["title","summary","action_items","topics"],"properties":{\
    "title":{"type":"string"},"summary":{"type":"string"},\
    "action_items":{"type":"array","items":{"type":"string"}},\
    "topics":{"type":"array","items":{"type":"string"}}}}
    """

    private struct Raw: Decodable {
        let title: String
        let summary: String
        let action_items: [String]
        let topics: [String]
    }

    static func summarize(transcript: String) async throws -> SessionSummaryDoc {
        let stdin = try JSONEncoder().encode(["transcript": transcript])
        let data = try await ClaudeCLI.invoke(prompt: prompt, schema: schema, stdin: stdin, timeout: .seconds(120))
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        return SessionSummaryDoc(title: raw.title, summary: raw.summary,
                                 actionItems: raw.action_items, topics: raw.topics)
    }

    /// Digest of a day's session summaries.
    static func digest(of summaries: [String]) async throws -> String {
        let joined = summaries.enumerated().map { "## Session \($0.offset + 1)\n\($0.element)" }.joined(separator: "\n\n")
        let stdin = try JSONEncoder().encode(["summaries": joined])
        let schema = """
        {"type":"object","additionalProperties":false,"required":["digest"],\
        "properties":{"digest":{"type":"string"}}}
        """
        let prompt = """
        Combine these per-session summaries from one day into a single markdown \
        digest: a short overview, then the notable threads and any outstanding \
        action items across sessions. Base it only on the provided summaries.
        """
        let data = try await ClaudeCLI.invoke(prompt: prompt, schema: schema, stdin: stdin, timeout: .seconds(120))
        struct D: Decodable { let digest: String }
        return try JSONDecoder().decode(D.self, from: data).digest
    }
}
