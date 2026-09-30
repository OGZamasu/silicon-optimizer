import Foundation
import Network
import Testing
@testable import SiliconControl

/// Who may reach `/elevenlabs/*`: this Mac's own control token on the loopback listener, and
/// nobody else — not a phone paired at full scope, not a chat-only phone, not a swarm peer,
/// on either listener. These routes spend the owner's credits and some place phone calls.
@Suite("ElevenLabs control: who may reach it")
struct ElevenLabsControlPolicyTests {

    /// Every route, as a client sends it.
    static let routes: [(method: String, target: String, body: String?)] = [
        ("GET", "/elevenlabs/status", nil),
        ("GET", "/elevenlabs/operations?q=speech&risk=generate&limit=5", nil),
        ("GET", "/elevenlabs/operations/text_to_speech_full", nil),
        ("POST", "/elevenlabs/call", #"{"operation":"get_user_info","arguments":{}}"#),
    ]

    /// Paths as the router sees them (query gone, percent-escapes decoded), including the
    /// spellings that route to the same place or to nowhere. Each must be refused by name.
    static let paths = [
        "/elevenlabs/status", "/elevenlabs/operations", "/elevenlabs/operations/x",
        "/elevenlabs/call", "/elevenlabs", "/elevenlabs/", "//elevenlabs/call",
        "/ElevenLabs/call", "/ELEVENLABS/status", "/elevenlabs/call/../status",
        "/elevenlabs/not-a-route",
    ]

    static let everyoneElse: [ControlServer.Caller] = [
        .swarm, .device(id: "phone-full", scope: .full), .device(id: "phone-chat", scope: .chat),
    ]

    // MARK: - The rule

    @Test func onlyThisMacsTokenMayReachAnyElevenLabsPath() {
        for path in Self.paths {
            for method in ["GET", "POST", "DELETE", "PATCH"] {
                #expect(ControlServer.Caller.control.mayReach(method: method, path: path))
                for caller in Self.everyoneElse {
                    #expect(
                        !caller.mayReach(method: method, path: path),
                        "\(caller) reached \(method) \(path)"
                    )
                }
            }
        }
    }

    /// The rule is about these routes and nothing else: what a full-control phone could reach
    /// before, it still reaches.
    @Test func theRuleChangesNothingOutsideElevenLabs() {
        let full = ControlServer.Caller.device(id: "phone-full", scope: .full)
        #expect(full.mayReach(method: "POST", path: "/load"))
        #expect(full.mayReach(method: "POST", path: "/image/generate"))
        #expect(full.mayReach(method: "GET", path: "/elevenlabsish"))
        #expect(ControlServer.Caller.swarm.mayReach(method: "GET", path: "/status"))
        #expect(!ElevenLabsControl.isElevenLabsPath("/elevenlabs.json"))
        #expect(!ElevenLabsControl.isElevenLabsPath("/v1/elevenlabs"))
    }

    @Test func everyoneElseIsToldTheSameOneSentence() throws {
        for path in Self.paths {
            let request = HTTPRequest(
                method: "POST", path: path, query: [:], headers: [:], body: Data()
            )
            #expect(ControlServer.scopeRefusal(for: request, as: .control) == nil)
            for caller in Self.everyoneElse {
                let refusal = try #require(ControlServer.scopeRefusal(for: request, as: caller))
                #expect(refusal.status == 403)
                let sentence = try JSONDecoder().decode(
                    ControlAPI.ErrorResponse.self, from: refusal.body
                ).error
                #expect(sentence == ElevenLabsControl.onlyThisMac)
            }
        }
        #expect(ElevenLabsControl.onlyThisMac.contains("credits"))
    }

    // MARK: - On the wire

    /// Four callers × two listeners × every route. On loopback a device token is no
    /// credential at all and on the tailnet the control token is none, so those are 401s;
    /// every caller the server does recognise, other than this Mac's own token, is a 403
    /// with the one sentence.
    @MainActor
    @Test func everyCallerOnEveryListenerOnEveryRoute() async throws {
        let swarmSecret = "swarm-fixture-secret"
        try await withServer(
            host: BuddyTestHost(tokens: ["ok"], pace: .milliseconds(1), failing: false),
            swarmToken: swarmSecret
        ) { fixture in
            let full = try await fixture.pair(name: "Full phone", scope: .full).token
            let chat = try await fixture.pair(name: "Chat phone", scope: .chat).token
            // The owner has also let the swarm reach this Mac: the same socket, with the
            // swarm secret honoured on it too.
            try await fixture.server.setTailnetAccess(
                address: "127.0.0.1", port: fixture.phone.port, for: .swarm
            )

            let control = fixture.local.token
            let expectations: [(caller: String, token: String?, loopback: Int, tailnet: Int)] = [
                ("control", control, Self.controlAnswer, 401),
                ("swarm", swarmSecret, 403, 403),
                ("full-scope phone", full, 401, 403),
                ("chat-only phone", chat, 401, 403),
                ("nobody", nil, 401, 401),
            ]
            for route in Self.routes {
                for expected in expectations {
                    for (listener, client, status) in [
                        ("loopback", fixture.local, expected.loopback),
                        ("tailnet", fixture.phone, expected.tailnet),
                    ] {
                        let (answered, body) = try await client.call(
                            route.method, route.target, token: expected.token, body: route.body
                        )
                        #expect(
                            answered == status,
                            "\(expected.caller) on \(listener): \(route.method) \(route.target) → \(answered)"
                        )
                        if status == 403 {
                            let sentence = try JSONDecoder().decode(
                                ControlAPI.ErrorResponse.self, from: body
                            ).error
                            #expect(sentence == ElevenLabsControl.onlyThisMac)
                        }
                    }
                }
            }
        }
    }

    /// What this Mac's own token gets on loopback before the routes exist: the router's 404,
    /// which is the proof that it got past every gate.
    static let controlAnswer = 404

    /// Refused on the headers. A phone declares three megabytes — inside what it may send
    /// anywhere else — and then sends nothing: the 403 must already be on its way, because
    /// nothing about these routes waits for a body it is going to refuse.
    @MainActor
    @Test func aPhoneOrAPeerIsRefusedBeforeItsBodyIsRead() async throws {
        let swarmSecret = "swarm-fixture-secret"
        try await withServer(
            host: BuddyTestHost(tokens: ["ok"], pace: .milliseconds(1), failing: false),
            swarmToken: swarmSecret
        ) { fixture in
            let full = try await fixture.pair(name: "Full phone", scope: .full).token
            let chat = try await fixture.pair(name: "Chat phone", scope: .chat).token
            try await fixture.server.setTailnetAccess(
                address: "127.0.0.1", port: fixture.phone.port, for: .swarm
            )
            let refusals: [(who: String, port: Int, token: String, declared: Int, status: String)] = [
                ("full-scope phone", fixture.phone.port, full, 3_000_000, "403"),
                ("chat-only phone", fixture.phone.port, chat, 3_000_000, "403"),
                ("swarm on the tailnet", fixture.phone.port, swarmSecret, 12_000_000, "403"),
                ("swarm on loopback", fixture.local.port, swarmSecret, 12_000_000, "403"),
                // Nobody at all is not read either: on loopback the ordinary ceiling is
                // sixteen megabytes for anyone, and here it is nothing.
                ("a made-up token on loopback", fixture.local.port, "made-up", 12_000_000, "401"),
            ]
            for refusal in refusals {
                let answer = try await Self.answerToHeadersAlone(
                    port: refusal.port,
                    "POST /elevenlabs/call HTTP/1.1\r\nHost: 127.0.0.1\r\n"
                        + "Authorization: Bearer \(refusal.token)\r\n"
                        + "Content-Type: application/json\r\n"
                        + "Content-Length: \(refusal.declared)\r\n\r\n"
                )
                #expect(
                    answer.hasPrefix("HTTP/1.1 \(refusal.status)"),
                    "\(refusal.who) was not refused before its body: \(answer.prefix(40))"
                )
                if refusal.status == "403" {
                    #expect(answer.contains(ElevenLabsControl.onlyThisMac), "\(refusal.who)")
                }
            }
        }
    }

    /// Sends a request's headers and nothing more, and returns whatever comes back within
    /// `seconds` — or throws, which is what a server still waiting for the body looks like.
    static func answerToHeadersAlone(
        port: Int, _ head: String, within seconds: Double = 5
    ) async throws -> String {
        let raw = try await RawConnection.connect(port: port)
        defer { raw.close() }
        try await raw.send(head)
        return try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask { try await raw.readSome() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            // A read still pending ends when its connection does.
            raw.close()
            guard let first else { throw BuddyTestError.timeout }
            return first
        }
    }
}
