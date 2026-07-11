import Events
import Foundation

/// Whisper model files: locations, presence checks, first-run download.
enum ModelStore {
    static var dir: URL { SessionStore.root.appending(path: "models") }

    enum Model: String, CaseIterable {
        case baseEN = "ggml-base.en.bin"
        case largeTurbo = "ggml-large-v3-turbo.bin"
        case vad = "ggml-silero-v6.2.0.bin"

        var url: URL { ModelStore.dir.appending(path: rawValue) }

        var remote: URL {
            switch self {
            case .baseEN, .largeTurbo:
                URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(rawValue)")!
            case .vad:
                URL(string: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/\(rawValue)")!
            }
        }
    }

    static func isPresent(_ model: Model) -> Bool {
        FileManager.default.fileExists(atPath: model.url.path)
    }

    /// Downloads the model if missing. Emits modelMissing on failure.
    static func ensure(_ model: Model, hub: EventHub) async -> Bool {
        if isPresent(model) { return true }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let (temp, response) = try await URLSession.shared.download(from: model.remote)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            try? FileManager.default.removeItem(at: model.url)
            try FileManager.default.moveItem(at: temp, to: model.url)
            hub.emit(.resolved(.modelMissing))
            return true
        } catch {
            hub.emit(.failure(.modelMissing, detail: "\(model.rawValue): \(error.localizedDescription)"))
            return false
        }
    }
}
