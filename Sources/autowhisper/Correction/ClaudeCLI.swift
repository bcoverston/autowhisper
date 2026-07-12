import Foundation

/// Backend that shells out to a local `claude -p` (the user's subscription).
/// Payload JSON on stdin, structured output back. Runs with all tools disabled
/// and no session persistence; cwd is the app-support dir so no project
/// CLAUDE.md leaks into the prompt.
struct CLIBackend: LLMBackend {
    let model: String

    static func locate() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    func structured(prompt: String, schema: String, input: Data, timeout: Duration) async throws -> Data {
        guard let cli = Self.locate() else { throw LLMError.notFound }

        let process = Process()
        process.executableURL = cli
        process.arguments = [
            "-p", prompt,
            "--tools", "",
            "--no-session-persistence",
            "--setting-sources", "",
            "--model", model,
            "--output-format", "json",
            "--json-schema", schema,
        ]
        process.currentDirectoryURL = SessionStore.root
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
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
                        inPipe.fileHandleForWriting.write(input)
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
                throw LLMError.timeout
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw LLMError.timeout }
            return first
        }

        guard process.terminationStatus == 0 else {
            let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw LLMError.failed("claude exit \(process.terminationStatus): \(stderr.prefix(200))")
        }
        struct Envelope: Decodable { let is_error: Bool; let structured_output: JSONAny?; let result: String? }
        let env = try JSONDecoder().decode(Envelope.self, from: data)
        guard !env.is_error, let structured = env.structured_output else {
            throw LLMError.failed("claude error: \((env.result ?? "no structured output").prefix(200))")
        }
        return try JSONEncoder().encode(structured)
    }
}

/// Minimal type-erased JSON so `structured_output` can be re-encoded and decoded
/// into whichever concrete shape the caller expects.
struct JSONAny: Codable {
    let value: Any
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode([String: JSONAny].self) { value = v.mapValues(\.value) }
        else if let v = try? c.decode([JSONAny].self) { value = v.map(\.value) }
        else if let v = try? c.decode(Bool.self) { value = v }
        else if let v = try? c.decode(Int.self) { value = v }
        else if let v = try? c.decode(Double.self) { value = v }
        else if let v = try? c.decode(String.self) { value = v }
        else { value = NSNull() }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case let v as [String: Any]: try c.encode(v.mapValues(JSONAny.init))
        case let v as [Any]: try c.encode(v.map(JSONAny.init))
        case let v as Bool: try c.encode(v)
        case let v as Int: try c.encode(v)
        case let v as Double: try c.encode(v)
        case let v as String: try c.encode(v)
        default: try c.encodeNil()
        }
    }
    init(_ any: Any) { value = any }
}
