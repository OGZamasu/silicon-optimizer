import Foundation
import SiliconElevenLabs

/// What every live screen keeps about the one session it may have open: a token that changes
/// with every start and end (so a late event, a late answer or a slow start never lands on a
/// newer session), the account the session belongs to, and the pane's count of billable work in
/// flight (so Settings refuses a new key or region while a session is open).
@MainActor
final class LiveSessionGuard {
    private(set) var token = UUID()
    private var binding: LiveAccountBinding?
    private var counted = false
    let context: LiveContext

    init(context: LiveContext) {
        self.context = context
    }

    /// A session is starting on `client`: a new token, bound to this account.
    func begin(client: ElevenLabsClient, work: any ElevenLabsLiveWork) -> UUID {
        token = UUID()
        binding = LiveAccountBinding(client: client, pane: context.pane)
        context.pane?.trackLive(work)
        if !counted {
            context.pane?.billableRunStarted()
            counted = true
        }
        return token
    }

    func isCurrent(_ candidate: UUID) -> Bool { candidate == token }

    /// Whether the session still belongs to the linked account: the same client, the same
    /// region, the same pane session.
    var accountIsCurrent: Bool { binding?.isCurrent(in: context) ?? false }

    /// The session is over: its token is spent and it no longer counts as billable work.
    func end() {
        token = UUID()
        binding = nil
        if counted {
            context.pane?.billableRunEnded()
            counted = false
        }
    }
}
