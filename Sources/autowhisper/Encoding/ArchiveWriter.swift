@preconcurrency import AVFoundation
import Events
import Foundation

/// Consumes mixed 16 kHz mono PCM and writes rotating AAC-LC chunks.
/// Spike b: AAC-LC 16 kHz mono ~32 kbps ≈ 11.7 MB/h; AVAudioFile finalizes the
/// header on deinit, so rotation drops the writer before announcing the chunk.
actor ArchiveWriter {
    static let chunkSeconds = 300.0

    private let audioDir: URL
    private let hub: EventHub
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                       channels: 1, interleaved: false)!
    private var file: AVAudioFile?
    private var chunkIndex = 0
    private var framesInChunk: Int = 0

    init(sessionDir: URL, hub: EventHub) throws {
        self.audioDir = sessionDir.appending(path: "audio")
        self.hub = hub
        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
    }

    /// Drains the PCM stream to disk; returns when the stream finishes.
    func run(_ stream: AsyncStream<[Float]>) async {
        for await block in stream {
            write(block)
        }
        closeCurrentChunk()
    }

    private func write(_ samples: [Float]) {
        do {
            if file == nil {
                let url = audioDir.appending(path: String(format: "chunk-%03d.m4a", chunkIndex))
                file = try AVAudioFile(forWriting: url, settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 16_000,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 32_000,
                ])
                framesInChunk = 0
            }
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer {
                buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count)
            }
            try file?.write(from: buffer)
            framesInChunk += samples.count
            if Double(framesInChunk) / 16_000 >= Self.chunkSeconds {
                closeCurrentChunk()
            }
        } catch {
            hub.emit(.failure(.diskWriteFailed, detail: error.localizedDescription))
            file = nil
        }
    }

    private func closeCurrentChunk() {
        guard file != nil else { return }
        file = nil   // deinit finalizes the header
        hub.emit(.chunkClosed(index: chunkIndex))
        chunkIndex += 1
    }
}
