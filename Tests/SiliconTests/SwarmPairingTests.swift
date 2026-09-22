import Foundation
import Testing
@testable import SiliconControl
@testable import SiliconUI

@Suite("Swarm pairing pieces")
struct SwarmPairingPieceTests {

    @Test("client-token responses distinguish legacy absence from operational failure")
    func clientTokenResponseClassification() {
        let token = Data(#"{"token":" per-member "}"#.utf8)
        #expect(AppModel.classifyClientTokenResponse(status: 201, body: token)
            == .minted("per-member"))
        #expect(AppModel.classifyClientTokenResponse(status: 404, body: Data())
            == .unsupported)
        #expect(AppModel.classifyClientTokenResponse(status: 401, body: token) == .failed)
        #expect(AppModel.classifyClientTokenResponse(status: 500, body: token) == .failed)
        #expect(AppModel.classifyClientTokenResponse(status: 200, body: Data("{}".utf8))
            == .failed)
        #expect(AppModel.classifyClientTokenResponse(
            status: 200, body: Data(#"{"token":""}"#.utf8)
        ) == .failed)
    }

    @Test("codes are six digits, spaced")
    func codeShape() {
        for _ in 0..<50 {
            let code = SwarmPairing.makeCode()
            #expect(code.count == 7)
            let halves = code.split(separator: " ")
            #expect(halves.count == 2)
            #expect(halves.allSatisfy { $0.count == 3 && $0.allSatisfy(\.isNumber) })
        }
    }

    @Test("client names stay friendly single path components")
    func clientNameBoundary() {
        #expect(SwarmPairing.normalizedClientName("  Studio Mac  ") == "Studio Mac")
        #expect(SwarmPairing.normalizedClientName(String(repeating: "a", count: 80))?.count == 64)
        for invalid in ["", "   ", ".", "..", "../admin", "a/b", "a\\b", "%2e%2e", "x\ny"] {
            #expect(SwarmPairing.normalizedClientName(invalid) == nil)
        }
    }

    @Test("the tailscale CGNAT range and nothing else")
    func cidrCheck() {
        #expect(SwarmPairing.isTailnetIPv4("100.64.0.1"))
        #expect(SwarmPairing.isTailnetIPv4("100.118.191.121"))
        #expect(SwarmPairing.isTailnetIPv4("100.127.255.254"))
        #expect(!SwarmPairing.isTailnetIPv4("100.128.0.1"))
        #expect(!SwarmPairing.isTailnetIPv4("100.63.0.1"))
        #expect(!SwarmPairing.isTailnetIPv4("192.168.1.10"))
        #expect(!SwarmPairing.isTailnetIPv4("10.0.0.5"))
        #expect(!SwarmPairing.isTailnetIPv4("not an ip"))
    }

    @Test("tailscale status JSON becomes probe targets")
    func statusParsing() throws {
        let status = """
        {"BackendState": "Running", "Self": {"TailscaleIPs": ["100.100.10.5"]},
         "Peer": {
          "key1": {"HostName": "windows-node", "Online": true,
                   "TailscaleIPs": ["100.118.191.121", "fd7a::1"]},
          "key2": {"HostName": "sams-mac", "Online": false,
                   "TailscaleIPs": ["100.90.10.2"]},
          "key3": {"HostName": "no-v4", "Online": true, "TailscaleIPs": ["fd7a::2"]}
        }}
        """
        let peers = SwarmPairing.peers(inStatusJSON: Data(status.utf8))
        #expect(SwarmPairing.localIPv4(inStatusJSON: Data(status.utf8)) == "100.100.10.5")
        #expect(peers.count == 2)
        #expect(peers[0].hostName == "sams-mac")
        #expect(peers[0].online == false)
        #expect(peers[1].ip == "100.118.191.121")
        #expect(peers[1].online == true)

        let stopped = Data(status.replacingOccurrences(
            of: "\"Running\"", with: "\"Stopped\""
        ).utf8)
        #expect(SwarmPairing.localIPv4(inStatusJSON: stopped) == nil)
        #expect(SwarmPairing.peers(inStatusJSON: stopped).isEmpty)
    }

    @Test("a joiner adopts the swarm's token and unions peers")
    func configAdoption() {
        let mine = SwarmConfig(
            swarmToken: "old-local-token",
            peers: [SwarmPeer(name: "old-node", baseURL: "http://100.1.1.1:1")]
        )
        let received = SwarmConfig(
            swarmToken: "the-swarm-token",
            peers: [
                SwarmPeer(name: "silicon-node", baseURL: "http://100.118.191.121:8790"),
                SwarmPeer(name: "old-node", baseURL: "http://100.2.2.2:2"),
            ]
        )
        let merged = mine.adopting(received)
        #expect(merged.swarmToken == "the-swarm-token")
        #expect(merged.peers.count == 2)
        #expect(merged.peers.first { $0.name == "old-node" }?.baseURL
                == "http://100.2.2.2:2")
        #expect(merged.peers.contains { $0.name == "silicon-node" })
    }
}

@Suite("Swarm pairing end to end", .serialized)
struct SwarmPairingFlowTests {

    /// A port nobody is on, asked of the kernel rather than guessed: a number drawn from a
    /// range can land on one another suite in this process is using, and did.
    private func freePort() async throws -> Int {
        try await BuddyControlTests.freeLoopbackPort()
    }

    @Test("hello, knock, code, approve, deliver once")
    func approvedFlow() async throws {
        let release = SwarmConfig(
            swarmToken: nil,
            peers: [SwarmPeer(name: "silicon-node", baseURL: "http://100.118.191.121:8790",
                              token: "client-tok-abc")]
        )
        let server = PairingServer(hostName: "Owner Mac")
        let port = try await freePort()
        try await server.start(on: "127.0.0.1", port: port)
        defer { Task { await server.stop() } }
        try await Task.sleep(for: .milliseconds(300))

        let hello = try #require(await PairingClient.hello(host: "127.0.0.1", port: port))
        #expect(hello.name == "Owner Mac")
        #expect(hello.accepting)

        let receipt = try await PairingClient.requestJoin(
            host: "127.0.0.1", name: "Joiner Mac", port: port
        )
        #expect(receipt.code.count == 7)

        // While one request is pending, the door reads busy and a second knock bounces.
        let busyHello = await PairingClient.hello(host: "127.0.0.1", port: port)
        #expect(busyHello?.accepting == false)
        await #expect(throws: PairingClient.PairingError.self) {
            _ = try await PairingClient.requestJoin(
                host: "127.0.0.1", name: "Party Crasher", port: port
            )
        }

        let pendingBefore = await server.pending()
        #expect(pendingBefore?.name == "Joiner Mac")
        #expect(pendingBefore?.code == receipt.code)

        let waiting = try await PairingClient.status(
            host: "127.0.0.1", requestID: receipt.requestID, port: port
        )
        #expect(waiting.state == "pending")

        await server.approve(receipt.requestID, releasing: release)
        let approved = try await PairingClient.status(
            host: "127.0.0.1", requestID: receipt.requestID, port: port
        )
        #expect(approved.state == "approved")
        #expect(approved.swarm?.effectiveToken == nil)
        #expect(approved.swarm?.peers.first?.name == "silicon-node")
        #expect(approved.swarm?.peers.first?.token == "client-tok-abc")

        // The credentials cross the wire exactly once.
        let again = try await PairingClient.status(
            host: "127.0.0.1", requestID: receipt.requestID, port: port
        )
        #expect(again.state == "expired")
        #expect(again.swarm == nil)
        #expect(await server.wasDelivered())
    }

    @Test("a denied knock stays denied and frees the door")
    func deniedFlow() async throws {
        let server = PairingServer(hostName: "Owner")
        let port = try await freePort()
        try await server.start(on: "127.0.0.1", port: port)
        defer { Task { await server.stop() } }
        try await Task.sleep(for: .milliseconds(300))

        let receipt = try await PairingClient.requestJoin(
            host: "127.0.0.1", name: "Joiner", port: port
        )
        await server.deny(receipt.requestID)
        let status = try await PairingClient.status(
            host: "127.0.0.1", requestID: receipt.requestID, port: port
        )
        #expect(status.state == "denied")
        #expect(status.swarm == nil)

        // The slot is free again for the next request.
        let hello = await PairingClient.hello(host: "127.0.0.1", port: port)
        #expect(hello?.accepting == true)
    }

    @Test("a denied requester cannot hold the invite by never polling")
    func denialFreesSlotWithoutRequesterPoll() async throws {
        let server = PairingServer(hostName: "Owner")
        let port = try await freePort()
        try await server.start(on: "127.0.0.1", port: port)
        defer { Task { await server.stop() } }
        try await Task.sleep(for: .milliseconds(300))

        let deniedReceipt = try await PairingClient.requestJoin(
            host: "127.0.0.1", name: "Uncooperative Joiner", port: port
        )
        await server.deny(deniedReceipt.requestID)

        // The denied client has not polled, but the invitation is available again.
        let hello = await PairingClient.hello(host: "127.0.0.1", port: port)
        #expect(hello?.accepting == true)
        let nextReceipt = try await PairingClient.requestJoin(
            host: "127.0.0.1", name: "Next Joiner", port: port
        )
        #expect(await server.pending()?.name == "Next Joiner")

        // A late poll still tells the denied client what happened, without disturbing
        // the next client's pending request.
        let denied = try await PairingClient.status(
            host: "127.0.0.1", requestID: deniedReceipt.requestID, port: port
        )
        #expect(denied.state == "denied")
        let next = try await PairingClient.status(
            host: "127.0.0.1", requestID: nextReceipt.requestID, port: port
        )
        #expect(next.state == "pending")
    }

    @Test("stale requests expire on their own")
    func expiry() async throws {
        let server = PairingServer(hostName: "Owner", requestLifetime: 0.2)
        let port = try await freePort()
        try await server.start(on: "127.0.0.1", port: port)
        defer { Task { await server.stop() } }
        try await Task.sleep(for: .milliseconds(300))

        _ = try await PairingClient.requestJoin(
            host: "127.0.0.1", name: "Slowpoke", port: port
        )
        try await Task.sleep(for: .milliseconds(400))
        #expect(await server.pending() == nil)
        let hello = await PairingClient.hello(host: "127.0.0.1", port: port)
        #expect(hello?.accepting == true)
    }
}
@Suite("Per-peer bearer resolution")
struct SwarmBearerTests {

    @Test("client token wins for its peer; shared covers the rest; admin ops stay shared")
    func bearerResolution() {
        var config = SwarmConfig(
            swarmToken: "admin-secret",
            peers: [
                SwarmPeer(name: "silicon-node", baseURL: "http://n:1", token: "client-a"),
                SwarmPeer(name: "old-node", baseURL: "http://o:1"),
            ]
        )
        #expect(config.bearer(forPeer: "silicon-node") == "client-a")
        #expect(config.bearer(forPeer: "old-node") == "admin-secret")
        #expect(config.bearer(forPeer: "unknown") == "admin-secret")
        #expect(config.effectiveToken == "admin-secret")

        config.setToken("client-b", forPeer: "old-node")
        #expect(config.bearer(forPeer: "old-node") == "client-b")
        config.setToken(nil, forPeer: "old-node")
        #expect(config.bearer(forPeer: "old-node") == "admin-secret")
    }

    @Test("a joiner keeps their own admin token and adopts per-peer client tokens")
    func joinerAdoptionWithClientTokens() {
        let mine = SwarmConfig(swarmToken: "my-own-admin", peers: [])
        let received = SwarmConfig(
            swarmToken: nil,
            peers: [SwarmPeer(name: "silicon-node", baseURL: "http://n:1",
                              token: "minted-for-me")]
        )
        let merged = mine.adopting(received)
        #expect(merged.swarmToken == "my-own-admin")
        #expect(merged.bearer(forPeer: "silicon-node") == "minted-for-me")
    }

    @Test("per-peer tokens survive the config round-trip")
    func tokenCodable() throws {
        let config = SwarmConfig(
            swarmToken: "s",
            peers: [SwarmPeer(name: "n", baseURL: "http://n:1", token: "t-1")]
        )
        let data = try JSONEncoder().encode(config)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"token\":\"t-1\""))
        let back = try JSONDecoder().decode(SwarmConfig.self, from: data)
        #expect(back.peers.first?.token == "t-1")
    }
}

@Suite("Client token roles")
struct ClientTokenRoleTests {
    /// A node that reports the role it minted hands it back; an older node's silence
    /// leaves it nil, which is what makes the app re-mint until a node confirms admin.
    @Test func roleRidesTheMintResponse() {
        let withRole = Data(#"{"name":"mac","token":"tok-1","role":"admin"}"#.utf8)
        #expect(AppModel.classifyClientTokenResponse(status: 200, body: withRole)
                == .minted("tok-1", role: "admin"))
        let legacy = Data(#"{"name":"mac","token":"tok-2"}"#.utf8)
        #expect(AppModel.classifyClientTokenResponse(status: 200, body: legacy)
                == .minted("tok-2", role: nil))
    }

    @Test func roleIsRememberedWithTheTokenAndOptionalOnDisk() throws {
        var config = SwarmConfig(
            swarmToken: "s", peers: [SwarmPeer(name: "node", baseURL: "http://n:1")]
        )
        config.setToken("tok", forPeer: "node", role: "admin")
        #expect(config.peers[0].role == "admin")
        #expect(config.bearer(forPeer: "node") == "tok")

        // A swarm.json written before roles existed still loads.
        let legacy = Data(#"{"swarm_token":"s","peers":[{"name":"node","base_url":"http://n:1","token":"t"}]}"#.utf8)
        let decoded = try JSONDecoder().decode(SwarmConfig.self, from: legacy)
        #expect(decoded.peers[0].role == nil)
    }
}
