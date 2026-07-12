import Foundation

/// OpenAI Chat Completions with a strict `json_schema` response format. Unlike
/// Anthropic's tool-use, the structured result comes back as a JSON *string* in
/// `choices[0].message.content`, which we validate and return.
struct OpenAIBackend: LLMBackend {
    let baseURL: String
    let model: String
    let apiKey: String

    func structured(prompt: String, schema: String, input: Data, timeout: Duration) async throws -> Data {
        guard let url = URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1/chat/completions") else {
            throw LLMError.notConfigured("invalid OpenAI base URL")
        }
        let schemaObj = try JSONSerialization.jsonObject(with: Data(schema.utf8))
        let content = String(data: input, encoding: .utf8) ?? ""
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": prompt],
                ["role": "user", "content": content],
            ],
            "response_format": [
                "type": "json_schema",
                "json_schema": ["name": "emit", "strict": true, "schema": schemaObj],
            ],
        ]
        var req = URLRequest(url: url, timeoutInterval: timeout.seconds)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw LLMError.failed("no HTTP response") }
        guard http.statusCode == 200 else {
            throw LLMError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return try Self.extractContent(from: data)
    }

    static func extractContent(from data: Data) throws -> Data {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.failed("unparseable OpenAI response")
        }
        if let error = obj["error"] as? [String: Any], let msg = error["message"] as? String {
            throw LLMError.failed(msg)
        }
        guard let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            throw LLMError.failed("no choices in OpenAI response")
        }
        if let refusal = message["refusal"] as? String, !refusal.isEmpty {
            throw LLMError.failed("model refused: \(refusal)")
        }
        guard let content = message["content"] as? String else {
            throw LLMError.failed("no content in OpenAI response")
        }
        // content is a JSON string matching the schema — validate by round-trip.
        let parsed = try JSONSerialization.jsonObject(with: Data(content.utf8))
        return try JSONSerialization.data(withJSONObject: parsed)
    }
}
