import Foundation

/// Headless `claude -p` wrapper: payload JSON on stdin, structured output back.
/// Runs with all tools disabled and no session persistence; cwd is the app
/// support dir so no project CLAUDE.md leaks into the prompt.
enum ClaudeCLI {
    static let prompt = """
    Correct this speech-to-text draft transcript. Each segment has a confidence \
    score (avg_p) and a no-speech probability; low-confidence segments may include \
    alt_hypothesis from a more accurate model — use it to arbitrate what was said. \
    Fix mis-transcriptions, casing, and punctuation only; never paraphrase, \
    summarize, or merge segments. Return every segment with its final text.
    """

    static let schema = """
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
        }
        let segments: [Segment]
    }

    private struct Response: Decodable {
        struct Structured: Decodable {
            struct Segment: Decodable {
                let id: Int
                let text: String
            }
            let segments: [Segment]
        }
        let is_error: Bool
        let structured_output: Structured?
        let result: String?
    }

    enum CLIError: Error, LocalizedError {
        case notFound
        case timeout
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notFound: "claude CLI not found"
            case .timeout: "claude timed out"
            case .failed(let detail): detail
            }
        }
    }

    static func locate() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Returns segment id → corrected text.
    static func correct(_ payload: Payload, timeout: Duration = .seconds(180)) async throws -> [Int: String] {
        guard let cli = locate() else { throw CLIError.notFound }
        let stdin = try JSONEncoder().encode(payload)

        let process = Process()
        process.executableURL = cli
        process.arguments = [
            "-p", prompt,
            "--tools", "",
            "--no-session-persistence",
            "--setting-sources", "",
            "--model", "sonnet",
            "--output-format", "json",
            "--json-schema", schema,
        ]
        process.currentDirectoryURL = SessionStore.root
        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe

        let data: Data = try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { cont in
                    process.terminationHandler = { _ in
                        cont.resume(returning: outPipe.fileHandleForReading.readDataToEndOfFile())
                    }
                    do {
                        try process.run()
                        inPipe.fileHandleForWriting.write(stdin)
                        try? inPipe.fileHandleForWriting.close()
                    } catch {
                        process.terminationHandler = nil
                        cont.resume(throwing: error)
                    }
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                process.terminate()
                throw CLIError.timeout
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CLIError.timeout }
            return first
        }

        guard process.terminationStatus == 0 else {
            let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw CLIError.failed("exit \(process.terminationStatus): \(stderr.prefix(200))")
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard !response.is_error, let structured = response.structured_output else {
            throw CLIError.failed("claude error: \((response.result ?? "no structured output").prefix(200))")
        }
        return Dictionary(uniqueKeysWithValues: structured.segments.map { ($0.id, $0.text) })
    }
}
