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
                                  endedAt: meta.endedAt, status: meta.status)
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
