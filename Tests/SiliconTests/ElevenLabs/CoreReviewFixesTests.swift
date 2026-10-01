import Foundation
import Security
import Testing
@testable import SiliconElevenLabs
@testable import SiliconUI

/// What the core's review found, one test per finding, each written to fail without its fix.
@Suite("ElevenLabs core — review fixes")
struct CoreReviewFixesTests {

    static let key = CoreClientTests.key

    // MARK: - The key never appears in a dump

    @Test func aRequestDumpedOrReflectedNeverShowsItsKey() throws {
        let request = ElevenLabsRequest(
            operationID: "get_user_info", method: "GET",
            url: try #require(URL(string: "https://api.elevenlabs.io/v1/user")),
            headers: ["xi-api-key": Self.key, "Accept": "application/json"],
            body: .none, timeout: 10, responseHandling: .memory(limit: 1_000)
        )
        var dumped = ""
        dump(request, to: &dumped)
        #expect(!dumped.contains(Self.key))
        #expect(!dumped.contains("xi-api-key"))
        #expect(!String(reflecting: request).contains(Self.key))
        #expect(!"\(request)".contains(Self.key))
        // What is reflected is still useful.
        #expect(dumped.contains("get_user_info"))
        #expect(dumped.contains("https://api.elevenlabs.io/v1/user"))
    }

    // MARK: - Dot segments

    @Test func aPathValueOfDotsIsRefusedBeforeAnythingIsSent() async throws {
        for dots in [".", ".."] {
            let rig = CoreClientTests.Rig(replies: [.json([:])])
            defer { rig.cleanUp() }
            do {
                _ = try await rig.client.call("delete_sample", arguments: [
                    "voice_id": "voice-1", "sample_id": .string(dots),
                ])
                Issue.record("a path value of \(dots) was accepted")
            } catch ElevenLabsError.invalidArguments(let problems) {
                #expect(problems.contains { $0.contains("sample_id") && $0.contains("\"..\"") })
            }
            #expect(rig.transport.requests.isEmpty)
        }
    }

    @Test func ordinaryPathValuesContainingDotsStillGoThrough() async throws {
        let rig = CoreClientTests.Rig(replies: [.json([:])])
        defer { rig.cleanUp() }
        _ = try await rig.client.call("delete_sample", arguments: [
            "voice_id": "voice.1", "sample_id": "..hidden",
        ])
        let url = try #require(rig.transport.requests.first?.url)
        #expect(url.absoluteString == "https://api.elevenlabs.io/v1/voices/voice.1/samples/..hidden")
    }

    // MARK: - The Keychain credential under a slow first read

    /// A Keychain whose read waits until the test lets it go, counting how often it was asked.
    final class SlowKeychain: @unchecked Sendable {
        private let lock = NSLock()
        /// Opens once and stays open, so a read that runs more than once (the bug) fails an
        /// assertion instead of waiting forever for a second release.
        private let gate = NSCondition()
        private var opened = false
        private var _reads = 0
        private var _started = false
        private let answer: String
        init(answer: String) { self.answer = answer }

        var reads: Int { lock.withLock { _reads } }
        var started: Bool { lock.withLock { _started } }
        func letReadFinish() {
            gate.lock()
            opened = true
            gate.broadcast()
            gate.unlock()
        }

        var access: ElevenLabsCredential.Access {
            .init(
                read: { [self] in
                    lock.withLock { _reads += 1; _started = true }
                    gate.lock()
                    while !opened { gate.wait() }
                    gate.unlock()
                    return .found(answer)
                },
                write: { _ in errSecSuccess },
                delete: { errSecSuccess }
            )
        }

        func waitUntilAsked() async throws {
            for _ in 0..<1_000 where !started { try await Task.sleep(for: .milliseconds(5)) }
            #expect(started, "the read never started")
        }
    }

    static let oldKey = "sk_" + String(repeating: "old0", count: 12)
    static let newKey = "sk_" + String(repeating: "new1", count: 12)

    @Test func aReadInFlightWhenRemoveFinishesCannotBringTheOldKeyBack() async throws {
        let keychain = SlowKeychain(answer: Self.oldKey)
        let credential = ElevenLabsCredential(access: keychain.access)
        let slow = Task { try await credential.apiKey() }
        try await keychain.waitUntilAsked()
        try await credential.remove()
        keychain.letReadFinish()
        #expect(try await slow.value == nil, "the request that was waiting must not be handed the removed key")
        #expect(try await credential.apiKey() == nil, "and the cache must not have been overwritten")
        #expect(keychain.reads == 1)
    }

    @Test func aReadInFlightWhenAKeyIsStoredCannotOverwriteTheNewOne() async throws {
        let keychain = SlowKeychain(answer: Self.oldKey)
        let credential = ElevenLabsCredential(access: keychain.access)
        let slow = Task { try await credential.apiKey() }
        try await keychain.waitUntilAsked()
        try await credential.store(Self.newKey)
        keychain.letReadFinish()
        #expect(try await slow.value == Self.newKey)
        #expect(try await credential.apiKey() == Self.newKey)
        #expect(keychain.reads == 1)
    }

    @Test func requestsThatArriveTogetherShareOneKeychainRead() async throws {
        let keychain = SlowKeychain(answer: Self.oldKey)
        let credential = ElevenLabsCredential(access: keychain.access)
        let waiters = (0..<6).map { _ in Task { try await credential.apiKey() } }
        try await keychain.waitUntilAsked()
        // Give the others time to arrive behind the first before it finishes.
        try await Task.sleep(for: .milliseconds(100))
        keychain.letReadFinish()
        for waiter in waiters { #expect(try await waiter.value == Self.oldKey) }
        #expect(keychain.reads == 1, "one consent dialog, not one per caller")
    }

    // MARK: - Which URLs the key may be sent to

    @Test func onlyTheFiveHostsOverHTTPSOnPort443AreAllowed() throws {
        let hosts = ElevenLabsRegion.allowedHosts
        #expect(hosts.count == 5)
        func allowed(_ text: String, loopback: Int? = nil) -> Bool {
            URLSessionTransport.isAllowed(URL(string: text)!, allowedHosts: hosts, loopbackPort: loopback)
        }
        for host in hosts {
            #expect(allowed("https://\(host)/v1/user"))
            #expect(allowed("https://\(host):443/v1/user"))
        }
        let refused = [
            "http://api.elevenlabs.io/v1/user",                 // not https
            "https://api.elevenlabs.io:8443/v1/user",           // another port
            "https://api.elevenlabs.io:80/v1/user",
            "https://api.elevenlabs.io.example.com/v1/user",    // a suffix of a look-alike
            "https://example.com/v1/user",
            "https://API.ELEVENLABS.IO/v1/user",                // compared exactly
            "https://api.elevenlabs.io./v1/user",               // trailing dot
            "https://xapi.elevenlabs.io/v1/user",
            "https://elevenlabs.io/v1/user",
            "https://api.eu.elevenlabs.io/v1/user",             // not one of the five
            "https://127.0.0.1/v1/user",
            "wss://api.elevenlabs.io/v1/user",
            "ftp://api.elevenlabs.io/v1/user",
            "file:///etc/passwd",
        ]
        for text in refused { #expect(!allowed(text), "\(text) must not be allowed") }
    }

    @Test func theLoopbackAllowanceIsExactlyOnePortOverHTTP() throws {
        let hosts = ElevenLabsRegion.allowedHosts
        func allowed(_ text: String, loopback: Int?) -> Bool {
            URLSessionTransport.isAllowed(URL(string: text)!, allowedHosts: hosts, loopbackPort: loopback)
        }
        #expect(allowed("http://127.0.0.1:5000/x", loopback: 5000))
        #expect(!allowed("http://127.0.0.1:5001/x", loopback: 5000))
        #expect(!allowed("https://127.0.0.1:5000/x", loopback: 5000))
        #expect(!allowed("http://localhost:5000/x", loopback: 5000))
        #expect(!allowed("http://127.0.0.1:5000/x", loopback: nil), "production has no loopback allowance")
    }

    // MARK: - Secrets the owner types never show in "Show API call"

    @Test func aSecretsValueIsMaskedInTheDescribedCall() throws {
        let rig = CoreClientTests.Rig(replies: [])
        defer { rig.cleanUp() }
        let call = try rig.client.describe("create_secret_route", arguments: [
            "name": "stripe", "value": "hunter2-very-secret-value", "type": "new",
        ])
        let text = try #require(call.body).jsonString()
        #expect(!text.contains("hunter2"), "the secret's value must not appear")
        #expect(text.contains("stripe"), "the rest of the request is shown as typed")
        #expect(!call.headers.values.contains { $0.contains(Self.key) })
    }

    @Test func aKeyPastedIntoAPromptIsScrubbedFromTheDescribedCall() throws {
        let rig = CoreClientTests.Rig(replies: [])
        defer { rig.cleanUp() }
        let call = try rig.client.describe("text_to_speech_full", arguments: [
            "voice_id": "voice-1", "text": .string("read this out: \(Self.key)"),
        ])
        #expect(!(try #require(call.body).jsonString()).contains(Self.key))
    }

    @Test func providerTokensPasswordsAndLiteralHeadersAreMaskedWhileReferencesAndIdsStay() {
        let request: JSONValue = [
            "account_sid": "AC-public-id",
            "account_auth_token": "twilio-auth-token-value",
            "inbound_trunk_config": [
                "credentials": ["username": "sip-user", "password": "sip-password-value"],
                "attributes_to_headers": ["x-tenant": "X-Tenant"],
            ],
            "tool_config": ["api_schema": [
                "url": "https://hooks.example.com/run",
                "request_headers": [
                    "Authorization": "Bearer literal-token-value",
                    "X-From-Vault": ["secret_id": "secret-7"],
                ],
            ]],
            "max_tokens": 512,
        ]
        let shown = ElevenLabsRedaction.maskingRequestSecrets(in: request, operationID: "add_tool_route")
        let text = (try? shown.jsonString()) ?? ""
        for leaked in ["twilio-auth-token-value", "sip-password-value", "literal-token-value"] {
            #expect(!text.contains(leaked), "\(leaked) must be masked")
        }
        for kept in ["AC-public-id", "sip-user", "X-Tenant", "https://hooks.example.com/run", "secret-7",
                     "Authorization", "512"] {
            #expect(text.contains(kept), "\(kept) is not a secret and must stay")
        }
    }

    /// A transfer's post-dial digits can be a conference PIN or an account passcode, and its SIP
    /// UUI payload carries CRM identifiers: both are the owner's typing and masked. A dynamic
    /// post-dial value names a variable and stays; so does the number transferred to.
    @Test func aTransfersPostDialDigitsAndUUIPayloadAreMaskedInTheDescribedCall() {
        let request: JSONValue = ["tool_config": ["params": ["transfers": [
            ["transfer_destination": ["type": "phone", "phone_number": "+15550100"],
             "post_dial_digits": ["type": "static", "value": "ww1234#"],
             "uui": ["data": "crm-case-4471-escalated", "protocol_discriminator": "00"]],
            ["post_dial_digits": ["type": "dynamic", "value": "conference_pin"]],
        ]]]]
        let text = (try? ElevenLabsRedaction.maskingRequestSecrets(in: request, operationID: "add_tool_route")
            .jsonString()) ?? ""
        #expect(!text.contains("ww1234#"), "post-dial digits must be masked")
        #expect(!text.contains("crm-case-4471"), "the UUI payload must be masked")
        for kept in ["+15550100", "conference_pin", "protocol_discriminator", "static"] {
            #expect(text.contains(kept), "\(kept) is not a secret and must stay")
        }
    }

    @Test func anEnvironmentVariablesPlainValuesAreMaskedButItsReferencesStay() {
        let request: JSONValue = ["label": "backend", "values": [
            "production": "https://internal.example.com/?key=abc123", "staging": ["secret_id": "s-1"],
        ]]
        let text = (try? ElevenLabsRedaction.maskingRequestSecrets(
            in: request, operationID: "create_environment_variable").jsonString()) ?? ""
        #expect(!text.contains("abc123"))
        #expect(text.contains("s-1") && text.contains("backend") && text.contains("production"))
    }

    // MARK: - Literal header values in answers

    @Test func literalHeaderValuesInAnAnswerAreMaskedButSecretReferencesStay() throws {
        let operation = try #require(ElevenLabsCatalog.operation("get_tool_route"))
        #expect(!operation.returnsCredential, "this is the case no field-name rule can see")
        let answer: JSONValue = [
            "id": "tool-1",
            "tool_config": ["api_schema": [
                "request_headers": [
                    "Authorization": "Bearer literal-token-value",
                    "X-From-Vault": ["secret_id": "secret-7"],
                ],
            ]],
        ]
        let text = try ElevenLabsRedaction.redactCredentials(in: answer, for: operation).jsonString()
        #expect(!text.contains("literal-token-value"))
        #expect(text.contains("Authorization") && text.contains("secret-7") && text.contains("tool-1"))
    }

    // MARK: - The masks cover every secret-looking field in the spec

    /// Walks every request schema in the pinned spec for fields that look like secrets, and
    /// requires each to be either masked or on a short list of things that only look like one.
    /// A spec refresh that adds `client_token` fails here, not on the owner's screen.
    @Test func everySecretLookingRequestFieldInTheSpecIsClassified() throws {
        let data = try Data(contentsOf: CoreCatalogTests.repository.appendingPathComponent("Scripts/elevenlabs/openapi.json"))
        let spec = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let schemas = try #require((spec["components"] as? [String: Any])?["schemas"] as? [String: Any])
        let paths = try #require(spec["paths"] as? [String: Any])
        let looksSecret = try NSRegularExpression(pattern: "secret|token|password|passphrase|api[_-]?key|credential|authorization|bearer|private|client_key|signature")
        let looksLikeHeaders = try NSRegularExpression(pattern: "headers")

        var found: Set<String> = []
        func walk(_ node: Any?, depth: Int, seen: inout Set<String>) {
            guard depth < 8, let node = node as? [String: Any] else { return }
            if let ref = node["$ref"] as? String {
                let name = String(ref.split(separator: "/").last ?? "")
                guard seen.insert(name).inserted else { return }
                walk(schemas[name], depth: depth + 1, seen: &seen)
                return
            }
            for combinator in ["anyOf", "oneOf", "allOf"] {
                for variant in node[combinator] as? [Any] ?? [] { walk(variant, depth: depth + 1, seen: &seen) }
            }
            for (name, property) in node["properties"] as? [String: Any] ?? [:] {
                let range = NSRange(name.startIndex..., in: name)
                if looksSecret.firstMatch(in: name, range: range) != nil
                    || looksLikeHeaders.firstMatch(in: name, range: range) != nil {
                    found.insert(name.lowercased())
                }
                walk(property, depth: depth + 1, seen: &seen)
            }
            walk(node["items"], depth: depth + 1, seen: &seen)
            walk(node["additionalProperties"], depth: depth + 1, seen: &seen)
        }
        for (_, item) in paths {
            for (method, operation) in item as? [String: Any] ?? [:] where ["post", "put", "patch"].contains(method) {
                let content = ((operation as? [String: Any])?["requestBody"] as? [String: Any])?["content"] as? [String: Any] ?? [:]
                for (_, media) in content {
                    var seen: Set<String> = []
                    walk((media as? [String: Any])?["schema"], depth: 0, seen: &seen)
                }
            }
        }

        // Query parameters too: they are shown in the URL.
        var queryFound: Set<String> = []
        for (_, item) in paths {
            for (method, operation) in item as? [String: Any] ?? [:] where ["get", "post", "put", "patch", "delete"].contains(method) {
                for parameter in (operation as? [String: Any])?["parameters"] as? [[String: Any]] ?? []
                where parameter["in"] as? String == "query" {
                    let name = (parameter["name"] as? String ?? "").lowercased()
                    if looksSecret.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil {
                        queryFound.insert(name)
                    }
                }
            }
        }
        let queryNotSecrets: Set<String> = ["next_page_token", "api_key_name"]
        let unclassifiedQuery = queryFound.subtracting(ElevenLabsRedaction.secretQueryParameters).subtracting(queryNotSecrets)
        #expect(unclassifiedQuery.isEmpty, "query parameters that look like credentials and are not classified: \(unclassifiedQuery.sorted())")
        #expect(queryFound.contains("token") && queryFound.contains("conversation_signature"), "the walk found the parameters it should")

        let masked = ElevenLabsRedaction.requestSecretFields.union(ElevenLabsRedaction.headerMapFields)
        let notSecrets: Set<String> = [
            "secret_id",               // a reference to a secret, not its value
            "max_tokens",              // an LLM limit
            "credentials",             // a container: its password is masked on its own
            "token_url", "token_response_field",   // where and what to read, not a token
            "credential_id", "workspace_api_key_id",   // ids
            "attributes_to_headers",   // SIP attribute to header *name*
            "next_page_token",         // a pagination cursor
        ]
        let unclassified = found.subtracting(masked).subtracting(notSecrets)
        #expect(unclassified.isEmpty, "request fields that look like secrets and are not classified: \(unclassified.sorted())")
        #expect(found.contains("account_auth_token") && found.contains("request_headers"), "the walk found the fields it should")
    }

    // MARK: - A masked value is never sent back

    @Test func aMaskedValueFromAnEarlierAnswerIsRefusedInsteadOfOverwritingTheRealOne() async throws {
        let rig = CoreClientTests.Rig(replies: [.json([:])])
        defer { rig.cleanUp() }
        let masked: JSONValue = ["api_schema": ["url": "https://hooks.example.com/run",
                                                "request_headers": ["Authorization": .string(ElevenLabsRedaction.placeholder)]]]
        do {
            _ = try await rig.client.call("update_tool_route", arguments: [
                "tool_id": "tool-1", "tool_config": masked,
            ])
            Issue.record("a masked header was sent")
        } catch ElevenLabsError.invalidArguments(let problems) {
            #expect(problems.contains { $0.contains("tool_config") && $0.contains("overwrite") })
        }
        #expect(rig.transport.requests.isEmpty)
        // Ordinary text is untouched.
        #expect(rig.client.validate("text_to_speech_full", arguments: [
            "voice_id": "voice-1", "text": "Nothing is redacted here.",
        ]).isEmpty)
    }

    // MARK: - The owner's switch reveals one operation's credential fields, not the vault

    @Test func revealingCredentialFieldsShowsOnlyWhatTheOperationReturnsForTheOwner() throws {
        let operation = try #require(ElevenLabsCatalog.operation("create_workspace_webhook_route"))
        #expect(operation.returnsCredential)
        let key = Self.key
        let answer: JSONValue = [
            "webhook_secret": "whsec-value-the-owner-asked-for",
            "xi_api_key_preview": .string(key),
            "settings": ["request_headers": ["Authorization": "Bearer literal-token-value"]],
        ]
        let masked = try ElevenLabsRedaction.redactCredentials(in: answer, for: operation).jsonString()
        #expect(!masked.contains("whsec-value") && !masked.contains("literal-token-value"))

        let revealed = try ElevenLabsRedaction.redactCredentials(
            in: answer, for: operation, revealingCredentialFields: true).jsonString()
        #expect(revealed.contains("whsec-value-the-owner-asked-for"), "the switch reveals the named field")
        #expect(!revealed.contains(key), "but never a key")
        #expect(revealed.contains("literal-token-value"),
                "and header values, so an agent that may edit a tool can write its whole config back")

        // The app's own runner: named credential fields masked (they are shown once), header
        // values left for the owner's editor to write back.
        let forTheOwner = try ElevenLabsRedaction.redactCredentials(
            in: answer, for: operation, maskingHeaderValues: false).jsonString()
        #expect(!forTheOwner.contains("whsec-value") && !forTheOwner.contains(key))
        #expect(forTheOwner.contains("literal-token-value"))
    }

    @Test func aListOfSIPHeadersHasItsValuesMasked() throws {
        let operation = try #require(ElevenLabsCatalog.operation("get_tool_route"))
        let answer: JSONValue = ["params": ["transfers": [[
            "custom_sip_headers": [["type": "static", "key": "X-Auth", "value": "sip-secret-value"]],
        ]]]]
        let text = try ElevenLabsRedaction.redactCredentials(in: answer, for: operation).jsonString()
        #expect(!text.contains("sip-secret-value"))
        #expect(text.contains("X-Auth"))
    }

    // MARK: - Credential query parameters

    @Test func aTokenInTheQueryIsMaskedInWhatIsShownButSentToElevenLabs() async throws {
        let rig = CoreClientTests.Rig(replies: [.json([:])])
        defer { rig.cleanUp() }
        let token = "single-use-token-value-1234"
        let signature = "conversation-signature-value-5678"

        let shown = try rig.client.describe("get_agent_widget_route", arguments: [
            "agent_id": "agent-1", "conversation_signature": .string(signature),
        ])
        #expect(!shown.url.contains(signature), "Show API call and Copy as curl must not carry it")
        #expect(shown.url.contains("conversation_signature="))

        _ = try await rig.client.call("get_agent_widget_route", arguments: [
            "agent_id": "agent-1", "conversation_signature": .string(signature),
        ])
        let sent = try #require(rig.transport.requests.first)
        #expect(sent.url.absoluteString.contains(signature), "ElevenLabs still receives the real value")
        #expect(!"\(sent)".contains(signature) && !String(reflecting: sent).contains(signature))
        var dumped = ""
        dump(sent, to: &dumped)
        #expect(!dumped.contains(signature))

        let masked = ElevenLabsRedaction.maskingQuerySecrets(
            in: try #require(URL(string: "https://api.elevenlabs.io/v1/speech-to-text?token=\(token)&next_page_token=cursor-1")))
        #expect(!masked.contains(token))
        #expect(masked.contains("next_page_token=cursor-1"), "a pagination cursor is not a secret")
    }

    /// A body is scrubbed of `sk_…` keys in every string; the URL is too — a key pasted into a
    /// search box or an id field is the owner's typing, and Show API call is copied around.
    @Test func aKeyTypedIntoAQueryOrPathValueIsScrubbedFromTheDescribedURL() async throws {
        let rig = CoreClientTests.Rig(replies: [.json([:])])
        defer { rig.cleanUp() }
        let search = try rig.client.describe("get_user_voices_v2", arguments: [
            "search": .string("voices for \(Self.key)"), "page_size": 10,
        ])
        #expect(!search.url.contains(Self.key))
        #expect(search.url.contains("search=voices%20for%20%E2%80%B9redacted%E2%80%BA"))
        #expect(search.url.contains("page_size=10"), "the rest of the query is shown as sent")
        let byID = try rig.client.describe("get_voice_by_id", arguments: ["voice_id": .string(Self.key)])
        #expect(!byID.url.contains(Self.key))

        _ = try await rig.client.call("get_user_voices_v2", arguments: ["search": .string(Self.key)])
        let sent = try #require(rig.transport.requests.first)
        #expect(sent.url.absoluteString.contains(Self.key), "ElevenLabs still receives what was typed")
        #expect(!"\(sent)".contains(Self.key) && !String(reflecting: sent).contains(Self.key))
    }

    /// The query mask fails closed — a URL it cannot take apart is shown without its query — and
    /// sees through a percent-encoded or upper-case name and a fragment. The client never builds
    /// such URLs; the mask must not depend on that.
    @Test func theQueryMaskFailsClosedAndSeesThroughEncodedNamesAndFragments() throws {
        func masked(_ text: String) throws -> String {
            ElevenLabsRedaction.maskingQuerySecrets(in: try #require(URL(string: text)))
        }
        let base = "https://api.elevenlabs.io/v1/speech-to-text"
        let encoded = try masked("\(base)?%74oken=encoded-name-value&TOKEN=upper-case-value&enable_logging=false")
        #expect(!encoded.contains("encoded-name-value") && !encoded.contains("upper-case-value"))
        #expect(encoded.contains("enable_logging=false"), "other parameters are shown as sent")

        let fragment = try masked("\(base)?x=1#token=fragment-value")
        #expect(!fragment.contains("fragment-value"))
        #expect(fragment.hasPrefix("\(base)?x=1#"))

        let unread = ElevenLabsRedaction.maskingQuerySecrets(
            in: "\(base)?token=raw-value&x=1#more", components: nil)
        #expect(unread == "\(base)?%E2%80%B9redacted%E2%80%BA", "nothing after the path when the URL cannot be read")
        #expect(ElevenLabsRedaction.maskingQuerySecrets(in: "\(base)/\(Self.key)", components: nil) == "\(base)/%E2%80%B9redacted%E2%80%BA")
    }

    @Test func aSlashBackslashOrNULInAPathValueIsRefusedBeforeAnythingIsSent() async throws {
        // "P/convert" would reach a different (billing) route once the server decodes %2F.
        for bad in ["P/convert", "a\\b", "a\0b", String(repeating: "x", count: 513)] {
            let rig = CoreClientTests.Rig(replies: [.json([:])])
            defer { rig.cleanUp() }
            do {
                _ = try await rig.client.call("get_voice_by_id", arguments: ["voice_id": .string(bad)])
                Issue.record("a path value of \(bad.prefix(12)) was accepted")
            } catch ElevenLabsError.invalidArguments(let problems) {
                #expect(problems.contains { $0.contains("voice_id") })
            }
            #expect(rig.transport.requests.isEmpty)
        }
    }

    @Test func aPercentSignInAPathValueIsEncodedAsALiteralPercentNeverAsASlash() async throws {
        let rig = CoreClientTests.Rig(replies: [.json([:])])
        defer { rig.cleanUp() }
        _ = try await rig.client.call("get_voice_by_id", arguments: ["voice_id": "P%2Fconvert"])
        let url = try #require(rig.transport.requests.first?.url).absoluteString
        #expect(url.hasSuffix("/v1/voices/P%252Fconvert"))
    }
}
