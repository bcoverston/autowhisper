import Foundation

/// Rolling audio retention: deletes chunk files from sessions older than the
/// configured window. Transcripts and JSONL are never touched.
enum RetentionManager {
    static var retentionDays: Int {
        let value = UserDefaults.standard.integer(forKey: "retentionDays")
        return value > 0 ? value : 30
    }

    /// Chunk files past the retention window (sessions still recording excluded).
    static func expiredChunks(asOf now: Date = .now) -> [URL] {
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
        return SessionStore.listSessions()
            .filter { $0.status != .recording && $0.startedAt < cutoff }
            .flatMap { summary in
                SessionStore.artifacts(dir: summary.dir)
                    .filter { $0.kind == .audioChunk }
                    .map(\.url)
            }
    }

    static func purge() {
        for url in expiredChunks() {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Purge at launch and every 12 h thereafter.
    static func schedule() -> Task<Void, Never> {
        Task.detached(priority: .background) {
            while !Task.isCancelled {
                purge()
                try? await Task.sleep(for: .seconds(12 * 3600))
            }
        }
    }
}
