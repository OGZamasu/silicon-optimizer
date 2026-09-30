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
        return redactFields(
            fields.union(ElevenLabsRiskTable.alwaysRedactedFields), in: value, maskingHeaderValues: true
        )
    }

    /// Maps of header name to header value, wherever a tool, MCP server, custom LLM, webhook
    /// or SIP trunk carries them. A value may be a plain string, and then it comes back exactly
    /// as the owner typed it — `Authorization: Bearer …` — which no field-name rule can see. The
    /// values that are strings are secrets; the ones that are references (`{"secret_id": …}`,
    /// an environment variable, a dynamic variable) are not, and stay.
    static let headerMapFields: Set<String> = [
        "request_headers", "custom_headers", "custom_sip_headers", "headers",
    ]

    /// `map` with every plain-string value replaced and every reference kept.
    static func maskHeaderValues(_ map: JSONValue) -> JSONValue {
        guard case .object(let entries) = map else { return map }
        return .object(entries.mapValues { entry in
            if case .string(let text) = entry, !text.isEmpty { return .string(placeholder) }
            return entry
        })
    }

    /// Field names whose string values are secrets wherever they appear in a request the owner
    /// typed. Checked against every request schema in the pinned spec by
    /// `CoreReviewFixesTests`, so a spec refresh that adds one fails a test, not the owner.
    static let requestSecretFields: Set<String> = [
        "api_key", "api_token", "token", "password", "client_secret", "secret_key", "secret_token",
        "account_auth_token", "auth_token", "authorization", "xi-api-key", "webhook_secret",
        "hmac_secret", "access_token", "refresh_token", "shareable_token",
    ]

    /// Request fields that are secrets only in one operation, because their name alone says
    /// nothing: a secret's `value`, and an environment variable's `values` (plain strings feed
    /// tool URLs and headers).
    static let requestSecretFieldsByOperation: [String: Set<String>] = [
        "create_secret_route": ["value"],
        "update_secret_route": ["value"],
    ]
    static let requestSecretMapsByOperation: [String: Set<String>] = [
        "create_environment_variable": ["values"],
        "update_environment_variable": ["values"],
    ]

    /// A request body as "Show API call" and "Copy as curl" may show it: what the owner typed
    /// that is a secret — a secret's value, a Twilio or Exotel auth token, a SIP password, a
    /// literal `Authorization` header — replaced by a placeholder, keys and everything else as
    /// typed, and `sk_…` keys scrubbed from every string.
    public static func maskingRequestSecrets(in value: JSONValue, operationID: String) -> JSONValue {
        let extra = requestSecretFieldsByOperation[operationID] ?? []
        let maps = requestSecretMapsByOperation[operationID] ?? []
        func mask(_ value: JSONValue) -> JSONValue {
            switch value {
            case .object(let object):
                return .object(Dictionary(uniqueKeysWithValues: object.map { key, inner in
                    let name = key.lowercased()
                    if case .string(let text) = inner, !text.isEmpty,
                       requestSecretFields.contains(name) || extra.contains(name) {
                        return (key, .string(placeholder))
                    }
                    if headerMapFields.contains(name) || maps.contains(name) {
                        return (key, maskHeaderValues(mask(inner)))
                    }
                    return (key, mask(inner))
                }))
            case .array(let array):
                return .array(array.map(mask))
            case .string(let text):
                return .string(redactKeys(text))
            case .null, .bool, .number:
                return value
            }
        }
        return mask(value)
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
    static func redactFields(
        _ fields: Set<String>, in value: JSONValue, maskingHeaderValues: Bool = false
    ) -> JSONValue {
        switch value {
        case .object(let object):
            return .object(Dictionary(uniqueKeysWithValues: object.map { key, inner in
                if fields.contains(key), inner != .null {
                    return (key, .string(placeholder))
                }
                let redacted = redactFields(fields, in: inner, maskingHeaderValues: maskingHeaderValues)
                if maskingHeaderValues, headerMapFields.contains(key) {
                    return (key, maskHeaderValues(redacted))
                }
                return (key, redacted)
            }))
        case .array(let array):
            return .array(array.map { redactFields(fields, in: $0, maskingHeaderValues: maskingHeaderValues) })
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
