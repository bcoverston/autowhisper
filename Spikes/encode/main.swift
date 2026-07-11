// Spike b: can AVAudioFile encode low-bitrate Opus (and AAC-LC fallback) for
// speech archival? Also: what happens to an unfinalized file after kill -9?
//
// Usage: spike-encode              run the encode matrix
//        spike-encode --killtest   write opus + aac forever (parent kills us)

import AVFoundation
import Foundation

setvbuf(stdout, nil, _IONBF, 0)
let outDir = URL(fileURLWithPath: "/Users/bcover/Projects/autowhisper/Spikes/out")

nonisolated func sineBuffer(format: AVAudioFormat, seconds: Double) -> AVAudioPCMBuffer {
    let frames = AVAudioFrameCount(format.sampleRate * seconds)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for ch in 0..<Int(format.channelCount) {
        let data = buffer.floatChannelData![ch]
        for i in 0..<Int(frames) {
            let t = Double(i) / format.sampleRate
            data[i] = Float(0.3 * sin(2 * .pi * 220 * t) * (0.5 + 0.5 * sin(2 * .pi * 3 * t))
                          + 0.1 * sin(2 * .pi * 660 * t))
        }
    }
    return buffer
}

nonisolated func tryEncode(name: String, formatID: AudioFormatID, sampleRate: Double,
                           bitRate: Int?, ext: String) {
    let url = outDir.appending(path: "\(name).\(ext)")
    try? FileManager.default.removeItem(at: url)
    var settings: [String: Any] = [
        AVFormatIDKey: formatID,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 1,
    ]
    if let bitRate { settings[AVEncoderBitRateKey] = bitRate }
    do {
        // Scope the writer so it deinits (finalizing the header) before reread.
        try {
            let file = try AVAudioFile(forWriting: url, settings: settings)
            let buffer = sineBuffer(format: file.processingFormat, seconds: 10)
            try file.write(from: buffer)
        }()
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        do {
            let reread = try AVAudioFile(forReading: url)
            let duration = Double(reread.length) / reread.fileFormat.sampleRate
            let kbps = Double(size) * 8 / 10 / 1000
            print("\(name): OK size=\(size)B (\(String(format: "%.0f", kbps)) kbps, \(String(format: "%.1f", Double(size) * 360 / 1_048_576)) MB/h) reread=\(String(format: "%.2f", duration))s @ \(reread.fileFormat.sampleRate) Hz")
        } catch {
            print("\(name): wrote \(size)B but REREAD FAILED: \(error.localizedDescription)")
        }
    } catch {
        print("\(name): WRITE FAILED: \(error.localizedDescription)")
    }
}

if CommandLine.arguments.contains("--killtest") {
    nonisolated func run() {
        let configs: [(String, AudioFormatID, Double, String)] = [
            ("killtest-opus", kAudioFormatOpus, 24000, "caf"),
            ("killtest-aac", kAudioFormatMPEG4AAC, 16000, "m4a"),
        ]
        var files: [AVAudioFile] = []
        var buffers: [AVAudioPCMBuffer] = []
        for (name, fmt, sr, ext) in configs {
            let url = outDir.appending(path: "\(name).\(ext)")
            try? FileManager.default.removeItem(at: url)
            let settings: [String: Any] = [AVFormatIDKey: fmt, AVSampleRateKey: sr,
                                           AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 24000]
            guard let f = try? AVAudioFile(forWriting: url, settings: settings) else {
                print("\(name): open failed")
                continue
            }
            files.append(f)
            buffers.append(sineBuffer(format: f.processingFormat, seconds: 1))
        }
        print("killtest writing… kill -9 me")
        while true {
            for (i, f) in files.enumerated() { try? f.write(from: buffers[i]) }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
    run()
} else {
    nonisolated func run() {
        for (sr, tag) in [(16000.0, "16k"), (24000.0, "24k"), (48000.0, "48k")] {
            tryEncode(name: "opus-\(tag)", formatID: kAudioFormatOpus, sampleRate: sr, bitRate: 24000, ext: "opus")
            tryEncode(name: "opus-\(tag)-caf", formatID: kAudioFormatOpus, sampleRate: sr, bitRate: 24000, ext: "caf")
        }
        tryEncode(name: "opus-48k-nobr", formatID: kAudioFormatOpus, sampleRate: 48000, bitRate: nil, ext: "caf")
        tryEncode(name: "aac-16k", formatID: kAudioFormatMPEG4AAC, sampleRate: 16000, bitRate: 32000, ext: "m4a")
        tryEncode(name: "aac-24k", formatID: kAudioFormatMPEG4AAC, sampleRate: 24000, bitRate: 24000, ext: "m4a")
    }
    run()
}
