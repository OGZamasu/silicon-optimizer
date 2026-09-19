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

    public var isListening: Bool { address != nil }

    /// One sentence for Settings and the Dashboard's swarm card. Written here rather than
    /// in either view, because both have to say the same thing.
    public var summary: String {
        if let address, let port {
            return "Reachable by your peers at \(address):\(port) — your tailnet only."
        }
        if let problem { return problem }
        return isRequested
            ? "Turning on… the tailnet listener is not up yet."
            : "Local only — turn on swarm access in Settings to let your peers reach this Mac."
    }

    public func refresh(server: ControlServer?) async {
        guard let server else {
            isRequested = false
            address = nil
            port = nil
            problem = nil
            return
        }
        let state = await server.exposure
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
}
