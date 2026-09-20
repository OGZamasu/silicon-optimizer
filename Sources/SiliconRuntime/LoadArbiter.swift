import Foundation

/// Which load most recently claimed the machine, so a load that loses it is told, rather than
/// left to report the mystery that follows.
///
/// Two loads overlap more easily than it looks: the owner taps Load on the Mac while a phone
/// is already loading something, or taps it twice. The app's own sequence is *stop the old
/// server, then start the new one* — so from the first load's point of view its server simply
/// vanished, and every fact it had said "the app asked for this stop", which is also what an
/// unload looks like. That is the whole reason this exists: the replacement arrives a moment
/// *after* the stop, never before it, so a displaced load waits for the newer load to
/// announce itself before deciding what to call its own ending.
///
/// It remembers the newest claim *ever* begun rather than the one currently running. A load
/// that is over is still the load that displaced this one — a fast winner used to finish
/// before the loser asked, and the loser then reported an unload that nobody had asked for.
///
/// Nothing here cancels anything. It records who claimed the machine and answers questions;
/// refusing an overlapping load is the control API's business, one layer up, where there is a
/// caller to refuse.
public actor LoadArbiter {

    /// The one the app uses. Tests build their own — a claim is process-wide state, and a
    /// suite that shared it would be reading another suite's loads.
    public static let shared = LoadArbiter()

    public struct Claim: Sendable, Equatable {
        public let id: Int
        public let model: String
        public let runtime: RuntimeKind
    }

    /// How long a load that was stopped mid-flight waits to find out whether a newer load is
    /// what stopped it. Long enough to cover the app's unload-then-start sequence, short
    /// enough that nobody notices an error arriving a moment later than it could have — and
    /// not spent at all when the answer is already known.
    public let settle: Duration

    private var nextID = 1
    /// The newest claim ever begun, running or not.
    private var latest: Claim?

    public init(settle: Duration = .milliseconds(1500)) {
        self.settle = settle
    }

    /// Records a load about to start, and hands it the claim it can ask about later.
    @discardableResult
    public func begin(model: String, runtime: RuntimeKind) -> Claim {
        let claim = Claim(id: nextID, model: model, runtime: runtime)
        nextID += 1
        latest = claim
        return claim
    }

    /// The load that displaced this one, or nil if nothing did.
    ///
    /// Waits up to `settle` for an answer, because of the ordering above: asked the instant a
    /// server dies, the honest answer is "nobody yet". A winner that has already announced
    /// itself — or already finished — is answered immediately.
    public func displacement(of claim: Claim) async -> Claim? {
        if let newer = newerThan(claim) { return newer }
        let deadline = ContinuousClock.now + settle
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(25))
            if let newer = newerThan(claim) { return newer }
        }
        return newerThan(claim)
    }

    private func newerThan(_ claim: Claim) -> Claim? {
        guard let latest, latest.id > claim.id else { return nil }
        return latest
    }
}
