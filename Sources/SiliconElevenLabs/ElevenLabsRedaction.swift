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
    ///
    /// `revealingCredentialFields` is the owner's switch: it hands an agent the fields the risk
    /// table names for this one operation (a new API key, a webhook secret, a signed URL) and
    /// nothing else. The account's own key preview and any `sk_…` key stay masked either way —
    /// the switch allows the action, it does not open the vault.
    ///
    /// Plain-string header values (`Authorization: Bearer …` in a tool, MCP server or webhook)
    /// are masked by default and follow the same switch: masked unless the owner let agents see
    /// credentials, because an agent that edits a tool must send its whole `tool_config` back,
    /// headers included, and a masked value cannot be sent back. `maskingHeaderValues` overrides
    /// the switch for them: the app's own runner passes `false`, because the owner's editor needs
    /// the real config to write back and the header values are not credentials the API "will not
    /// show again". An `sk_…` key inside a header value is masked whatever either says.
    public static func redactCredentials(
        in value: JSONValue, for operation: ElevenLabsOperation,
        revealingCredentialFields: Bool = false, maskingHeaderValues: Bool? = nil
    ) -> JSONValue {
        let named = ElevenLabsRiskTable.credentialFields[operation.id].map(Set.init)
            ?? (operation.returnsCredential ? credentialFieldNames : [])
        let fields = (revealingCredentialFields ? [] : named)
            .union(ElevenLabsRiskTable.alwaysRedactedFields)
        return redactFields(
            fields, in: value, maskingHeaderValues: maskingHeaderValues ?? !revealingCredentialFields
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
        switch map {
        case .object(let entries):
            return .object(entries.mapValues { entry in
                if case .string(let text) = entry, !text.isEmpty { return .string(placeholder) }
                return entry
            })
        case .array(let items):
            // `custom_sip_headers` is a list of {type, key, value}: the value is the secret.
            return .array(items.map { item in
                guard case .object(var fields) = item, case .string(let text)? = fields["value"], !text.isEmpty
                else { return item }
                fields["value"] = .string(placeholder)
                return .object(fields)
            })
        default:
            return map
        }
    }

    /// Field names whose string values are secrets wherever they appear in a request the owner
    /// typed. Checked against every request schema in the pinned spec by
    /// `CoreReviewFixesTests`, so a spec refresh that adds one fails a test, not the owner.
    static let requestSecretFields: Set<String> = [
        "api_key", "api_token", "token", "password", "client_secret", "secret_key", "secret_token",
        "account_auth_token", "auth_token", "authorization", "xi-api-key", "webhook_secret",
        "hmac_secret", "access_token", "refresh_token", "shareable_token",
        // An mTLS auth connection's private key (PEM) and its passphrase.
        "client_key", "key_passphrase", "passphrase", "private_key",
    ]

    /// Query parameters that carry a credential: a single-use token for realtime transcription
    /// and the signature that starts a widget conversation. They must reach ElevenLabs, and must
    /// not appear in anything shown or logged, so URLs are masked through `maskingQuerySecrets`.
    static let secretQueryParameters: Set<String> = ["token", "conversation_signature"]

    /// `url` as text with the values of `secretQueryParameters` replaced, and any `sk_…` key the
    /// owner typed into another value (a search, an id) scrubbed as it is from a body. What
    /// "Show API call", "Copy as curl" and a request's `description` use; the request itself
    /// keeps the real URL.
    public static func maskingQuerySecrets(in url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.percentEncodedQueryItems, !items.isEmpty
        else { return redactKeys(inURL: url.absoluteString) }
        components.percentEncodedQueryItems = items.map { item in
            secretQueryParameters.contains(item.name.lowercased())
                ? URLQueryItem(name: item.name, value: urlPlaceholder) : item
        }
        return redactKeys(inURL: components.string ?? url.absoluteString)
    }

    /// The placeholder as it stands in a URL.
    static let urlPlaceholder = "%E2%80%B9redacted%E2%80%BA"

    /// `sk_…` keys in a URL. A key typed after a space or a symbol follows that character's
    /// percent-escape there (`search=for%20sk_…`), so an escape counts as a boundary too.
    static func redactKeys(inURL text: String) -> String {
        guard text.contains("sk_") else { return text }
        return urlKeyPattern.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text),
            withTemplate: NSRegularExpression.escapedTemplate(for: urlPlaceholder)
        )
    }

    private static let urlKeyPattern = try! NSRegularExpression(
        pattern: #"(?:(?<![A-Za-z0-9])|(?<=%[0-9A-Fa-f]{2}))sk_[A-Za-z0-9_\-]{8,}"#
    )

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

    /// Objects one of whose fields is what the owner typed for a phone transfer: the DTMF digits
    /// sent once it connects (an extension, but also a conference PIN or an account passcode) and
    /// the SIP User-to-User payload (CRM identifiers, an escalation reason). That field is masked;
    /// a `dynamic` post-dial value names a variable rather than holding digits, and stays.
    static let requestSecretSubfields: [String: String] = ["post_dial_digits": "value", "uui": "data"]

    /// A request body as "Show API call" and "Copy as curl" may show it: what the owner typed
    /// that is a secret — a secret's value, a Twilio or Exotel auth token, a SIP password, a
    /// literal `Authorization` header, a transfer's post-dial digits and UUI payload — replaced
    /// by a placeholder, keys and everything else as typed, and `sk_…` keys scrubbed from every
    /// string.
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
                    if let field = requestSecretSubfields[name] {
                        switch mask(inner) {
                        case .string(let text) where !text.isEmpty:
                            return (key, .string(placeholder))
                        case .object(var fields):
                            if case .string(let text)? = fields[field], !text.isEmpty,
                               fields["type"] != .string("dynamic") {
                                fields[field] = .string(placeholder)
                            }
                            return (key, .object(fields))
                        case let other:
                            return (key, other)
                        }
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
