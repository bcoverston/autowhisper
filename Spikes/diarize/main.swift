// Spike: FluidAudio diarization + embeddings on a real session chunk.
// Usage: spike-diarize /path/to/chunk.m4a

@preconcurrency import AVFoundation
import FluidAudio
import Foundation

setvbuf(stdout, nil, _IONBF, 0)

nonisolated func loadPCM16k(_ url: URL) -> [Float] {
    let file = try! AVAudioFile(forReading: url)
    let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    let converter = AVAudioConverter(from: file.processingFormat, to: target)!
    let inBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try! file.read(into: inBuffer)
    let outCap = AVAudioFrameCount(Double(file.length) * 16000 / file.processingFormat.sampleRate) + 4096
    let outBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCap)!
    var fed = false
    var err: NSError?
    converter.convert(to: outBuffer, error: &err) { _, s in
        if fed { s.pointee = .endOfStream; return nil }
        fed = true; s.pointee = .haveData; return inBuffer
    }
    return Array(UnsafeBufferPointer(start: outBuffer.floatChannelData![0], count: Int(outBuffer.frameLength)))
}

let paths = Array(CommandLine.arguments.dropFirst())
let samples = paths.flatMap { loadPCM16k(URL(fileURLWithPath: $0)) }
print("loaded \(samples.count) samples from \(paths.count) file(s) (\(String(format: "%.1f", Double(samples.count)/16000))s @16k)")

let models = try await DiarizerModels.downloadIfNeeded()
print("models loaded")
let diarizer = DiarizerManager()
diarizer.initialize(models: models)

let t0 = Date()
let result = try diarizer.performCompleteDiarization(samples)
print(String(format: "diarized in %.2fs", -t0.timeIntervalSinceNow))

print("segments: \(result.segments.count)")
for seg in result.segments.prefix(30) {
    print(String(format: "  %6.2f–%6.2fs  %@", seg.startTimeSeconds, seg.endTimeSeconds, seg.speakerId))
}
let speakers = Set(result.segments.map(\.speakerId))
print("distinct speakers: \(speakers.count) — \(speakers.sorted())")
if let db = result.speakerDatabase {
    for (id, emb) in db {
        let norm = sqrt(emb.reduce(0) { $0 + $1*$1 })
        print("  embedding[\(id)]: dim=\(emb.count) L2norm=\(String(format: "%.3f", norm))")
    }
}
print("spike-diarize OK")

// Cross-session: embeddings for persistence + matching
let list = diarizer.speakerManager.getSpeakerList()
print("speakerManager speakers: \(list.count)")
for sp in list {
    let n = sqrt(sp.currentEmbedding.reduce(0) { $0 + $1*$1 })
    print("  \(sp.id) name=\(sp.name) dim=\(sp.currentEmbedding.count) L2=\(String(format: "%.3f", n)) dur=\(String(format: "%.1f", sp.duration))s")
}
