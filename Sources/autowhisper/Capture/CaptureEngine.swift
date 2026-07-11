@preconcurrency import AVFoundation
import Events
import Foundation
import Synchronization

/// Drains the tap controller's ring buffers on a dedicated queue, converts every
/// stream to 16 kHz mono float, mixes mic + system into one stream, computes
/// pre-mix RMS levels (throttled to 10 Hz), and vends mixed PCM blocks.
final class CaptureEngine: @unchecked Sendable {
    static let targetRate = 16_000.0

    private let controller = SystemTapController()
    private let hub: EventHub
    private let drainQueue = DispatchQueue(label: "autowhisper.capture.drain", qos: .userInteractive)
    private var timer: DispatchSourceTimer?

    // Drain-queue-only state.
    private var converters: [AVAudioConverter] = []
    private var inFormats: [AVAudioFormat] = []
    private var pending: [[Float]] = []          // converted 16k samples per source: [mic, system]
    private var levelAccumulator = 0
    private var scratch: [Float] = []

    private var sinks: [AsyncStream<[Float]>.Continuation] = []
    private let micMuted = Atomic<Bool>(false)

    init(hub: EventHub) {
        self.hub = hub
    }

    /// Mute keeps the mic stream flowing but zeroes its samples, so the mix
    /// timeline stays aligned and the mic meter drops to zero.
    func setMicMuted(_ muted: Bool) {
        micMuted.store(muted, ordering: .relaxed)
    }

    /// Register a consumer of the mixed 16 kHz mono PCM. Call before start().
    func makePCMStream() -> AsyncStream<[Float]> {
        let (stream, cont) = AsyncStream<[Float]>.makeStream()
        sinks.append(cont)
        return stream
    }

    func start() throws {
        try controller.start()

        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.targetRate,
                                   channels: 1, interleaved: false)!
        inFormats = controller.streams.map {
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: $0.sampleRate,
                          channels: 1, interleaved: false)!
        }
        converters = inFormats.map { AVAudioConverter(from: $0, to: target)! }
        pending = [[], []]
        scratch = [Float](repeating: 0, count: 1 << 16)

        let timer = DispatchSource.makeTimerSource(queue: drainQueue)
        timer.schedule(deadline: .now() + 0.05, repeating: 0.05)
        timer.setEventHandler { [weak self] in self?.drain() }
        timer.resume()
        self.timer = timer
    }

    /// Stops capture, flushes remaining audio, and finishes the PCM stream.
    func stop() {
        timer?.cancel()
        timer = nil
        controller.stop()
        drainQueue.sync { [self] in
            drain()
            for sink in sinks { sink.finish() }
        }
    }

    private func drain() {
        var mixSources: [(samples: [Float], isMic: Bool)] = []
        var micRMS: Float = 0
        var systemRMS: Float = 0

        for (index, stream) in controller.streams.enumerated() {
            let count = scratch.withUnsafeMutableBufferPointer {
                stream.ring.read(into: $0.baseAddress!, max: $0.count)
            }
            guard count > 0 else {
                mixSources.append(([], stream.isMic))
                continue
            }
            if stream.isMic && micMuted.load(ordering: .relaxed) {
                for i in 0..<count { scratch[i] = 0 }
            }
            // Pre-mix RMS on the native-rate data.
            var sum: Float = 0
            for i in 0..<count { sum += scratch[i] * scratch[i] }
            let rms = (sum / Float(count)).squareRoot()
            if stream.isMic { micRMS = max(micRMS, rms) } else { systemRMS = max(systemRMS, rms) }

            mixSources.append((convert(Array(scratch[0..<count]), converterIndex: index), stream.isMic))
        }

        // Accumulate per source (mic = 0, system = 1), summing multiple streams of a kind.
        for (samples, isMic) in mixSources where !samples.isEmpty {
            let slot = isMic ? 0 : 1
            if pending[slot].isEmpty {
                pending[slot] = samples
            } else {
                let overlap = min(pending[slot].count, samples.count)
                for i in 0..<overlap { pending[slot][i] += samples[i] }
                if samples.count > overlap { pending[slot].append(contentsOf: samples[overlap...]) }
            }
        }

        // Mix whatever both sources have; carry remainders.
        let n = min(pending[0].count, pending[1].count)
        if n > 0 {
            var mixed = [Float](repeating: 0, count: n)
            for i in 0..<n { mixed[i] = max(-1, min(1, pending[0][i] + pending[1][i])) }
            pending[0].removeFirst(n)
            pending[1].removeFirst(n)
            for sink in sinks { sink.yield(mixed) }
        }

        // Levels at 10 Hz (every other 50 ms drain).
        levelAccumulator += 1
        if levelAccumulator % 2 == 0 {
            hub.emit(.levels(mic: min(1, micRMS * 4), system: min(1, systemRMS * 4)))
        }
    }

    private func convert(_ input: [Float], converterIndex: Int) -> [Float] {
        let inFormat = inFormats[converterIndex]
        if inFormat.sampleRate == Self.targetRate { return input }
        let converter = converters[converterIndex]

        let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(input.count))!
        inBuffer.frameLength = AVAudioFrameCount(input.count)
        input.withUnsafeBufferPointer {
            inBuffer.floatChannelData![0].update(from: $0.baseAddress!, count: input.count)
        }

        let outCapacity = AVAudioFrameCount(Double(input.count) * Self.targetRate / inFormat.sampleRate) + 64
        let outBuffer = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: outCapacity)!
        var fed = false
        var error: NSError?
        converter.convert(to: outBuffer, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return inBuffer
        }
        guard error == nil else { return [] }
        return Array(UnsafeBufferPointer(start: outBuffer.floatChannelData![0], count: Int(outBuffer.frameLength)))
    }
}
