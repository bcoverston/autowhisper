import Foundation

/// Shared Anthropic Messages-API shaping, used by both the direct API and
/// Bedrock backends (Bedrock wraps the same request/response — only transport
/// and auth differ). Structured output is forced via a single tool: the model
/// must call `emit` with input matching our schema, and we return that input.
enum AnthropicMessages {
    static let maxTokens = 8192

    /// Build the request body. `model` is embedded for the direct API; for
    /// Bedrock the model is in the URL, so pass `bedrock: true` (adds
    /// `anthropic_version` instead).
    static func body(prompt: String, schema: String, input: Data,
                     model: String, bedrock: Bool) throws -> Data {
        let schemaObj = try JSONSerialization.jsonObject(with: Data(schema.utf8))
        let content = String(data: input, encoding: .utf8) ?? ""
        var dict: [String: Any] = [
            "max_tokens": maxTokens,
            "system": prompt,
            "tools": [[
                "name": "emit",
                "description": "Return the structured result via this tool.",
                "input_schema": schemaObj,
            ]],
            "tool_choice": ["type": "tool", "name": "emit"],
            "messages": [["role": "user", "content": content]],
        ]
        if bedrock {
            dict["anthropic_version"] = "bedrock-2023-05-31"
        } else {
            dict["model"] = model
        }
        return try JSONSerialization.data(withJSONObject: dict)
    }

    /// Extract the forced tool's `input` object as JSON — the structured result.
    static func toolInput(from response: Data) throws -> Data {
        guard let obj = try JSONSerialization.jsonObject(with: response) as? [String: Any] else {
            throw LLMError.failed("unparseable response")
        }
        if let error = obj["error"] as? [String: Any], let msg = error["message"] as? String {
            throw LLMError.failed(msg)
        }
        guard let content = obj["content"] as? [[String: Any]] else {
            let snippet = String(data: response, encoding: .utf8)?.prefix(200) ?? ""
            throw LLMError.failed("no content in response: \(snippet)")
        }
        for block in content where block["type"] as? String == "tool_use" {
            if let inputObj = block["input"] {
                return try JSONSerialization.data(withJSONObject: inputObj)
            }
        }
        throw LLMError.failed("model did not call the emit tool")
    }
}

/// Anthropic API over HTTPS with an API key (`x-api-key`).
struct AnthropicAPIBackend: LLMBackend {
    let baseURL: String
    let model: String
    let apiKey: String

    func structured(prompt: String, schema: String, input: Data, timeout: Duration) async throws -> Data {
        guard let url = URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1/messages") else {
            throw LLMError.notConfigured("invalid Anthropic base URL")
        }
        var req = URLRequest(url: url, timeoutInterval: timeout.seconds)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try AnthropicMessages.body(prompt: prompt, schema: schema, input: input,
                                                  model: model, bedrock: false)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw LLMError.failed("no HTTP response") }
        guard http.statusCode == 200 else {
            throw LLMError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return try AnthropicMessages.toolInput(from: data)
    }
}
