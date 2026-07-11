// Spike c: whisper.xcframework hello-world — transcribe the spike-a capture,
// print per-segment confidence, and run standalone Silero VAD segmentation.

@preconcurrency import AVFoundation
import Foundation
import whisper

setvbuf(stdout, nil, _IONBF, 0)

nonisolated func loadPCM16k(_ url: URL) -> [Float] {
    let file = try! AVAudioFile(forReading: url)
    let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    let converter = AVAudioConverter(from: file.processingFormat, to: target)!
    let inBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try! file.read(into: inBuffer)
    let ratio = 16000.0 / file.processingFormat.sampleRate
    let outBuffer = AVAudioPCMBuffer(pcmFormat: target,
                                     frameCapacity: AVAudioFrameCount(Double(file.length) * ratio) + 4096)!
    var fed = false
    var error: NSError?
    converter.convert(to: outBuffer, error: &error) { _, status in
        if fed { status.pointee = .endOfStream; return nil }
        fed = true
        status.pointee = .haveData
        return inBuffer
    }
    precondition(error == nil, "convert failed: \(error!)")
    return Array(UnsafeBufferPointer(start: outBuffer.floatChannelData![0], count: Int(outBuffer.frameLength)))
}

nonisolated func run() {
    let models = ("~/Library/Application Support/autowhisper/models" as NSString).expandingTildeInPath
    let wav = URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/Spikes/out/spike-tap-stream1.wav")
    let samples = loadPCM16k(wav)
    print("samples: \(samples.count) (\(String(format: "%.1f", Double(samples.count) / 16000))s @16k)")

    // --- Transcription with base.en ---
    var cparams = whisper_context_default_params()
    cparams.use_gpu = true
    let t0 = Date()
    guard let ctx = whisper_init_from_file_with_params("\(models)/ggml-base.en.bin", cparams) else {
        fatalError("model load failed")
    }
    print("model loaded in \(String(format: "%.2f", -t0.timeIntervalSinceNow))s")

    var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
    params.print_progress = false
    params.print_realtime = false
    params.token_timestamps = true
    params.no_timestamps = false
    "en".withCString { params.language = $0
        let t1 = Date()
        let rc = samples.withUnsafeBufferPointer { whisper_full(ctx, params, $0.baseAddress, Int32($0.count)) }
        precondition(rc == 0, "whisper_full rc=\(rc)")
        print("transcribed in \(String(format: "%.2f", -t1.timeIntervalSinceNow))s")
    }

    for i in 0..<whisper_full_n_segments(ctx) {
        let text = String(cString: whisper_full_get_segment_text(ctx, i))
        let segT0 = whisper_full_get_segment_t0(ctx, i) * 10   // centiseconds → ms
        let segT1 = whisper_full_get_segment_t1(ctx, i) * 10
        let nTokens = whisper_full_n_tokens(ctx, i)
        var pSum: Float = 0
        for j in 0..<nTokens { pSum += whisper_full_get_token_p(ctx, i, j) }
        let avgP = nTokens > 0 ? pSum / Float(nTokens) : 0
        let noSpeech = whisper_full_get_segment_no_speech_prob(ctx, i)
        print(String(format: "[%6d–%6dms] avg_p=%.3f no_speech=%.3f%@ %@",
                     segT0, segT1, avgP, noSpeech, avgP < 0.6 || noSpeech > 0.5 ? " FLAG" : "", text))
    }
    whisper_free(ctx)

    // --- Standalone VAD ---
    var vcparams = whisper_vad_default_context_params()
    vcparams.use_gpu = false
    guard let vad = whisper_vad_init_from_file_with_params("\(models)/ggml-silero-v6.2.0.bin", vcparams) else {
        fatalError("vad model load failed")
    }
    let vparams = whisper_vad_default_params()
    guard let segs = samples.withUnsafeBufferPointer({
        whisper_vad_segments_from_samples(vad, vparams, $0.baseAddress, Int32($0.count))
    }) else { fatalError("vad segmentation failed") }
    let n = whisper_vad_segments_n_segments(segs)
    print("VAD: \(n) speech segments")
    for i in 0..<n {
        let s0 = whisper_vad_segments_get_segment_t0(segs, i)
        let s1 = whisper_vad_segments_get_segment_t1(segs, i)
        print(String(format: "  vad[%d] %.2fs – %.2fs", i, s0 / 100, s1 / 100))
    }
    whisper_vad_free_segments(segs)
    whisper_vad_free(vad)
    print("spike-whisper OK")
}

run()
