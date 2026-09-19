import SiliconControl
import SwiftUI

/// One line in the Codex and Pi chat headers: somebody is looking at this session on their
/// phone.
///
/// It exists because the session is genuinely shared. A paired device can read this
/// transcript, send into it and answer the approvals on it, and the owner typing at the Mac
/// should know that without having to remember they left a phone connected in the kitchen.
///
/// The count comes from `BuddyEventHub`, which knows what scope each open `/events` stream
/// was paired for. **Full scope only**, deliberately: a chat-only device reading the same
/// stream cannot reach an agent session at all — it is refused by the scope gate — so
/// counting it here would tell the owner something stronger than what is true. This Mac's
/// own control token and the swarm secret are not devices and are never counted.
///
/// Polled rather than observed: the hub is an actor with no change notification, a badge is
/// not worth inventing one for, and two seconds is well inside the time it takes to notice
/// a line of text appear.
struct BuddyWatchingBadge: View {

    @State private var watchers = 0

    /// How often the badge asks. Slow on purpose — this is a background fact, not a
    /// reading a person is waiting on.
    static let pollInterval: Duration = .seconds(2)

    var body: some View {
        Group {
            if watchers > 0 {
                Label(Self.caption(watchers), systemImage: "iphone.gen3.radiowaves.left.and.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(
                        "A device paired with full control has this session open. It can "
                        + "read the transcript, send messages and answer approvals — the "
                        + "same session, not a copy."
                    )
                    .transition(.opacity)
            }
        }
        .task {
            // Ends with the view: the loop is cancelled when the tab goes away, and the
            // hub is asked nothing while nobody is looking at a chat.
            while !Task.isCancelled {
                let now = await BuddyEventHub.shared.watchingDeviceCount
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
}
