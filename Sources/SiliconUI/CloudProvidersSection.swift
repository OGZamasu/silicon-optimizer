import AppKit
import SiliconCore
import SwiftUI

/// Settings → Cloud providers.
///
/// The one place in this app where work leaves your hardware, so it reads like an opt-in and
/// not like a default: nothing is configured, nothing is fetched, and no remote model appears
/// in any picker until someone puts a key in. Removing the key puts it all back.
///
/// Models are ticked rather than listed wholesale. OpenRouter alone offers hundreds, and a
/// picker with three local models buried under four hundred remote ones would be a worse
/// version of this app.
struct CloudProvidersSection: View {
    @Environment(AppModel.self) private var model

    /// In-progress key text, never persisted here. A saved key is not read back into the
    /// field — the app has no reason to show a credential it already holds.
    ///
    /// Owned by whoever shows this section rather than by the section itself: Settings puts
    /// its panes behind a `switch`, and a half-typed key must not be thrown away by a trip
    /// to another pane and back.
    @Binding var drafts: [String: String]
    @Binding var search: String

    /// Enough to browse a small catalogue, few enough that a provider with hundreds of models
    /// pushes you towards the search field instead of scrolling a Form forever.
    private static let visibleLimit = 40

    var body: some View {
        Section("Cloud providers") {
            Text(
                "Optional, and off unless you add a key. Your Mac and your swarm need none of "
                + "this — it is here for models no machine you own can run."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            ForEach(CloudProvider.allCases) { provider in
                providerRow(provider)
            }

            if !model.cloudCredentials.isEmpty {
                discoveredModels
                if model.cloudCredentials.configured.contains(where: \.offersAudio) {
                    customAudioModels
                }
            }
        }
    }

    // MARK: - One provider

    @ViewBuilder
    private func providerRow(_ provider: CloudProvider) -> some View {
        let saved = model.cloudCredentials.key(for: provider) != nil

        LabeledContent(provider.displayName) {
            HStack(spacing: 8) {
                if saved {
                    Label("Key saved", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                    Button("Remove") { model.setCloudKey(nil, for: provider) }
                } else {
                    SecureField(
                        "API key",
                        text: Binding(
                            get: { drafts[provider.rawValue] ?? "" },
                            set: { drafts[provider.rawValue] = $0 }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 200)
                    Button("Save") {
                        model.setCloudKey(drafts[provider.rawValue], for: provider)
                        drafts[provider.rawValue] = ""
                    }
                    .disabled(
                        (drafts[provider.rawValue] ?? "")
                            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                    Button("Get a key") { NSWorkspace.shared.open(provider.keyPageURL) }
                        .buttonStyle(.link)
                }
            }
        }

        Text(providerNote(provider))
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func providerNote(_ provider: CloudProvider) -> String {
        switch provider {
        case .gmi:
            "Chat models, plus the speech and music models in the Voice tab."
        case .openRouter:
            "Chat models only — OpenRouter brokers text, not audio."
        case .nvidia:
            "Chat models only, and free to start: the developer program hands out a key "
            + "without a card. Rate limited rather than metered."
        case .tokenHarbor:
            "One key across the big labs. Chat only. Models whose id ends in :free never "
            + "charge your balance."
        case .aiHubMix:
            "Four hundred models, fifty-odd free on daily quotas — the ids ending in -free. "
            + "Chat only."
        }
    }

    // MARK: - What the keys can reach

    @ViewBuilder
    private var discoveredModels: some View {
        HStack {
            if model.cloudRefreshing {
                ProgressView().controlSize(.small)
                Text("Asking each provider what it can reach…")
            } else if let error = model.cloudRefreshError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else {
                Text(reachSummary)
            }
            Spacer()
            Button("Refresh") { Task { await model.refreshCloudModels() } }
                .disabled(model.cloudRefreshing)
        }
        .font(.caption)
        .foregroundStyle(.secondary)

        if !model.cloudModels.isEmpty {
            TextField("Search models", text: $search)
                .textFieldStyle(.roundedBorder)

            let matches = filtered
            ForEach(matches.prefix(Self.visibleLimit)) { entry in
                Toggle(isOn: binding(for: entry)) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.displayName)
                        Text(contextNote(entry))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if matches.count > Self.visibleLimit {
                Text(
                    "\(matches.count - Self.visibleLimit) more — search to narrow this down."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if matches.isEmpty {
                Text("Nothing matches “\(search)”.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The audio queue has no listing to ask, so its models are written down — and a written
    /// list goes stale. This is how someone reaches one that shipped after this build did.
    @ViewBuilder
    private var customAudioModels: some View {
        LabeledContent("Extra audio models") {
            TextField(
                "Model ids",
                text: Binding(
                    get: { (model.settings.customCloudAudioModels ?? []).joined(separator: ", ") },
                    set: { typed in
                        model.settings.customCloudAudioModels = typed
                            .split(whereSeparator: { $0 == "," || $0.isNewline })
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                    }
                ),
                prompt: Text("minimax-tts-speech-2.8-turbo")
            )
            .textFieldStyle(.roundedBorder)
        }

        Text(
            "Comma separated. Speech and music ids from your provider's catalogue — anything "
            + "with “music” in it appears under Music, the rest under Speak. A wrong id fails "
            + "when you use it, with the provider's own explanation."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var reachSummary: String {
        let enabled = (model.settings.enabledCloudModels ?? []).count
        guard !model.cloudModels.isEmpty else {
            return "No models found yet. Refresh, or check the key."
        }
        return "\(model.cloudModels.count) models reachable · \(enabled) switched on"
    }

    private var filtered: [CloudModel] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return model.cloudModels }
        return model.cloudModels.filter {
            $0.displayName.localizedCaseInsensitiveContains(needle)
                || $0.id.localizedCaseInsensitiveContains(needle)
        }
    }

    private func contextNote(_ entry: CloudModel) -> String {
        var parts = [entry.provider.displayName, entry.id]
        if let window = entry.contextWindow {
            parts.append("\(window / 1000)K context")
        }
        return parts.joined(separator: " · ")
    }

    /// Ticking writes straight through to settings — the Form's `onChange` saves it, the
    /// same as every other control on this page.
    private func binding(for entry: CloudModel) -> Binding<Bool> {
        Binding(
            get: { (model.settings.enabledCloudModels ?? []).contains(entry.gatewayID) },
            set: { isOn in
                var enabled = model.settings.enabledCloudModels ?? []
                if isOn {
                    if !enabled.contains(entry.gatewayID) { enabled.append(entry.gatewayID) }
                } else {
                    enabled.removeAll { $0 == entry.gatewayID }
                }
                model.settings.enabledCloudModels = enabled
            }
        )
    }
}
