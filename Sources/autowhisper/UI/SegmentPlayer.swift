@preconcurrency import AVFoundation
import Events
import Foundation
import Observation

/// Plays a single segment's audio by seeking into the archived chunk that
/// contains it. Chunk boundaries align with the session timeline (5-min chunks),
/// so segment t0_ms maps to chunk `t0_ms / 300_000` at offset `t0_ms % 300_000`.
@MainActor @Observable
final class SegmentPlayer {
    private static let chunkMs = 300_000

    private var player: AVAudioPlayer?
    private var stopTask: Task<Void, Never>?
    var playingID: Int?

    func toggle(_ segment: DraftSegment, sessionDir: URL) {
        if playingID == segment.id { stop(); return }
        stop()

        let chunkIndex = segment.t0_ms / Self.chunkMs
        let url = sessionDir.appending(path: String(format: "audio/chunk-%03d.m4a", chunkIndex))
        guard FileManager.default.fileExists(atPath: url.path),
              let p = try? AVAudioPlayer(contentsOf: url) else { return }

        let start = Double(segment.t0_ms % Self.chunkMs) / 1000
        let duration = Double(segment.t1_ms - segment.t0_ms) / 1000 + 0.3   // small tail pad
        p.prepareToPlay()
        p.currentTime = min(start, max(0, p.duration - 0.05))
        p.play()
        player = p
        playingID = segment.id
        stopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            self?.stop()
        }
    }

    func stop() {
        stopTask?.cancel()
        stopTask = nil
        player?.stop()
        player = nil
        playingID = nil
    }
}
