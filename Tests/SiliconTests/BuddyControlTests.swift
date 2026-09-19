import Foundation
import Network
import Testing
@testable import SiliconControl

/// The control server as a phone meets it: pairing, a device token, the second listener, the
/// two streaming routes, and everything that has to stop when the owner says so.
///
/// Everything here runs over loopback with a private handshake file and a private
/// `buddy.json`, so no user app, no tailnet and no real model is involved. The "tailnet"
/// listener is bound to 127.0.0.1 at a port the fixture picks — the control server's own
/// port would make it impossible to tell which listener answered.
@Suite("Silicon Buddy control routes")
struct BuddyControlTests {

    // MARK: - Pairing over the wire

    @Test func pairingMintsATokenThatWorksEverywhereAndOnlyTheMacCanRevokeIt() async throws {
        try await withServer { fixture in
            let paired = try await fixture.pair(name: "iPad mini", platform: "ipados")
            #expect(paired.port == fixture.phone.port)
            #expect(paired.scope == "full")

            // A device token is a bearer like any other, on every working route.
            #expect(try await fixture.phone.status("GET", "/status", token: paired.token) == 200)
            #expect(try await fixture.phone.status("GET", "/installed", token: paired.token) == 200)
            #expect(try await fixture.phone.status("GET", "/status", token: "guessed") == 401)

            // Except the two that administer other devices.
            #expect(try await fixture.phone.status(
                "GET", "/buddy/devices", token: paired.token
            ) == 403)
            #expect(try await fixture.phone.status(
                "DELETE", "/buddy/devices/\(paired.deviceID)", token: paired.token
            ) == 403)

            let (listStatus, listBody) = try await fixture.local.call(
                "GET", "/buddy/devices", token: fixture.local.token
            )
            #expect(listStatus == 200)
            let listed = try JSONDecoder().decode(
                [ControlAPI.BuddyDeviceSummary].self, from: listBody
            )
            #expect(listed.map(\.name) == ["iPad mini"])
            #expect(listed.map(\.scope) == ["full"])
            #expect(listed.first?.lastSeen != nil)
            // The digest never leaves the file it is written in.
            #expect(!String(decoding: listBody, as: UTF8.self).contains("tokenHash"))

            #expect(try await fixture.local.status(
                "DELETE", "/buddy/devices/\(paired.deviceID)", token: fixture.local.token
            ) == 200)
            #expect(try await fixture.local.status(
                "DELETE", "/buddy/devices/\(paired.deviceID)", token: fixture.local.token
            ) == 404)
            // Revoked means revoked, on the next request rather than the next launch.
            #expect(try await fixture.phone.status("GET", "/status", token: paired.token) == 401)
        }
    }

    /// The listener a request arrived on is a security boundary, not bookkeeping. A phone
    /// that leaves the house — or is lost with its token on it — must not be able to
    /// authenticate from a café the Mac happens to share a network with.
    @Test func aDeviceTokenIsNotACredentialOnTheLoopbackListener() async throws {
        try await withServer { fixture in
            let paired = try await fixture.pair()
            #expect(try await fixture.phone.status("GET", "/status", token: paired.token) == 200)
            #expect(try await fixture.local.status("GET", "/status", token: paired.token) == 401)
            // And pairing itself is refused there, so a token cannot be minted that way.
            await fixture.registry.invite(host: "127.0.0.1", port: fixture.local.port)
            let refused = try await fixture.local.status(
                "POST", "/buddy/pair", token: nil,
                body: #"{"code":"000000","deviceName":"x","platform":"y"}"#
            )
            #expect(refused == 403 || refused == 404)
        }
    }

    @Test func turningTheToggleOffSuspendsEveryPairedDevice() async throws {
        try await withServer { fixture in
            let paired = try await fixture.pair()
            #expect(try await fixture.phone.status("GET", "/status", token: paired.token) == 200)

            await fixture.registry.setAllowsTailnetDevices(false)
            #expect(try await fixture.phone.status("GET", "/status", token: paired.token) == 401)
            // Suspended, not forgotten: the row is still there to be turned back on.
            #expect(await fixture.registry.devices().count == 1)

            await fixture.registry.setAllowsTailnetDevices(true)
            #expect(try await fixture.phone.status("GET", "/status", token: paired.token) == 200)
        }
    }

    @Test func aWrongCodeIsRefusedAndThenThrottled() async throws {
        try await withServer { fixture in
            await fixture.registry.invite(host: "127.0.0.1", port: fixture.phone.port)
            let attempt = #"{"code":"000000","deviceName":"Phone","platform":"android"}"#

            for _ in 0..<BuddyRegistry.attemptsPerMinute {
                let refused = try await fixture.phone.status(
                    "POST", "/buddy/pair", token: nil, body: attempt
                )
                #expect(refused == 403)
            }
            let throttled = try await fixture.phone.status(
                "POST", "/buddy/pair", token: nil, body: attempt
            )
            #expect(throttled == 429)
        }
    }

    @Test func pairingWithNoCodeOpenIsRefusedRatherThanAccepted() async throws {
        try await withServer { fixture in
            let refused = try await fixture.phone.status(
                "POST", "/buddy/pair", token: nil,
                body: #"{"code":"123456","deviceName":"Phone","platform":"android"}"#
            )
            #expect(refused == 403)
        }
    }

    // MARK: - Scope

    @Test func aChatOnlyDeviceMayTalkButNotSpendTheMachine() async throws {
        try await withServer { fixture in
            let paired = try await fixture.pair(scope: .chat)
            #expect(paired.scope == "chat")
            let token = paired.token

            for allowed in [
                ("GET", "/status"), ("GET", "/installed"), ("GET", "/catalog"),
                ("GET", "/swarm"), ("GET", "/video/models"), ("GET", "/image/models"),
                ("GET", "/mesh/models"), ("GET", "/video/queue"), ("GET", "/conversations"),
                ("GET", "/v1/node"),
            ] {
                let code = try await fixture.phone.status(allowed.0, allowed.1, token: token)
                #expect(code == 200, "\(allowed.0) \(allowed.1) should be open to chat-only")
            }

            // Advisory routes: whatever this fixture's host answers, the scope gate is not
            // what stopped them. Reading and advising spends nothing.
            for advisory in [("GET", "/recommend"), ("POST", "/plan")] {
                let code = try await fixture.phone.status(
                    advisory.0, advisory.1, token: token,
                    body: advisory.0 == "POST" ? #"{"modelID":"x"}"# : nil
                )
                #expect(code != 403, "\(advisory.0) \(advisory.1) should be open to chat-only")
            }

            for refused in [
                ("POST", "/load"), ("POST", "/unload"), ("POST", "/install"),
                ("POST", "/benchmark"), ("POST", "/video/generate"),
                ("POST", "/image/generate"), ("POST", "/mesh/generate"),
                ("POST", "/video/queue"), ("POST", "/video/queue/control"),
                ("GET", "/buddy/devices"), ("GET", "/jev"),
            ] {
                let (code, body) = try await fixture.phone.call(
                    refused.0, refused.1, token: token, body: refused.0 == "POST" ? "{}" : nil
                )
                #expect(code == 403, "\(refused.0) \(refused.1) should be closed to chat-only")
                // The body the fixtures promise, from the one branch that can produce it.
                let envelope = try JSONDecoder().decode(ControlAPI.ErrorResponse.self, from: body)
                #expect(envelope.error == ControlServer.chatOnlyRefusal,
                        "\(refused.0) \(refused.1) sent a different sentence")
            }

            // Chat is the whole point of the scope, streaming included.
            let events = try await fixture.phone.events(
                "POST", "/chat/stream", token: token,
                body: #"{"messages":[{"role":"user","content":"hi","images":[]}]}"#
            ) { $0.contains { $0.name == "finished" } }
            #expect(events.contains { $0.name == "token" })

            // A full-control device is not affected by any of this.
            let full = try await fixture.pair(name: "Studio phone")
            #expect(try await fixture.phone.status(
                "POST", "/video/queue/control", token: full.token, body: #"{"action":"pause"}"#
            ) == 200)
        }
    }

    /// Reading what Jev costs is a full-control device's business; changing what this Mac
    /// will spend is the Mac's alone. A stolen phone token must not be able to lift the
    /// budget cap or switch a feature on.
    @Test func onlyTheMacMayChangeTheJevSettings() async throws {
        try await withServer { fixture in
            let paired = try await fixture.pair()
            #expect(paired.scope == "full")

            // A full-control phone may look.
            let (readStatus, readBody) = try await fixture.phone.call(
                "GET", "/jev", token: paired.token
            )
            #expect(readStatus == 200)
            let status = try JSONDecoder().decode(ControlAPI.JevStatus.self, from: readBody)
            #expect(status.model == "jev-1.13.0")
            #expect(status.features.count == 8)
            // Whatever else this route says, it never says the key.
            let text = String(decoding: readBody, as: UTF8.self)
            #expect(text.contains("\"keySet\""))
            #expect(!text.lowercased().contains("apikey"))
            #expect(!text.contains("sk-"))

            // But not set.
            let (writeStatus, writeBody) = try await fixture.phone.call(
                "POST", "/jev", token: paired.token, body: #"{"enabled":true}"#
            )
            #expect(writeStatus == 403)
            let refusal = try JSONDecoder().decode(ControlAPI.ErrorResponse.self, from: writeBody)
            #expect(refusal.error == ControlServer.jevWriteRefusal)
            // And nothing changed on the way to being refused.
            #expect(try await JSONDecoder().decode(
                ControlAPI.JevStatus.self,
                from: fixture.phone.call("GET", "/jev", token: paired.token).1
            ).enabled == false)

            // The Mac's own token may.
            let (accepted, updated) = try await fixture.local.call(
                "POST", "/jev", token: fixture.local.token,
                body: #"{"enabled":true,"model":"jev-latest"}"#
            )
            #expect(accepted == 200)
            let after = try JSONDecoder().decode(ControlAPI.JevStatus.self, from: updated)
            #expect(after.enabled && after.model == "jev-latest")
        }
    }

    /// Pairing cannot be scope-gated: it is unauthenticated, and a phone asking to be given
    /// more than chat still has its old token in the header while it asks.
    @Test func aChatOnlyDeviceCanPairAgainForFullControl() async throws {
        try await withServer { fixture in
            let chatOnly = try await fixture.pair(scope: .chat)
            #expect(try await fixture.phone.status(
                "POST", "/load", token: chatOnly.token, body: "{}"
            ) == 403)

            let invitation = await fixture.registry.invite(
                host: "127.0.0.1", port: fixture.phone.port, scope: .full
            )
            // Sent with the chat token still attached, which is what a phone would do.
            let (status, body) = try await fixture.phone.call(
                "POST", "/buddy/pair", token: chatOnly.token,
                body: #"{"code":"\#(invitation.code)","deviceName":"Phone","platform":"android"}"#
            )
            #expect(status == 200)
            let upgraded = try JSONDecoder().decode(ControlAPI.BuddyPairResponse.self, from: body)
            #expect(upgraded.scope == "full")
            #expect(try await fixture.phone.status(
                "POST", "/video/queue/control", token: upgraded.token,
                body: #"{"action":"pause"}"#
            ) == 200)
        }
    }

    // MARK: - The second listener

    @Test func onlyTailnetAndLoopbackAddressesMayBeBound() {
        for allowed in ["100.64.0.1", "100.100.100.100", "100.127.255.255", "127.0.0.1"] {
            #expect(ControlServer.isBindableTailnetAddress(allowed))
        }
        // The wildcard above all: binding it is exactly how a private API becomes public.
        // The hostname shapes matter just as much — `NWEndpoint.Host` would take them as
        // names and resolve them, handing the bind target to whoever runs that zone.
        for refused in [
            "0.0.0.0", "::", "::1", "", " ", "192.168.1.10", "10.0.0.5", "100.128.0.1",
            "100.63.255.255", "99.64.0.1", "127.0.0.1.1", "localhost", "100.64.0.1:8788",
            "100.64.0.1.evil.example.com", "evil.example.com/100.64.0.1", "100.64.0.1%en0",
            "127.0.0.1.attacker.test", "0100.64.0.1", "100.064.0.1", "100.64.0.01",
        ] {
            #expect(!ControlServer.isBindableTailnetAddress(refused), "\(refused) must be refused")
        }
    }

    @Test func theSecondListenerClosesOnDemandAndRebindsWhenTheAddressMoves() async throws {
        try await withServer { fixture in
            await #expect(throws: ControlServer.TailnetBindError.self) {
                try await fixture.server.setTailnetAccess(address: "0.0.0.0")
            }

            // Same routes, a different way in — but not the same credentials. The control
            // token is this Mac's own and is refused out here; a paired device's works.
            #expect(try await fixture.phone.status("GET", "/health", token: nil) == 200)
            #expect(try await fixture.phone.status(
                "GET", "/status", token: fixture.local.token
            ) == 401)
            let paired = try await fixture.pair(name: "Onward")
            #expect(try await fixture.phone.status("GET", "/status", token: paired.token) == 200)
            #expect(try await fixture.phone.status("GET", "/status", token: nil) == 401)

            // A tailscale address can move under the app; the listener has to follow.
            let moved = try await fixture.reopenTailnetListener()
            #expect(moved != fixture.phone.port)
            let onward = TestClient(port: moved, token: fixture.local.token, session: fixture.session)
            #expect(try await onward.status("GET", "/health", token: nil) == 200)
            await #expect(throws: (any Error).self) {
                _ = try await fixture.phone.status("GET", "/health", token: nil)
            }

            try await fixture.server.setTailnetAccess(address: nil)
            #expect(await fixture.server.tailnetListenerAddress == nil)
            await #expect(throws: (any Error).self) {
                _ = try await onward.status("GET", "/health", token: nil)
            }
            // Loopback is untouched throughout.
            #expect(try await fixture.local.status(
                "GET", "/status", token: fixture.local.token
            ) == 200)
        }
    }

    /// A tailscale address can move under the app — a re-auth, a different tailnet. A
    /// listener still bound to yesterday's endpoint is a feature that silently stopped.
    @Test func aChangedEndpointRebindsRatherThanBeingIgnored() async throws {
        try await withServer { fixture in
            let first = fixture.phone.port
            // Asked of the kernel rather than guessed: this test allows no retry, so a port
            // that happened to be busy would look exactly like a listener that did not move.
            let second = try await Self.freeLoopbackPort()

            // Asked for directly, with no retry loop to paper over a listener that stayed
            // where it was: this must rebind on the first attempt or not at all.
            try await fixture.server.setTailnetAccess(address: "127.0.0.1", port: second)
            try await waitUntil { await BuddyControlTests.reachable(port: second) }
            await #expect(throws: (any Error).self) {
                _ = try await fixture.phone.status("GET", "/health", token: nil)
            }
        }
    }

    // MARK: - Request framing and size

    @Test func aDeviceMaySendAPromptButNotAModel() async throws {
        try await withServer { fixture in
            let paired = try await fixture.pair()
            let huge = String(repeating: "a", count: BuddyLimits.requestBodyBytes + 1024)
            let body = #"{"messages":[{"role":"user","content":"\#(huge)","images":[]}]}"#
            #expect(try await fixture.phone.status(
                "POST", "/chat", token: paired.token, body: body
            ) == 413)
            // The Mac's own bridge keeps the ceiling it had.
            #expect(try await fixture.local.status(
                "POST", "/chat", token: fixture.local.token, body: body
            ) != 413)
        }
    }

    /// `/buddy/pair` is the one route whose throttle cannot run until the body is read, so
    /// the body has to be small before anything else is true about it.
    @Test func anUnauthenticatedTailnetBodyIsCappedFarBelowADevices() async throws {
        try await withServer { fixture in
            await fixture.registry.invite(host: "127.0.0.1", port: fixture.phone.port)
            let padding = String(repeating: "a", count: BuddyLimits.unauthenticatedBodyBytes)
            let refused = try await fixture.phone.status(
                "POST", "/buddy/pair", token: nil,
                body: #"{"code":"000000","deviceName":"\#(padding)","platform":"android"}"#
            )
            #expect(refused == 413)
            // The code survives, because nothing ever looked at it.
            #expect(await fixture.registry.openInvitation() != nil)

            // A paired device's ceiling is much higher, and the same body gets through it.
            let paired = try await fixture.pair()
            let accepted = try await fixture.phone.status(
                "POST", "/chat", token: paired.token,
                body: #"{"messages":[{"role":"user","content":"\#(padding)","images":[]}]}"#
            )
            #expect(accepted == 200)
        }
    }

    @Test func aChunkedBodyIsAnsweredRatherThanDropped() async throws {
        try await withServer { fixture in
            let raw = try await RawConnection.connect(port: fixture.local.port)
            defer { raw.close() }
            try await raw.send(
                "POST /chat HTTP/1.1\r\nHost: 127.0.0.1\r\n"
                    + "Authorization: Bearer \(fixture.local.token)\r\n"
                    + "Transfer-Encoding: chunked\r\n\r\n0\r\n\r\n"
            )
            let reply = try await raw.readSome()
            #expect(reply.contains("411"))
            #expect(reply.contains("Content-Length"))
        }
    }

    // MARK: - Streaming chat

    @Test func chatStreamSendsTokensThenMetrics() async throws {
        try await withServer(tokens: ["Hel", "lo", " there"]) { fixture in
            let events = try await fixture.local.events(
                "POST", "/chat/stream", token: fixture.local.token,
                body: #"{"messages":[{"role":"user","content":"hi","images":[]}]}"#
            ) { $0.contains { $0.name == "finished" } }

            #expect(events.filter { $0.name == "token" }.map(\.data) == [
                #"{"text":"Hel"}"#, #"{"text":"lo"}"#, #"{"text":" there"}"#,
            ])
            let finished = try #require(events.first { $0.name == "finished" })
            let metrics = try JSONDecoder().decode(
                ControlAPI.ChatMetrics.self, from: Data(finished.data.utf8)
            )
            #expect(metrics.generatedTokens == 3 && metrics.promptTokens == 7)
        }
    }

    /// Nothing is written until the host agrees to start, so a refusal is a status a phone
    /// can act on rather than a 200 whose first frame contradicts it.
    @Test func aRefusalBeforeTheFirstFrameIsAStatusNotAnEvent() async throws {
        try await withServer(failing: true) { fixture in
            let (status, body) = try await fixture.local.call(
                "POST", "/chat/stream", token: fixture.local.token,
                body: #"{"messages":[{"role":"user","content":"hi","images":[]}]}"#
            )
            #expect(status == 400)
            #expect(String(decoding: body, as: UTF8.self).contains("No model is loaded."))

            let missing = try await fixture.local.status(
                "POST", "/conversations/\(UUID().uuidString)/messages",
                token: fixture.local.token, body: #"{"content":"hi","images":[]}"#
            )
            #expect(missing == 404)
        }
    }

    @Test func aSecondMessageIntoAConversationStillAnsweringIsRefused() async throws {
        try await withServer(tokens: (0..<200).map { "t\($0)" }, pace: .milliseconds(20)) {
            fixture in
            let summary = try await fixture.createConversation()
            let first = Task {
                _ = try await fixture.local.events(
                    "POST", "/conversations/\(summary.id)/messages",
                    token: fixture.local.token, body: #"{"content":"hi","images":[]}"#
                ) { $0.count >= 300 }
            }
            defer { first.cancel() }
            try await waitUntil { await fixture.host.emitted >= 2 }

            let busy = try await fixture.local.status(
                "POST", "/conversations/\(summary.id)/messages",
                token: fixture.local.token, body: #"{"content":"and another"}"#
            )
            #expect(busy == 409)
        }
    }

    @Test func aClientWalkingAwayCancelsTheGenerationAndFreesTheSlot() async throws {
        try await withServer(tokens: (0..<200).map { "t\($0)" }, pace: .milliseconds(20)) {
            fixture in
            let reading = Task {
                _ = try await fixture.local.events(
                    "POST", "/chat/stream", token: fixture.local.token,
                    body: #"{"messages":[{"role":"user","content":"hi","images":[]}]}"#
                ) { $0.count >= 2 }
                // Never reached: this stream has 200 tokens to go.
                try await Task.sleep(for: .seconds(30))
            }
            try await waitUntil { await fixture.host.startedStreams == 1 }
            try await waitUntil { await fixture.host.emitted >= 2 }
            reading.cancel()
            _ = try? await reading.value

            // The upstream generation stops, rather than talking to a dead socket.
            try await waitUntil { await fixture.host.cancelledStreams == 1 }
            try await waitUntil { await fixture.server.openEventStreams == 0 }
        }
    }

    /// The case that leaks: a client that stops reading without closing. The socket buffer
    /// fills, the send never completes and never errors, and without a deadline the slot is
    /// held until the app quits.
    @Test func aClientThatStopsReadingIsReapedRatherThanHeldForever() async throws {
        let hub = BuddyEventHub()
        try await withServer(hub: hub, writeDeadline: .milliseconds(400)) { fixture in
            let raw = try await RawConnection.connect(port: fixture.local.port)
            defer { raw.close() }
            try await raw.send(
                "GET /events HTTP/1.1\r\nHost: 127.0.0.1\r\n"
                    + "Authorization: Bearer \(fixture.local.token)\r\n\r\n"
            )
            try await waitUntil { await fixture.server.openEventStreams == 1 }

            // Enough to overflow any socket buffer while nothing on the far side reads.
            let padding = String(repeating: "x", count: 262_144)
            let filling = Task {
                while !Task.isCancelled {
                    await hub.post(.download(.init(
                        id: "big", name: padding, fraction: 0.5,
                        bytesReceived: 1, bytesExpected: 2, bytesPerSecond: 3
                    )))
                    try? await Task.sleep(for: .milliseconds(20))
                }
            }
            defer { filling.cancel() }

            try await waitUntil(15) { await fixture.server.openEventStreams == 0 }
        }
    }

    @Test func onlySoManyStreamsAtOnce() async throws {
        try await withServer(tokens: []) { fixture in
            var held: [StreamHandle] = []
            defer { held.forEach { $0.cancel() } }
            for _ in 0..<ControlServer.maximumEventStreams {
                held.append(try await fixture.local.openEventStream())
            }
            // Every slot is taken, so the next phone is told to close one rather than
            // being quietly starved of a socket the MCP bridge also needs.
            #expect(try await fixture.local.status(
                "GET", "/events", token: fixture.local.token
            ) == 429)

            held.removeLast().cancel()
            try await waitUntil {
                await fixture.server.openEventStreams < ControlServer.maximumEventStreams
            }
            held.append(try await fixture.local.openEventStream())
        }
    }

    // MARK: - The /events stream

    @Test func theEventStreamOpensWithAHeartbeatAndForwardsWhatTheAppPosts() async throws {
        let hub = BuddyEventHub()
        try await withServer(hub: hub) { fixture in
            let posting = Task {
                // Posted repeatedly: the subscription is established inside the server, so
                // there is no moment this side can wait for other than the first frame.
                while !Task.isCancelled {
                    await hub.post(.download(.init(
                        id: "qwen3-coder", name: "Qwen3-Coder", fraction: 0.5,
                        bytesReceived: 512, bytesExpected: 1024, bytesPerSecond: 128
                    )))
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
            defer { posting.cancel() }

            let events = try await fixture.local.events(
                "GET", "/events", token: fixture.local.token, body: nil
            ) { $0.contains { $0.name == "download" } }
            #expect(events.first?.name == "heartbeat")
            let beat = try JSONDecoder().decode(
                ControlAPI.HeartbeatEvent.self, from: Data(events[0].data.utf8)
            )
            #expect(ControlAPI.date(fromTimestamp: beat.at) != nil)

            let download = try #require(events.first { $0.name == "download" })
            let decoded = try JSONDecoder().decode(
                ControlAPI.DownloadEvent.self, from: Data(download.data.utf8)
            )
            #expect(decoded.id == "qwen3-coder" && decoded.fraction == 0.5)
            // The host is asked to start watching exactly when someone starts reading.
            #expect(await fixture.host.eventUpdatesRequested >= 1)
        }
    }

    /// Revoking has to reach what a device is already holding. Waiting for its next request
    /// would leave an SSE subscription alive for as long as the phone cared to keep it.
    @Test func revokingADeviceEndsTheStreamItIsHolding() async throws {
        try await withServer { fixture in
            let paired = try await fixture.pair()
            let stream = try await fixture.phone.openEventStream(token: paired.token)
            try await waitUntil { await fixture.server.openEventStreams == 1 }

            #expect(try await fixture.local.status(
                "DELETE", "/buddy/devices/\(paired.deviceID)", token: fixture.local.token
            ) == 200)
            try await waitUntil { await fixture.server.openEventStreams == 0 }
            stream.cancel()
        }
    }

    @Test func turningTheToggleOffEndsEveryStream() async throws {
        try await withServer { fixture in
            let paired = try await fixture.pair()
            let stream = try await fixture.phone.openEventStream(token: paired.token)
            try await waitUntil { await fixture.server.openEventStreams == 1 }

            await fixture.registry.setAllowsTailnetDevices(false)
            try await waitUntil { await fixture.server.openEventStreams == 0 }
            stream.cancel()
        }
    }

    @Test func theEventStreamNeedsATokenLikeEverythingElse() async throws {
        try await withServer { fixture in
            let refused = try await fixture.local.status("GET", "/events", token: nil)
            #expect(refused == 401)
        }
    }

    // MARK: - Conversations

    @Test func conversationsAreListedCreatedReadAndRepliedTo() async throws {
        try await withServer(tokens: ["Yes", "."]) { fixture in
            let summary = try await fixture.createConversation(title: "Trip plan")
            #expect(summary.title == "Trip plan" && summary.messageCount == 0)

            let (_, listed) = try await fixture.local.call(
                "GET", "/conversations", token: fixture.local.token
            )
            let list = try JSONDecoder().decode(
                [ControlAPI.ConversationSummary].self, from: listed
            )
            #expect(list.map(\.id) == [summary.id])

            let events = try await fixture.local.events(
                "POST", "/conversations/\(summary.id)/messages", token: fixture.local.token,
                body: #"{"content":"Are we going?","images":[]}"#
            ) { $0.contains { $0.name == "finished" } }
            #expect(events.filter { $0.name == "token" }.count == 2)

            let (detailStatus, detail) = try await fixture.local.call(
                "GET", "/conversations/\(summary.id)", token: fixture.local.token
            )
            #expect(detailStatus == 200)
            let conversation = try JSONDecoder().decode(
                ControlAPI.ConversationDetail.self, from: detail
            )
            #expect(conversation.messages.map(\.role) == ["user", "assistant"])
            #expect(conversation.messages.last?.content == "Yes.")
            #expect(!conversation.isGenerating)
            // Images are never sent back, however they arrived.
            #expect(!String(decoding: detail, as: UTF8.self).contains("images"))

            #expect(try await fixture.local.status(
                "GET", "/conversations/\(UUID().uuidString)", token: fixture.local.token
            ) == 404)
            #expect(try await fixture.local.status("GET", "/conversations", token: nil) == 401)
        }
    }

    // MARK: - Fixture

    struct Fixture {
        let server: ControlServer
        /// The loopback listener — the MCP bridge's way in, and the control token's.
        let local: TestClient
        /// The stand-in for the tailnet listener, on loopback at its own port.
        let phone: TestClient
        let registry: BuddyRegistry
        let host: BuddyTestHost
        let session: URLSession

        func pair(
            name: String = "Galaxy S24 Ultra", platform: String = "android",
            scope: BuddyScope = .full
        ) async throws -> ControlAPI.BuddyPairResponse {
            let invitation = await registry.invite(
                host: "127.0.0.1", port: phone.port, scope: scope
            )
            let (status, body) = try await phone.call(
                "POST", "/buddy/pair", token: nil,
                body: #"{"code":"\#(invitation.code)","deviceName":"\#(name)","platform":"\#(platform)"}"#
            )
            #expect(status == 200)
            return try JSONDecoder().decode(ControlAPI.BuddyPairResponse.self, from: body)
        }

        func createConversation(title: String = "Fixture") async throws
            -> ControlAPI.ConversationSummary {
            let (status, body) = try await local.call(
                "POST", "/conversations", token: local.token, body: #"{"title":"\#(title)"}"#
            )
            #expect(status == 200)
            return try JSONDecoder().decode(ControlAPI.ConversationSummary.self, from: body)
        }

        /// Moves the second listener to a different port, as a changed tailscale address
        /// would, and returns where it landed.
        func reopenTailnetListener() async throws -> Int {
            try await BuddyControlTests.bindTailnetListener(on: server, avoiding: phone.port)
        }
    }

    private func waitUntil(
        _ seconds: Double = 5, _ condition: @Sendable () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw BuddyTestError.timeout }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Binds the second listener on loopback at a port nobody is using.
    ///
    /// Kernel-assigned rather than guessed from a range: a guess can land on the primary
    /// listener's own port — where `SO_REUSEPORT` makes both binds succeed and the two
    /// listeners then share the connections — or on a port another suite in this process
    /// is about to want.
    static func bindTailnetListener(on server: ControlServer, avoiding: Int? = nil) async throws -> Int {
        for _ in 0..<16 {
            let candidate = try await freeLoopbackPort()
            guard candidate != avoiding else { continue }
            try await server.setTailnetAccess(address: "127.0.0.1", port: candidate)
            for _ in 0..<50 {
                if await server.tailnetError != nil { break }
                if await server.tailnetListenerAddress != nil,
                   await reachable(port: candidate) { return candidate }
                try await Task.sleep(for: .milliseconds(20))
            }
            try await server.setTailnetAccess(address: nil)
        }
        throw BuddyTestError.timeout
    }

    /// A port nobody is on. Binding and letting go is the portable way to ask, and the
    /// window in between is not one any test here can lose to.
    static func freeLoopbackPort() async throws -> Int {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: .any)
        listener.newConnectionHandler = { $0.cancel() }
        listener.start(queue: .global(qos: .userInitiated))
        defer { listener.cancel() }
        let deadline = ContinuousClock.now + .seconds(5)
        while true {
            if case .ready = listener.state, let port = listener.port {
                return Int(port.rawValue)
            }
            guard ContinuousClock.now < deadline else { throw BuddyTestError.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    static func reachable(port: Int) async -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!)
        request.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: request) else {
            return false
        }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    private func withServer(
        tokens: [String] = ["ok"], pace: Duration = .milliseconds(1), failing: Bool = false,
        hub: BuddyEventHub = BuddyEventHub(),
        writeDeadline: Duration = ControlServer.defaultEventWriteDeadline,
        _ body: (Fixture) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("buddy-control-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let handshakeURL = directory.appendingPathComponent("control.json")
        let registry = BuddyRegistry(url: directory.appendingPathComponent("buddy.json"))
        let host = BuddyTestHost(tokens: tokens, pace: pace, failing: failing)
        let server = ControlServer(
            host: host, handshakeURL: handshakeURL, buddy: registry, events: hub,
            eventWriteDeadline: writeDeadline,
            // Never the real CLI: a test must not bind whatever tailnet this machine is on.
            discoverTailnetAddress: { nil }
        )

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 64
        configuration.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        try await server.start()
        defer { Task { await server.stop() } }
        try await waitUntil { FileManager.default.fileExists(atPath: handshakeURL.path) }
        let handshake = try JSONDecoder().decode(
            ControlAPI.Handshake.self, from: try Data(contentsOf: handshakeURL)
        )
        await registry.setAllowsTailnetDevices(true)
        let tailnetPort = try await Self.bindTailnetListener(on: server)

        try await body(Fixture(
            server: server,
            local: TestClient(port: handshake.port, token: handshake.token, session: session),
            phone: TestClient(port: tailnetPort, token: handshake.token, session: session),
            registry: registry, host: host, session: session
        ))
        await server.stop()
    }
}

enum BuddyTestError: Error, LocalizedError {
    case timeout, noModelLoaded, unexpectedRoute

    var errorDescription: String? {
        switch self {
        case .timeout: "The fixture timed out."
        case .noModelLoaded: "No model is loaded."
        case .unexpectedRoute: "Unexpected test route."
        }
    }
}

// MARK: - A client that can read a stream

struct TestClient: Sendable {
    let port: Int
    let token: String
    let session: URLSession

    func request(_ method: String, _ path: String, token: String?, body: String?) -> URLRequest {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = method
        request.httpBody = body.map { Data($0.utf8) }
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    func call(
        _ method: String, _ path: String, token: String?, body: String? = nil
    ) async throws -> (Int, Data) {
        let (data, response) = try await session.data(
            for: request(method, path, token: token, body: body)
        )
        return (try #require((response as? HTTPURLResponse)?.statusCode), data)
    }

    func status(
        _ method: String, _ path: String, token: String?, body: String? = nil
    ) async throws -> Int {
        try await call(method, path, token: token, body: body).0
    }

    struct Frame: Sendable, Equatable {
        var name: String
        var data: String
    }

    /// Reads SSE frames until `stop` has seen enough.
    func events(
        _ method: String, _ path: String, token: String?, body: String?,
        until stop: @Sendable ([Frame]) -> Bool
    ) async throws -> [Frame] {
        let (bytes, response) = try await session.bytes(
            for: request(method, path, token: token, body: body)
        )
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        var frames: [Frame] = []
        var name = ""
        for try await line in bytes.lines {
            if line.hasPrefix("event: ") {
                name = String(line.dropFirst("event: ".count))
            } else if line.hasPrefix("data: ") {
                frames.append(Frame(name: name, data: String(line.dropFirst("data: ".count))))
                if stop(frames) { break }
            }
        }
        return frames
    }

    /// Opens an `/events` stream and holds it, returning once the server has actually
    /// accepted it — which is what the first heartbeat proves.
    func openEventStream(token: String? = nil) async throws -> StreamHandle {
        let bearer = token ?? self.token
        let ready = Ready()
        let task = Task {
            let (bytes, response) = try await session.bytes(
                for: request("GET", "/events", token: bearer, body: nil)
            )
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw BuddyTestError.unexpectedRoute
            }
            for try await line in bytes.lines where line.hasPrefix("data: ") {
                await ready.signal()
            }
        }
        do {
            try await ready.wait()
        } catch {
            task.cancel()
            throw error
        }
        return StreamHandle(task: task)
    }
}

struct StreamHandle {
    let task: Task<Void, any Error>
    func cancel() { task.cancel() }
}

/// One-shot readiness, because a held-open stream has no return value to wait on.
actor Ready {
    private var signalled = false

    func signal() { signalled = true }

    func wait() async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !signalled {
            guard ContinuousClock.now < deadline else { throw BuddyTestError.timeout }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

/// A socket that speaks HTTP and then stops listening — which `URLSession` will not do, and
/// which is exactly the client the write deadline exists for.
final class RawConnection: @unchecked Sendable {
    private let connection: NWConnection

    private init(connection: NWConnection) { self.connection = connection }

    static func connect(port: Int) async throws -> RawConnection {
        let connection = NWConnection(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: UInt16(port))!,
            using: .tcp
        )
        connection.start(queue: .global(qos: .userInitiated))
        let deadline = ContinuousClock.now + .seconds(5)
        while true {
            if case .ready = connection.state { break }
            guard ContinuousClock.now < deadline else {
                connection.cancel()
                throw BuddyTestError.timeout
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        return RawConnection(connection: connection)
    }

    func send(_ text: String) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: Data(text.utf8), completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    func readSome() async throws -> String {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<String, any Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) {
                data, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: String(decoding: data ?? Data(), as: UTF8.self))
                }
            }
        }
    }

    func close() { connection.cancel() }
}

// MARK: - The host double

/// A `ControlHost` with a scripted model and an in-memory conversation store. It counts the
/// streams it starts and the ones that were cancelled out from under it, which is how the
/// disconnect test proves the generation actually stopped.
actor BuddyTestHost: ControlHost {

    private let tokens: [String]
    private let pace: Duration
    private let failing: Bool
    private(set) var startedStreams = 0
    private(set) var cancelledStreams = 0
    private(set) var emitted = 0
    private(set) var eventUpdatesRequested = 0
    private var stored: [ControlAPI.ConversationDetail] = []
    private var answering: Set<String> = []
    /// Where `GET /swarm` gets its exposure block, when a test cares. The app reads it off
    /// the control server; a double has to be handed the same thing to read.
    private var exposureSource: (@Sendable () async -> ControlAPI.SwarmView.Exposure?)?

    func reportExposure(
        from source: @escaping @Sendable () async -> ControlAPI.SwarmView.Exposure?
    ) {
        exposureSource = source
    }

    init(tokens: [String], pace: Duration, failing: Bool) {
        self.tokens = tokens
        self.pace = pace
        self.failing = failing
    }

    private func noteCancelled() { cancelledStreams += 1 }
    private func noteEmitted() { emitted += 1 }
    private func finishAnswering(_ id: String?) {
        guard let id else { return }
        answering.remove(id)
    }

    private func scripted(
        appendingTo conversation: String? = nil
    ) throws -> AsyncThrowingStream<ControlAPI.ChatStreamEvent, any Error> {
        guard !failing else { throw BuddyTestError.noModelLoaded }
        startedStreams += 1
        if let conversation { answering.insert(conversation) }
        let tokens = self.tokens
        let pace = self.pace
        return AsyncThrowingStream { continuation in
            let work = Task {
                defer { Task { await self.finishAnswering(conversation) } }
                do {
                    for token in tokens {
                        try await Task.sleep(for: pace)
                        await self.noteEmitted()
                        if let conversation {
                            await self.append(token, to: conversation)
                        }
                        continuation.yield(.token(token))
                    }
                    continuation.yield(.finished(.init(
                        promptTokens: 7, generatedTokens: tokens.count,
                        tokensPerSecond: 12.5, timeToFirstToken: 0.25
                    )))
                    continuation.finish()
                } catch {
                    await self.noteCancelled()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    private func append(_ token: String, to id: String) {
        guard let index = stored.firstIndex(where: { $0.id == id }),
              let last = stored[index].messages.indices.last
        else { return }
        stored[index].messages[last].content += token
    }

    func chatStream(
        _ request: ControlAPI.ChatRequest
    ) async throws -> AsyncThrowingStream<ControlAPI.ChatStreamEvent, any Error> {
        try scripted()
    }

    func conversationList() async -> [ControlAPI.ConversationSummary] {
        stored.map {
            .init(id: $0.id, title: $0.title, updatedAt: $0.updatedAt,
                  messageCount: $0.messages.count)
        }
    }

    func createConversation(title: String?) async -> ControlAPI.ConversationSummary {
        let conversation = ControlAPI.ConversationDetail(
            id: UUID().uuidString, title: title ?? "New Conversation",
            updatedAt: ControlAPI.timestamp(Date()), messages: []
        )
        stored.append(conversation)
        return .init(id: conversation.id, title: conversation.title,
                     updatedAt: conversation.updatedAt, messageCount: 0)
    }

    func conversation(id: String) async throws -> ControlAPI.ConversationDetail {
        guard var found = stored.first(where: { $0.id == id }) else {
            throw BuddyHostError.noSuchConversation(id)
        }
        found.isGenerating = answering.contains(id)
        return found
    }

    func replyInConversation(
        id: String, to message: ControlAPI.NewMessageRequest
    ) async throws -> AsyncThrowingStream<ControlAPI.ChatStreamEvent, any Error> {
        guard let index = stored.firstIndex(where: { $0.id == id }) else {
            throw BuddyHostError.noSuchConversation(id)
        }
        guard !answering.contains(id) else { throw BuddyHostError.conversationBusy(id) }
        let now = ControlAPI.timestamp(Date())
        stored[index].messages.append(
            .init(role: "user", content: message.content, createdAt: now)
        )
        stored[index].messages.append(.init(role: "assistant", content: "", createdAt: now))
        return try scripted(appendingTo: id)
    }

    func beginEventUpdates(postingTo hub: BuddyEventHub) async { eventUpdatesRequested += 1 }

    func status() async -> ControlAPI.Status {
        .init(state: "idle", loadedModelID: nil, loadedModelName: nil, contextLength: nil,
              expertStreaming: false, lastGenerationTokensPerSecond: nil)
    }
    func installed() async -> [ControlAPI.InstalledModel] { [] }
    func catalog(category: String?, onlyRunnable: Bool) async -> [ControlAPI.CatalogModel] { [] }
    func recommend(category: String?) async -> ControlAPI.CatalogModel? { nil }
    func unload() async {}
    func videoModels() async -> [ControlAPI.VideoModel] { [] }
    func imageModels() async -> [ControlAPI.ImageModel] { [] }
    func meshModels() async -> [ControlAPI.MeshModel] { [] }
    func videoQueue() async -> ControlAPI.VideoQueueView {
        .init(paused: false, activeID: nil, message: nil, items: [])
    }
    func controlVideoQueue(
        _ request: ControlAPI.VideoQueueControl
    ) async throws -> ControlAPI.VideoQueueView {
        await videoQueue()
    }
    func swarm() async -> ControlAPI.SwarmView {
        .init(peers: [], polledSecondsAgo: nil, exposure: await exposureSource?())
    }
    func profile() async -> ControlAPI.Profile { fatalError("Unexpected test route") }
    func metrics() async -> ControlAPI.Metrics { fatalError("Unexpected test route") }
    /// Answered rather than trapped: `/v1/node` is one of the routes a chat-only device
    /// may reach, so the scope test actually calls it.
    func nodeAdvertisement() async -> ControlAPI.NodeAdvertisement {
        .init(
            name: "Fixture", platform: "macos-apple-silicon",
            profile: .init(chip: "Apple M3 Max", memoryGB: 38.7,
                           bandwidthGBps: 300, gpuCores: 40),
            capabilities: [],
            metrics: .init(queueDepth: 0, headroomGB: 8.9, gpuUtilPct: 0, memoryUsedPct: 0)
        )
    }
    func plan(_ request: ControlAPI.PlanRequest) async throws -> ControlAPI.Plan {
        throw BuddyTestError.unexpectedRoute
    }
    func install(_ request: ControlAPI.LoadRequest) async throws -> String {
        throw BuddyTestError.unexpectedRoute
    }
    func load(_ request: ControlAPI.LoadRequest) async throws -> ControlAPI.Status {
        throw BuddyTestError.unexpectedRoute
    }
    func chat(_ request: ControlAPI.ChatRequest) async throws -> ControlAPI.ChatResponse {
        .init(content: "ok", reasoning: nil, promptTokens: 1,
              generatedTokens: 1, tokensPerSecond: 1)
    }
    func decide(_ request: ControlAPI.DecideRequest) async throws -> ControlAPI.DecideResponse {
        throw BuddyTestError.unexpectedRoute
    }

    /// Answered rather than trapped: the scope test really calls both, and `POST /jev` has
    /// to get past the route before the control-token gate can refuse it.
    private var jev = ControlAPI.JevStatus.fixture()
    func jevStatus() async -> ControlAPI.JevStatus { jev }
    func updateJev(_ update: ControlAPI.JevUpdate) async throws -> ControlAPI.JevStatus {
        if let enabled = update.enabled { jev.enabled = enabled }
        if let model = update.model { jev.model = model }
        return jev
    }

    func benchmark() async throws -> ControlAPI.BenchmarkResult {
        throw BuddyTestError.unexpectedRoute
    }
    func planImage(_ request: ControlAPI.ImageRequest) async throws -> ControlAPI.ImagePlan {
        throw BuddyTestError.unexpectedRoute
    }
    func generateImage(
        _ request: ControlAPI.ImageRequest
    ) async throws -> ControlAPI.ImageResponse {
        throw BuddyTestError.unexpectedRoute
    }
    func planMesh(_ request: ControlAPI.MeshRequest) async throws -> ControlAPI.MeshPlan {
        throw BuddyTestError.unexpectedRoute
    }
    func generateMesh(_ request: ControlAPI.MeshRequest) async throws -> ControlAPI.MeshResponse {
        throw BuddyTestError.unexpectedRoute
    }
    func generateVideo(
        _ request: ControlAPI.VideoGenerateRequest
    ) async throws -> ControlAPI.VideoResponse {
        throw BuddyTestError.unexpectedRoute
    }
    func enqueueVideos(
        _ request: ControlAPI.VideoQueueRequest
    ) async throws -> ControlAPI.VideoQueueView {
        throw BuddyTestError.unexpectedRoute
    }
}
