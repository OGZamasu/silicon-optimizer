import Foundation
import SiliconElevenLabs

/// The pane's end of the app model: disconnecting and leaving the pane's place. The key, the
/// client, the account check and linking itself are the core's (`AppModel+ElevenLabs`).
extension AppModel {

    /// Checks the plan and balance with the core's free account call, and tells the pane
    /// whether the account was reachable — the header's refresh, the pane's first look, and
    /// Settings' Check all go through here.
    func checkElevenLabsAccount() async {
        do {
            try await refreshElevenLabsAccount()
            elevenLabsPane.noteSuccess()
        } catch {
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
