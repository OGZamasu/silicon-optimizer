import AppKit
import SiliconElevenLabs
import SwiftUI
import UniformTypeIdentifiers

/// Dubbing: a video or audio file (or a link to one) spoken in another language, its
/// subtitles and transcripts, and dubbing projects with editable transcripts per language.
struct DubbingSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        DubbingScreen(model: VoicesStudioModels.model(DubbingSectionModel.self, for: app) {
            DubbingSectionModel(environment: $0)
        })
    }
}

struct DubbingScreen: View {
    @Bindable var model: DubbingSectionModel

    var body: some View {
        ElevenLabsSectionPage(.dubbing) {
            Button {
                Task { model.mode == .dubs ? await model.refreshDubs() : await model.refreshProjects() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        } content: {
            Picker("Show", selection: $model.mode) {
                ForEach(DubbingSectionModel.Mode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            switch model.mode {
            case .dubs:
                DubbingCreateCard(model: model)
                DubbingListCard(model: model)
                if let dub = model.selectedDub { DubbingDubCard(model: model, dub: dub) }
            case .projects:
                DubbingProjectCreateCard(model: model)
                DubbingProjectsCard(model: model)
                if let project = model.selectedProject { DubbingProjectCard(model: model, project: project) }
            }
            VoicesStudioActivity(
                actions: model.actions,
                fallback: model.actions.runner(model.mode == .dubs ? "list_dubs" : "dubbing_project_list")
            )
        }
        .task(id: model.mode) {
            if model.mode == .dubs, !model.loadedDubs { await model.refreshDubs() }
            if model.mode == .projects, !model.loadedProjects { await model.refreshProjects() }
        }
    }
}

// MARK: - Dubs

struct DubbingCreateCard: View {
    @Bindable var model: DubbingSectionModel
    @State private var expanded = true
    @State private var advanced = false

    var body: some View {
        CollapsibleCard(title: "New dub", systemImage: "plus.circle", isExpanded: $expanded) {
            VoicesStudioFilePicker(title: "Video or audio", files: $model.draft.files,
                                   help: VoicesStudioSchema.description("create_dubbing", "file"))
            TextField("…or a link to it", text: $model.draft.sourceURL).textFieldStyle(.roundedBorder)
                .help(VoicesStudioSchema.description("create_dubbing", "source_url"))
            HStack(spacing: 8) {
                TextField("From (language code, blank to detect)", text: $model.draft.sourceLanguage)
                    .help(VoicesStudioSchema.description("create_dubbing", "source_lang"))
                TextField("Into (language code, e.g. es)", text: $model.draft.targetLanguage)
                    .help(VoicesStudioSchema.description("create_dubbing", "target_lang"))
            }
            .textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                TextField("Name (optional)", text: $model.draft.name)
                TextField("Speakers (0 detects)", text: $model.draft.speakers).frame(width: 150)
                    .help(VoicesStudioSchema.description("create_dubbing", "num_speakers"))
            }
            .textFieldStyle(.roundedBorder)
            DisclosureGroup("More options", isExpanded: $advanced) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        TextField("Start time", text: $model.draft.startTime)
                        TextField("End time", text: $model.draft.endTime)
                        TextField("Accent (experimental)", text: $model.draft.targetAccent)
                    }
                    .textFieldStyle(.roundedBorder)
                    Toggle("Watermark the video", isOn: $model.draft.watermark)
                    Toggle("Highest resolution", isOn: $model.draft.highestResolution)
                    Toggle("Drop the background audio", isOn: $model.draft.dropBackgroundAudio)
                        .help(VoicesStudioSchema.description("create_dubbing", "drop_background_audio"))
                    Toggle("Censor profanity in transcripts", isOn: $model.draft.profanityFilter)
                    Toggle("Prepare for editing in Dubbing Studio", isOn: $model.draft.dubbingStudio)
                    Toggle("Use similar library voices instead of clones", isOn: $model.draft.disableVoiceCloning)
                        .help(VoicesStudioSchema.description("create_dubbing", "disable_voice_cloning"))
                    VoicesStudioChoicePicker(title: "Mode", selection: $model.draft.mode, choices: model.dubModes)
                        .help(VoicesStudioSchema.description("create_dubbing", "mode"))
                    if model.draft.mode == "manual" {
                        VoicesStudioFilePicker(title: "Transcript CSV", files: $model.draft.csvFile,
                                               help: VoicesStudioSchema.description("create_dubbing", "csv_file"))
                        TextField("CSV frames per second", text: $model.draft.csvFPS).textFieldStyle(.roundedBorder)
                        VoicesStudioFilePicker(title: "Foreground audio", files: $model.draft.foregroundAudio)
                        VoicesStudioFilePicker(title: "Background audio", files: $model.draft.backgroundAudio)
                    }
                }
                .padding(.top, 6)
            }
            .font(.callout)
            if !model.draftProblems.isEmpty { ElevenLabsProblemList(problems: model.draftProblems) }
            if let runner = model.actions.runner("create_dubbing") {
                VoicesStudioRunButton(actions: model.actions, runner: runner, title: "Start dubbing",
                                      costNote: DubbingSectionModel.CostNote.dub) {
                    Task { await model.createDub() }
                }
            }
        }
    }
}

struct DubbingListCard: View {
    @Bindable var model: DubbingSectionModel

    var body: some View {
        Card(title: "Dubs", systemImage: "globe") {
            HStack(spacing: 8) {
                VoicesStudioChoicePicker(title: "Status", selection: $model.statusFilter, choices: model.dubStatuses,
                                         defaultLabel: "Any status")
                VoicesStudioChoicePicker(title: "Made by", selection: $model.creatorFilter, choices: model.creatorFilters,
                                         defaultLabel: "Anyone")
            }
            .labelsHidden()
            .fixedSize()
            .onChange(of: model.statusFilter) { Task { await model.refreshDubs() } }
            .onChange(of: model.creatorFilter) { Task { await model.refreshDubs() } }
            VoicesStudioListState(loading: model.listingDubs, problem: model.dubsProblem, isEmpty: model.dubs.isEmpty,
                                  emptyText: "No dubs yet.")
            ForEach(model.dubs) { dub in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(dub.name).font(.callout.weight(.medium)).lineLimit(1)
                        Text("\(dub.sourceLanguage ?? "?") → \(dub.targetLanguages.joined(separator: ", "))"
                             + (VoicesStudioFormat.duration(dub.duration).map { " · \($0)" } ?? ""))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(VoicesStudioFormat.date(iso: dub.createdAt) ?? "").font(.caption).foregroundStyle(.tertiary)
                    VoicesStudioStatusBadge(status: dub.status)
                }
                .padding(.vertical, 4).padding(.horizontal, 6)
                .background(model.selectedDub?.id == dub.id ? Color.accentColor.opacity(0.12) : .clear,
                            in: .rect(cornerRadius: 6))
                .contentShape(Rectangle())
                .onTapGesture { Task { await model.selectDub(dub.id) } }
            }
            VoicesStudioMoreButton(hasMore: model.dubsHaveMore, loading: model.listingDubs) {
                Task { await model.moreDubs() }
            }
        }
    }
}

struct DubbingDubCard: View {
    @Bindable var model: DubbingSectionModel
    let dub: DubbingDub

    var body: some View {
        Card(title: dub.name, systemImage: "film") {
            HStack {
                VoicesStudioStatusBadge(status: dub.status)
                Text(dub.id).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                Spacer()
                Button("Check status") { Task { await model.selectDub(dub.id) } }.controlSize(.small)
            }
            if let error = dub.error, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
            }
            VoicesStudioFact("Languages", "\(dub.sourceLanguage ?? "?") → \(dub.targetLanguages.joined(separator: ", "))")
            VoicesStudioFact("Length", VoicesStudioFormat.duration(dub.duration))
            VoicesStudioFact("Media", dub.mediaType)
            Divider()
            HStack(spacing: 8) {
                Picker("Language", selection: $model.downloadLanguage) {
                    ForEach(dub.targetLanguages, id: \.self) { Text($0).tag($0) }
                }
                .fixedSize()
                Button("Download the dub") { Task { await model.download() } }
                    .disabled(!dub.isFinished || model.downloadLanguage.isEmpty || model.actions.isRunning("get_dubbed_file"))
                    .help(dub.isFinished ? "Fetch the dubbed audio or video" : "Available once the dub is finished")
            }
            if let file = model.downloads[model.downloadLanguage] {
                ElevenLabsFileResult(url: file.url, contentType: file.contentType, bytes: file.bytes)
            }
            Divider()
            HStack(spacing: 8) {
                Picker("Transcript of", selection: $model.transcriptLanguage) {
                    Text("The original").tag("source")
                    ForEach(dub.targetLanguages, id: \.self) { Text($0).tag($0) }
                }
                .fixedSize()
                Picker("Format", selection: $model.transcriptFormat) {
                    ForEach(model.transcriptFormats, id: \.self) { Text($0.uppercased()).tag($0) }
                }
                .fixedSize()
                Button("Get transcript") { Task { await model.loadTranscript() } }
                    .disabled(model.actions.isRunning("get_dubbing_transcripts"))
            }
            if let transcript = model.transcript {
                ElevenLabsTextBlock(text: transcript, monospaced: true)
                HStack {
                    Spacer()
                    Button("Save as file…") {
                        DubbingSaving.save(transcript, suggestedName: "\(dub.name).\(model.transcriptFormat == "webvtt" ? "vtt" : model.transcriptFormat)")
                    }
                    .controlSize(.small)
                }
            }
            if !model.transcriptUtterances.isEmpty {
                ElevenLabsJSONBlock(value: .array(model.transcriptUtterances), label: "\(model.transcriptUtterances.count) utterances")
            }
            HStack {
                Spacer()
                Button(role: .destructive) { Task { await model.deleteDub() } } label: {
                    Label("Delete dub…", systemImage: "trash")
                }
            }
        }
    }
}

/// Saves text the owner asked to keep (subtitles, a transcript) where they choose.
enum DubbingSaving {
    @MainActor
    static func save(_ text: String, suggestedName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = ElevenLabsFileNames.sanitized(suggestedName)
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? Data(text.utf8).write(to: url, options: .atomic)
    }
}

// MARK: - Projects

struct DubbingProjectCreateCard: View {
    @Bindable var model: DubbingSectionModel
    @State private var expanded = false

    var body: some View {
        CollapsibleCard(title: "New dubbing project", systemImage: "plus.circle", isExpanded: $expanded) {
            VoicesStudioFilePicker(title: "Video or audio", files: $model.projectDraft.files,
                                   help: VoicesStudioSchema.description("dubbing_project_create", "file"))
            TextField("…or a public link to it", text: $model.projectDraft.sourceURL).textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                TextField("Source language (BCP-47, blank to detect)", text: $model.projectDraft.sourceLanguage)
                TextField("Also dub into (optional)", text: $model.projectDraft.targetLanguage)
                    .help(VoicesStudioSchema.description("dubbing_project_create", "target_language"))
            }
            .textFieldStyle(.roundedBorder)
            if !model.projectModels.isEmpty {
                VoicesStudioChoicePicker(title: "Dubbing model", selection: $model.projectDraft.modelID,
                                         choices: model.projectModels)
                    .help(VoicesStudioSchema.description("dubbing_project_create", "model_id"))
            }
            TextField("Key terms, comma-separated (names, brands)", text: $model.projectDraft.keyterms)
                .textFieldStyle(.roundedBorder)
                .help(VoicesStudioSchema.description("dubbing_project_create", "keyterms"))
            HStack(spacing: 8) {
                TextField("Your reference (optional)", text: $model.projectDraft.reference)
                TextField("Webhook ids to notify, comma-separated", text: $model.projectDraft.webhookIDs)
                    .help(VoicesStudioSchema.description("dubbing_project_create", "webhook_ids"))
            }
            .textFieldStyle(.roundedBorder)
            VoicesStudioFilePicker(title: "Own transcript (Enterprise)", files: $model.projectDraft.transcript,
                                   help: VoicesStudioSchema.description("dubbing_project_create", "transcript"))
            if !model.projectProblems.isEmpty { ElevenLabsProblemList(problems: model.projectProblems) }
            if let runner = model.actions.runner("dubbing_project_create") {
                VoicesStudioRunButton(actions: model.actions, runner: runner, title: "Create project",
                                      costNote: DubbingSectionModel.CostNote.project) {
                    Task { await model.createProject() }
                }
            }
        }
    }
}

struct DubbingProjectsCard: View {
    @Bindable var model: DubbingSectionModel

    var body: some View {
        Card(title: "Projects", systemImage: "folder") {
            Picker("Status", selection: $model.projectStatusFilter) {
                Text("Any status").tag("")
                ForEach(DubbingSectionModel.projectStatuses, id: \.self) { Text(VoicesStudioFormat.words($0)).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .onChange(of: model.projectStatusFilter) { Task { await model.refreshProjects() } }
            VoicesStudioListState(loading: model.listingProjects, problem: model.projectsProblem,
                                  isEmpty: model.projects.isEmpty, emptyText: "No dubbing projects yet.")
            ForEach(model.projects) { project in
                HStack(spacing: 8) {
                    Image(systemName: project.hasVideo == true ? "film" : "waveform").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(project.title).font(.callout.weight(.medium)).lineLimit(1)
                        Text([project.sourceLanguage, project.modelID, VoicesStudioFormat.duration(project.duration),
                              project.languageIDs.count == 1 ? "1 language" : "\(project.languageIDs.count) languages"].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VoicesStudioStatusBadge(status: project.status)
                }
                .padding(.vertical, 4).padding(.horizontal, 6)
                .background(model.selectedProject?.id == project.id ? Color.accentColor.opacity(0.12) : .clear,
                            in: .rect(cornerRadius: 6))
                .contentShape(Rectangle())
                .onTapGesture { Task { await model.selectProject(project.id) } }
            }
            VoicesStudioMoreButton(hasMore: model.projectsHaveMore, loading: model.listingProjects) {
                Task { await model.moreProjects() }
            }
        }
    }
}

struct DubbingProjectCard: View {
    @Bindable var model: DubbingSectionModel
    let project: DubbingProject

    var body: some View {
        Card(title: project.title, systemImage: "globe") {
            HStack {
                VoicesStudioStatusBadge(status: project.status)
                Text(project.id).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                Spacer()
                Button("Check status") { Task { await model.selectProject(project.id) } }.controlSize(.small)
            }
            if let error = project.error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
            ForEach(project.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.circle").font(.caption) }
            Divider()
            Text("Languages").font(.headline)
            ForEach(model.languages) { language in
                DubbingLanguageRow(model: model, language: language)
            }
            Text("Add a language").font(.subheadline.weight(.medium))
            LabeledContent("Dub into") {
                TextField("BCP-47, e.g. fr or es-MX", text: $model.newLanguage)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
            }
            HStack(spacing: 8) {
                Toggle("Cloning strength", isOn: $model.setsCloningStrength)
                if model.setsCloningStrength {
                    Slider(value: $model.cloningStrength, in: DubbingSectionModel.cloningRange, step: 1).frame(maxWidth: 160)
                    Text("\(Int(model.cloningStrength))").monospacedDigit()
                }
            }
            if let runner = model.actions.runner("dubbing_language_create") {
                VoicesStudioRunButton(actions: model.actions, runner: runner, title: "Add language",
                                      disabled: model.newLanguage.trimmingCharacters(in: .whitespaces).isEmpty,
                                      costNote: DubbingSectionModel.CostNote.language) {
                    Task { await model.addLanguage() }
                }
            }
            Divider()
            DubbingTranscriptEditor(model: model)
            HStack {
                Spacer()
                Button(role: .destructive) { Task { await model.deleteProject() } } label: {
                    Label("Delete project…", systemImage: "trash")
                }
            }
        }
    }
}

struct DubbingLanguageRow: View {
    let model: DubbingSectionModel
    let language: DubbingLanguage

    var body: some View {
        HStack(spacing: 8) {
            Text(language.targetLanguage).font(.callout.weight(.medium).monospaced())
            VoicesStudioStatusBadge(status: language.status)
            if let strength = language.cloningStrength { Text("cloning \(strength)").font(.caption).foregroundStyle(.secondary) }
            if let error = language.error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(1) }
            Spacer()
            if let link = language.losslessAudio {
                Button("Download FLAC") { NSWorkspace.shared.open(link) }
                    .controlSize(.small)
                    .help("Opens the signed download link (valid for an hour) in your browser")
            }
            Button("Translation") { Task { await model.loadTargetTranscript(language.id) } }.controlSize(.small)
            Button("Refresh") { Task { await model.refreshLanguage(language) } }.controlSize(.small)
            Button(role: .destructive) { Task { await model.deleteLanguage(language) } } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Delete the \(language.targetLanguage) dub")
        }
    }
}

struct DubbingTranscriptEditor: View {
    @Bindable var model: DubbingSectionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Transcript").font(.headline)
                Spacer()
                Button("Load the original") { Task { await model.loadSourceTranscript() } }.controlSize(.small)
                if !model.sourceEdits.isEmpty {
                    Button("Save \(model.sourceEdits.count) edits") { Task { await model.saveSourceEdits() } }
                        .controlSize(.small).buttonStyle(.borderedProminent)
                }
            }
            ForEach(model.sourceSegments) { segment in
                HStack(alignment: .top, spacing: 8) {
                    Text("\(VoicesStudioFormat.duration(segment.start) ?? "") \(segment.speakerID)")
                        .font(.caption.monospaced()).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                    TextField("Text", text: Binding(
                        get: { model.sourceEdits[segment.id] ?? segment.text },
                        set: { model.sourceEdits[segment.id] = $0 == segment.text ? nil : $0 }
                    ), axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    Button(role: .destructive) { Task { await model.deleteSegment(segment) } } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Delete segment")
                }
            }
            if !model.sourceSegments.isEmpty {
                HStack(spacing: 6) {
                    TextField("Speaker", text: $model.newSegment.speaker).frame(width: 90)
                    TextField("Start s", text: $model.newSegment.start).frame(width: 60)
                    TextField("End s", text: $model.newSegment.end).frame(width: 60)
                    TextField("New segment text", text: $model.newSegment.text)
                    Button("Add") { Task { await model.addSegment() } }
                        .disabled(model.addSegmentArguments() == nil)
                }
                .textFieldStyle(.roundedBorder)
                .font(.callout)
            }
            if let languageID = model.selectedLanguageID,
               let language = model.languages.first(where: { $0.id == languageID }) {
                Divider()
                HStack {
                    Text("Translation into \(language.targetLanguage)").font(.headline)
                    Spacer()
                    if !model.targetEdits.isEmpty {
                        Button("Save \(model.targetEdits.count) edits") { Task { await model.saveTargetEdits() } }
                            .controlSize(.small).buttonStyle(.borderedProminent)
                    }
                }
                if let runner = model.actions.runner("dubbing_target_transcript_regenerate") {
                    VoicesStudioRunButton(
                        actions: model.actions, runner: runner, title: "Regenerate",
                        disabled: model.regenerateHold != nil, disabledReason: model.regenerateHold,
                        costNote: DubbingSectionModel.CostNote.regenerate
                    ) { Task { await model.regenerate() } }
                    .controlSize(.small)
                }
                if let charge = model.lastRegeneration {
                    Text("The last regeneration charged \(VoicesStudioFormat.duration(charge.charged) ?? "0:00"); "
                         + "\(VoicesStudioFormat.duration(charge.freeLeft) ?? "0:00") of free regeneration is left.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(model.targetSegments) { segment in
                    HStack(alignment: .top, spacing: 8) {
                        Text(segment.text).font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        TextField("Translation", text: Binding(
                            get: { model.targetEdits[segment.id] ?? segment.translation ?? "" },
                            set: { model.targetEdits[segment.id] = $0 == (segment.translation ?? "") ? nil : $0 }
                        ), axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }
}
