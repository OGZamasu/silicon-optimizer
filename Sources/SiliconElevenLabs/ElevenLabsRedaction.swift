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

    /// An answer with its credential fields replaced — what MCP and control output carry unless
    /// the owner's switch lets agents see them. For a credential-returning operation that is
    /// the fields the risk table names for it; for every answer, the key preview `GET /v1/user`
    /// includes and any `sk_…` string.
    public static func redactCredentials(
        in value: JSONValue, for operation: ElevenLabsOperation
    ) -> JSONValue {
        let fields = ElevenLabsRiskTable.credentialFields[operation.id].map(Set.init)
            ?? (operation.returnsCredential ? credentialFieldNames : [])
        return redactFields(fields.union(ElevenLabsRiskTable.alwaysRedactedFields), in: value)
    }

    /// Field names redacted from a credential-returning operation the risk table has no field
    /// list for (one a spec refresh added).
    public static let credentialFieldNames: Set<String> = [
        "xi-api-key", "xi_api_key", "api_key", "key", "secret", "value", "token",
        "signed_url", "webhook_secret", "hmac_secret", "client_secret", "access_token",
        "refresh_token", "password", "conversation_token",
    ]

    /// `value` with every field named in `fields` (at any depth) replaced, and `sk_…` keys
    /// in any string redacted. Other hex runs are left alone here: ElevenLabs' public user and
    /// owner ids are 64 hex digits, and an answer that lost them would be useless — unlike an
    /// error message, which loses nothing by it.
    static func redactFields(_ fields: Set<String>, in value: JSONValue) -> JSONValue {
        switch value {
        case .object(let object):
            return .object(Dictionary(uniqueKeysWithValues: object.map { key, inner in
                if fields.contains(key), inner != .null {
                    return (key, .string(placeholder))
                }
                return (key, redactFields(fields, in: inner))
            }))
        case .array(let array):
            return .array(array.map { redactFields(fields, in: $0) })
        case .string(let text):
            return .string(redactKeys(text))
        case .null, .bool, .number:
            return value
        }
    }

    /// Only `sk_…` keys: what a JSON answer is scrubbed of.
    static func redactKeys(_ text: String) -> String {
        guard text.contains("sk_") else { return text }
        return patterns[0].stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: placeholder
        )
    }

    private static let patterns: [NSRegularExpression] = [
        // Current keys: sk_ followed by the secret.
        #"(?<![A-Za-z0-9])sk_[A-Za-z0-9_\-]{8,}"#,
        // Legacy keys: 32 hex digits. Longer runs too.
        #"(?<![A-Za-z0-9])[0-9a-fA-F]{32,}(?![A-Za-z0-9])"#,
    ].map { try! NSRegularExpression(pattern: $0) }
}
