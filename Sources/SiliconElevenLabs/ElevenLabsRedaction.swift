import Foundation

/// Keeps anything key-shaped out of every string this module produces.
public enum ElevenLabsRedaction {
    public static let placeholder = "‹redacted›"

    /// `text` with the given key, and anything shaped like an ElevenLabs key (`sk_…`, or a run
    /// of 32 or more hex digits), replaced by a placeholder.
    public static func redact(_ text: String, knownKey: String? = nil) -> String {
        var result = text
        if let knownKey, knownKey.count >= 8 {
            result = result.replacingOccurrences(of: knownKey, with: placeholder)
        }
        for pattern in patterns {
            result = pattern.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result),
                withTemplate: placeholder
            )
        }
        return result
    }

    /// A credential-returning operation's answer with its secret fields replaced — what MCP and
    /// control output carry unless the owner's switch lets agents see them. Other operations'
    /// answers pass through, with only key-shaped strings redacted.
    public static func redactCredentials(
        in value: JSONValue, for operation: ElevenLabsOperation
    ) -> JSONValue {
        guard operation.returnsCredential else { return redactStrings(in: value) }
        return redactFields(in: value)
    }

    /// Field names that carry a secret in ElevenLabs answers.
    public static let credentialFieldNames: Set<String> = [
        "xi-api-key", "xi_api_key", "api_key", "key", "secret", "value", "token",
        "signed_url", "webhook_secret", "hmac_secret", "client_secret", "access_token",
        "refresh_token", "password", "conversation_token",
    ]

    static func redactFields(in value: JSONValue) -> JSONValue {
        switch value {
        case .object(let object):
            return .object(Dictionary(uniqueKeysWithValues: object.map { key, inner in
                if credentialFieldNames.contains(key.lowercased()), inner != .null {
                    return (key, .string(placeholder))
                }
                return (key, redactFields(in: inner))
            }))
        case .array(let array):
            return .array(array.map(redactFields(in:)))
        case .string(let text):
            return .string(redact(text))
        case .null, .bool, .number:
            return value
        }
    }

    static func redactStrings(in value: JSONValue) -> JSONValue {
        switch value {
        case .object(let object): .object(object.mapValues(redactStrings(in:)))
        case .array(let array): .array(array.map(redactStrings(in:)))
        case .string(let text): .string(redact(text))
        case .null, .bool, .number: value
        }
    }

    private static let patterns: [NSRegularExpression] = [
        // Current keys: sk_ followed by the secret.
        #"(?<![A-Za-z0-9])sk_[A-Za-z0-9_\-]{8,}"#,
        // Legacy keys: 32 hex digits. Longer runs too.
        #"(?<![A-Za-z0-9])[0-9a-fA-F]{32,}(?![A-Za-z0-9])"#,
    ].map { try! NSRegularExpression(pattern: $0) }
}
