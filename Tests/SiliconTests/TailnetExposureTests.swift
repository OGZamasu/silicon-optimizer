import Foundation
import Network
import Testing
@testable import SiliconControl

/// Reaching this Mac from anywhere but this Mac: one listener, on the tailscale address,
/// shared by the swarm and Silicon Buddy.
///
/// The product is Tailscale-only by decision, so there is no 0.0.0.0 path left in the
/// server at all — "let other Silicon nodes reach this Mac" binds 100.64/10 or it binds
/// nothing. Everything here runs over loopback with a private handshake file and a private
/// `buddy.json`: 127.0.0.1 stands in for the tailnet address (the bind rule accepts it for
/// exactly that reason) at a kernel-assigned port, so the loopback listener and the shared
/// one can always be told apart.
@Suite("Tailnet-only exposure")
struct TailnetExposureTests {

    // MARK: - The bind itself

    /// The heart of it. Exposure used to mean `0.0.0.0:8788` on the primary listener; it
    /// now means the tailnet address on the shared one, and nothing about the loopback
    /// listener changes. Reverting either half fails here.
    @Test func exposingTheSwarmBindsTheTailnetAddressAndNeverTheWildcard() async throws {
        try await withExposedServer { fixture in
            #expect(await fixture.server.swarmExposureRequested)
            #expect(await fixture.server.tailnetEndpoint
                == ControlServer.TailnetEndpoint(address: "127.0.0.1", port: fixture.peerPort))
            #expect(await fixture.server.tailnetOwnership == .swarm)
            let health = try await fixture.peer.status("GET", "/health", token: nil)
            #expect(health == 200)

            // The primary listener is loopback on an ephemeral port — not the swarm's fixed
            // one, which is the shared listener's and only ever reached by its address.
            let loopbackPort = await fixture.server.listeningPort
            #expect(loopbackPort != fixture.peerPort)
            #expect(loopbackPort != ControlServer.tailnetPort)

            // And it is loopback in the sense that matters: a request to this Mac's own
            // network address does not reach it. A wildcard bind would answer this.
            if let lan = Self.nonLoopbackIPv4() {
                #expect(!(await Self.answers(host: lan, port: loopbackPort)))
            }

            // The wildcard cannot be reached by asking for it, either.
            await #expect(throws: ControlServer.TailnetBindError.self) {
                try await fixture.server.setTailnetAccess(address: "0.0.0.0", for: .swarm)
            }
            #expect(await fixture.server.tailnetListenerAddress == "127.0.0.1")
        }
    }

    /// A tailscale address the CLI will not give up is the common failure — tailscale not
    /// running, not logged in, still coming up after a reboot. Exposure then binds nothing
    /// at all rather than falling back to something broader, and says why.
    @Test func withNoTailnetAddressNothingBindsAndTheReasonIsPlain() async throws {
        let bench = try await Bench(discovering: nil)
        defer { bench.tearDown() }
        try await bench.server.start(
            exposeToTailnet: true, swarmToken: Bench.swarmToken,
            tailnetPort: try await BuddyControlTests.freeLoopbackPort()
        )

        #expect(await bench.server.swarmExposureRequested)
        #expect(await bench.server.tailnetEndpoint == nil)
        let problem = try #require(await bench.server.tailnetError)
        #expect(problem.contains("Join the tailnet first"))

        let exposure = await bench.server.exposure
        #expect(exposure.requested)
        #expect(!exposure.listening)
        #expect(exposure.address == nil)
        #expect(exposure.problem == problem)

        // Loopback is unaffected: the local bridge still has everything it had.
        let local = try await bench.loopbackClient()
        #expect(try await local.status("GET", "/status", token: local.token) == 200)
        await bench.server.stop()
    }

    /// Tailscale comes up a minute after the app does, and the owner should not have to
    /// restart anything. The swarm's own refresh carries the retry.
    @Test func aBindThatFailedBecauseTailscaleWasDownRetriesOnTheRefreshPath() async throws {
        let discovery = DiscoveryBox(address: nil)
        let bench = try await Bench(discovering: discovery)
        defer { bench.tearDown() }
        let port = try await BuddyControlTests.freeLoopbackPort()
        try await bench.server.start(
            exposeToTailnet: true, swarmToken: Bench.swarmToken, tailnetPort: port
        )
        #expect(await bench.server.tailnetEndpoint == nil)
        // The ownership survives the failure — without it there would be nothing left to
        // retry for, and the listener would stay down until the next launch.
        #expect(await bench.server.tailnetOwnership == .swarm)

        discovery.set("127.0.0.1")
        await bench.server.refreshTailnetAccess()

        #expect(await bench.server.tailnetEndpoint
            == ControlServer.TailnetEndpoint(address: "127.0.0.1", port: port))
        #expect(await bench.server.tailnetError == nil)
        #expect(await BuddyControlTests.reachable(port: port))
        await bench.server.stop()
    }

    /// An installation from before this change has `exposeControlOnLAN` on in settings and a
    /// token in swarm.json. It keeps working, unedited — bound to the tailnet now — and
    /// `GET /swarm` says where, so a peer that cannot call back has an answer to read.
    @Test func anExistingExposedConfigurationKeepsWorkingOnTheTailnet() async throws {
        try await withExposedServer { fixture in
            await fixture.host.reportExposure { [server = fixture.server] in
                await server.exposure
            }
            let (status, body) = try await fixture.local.call(
                "GET", "/swarm", token: fixture.local.token
            )
            #expect(status == 200)
            let view = try JSONDecoder().decode(ControlAPI.SwarmView.self, from: body)
            let exposure = try #require(view.exposure)
            #expect(exposure.requested)
            #expect(exposure.listening)
            #expect(exposure.address == "127.0.0.1")
            #expect(exposure.port == fixture.peerPort)
            #expect(exposure.problem == nil)
        }
    }

    /// Exposure without a swarm token is still refused outright — an unauthenticated jobs
    /// API is an unauthenticated remote-execution service, tailnet or not.
    @Test func exposureWithoutASwarmTokenBindsNothing() async throws {
        let bench = try await Bench(discovering: "127.0.0.1")
        defer { bench.tearDown() }
        try await bench.server.start(
            exposeToTailnet: true, swarmToken: "  ",
            tailnetPort: try await BuddyControlTests.freeLoopbackPort()
        )
        #expect(!(await bench.server.swarmExposureRequested))
        #expect(await bench.server.tailnetEndpoint == nil)
        #expect(await bench.server.tailnetOwnership == [])
        await bench.server.stop()
    }

    // MARK: - One listener, two features

    /// The swarm and Silicon Buddy want the same address on the same port. They get one
    /// socket, and the second one to ask does not rebind it — a second bind would either be
    /// refused or split the connections between two listeners.
    @Test func bothFeaturesShareExactlyOneListener() async throws {
        try await withExposedServer { fixture in
            let before = await fixture.server.tailnetEndpoint
            try await fixture.allowDevices(true)

            #expect(await fixture.server.tailnetOwnership == [.swarm, .buddy])
            #expect(await fixture.server.tailnetEndpoint == before)
            #expect(await BuddyControlTests.reachable(port: fixture.peerPort))

            // Both credentials, one door.
            let paired = try await fixture.pair()
            #expect(try await fixture.peer.status(
                "GET", "/status", token: Bench.swarmToken
            ) == 200)
            #expect(try await fixture.peer.status("GET", "/status", token: paired.token) == 200)
            // And the device token is still not a credential on loopback.
            #expect(try await fixture.local.status("GET", "/status", token: paired.token) == 401)
        }
    }

    /// Turning Silicon Buddy off no longer takes the listener with it, because the swarm is
    /// holding it. All the toggle does is stop device bearers meaning anything.
    @Test func theBuddyToggleOnlyGatesDeviceBearersWhileTheSwarmIsExposed() async throws {
        try await withExposedServer { fixture in
            try await fixture.allowDevices(true)
            let paired = try await fixture.pair()
            let endpoint = await fixture.server.tailnetEndpoint

            try await fixture.allowDevices(false)

            #expect(await fixture.server.tailnetEndpoint == endpoint)
            #expect(await fixture.server.tailnetOwnership == .swarm)
            #expect(try await fixture.peer.status("GET", "/status", token: paired.token) == 401)
            // The swarm carries on through the same socket, unaffected.
            #expect(try await fixture.peer.status(
                "GET", "/status", token: Bench.swarmToken
            ) == 200)
            // Suspended, not forgotten.
            #expect(await fixture.registry.devices().count == 1)

            try await fixture.allowDevices(true)
            #expect(try await fixture.peer.status("GET", "/status", token: paired.token) == 200)
        }
    }

    /// The mirror image, and the reason the swarm toggle still means something once Silicon
    /// Buddy can raise the same socket by itself: "let other Silicon nodes reach this Mac",
    /// turned off, has to keep them out even while the listener is up for the phones.
    @Test func theSwarmTokenIsNotACredentialOnAListenerTheSwarmDidNotAskFor() async throws {
        let bench = try await Bench(discovering: "127.0.0.1")
        defer { bench.tearDown() }
        try await bench.server.start(swarmToken: Bench.swarmToken)
        let local = try await bench.loopbackClient()
        await bench.registry.setAllowsTailnetDevices(true)
        let port = try await BuddyControlTests.bindTailnetListener(on: bench.server)
        let peer = TestClient(port: port, token: local.token, session: bench.session)

        #expect(await bench.server.tailnetOwnership == .buddy)
        #expect(try await peer.status("GET", "/status", token: Bench.swarmToken) == 401)
        // On loopback it is what it always was: this Mac's own tools use it.
        #expect(try await local.status("GET", "/status", token: Bench.swarmToken) == 200)
        await bench.server.stop()
    }

    /// The last one out closes the door.
    @Test func theListenerClosesOnlyWhenBothFeaturesLetGo() async throws {
        try await withExposedServer { fixture in
            try await fixture.allowDevices(true)
            #expect(await fixture.server.tailnetOwnership == [.swarm, .buddy])

            try await fixture.server.setTailnetAccess(address: nil, for: .buddy)
            #expect(await fixture.server.tailnetEndpoint != nil)
            #expect(try await fixture.peer.status("GET", "/health", token: nil) == 200)

            try await fixture.server.setTailnetAccess(address: nil, for: .swarm)
            #expect(await fixture.server.tailnetEndpoint == nil)
            #expect(await fixture.server.tailnetOwnership == [])
            await #expect(throws: (any Error).self) {
                _ = try await fixture.peer.status("GET", "/health", token: nil)
            }
            // Loopback, throughout.
            #expect(try await fixture.local.status(
                "GET", "/status", token: fixture.local.token
            ) == 200)
        }
    }

    /// Scope is decided in one place and nothing about sharing the listener moved it: a
    /// chat-only phone may still talk, and may still not spend the machine.
    @Test func theScopeGateIsUnchangedOnTheSharedListener() async throws {
        try await withExposedServer { fixture in
            try await fixture.allowDevices(true)
            let chatOnly = try await fixture.pair(scope: .chat)

            #expect(try await fixture.peer.status("GET", "/status", token: chatOnly.token) == 200)
            #expect(try await fixture.peer.status(
                "POST", "/install", token: chatOnly.token, body: #"{"modelID":"x"}"#
            ) == 403)

            let full = try await fixture.pair(name: "Pixel", scope: .full)
            #expect(try await fixture.peer.status("GET", "/status", token: full.token) == 200)
        }
    }

    // MARK: - The bench

    /// A control server with a private handshake file and registry, an injected tailnet
    /// address, and a session to reach both listeners with.
    struct Bench {
        static let swarmToken = "a-shared-swarm-secret"

        let directory: URL
        let handshakeURL: URL
        let registry: BuddyRegistry
        let host: BuddyTestHost
        let server: ControlServer
        let session: URLSession

        init(discovering address: String?) async throws {
            try await self.init(discovering: DiscoveryBox(address: address))
        }

        init(discovering discovery: DiscoveryBox) async throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("tailnet-exposure-\(UUID())")
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            handshakeURL = directory.appendingPathComponent("control.json")
            registry = BuddyRegistry(url: directory.appendingPathComponent("buddy.json"))
            host = BuddyTestHost(tokens: ["ok"], pace: .milliseconds(1), failing: false)
            server = ControlServer(
                host: host, handshakeURL: handshakeURL, buddy: registry,
                events: BuddyEventHub(),
                // Never the real CLI: a test must not bind whatever tailnet this machine is on.
                discoverTailnetAddress: { discovery.current }
            )
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 20
            session = URLSession(configuration: configuration)
        }

        /// The handshake is written when the primary listener comes up, so this is also how
        /// a test waits for the server to be serving at all.
        func loopbackClient() async throws -> TestClient {
            let deadline = ContinuousClock.now + .seconds(5)
            while !FileManager.default.fileExists(atPath: handshakeURL.path) {
                guard ContinuousClock.now < deadline else { throw TailnetTestError.timeout }
                try await Task.sleep(for: .milliseconds(20))
            }
            let handshake = try JSONDecoder().decode(
                ControlAPI.Handshake.self, from: try Data(contentsOf: handshakeURL)
            )
            return TestClient(port: handshake.port, token: handshake.token, session: session)
        }

        func tearDown() {
            session.invalidateAndCancel()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    struct Fixture {
        let bench: Bench
        /// Where the swarm and the phones both arrive.
        let peerPort: Int
        let local: TestClient
        let peer: TestClient

        var server: ControlServer { bench.server }
        var registry: BuddyRegistry { bench.registry }
        var host: BuddyTestHost { bench.host }

        /// The Buddy toggle as the window drives it: the registry, then the server's own
        /// refresh, which is where ownership of the shared listener is decided.
        func allowDevices(_ allowed: Bool) async throws {
            await registry.setAllowsTailnetDevices(allowed)
            await server.refreshTailnetAccess()
        }

        func pair(
            name: String = "Galaxy S24 Ultra", scope: BuddyScope = .full
        ) async throws -> ControlAPI.BuddyPairResponse {
            let invitation = await registry.invite(
                host: "127.0.0.1", port: peerPort, scope: scope
            )
            let (status, body) = try await peer.call(
                "POST", "/buddy/pair", token: nil,
                body: #"{"code":"\#(invitation.code)","deviceName":"\#(name)","platform":"android"}"#
            )
            #expect(status == 200)
            return try JSONDecoder().decode(ControlAPI.BuddyPairResponse.self, from: body)
        }
    }

    /// A server started exactly as an owner with swarm exposure on would have it: the swarm
    /// asked, Silicon Buddy has not, and the one listener is up on the "tailnet" address.
    ///
    /// The port is kernel-assigned and retried, because a port that was free a moment ago
    /// can be taken by another suite in this process before the bind lands — and a busy
    /// port would otherwise look exactly like an exposure that refused to bind.
    private func withExposedServer(_ body: (Fixture) async throws -> Void) async throws {
        for attempt in 0..<8 {
            let bench = try await Bench(discovering: "127.0.0.1")
            let port = try await BuddyControlTests.freeLoopbackPort()
            try await bench.server.start(
                exposeToTailnet: true, swarmToken: Bench.swarmToken, tailnetPort: port
            )
            let local = try await bench.loopbackClient()
            guard await bench.server.tailnetEndpoint != nil,
                  await BuddyControlTests.reachable(port: port)
            else {
                await bench.server.stop()
                bench.tearDown()
                guard attempt < 7 else { throw TailnetTestError.timeout }
                continue
            }
            defer { bench.tearDown() }
            try await body(Fixture(
                bench: bench, peerPort: port, local: local,
                peer: TestClient(port: port, token: local.token, session: bench.session)
            ))
            await bench.server.stop()
            return
        }
        throw TailnetTestError.timeout
    }

    // MARK: - Reaching this Mac by its own network address

    /// This Mac's first ordinary IPv4 — the address a wildcard bind would answer on and a
    /// loopback bind will not. Nil on a machine with nothing but loopback up, where the
    /// check simply has nothing to prove.
    static func nonLoopbackIPv4() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var found: String?
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(pointer.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let address = pointer.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET)
            else { continue }
            var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                address, socklen_t(address.pointee.sa_len), &name, socklen_t(name.count),
                nil, 0, NI_NUMERICHOST
            ) == 0 else { continue }
            let text = String(cString: name)
            // Tailscale's own interface is not loopback but is not the point here either.
            guard !SwarmPairing.isTailnetIPv4(text) else { continue }
            found = text
            break
        }
        return found
    }

    static func answers(host: String, port: Int) async -> Bool {
        var request = URLRequest(url: URL(string: "http://\(host):\(port)/health")!)
        request.timeoutInterval = 3
        guard let (_, response) = try? await URLSession.shared.data(for: request) else {
            return false
        }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }
}

/// A tailscale address that can change between calls, the way the real CLI's answer does
/// when tailscale starts, stops, or re-authenticates under a running app.
final class DiscoveryBox: @unchecked Sendable {
    private let lock = NSLock()
    private var address: String?

    init(address: String?) { self.address = address }

    var current: String? {
        lock.lock()
        defer { lock.unlock() }
        return address
    }

    func set(_ value: String?) {
        lock.lock()
        defer { lock.unlock() }
        address = value
    }
}

enum TailnetTestError: Error, LocalizedError {
    case timeout

    var errorDescription: String? { "The exposure fixture timed out." }
}
