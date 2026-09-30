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
        let looksSecret = try NSRegularExpression(pattern: "secret|token|password|api[_-]?key|credential|authorization|bearer|private[_-]?key")
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

        let masked = ElevenLabsRedaction.requestSecretFields.union(ElevenLabsRedaction.headerMapFields)
        let notSecrets: Set<String> = [
            "secret_id",               // a reference to a secret, not its value
            "max_tokens",              // an LLM limit
            "credentials",             // a container: its password is masked on its own
            "token_url", "token_response_field",   // where and what to read, not a token
            "credential_id", "workspace_api_key_id",   // ids
            "attributes_to_headers",   // SIP attribute to header *name*
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
        #expect(!revealed.contains("literal-token-value"), "and never a literal header value")
    }
}
