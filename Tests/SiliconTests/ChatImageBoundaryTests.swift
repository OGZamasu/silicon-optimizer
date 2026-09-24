import Foundation
import Testing
@testable import SiliconControl
@testable import SiliconRuntime

/// Chat images are pictures carried inline, never addresses.
///
/// The llama-server this app bundles downloads an `http(s)` `image_url` — redirects
/// followed, credentials from the address used — so an image that is a URL makes this Mac
/// fetch whatever a caller names. A swarm node and a phone paired for chat only both reach
/// the chat routes, and neither is somebody this Mac should fetch for.
@Suite("Chat images at the control server")
@MainActor
struct ChatImageBoundaryTests {

    static let swarmSecret = "swarm-secret-for-the-chat-image-fixture"
    /// What llama-server would have fetched: the cloud metadata address, a loopback
    /// service, and a tailnet neighbour.
    static let addresses = [
        "http://169.254.169.254/latest/meta-data/",
        "https://127.0.0.1:8788/buddy/devices",
        "http://100.64.0.9:8000/v1/jobs",
    ]
    static let picture = "data:image/jpeg;base64,/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAA=="

    static func chat(images: [String]) -> String {
        let list = images.map { "\"\($0)\"" }.joined(separator: ",")
        return #"{"messages":[{"role":"user","content":"What is this?","images":[\#(list)]}]}"#
    }

    @Test func onlyAPictureCarriedInlineCountsAsAnImage() {
        #expect(ControlAPI.ChatImages.isInline(Self.picture))
        #expect(ControlAPI.ChatImages.isInline("DATA:image/PNG;BASE64,iVBORw0KGgo="))
        #expect(ControlAPI.ChatImages.isInline("data:image/webp;name=x.webp;base64,UklGRg=="))
        for address in Self.addresses {
            #expect(!ControlAPI.ChatImages.isInline(address), "\(address)")
        }
        for other in [
            "", "data:", "data:image/jpeg,raw-bytes", "data:text/html;base64,PGgxPg==",
            "file:///etc/passwd", "//169.254.169.254/x", " data:image/png;base64,AA",
            "data:image/png ;base64,AA",
            // A header that never ends is not a header.
            "data:image/png;" + String(repeating: "x", count: 300) + ";base64,AA",
        ] {
            #expect(!ControlAPI.ChatImages.isInline(other), "\(other)")
        }
    }

    @Test func aSwarmNodeCannotHaveThisMacFetchAnAddress() async throws {
        let host = BuddyTestHost(tokens: ["ok"], pace: .milliseconds(1), failing: false)
        try await withServer(host: host, swarmToken: Self.swarmSecret) {
            (fixture: AgentFixture) async throws in
            for address in Self.addresses {
                let (status, body) = try await fixture.local.call(
                    "POST", "/chat", token: Self.swarmSecret, body: Self.chat(images: [address])
                )
                #expect(status == 400)
                let refusal = try JSONDecoder().decode(ControlAPI.ErrorResponse.self, from: body)
                #expect(refusal.error == ControlAPI.ChatImages.notInline)
                #expect(try await fixture.local.status(
                    "POST", "/chat/stream", token: Self.swarmSecret,
                    body: Self.chat(images: [address])
                ) == 400)
            }
            // A picture beside an address does not carry the address through.
            #expect(try await fixture.local.status(
                "POST", "/chat", token: Self.swarmSecret,
                body: Self.chat(images: [Self.picture, Self.addresses[0]])
            ) == 400)
            #expect(await host.paidLanesOnChat.isEmpty, "the host was reached")
            #expect(await host.startedStreams == 0)

            // Inline pictures still answer.
            #expect(try await fixture.local.status(
                "POST", "/chat", token: Self.swarmSecret, body: Self.chat(images: [Self.picture])
            ) == 200)
        }
    }

    /// `POST /chat` used to skip the attachment limits the streams had: a node could send
    /// sixteen megabytes of images in one request.
    @Test func aSwarmNodeIsHeldToAPhonesAttachmentLimitsOnPlainChatToo() async throws {
        let host = BuddyTestHost(tokens: ["ok"], pace: .milliseconds(1), failing: false)
        try await withServer(host: host, swarmToken: Self.swarmSecret) {
            (fixture: AgentFixture) async throws in
            let many = Array(repeating: Self.picture, count: BuddyLimits.imagesPerMessage + 1)
            #expect(try await fixture.local.status(
                "POST", "/chat", token: Self.swarmSecret, body: Self.chat(images: many)
            ) == 400)
            let large = "data:image/png;base64,"
                + String(repeating: "A", count: BuddyLimits.imageCharacters)
            #expect(try await fixture.local.status(
                "POST", "/chat", token: Self.swarmSecret, body: Self.chat(images: [large])
            ) == 400)
            #expect(await host.paidLanesOnChat.isEmpty, "the host was reached")
        }
    }

    @Test func aPhonePairedForChatCannotEither() async throws {
        let host = BuddyTestHost(tokens: ["ok"], pace: .milliseconds(1), failing: false)
        try await withServer(host: host) { (fixture: AgentFixture) async throws in
            let chatOnly = try await fixture.pair(scope: .chat)
            let address = Self.addresses[0]
            #expect(try await fixture.phone.status(
                "POST", "/chat", token: chatOnly.token, body: Self.chat(images: [address])
            ) == 400)
            #expect(try await fixture.phone.status(
                "POST", "/chat/stream", token: chatOnly.token, body: Self.chat(images: [address])
            ) == 400)

            // Nor store one in a conversation, where every later turn would fetch it again.
            let (created, summary) = try await fixture.local.call(
                "POST", "/conversations", token: fixture.local.token, body: "{}"
            )
            #expect(created == 200)
            let id = try JSONDecoder().decode(ControlAPI.ConversationSummary.self, from: summary).id
            let (status, body) = try await fixture.phone.call(
                "POST", "/conversations/\(id)/messages", token: chatOnly.token,
                body: #"{"content":"What is this?","images":["\#(address)"]}"#
            )
            #expect(status == 400)
            let refusal = try JSONDecoder().decode(ControlAPI.ErrorResponse.self, from: body)
            #expect(refusal.error == ControlAPI.ChatImages.notInline)
            #expect(try await host.conversation(id: id).messages.isEmpty)
            #expect(await host.paidLanesOnChat.isEmpty, "the host was reached")
            #expect(await host.startedStreams == 0)
        }
    }

    /// The MCP bridge attaches files of up to ten megabytes as data URLs, past a phone's
    /// per-image cap. The Mac's own token keeps that, and loses only the addresses.
    @Test func theMacsOwnTokenKeepsLargePicturesButNotAddresses() async throws {
        let host = BuddyTestHost(tokens: ["ok"], pace: .milliseconds(1), failing: false)
        try await withServer(host: host) { (fixture: AgentFixture) async throws in
            #expect(try await fixture.local.status(
                "POST", "/chat", token: fixture.local.token,
                body: Self.chat(images: [Self.addresses[1]])
            ) == 400)
            let large = "data:image/png;base64,"
                + String(repeating: "A", count: 3 * BuddyLimits.imageCharacters)
            #expect(try await fixture.local.status(
                "POST", "/chat", token: fixture.local.token, body: Self.chat(images: [large])
            ) == 200)
        }
    }

    /// A conversation stored before the door was shut can still hold an address, and the
    /// whole history goes out again with every turn. The runtime is never handed one.
    @Test func anAddressAlreadyInAConversationNeverReachesTheRuntime() throws {
        let request = ChatRequest(messages: [
            ChatMessage(role: .user, content: "Earlier", images: [Self.addresses[0]]),
            ChatMessage(role: .assistant, content: "A tram."),
            ChatMessage(
                role: .user, content: "And this?", images: [Self.addresses[2], Self.picture]
            ),
        ])
        let encoded = try JSONEncoder().encode(WireChatRequest(request))
        let wire = String(decoding: encoded, as: UTF8.self)
        for address in Self.addresses {
            #expect(!wire.contains(address.replacingOccurrences(of: "/", with: "\\/")))
            #expect(!wire.contains(address))
        }
        #expect(wire.contains("image_url"))
        #expect(wire.contains("data:image\\/jpeg;base64"))
        // The message whose only image was an address goes out as the text it was.
        let decoded = try #require(
            try JSONSerialization.jsonObject(with: Data(wire.utf8)) as? [String: Any]
        )
        let messages = try #require(decoded["messages"] as? [[String: Any]])
        #expect(messages[0]["content"] as? String == "Earlier")
    }
}
