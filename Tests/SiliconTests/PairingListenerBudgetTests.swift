import Foundation
import Testing
@testable import SiliconControl

/// The swarm's pairing listener is open to the whole tailnet for as long as the invite sheet
/// is, and nothing on it is authenticated. A host that holds its sockets must not be able
/// to keep the joiner the owner is waiting for from saying hello.
@Suite("Swarm pairing listener budget", .serialized)
struct PairingListenerBudgetTests {

    /// Sixteen connections that each promise sixteen megabytes and send them a byte at a
    /// time. With the control server's general ceiling, and a body read for as long as it
    /// keeps arriving, that was every socket the listener has, for a quarter of an hour.
    @Test func tricklingJoinsDoNotLockOutAHello() async throws {
        let server = PairingServer(hostName: "Owner Mac")
        let port = try await BuddyControlTests.freeLoopbackPort()
        try await server.start(on: "127.0.0.1", port: port)
        defer { Task { await server.stop() } }
        try await Task.sleep(for: .milliseconds(300))

        var trickles: [RawConnection] = []
        defer { trickles.forEach { $0.close() } }
        for _ in 0..<PairingServer.maximumConnections {
            let raw = try await RawConnection.connect(port: port)
            try? await raw.send(
                "POST /swarm/pair/request HTTP/1.1\r\nHost: 127.0.0.1\r\n"
                    + "Content-Type: application/json\r\nContent-Length: 16000000\r\n\r\n{"
            )
            trickles.append(raw)
        }
        let dribble = Task { [trickles] in
            while !Task.isCancelled {
                try await Task.sleep(for: .milliseconds(500))
                for raw in trickles { try? await raw.send(" ") }
            }
        }
        defer { dribble.cancel() }
        try await Task.sleep(for: .milliseconds(500))

        let hello = await PairingClient.hello(host: "127.0.0.1", port: port)
        #expect(hello?.accepting == true, "the listener was held by the trickles")
    }

    /// And what a slot costs now: a body of what a join can be, at a slow link's pace, is
    /// in within seconds of the headers' own deadline.
    @Test func aPairingRequestIsSmallEnoughToBeOverQuickly() {
        let start = ContinuousClock.now
        let ceiling = ControlServer.ReadDeadlines.standard
            .ceiling(forBodyOf: PairingServer.maximumBody, from: start)
        #expect(ceiling < start + .seconds(16))
        // The longest name the owner's sheet would show, in two-byte characters, with room.
        let name = String(repeating: "é", count: 256)
        let join = try? JSONEncoder().encode(PairingJoinRequest(name: name))
        #expect((join?.count ?? .max) <= PairingServer.maximumBody)
    }

    /// One address takes its share and no more; a joiner at another address still gets in.
    @Test func oneAddressCannotTakeTheWholePairingListener() {
        var budget = ControlServer.ConnectionBudget(
            perListener: PairingServer.maximumConnections,
            perTailnetSource: PairingServer.maximumConnectionsPerAddress
        )
        var held = 0
        while budget.admit(from: .tailnet, source: "100.64.0.9") { held += 1 }
        #expect(held == PairingServer.maximumConnectionsPerAddress)
        #expect(held < PairingServer.maximumConnections)
        let joiner = budget.admit(from: .tailnet, source: "100.64.0.10")
        #expect(joiner)
    }
}
