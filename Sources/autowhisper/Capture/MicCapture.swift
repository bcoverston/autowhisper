@preconcurrency import AVFoundation
import Foundation

/// Microphone capture via AVAudioEngine, started and stopped on demand.
/// Deliberately separate from the system-audio tap: engaging the input node is
/// what makes macOS show the orange mic-in-use indicator, and stopping it
/// genuinely releases the hardware (the indicator goes away).
final class MicCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    let ring = AudioRingBuffer(capacity: 48_000 * 8)
    private(set) var sampleRate: Double = 48_000

    var isRunning: Bool { engine.isRunning }

    func start() throws {
        guard !engine.isRunning else { return }
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        sampleRate = format.sampleRate
        let ring = self.ring
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            guard let channel = buffer.floatChannelData?[0] else { return }
            ring.write(channel, count: Int(buffer.frameLength))
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        guard engine.isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}
