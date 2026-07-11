import Events
import Foundation
import whisper

/// base.en fast-pass transcription. The whisper context loads once (~7 s with
/// Metal init) and stays resident for the process lifetime.
actor WhisperTranscriber {
    static let shared = WhisperTranscriber()

    static var flagAvgP: Float {
        let value = UserDefaults.standard.double(forKey: "confidenceThreshold")
        return value > 0 ? Float(value) : 0.6
    }
    static let flagNoSpeech: Float = 0.5
    /// --flag-all: test hook forcing every segment through the re-check path.
    private static let flagAll = CommandLine.arguments.contains("--flag-all")

    private var ctx: OpaquePointer?

    static func quietLogs() {
        whisper_log_set({ _, _, _ in }, nil)
    }

    private func context() throws -> OpaquePointer {
        if let ctx { return ctx }
        Self.quietLogs()
        var params = whisper_context_default_params()
        params.use_gpu = true
        guard let loaded = whisper_init_from_file_with_params(ModelStore.Model.baseEN.url.path, params) else {
            throw NSError(domain: "autowhisper", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "base.en model load failed"])
        }
        ctx = loaded
        return loaded
    }

    /// Transcribes one VAD window. `offsetMs` is the window's position in the
    /// session timeline; segment IDs continue from `firstID`.
    func transcribe(window: [Float], offsetMs: Int, firstID: Int) throws -> [DraftSegment] {
        let ctx = try context()
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_progress = false
        params.print_realtime = false
        params.token_timestamps = true
        params.no_timestamps = false

        let rc = "en".withCString { lang in
            params.language = lang
            return window.withUnsafeBufferPointer {
                whisper_full(ctx, params, $0.baseAddress, Int32($0.count))
            }
        }
        guard rc == 0 else {
            throw NSError(domain: "autowhisper", code: Int(rc),
                          userInfo: [NSLocalizedDescriptionKey: "whisper_full rc=\(rc)"])
        }

        var segments: [DraftSegment] = []
        for i in 0..<whisper_full_n_segments(ctx) {
            let text = String(cString: whisper_full_get_segment_text(ctx, i))
                .trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            let nTokens = whisper_full_n_tokens(ctx, i)
            var pSum: Float = 0
            for j in 0..<nTokens { pSum += whisper_full_get_token_p(ctx, i, j) }
            let avgP = nTokens > 0 ? pSum / Float(nTokens) : 0
            let noSpeech = whisper_full_get_segment_no_speech_prob(ctx, i)
            segments.append(DraftSegment(
                id: firstID + segments.count,
                t0_ms: offsetMs + Int(whisper_full_get_segment_t0(ctx, i)) * 10,
                t1_ms: offsetMs + Int(whisper_full_get_segment_t1(ctx, i)) * 10,
                text: text,
                avg_p: avgP,
                no_speech_prob: noSpeech,
                flagged: Self.flagAll || avgP < Self.flagAvgP || noSpeech > Self.flagNoSpeech))
        }
        return segments
    }
}
