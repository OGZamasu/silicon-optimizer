import Foundation
import Observation
import SiliconElevenLabs
import SwiftUI

/// Sound effects from a description: how long, how literal, looping or not — each take kept
/// to compare.
struct SoundEffectsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SoundEffectsScreen(screen: CreativeSession.shared(for: model).soundEffects)
    }
}

@MainActor
@Observable
final class SoundEffectsScreenModel: CreativeScreenModel {

    static let generate = "sound_generation"
    static let operationIDs = [generate]

    static let controls: [CreativeControl] = [
        CreativeControl("Description", operationIDs, "text"),
        CreativeControl("Length", operationIDs, "duration_seconds"),
        CreativeControl("Prompt influence", operationIDs, "prompt_influence"),
        CreativeControl("Loop", operationIDs, "loop"),
        CreativeControl("Model", operationIDs, "model_id"),
        CreativeControl("Output format", operationIDs, "output_format"),
    ]

    let session: CreativeSession
    let runner: ElevenLabsRunner
    var text = ""
    /// Nil lets the model choose a length from the description.
    var automaticDuration = true
    var duration: Double
    var promptInfluence: Double
    var loop = false
    var modelID: String
    var outputFormat: String

    private(set) var takes: [CreativeTake] = []

    init(session: CreativeSession) {
        self.session = session
        runner = session.runner(Self.generate, title: "Sound effect")
        let range = CreativeSpec.range(Self.generate, "duration_seconds") ?? 0.5...30
        duration = min(max(5, range.lowerBound), range.upperBound)
        promptInfluence = CreativeSpec.defaultNumber(Self.generate, "prompt_influence") ?? 0.3
        loop = CreativeSpec.defaultBool(Self.generate, "loop") ?? false
        modelID = CreativeSpec.defaultString(Self.generate, "model_id")
            ?? CreativeSpec.choices(Self.generate, "model_id").first ?? ""
        outputFormat = CreativeSpec.defaultString(Self.generate, "output_format") ?? ""
    }

    var durationRange: ClosedRange<Double> { CreativeSpec.range(Self.generate, "duration_seconds") ?? 0.5...30 }
    var influenceRange: ClosedRange<Double> { CreativeSpec.range(Self.generate, "prompt_influence") ?? 0...1 }
    var models: [String] { CreativeSpec.choices(Self.generate, "model_id") }
    var outputFormats: [String] { CreativeSpec.choices(Self.generate, "output_format") }

    var problems: [String] {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? ["Describe the sound."] : []
    }

    func arguments() -> [String: JSONValue] {
        var arguments: [String: JSONValue] = [
            "text": .string(text),
            "prompt_influence": .number(CreativeVoiceSettings.rounded(promptInfluence)),
            "output_format": .string(outputFormat),
        ]
        if !automaticDuration { arguments["duration_seconds"] = .number((duration * 10).rounded() / 10) }
        if loop { arguments["loop"] = true }
        if !modelID.isEmpty { arguments["model_id"] = .string(modelID) }
        return arguments
    }

    func generate() async {
        guard problems.isEmpty, CreativeRunGate.isKnown(runner) else { return }
        guard let result = await runner.perform(arguments: arguments()) else { return }
        var title = text.count > 60 ? String(text.prefix(59)) + "…" : text
        if !automaticDuration { title += String(format: " · %.1f s", duration) }
        if loop { title += " · loop" }
        if let take = CreativeTake(result: result, title: title) { takes.insert(take, at: 0) }
    }

    func removeTake(_ take: CreativeTake) {
        takes.removeAll { $0.id == take.id }
    }
}

struct SoundEffectsScreen: View {
    @Bindable var screen: SoundEffectsScreenModel

    var body: some View {
        ElevenLabsSectionPage(.soundEffects) {
            CreativeCard("Describe the sound", systemImage: "speaker.wave.3") {
                ElevenLabsTextArea(
                    text: $screen.text,
                    prompt: "Glass shattering on a tiled floor, then a cat running away", minHeight: 90
                )
            }
            CreativeCard("Shape", systemImage: "slider.horizontal.3") {
                Toggle("Let the model choose the length", isOn: $screen.automaticDuration)
                if !screen.automaticDuration {
                    CreativeSlider(
                        title: "Length", value: $screen.duration, range: screen.durationRange, step: 0.1,
                        format: { String(format: "%.1f s", $0) }
                    )
                }
                CreativeSlider(
                    title: "Prompt influence", value: $screen.promptInfluence, range: screen.influenceRange,
                    step: 0.01, defaultValue: CreativeSpec.defaultNumber(SoundEffectsScreenModel.generate, "prompt_influence"),
                    low: "More creative", high: "More literal"
                )
                Toggle("Loops seamlessly", isOn: $screen.loop)
                if screen.models.count > 1 {
                    CreativeChoicePicker(title: "Model", selection: $screen.modelID, choices: screen.models)
                } else if !screen.modelID.isEmpty {
                    LabeledContent("Model", value: screen.modelID)
                }
                CreativeOutputFormatPicker(selection: $screen.outputFormat, choices: screen.outputFormats)
            }
            CreativeRunRow(runner: screen.runner, title: "Generate sound", problems: screen.problems) {
                Task { await screen.generate() }
            }
            if screen.runner.phase != .idle || !screen.takes.isEmpty {
                CreativeCard("Result", systemImage: "play.circle") {
                    if let take = screen.takes.first {
                        ElevenLabsAudioPlayerView(url: take.file, title: take.title).id(take.file)
                        if let meta = screen.runner.result?.meta { ElevenLabsMetaLine(meta: meta) }
                    }
                    ElevenLabsRunnerOutput(runner: screen.runner, showsResult: false)
                }
            }
            CreativeTakesList(takes: Array(screen.takes.dropFirst())) { screen.removeTake($0) }
        }
    }
}
