import Foundation
import SiliconControl

// MARK: - Which lane

/// The lanes that can answer a typed decision.
///
/// Three of them answer the *same* request shape — `state` plus `questions`, typed
/// probabilistic answers out — and differ only in where the computation happens and who
/// pays for it. That is the whole point of naming them: a feature asks a question, and the
/// question does not change because the answer came from a different machine.
///
/// - `jev`: TypeSafe's hosted System One. Cloud, paid, the owner's own key, off by default.
/// - `laya`: laya-mlx on this Mac's GPU. Free, private, about a hundredth of a second.
/// - `node`: the same Laya checkpoints on a swarm node's CUDA card, over the tailnet.
/// - `oneToken`: the loaded language model read one token deep — the last resort that was
///   here before any of this, and still the only lane that needs nothing installed.
public enum DecisionLaneID: String, Codable, Sendable, CaseIterable, Hashable {
    case jev
    case laya
    case node
    case oneToken

    /// What `DecideResponse.provider` and `sources` call this lane.
    ///
    /// Not the case name: `typesafe` and `local` are already on the wire and already read by
    /// clients, the MCP tool and the contract fixtures, so they keep their spellings. The two
    /// new lanes get new words rather than re-using either.
    public var wireName: String {
        switch self {
        case .jev: ControlAPI.DecideResponse.Lane.typeSafe
        case .laya: "laya"
        case .node: "node"
        case .oneToken: ControlAPI.DecideResponse.Lane.local
        }
    }

    public static func named(_ wire: String) -> DecisionLaneID? {
        // A node answer carries the peer's name — `node:studio` — so the lane is the part
        // before the colon. Nothing else uses one.
        let head = wire.split(separator: ":", maxSplits: 1).first.map(String.init) ?? wire
        return allCases.first { $0.wireName == head }
    }

    public var displayName: String {
        switch self {
        case .jev: "Jev (TypeSafe)"
        case .laya: "Laya on this Mac"
        case .node: "Laya on a node"
        case .oneToken: "The loaded model"
        }
    }

    /// Whether asking this lane sends the state off this Mac.
    ///
    /// The node is *not* free of this even though nothing is billed: the state crosses the
    /// tailnet to another machine. Two different questions — "does this cost money?" and
    /// "does this leave the Mac?" — and the Decisions panel asks both, so they are two
    /// properties rather than one word.
    public var leavesTheMac: Bool {
        switch self {
        case .jev, .node: true
        case .laya, .oneToken: false
        }
    }

    /// Whether asking this lane spends the owner's money.
    public var costsMoney: Bool { self == .jev }
}

// MARK: - What a lane is

/// Something that answers a typed decision request.
///
/// Deliberately the *same* request and response types the control API already carries, so a
/// lane cannot quietly answer a different question from the one the feature asked, and so a
/// test double is a closure rather than a translation layer.
public protocol DecisionLane: Sendable {
    var laneID: DecisionLaneID { get }

    /// Whether this lane would answer right now.
    ///
    /// Must be cheap and must not prompt: this is called while drawing Settings and on every
    /// routing decision. No network, no Keychain read, no model load.
    func isReady() async -> Bool

    /// Answers, or throws. The response's `provider` is set by the lane to its own
    /// `wireName`, so the caller never has to remember who it asked.
    func decide(_ request: ControlAPI.DecideRequest) async throws -> ControlAPI.DecideResponse
}

// MARK: - The owner's choice, per feature

/// What the owner has said about which lane answers one feature.
///
/// `alwaysLocal` is the important one, and it is why this is four cases rather than a bool:
/// it means "never the cloud for this", and it keeps meaning that when Jev is switched on
/// for everything else. A feature set to `alwaysLocal` cannot spend a penny however the
/// master switch moves.
public enum DecisionLaneOverride: String, Codable, Sendable, CaseIterable, Hashable {
    /// The routing policy decides. The default, and what the owner asked for.
    case automatic
    /// Only a lane that stays on hardware the owner owns — Laya here, then the node, then
    /// the loaded model. Never Jev.
    case alwaysLocal
    /// Only Jev. When Jev cannot answer, the feature gets nothing rather than a free
    /// substitute: somebody who pinned a feature to the calibrated lane did not ask for the
    /// uncalibrated one.
    case alwaysJev
    /// This feature asks nobody. Exactly as it behaved before any of this existed.
    case off

    public var displayName: String {
        switch self {
        case .automatic: "Automatic"
        case .alwaysLocal: "Always local"
        case .alwaysJev: "Always Jev"
        case .off: "Off"
        }
    }

    public var summary: String {
        switch self {
        case .automatic:
            "Jev when it is on and keyed, otherwise the fastest local lane."
        case .alwaysLocal:
            "Never the cloud, whatever the master switch says."
        case .alwaysJev:
            "Only Jev. Nothing answers this when Jev cannot."
        case .off:
            "Nothing answers this."
        }
    }
}

/// Which lanes could answer right now — the input to the policy, gathered once so the
/// policy itself can be a pure function with no actors, no clock and no network in it.
public struct DecisionLaneAvailability: Sendable, Equatable {
    public var jev: Bool
    public var laya: Bool
    public var node: Bool
    public var oneToken: Bool

    public init(jev: Bool = false, laya: Bool = false, node: Bool = false, oneToken: Bool = false) {
        self.jev = jev
        self.laya = laya
        self.node = node
        self.oneToken = oneToken
    }

    public subscript(lane: DecisionLaneID) -> Bool {
        switch lane {
        case .jev: jev
        case .laya: laya
        case .node: node
        case .oneToken: oneToken
        }
    }

    public var none: Bool { !jev && !laya && !node && !oneToken }
}

// MARK: - The policy

/// Who answers, given what the owner has decided and what is installed.
///
/// A pure function on purpose. This is the rule that decides whether the owner's money gets
/// spent and whether their words leave the machine, and a rule like that should be readable
/// in one screen and testable in every combination without a server, a key or a model.
public enum DecisionLanePolicy {

    /// The order a local lane is preferred in when more than one is there.
    ///
    /// This Mac's own Laya first, always. It is the only lane that is both free and private,
    /// its published latency is in milliseconds, and preferring a peer over it would mean
    /// sending the state across a network to save nothing. The node is the fallback for a
    /// Mac that has not installed Laya — or has it, but the checkpoint is not resident — and
    /// the one-token decider is behind both because its probabilities are the loaded model's
    /// own rather than a decision model's.
    public static let localPreference: [DecisionLaneID] = [.laya, .node, .oneToken]

    /// Which lane answers, or nil when nothing should.
    ///
    /// Nil is a real answer, not a failure: it means this feature behaves exactly as it does
    /// today with nothing available — the router uses its default, the guardrail leaves the
    /// engine alone, `/decide` says what it has always said.
    public static func lane(
        override: DecisionLaneOverride,
        available: DecisionLaneAvailability
    ) -> DecisionLaneID? {
        switch override {
        case .off:
            return nil
        case .alwaysJev:
            // No silent substitution. A feature pinned to the calibrated lane is not asking
            // for an uncalibrated one when the calibrated one is unavailable.
            return available.jev ? .jev : nil
        case .alwaysLocal:
            // And no silent *escalation*: this is the case that has to be impossible to get
            // a cloud call out of, so `.jev` is not in the list it searches.
            return localPreference.first { available[$0] }
        case .automatic:
            // What the owner asked for, in their order: "when Jev is turned on and has a
            // key, Jev answers; otherwise Laya answers when it is installed; otherwise the
            // one-token decider; otherwise the feature behaves exactly as it does today."
            //
            // `available.jev` is already "turned on, keyed, in budget, and this feature's
            // own switch is on" — see `JevService.isAvailable`. So there is no path from
            // here to a cloud call the owner has not switched on, and that is checked by a
            // test that walks every combination of these four flags.
            if available.jev { return .jev }
            return localPreference.first { available[$0] }
        }
    }

    /// The lanes this one would fall through to if it failed, in order.
    ///
    /// Used for the one retry a live request gets: a sidecar that died between the
    /// availability check and the question should not turn into a failed decision when a
    /// node is sitting there ready. Never crosses from local to Jev — a lane failing is not
    /// the owner deciding to spend money.
    public static func fallbacks(
        after lane: DecisionLaneID,
        override: DecisionLaneOverride,
        available: DecisionLaneAvailability
    ) -> [DecisionLaneID] {
        guard override != .off, override != .alwaysJev, lane != .jev else { return [] }
        guard let start = localPreference.firstIndex(of: lane) else { return [] }
        return localPreference[(start + 1)...].filter { available[$0] }
    }
}
