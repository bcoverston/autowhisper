import Foundation

/// Google Gemini `generateContent` with a `responseSchema`. Two quirks vs the
/// others: the response schema is an OpenAPI subset that rejects `additional
/// Properties`/`$schema` (stripped here), and the structured result is a JSON
/// *string* in `candidates[0].content.parts[0].text`. The API key goes in the
/// `x-goog-api-key` header — never the URL query, so it can't leak into logs.
struct GeminiBackend: LLMBackend {
    let baseURL: String
    let model: String
    let apiKey: String

    func structured(prompt: String, schema: String, input: Data, timeout: Duration) async throws -> Data {
        let base = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/v1beta/models/\(model):generateContent") else {
            throw LLMError.notConfigured("invalid Gemini base URL or model")
        }
        let content = String(data: input, encoding: .utf8) ?? ""
        let body: [String: Any] = [
            "system_instruction": ["parts": [["text": prompt]]],
            "contents": [["role": "user", "parts": [["text": content]]]],
            "generationConfig": [
                "responseMimeType": "application/json",
                "responseSchema": try Self.responseSchema(from: schema),
            ],
        ]
        var req = URLRequest(url: url, timeoutInterval: timeout.seconds)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw LLMError.failed("no HTTP response") }
        guard http.statusCode == 200 else {
            throw LLMError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return try Self.extractContent(from: data)
    }

    /// Gemini's `responseSchema` is an OpenAPI-3 subset — drop JSON-Schema-only
    /// keys it rejects (`additionalProperties`, `$schema`) recursively.
    static func responseSchema(from schema: String) throws -> Any {
        func strip(_ any: Any) -> Any {
            if var dict = any as? [String: Any] {
                dict.removeValue(forKey: "additionalProperties")
                dict.removeValue(forKey: "$schema")
                for (k, v) in dict { dict[k] = strip(v) }
                return dict
            }
            if let arr = any as? [Any] { return arr.map(strip) }
            return any
        }
        return strip(try JSONSerialization.jsonObject(with: Data(schema.utf8)))
    }

    static func extractContent(from data: Data) throws -> Data {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.failed("unparseable Gemini response")
        }
        if let error = obj["error"] as? [String: Any], let msg = error["message"] as? String {
            throw LLMError.failed(msg)
        }
        guard let candidates = obj["candidates"] as? [[String: Any]],
              let contentObj = candidates.first?["content"] as? [String: Any],
              let parts = contentObj["parts"] as? [[String: Any]],
              let text = parts.first?["text"] as? String else {
            let snippet = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            throw LLMError.failed("no content in Gemini response: \(snippet)")
        }
        let parsed = try JSONSerialization.jsonObject(with: Data(text.utf8))
        return try JSONSerialization.data(withJSONObject: parsed)
    }
}
