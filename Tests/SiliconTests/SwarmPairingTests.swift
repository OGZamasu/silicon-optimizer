import Foundation
import Testing
@testable import SiliconControl

@Suite("Swarm pairing pieces")
struct SwarmPairingPieceTests {

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
        {"Peer": {
          "key1": {"HostName": "windows-node", "Online": true,
                   "TailscaleIPs": ["100.118.191.121", "fd7a::1"]},
          "key2": {"HostName": "sams-mac", "Online": false,
                   "TailscaleIPs": ["100.90.10.2"]},
          "key3": {"HostName": "no-v4", "Online": true, "TailscaleIPs": ["fd7a::2"]}
        }}
        """
        let peers = SwarmPairing.peers(inStatusJSON: Data(status.utf8))
        #expect(peers.count == 2)
        #expect(peers[0].hostName == "sams-mac")
        #expect(peers[0].online == false)
        #expect(peers[1].ip == "100.118.191.121")
        #expect(peers[1].online == true)
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

    private func freePort() -> Int {
        Int.random(in: 22_000...58_000)
    }

    @Test("hello, knock, code, approve, deliver once")
    func approvedFlow() async throws {
        let release = SwarmConfig(
            swarmToken: "tok-123",
            peers: [SwarmPeer(name: "silicon-node", baseURL: "http://100.118.191.121:8790")]
        )
        let server = PairingServer(hostName: "Owner Mac", release: release)
        let port = freePort()
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

        await server.approve(receipt.requestID)
        let approved = try await PairingClient.status(
            host: "127.0.0.1", requestID: receipt.requestID, port: port
        )
        #expect(approved.state == "approved")
        #expect(approved.swarm?.effectiveToken == "tok-123")
        #expect(approved.swarm?.peers.first?.name == "silicon-node")

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
        let server = PairingServer(
            hostName: "Owner", release: SwarmConfig(swarmToken: "t", peers: [])
        )
        let port = freePort()
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

    @Test("stale requests expire on their own")
    func expiry() async throws {
        let server = PairingServer(
            hostName: "Owner", release: SwarmConfig(swarmToken: "t", peers: []),
            requestLifetime: 0.2
        )
        let port = freePort()
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