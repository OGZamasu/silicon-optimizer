import Foundation
import Testing
@testable import SiliconControl
@testable import SiliconUI

/// What Settings and the Dashboard say about reaching this Mac.
///
/// The copy is a claim about a socket, and the socket has four states worth telling apart:
/// up for the swarm, up for Silicon Buddy only, asked for and not up, and off. Saying
/// "reachable by your peers" in the second one would be a lie with a port number in it —
/// every peer that dialled it would get a 401 — which is exactly the kind of wrong that
/// sends someone to debug their tailnet.
@Suite("Swarm exposure copy")
@MainActor
struct SwarmExposureCopyTests {

    @Test func reachableIsSaidOnlyWhenTheSwarmAskedForItAndTheListenerIsUp() {
        let exposure = SwarmExposure()
        exposure.apply(.init(
            requested: true, listening: true, address: "100.64.0.9", port: 8788
        ))
        #expect(exposure.isReachableByPeers)
        #expect(exposure.summary == "Reachable by your peers at 100.64.0.9:8788 — your tailnet only.")
    }

    @Test func aListenerUpForSiliconBuddyAloneIsNotReachableByPeers() {
        let exposure = SwarmExposure()
        // Silicon Buddy is holding the listener; swarm access is off, so the swarm token is
        // refused on it. The socket is up and the peers are not getting in.
        exposure.apply(.init(
            requested: false, listening: true, address: "100.64.0.9", port: 8788
        ))
        #expect(exposure.isListening)
        #expect(!exposure.isReachableByPeers)
        #expect(!exposure.summary.contains("Reachable by your peers"))
        #expect(exposure.summary.contains("swarm access is off"))
    }

    @Test func aProblemIsShownVerbatimWhenExposureWasAskedFor() {
        let exposure = SwarmExposure()
        exposure.apply(.init(
            requested: true, listening: false, problem: ControlServer.noTailnetAddress
        ))
        #expect(!exposure.isReachableByPeers)
        #expect(exposure.summary == ControlServer.noTailnetAddress)
        #expect(exposure.address == nil)
        #expect(exposure.port == nil)
    }

    @Test func offSaysLocalOnly() {
        let exposure = SwarmExposure()
        exposure.apply(.init(requested: false, listening: false))
        #expect(!exposure.isListening)
        #expect(!exposure.isReachableByPeers)
        #expect(exposure.summary.contains("Local only"))
    }

    /// An address that arrives with `listening: false` is a bind that has not landed — a
    /// listener waiting on an address this Mac does not hold reports exactly that. The copy
    /// must not quote it as somewhere to dial.
    @Test func anAddressWithoutAListenerIsNotShownAsAnAddress() {
        let exposure = SwarmExposure()
        exposure.apply(.init(
            requested: true, listening: false, address: "100.64.1.1", port: 8788,
            problem: "Could not bind 100.64.1.1:8788 — Can't assign requested address"
        ))
        #expect(exposure.address == nil)
        #expect(exposure.port == nil)
        #expect(!exposure.isReachableByPeers)
        #expect(exposure.summary.contains("Could not bind"))
    }
}
