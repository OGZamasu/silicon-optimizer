import Foundation
import Observation
import SiliconElevenLabs
import SwiftUI

/// The models this account can use, what each can do, what it costs and which languages it
/// speaks — and one click to use one.
struct ModelsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ModelsScreen(screen: CreativeSession.shared(for: model).modelsScreen)
    }
}

@MainActor
@Observable
final class ModelsScreenModel: CreativeScreenModel {

    /// A capability to filter by.
    enum Capability: String, CaseIterable, Identifiable {
        case textToSpeech
        case voiceConversion
        case style
        case speakerBoost
        case finetuning

        var id: String { rawValue }
        var title: String {
            switch self {
            case .textToSpeech: "Text to speech"
            case .voiceConversion: "Voice changer"
            case .style: "Style"
            case .speakerBoost: "Speaker boost"
            case .finetuning: "Fine-tuning"
            }
        }

        func holds(for model: CreativeModel) -> Bool {
            switch self {
            case .textToSpeech: model.canDoTextToSpeech
            case .voiceConversion: model.canDoVoiceConversion
            case .style: model.canUseStyle
            case .speakerBoost: model.canUseSpeakerBoost
            case .finetuning: model.canBeFinetuned
            }
        }
    }

    static let list = "get_models"
    static let operationIDs = [list]
    /// `GET /v1/models` takes no arguments; the screen's filters work on the answer.
    static let controls: [CreativeControl] = []

    let session: CreativeSession
    var search = ""
    var required: Set<Capability> = []

    init(session: CreativeSession) {
        self.session = session
    }

    var directory: CreativeModelsDirectory { session.models }

    /// The models that have every chosen capability and match the search (in the name, id,
    /// description or a language).
    var shown: [CreativeModel] {
        let words = search.lowercased().split(whereSeparator: \.isWhitespace)
        return directory.models.filter { model in
            guard required.allSatisfy({ $0.holds(for: model) }) else { return false }
            guard !words.isEmpty else { return true }
            let haystack = ([model.name, model.id, model.description] + model.languages.flatMap { [$0.name, $0.id] })
                .joined(separator: " ").lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    func useForSpeech(_ model: CreativeModel) {
        session.speech.modelID = model.id
        session.open(.speech)
    }

    func useForVoiceChanger(_ model: CreativeModel) {
        session.voiceChanger.modelID = model.id
        session.open(.voiceChanger)
    }
}

struct ModelsScreen: View {
    @Bindable var screen: ModelsScreenModel

    var body: some View {
        ElevenLabsSectionPage(.models) {
            Button {
                Task { await screen.directory.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(screen.directory.loading)
        } content: {
            CreativeCard {
                TextField("Search", text: $screen.search, prompt: Text("Search by name or language"))
                    .textFieldStyle(.roundedBorder)
                CreativeFlowLayout {
                    ForEach(ModelsScreenModel.Capability.allCases) { capability in
                        CreativeChipToggle(title: capability.title, isOn: creativeMembership(capability, in: $screen.required))
                    }
                }
            }
            if screen.directory.loading, screen.directory.models.isEmpty {
                ProgressView().frame(maxWidth: .infinity)
            }
            if screen.directory.runner.phase != .idle {
                ElevenLabsRunnerOutput(runner: screen.directory.runner, showsResult: false)
            }
            let shown = screen.shown
            if screen.directory.loaded, shown.isEmpty {
                Text(screen.directory.models.isEmpty ? "No models listed." : "No model has everything asked for.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(shown) { model in
                ModelCard(model: model, screen: screen)
            }
        }
        .task { await screen.directory.loadIfNeeded() }
    }
}

private struct ModelCard: View {
    let model: CreativeModel
    let screen: ModelsScreenModel
    @State private var showsLanguages = false

    var body: some View {
        CreativeCard(model.name) {
            Text(model.id)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        } content: {
            if !model.description.isEmpty {
                Text(model.description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            CreativeFlowLayout {
                ForEach(ModelsScreenModel.Capability.allCases) { capability in
                    let holds = capability.holds(for: model)
                    Label(capability.title, systemImage: holds ? "checkmark.circle.fill" : "minus.circle")
                        .font(.caption)
                        .foregroundStyle(holds ? Color.green : Color.secondary)
                }
                if model.servesProVoices {
                    Label("Professional voices", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                }
                if model.requiresAlphaAccess {
                    Label("Alpha access", systemImage: "lock").font(.caption).foregroundStyle(.orange)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                if let multiplier = model.characterCostMultiplier {
                    GridRow {
                        Text("Cost").foregroundStyle(.secondary)
                        Text(String(format: "%g× characters", multiplier))
                    }
                }
                if let limit = model.maximumTextLengthPerRequest, limit > 0 {
                    GridRow {
                        Text("Per request").foregroundStyle(.secondary)
                        Text("\(limit.formatted()) characters")
                    }
                }
                if let free = model.maxCharactersFreeUser, let paid = model.maxCharactersSubscribedUser, free + paid > 0 {
                    GridRow {
                        Text("Request limit").foregroundStyle(.secondary)
                        Text("\(free.formatted()) free · \(paid.formatted()) subscribed")
                    }
                }
                if let group = model.concurrencyGroup {
                    GridRow {
                        Text("Concurrency").foregroundStyle(.secondary)
                        Text(group)
                    }
                }
            }
            .font(.callout)
            DisclosureGroup(isExpanded: $showsLanguages) {
                CreativeFlowLayout {
                    ForEach(model.languages, id: \.id) { language in
                        Text(language.name)
                            .font(.caption)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: .capsule)
                    }
                }
                .padding(.top, 4)
            } label: {
                Text("\(model.languages.count) \(model.languages.count == 1 ? "language" : "languages") — \(model.languageSummary)")
                    .font(.callout)
            }
            HStack(spacing: 8) {
                if model.canDoTextToSpeech {
                    Button("Use in Speech") { screen.useForSpeech(model) }
                }
                if model.canDoVoiceConversion {
                    Button("Use in Voice changer") { screen.useForVoiceChanger(model) }
                }
            }
            .controlSize(.small)
        }
    }
}
