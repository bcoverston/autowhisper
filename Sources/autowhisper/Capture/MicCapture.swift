@preconcurrency import AVFoundation
import Foundation

/// Microphone capture via AVAudioEngine, started and stopped on demand.
/// Deliberately separate from the system-audio tap: engaging the input node is
/// what makes macOS show the orange mic-in-use indicator, and stopping it
/// genuinely releases the hardware (the indicator goes away).
///
/// On AVAudioEngineConfigurationChange (default input switched — e.g. AirPods,
/// whose mic runs at 16/24 kHz) the engine stops itself; we re-query the input
/// format, reinstall the tap, and restart. The owner reads `sampleRate` per
/// conversion, so a rate change is picked up without further signaling.
final class MicCapture: @unchecked Sendable {
    private var engine = AVAudioEngine()
    private var observer: Any?
    private var shouldRun = false
    private let queue = DispatchQueue(label: "autowhisper.capture.mic")

    let ring = AudioRingBuffer(capacity: 48_000 * 8)
    private(set) var sampleRate: Double = 48_000

    var isRunning: Bool { engine.isRunning }

    func start() throws {
        try queue.sync {
            shouldRun = true
            try engageEngine()
            if observer == nil {
                observer = NotificationCenter.default.addObserver(
                    forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
                ) { [weak self] _ in
                    self?.handleConfigurationChange()
                }
            }
        }
    }

    func stop() {
        queue.sync {
            shouldRun = false
            if let observer {
                NotificationCenter.default.removeObserver(observer)
                self.observer = nil
            }
            disengageEngine()
        }
    }

    // MARK: - queue-only

    private func engageEngine() throws {
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

    private func disengageEngine() {
        guard engine.isRunning || engine.inputNode.numberOfInputs > 0 else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func handleConfigurationChange() {
        queue.async { [self] in
            guard shouldRun else { return }
            // The engine has stopped and uninitialized itself; reinstall with
            // the device's fresh format. Fall back to a new engine instance.
            engine.inputNode.removeTap(onBus: 0)
            do {
                try engageEngine()
            } catch {
                engine = AVAudioEngine()
                try? engageEngine()
            }
        }
    }
}
