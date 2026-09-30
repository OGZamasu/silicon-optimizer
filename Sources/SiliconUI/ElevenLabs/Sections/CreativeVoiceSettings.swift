import Foundation
import Observation
import SiliconElevenLabs
import SwiftUI

/// Voice settings for one generation — stability, similarity, style, speed, speaker boost —
/// with ranges and defaults from the catalog's `voice_settings` schema. Sent only when the
/// owner overrides the voice's saved settings; otherwise the voice's own apply.
@MainActor
@Observable
final class CreativeVoiceSettings {
    /// The operation whose `voice_settings` schema gives the ranges and defaults.
    let schemaOperationID: String
    /// Send these instead of the voice's saved settings.
    var overrides = false
    var stability: Double = 0.5
    var similarityBoost: Double = 0.75
    var style: Double = 0
    var speed: Double = 1
    var useSpeakerBoost = true
    /// Why the voice's saved settings could not be loaded, if they could not.
    private(set) var loadProblem: String?

    @ObservationIgnored private let savedSettings: ElevenLabsRunner?

    /// The names under `voice_settings` a slider or switch sets.
    static let numberNames = ["stability", "similarity_boost", "style", "speed"]
    static let names = numberNames + ["use_speaker_boost"]

    init(schemaOperationID: String = "text_to_speech_full", savedSettings: ElevenLabsRunner? = nil) {
        self.schemaOperationID = schemaOperationID
        self.savedSettings = savedSettings
        reset()
    }

    func range(_ name: String) -> ClosedRange<Double> {
        CreativeSpec.range(schemaOperationID, "voice_settings.\(name)") ?? 0...1
    }

    func defaultValue(_ name: String) -> Double? {
        CreativeSpec.defaultNumber(schemaOperationID, "voice_settings.\(name)")
    }

    /// Every value back to the spec's default.
    func reset() {
        stability = defaultValue("stability") ?? stability
        similarityBoost = defaultValue("similarity_boost") ?? similarityBoost
        style = defaultValue("style") ?? style
        speed = defaultValue("speed") ?? speed
        useSpeakerBoost = CreativeSpec.defaultBool(schemaOperationID, "voice_settings.use_speaker_boost") ?? useSpeakerBoost
    }

    /// The `voice_settings` object, or nil when the voice's saved settings apply. Style and
    /// speaker boost are left out for a model that cannot use them.
    func json(for model: CreativeModel? = nil) -> JSONValue? {
        guard overrides else { return nil }
        var object: [String: JSONValue] = [
            "stability": .number(Self.rounded(stability)),
            "similarity_boost": .number(Self.rounded(similarityBoost)),
            "speed": .number(Self.rounded(speed)),
        ]
        if model?.canUseStyle ?? true { object["style"] = .number(Self.rounded(style)) }
        if model?.canUseSpeakerBoost ?? true { object["use_speaker_boost"] = .bool(useSpeakerBoost) }
        return .object(object)
    }

    /// Loads values from a `VoiceSettingsResponseModel`, clamped to the ranges.
    func load(_ json: JSONValue) {
        func clamp(_ name: String, _ value: Double?) -> Double? {
            value.map { min(max($0, range(name).lowerBound), range(name).upperBound) }
        }
        stability = clamp("stability", json["stability"].doubleValue) ?? stability
        similarityBoost = clamp("similarity_boost", json["similarity_boost"].doubleValue) ?? similarityBoost
        style = clamp("style", json["style"].doubleValue) ?? style
        speed = clamp("speed", json["speed"].doubleValue) ?? speed
        useSpeakerBoost = json["use_speaker_boost"].boolValue ?? useSpeakerBoost
    }

    /// Starts from `voiceID`'s saved settings (`GET /v1/voices/{voice_id}/settings`, free).
    func loadSaved(voiceID: String) async {
        guard let savedSettings, !voiceID.isEmpty, CreativeRunGate.isKnown(savedSettings) else { return }
        loadProblem = nil
        if case .json(let value, _)? = await savedSettings.perform(arguments: ["voice_id": .string(voiceID)]) {
            load(value)
            overrides = true
        } else {
            loadProblem = savedSettings.errorMessage
        }
    }

    var isLoadingSaved: Bool { savedSettings?.isRunning ?? false }

    /// Two decimals: what a slider can meaningfully set.
    static func rounded(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }
}

/// The settings as sliders, with the switch that decides whether they are sent.
struct CreativeVoiceSettingsCard: View {
    @Bindable var settings: CreativeVoiceSettings
    var model: CreativeModel?
    /// The chosen voice, for "Start from the voice's settings".
    var voiceID: String

    var body: some View {
        CreativeCard("Voice settings", systemImage: "slider.horizontal.3") {
            if settings.isLoadingSaved { ProgressView().controlSize(.small) }
            Button("Start from the voice's settings") {
                Task { await settings.loadSaved(voiceID: voiceID) }
            }
            .controlSize(.small)
            .disabled(voiceID.isEmpty || settings.isLoadingSaved)
            .help("Load the settings saved with this voice (free)")
        } content: {
            Toggle("Override the voice's saved settings for this generation", isOn: $settings.overrides)
            if let problem = settings.loadProblem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
            Group {
                CreativeSlider(
                    title: "Stability", value: $settings.stability, range: settings.range("stability"),
                    step: 0.01, defaultValue: settings.defaultValue("stability"),
                    low: "More expressive", high: "More consistent"
                )
                CreativeSlider(
                    title: "Similarity", value: $settings.similarityBoost,
                    range: settings.range("similarity_boost"), step: 0.01,
                    defaultValue: settings.defaultValue("similarity_boost"),
                    low: "Looser", high: "Closer to the voice"
                )
                if model?.canUseStyle ?? true {
                    CreativeSlider(
                        title: "Style exaggeration", value: $settings.style, range: settings.range("style"),
                        step: 0.01, defaultValue: settings.defaultValue("style"),
                        low: "None", high: "Exaggerated"
                    )
                }
                CreativeSlider(
                    title: "Speed", value: $settings.speed, range: settings.range("speed"), step: 0.01,
                    defaultValue: settings.defaultValue("speed"),
                    format: { String(format: "%.2f×", $0) }, low: "Slower", high: "Faster"
                )
                if model?.canUseSpeakerBoost ?? true {
                    Toggle("Speaker boost", isOn: $settings.useSpeakerBoost)
                        .help("Closer to the original speaker, at slightly higher latency")
                }
                HStack {
                    Spacer()
                    Button("Reset to defaults") { settings.reset() }.controlSize(.small)
                }
            }
            .disabled(!settings.overrides)
            .opacity(settings.overrides ? 1 : 0.55)
        }
    }
}

/// Pronunciation dictionaries to apply, in order, chosen from the account's.
struct CreativeDictionaryPicker: View {
    @Binding var locators: [CreativeDictionaryLocator]
    let directory: CreativeDictionaryDirectory
    var maxItems: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Pronunciation dictionaries")
                Spacer()
                Menu("Add") {
                    if directory.dictionaries.isEmpty {
                        Text(directory.runner.isRunning ? "Loading…" : "No dictionaries on this account")
                    }
                    ForEach(directory.dictionaries) { dictionary in
                        Button(dictionary.name) {
                            locators.append(CreativeDictionaryLocator(
                                dictionaryID: dictionary.id, versionID: dictionary.latestVersionID,
                                name: dictionary.name
                            ))
                        }
                        .disabled(locators.contains { $0.dictionaryID == dictionary.id })
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(maxItems.map { locators.count >= $0 } ?? false)
            }
            .font(.callout)
            if locators.isEmpty {
                Text("None. Dictionaries are managed under Pronunciation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(locators.enumerated()), id: \.element.id) { index, locator in
                HStack(spacing: 6) {
                    Text("\(index + 1).").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Text(locator.name).lineLimit(1)
                    if let version = locator.versionID {
                        Text("version \(version.prefix(8))").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        locators.remove(at: index)
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(locator.name)")
                }
                .font(.callout)
            }
            if let error = directory.runner.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .task { await directory.loadIfNeeded() }
    }
}

/// The Run button, and under it every reason it is not ready yet.
struct CreativeRunRow: View {
    let runner: ElevenLabsRunner
    var title: String
    var estimatedCharacters: Int?
    var problems: [String]
    var note: String?
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ElevenLabsRunButton(
                runner: runner, title: title, estimatedCharacters: estimatedCharacters,
                disabled: !problems.isEmpty, action: action
            )
            if let note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(problems, id: \.self) { problem in
                Label(problem, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
