import Foundation

/// One structured-completion call: instructions + JSON schema + a JSON payload
/// on stdin, returning the structured result as JSON. Every backend (local
/// `claude` CLI, Anthropic API, AWS Bedrock) implements exactly this; the rest
/// of the app is backend-agnostic.
protocol LLMBackend: Sendable {
    func structured(prompt: String, schema: String, input: Data, timeout: Duration) async throws -> Data
}

enum LLMError: Error, LocalizedError {
    case notConfigured(String)
    case notFound
    case timeout
    case http(Int, String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let what): what
        case .notFound: "claude CLI not found"
        case .timeout: "correction backend timed out"
        case .http(let code, let body): "HTTP \(code): \(body.prefix(200))"
        case .failed(let detail): detail
        }
    }
}

/// Backend selection + shared correction/summary contract. The choice and its
/// configuration live in UserDefaults (Settings); secrets live in the Keychain,
/// never in defaults.
enum LLM {
    enum Kind: String, CaseIterable, Identifiable {
        case cli, api, bedrock, openai, gemini
        var id: String { rawValue }
        var label: String {
            switch self {
            case .cli: "Claude CLI (local subscription)"
            case .api: "Anthropic API (API key)"
            case .bedrock: "AWS Bedrock"
            case .openai: "OpenAI (API key)"
            case .gemini: "Google Gemini (API key)"
            }
        }
    }

    static var kind: Kind {
        Kind(rawValue: UserDefaults.standard.string(forKey: "correctionBackend") ?? "cli") ?? .cli
    }

    // Non-secret configuration (defaults chosen to keep the CLI path zero-config).
    private static func s(_ key: String, _ fallback: String) -> String {
        let v = UserDefaults.standard.string(forKey: key) ?? ""
        return v.isEmpty ? fallback : v
    }
    static var cliModel: String { s("llmModelCLI", "sonnet") }
    static var apiModel: String { s("llmModelAPI", "claude-sonnet-5") }
    static var apiBaseURL: String { s("anthropicBaseURL", "https://api.anthropic.com") }
    static var bedrockRegion: String { s("bedrockRegion", "us-east-1") }
    static var bedrockModel: String { s("bedrockModelID", "") }
    static var openaiModel: String { s("openaiModel", "gpt-4o") }
    static var openaiBaseURL: String { s("openaiBaseURL", "https://api.openai.com") }
    static var geminiModel: String { s("geminiModel", "gemini-2.5-flash") }
    static var geminiBaseURL: String { s("geminiBaseURL", "https://generativelanguage.googleapis.com") }

    private static func envKey(_ names: [String]) -> String? {
        let env = ProcessInfo.processInfo.environment
        return names.lazy.compactMap { env[$0] }.first { !$0.isEmpty }
    }

    static func backend() throws -> LLMBackend {
        switch kind {
        case .cli:
            return CLIBackend(model: cliModel)
        case .api:
            let key = Secrets.load(.anthropicAPIKey) ?? envKey(["ANTHROPIC_API_KEY"])
            guard let key, !key.isEmpty else {
                throw LLMError.notConfigured("Anthropic API key not set (Settings → Correction, or ANTHROPIC_API_KEY)")
            }
            return AnthropicAPIBackend(baseURL: apiBaseURL, model: apiModel, apiKey: key)
        case .openai:
            let key = Secrets.load(.openaiAPIKey) ?? envKey(["OPENAI_API_KEY"])
            guard let key, !key.isEmpty else {
                throw LLMError.notConfigured("OpenAI API key not set (Settings → Correction, or OPENAI_API_KEY)")
            }
            return OpenAIBackend(baseURL: openaiBaseURL, model: openaiModel, apiKey: key)
        case .gemini:
            let key = Secrets.load(.geminiAPIKey) ?? envKey(["GEMINI_API_KEY", "GOOGLE_API_KEY"])
            guard let key, !key.isEmpty else {
                throw LLMError.notConfigured("Gemini API key not set (Settings → Correction, or GEMINI_API_KEY)")
            }
            return GeminiBackend(baseURL: geminiBaseURL, model: geminiModel, apiKey: key)
        case .bedrock:
            guard !bedrockModel.isEmpty else {
                throw LLMError.notConfigured("Bedrock model id not set (Settings → Correction)")
            }
            guard let creds = AWSCredentials.resolve() else {
                throw LLMError.notConfigured("no AWS credentials — set them in Settings, or use env / ~/.aws/credentials")
            }
            return BedrockBackend(region: bedrockRegion, model: bedrockModel, creds: creds)
        }
    }

    /// Structured completion via the configured backend. Shared by correction and
    /// summarization; returns the raw structured JSON for the caller to decode.
    static func invoke(prompt: String, schema: String, stdin: Data,
                       timeout: Duration = .seconds(180)) async throws -> Data {
        try await backend().structured(prompt: prompt, schema: schema, input: stdin, timeout: timeout)
    }

    // MARK: - Transcript correction (the same prompt/schema for every backend)

    static let correctionPrompt = """
    Correct this speech-to-text draft transcript. Each segment has a confidence \
    score (avg_p) and a no-speech probability; low-confidence segments may include \
    alt_hypothesis from a more accurate model — use it to arbitrate what was said. \
    Some segments carry a speaker label; use it as dialog context to keep \
    attribution coherent, but do not change speakers. Fix mis-transcriptions, \
    casing, and punctuation only; never paraphrase, summarize, or merge segments. \
    Return every segment with its final text.
    """

    static let correctionSchema = """
    {"type":"object","additionalProperties":false,"required":["segments"],\
    "properties":{"segments":{"type":"array","items":{"type":"object",\
    "additionalProperties":false,"required":["id","text"],"properties":\
    {"id":{"type":"integer"},"text":{"type":"string"}}}}}}
    """

    struct Payload: Encodable {
        struct Segment: Encodable {
            let id: Int
            let t0: Int
            let t1: Int
            let text: String
            let avg_p: Float
            let no_speech_prob: Float
            let alt_hypothesis: String?
            let speaker: String?
        }
        let segments: [Segment]
    }

    private struct CorrectionResult: Decodable {
        struct Segment: Decodable { let id: Int; let text: String }
        let segments: [Segment]
    }

    /// Offline validation of the parts that don't need a live endpoint: SigV4
    /// signing, Gemini schema sanitizing, and the OpenAI/Gemini response parsers.
    static func selfTest() -> Bool {
        guard SigV4.selfTest() else { return false }

        // Gemini's responseSchema must not carry JSON-Schema-only keys.
        guard let gschema = try? GeminiBackend.responseSchema(from: correctionSchema),
              let gdata = try? JSONSerialization.data(withJSONObject: gschema),
              let gstr = String(data: gdata, encoding: .utf8),
              !gstr.contains("additionalProperties"), gstr.contains("segments") else { return false }

        func extracts(_ data: Data, _ f: (Data) throws -> Data) -> Bool {
            guard let out = try? f(data),
                  let obj = try? JSONSerialization.jsonObject(with: out) as? [String: Any],
                  let segs = obj["segments"] as? [[String: Any]] else { return false }
            return segs.first?["text"] as? String == "hi"
        }
        let inner = #"{"segments":[{"id":0,"text":"hi"}]}"#
        let openai = Data(#"{"choices":[{"message":{"content":"{\"segments\":[{\"id\":0,\"text\":\"hi\"}]}"}}]}"#.utf8)
        let gemini = Data(#"{"candidates":[{"content":{"parts":[{"text":"{\"segments\":[{\"id\":0,\"text\":\"hi\"}]}"}]}}]}"#.utf8)
        _ = inner
        return extracts(openai, OpenAIBackend.extractContent)
            && extracts(gemini, GeminiBackend.extractContent)
    }

    /// Returns segment id → corrected text.
    static func correct(_ payload: Payload, timeout: Duration = .seconds(180)) async throws -> [Int: String] {
        let stdin = try JSONEncoder().encode(payload)
        let data = try await invoke(prompt: correctionPrompt, schema: correctionSchema,
                                    stdin: stdin, timeout: timeout)
        let decoded = try JSONDecoder().decode(CorrectionResult.self, from: data)
        return Dictionary(uniqueKeysWithValues: decoded.segments.map { ($0.id, $0.text) })
    }
}

extension Duration {
    /// Whole seconds as a Double — for URLRequest/URLSession timeouts.
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
