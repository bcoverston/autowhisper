import Foundation
import Security

/// Keychain-backed secrets for the correction backends. API keys and AWS
/// credentials are biometric-adjacent secrets — they live here, never in
/// UserDefaults. One generic-password item per key, scoped to this app.
enum Secrets {
    enum Key: String, CaseIterable {
        case anthropicAPIKey = "anthropic-api-key"
        case awsAccessKeyID = "aws-access-key-id"
        case awsSecretAccessKey = "aws-secret-access-key"
        case awsSessionToken = "aws-session-token"
        case openaiAPIKey = "openai-api-key"
        case geminiAPIKey = "gemini-api-key"
    }

    private static let service = "com.coverston.autowhisper.secrets"

    static func load(_ key: Key) -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    /// Store (or clear, when `value` is empty) a secret.
    static func save(_ key: Key, _ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { delete(key); return }
        let data = Data(trimmed.utf8)
        let update = [kSecValueData as String: data] as CFDictionary
        let status = SecItemUpdate(baseQuery(key) as CFDictionary, update)
        if status == errSecItemNotFound {
            var add = baseQuery(key)
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func delete(_ key: Key) {
        SecItemDelete(baseQuery(key) as CFDictionary)
    }

    /// Is a secret present (for showing "set" vs "not set" without revealing it)?
    static func has(_ key: Key) -> Bool {
        let env: [Key: [String]] = [
            .anthropicAPIKey: ["ANTHROPIC_API_KEY"],
            .awsAccessKeyID: ["AWS_ACCESS_KEY_ID"],
            .awsSecretAccessKey: ["AWS_SECRET_ACCESS_KEY"],
            .awsSessionToken: ["AWS_SESSION_TOKEN"],
            .openaiAPIKey: ["OPENAI_API_KEY"],
            .geminiAPIKey: ["GEMINI_API_KEY", "GOOGLE_API_KEY"],
        ]
        let vars = ProcessInfo.processInfo.environment
        if (env[key] ?? []).contains(where: { (vars[$0] ?? "").isEmpty == false }) { return true }
        return load(key) != nil
    }

    private static func baseQuery(_ key: Key) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
    }
}
