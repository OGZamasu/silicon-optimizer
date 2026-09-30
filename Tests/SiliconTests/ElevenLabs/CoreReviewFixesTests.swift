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
}
