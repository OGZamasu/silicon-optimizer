import Foundation
import SiliconElevenLabs

/// The pane's end of the app model: the balance check, disconnecting, and where runners put
/// streamed audio. The key, the client and linking itself are the core's
/// (`AppModel+ElevenLabs`).
extension AppModel {

    /// Where a stream played as it arrives is kept: the app's ElevenLabs output folder. Nil
    /// until the core's sink is in place, which makes `.play` collect instead.
    var elevenLabsRunnerSink: (any ElevenLabsFileSink)? {
        nil
    }

    /// Checks the plan and balance again with the free account call, and remembers the
    /// answer for the header and Settings.
    func refreshElevenLabsBalance() async {
        guard let client = elevenLabsClient else { return }
        do {
            elevenLabsLink.account = try await client.account()
            elevenLabsLink.lastError = nil
            elevenLabsPane.noteSuccess()
        } catch {
            elevenLabsLink.lastError = ElevenLabsRunnerFailure(error).message
            elevenLabsPane.noteFailure(error)
        }
    }

    /// Removes the key and forgets what the pane held for this account. The pane leaves the
    /// sidebar, so a window showing it moves to Settings.
    func disconnectElevenLabs() {
        unlinkElevenLabs()
        elevenLabsPane.reset()
        leaveHiddenTab()
    }

    /// Moves the selection to Settings when it is on a place the sidebar no longer lists —
    /// the ElevenLabs pane, once its key is gone.
    func leaveHiddenTab() {
        if !selectedTab.isOffered(elevenLabsLinked: elevenLabsLinked) { selectedTab = .settings }
    }
}
