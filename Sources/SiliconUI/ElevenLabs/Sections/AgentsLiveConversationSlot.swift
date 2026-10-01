import SwiftUI

/// The place under the Agents editor for talking to the agent live — the realtime wave's
/// "Talk to an agent" section, opened with this agent chosen. Nothing starts from here: no
/// socket, no microphone, no signed URL; the owner presses Start on that screen.
struct AgentsLiveConversationSlot: View {
    /// Optional: the Agents screens are drawn without an app model in previews and tests.
    @Environment(AppModel.self) private var model: AppModel?
    let agentID: String
    let agentName: String

    var body: some View {
        AgentsCard("Talk to “\(agentName)”", subtitle: "A live conversation — your microphone and the agent's voice, or text both ways.") {
            HStack(spacing: 10) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("Opens Talk to an agent with this agent chosen. Nothing starts until you press Start there, and the microphone stays off until then.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Talk to it live…") { model?.openLiveAgent(agentID: agentID, name: agentName) }
                .disabled(model == nil)
                .help("Opens ElevenLabs → Talk to an agent")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Live conversation with \(agentName)")
    }
}
