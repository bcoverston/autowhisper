@preconcurrency import AVFoundation
import AppKit
import Events
import Foundation
import Synchronization

/// Drains system-tap and mic rings on a dedicated queue, converts to 16 kHz
/// mono, and mixes into one PCM stream. The WALL CLOCK is the mix master:
/// each drain emits exactly the samples elapsed time demands, zero-padding
/// starved sources. (The tap's aggregate is clocked by the output device,
/// which idles when nothing plays — so neither source can be the master.)
final class CaptureEngine: @unchecked Sendable {
    static let targetRate = 16_000.0
    private static let micCarryLimit = 4_800          // 300 ms @16k: resync beyond this

    private let controller = SystemTapController()
    private let mic = MicCapture()
    private let hub: EventHub
    private let drainQueue = DispatchQueue(label: "autowhisper.capture.drain", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private let micEnabled = Atomic<Bool>(false)

    // Drain-queue-only state.
    private var systemConverter: AVAudioConverter?
    private var micConverter: AVAudioConverter?
    private var sysPending: [Float] = []
    private var micPending: [Float] = []
    private var emittedSamples = 0
    private var startedAtNs: UInt64 = 0
    private var levelAccumulator = 0
    private var scratch: [Float] = []
    // --autotest instrumentation
    private let debugLog = CommandLine.arguments.contains("--autotest")
    private var dbgSysIn = 0
    private var dbgMicIn = 0
    private var dbgDrains = 0

    private var sinks: [AsyncStream<[Float]>.Continuation] = []
    private let running = Atomic<Bool>(false)

    // Drain-queue-only rebuild/watchdog state.
    private var rebuildScheduled = false
    private var zeroDeliveredSeconds = 0.0
    private var lastWatchdogRebuildNs: UInt64 = 0
    private var tapIssueRaised = false
    private var everSawSystemAudio = false
    private var sleepObservers: [Any] = []

    init(hub: EventHub) {
        self.hub = hub
    }

    /// Register a consumer of the mixed 16 kHz mono PCM. Call before start().
    func makePCMStream() -> AsyncStream<[Float]> {
        let (stream, cont) = AsyncStream<[Float]>.makeStream()
        sinks.append(cont)
        return stream
    }

    func start(micOn: Bool) throws {
        try controller.start()
        running.store(true, ordering: .relaxed)
        controller.onInvalidated = { [weak self] in self?.scheduleRebuild() }
        installSleepObservers()
        systemConverter = makeConverter(from: controller.sampleRate)
        scratch = [Float](repeating: 0, count: 1 << 16)
        startedAtNs = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)   // sleep-inclusive
        emittedSamples = 0
        setMicEnabled(micOn)

        let timer = DispatchSource.makeTimerSource(queue: drainQueue)
        timer.schedule(deadline: .now() + 0.05, repeating: 0.05)
        timer.setEventHandler { [weak self] in self?.drain() }
        timer.resume()
        self.timer = timer
    }

    /// Starts/stops the microphone hardware. Engaging the AVAudioEngine input
    /// is what drives the macOS orange mic-in-use indicator.
    func setMicEnabled(_ enabled: Bool) {
        if enabled {
            do {
                try mic.start()
                micEnabled.store(true, ordering: .relaxed)
            } catch {
                micEnabled.store(false, ordering: .relaxed)
                hub.emit(.failure(.micPermissionDenied, detail: "mic start: \(error.localizedDescription)"))
            }
        } else {
            micEnabled.store(false, ordering: .relaxed)
            mic.stop()
        }
        hub.emit(.captureState(
            systemDevice: SystemTapController.deviceName(kAudioHardwarePropertyDefaultOutputDevice),
            micDevice: SystemTapController.deviceName(kAudioHardwarePropertyDefaultInputDevice),
            micActive: mic.isRunning))
    }

    /// Stops capture, flushes remaining audio, and finishes the PCM streams.
    func stop() {
        running.store(false, ordering: .relaxed)
        controller.onInvalidated = nil
        removeSleepObservers()
        timer?.cancel()
        timer = nil
        controller.stop()
        mic.stop()
        drainQueue.sync { [self] in
            drain()
            for sink in sinks { sink.finish() }
        }
    }

    private func drain() {
        // Pull whatever each source produced since the last drain into carries.
        let sysCount = scratch.withUnsafeMutableBufferPointer {
            controller.ring.read(into: $0.baseAddress!, max: $0.count)
        }
        var systemRMS: Float = 0
        if sysCount > 0 {
            systemRMS = rms(count: sysCount)
            sysPending.append(contentsOf: convert(Array(scratch[0..<sysCount]),
                                                  using: &systemConverter, inputRate: controller.sampleRate))
            watchdog(deliveredZeros: systemRMS == 0, seconds: Double(sysCount) / controller.sampleRate)
        }
        var micRMS: Float = 0
        if micEnabled.load(ordering: .relaxed) {
            let micCount = scratch.withUnsafeMutableBufferPointer {
                mic.ring.read(into: $0.baseAddress!, max: $0.count)
            }
            if micCount > 0 {
                micRMS = rms(count: micCount)
                micPending.append(contentsOf: convert(Array(scratch[0..<micCount]),
                                                      using: &micConverter, inputRate: mic.sampleRate))
            }
        } else {
            micPending.removeAll(keepingCapacity: true)
        }

        // Emit exactly what the wall clock demands, zero-padding starved sources
        // (an idle output device stops the tap's aggregate entirely).
        let elapsed = Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - startedAtNs) / 1e9
        let target = Int(elapsed * Self.targetRate)
        let n = min(max(0, target - emittedSamples), Int(Self.targetRate))   // ≤1 s catch-up
        if n > 0 {
            var mixed = [Float](repeating: 0, count: n)
            let sysN = min(n, sysPending.count)
            for i in 0..<sysN { mixed[i] = sysPending[i] }
            sysPending.removeFirst(sysN)
            let micN = min(n, micPending.count)
            for i in 0..<micN { mixed[i] = max(-1, min(1, mixed[i] + micPending[i])) }
            micPending.removeFirst(micN)
            emittedSamples += n
            for sink in sinks { sink.yield(mixed) }
        }
        // A source running ahead of the wall clock (or resuming after idle with
        // a backlog) gets trimmed so it can't smear old audio into the present.
        if sysPending.count > Self.micCarryLimit { sysPending.removeFirst(sysPending.count - Self.micCarryLimit / 2) }
        if micPending.count > Self.micCarryLimit { micPending.removeFirst(micPending.count - Self.micCarryLimit / 2) }

        levelAccumulator += 1
        if levelAccumulator % 2 == 0 {
            hub.emit(.levels(mic: min(1, micRMS * 4), system: min(1, systemRMS * 4)))
        }

        if debugLog {
            dbgSysIn += sysCount
            dbgMicIn += micEnabled.load(ordering: .relaxed) ? 1 : 0
            dbgDrains += 1
            if dbgDrains % 20 == 0 {
                let line = String(format: "t=%.1f emitted=%.1fs sysIn=%.1fs@%.0fHz sysPend=%d micPend=%d\n",
                                  elapsed, Double(emittedSamples) / 16000,
                                  Double(dbgSysIn) / controller.sampleRate, controller.sampleRate,
                                  sysPending.count, micPending.count)
                let log = SessionStore.root.appending(path: "logs/engine-debug.log")
                try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(),
                                                         withIntermediateDirectories: true)
                if let h = FileHandle(forWritingAtPath: log.path) {
                    h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
                } else {
                    try? line.data(using: .utf8)!.write(to: log)
                }
            }
        }
    }

    /// Called from HAL listener queues; debounce onto the drain queue.
    private func scheduleRebuild() {
        guard running.load(ordering: .relaxed) else { return }
        drainQueue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, !self.rebuildScheduled else { return }
            self.rebuildScheduled = true
            self.rebuildNow()
            self.rebuildScheduled = false
        }
    }

    /// Drain-queue only. Tears down and recreates tap + aggregate; the ring is
    /// stable across rebuilds, stale carry is dropped so old audio can't smear.
    private func rebuildNow() {
        guard running.load(ordering: .relaxed) else { return }
        sysPending.removeAll(keepingCapacity: true)
        do {
            try controller.rebuild()
            tapIssueRaised = false
            hub.emit(.resolved(.tapInvalidated))
        } catch {
            hub.emit(.failure(.tapInvalidated, detail: "rebuild: \(error.localizedDescription)"))
            tapIssueRaised = true
        }
        hub.emit(.captureState(
            systemDevice: SystemTapController.deviceName(kAudioHardwarePropertyDefaultOutputDevice),
            micDevice: SystemTapController.deviceName(kAudioHardwarePropertyDefaultInputDevice),
            micActive: mic.isRunning))
    }

    /// Silence handling for the always-on tap. Steady-state silence is NORMAL —
    /// it just means nothing is playing on the Mac (you may be capturing the room
    /// via mic) — so it must NOT raise a user banner. We only treat silence as a
    /// fault if real system audio had previously been captured and then dropped
    /// out (a regression, e.g. Bluetooth device sleep), and even then we attempt
    /// one silent rebuild rather than nagging. Device changes are handled by the
    /// property listener; this is only a backstop.
    private func watchdog(deliveredZeros: Bool, seconds: Double) {
        guard deliveredZeros else {
            everSawSystemAudio = true
            zeroDeliveredSeconds = 0
            if tapIssueRaised {                 // clear any stale banner from a prior build
                tapIssueRaised = false
                hub.emit(.resolved(.tapInvalidated))
            }
            return
        }
        guard everSawSystemAudio else { zeroDeliveredSeconds = 0; return }   // never played → not a fault
        zeroDeliveredSeconds += seconds
        guard zeroDeliveredSeconds >= 8 else { return }
        zeroDeliveredSeconds = 0
        let now = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
        if now - lastWatchdogRebuildNs > 600 * 1_000_000_000 {
            lastWatchdogRebuildNs = now
            everSawSystemAudio = false          // require re-confirmation after the recovery attempt
            rebuildNow()                        // silent; only surfaces a banner if the rebuild itself fails
        }
    }

    private func installSleepObservers() {
        let center = NSWorkspace.shared.notificationCenter
        sleepObservers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [weak self] _ in
                guard let self, self.running.load(ordering: .relaxed) else { return }
                self.drainQueue.async { self.controller.stop() }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
                self?.scheduleRebuild()
            },
        ]
    }

    private func removeSleepObservers() {
        for observer in sleepObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        sleepObservers.removeAll()
    }

    private func rms(count: Int) -> Float {
        var sum: Float = 0
        for i in 0..<count { sum += scratch[i] * scratch[i] }
        return (sum / Float(count)).squareRoot()
    }

    private func makeConverter(from rate: Double) -> AVAudioConverter? {
        guard rate != Self.targetRate else { return nil }
        let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                  channels: 1, interleaved: false)!
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.targetRate,
                                   channels: 1, interleaved: false)!
        return AVAudioConverter(from: input, to: target)!
    }

    private func convert(_ input: [Float], using converter: inout AVAudioConverter?,
                         inputRate: Double) -> [Float] {
        if converter == nil || (converter != nil && converter!.inputFormat.sampleRate != inputRate) {
            converter = makeConverter(from: inputRate)
        }
        guard let converter else { return input }   // already 16 kHz

        let inFormat = converter.inputFormat
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
