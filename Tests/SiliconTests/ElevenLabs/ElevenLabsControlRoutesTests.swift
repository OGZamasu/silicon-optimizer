import Foundation
import Testing
@testable import SiliconControl

/// The wire layer: what each `/elevenlabs/*` request reaches the host as, what comes back, and
/// what never reaches the host at all.
@Suite("ElevenLabs control: routes")
struct ElevenLabsControlRoutesTests {

    @MainActor
    @Test func eachRouteReachesTheHostExactlyAsSent() async throws {
        let host = BuddyTestHost(tokens: ["ok"], pace: .milliseconds(1), failing: false)
        await ElevenLabsControlHostLog.shared.clear(host)
        try await withServer(host: host) { fixture in
            let token = fixture.local.token
            #expect(try await fixture.local.status("GET", "/elevenlabs/status", token: token) == 200)
            #expect(try await fixture.local.status(
                "GET",
                "/elevenlabs/operations?q=speech%20to%20text&group=Text%20to%20speech&risk=generate&limit=7",
                token: token
            ) == 200)
            #expect(try await fixture.local.status("GET", "/elevenlabs/operations", token: token) == 200)
            #expect(try await fixture.local.status(
                "GET", "/elevenlabs/operations/text_to_speech_full", token: token
            ) == 200)
            let call = #"{"operation":"text_to_speech_full","arguments":{"voice_id":"v","text":"Hi"},"files":[],"confirm":false}"#
            let (status, body) = try await fixture.local.call(
                "POST", "/elevenlabs/call", token: token, body: call
            )
            #expect(status == 200)
            #expect(String(decoding: body, as: UTF8.self).contains(#""route":"call""#))

            let seen = await ElevenLabsControlHostLog.shared.requests(for: host)
            #expect(seen.map(\.route) == [
                .status,
                .operations(.init(text: "speech to text", group: "Text to speech", risk: "generate", limit: "7")),
                .operations(.init()),
                .operation(id: "text_to_speech_full"),
                // The body as it arrived, byte for byte: the server does not read it.
                .call(body: Data(call.utf8)),
            ])
        }
    }

    /// The host's status and body are what the client gets — a 409 stays a 409.
    @MainActor
    @Test func theHostsStatusAndBodyGoOutAsTheyAre() async throws {
        let host = BuddyTestHost(tokens: ["ok"], pace: .milliseconds(1), failing: false)
        await ElevenLabsControlHostLog.shared.clear(host)
        try await withServer(host: host) { fixture in
            let (status, body) = try await fixture.local.call(
                "POST", "/elevenlabs/call", token: fixture.local.token,
                body: #"{"fixtureStatus":409}"#
            )
            #expect(status == 409)
            let refusal = try JSONDecoder().decode(ControlAPI.ErrorResponse.self, from: body)
            #expect(refusal.error == "fixture refusal 409")
        }
    }

    @MainActor
    @Test func aPathThatIsNoRouteIsA404AndNeverReachesTheHost() async throws {
        let host = BuddyTestHost(tokens: ["ok"], pace: .milliseconds(1), failing: false)
        await ElevenLabsControlHostLog.shared.clear(host)
        try await withServer(host: host) { fixture in
            for (method, path) in [
                ("GET", "/elevenlabs"), ("GET", "/elevenlabs/"), ("POST", "/elevenlabs/status"),
                ("GET", "/elevenlabs/call"), ("DELETE", "/elevenlabs/operations/x"),
                ("GET", "/elevenlabs/operations/a/b"), ("GET", "/ElevenLabs/status"),
                ("PUT", "/elevenlabs/call"),
            ] {
                let status = try await fixture.local.status(
                    method, path, token: fixture.local.token, body: method == "GET" ? nil : "{}"
                )
                #expect(status == 404, "\(method) \(path) → \(status)")
            }
            #expect(await ElevenLabsControlHostLog.shared.requests(for: host).isEmpty)
        }
    }

    /// The token keeps a web page out already. A page that rebinds its own name to 127.0.0.1
    /// still sends its own `Host` and `Origin`, and those are refused here too.
    @MainActor
    @Test func aBrowsersHostOrOriginIsRefusedOnLoopback() async throws {
        let host = BuddyTestHost(tokens: ["ok"], pace: .milliseconds(1), failing: false)
        await ElevenLabsControlHostLog.shared.clear(host)
        try await withServer(host: host) { fixture in
            for headers in [
                "Host: rebound.example:\(fixture.local.port)\r\n",
                "Host: 127.0.0.1:\(fixture.local.port)\r\nOrigin: http://rebound.example\r\n",
            ] {
                let answer = try await rawHTTP(
                    port: fixture.local.port, session: fixture.local.session,
                    "GET /elevenlabs/status HTTP/1.1\r\n" + headers
                        + "Authorization: Bearer \(fixture.local.token)\r\n"
                        + "Connection: close\r\n\r\n"
                )
                #expect(answer.hasPrefix("HTTP/1.1 403"))
                #expect(answer.contains(ElevenLabsControl.loopbackOnly))
            }
            #expect(await ElevenLabsControlHostLog.shared.requests(for: host).isEmpty)
        }
    }

    /// Everything that is not the Mac app — the MCP bridge's doubles, the other fixtures —
    /// answers a plain 501 rather than pretending to be connected.
    @MainActor
    @Test func aHostThatIsNotTheMacAnswersNotHere() async throws {
        try await withServer(host: BareDecisionHost()) { fixture in
            let (status, body) = try await fixture.local.call(
                "GET", "/elevenlabs/status", token: fixture.local.token
            )
            #expect(status == 501)
            let refusal = try JSONDecoder().decode(ControlAPI.ErrorResponse.self, from: body)
            #expect(refusal.error == ElevenLabsControl.notOnThisHost)
        }
    }

    @Test func theRouteTableIsTheseFiveAndNothingElse() {
        func route(_ method: String, _ path: String, _ query: [String: String] = [:])
            -> ElevenLabsControlRequest.Route? {
            ControlServer.elevenLabsRoute(
                method: method, segments: path.split(separator: "/").map(String.init),
                query: query, body: Data("{}".utf8)
            )
        }
        #expect(route("GET", "/elevenlabs/status") == .status)
        #expect(route("GET", "/elevenlabs/operations", ["q": "dub", "limit": "3"])
            == .operations(.init(text: "dub", limit: "3")))
        #expect(route("GET", "/elevenlabs/operations/get_voices") == .operation(id: "get_voices"))
        #expect(route("POST", "/elevenlabs/call") == .call(body: Data("{}".utf8)))
        #expect(route("POST", "/elevenlabs/agents/converse") == .agentConverse(body: Data("{}".utf8)))
        #expect(route("POST", "/elevenlabs/operations") == nil)
        // A trailing slash is the same route, as everywhere on this server.
        #expect(route("GET", "/elevenlabs/operations/") == .operations(.init()))
        #expect(route("GET", "/elevenlabs") == nil)
        #expect(route("GET", "/status") == nil)
    }

    /// The fixed-shape answers survive a round trip, and every refusal is readable as the
    /// ordinary `{"error": …}` every client already decodes.
    @Test func theWireTypesRoundTripAndARefusalIsAnError() throws {
        let status = ElevenLabsWire.Status(
            linked: true, region: "api.elevenlabs.io", regionName: "Global",
            agentsMayRunRiskyActions: false, operations: 403,
            account: .init(
                tier: "creator", characterCount: 1_200, characterLimit: 100_000,
                remainingCharacters: 98_800, nextResetAt: "2026-10-01T00:00:00Z",
                checkedAt: "2026-09-29T20:00:00Z"
            )
        )
        let decodedStatus = try JSONDecoder().decode(
            ElevenLabsWire.Status.self, from: ElevenLabsControlResponse.encode(status).body
        )
        #expect(decodedStatus == status)
        #expect(decodedStatus.riskySwitch == ElevenLabsControl.riskySwitch)

        let list = ElevenLabsWire.OperationList(
            total: 9,
            operations: [.init(
                id: "delete_voice", method: "DELETE", path: "/v1/voices/{voice_id}",
                group: "Voices", summary: "Delete Voice", risk: "destructive", billable: false,
                returnsCredential: false, requiresConfirmation: true, deprecated: false,
                supportsStreaming: false, fileFields: []
            )],
            groups: [.init(name: "Voices", count: 14)]
        )
        #expect(list.returned == 1)
        #expect(try JSONDecoder().decode(
            ElevenLabsWire.OperationList.self, from: ElevenLabsControlResponse.encode(list).body
        ) == list)

        let refusal = ElevenLabsControlResponse.refusal(403, .init(
            error: "Refused.", operation: "delete_voice", risk: "destructive",
            setting: ElevenLabsControl.riskySwitch
        ))
        #expect(refusal.status == 403)
        #expect(try JSONDecoder().decode(ControlAPI.ErrorResponse.self, from: refusal.body).error
            == "Refused.")
        #expect(try JSONDecoder().decode(ElevenLabsWire.Refusal.self, from: refusal.body).setting
            == ElevenLabsControl.riskySwitch)
    }
}

// MARK: - The recording host

/// What each test host was asked on `/elevenlabs/*`. Keyed by host, because suites run in
/// parallel and each builds its own.
actor ElevenLabsControlHostLog {
    static let shared = ElevenLabsControlHostLog()

    private var log: [ObjectIdentifier: [ElevenLabsControlRequest]] = [:]

    func note(_ host: ObjectIdentifier, _ request: ElevenLabsControlRequest) {
        log[host, default: []].append(request)
    }

    func requests(for host: BuddyTestHost) -> [ElevenLabsControlRequest] {
        log[ObjectIdentifier(host)] ?? []
    }

    /// Called as a test builds its host: an identifier can be reused once a host is gone.
    func clear(_ host: BuddyTestHost) { log[ObjectIdentifier(host)] = nil }
}

/// The ElevenLabs half of the control-server double: it records the request and answers with
/// the route it was, or with a status a call body asks for (`{"fixtureStatus": 409}`).
extension BuddyTestHost {
    func elevenLabs(_ request: ElevenLabsControlRequest) async -> ElevenLabsControlResponse {
        await ElevenLabsControlHostLog.shared.note(ObjectIdentifier(self), request)
        switch request.route {
        case .status: return .encode(["route": "status"])
        case .operations: return .encode(["route": "operations"])
        case .operation(let id): return .encode(["route": "operation", "id": id])
        case .call(let body):
            struct Asked: Decodable { var fixtureStatus: Int? }
            if let asked = try? JSONDecoder().decode(Asked.self, from: body).fixtureStatus {
                return .error(asked, "fixture refusal \(asked)")
            }
            return .encode(["route": "call"])
        case .agentConverse:
            return .encode(["route": "agentConverse"])
        }
    }
}
