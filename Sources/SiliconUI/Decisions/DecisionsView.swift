import SiliconControl
import SiliconRuntime
import SwiftUI

/// Decisions: a place in the sidebar, not a section in Settings.
///
/// Every typed question this app asks — should this be escalated, which skill, which model,
/// is this safe — goes through a lane, and the owner is entitled to see which one, what it
/// costs, and whether it leaves the Mac. That is a screen you open on purpose, so it gets a
/// sidebar entry of its own rather than a heading two thirds of the way down Settings.
///
/// The TypeSafe account sits underneath it, because a key, a budget and a model pin are
/// only ever looked at while deciding who answers.
struct DecisionsView: View {
    @Environment(AppModel.self) private var model
    /// Bumped when the key row stores or clears a key, so the Jev controls below are
    /// rebuilt against the credential that now exists rather than the one that did.
    @State private var jevRevision = 0

    var body: some View {
        Form {
            DecisionsSection()

            Section("TypeSafe (Jev)") {
                TypeSafeKeyRow(onKeyChanged: { jevRevision += 1 })
                Text(
                    "Optional. Lets the decide tool and POST /decide ask TypeSafe's Jev for typed "
                    + "decisions ($0.042 per million input tokens, output free). Without a key the "
                    + "same questions are answered by the lanes above — Laya here, a node, or the "
                    + "model loaded on this Mac — and nothing leaves the Mac."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Link(
                    "Get a key at console.typesafe.ai",
                    destination: URL(string: "https://console.typesafe.ai/settings/keys")!
                )
                .font(.caption)
                JevSection().id(jevRevision)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Decisions")
    }
}
