import AppKit
import SiliconElevenLabs
import SwiftUI

/// Audio Native: an embeddable player that reads an article aloud on the owner's site.
struct AudioNativeSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        AudioNativeScreen(model: VoicesStudioModels.model(AudioNativeSectionModel.self, for: app) {
            AudioNativeSectionModel(environment: $0)
        })
    }
}

struct AudioNativeScreen: View {
    @Bindable var model: AudioNativeSectionModel

    var body: some View {
        ElevenLabsSectionPage(.audioNative) {
            AudioNativeCreateCard(model: model)
            if let snippet = model.snippet {
                AudioNativeSnippetCard(snippet: snippet, converting: model.converting)
            }
            AudioNativeProjectCard(model: model)
            VoicesStudioActivity(actions: model.actions,
                                 fallback: model.actions.runner("get_audio_native_project_settings_endpoint"))
        }
        .task { await model.loadPickers() }
    }
}

struct AudioNativeCreateCard: View {
    @Bindable var model: AudioNativeSectionModel
    @State private var look = false

    var body: some View {
        Card(title: "A player for an article", systemImage: "play.rectangle") {
            TextField("Project name", text: $model.draft.name).textFieldStyle(.roundedBorder)
            VoicesStudioFilePicker(title: "Article (.txt or .html)", files: $model.draft.file,
                                   help: VoicesStudioSchema.description("create_audio_native_project", "file"))
            HStack(spacing: 8) {
                TextField("Title shown in the player", text: $model.draft.title)
                TextField("Author shown in the player", text: $model.draft.author)
            }
            .textFieldStyle(.roundedBorder)
            ElevenLabsVoicePicker(selection: $model.draft.voiceID, title: "Voice", directory: model.directory)
            StudioModelPicker(title: "Model", selection: $model.draft.modelID, models: model.speechModels,
                              defaultLabel: "Player default")
            DisclosureGroup("Look and reading", isExpanded: $look) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        TextField("Text colour (e.g. #1A1A1A)", text: $model.draft.textColor)
                        TextField("Background colour (e.g. #FFFFFF)", text: $model.draft.backgroundColor)
                    }
                    .textFieldStyle(.roundedBorder)
                    VoicesStudioChoicePicker(title: "Text normalisation", selection: $model.draft.textNormalization,
                                             choices: model.normalizations)
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
                .padding(.top, 6)
            }
            .font(.callout)
            Toggle("Convert to audio now", isOn: $model.draft.autoConvert)
                .help(VoicesStudioSchema.description("create_audio_native_project", "auto_convert"))
            if !model.problems.isEmpty { ElevenLabsProblemList(problems: model.problems) }
            if let runner = model.actions.runner("create_audio_native_project") {
                VoicesStudioRunButton(actions: model.actions, runner: runner, title: "Create player") {
                    Task { await model.create() }
                }
            }
        }
    }
}

struct AudioNativeSnippetCard: View {
    let snippet: String
    let converting: Bool
    @State private var copied = false

    var body: some View {
        Card(title: "Embed code", systemImage: "chevron.left.forwardslash.chevron.right") {
            if converting {
                Label("Converting the article; the player fills in once it is done.", systemImage: "hourglass")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ElevenLabsTextBlock(text: snippet, monospaced: true)
            HStack {
                Spacer()
                Button(copied ? "Copied" : "Copy embed code") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(snippet, forType: .string)
                    copied = true
                }
            }
        }
    }
}

struct AudioNativeProjectCard: View {
    @Bindable var model: AudioNativeSectionModel

    var body: some View {
        Card(title: "A player's settings and content", systemImage: "slider.horizontal.3") {
            HStack(spacing: 8) {
                Picker("Project", selection: $model.projectID) {
                    Text("Choose a project").tag("")
                    ForEach(model.projects) { Text($0.name).tag($0.id) }
                    if !model.projectID.isEmpty, !model.projects.contains(where: { $0.id == model.projectID }) {
                        Text(model.projectID).tag(model.projectID)
                    }
                }
                Button("Show settings") { Task { await model.loadSettings() } }
                    .disabled(model.projectID.isEmpty)
            }
            .onChange(of: model.projectID) { Task { await model.loadSettings() } }
            if let settings = model.settings {
                HStack {
                    VoicesStudioStatusBadge(status: settings.enabled ? "enabled" : "disabled")
                    if let status = settings.status { VoicesStudioStatusBadge(status: status) }
                }
                VoicesStudioFact("Title", settings.title)
                VoicesStudioFact("Author", settings.author)
                VoicesStudioFact("Colours", [settings.textColor, settings.backgroundColor].compactMap { $0 }.joined(separator: " on "))
                VoicesStudioFact("Snapshot", settings.snapshotID)
                if let audio = settings.audioURL {
                    Button("Open the published audio") { NSWorkspace.shared.open(audio) }.controlSize(.small)
                }
            }
            Divider()
            Text("Replace the article").font(.headline)
            VoicesStudioFilePicker(title: "Article (.txt or .html)", files: $model.contentFile,
                                   help: VoicesStudioSchema.description("audio_native_project_update_content_endpoint", "file"))
            HStack {
                Toggle("Convert", isOn: $model.contentAutoConvert)
                Toggle("Publish when converted", isOn: $model.contentAutoPublish)
                    .help(VoicesStudioSchema.description("audio_native_project_update_content_endpoint", "auto_publish"))
                Spacer()
                if let runner = model.actions.runner("audio_native_project_update_content_endpoint") {
                    VoicesStudioRunButton(actions: model.actions, runner: runner, title: "Update",
                                        disabled: model.projectID.isEmpty || model.contentFile.isEmpty) {
                        Task { await model.updateContent() }
                    }
                }
            }
            Divider()
            Text("Update a player from its page").font(.headline)
            Text("ElevenLabs finds the player made for this page, reads the page again, and converts and publishes it — which uses credits.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Page URL", text: $model.pageURL).textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                TextField("Title (optional)", text: $model.pageTitle)
                TextField("Author (optional)", text: $model.pageAuthor)
            }
            .textFieldStyle(.roundedBorder)
            if let runner = model.actions.runner("audio_native_update_content_from_url") {
                VoicesStudioRunButton(actions: model.actions, runner: runner, title: "Update from page", disabled: model.pageURL.isEmpty) {
                    Task { await model.updateFromPage() }
                }
            }
        }
    }
}
