import Foundation
import Testing
@testable import SiliconControl

/// A connection takes a slot before anything about it is known — its bearer is in a request
/// that has not been read yet. Idle sockets from one tailnet host must not be able to leave
/// the MCP bridge on loopback, or everybody else on the tailnet, without one.
@Suite("Control server connection budget")
@MainActor
struct ConnectionBudgetTests {

    typealias Budget = ControlServer.ConnectionBudget

    @Test func oneTailnetAddressTakesOnlyItsShareAndLoopbackKeepsItsOwn() {
        var budget = Budget()
        func admit(_ origin: ControlServer.Origin, _ source: String) -> Bool {
            budget.admit(from: origin, source: source)
        }
        let greedy = "100.64.0.9"
        for _ in 0..<Budget.perTailnetSource {
            #expect(admit(.tailnet, greedy))
        }
        #expect(!admit(.tailnet, greedy))
        // Somebody else on the tailnet — a phone — is still let in, and so is loopback.
        #expect(admit(.tailnet, "100.64.0.10"))
        #expect(admit(.primary, "127.0.0.1"))

        // Filled from many addresses, the tailnet listener is full; loopback is not.
        var next = 11
        while admit(.tailnet, "100.64.0.\(next)") { next += 1 }
        #expect(budget.total == Budget.perListener + 1)
        for _ in 0..<(Budget.perListener - 1) {
            #expect(admit(.primary, "127.0.0.1"))
        }
        #expect(!admit(.primary, "127.0.0.1"))

        // A slot given back is a slot to be had again, by the address that gave it back.
        budget.release(from: .tailnet, source: greedy)
        #expect(admit(.tailnet, greedy))
        #expect(!admit(.tailnet, greedy))
    }

    @Test func idleConnectionsFromTheTailnetLeaveTheLoopbackListenerAnswering() async throws {
        let host = BuddyTestHost(tokens: ["ok"], pace: .milliseconds(1), failing: false)
        try await withServer(host: host) { (fixture: AgentFixture) async throws in
            // Sixty-four sockets that connect and then say nothing: the whole of what the
            // old shared budget had, from one address, for fifteen seconds at a time.
            let idle = IdleSockets(count: 64, port: fixture.phone.port)
            defer { idle.closeAll() }
            #expect(idle.count == 64)
            try await Self.eventually { await fixture.server.openConnections >= 16 }
            // Every one of them has had time to be admitted or turned away.
            try await Task.sleep(for: .milliseconds(300))

            #expect(try await fixture.local.status("GET", "/health", token: nil) == 200)
            #expect(await fixture.server.openConnections <= Budget.perTailnetSource)

            // Given back, the tailnet listener answers again.
            idle.closeAll()
            try await Self.eventually { await fixture.server.openConnections == 0 }
            #expect(try await fixture.phone.status("GET", "/health", token: nil) == 200)
        }
    }

    private static func eventually(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw BuddyTestError.timeout }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

/// Plain sockets that connect and send nothing — what a hostile or broken client looks like
/// before its first byte, and something `URLSession` will not be.
private final class IdleSockets {
    private var descriptors: [Int32] = []

    var count: Int { descriptors.count }

    init(count: Int, port: Int) {
        for _ in 0..<count {
            let descriptor = socket(AF_INET, SOCK_STREAM, 0)
            guard descriptor >= 0 else { continue }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(UInt16(port).bigEndian)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                }
            }
            if connected { descriptors.append(descriptor) } else { Darwin.close(descriptor) }
        }
    }

    func closeAll() {
        descriptors.forEach { Darwin.close($0) }
        descriptors.removeAll()
    }
}
