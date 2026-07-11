import Foundation
import whisper

/// large-v3-turbo re-transcription of low-confidence spans. Lazy-loaded
/// (~1.6 GB) and unloaded at session end to give the memory back.
actor RecheckTranscriber {
    static let shared = RecheckTranscriber()

    private var ctx: OpaquePointer?

    /// Returns the higher-accuracy hypothesis for a short audio slice,
    /// or nil when the model is unavailable or produced nothing.
    func hypothesis(for slice: [Float]) -> String? {
        guard ModelStore.isPresent(.largeTurbo) else { return nil }
        if ctx == nil {
            WhisperTranscriber.quietLogs()
            var params = whisper_context_default_params()
            params.use_gpu = true
            ctx = whisper_init_from_file_with_params(ModelStore.Model.largeTurbo.url.path, params)
        }
        guard let ctx else { return nil }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_progress = false
        params.print_realtime = false
        let rc = "en".withCString { lang in
            params.language = lang
            return slice.withUnsafeBufferPointer {
                whisper_full(ctx, params, $0.baseAddress, Int32($0.count))
            }
        }
        guard rc == 0 else { return nil }

        let text = (0..<whisper_full_n_segments(ctx))
            .map { String(cString: whisper_full_get_segment_text(ctx, $0)) }
            .joined()
            .trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    func unload() {
        if let ctx { whisper_free(ctx) }
        ctx = nil
    }
}
