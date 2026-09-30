import SiliconElevenLabs
import SwiftUI

/// Voice design: describe a voice (or how to change one of yours), listen to what ElevenLabs
/// makes of it, and keep the one that fits.
struct VoiceDesignSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VoiceDesignScreen(model: VoicesStudioModels.model(VoiceDesignSectionModel.self, for: app) {
            VoiceDesignSectionModel(environment: $0)
        })
    }
}

struct VoiceDesignScreen: View {
    @Bindable var model: VoiceDesignSectionModel

    var body: some View {
        ElevenLabsSectionPage(.voiceDesign) {
            Picker("Mode", selection: $model.mode) {
                ForEach(VoiceDesignSectionModel.Mode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: model.mode) {
                model.guidanceScale = VoicesStudioSchema.defaultNumber(model.operationID, "guidance_scale") ?? model.guidanceScale
            }

            VoiceDesignPromptCard(model: model)
            if !model.previews.isEmpty {
                VoiceDesignPreviewsCard(model: model)
            }
            VoicesStudioActivity(actions: model.actions, fallback: model.actions.runner(model.operationID))
        }
    }
}

struct VoiceDesignPromptCard: View {
    @Bindable var model: VoiceDesignSectionModel
    @State private var showsAdvanced = false

    var body: some View {
        Card(title: model.mode == .design ? "Describe the voice" : "Describe the change", systemImage: "wand.and.stars") {
            if model.mode == .remix {
                ElevenLabsVoicePicker(selection: $model.remixVoiceID, title: "Start from",
                                      directory: model.directory)
            }
            VoicesStudioCountedEditor(
                title: model.mode == .design ? "Description" : "What to change",
                text: $model.voiceDescription,
                minimum: model.descriptionLimits.0, maximum: model.descriptionLimits.1, height: 70,
                prompt: model.mode == .design
                    ? "A calm, low-pitched narrator in their fifties with a warm Scottish accent."
                    : "Make it brighter and a little faster."
            )
            Toggle("Let ElevenLabs write the preview text", isOn: $model.autoGenerateText)
                .help(VoicesStudioSchema.description(model.operationID, "auto_generate_text"))
            if !model.autoGenerateText {
                VoicesStudioCountedEditor(
                    title: "Preview text", text: $model.text,
                    minimum: model.textLimits.0, maximum: model.textLimits.1, height: 70
                )
            }
            if model.mode == .design, !model.models.isEmpty {
                VoicesStudioChoicePicker(title: "Model", selection: $model.modelID, choices: model.models)
                    .help(VoicesStudioSchema.description("text_to_voice_design", "model_id"))
            }
            DisclosureGroup("More settings", isExpanded: $showsAdvanced) {
                VStack(alignment: .leading, spacing: 8) {
                    VoicesStudioSlider(
                        title: "Loudness", value: $model.loudness,
                        range: VoiceDesignSectionModel.range(model.operationID, "loudness", fallback: -1...1),
                        help: VoicesStudioSchema.description(model.operationID, "loudness")
                    )
                    VoicesStudioSlider(
                        title: "Guidance", value: $model.guidanceScale,
                        range: VoiceDesignSectionModel.range(model.operationID, "guidance_scale", fallback: 0...100),
                        step: 0.5, help: VoicesStudioSchema.description(model.operationID, "guidance_scale")
                    )
                    if model.mode == .design {
                        Toggle("Set quality", isOn: $model.setsQuality)
                        if model.setsQuality {
                            VoicesStudioSlider(
                                title: "Quality", value: $model.quality,
                                range: VoiceDesignSectionModel.range("text_to_voice_design", "quality", fallback: -1...1),
                                help: VoicesStudioSchema.description("text_to_voice_design", "quality")
                            )
                        }
                        Toggle("Enhance the description first", isOn: $model.shouldEnhance)
                            .help(VoicesStudioSchema.description("text_to_voice_design", "should_enhance"))
                    }
                    if model.supportsReference || model.mode == .remix {
                        Toggle("Set prompt strength", isOn: $model.setsPromptStrength)
                        if model.setsPromptStrength {
                            VoicesStudioSlider(
                                title: "Prompt strength", value: $model.promptStrength,
                                range: VoiceDesignSectionModel.range(model.operationID, "prompt_strength", fallback: 0...1),
                                help: VoicesStudioSchema.description(model.operationID, "prompt_strength")
                            )
                        }
                    }
                    if model.supportsReference {
                        VoicesStudioFilePicker(title: "Reference audio", files: $model.referenceAudio,
                                               help: VoicesStudioSchema.description("text_to_voice_design", "reference_audio_base64"))
                    }
                    TextField("Seed (optional)", text: $model.seed)
                        .textFieldStyle(.roundedBorder)
                        .help(VoicesStudioSchema.description(model.operationID, "seed"))
                    VoicesStudioChoicePicker(title: "Output format", selection: $model.outputFormat,
                                             choices: model.outputFormats)
                    Toggle("Return ids only, fetch each preview's audio when played", isOn: $model.streamPreviews)
                        .help(VoicesStudioSchema.description(model.operationID, "stream_previews"))
                }
                .padding(.top, 6)
            }
            .font(.callout)
            if !model.problems.isEmpty {
                ElevenLabsProblemList(problems: model.problems)
            }
            if let runner = model.actions.runner(model.operationID) {
                VoicesStudioRunButton(
                    actions: model.actions, runner: runner, title: model.mode == .design ? "Design voices" : "Remix",
                    disabled: model.voiceDescription.trimmingCharacters(in: .whitespaces).isEmpty
                ) {
                    Task { await model.generate() }
                }
            }
        }
    }
}

struct VoiceDesignPreviewsCard: View {
    @Bindable var model: VoiceDesignSectionModel

    var body: some View {
        Card(title: "Previews", systemImage: "play.square.stack") {
            if let text = model.previewText, !text.isEmpty {
                Text("“\(text)”").font(.callout).foregroundStyle(.secondary).italic()
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(model.previews.enumerated()), id: \.element.id) { index, preview in
                VoiceDesignPreviewRow(model: model, preview: preview, number: index + 1)
            }
            Divider()
            Text("Keep the chosen preview").font(.headline)
            TextField("Name", text: $model.saveName).textFieldStyle(.roundedBorder)
            VoicesStudioCountedEditor(
                title: "Description", text: $model.saveDescription,
                minimum: VoicesStudioSchema.minLength("create_voice", "voice_description"),
                maximum: VoicesStudioSchema.maxLength("create_voice", "voice_description"), height: 50
            )
            VStack(alignment: .leading, spacing: 2) {
                Text("Labels, one “key: value” per line").font(.caption).foregroundStyle(.secondary)
                ElevenLabsTextArea(text: $model.saveLabels, prompt: "accent: Scottish", minHeight: 40)
            }
            HStack {
                if let saved = model.savedVoiceID {
                    Label("Saved as \(saved)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).font(.callout).textSelection(.enabled)
                }
                Spacer()
                Button("Save to my voices") { Task { await model.save() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canSave || model.actions.isRunning("create_voice"))
            }
        }
    }
}

struct VoiceDesignPreviewRow: View {
    @Bindable var model: VoiceDesignSectionModel
    let preview: VoiceDesignPreview
    let number: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: model.chosenPreview == preview.id ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(model.chosenPreview == preview.id ? Color.accentColor : .secondary)
                    .onTapGesture { model.chosenPreview = preview.id }
                    .accessibilityLabel("Choose preview \(number)")
                    .accessibilityAddTraits(.isButton)
                Text("Preview \(number)").font(.callout.weight(.medium))
                Text([VoicesStudioFormat.duration(preview.durationSecs), preview.language]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if preview.file == nil {
                    Button("Fetch audio") { Task { await model.fetchAudio(for: preview) } }
                        .controlSize(.small)
                }
            }
            if let file = preview.file {
                ElevenLabsAudioPlayerView(url: file).id(file)
                    .simultaneousGesture(TapGesture().onEnded { model.notePlayed(preview) })
            }
        }
        .padding(8)
        .background(model.chosenPreview == preview.id ? Color.accentColor.opacity(0.08) : .clear,
                    in: .rect(cornerRadius: 8))
    }
}
