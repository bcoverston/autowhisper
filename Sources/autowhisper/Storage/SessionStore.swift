import Events
import Foundation

/// Session directories, session.json lifecycle, and artifact listing.
/// All functions are synchronous file I/O — call from off the main actor.
enum SessionStore {
    static let root = URL(fileURLWithPath: ("~/Library/Application Support/autowhisper" as NSString).expandingTildeInPath)
    static var sessionsDir: URL { root.appending(path: "sessions") }

    struct Meta: Codable {
        var id: String
        var startedAt: Date
        var endedAt: Date?
        var status: SessionStatus
        var encoder: String
        var title: String?        // user-set
        var summary: SessionSummaryDoc?
    }

    static func setSummary(dir: URL, _ doc: SessionSummaryDoc) {
        guard var meta = readMeta(dir: dir) else { return }
        meta.summary = doc
        try? writeMeta(meta, dir: dir)
    }

    static func loadSummary(dir: URL) -> SessionSummaryDoc? {
        readMeta(dir: dir)?.summary
    }

    static func createSession(at date: Date = .now) throws -> (id: String, dir: URL) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withDashSeparatorInDate]
        let id = formatter.string(from: date).replacingOccurrences(of: ":", with: "-")
        let dir = sessionsDir.appending(path: id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try writeMeta(Meta(id: id, startedAt: date, endedAt: nil, status: .recording,
                           encoder: "aac-lc 16kHz mono 32kbps"), dir: dir)
        return (id, dir)
    }

    static func finalize(dir: URL, status: SessionStatus, endedAt: Date = .now) {
        guard var meta = readMeta(dir: dir) else { return }
        meta.status = status
        meta.endedAt = endedAt
        try? writeMeta(meta, dir: dir)
    }

    /// Launch-time sweep: any session still marked `recording` was orphaned by
    /// a crash — mark it interrupted so the UI never shows a phantom recording.
    static func sweepInterrupted() {
        for summary in listSessions() where summary.status == .recording {
            finalize(dir: summary.dir, status: .interrupted, endedAt: summary.startedAt)
        }
    }

    static func listSessions() -> [SessionSummary] {
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: sessionsDir, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { dir -> SessionSummary? in
            guard let meta = readMeta(dir: dir) else { return nil }
            return SessionSummary(id: meta.id, dir: dir, startedAt: meta.startedAt,
                                  endedAt: meta.endedAt, status: meta.status,
                                  title: meta.title ?? meta.summary?.title)
        }
        .sorted { $0.startedAt > $1.startedAt }
    }

    static func artifacts(dir: URL) -> [Artifact] {
        var result: [Artifact] = []
        let fm = FileManager.default
        for (name, kind) in [("transcript.md", Artifact.Kind.transcript),
                             ("draft.jsonl", .jsonl), ("recheck.jsonl", .jsonl),
                             ("corrected.jsonl", .jsonl)] {
            let url = dir.appending(path: name)
            if fm.fileExists(atPath: url.path) {
                result.append(Artifact(name: name, url: url, kind: kind))
            }
        }
        let chunks = ((try? fm.contentsOfDirectory(at: dir.appending(path: "audio"),
                                                   includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "m4a" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        result.append(contentsOf: chunks.map { Artifact(name: $0.lastPathComponent, url: $0, kind: .audioChunk) })
        return result
    }

    static func setTitle(dir: URL, title: String) {
        guard var meta = readMeta(dir: dir) else { return }
        meta.title = title.isEmpty ? nil : title
        try? writeMeta(meta, dir: dir)
    }

    /// Permanently removes a session directory (audio + transcripts).
    static func delete(dir: URL) {
        guard dir.path.hasPrefix(sessionsDir.path) else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    static func loadCorrections(dir: URL) -> [Int: String] {
        struct Entry: Decodable { let id: Int; let text: String }
        guard let data = try? Data(contentsOf: dir.appending(path: "corrected.jsonl")) else { return [:] }
        let decoder = JSONDecoder()
        var result: [Int: String] = [:]
        for line in data.split(separator: UInt8(ascii: "\n")) {
            if let e = try? decoder.decode(Entry.self, from: line) { result[e.id] = e.text }
        }
        return result
    }

    static func loadRecheckedIDs(dir: URL) -> Set<Int> {
        struct Entry: Decodable { let id: Int }
        guard let data = try? Data(contentsOf: dir.appending(path: "recheck.jsonl")) else { return [] }
        let decoder = JSONDecoder()
        return Set(data.split(separator: UInt8(ascii: "\n")).compactMap {
            (try? decoder.decode(Entry.self, from: $0))?.id
        })
    }

    /// IDs of sessions whose transcript or draft contains `query` (case-insensitive).
    static func sessionsMatching(_ query: String) -> Set<String> {
        let needle = query.lowercased()
        guard !needle.isEmpty else { return [] }
        var hits: Set<String> = []
        for summary in listSessions() {
            for name in ["transcript.md", "draft.jsonl"] {
                if let text = try? String(contentsOf: summary.dir.appending(path: name), encoding: .utf8),
                   text.lowercased().contains(needle) {
                    hits.insert(summary.id)
                    break
                }
            }
        }
        return hits
    }

    static func loadSpeakerEmbeddings(dir: URL) -> [String: [Float]] {
        guard let data = try? Data(contentsOf: dir.appending(path: "speaker-embeddings.json")),
              let map = try? JSONDecoder().decode([String: [Float]].self, from: data) else { return [:] }
        return map
    }

    /// Rewrite draft.jsonl replacing one speaker label with another (after tagging).
    static func relabelSpeaker(dir: URL, from: String, to: String) {
        let url = dir.appending(path: "draft.jsonl")
        var segments = loadDraftSegments(dir: dir)
        guard segments.contains(where: { $0.speaker == from }) else { return }
        segments = segments.map { var s = $0; if s.speaker == from { s.speaker = to }; return s }
        let encoder = JSONEncoder()
        let lines = segments.compactMap { try? encoder.encode($0) }
        var data = Data()
        for line in lines { data.append(line); data.append(UInt8(ascii: "\n")) }
        try? data.write(to: url)
        // Keep the embeddings file's key in sync so re-tagging works.
        var embeddings = loadSpeakerEmbeddings(dir: dir)
        if let e = embeddings.removeValue(forKey: from) {
            embeddings[to] = e
            try? JSONEncoder().encode(embeddings).write(to: dir.appending(path: "speaker-embeddings.json"))
        }
    }

    /// JSONL reader tolerating a trailing partial line (power loss can truncate).
    static func loadDraftSegments(dir: URL) -> [DraftSegment] {
        guard let data = try? Data(contentsOf: dir.appending(path: "draft.jsonl")) else { return [] }
        let decoder = JSONDecoder()
        return data.split(separator: UInt8(ascii: "\n")).compactMap {
            try? decoder.decode(DraftSegment.self, from: $0)
        }
    }

    /// True when the session recorded audio that retention has since purged.
    static func audioExpired(dir: URL) -> Bool {
        let audio = dir.appending(path: "audio")
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: audio.path)) ?? []
        return FileManager.default.fileExists(atPath: audio.path) && contents.isEmpty
            && readMeta(dir: dir)?.status != .recording
    }

    private static func readMeta(dir: URL) -> Meta? {
        guard let data = try? Data(contentsOf: dir.appending(path: "session.json")) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Meta.self, from: data)
    }

    private static func writeMeta(_ meta: Meta, dir: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(meta).write(to: dir.appending(path: "session.json"))
    }
}
