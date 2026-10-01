import SiliconElevenLabs
import SwiftUI

/// Studio: long-form projects — a book, an article, a script — in chapters, converted to audio,
/// with snapshots to play and download; and podcasts made from text or a page.
struct StudioSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        StudioScreen(model: VoicesStudioModels.model(StudioSectionModel.self, for: app) {
            StudioSectionModel(environment: $0)
        })
    }
}

struct StudioScreen: View {
    @Bindable var model: StudioSectionModel

    var body: some View {
        ElevenLabsSectionPage(.studio) {
            Button {
                Task { await model.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(model.isListing)
        } content: {
            Picker("Show", selection: $model.mode) {
                ForEach(StudioSectionModel.Mode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            switch model.mode {
            case .projects:
                StudioNewProjectCard(model: model)
                StudioProjectsCard(model: model)
                if let project = model.selected {
                    StudioProjectCard(model: model, project: project)
                    StudioChaptersCard(model: model, project: project)
                    if let chapter = model.chapter { StudioChapterEditor(model: model, chapter: chapter) }
                    StudioSnapshotsCard(model: model, project: project)
                }
            case .podcast:
                StudioPodcastCard(model: model)
            }
            VoicesStudioActivity(actions: model.actions, fallback: model.actions.runner("get_projects"))
        }
        .task { await model.refreshIfNeeded() }
    }
}

/// A model picker over the account's speech models, with ElevenLabs' default first.
struct StudioModelPicker: View {
    let title: String
    @Binding var selection: String
    let models: [VoicesStudioSpeechModel]
    var defaultLabel: String? = "Default"

    var body: some View {
        Picker(title, selection: $selection) {
            if let defaultLabel { Text(defaultLabel).tag("") }
            ForEach(models) { Text($0.name).tag($0.id) }
            if !selection.isEmpty, !models.contains(where: { $0.id == selection }) {
                Text(selection).tag(selection)
            }
        }
    }
}

// MARK: - New project

struct StudioNewProjectCard: View {
    @Bindable var model: StudioSectionModel
    @State private var advanced = false

    var body: some View {
        CollapsibleCard(title: "New project", systemImage: "plus.circle", isExpanded: $model.showsNewProject) {
            TextField("Name", text: $model.draft.name).textFieldStyle(.roundedBorder)
            Picker("Start", selection: $model.draft.source) {
                ForEach(StudioProjectDraft.Source.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            switch model.draft.source {
            case .blank: EmptyView()
            case .url:
                TextField("Page to read from", text: $model.draft.url).textFieldStyle(.roundedBorder)
                    .help(VoicesStudioSchema.description("add_project", "from_url"))
            case .document:
                VoicesStudioFilePicker(title: "Document (.epub, .pdf, .txt…)", files: $model.draft.document,
                                       help: VoicesStudioSchema.description("add_project", "from_document"))
            }
            HStack(spacing: 8) {
                TextField("Title", text: $model.draft.title)
                TextField("Author", text: $model.draft.author)
                TextField("Language (e.g. en)", text: $model.draft.language).frame(width: 140)
            }
            .textFieldStyle(.roundedBorder)
            ElevenLabsVoicePicker(selection: $model.draft.titleVoiceID, title: "Voice for titles", directory: model.directory)
            ElevenLabsVoicePicker(selection: $model.draft.paragraphVoiceID, title: "Voice for paragraphs",
                                  directory: model.directory)
            StudioModelPicker(title: "Model", selection: $model.draft.modelID, models: model.speechModels)
            VoicesStudioChoicePicker(title: "Quality", selection: $model.draft.qualityPreset,
                                     choices: model.choices("add_project", "quality_preset"))
                .help(VoicesStudioSchema.description("add_project", "quality_preset"))
            DisclosureGroup("More about the book", isExpanded: $advanced) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Description", text: $model.draft.description, axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(1...3)
                    HStack(spacing: 8) {
                        VoicesStudioChoicePicker(title: "Kind", selection: $model.draft.sourceType,
                                                 choices: model.choices("add_project", "source_type"))
                        VoicesStudioChoicePicker(title: "Audience", selection: $model.draft.targetAudience,
                                                 choices: model.choices("add_project", "target_audience"))
                        VoicesStudioChoicePicker(title: "Fiction", selection: $model.draft.fiction,
                                                 choices: model.choices("add_project", "fiction"))
                    }
                    HStack(spacing: 8) {
                        TextField("Genres, comma-separated", text: $model.draft.genres)
                        TextField("ISBN", text: $model.draft.isbn).frame(width: 160)
                        TextField("First published (YYYY-MM-DD)", text: $model.draft.publicationDate).frame(width: 200)
                    }
                    .textFieldStyle(.roundedBorder)
                    Toggle("Mature content", isOn: $model.draft.matureContent)
                    Toggle("Normalise volume for audiobook platforms", isOn: $model.draft.volumeNormalization)
                        .help(VoicesStudioSchema.description("add_project", "volume_normalization"))
                    Toggle("Assign voices automatically (alpha)", isOn: $model.draft.autoAssignVoices)
                    VoicesStudioChoicePicker(title: "Text normalisation", selection: $model.draft.textNormalization,
                                             choices: model.choices("add_project", "apply_text_normalization"))
                    TextField("Callback URL when converted (optional)", text: $model.draft.callbackURL)
                        .textFieldStyle(.roundedBorder)
                    if !model.dictionaries.isEmpty {
                        Text("Pronunciation dictionaries").font(.caption.weight(.medium))
                        ForEach(model.dictionaries) { dictionary in
                            Toggle(dictionary.name, isOn: Binding(
                                get: { model.draft.dictionaries.contains { $0.id == dictionary.id } },
                                set: { on in
                                    model.draft.dictionaries.removeAll { $0.id == dictionary.id }
                                    if on {
                                        model.draft.dictionaries.append(
                                            StudioDictionaryLocator(id: dictionary.id, versionID: dictionary.latestVersionID))
                                    }
                                }
                            ))
                        }
                    }
                }
                .padding(.top, 6)
            }
            .font(.callout)
            Toggle("Convert to audio as soon as it is created — uses credits", isOn: $model.draft.autoConvert)
                .help(VoicesStudioSchema.description("add_project", "auto_convert"))
            if !model.problems.isEmpty { ElevenLabsProblemList(problems: model.problems) }
            if let runner = model.actions.runner("add_project") {
                VoicesStudioRunButton(
                    actions: model.actions, runner: runner, title: "Create project",
                    costNote: model.draft.autoConvert ? "Converting it as soon as it is created uses credits." : nil,
                    spends: model.draft.autoConvert
                ) { Task { await model.createProject() } }
            }
        }
    }
}

// MARK: - Projects

struct StudioProjectsCard: View {
    let model: StudioSectionModel

    var body: some View {
        Card(title: "Projects", systemImage: "book") {
            VoicesStudioListState(loading: model.isListing, problem: model.listProblem, isEmpty: model.projects.isEmpty,
                                  emptyText: "No Studio projects yet.")
            ForEach(model.projects) { project in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(project.name).font(.callout.weight(.medium)).lineLimit(1)
                        Text([project.author, project.language, VoicesStudioFormat.date(unixSeconds: project.createdAt)]
                            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if project.canBeDownloaded { Image(systemName: "arrow.down.circle").foregroundStyle(.secondary) }
                    VoicesStudioStatusBadge(status: project.state)
                }
                .padding(.vertical, 4).padding(.horizontal, 6)
                .background(model.selected?.id == project.id ? Color.accentColor.opacity(0.12) : .clear,
                            in: .rect(cornerRadius: 6))
                .contentShape(Rectangle())
                .onTapGesture { Task { await model.select(project.id) } }
            }
        }
    }
}

struct StudioProjectCard: View {
    @Bindable var model: StudioSectionModel
    let project: StudioProject
    @State private var editing = false
    @State private var replacing = false

    var body: some View {
        Card(title: project.name, systemImage: "book.pages") {
            HStack {
                VoicesStudioStatusBadge(status: project.state)
                Text(project.id).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                Spacer()
                Button("Check status") { Task { await model.select(project.id) } }.controlSize(.small)
            }
            VoicesStudioFact("Title", project.title)
            VoicesStudioFact("Author", project.author)
            VoicesStudioFact("Model", project.defaultModelID)
            VoicesStudioFact("Quality", project.qualityPreset.map(VoicesStudioFormat.words))
            VoicesStudioFact("Last converted", VoicesStudioFormat.date(unixSeconds: project.lastConversion))
            if let credits = project.creditsToConvert, credits > 0 {
                VoicesStudioFact("To convert", "about \(credits.formatted()) credits, as ElevenLabs estimates for what is left")
            }
            if !model.mutedChapters.isEmpty {
                VoicesStudioFact("Muted chapters", "\(model.mutedChapters.count)")
            }
            HStack {
                if let runner = model.actions.runner("convert_project_endpoint") {
                    VoicesStudioRunButton(actions: model.actions, runner: runner, title: "Convert project") {
                        Task { await model.convert() }
                    }
                }
            }
            Divider()
            DisclosureGroup("Settings", isExpanded: $editing) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Name", text: $model.editDraft.name)
                    HStack(spacing: 8) {
                        TextField("Title", text: $model.editDraft.title)
                        TextField("Author", text: $model.editDraft.author)
                        TextField("ISBN", text: $model.editDraft.isbn).frame(width: 150)
                    }
                    ElevenLabsVoicePicker(selection: $model.editDraft.titleVoiceID, title: "Voice for titles",
                                          directory: model.directory)
                    ElevenLabsVoicePicker(selection: $model.editDraft.paragraphVoiceID, title: "Voice for paragraphs",
                                          directory: model.directory)
                    Toggle("Normalise volume for audiobook platforms", isOn: $model.editDraft.volumeNormalization)
                    HStack {
                        if let waiting = model.waitingForDetails {
                            Text(waiting).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Save settings") { Task { await model.saveEdit() } }
                            .disabled(model.editDraft.name.isEmpty || model.editDraft.titleVoiceID.isEmpty
                                      || model.editDraft.paragraphVoiceID.isEmpty || !model.detailsAreIn)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .padding(.top, 6)
            }
            DisclosureGroup("Replace the content", isExpanded: $replacing) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("From a web page", text: $model.contentURL).textFieldStyle(.roundedBorder)
                    VoicesStudioFilePicker(title: "…or a document", files: $model.contentDocument)
                    Toggle("Convert to audio afterwards — uses credits", isOn: $model.contentAutoConvert)
                    Text("Replacing the content replaces every chapter of “\(project.name)”, and your edits in them.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let runner = model.actions.runner("edit_project_content") {
                        VoicesStudioRunButton(
                            actions: model.actions, runner: runner, title: "Replace content…",
                            disabled: model.contentURL.isEmpty && model.contentDocument.isEmpty,
                            costNote: model.contentAutoConvert ? "Converting the new content uses credits." : nil,
                            spends: model.contentAutoConvert
                        ) { Task { await model.updateContent() } }
                    }
                }
                .padding(.top, 6)
            }
            if !model.dictionaries.isEmpty {
                DisclosureGroup("Pronunciation dictionaries (\(project.dictionaries.count))") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.dictionaries) { dictionary in
                            Toggle(dictionary.name, isOn: Binding(
                                get: { project.dictionaries.contains { $0.id == dictionary.id } },
                                set: { on in Task { await model.setDictionary(dictionary, attached: on) } }
                            ))
                            .disabled(!model.detailsAreIn)
                        }
                        Toggle("Mark affected text for conversion again", isOn: $model.invalidateAffectedText)
                            .help(VoicesStudioSchema.description("update_pronunciation_dictionaries", "invalidate_affected_text"))
                    }
                    .padding(.top, 6)
                }
            }
            HStack {
                Spacer()
                Button(role: .destructive) { Task { await model.delete() } } label: {
                    Label("Delete project…", systemImage: "trash")
                }
            }
        }
        .font(.callout)
    }
}

struct StudioChaptersCard: View {
    @Bindable var model: StudioSectionModel
    let project: StudioProject

    var body: some View {
        Card(title: "\(project.chapters.count) chapters", systemImage: "list.number") {
            Text("Converting a chapter uses credits; each chapter says about how many, when ElevenLabs does.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(project.chapters) { chapter in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(chapter.name).font(.callout.weight(.medium)).lineLimit(1)
                        Text(chapterLine(chapter)).font(.caption).foregroundStyle(.secondary)
                        if let error = chapter.lastError, !error.isEmpty {
                            Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                        }
                    }
                    Spacer()
                    if chapter.state == "converting", let progress = chapter.progress {
                        ProgressView(value: progress).frame(width: 80)
                    }
                    Button("Open") { Task { await model.openChapter(chapter.id) } }.controlSize(.small)
                    Button("Convert") { Task { await model.convertChapter(chapter) } }
                        .controlSize(.small)
                        .help("Uses credits from your ElevenLabs balance")
                        .disabled(model.actions.runner("convert_chapter_endpoint").map { model.actions.isBlocked($0) } ?? true)
                    Button(role: .destructive) { Task { await model.deleteChapter(chapter) } } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Delete \(chapter.name)")
                }
            }
            HStack(spacing: 8) {
                TextField("New chapter name", text: $model.newChapterName)
                TextField("From a web page (optional)", text: $model.newChapterURL)
                Button("Add chapter") { Task { await model.addChapter() } }
                    .disabled(model.newChapterName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .textFieldStyle(.roundedBorder)
        }
    }

    private func chapterLine(_ chapter: StudioChapter) -> String {
        var parts: [String] = [chapter.state == "default" ? "Ready" : VoicesStudioFormat.words(chapter.state)]
        if let converted = chapter.charactersConverted, let left = chapter.charactersUnconverted {
            parts.append("\((converted).formatted()) of \((converted + left).formatted()) characters converted")
        }
        if let credits = chapter.creditsToConvert, credits > 0 { parts.append("about \(credits.formatted()) credits to convert") }
        return parts.joined(separator: " · ")
    }
}

struct StudioChapterEditor: View {
    @Bindable var model: StudioSectionModel
    let chapter: StudioChapter

    var body: some View {
        Card(title: "Chapter: \(chapter.name)", systemImage: "text.book.closed") {
            TextField("Chapter name", text: $model.chapterName).textFieldStyle(.roundedBorder)
            if !model.chapterIsEditable {
                Text("This chapter holds content only the Studio editor can change; its text is shown read-only.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(chapter.blocks) { block in
                if model.chapterIsEditable {
                    ElevenLabsTextArea(text: Binding(
                        get: { model.blockEdits[block.id] ?? block.text },
                        set: { model.blockEdits[block.id] = $0 == block.text ? nil : $0 }
                    ), minHeight: 40)
                } else {
                    Text(block.text).font(.callout).textSelection(.enabled)
                }
            }
            HStack {
                if !model.blockEdits.isEmpty {
                    Text("\(model.blockEdits.count) paragraphs changed").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Save chapter") { Task { await model.saveChapter() } }
                    .disabled(!model.chapterHasChanges)
                    .help(model.chapterHasChanges ? "Save the chapter's new name and edited paragraphs" : "Nothing to save")
            }
            if !model.chapterSnapshots.isEmpty {
                Divider()
                Text("Chapter snapshots").font(.headline)
                ForEach(model.chapterSnapshots) { snapshot in
                    StudioSnapshotRow(model: model, snapshot: snapshot, zip: false) {
                        Task { await model.playChapterSnapshot(snapshot) }
                    }
                }
            }
        }
    }
}

struct StudioSnapshotsCard: View {
    let model: StudioSectionModel
    let project: StudioProject

    var body: some View {
        Card(title: "Snapshots", systemImage: "square.stack.3d.up") {
            if model.projectSnapshots.isEmpty {
                Text("A snapshot is made each time the project is converted.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(model.projectSnapshots) { snapshot in
                StudioSnapshotRow(model: model, snapshot: snapshot, zip: true) {
                    Task { await model.playSnapshot(snapshot) }
                }
            }
        }
    }
}

struct StudioSnapshotRow: View {
    let model: StudioSectionModel
    let snapshot: StudioSnapshot
    let zip: Bool
    let play: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(snapshot.name).font(.callout)
                Text(VoicesStudioFormat.date(unixSeconds: snapshot.createdAt) ?? "").font(.caption).foregroundStyle(.secondary)
                if let duration = model.snapshotDurations[snapshot.id] {
                    Text(VoicesStudioFormat.duration(duration) ?? "").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Play", action: play).controlSize(.small)
                Button("Details") { Task { await model.loadSnapshotDetails(snapshot) } }.controlSize(.small)
                if zip {
                    Button("Download ZIP") { Task { await model.downloadArchive(snapshot) } }.controlSize(.small)
                }
            }
            if let file = model.snapshotAudio[snapshot.id] {
                ElevenLabsFileResult(url: file.url, contentType: file.contentType, bytes: file.bytes)
            }
            if let archive = model.snapshotAudio[snapshot.id + "/zip"] {
                ElevenLabsFileResult(url: archive.url, contentType: archive.contentType, bytes: archive.bytes)
            }
        }
    }
}

// MARK: - Podcast

struct StudioPodcastCard: View {
    @Bindable var model: StudioSectionModel
    @State private var advanced = false

    var body: some View {
        Card(title: "A podcast from text or a page", systemImage: "mic") {
            Picker("Format", selection: $model.podcast.conversation) {
                Text("Conversation: host and guest").tag(true)
                Text("Bulletin: one host").tag(false)
            }
            .pickerStyle(.segmented)
            ElevenLabsVoicePicker(selection: $model.podcast.hostVoiceID, title: "Host", directory: model.directory)
            if model.podcast.conversation {
                ElevenLabsVoicePicker(selection: $model.podcast.guestVoiceID, title: "Guest", directory: model.directory)
            }
            Picker("Source", selection: $model.podcast.fromURL) {
                Text("Text").tag(false)
                Text("A web page").tag(true)
            }
            .pickerStyle(.segmented)
            if model.podcast.fromURL {
                TextField("Page", text: $model.podcast.url).textFieldStyle(.roundedBorder)
            } else {
                VoicesStudioCountedEditor(title: "Text", text: $model.podcast.text, height: 120)
            }
            StudioModelPicker(title: "Model", selection: $model.podcast.modelID, models: model.speechModels,
                              defaultLabel: "Choose a model")
            HStack(spacing: 8) {
                VoicesStudioChoicePicker(title: "Length", selection: $model.podcast.durationScale,
                                         choices: model.choices("create_podcast", "duration_scale"))
                    .help(VoicesStudioSchema.description("create_podcast", "duration_scale"))
                VoicesStudioChoicePicker(title: "Quality", selection: $model.podcast.qualityPreset,
                                         choices: model.choices("create_podcast", "quality_preset"))
            }
            DisclosureGroup("Intro, outro and direction", isExpanded: $advanced) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Language (e.g. en)", text: $model.podcast.language)
                    TextField("Intro, always spoken first", text: $model.podcast.intro, axis: .vertical).lineLimit(1...3)
                    TextField("Outro, always spoken last", text: $model.podcast.outro, axis: .vertical).lineLimit(1...3)
                    TextField("Style and tone instructions", text: $model.podcast.instructions, axis: .vertical).lineLimit(1...4)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Highlights, one per line (10–70 characters each)").font(.caption).foregroundStyle(.secondary)
                        ElevenLabsTextArea(text: $model.podcast.highlights, minHeight: 44)
                    }
                    VoicesStudioChoicePicker(title: "Text normalisation", selection: $model.podcast.textNormalization,
                                             choices: model.choices("create_podcast", "apply_text_normalization"))
                    TextField("Callback URL when ready (optional)", text: $model.podcast.callbackURL)
                }
                .textFieldStyle(.roundedBorder)
                .padding(.top, 6)
            }
            .font(.callout)
            if !model.problems.isEmpty { ElevenLabsProblemList(problems: model.problems) }
            if let runner = model.actions.runner("create_podcast") {
                Text("The audio a podcast generates is charged; writing its script is not charged for now.")
                    .font(.caption).foregroundStyle(.secondary)
                VoicesStudioRunButton(actions: model.actions, runner: runner, title: "Make podcast") {
                    Task { await model.createPodcast() }
                }
            }
        }
    }
}
