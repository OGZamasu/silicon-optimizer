import SiliconControl
import SwiftUI

/// One line in the Codex and Pi chat headers: a paired phone is following this Mac's agent
/// sessions.
///
/// It exists because the sessions are genuinely shared. A device paired with full control
/// can read these transcripts, send into them and answer their approvals, and the owner
/// typing at the Mac should know that without having to remember they left a phone
/// connected in the kitchen.
///
/// The count comes from `BuddyEventHub.agentWatcherCount`: every full-control device with
/// `/events` open, and every one that used an agent route in the last three minutes — a
/// phone can follow a session by polling or by sending and walking away, and a badge that
/// went dark whenever the stream dropped would say nobody was there just after a phone had
/// answered an approval. **Full scope only**, because that is exactly who can reach these
/// sessions: a device paired for chat is refused the agent routes and is sent no `agent`
/// frames, and this Mac's own token and the swarm secret are not devices at all.
///
/// Polled rather than observed: the hub is an actor with no change notification, a badge is
/// not worth inventing one for, and two seconds is well inside the time it takes to notice
/// a line of text appear.
struct BuddyWatchingBadge: View {

    @State private var watchers = 0

    /// How often the badge asks. Slow on purpose — this is a background fact, not a
    /// reading a person is waiting on.
    static let pollInterval: Duration = .seconds(2)

    /// How long a device counts as present after its last agent request.
    static let recentWindow: Duration = .seconds(180)

    var body: some View {
        Group {
            if watchers > 0 {
                Label(Self.caption(watchers), systemImage: "iphone.gen3.radiowaves.left.and.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(Self.tooltip)
                    .transition(.opacity)
            }
        }
        .task {
            // Ends with the view: the loop is cancelled when the tab goes away, and the
            // hub is asked nothing while nobody is looking at a chat.
            while !Task.isCancelled {
                let now = await BuddyEventHub.shared.agentWatcherCount(within: Self.recentWindow)
                if now != watchers {
                    withAnimation(.easeInOut(duration: 0.2)) { watchers = now }
                }
                guard (try? await Task.sleep(for: Self.pollInterval)) != nil else { return }
            }
        }
    }

    /// One device is the ordinary case and reads as a sentence; more than one is a count,
    /// because "Silicon Buddy is watching" while three phones are would be wrong in the
    /// direction that matters.
    static func caption(_ count: Int) -> String {
        count == 1
            ? "Silicon Buddy is watching"
            : "\(count) Silicon Buddies are watching"
    }

    /// Says what the badge counts, including the part that is not "right now".
    static let tooltip =
        "A phone or tablet paired with full control is following these agent sessions — "
        + "it has the live stream open, or used them in the last three minutes. It can read "
        + "the transcripts, send messages and answer approvals on both Codex and Pi."
}
