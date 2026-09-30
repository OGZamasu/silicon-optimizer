import SwiftUI

/// The place for talking to an agent live — mic in, the agent's voice out — which arrives with
/// the realtime wave (the Agents WebSocket, DESIGN.md §8). Until then it says so plainly and
/// does nothing: no socket, no microphone, no signed URL is fetched from here.
///
/// The realtime builder replaces this file wholesale (or points it at the "Talk to an agent"
/// section it adds); the name and the `init(agentID:agentName:)` the Agents editor calls stay.
struct AgentsLiveConversationSlot: View {
    let agentID: String
    let agentName: String

    var body: some View {
        AgentsCard("Talk to “\(agentName)”", subtitle: "Live voice conversation — coming with the realtime update.") {
            HStack(spacing: 10) {
                Image(systemName: "mic.slash")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
                Text("Speaking with an agent from this Mac needs the realtime connection, which is not part of this build. Until then, test the agent in Testing (simulated conversations and response tests), or get a signed URL in Conversations to talk to it from your own page.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Start a live conversation") {}
                .disabled(true)
                .help("Arrives with the realtime update")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Live conversation with \(agentName): not available yet")
    }
}
