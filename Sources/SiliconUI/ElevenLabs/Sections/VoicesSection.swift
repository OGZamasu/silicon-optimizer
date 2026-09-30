import SiliconElevenLabs
import SwiftUI

/// My voices: every voice on the account with its settings and samples, instant cloning from
/// a few recordings, the professional-clone workflow (samples, speakers, verification,
/// training), and a search of the shared library for voices that sound like a recording.
struct VoicesSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VoicesScreen(model: VoicesStudioModels.model(VoicesSectionModel.self, for: app) {
            VoicesSectionModel(environment: $0)
        })
    }
}

struct VoicesScreen: View {
    @Bindable var model: VoicesSectionModel

    var body: some View {
        ElevenLabsSectionPage(.voices) {
            Button {
                Task { await model.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(model.isListing)
        } content: {
            Picker("Show", selection: $model.mode) {
                ForEach(VoicesSectionModel.Mode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch model.mode {
            case .voices:
                VoicesListCard(model: model)
                if let voice = model.selected {
                    VoicesDetailCard(model: model, voice: voice)
                }
            case .clone:
                VoicesCloneCard(model: model)
            case .professional:
                VoicesProfessionalView(model: model)
            case .similar:
                VoicesSimilarCard(model: model)
            }

            VoicesStudioActivity(actions: model.actions, fallback: model.listRunner)
        }
        .task { await model.refreshIfNeeded() }
    }
}

// MARK: - List

struct VoicesListCard: View {
    @Bindable var model: VoicesSectionModel

    var body: some View {
        Card(title: model.totalCount.map { "\($0) voices" } ?? "Voices", systemImage: "person.crop.circle") {
            filters
            VoicesStudioListState(
                loading: model.isListing, problem: model.listProblem, isEmpty: model.rows.isEmpty,
                emptyText: model.loadedOnce ? "No voices match." : "Your voices appear here."
            )
            VStack(spacing: 2) {
                ForEach(model.rows) { voice in
                    VoicesRow(voice: voice, selected: model.selected?.id == voice.id, directory: model.directory) {
                        Task { await model.select(voice.id) }
                    }
                }
            }
            VoicesStudioMoreButton(hasMore: model.hasMore, loading: model.isListing) {
                Task { await model.loadMore() }
            }
        }
    }

    private var filters: some View {
        HStack(spacing: 8) {
            TextField("Search name, description, labels", text: $model.search)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await model.refresh() } }
            Picker("Kind", selection: $model.category) {
                Text("All kinds").tag("")
                ForEach(VoicesSectionModel.categories, id: \.self) { Text(VoicesStudioFormat.words($0)).tag($0) }
            }
            .fixedSize()
            Picker("Source", selection: $model.voiceType) {
                Text("All sources").tag("")
                ForEach(VoicesSectionModel.voiceTypes, id: \.self) { Text(VoicesStudioFormat.words($0)).tag($0) }
            }
            .fixedSize()
            Picker("Sort", selection: $model.sort) {
                Text("Default order").tag("")
                Text("Name").tag("name")
                Text("Newest").tag("created_at_unix")
            }
            .fixedSize()
        }
        .labelsHidden()
        .onChange(of: model.category) { Task { await model.refresh() } }
        .onChange(of: model.voiceType) { Task { await model.refresh() } }
        .onChange(of: model.sort) { Task { await model.refresh() } }
    }
}

/// A voice in a list: its sample to play, name, what it sounds like, and its kind.
struct VoicesRow: View {
    let voice: VoicesVoice
    let selected: Bool
    let directory: ElevenLabsVoiceDirectory
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VoicesPreviewButton(entry: voice.directoryEntry, directory: directory)
            VStack(alignment: .leading, spacing: 1) {
                Text(voice.name).font(.callout.weight(.medium)).lineLimit(1)
                if !voice.labelSummary.isEmpty {
                    Text(voice.labelSummary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if let state = voice.fineTuning?.states.values.first(where: { $0 != "not_started" }) {
                VoicesStudioStatusBadge(status: state)
            }
            if let category = voice.category {
                Badge(text: VoicesStudioFormat.words(category), tint: category == "premade" ? .secondary : .accentColor)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(selected ? Color.accentColor.opacity(0.12) : .clear, in: .rect(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(voice.name)
    }
}

/// Plays a voice's public sample through the pane's shared directory, which keeps one playing
/// at a time.
struct VoicesPreviewButton: View {
    let entry: ElevenLabsVoice
    let directory: ElevenLabsVoiceDirectory

    var body: some View {
        let playing = directory.previewing == entry.id
        Button {
            directory.togglePreview(entry)
        } label: {
            Image(systemName: playing ? "stop.circle.fill" : "play.circle")
                .font(.title3)
        }
        .buttonStyle(.borderless)
        .disabled(entry.previewURL == nil)
        .help(entry.previewURL == nil ? "No public sample" : (playing ? "Stop" : "Play \(entry.name)'s sample"))
        .accessibilityLabel(playing ? "Stop sample" : "Play sample")
    }
}

// MARK: - Detail

struct VoicesDetailCard: View {
    @Bindable var model: VoicesSectionModel
    let voice: VoicesVoice
    @State private var showsReplicate = false

    var body: some View {
        Card(title: voice.name, systemImage: "waveform") {
            HStack(spacing: 8) {
                if let category = voice.category { Badge(text: VoicesStudioFormat.words(category), tint: .accentColor) }
                if voice.requiresVerification == true {
                    VoicesStudioStatusBadge(status: voice.isVerified == true ? "verified" : "pending")
                }
                Text(voice.id).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                Spacer()
                VoicesPreviewButton(entry: voice.directoryEntry, directory: model.directory)
            }
            if let description = voice.description, !description.isEmpty {
                Text(description).font(.callout).foregroundStyle(.secondary)
            }
            VoicesStudioFact("Created", VoicesStudioFormat.date(unixSeconds: voice.createdAt))
            VoicesStudioFact("Labels", voice.labels.isEmpty ? nil : voice.labelSummary)
            if voice.isProfessional {
                HStack {
                    Text("A professional clone: samples, verification and training are in Professional clone.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Open") { model.mode = .professional }.controlSize(.small)
                }
            }
            Divider()
            VoicesSettingsEditor(model: model)
            Divider()
            VoicesEditForm(model: model, voice: voice)
            Divider()
            VoicesSamplesList(model: model, voice: voice)
            Divider()
            DisclosureGroup("Copy to a data-residency workspace", isExpanded: $showsReplicate) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Target workspace id", text: $model.replicateWorkspaceID)
                        .textFieldStyle(.roundedBorder)
                    Toggle("Keep the same voice id", isOn: $model.replicatePreservesID)
                    Button("Copy voice…") { Task { await model.replicate() } }
                        .disabled(model.replicateWorkspaceID.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.top, 6)
            }
            .font(.callout)
            HStack {
                Spacer()
                Button(role: .destructive) {
                    Task { await model.deleteSelected() }
                } label: {
                    Label("Delete voice…", systemImage: "trash")
                }
                .disabled(voice.category == "premade")
                .help(voice.category == "premade" ? "Premade voices cannot be deleted" : "Delete \(voice.name)")
            }
        }
    }
}

struct VoicesSettingsEditor: View {
    @Bindable var model: VoicesSectionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Settings").font(.headline)
                Spacer()
                Button("Account defaults") { Task { await model.loadDefaultSettings() } }
                    .controlSize(.small)
                    .help("Put the account's default settings in the sliders; Save keeps them")
                Button("Save settings") { Task { await model.saveSettings() } }
                    .controlSize(.small)
                    .disabled(model.settingsDraft == nil)
            }
            if let draft = Binding($model.settingsDraft) {
                VoicesStudioSlider(title: "Stability", value: draft.stability, range: VoicesSectionModel.stabilityRange,
                                   help: VoicesStudioSchema.description("edit_voice_settings", "stability"))
                VoicesStudioSlider(title: "Similarity", value: draft.similarityBoost, range: VoicesSectionModel.similarityRange,
                                   help: VoicesStudioSchema.description("edit_voice_settings", "similarity_boost"))
                VoicesStudioSlider(title: "Style", value: draft.style, range: VoicesSectionModel.styleRange,
                                   help: VoicesStudioSchema.description("edit_voice_settings", "style"))
                VoicesStudioSlider(title: "Speed", value: draft.speed, range: VoicesSectionModel.speedRange,
                                   help: VoicesStudioSchema.description("edit_voice_settings", "speed"))
                Toggle("Speaker boost", isOn: draft.useSpeakerBoost)
                    .help(VoicesStudioSchema.description("edit_voice_settings", "use_speaker_boost"))
            } else if let problem = model.detailProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                Button("Try again") { Task { await model.reloadSelected() } }.controlSize(.small)
            } else {
                Text("Loading this voice's settings…").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct VoicesEditForm: View {
    @Bindable var model: VoicesSectionModel
    let voice: VoicesVoice

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Name, description and labels").font(.headline)
            LabeledContent("Name") {
                TextField("Name", text: $model.editDraft.name).textFieldStyle(.roundedBorder).labelsHidden()
            }
            LabeledContent("Description") {
                TextField("Description", text: $model.editDraft.description, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .lineLimit(1...3)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Labels, one “key: value” per line (accent, age, gender, use case…)")
                    .font(.caption).foregroundStyle(.secondary)
                ElevenLabsTextArea(text: $model.editDraft.labels, prompt: "accent: British", minHeight: 44)
            }
            if !voice.isProfessional {
                VoicesStudioFilePicker(title: "Add samples", files: $model.editDraft.files, multiple: true,
                                       help: VoicesStudioSchema.description("edit_voice", "files"))
                Toggle("Remove background noise from new samples", isOn: $model.editDraft.removeBackgroundNoise)
                    .help(VoicesStudioSchema.description("edit_voice", "remove_background_noise"))
            }
            HStack {
                Spacer()
                Button("Save changes") { Task { await model.saveEdit() } }
                    .disabled(model.editDraft.name.trimmingCharacters(in: .whitespaces).isEmpty
                              || model.actions.isRunning("edit_voice"))
            }
        }
    }
}

struct VoicesSamplesList: View {
    let model: VoicesSectionModel
    let voice: VoicesVoice

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(voice.samples.isEmpty ? "No samples" : "\(voice.samples.count) samples").font(.headline)
            ForEach(voice.samples) { sample in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Image(systemName: "waveform").foregroundStyle(.secondary)
                        Text(sample.fileName).lineLimit(1).truncationMode(.middle)
                        Text([VoicesStudioFormat.duration(sample.durationSecs), VoicesStudioFormat.bytes(sample.sizeBytes)]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Button("Play") { Task { await model.playSample(sample) } }
                            .controlSize(.small)
                        Button(role: .destructive) {
                            Task { await model.deleteSample(sample) }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Delete this sample")
                        .accessibilityLabel("Delete \(sample.fileName)")
                    }
                    if let url = model.sampleFiles[sample.id] {
                        ElevenLabsAudioPlayerView(url: url).id(url)
                    }
                }
            }
        }
    }
}

// MARK: - Instant clone

struct VoicesCloneCard: View {
    @Bindable var model: VoicesSectionModel

    var body: some View {
        Card(title: "Clone a voice from recordings", systemImage: "person.wave.2") {
            Text("A minute or two of clean speech makes an instant clone. Only clone a voice you have the right to use.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Name", text: $model.clone.name).textFieldStyle(.roundedBorder)
            TextField("Description (optional)", text: $model.clone.description, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
            VStack(alignment: .leading, spacing: 2) {
                Text("Labels, one “key: value” per line").font(.caption).foregroundStyle(.secondary)
                ElevenLabsTextArea(text: $model.clone.labels, prompt: "accent: American", minHeight: 44)
            }
            VoicesStudioFilePicker(title: "Recordings", files: $model.clone.files, multiple: true,
                                   help: VoicesStudioSchema.description("add_voice", "files"))
            Toggle("Remove background noise", isOn: $model.clone.removeBackgroundNoise)
                .help(VoicesStudioSchema.description("add_voice", "remove_background_noise"))
            HStack {
                if let runner = model.actions.runner("add_voice") {
                    VoicesStudioRunButton(actions: model.actions, runner: runner, title: "Clone voice", disabled: !model.canClone) {
                        Task { await model.runClone() }
                    }
                }
            }
        }
    }
}

// MARK: - Similar voices

struct VoicesSimilarCard: View {
    @Bindable var model: VoicesSectionModel

    var body: some View {
        Card(title: "Voices in the library that sound like a recording", systemImage: "waveform.and.magnifyingglass") {
            VoicesStudioFilePicker(title: "Recording", files: $model.similarFile,
                                   help: VoicesStudioSchema.description("get_similar_library_voices", "audio_file"))
            HStack(spacing: 12) {
                TextField("Similarity threshold (0–2, optional)", text: $model.similarityThreshold)
                    .textFieldStyle(.roundedBorder)
                    .help(VoicesStudioSchema.description("get_similar_library_voices", "similarity_threshold"))
                TextField("How many, 1–100 (optional)", text: $model.similarTopK)
                    .textFieldStyle(.roundedBorder)
                    .help(VoicesStudioSchema.description("get_similar_library_voices", "top_k"))
            }
            HStack {
                Button("Find similar voices") { Task { await model.findSimilar() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.similarFile.isEmpty || model.actions.isRunning("get_similar_library_voices"))
                if model.actions.isRunning("get_similar_library_voices") { ProgressView().controlSize(.small) }
            }
            if model.searchedSimilar, model.similarResults.isEmpty {
                Text("Nothing close enough in the library.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(model.similarResults) { match in
                VoicesLibraryMatchRow(model: model, match: match)
            }
        }
    }
}

struct VoicesLibraryMatchRow: View {
    @Bindable var model: VoicesSectionModel
    let match: VoicesLibraryMatch

    var body: some View {
        HStack(spacing: 10) {
            VoicesPreviewButton(
                entry: ElevenLabsVoice(id: match.voiceID, name: match.name, previewURL: match.previewURL),
                directory: model.directory
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(match.name).font(.callout.weight(.medium))
                if !match.summary.isEmpty { Text(match.summary).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            TextField("Name in my voices", text: Binding(
                get: { model.addingName[match.id] ?? match.name },
                set: { model.addingName[match.id] = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(width: 170)
            Button("Add") { Task { await model.addFromLibrary(match) } }
                .disabled(model.actions.isRunning("add_sharing_voice"))
        }
    }
}
