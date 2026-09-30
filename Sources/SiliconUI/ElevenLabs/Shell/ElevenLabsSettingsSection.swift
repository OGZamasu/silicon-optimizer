import AppKit
import SiliconElevenLabs
import SwiftUI

/// Settings → ElevenLabs: connect a key, see the plan it belongs to, pick the region, decide
/// what agents may do, and open the pane.
///
/// A key is verified with ElevenLabs' free account call before anything is stored; the stored
/// key is never read back into the field.
struct ElevenLabsSettingsSection: View {
    @Environment(AppModel.self) private var model
    /// Owned by Settings, not by this section: panes are a `switch`, and a half-typed key must
    /// survive a trip to another pane and back.
    @Binding var draft: String

    @State private var connection = ElevenLabsConnectionModel()
    @State private var confirmingRemove = false
    @FocusState private var keyFieldFocused: Bool

    var body: some View {
        @Bindable var model = model

        Section("ElevenLabs") {
            Text(
                "Speech, sound effects, music, voices, dubbing and voice agents from your own "
                + "ElevenLabs account. Optional: nothing is sent to ElevenLabs until you add a key, "
                + "and everything there spends your ElevenLabs credits, not this Mac's."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            keyRow
            if let failure = Self.errorToShow(connectionFailure: connection.failure, lastError: model.elevenLabsLastError) {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.elevenLabsLinked {
                accountRow
            }
            regionRow
        }

        if model.elevenLabsLinked {
            Section("Agents") {
                Toggle(
                    "Let agents run destructive and real-world ElevenLabs actions",
                    isOn: $model.elevenLabsAllowRiskyForAgents
                )
                Text(
                    "Off: over MCP and the control API, agents may read, generate (spending "
                    + "credits) and edit, but deleting, phone calls and messages, invites, keys, "
                    + "webhooks, secrets and MCP servers are refused, and secrets in answers are hidden."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(
                    "On: agents may run those too, each call still saying confirm: true, and they see "
                    + "the keys and secrets those calls return. This app always asks you first either way."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Key

    private var keyRow: some View {
        LabeledContent("API key") {
            HStack(spacing: 8) {
                if model.elevenLabsLinked {
                    Label("Connected", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                }
                SecureField(
                    "API key",
                    text: $draft,
                    prompt: Text(model.elevenLabsLinked ? "Paste a new key to replace it" : "xi-api-key")
                )
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 200)
                .focused($keyFieldFocused)
                .onSubmit(connect)
                if connection.verifying {
                    ProgressView().controlSize(.small)
                }
                Button(model.elevenLabsLinked ? "Replace" : "Connect", action: connect)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || connection.verifying)
                if model.elevenLabsLinked {
                    Button("Remove key…") { confirmingRemove = true }
                        .disabled(connection.verifying)
                } else {
                    Button("Get a key") {
                        NSWorkspace.shared.open(URL(string: "https://elevenlabs.io/app/settings/api-keys")!)
                    }
                    .buttonStyle(.link)
                }
            }
        }
        .confirmationDialog("Remove the ElevenLabs key?", isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Remove key", role: .destructive) { connection.remove(model: model) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It is deleted from this Mac's Keychain and the ElevenLabs pane leaves the sidebar. The key itself keeps working on ElevenLabs until you revoke it there.")
        }
    }

    /// What goes under the key row: this Connect's failure, else the last thing that went
    /// wrong with the key — a Keychain removal that failed after Remove said it was done.
    static func errorToShow(connectionFailure: String?, lastError: String?) -> String? {
        connectionFailure ?? lastError
    }

    private func connect() {
        let key = draft
        Task {
            if await connection.connect(key: key, model: model) { draft = "" }
        }
    }

    // MARK: - Account

    @ViewBuilder
    private var accountRow: some View {
        if let account = model.elevenLabsAccount {
            LabeledContent("Plan") {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(ElevenLabsCreditsHeader.planName(account.tier))
                    Text("\(account.remainingCharacters.formatted()) of \(account.characterLimit.formatted()) credits left")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if let reset = account.nextResetAt {
                        Text("Resets \(reset.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } else {
            LabeledContent("Plan") {
                Button("Check") { Task { await model.checkElevenLabsAccount() } }
            }
        }
        LabeledContent {
            Button("Open ElevenLabs") { model.selectedTab = .elevenLabs }
        } label: {
            Text(connection.connected ? "Connected. The pane is in the sidebar." : "Everything ElevenLabs does is in its own pane.")
        }
    }

    // MARK: - Region

    private var regionRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Region", selection: Binding(
                get: { model.elevenLabsRegion },
                set: { connection.requestRegion($0, model: model) }
            )) {
                ForEach(ElevenLabsRegion.allCases) { region in
                    Text(region.displayName).tag(region)
                }
            }
            .disabled(connection.verifying)
            Text("Data-residency regions are separate workspaces, each with its own key; Global and US only share one.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let notice = connection.regionNotice {
                Label(notice, systemImage: "hourglass")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(item: Binding(
            get: { connection.pendingRegionChange },
            set: { if $0 == nil { connection.cancelRegionChange() } }
        )) { change in
            ElevenLabsRegionChangeSheet(
                change: change,
                onSwitch: { Task { await connection.switchRegionKeepingKey(model: model) } },
                onRemoveKey: {
                    connection.removeKeyAndSwitchRegion(model: model)
                    keyFieldFocused = true
                },
                onCancel: { connection.cancelRegionChange() }
            )
        }
    }
}

/// Asks before the region changes under a connected key.
struct ElevenLabsRegionChangeSheet: View {
    let change: ElevenLabsConnectionModel.RegionChange
    let onSwitch: () -> Void
    let onRemoveKey: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Switch to \(change.to.displayName)?")
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                if change.keyCarriesOver {
                    Button("Switch", action: onSwitch)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Remove key and enter a new one", action: onRemoveKey)
                        .buttonStyle(.borderedProminent)
                }
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 460)
    }

    private var message: String {
        if change.keyCarriesOver {
            return "\(change.from.displayName) and \(change.to.displayName) are the same account, "
                + "so the connected key keeps working. The balance is checked again on the new host."
        }
        return "Each data-residency region is its own workspace with its own key, so the key "
            + "connected for \(change.from.displayName) will not work on \(change.to.displayName). "
            + "Remove it, then paste the key made for \(change.to.displayName)."
    }
}
