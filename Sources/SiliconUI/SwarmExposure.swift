import Foundation
import SiliconControl

/// How this Mac is reachable by its own peers and phones: the tailnet address the control
/// API is bound to, or the reason it is not bound at all.
///
/// `AppModel` is `@Observable` and an extension cannot add stored properties to it, so —
/// like `BuddyCenter` — the swarm's half of the Settings and Dashboard copy lives here.
/// `ControlServer` remains the source of truth; this is the copy the windows draw from.
@MainActor
@Observable
public final class SwarmExposure {

    public static let shared = SwarmExposure()

    /// The owner asked for the swarm to reach this Mac, and swarm.json had a token.
    public private(set) var isRequested = false
    /// Where peers dial, once the listener is actually up.
    public private(set) var address: String?
    public private(set) var port: Int?
    /// Why it is not up, when it was asked for and could not be.
    public private(set) var problem: String?

    public init() {}

    /// The socket is up. Not the same as peers being able to use it: Silicon Buddy can be
    /// the only reason it exists.
    public var isListening: Bool { address != nil }

    /// What the swarm actually cares about — the listener is up *and* the owner asked for
    /// peers to be let in. With Buddy on and swarm access off the socket is there and every
    /// peer is refused, so saying "reachable" would be a lie with a port number in it.
    public var isReachableByPeers: Bool { isRequested && isListening }

    /// One sentence for Settings and the Dashboard's swarm card. Written here rather than
    /// in either view, because both have to say the same thing.
    public var summary: String {
        if isReachableByPeers, let address, let port {
            return "Reachable by your peers at \(address):\(port) — your tailnet only."
        }
        guard isRequested else {
            return isListening
                ? "Peers are refused — swarm access is off. The tailnet listener is up for "
                    + "Silicon Buddy only."
                : "Local only — turn on swarm access to let your peers reach this Mac."
        }
        if let problem { return problem }
        return "Turning on… the tailnet listener is not up yet."
    }

    public func refresh(server: ControlServer?) async {
        guard let server else {
            apply(.init(requested: false, listening: false))
            return
        }
        apply(await server.exposure)
    }

    /// Takes one snapshot. The app goes through `refresh(server:)`; this is also the seam
    /// the tests pin the copy with, for states a real listener cannot be talked into.
    public func apply(_ state: ControlAPI.SwarmView.Exposure) {
        isRequested = state.requested
        address = state.listening ? state.address : nil
        port = state.listening ? state.port : nil
        problem = state.problem
    }

    /// Retries the bind and republishes what happened. Tailscale can be down when the app
    /// launches and up a minute later, so this rides the swarm's own refresh rather than
    /// asking the owner to restart the app.
    public func retry(server: ControlServer?) async {
        await server?.refreshTailnetAccessIfDown()
        await refresh(server: server)
    }

    /// The button's version: rediscover and rebind whatever the current state, because
    /// somebody asked for it on purpose and "nothing happened" is not an answer.
    public func retryNow(server: ControlServer?) async {
        await server?.refreshTailnetAccess()
        await refresh(server: server)
    }
}
