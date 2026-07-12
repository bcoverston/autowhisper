import CryptoKit
import Foundation

/// AWS credentials, resolved from (in order) the app Keychain, the environment,
/// then the default profile in ~/.aws/credentials — so a login-launched GUI app
/// works without a shell env, and secrets need not be stored in the app.
struct AWSCredentials: Sendable {
    let accessKeyID: String
    let secretAccessKey: String
    let sessionToken: String?

    static func resolve() -> AWSCredentials? {
        if let id = Secrets.load(.awsAccessKeyID), let secret = Secrets.load(.awsSecretAccessKey),
           !id.isEmpty, !secret.isEmpty {
            return AWSCredentials(accessKeyID: id, secretAccessKey: secret,
                                  sessionToken: Secrets.load(.awsSessionToken))
        }
        let env = ProcessInfo.processInfo.environment
        if let id = env["AWS_ACCESS_KEY_ID"], let secret = env["AWS_SECRET_ACCESS_KEY"] {
            return AWSCredentials(accessKeyID: id, secretAccessKey: secret,
                                  sessionToken: env["AWS_SESSION_TOKEN"])
        }
        return fromCredentialsFile()
    }

    /// Minimal ~/.aws/credentials [default] parser (aws_access_key_id / secret /
    /// optional session token). Enough for the common local-dev case.
    private static func fromCredentialsFile() -> AWSCredentials? {
        let path = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".aws/credentials")
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return nil }
        var section = "", kv: [String: [String: String]] = [:]
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast())
            } else if let eq = line.firstIndex(of: "="), !section.isEmpty {
                let k = line[..<eq].trimmingCharacters(in: .whitespaces)
                let v = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                kv[section, default: [:]][k] = v
            }
        }
        guard let d = kv["default"], let id = d["aws_access_key_id"],
              let secret = d["aws_secret_access_key"] else { return nil }
        return AWSCredentials(accessKeyID: id, secretAccessKey: secret,
                              sessionToken: d["aws_session_token"])
    }
}

/// AWS Signature Version 4 for a single request. Kept minimal (no SDK): enough
/// for Bedrock Runtime InvokeModel. Verified against AWS's published test vector
/// in `selfTest()`.
enum SigV4 {
    /// Returns the headers to add (Authorization, X-Amz-Date, and the security
    /// token when present) for a signed request.
    static func sign(method: String, host: String, canonicalURI: String, query: String,
                     body: Data, service: String, region: String,
                     creds: AWSCredentials, now: Date) -> [String: String] {
        let amzDate = iso8601(now)               // 20150830T123600Z
        let dateStamp = String(amzDate.prefix(8)) // 20150830

        var headers = ["host": host, "x-amz-date": amzDate]
        if let token = creds.sessionToken, !token.isEmpty { headers["x-amz-security-token"] = token }

        let signed = headers.keys.map { $0.lowercased() }.sorted()
        let canonicalHeaders = signed.map { "\($0):\(headers[$0]!)\n" }.joined()
        let signedHeaders = signed.joined(separator: ";")
        let bodyHash = sha256hex(body)

        let canonicalRequest = [
            method, canonicalURI, query, canonicalHeaders, signedHeaders, bodyHash,
        ].joined(separator: "\n")

        let scope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256", amzDate, scope, sha256hex(Data(canonicalRequest.utf8)),
        ].joined(separator: "\n")

        let signingKey = deriveKey(secret: creds.secretAccessKey, dateStamp: dateStamp,
                                   region: region, service: service)
        let signature = hmac(key: signingKey, msg: Data(stringToSign.utf8)).hexString

        var out = headers
        out["Authorization"] = "AWS4-HMAC-SHA256 Credential=\(creds.accessKeyID)/\(scope), "
            + "SignedHeaders=\(signedHeaders), Signature=\(signature)"
        return out
    }

    private static func deriveKey(secret: String, dateStamp: String, region: String, service: String) -> Data {
        let kDate = hmac(key: Data("AWS4\(secret)".utf8), msg: Data(dateStamp.utf8))
        let kRegion = hmac(key: kDate, msg: Data(region.utf8))
        let kService = hmac(key: kRegion, msg: Data(service.utf8))
        return hmac(key: kService, msg: Data("aws4_request".utf8))
    }

    private static func hmac(key: Data, msg: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: msg, using: SymmetricKey(data: key)))
    }
    private static func sha256hex(_ data: Data) -> String { Data(SHA256.hash(data: data)).hexString }

    private static func iso8601(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02dT%02d%02d%02dZ",
                      c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
    }

    /// AWS "get-vanilla" SigV4 test vector — validates the signing math with no
    /// network. Returns true iff the derived signature matches the documented one.
    static func selfTest() -> Bool {
        let creds = AWSCredentials(accessKeyID: "AKIDEXAMPLE",
                                   secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
                                   sessionToken: nil)
        // 2015-08-30 12:36:00 UTC
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let date = cal.date(from: DateComponents(year: 2015, month: 8, day: 30,
                                                 hour: 12, minute: 36, second: 0))!
        let headers = sign(method: "GET", host: "example.amazonaws.com", canonicalURI: "/",
                           query: "", body: Data(), service: "service", region: "us-east-1",
                           creds: creds, now: date)
        let expected = "5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31"
        return headers["Authorization"]?.contains("Signature=\(expected)") ?? false
    }
}

private extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

/// AWS Bedrock Runtime InvokeModel for Claude — same Anthropic request/response
/// as the direct API, wrapped in SigV4.
struct BedrockBackend: LLMBackend {
    let region: String
    let model: String
    let creds: AWSCredentials

    func structured(prompt: String, schema: String, input: Data, timeout: Duration) async throws -> Data {
        let host = "bedrock-runtime.\(region).amazonaws.com"
        // Model ids contain ':' (e.g. …-v1:0); percent-encode the path segment so
        // the URL and the SigV4 canonical URI agree.
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let encodedModel = model.addingPercentEncoding(withAllowedCharacters: allowed) ?? model
        let path = "/model/\(encodedModel)/invoke"
        guard let url = URL(string: "https://\(host)\(path)") else {
            throw LLMError.notConfigured("invalid Bedrock model id")
        }
        let body = try AnthropicMessages.body(prompt: prompt, schema: schema, input: input,
                                              model: model, bedrock: true)
        var req = URLRequest(url: url, timeoutInterval: timeout.seconds)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("application/json", forHTTPHeaderField: "accept")
        req.httpBody = body
        let signed = SigV4.sign(method: "POST", host: host, canonicalURI: path, query: "",
                                body: body, service: "bedrock", region: region,
                                creds: creds, now: Date())
        for (k, v) in signed { req.setValue(v, forHTTPHeaderField: k) }

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw LLMError.failed("no HTTP response") }
        guard http.statusCode == 200 else {
            throw LLMError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return try AnthropicMessages.toolInput(from: data)
    }
}
