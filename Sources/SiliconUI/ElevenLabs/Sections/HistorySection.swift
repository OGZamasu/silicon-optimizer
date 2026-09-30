import Foundation
import Observation
import SiliconElevenLabs
import SwiftUI

/// Everything this account has generated: filtered, played, downloaded in bulk, sent back to
/// Speech, or deleted.
struct HistorySection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HistoryScreen(screen: CreativeSession.shared(for: model).history)
    }
}

/// A generation, as the history lists it.
struct HistoryItem: Identifiable, Hashable, Sendable {
    var id: String
    var date: Date
    var voiceID: String?
    var voiceName: String?
    var modelID: String?
    var text: String?
    /// Characters this generation used.
    var characters: Int?
    var source: String?
    var contentType: String?
    var state: String?
    var outputFormat: String?
    var requestID: String?
    /// The lines of a dialogue generation.
    var dialogue: [String]

    init?(json: JSONValue) {
        guard let id = json["history_item_id"].stringValue else { return nil }
        self.id = id
        date = Date(timeIntervalSince1970: json["date_unix"].doubleValue ?? 0)
        voiceID = json["voice_id"].stringValue
        voiceName = json["voice_name"].stringValue
        modelID = json["model_id"].stringValue
        text = json["text"].stringValue
        if let from = json["character_count_change_from"].intValue, let to = json["character_count_change_to"].intValue {
            characters = abs(to - from)
        }
        source = json["source"].stringValue
        contentType = json["content_type"].stringValue
        state = json["state"].stringValue
        outputFormat = json["output_format"].stringValue
        requestID = json["request_id"].stringValue
        dialogue = (json["dialogue"].arrayValue ?? []).compactMap { $0["text"].stringValue }
    }

    init(id: String, date: Date, voiceID: String? = nil, voiceName: String? = nil, modelID: String? = nil,
         text: String? = nil, characters: Int? = nil, source: String? = nil, requestID: String? = nil) {
        self.id = id
        self.date = date
        self.voiceID = voiceID
        self.voiceName = voiceName
        self.modelID = modelID
        self.text = text
        self.characters = characters
        self.source = source
        self.requestID = requestID
        dialogue = []
    }

    /// The text, or the dialogue's lines, as one line to show.
    var summary: String {
        let whole = text ?? dialogue.joined(separator: " / ")
        return whole.isEmpty ? "(no text)" : whole
    }
}

@MainActor
@Observable
final class HistoryScreenModel: CreativeScreenModel {

    static let list = "get_speech_history"
    static let get = "get_speech_history_item_by_id"
    static let audio = "get_audio_full_from_speech_history_item"
    static let delete = "delete_speech_history_item"
    static let download = "download_speech_history_items"
    static let operationIDs = [list, get, audio, delete, download]

    static let controls: [CreativeControl] = [
        CreativeControl("Search", [list], "search"),
        CreativeControl("Voice", [list], "voice_id"),
        CreativeControl("Model", [list], "model_id"),
        CreativeControl("Source", [list], "source"),
        CreativeControl("Order", [list], "sort_direction"),
        CreativeControl("Since", [list], "date_after_unix"),
        CreativeControl("Before", [list], "date_before_unix"),
        CreativeControl("Page size", [list], "page_size"),
        CreativeControl("Load more", [list], "start_after_history_item_id"),
        CreativeControl("Details", [get], "history_item_id"),
        CreativeControl("Play", [audio], "history_item_id"),
        CreativeControl("Delete", [delete], "history_item_id"),
        CreativeControl("Download selected", [download], "history_item_ids"),
        CreativeControl("Download format", [download], "output_format"),
    ]

    let session: CreativeSession
    let listRunner: ElevenLabsRunner
    let detailRunner: ElevenLabsRunner
    let audioRunner: ElevenLabsRunner
    let deleteRunner: ElevenLabsRunner
    let downloadRunner: ElevenLabsRunner

    // Filters
    var search = ""
    var voiceID = ""
    var modelID = ""
    var source = ""
    var sortDirection = ""
    var since: Date?
    var before: Date?

    private(set) var items: [HistoryItem] = []
    private(set) var hasMore = false
    var selection: Set<HistoryItem.ID> = []
    /// The item whose details are open, and what the detail call returned.
    private(set) var detail: HistoryItem?
    private(set) var detailJSON: JSONValue?
    /// Audio fetched this session, by item.
    private(set) var audioFiles: [HistoryItem.ID: URL] = [:]
    var downloadFormat: String
    /// The last bulk download.
    private(set) var download: URL?

    /// Items per page: the spec's default.
    let pageSize: Int

    init(session: CreativeSession) {
        self.session = session
        listRunner = session.runner(Self.list, records: false)
        detailRunner = session.runner(Self.get, records: false)
        audioRunner = session.runner(Self.audio, title: "History audio")
        deleteRunner = session.runner(Self.delete, records: false)
        downloadRunner = session.runner(Self.download, title: "History download")
        pageSize = CreativeSpec.defaultValue(Self.list, "page_size")?.intValue ?? 100
        downloadFormat = CreativeSpec.documented(Self.download, "output_format").last ?? "default"
    }

    var sources: [String] { CreativeSpec.choices(Self.list, "source") }
    var sortDirections: [String] { CreativeSpec.choices(Self.list, "sort_direction") }
    var downloadFormats: [String] { CreativeSpec.documented(Self.download, "output_format") }

    /// The filters as arguments, with `start_after_history_item_id` for a next page.
    func listArguments(after lastID: String? = nil) -> [String: JSONValue] {
        var arguments: [String: JSONValue] = ["page_size": .number(Double(pageSize))]
        let term = search.trimmingCharacters(in: .whitespaces)
        if !term.isEmpty { arguments["search"] = .string(term) }
        if !voiceID.isEmpty { arguments["voice_id"] = .string(voiceID) }
        if !modelID.isEmpty { arguments["model_id"] = .string(modelID) }
        if !source.isEmpty { arguments["source"] = .string(source) }
        if !sortDirection.isEmpty { arguments["sort_direction"] = .string(sortDirection) }
        if let since { arguments["date_after_unix"] = .number(since.timeIntervalSince1970.rounded(.down)) }
        if let before { arguments["date_before_unix"] = .number(before.timeIntervalSince1970.rounded(.down)) }
        if let lastID { arguments["start_after_history_item_id"] = .string(lastID) }
        return arguments
    }

    func refresh() async {
        await load(after: nil)
    }

    func loadMore() async {
        await load(after: items.last?.id)
    }

    private func load(after lastID: String?) async {
        guard CreativeRunGate.isKnown(listRunner) else { return }
        guard case .json(let value, _)? = await listRunner.perform(arguments: listArguments(after: lastID)) else { return }
        let page = (value["history"].arrayValue ?? []).compactMap(HistoryItem.init(json:))
        if lastID == nil {
            items = page
            selection = selection.filter { id in page.contains { $0.id == id } }
        } else {
            items += page.filter { item in !items.contains { $0.id == item.id } }
        }
        hasMore = value["has_more"].boolValue ?? false
    }

    /// Opens an item's details (`GET /v1/history/{id}`, free).
    func open(_ item: HistoryItem) async {
        detail = item
        detailJSON = nil
        guard CreativeRunGate.isKnown(detailRunner) else { return }
        if case .json(let value, _)? = await detailRunner.perform(arguments: ["history_item_id": .string(item.id)]),
           detail?.id == item.id {
            detailJSON = value
            if let full = HistoryItem(json: value) { detail = full }
        }
    }

    func closeDetail() {
        detail = nil
        detailJSON = nil
    }

    /// Fetches an item's audio to play and keep (free: it was paid for when generated).
    func fetchAudio(_ item: HistoryItem) async {
        guard audioFiles[item.id] == nil, CreativeRunGate.isKnown(audioRunner) else { return }
        audioRunner.title = "History — \(item.voiceName ?? "audio")"
        if let file = CreativeResults.audioFile(in: await audioRunner.perform(arguments: ["history_item_id": .string(item.id)])) {
            audioFiles[item.id] = file.url
        }
    }

    /// Deletes an item, after the confirmation naming it.
    func delete(_ item: HistoryItem) async {
        guard CreativeRunGate.isKnown(deleteRunner) else { return }
        let excerpt = item.summary.count > 40 ? String(item.summary.prefix(39)) + "…" : item.summary
        let done = await deleteRunner.perform(
            arguments: ["history_item_id": .string(item.id)],
            subject: "the history item “\(excerpt)”",
            consequence: "ElevenLabs will delete this generation and its audio from your history. This cannot be undone."
        )
        guard done != nil else { return }
        items.removeAll { $0.id == item.id }
        selection.remove(item.id)
        if detail?.id == item.id { closeDetail() }
    }

    func downloadArguments() -> [String: JSONValue] {
        var arguments: [String: JSONValue] = [
            "history_item_ids": .array(items.map(\.id).filter(selection.contains).map(JSONValue.string)),
        ]
        if downloadFormat != "default" { arguments["output_format"] = .string(downloadFormat) }
        return arguments
    }

    /// Downloads the selected items: several arrive as one zip.
    func downloadSelected() async {
        guard !selection.isEmpty, CreativeRunGate.isKnown(downloadRunner) else { return }
        download = CreativeResults.audioFile(in: await downloadRunner.perform(arguments: downloadArguments()))?.url
    }

    /// Sends an item back to Speech: its text, voice and model, ready to generate again.
    func reuseInSpeech(_ item: HistoryItem) {
        let speech = session.speech
        if let text = item.text { speech.text = text }
        if let voice = item.voiceID { speech.voiceID = voice }
        if let model = item.modelID { speech.modelID = model }
        session.open(.speech)
    }

    var selectedCharacters: Int {
        items.filter { selection.contains($0.id) }.compactMap(\.characters).reduce(0, +)
    }
}

struct HistoryScreen: View {
    @Bindable var screen: HistoryScreenModel
    @State private var filtersShown = false

    var body: some View {
        ElevenLabsSectionPage(.history) {
            Button {
                Task { await screen.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(screen.listRunner.isRunning)
        } content: {
            filters
            if let detail = screen.detail { detailCard(detail) }
            list
        }
        .task {
            if screen.items.isEmpty, screen.listRunner.phase == .idle { await screen.refresh() }
        }
    }

    private var filters: some View {
        CreativeCard {
            HStack(spacing: 8) {
                TextField("Search", text: $screen.search, prompt: Text("Search the text"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await screen.refresh() } }
                Button("Filters") { filtersShown.toggle() }
                    .popover(isPresented: $filtersShown, arrowEdge: .bottom) { filterForm }
            }
            let active = [!screen.voiceID.isEmpty, !screen.modelID.isEmpty, !screen.source.isEmpty,
                          screen.since != nil, screen.before != nil, !screen.sortDirection.isEmpty].filter { $0 }.count
            if active > 0 {
                HStack {
                    Text("\(active) filter\(active == 1 ? "" : "s") on").font(.caption).foregroundStyle(.secondary)
                    Button("Clear") {
                        screen.voiceID = ""; screen.modelID = ""; screen.source = ""
                        screen.since = nil; screen.before = nil; screen.sortDirection = ""
                        Task { await screen.refresh() }
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private var filterForm: some View {
        Form {
            ElevenLabsVoicePicker(selection: $screen.voiceID, title: "Voice", directory: screen.session.voices)
            CreativeModelPicker(title: "Model", selection: $screen.modelID, directory: screen.session.models) { _ in true }
            Picker("Source", selection: $screen.source) {
                Text("Any").tag("")
                ForEach(screen.sources, id: \.self) { Text($0).tag($0) }
            }
            Picker("Order", selection: $screen.sortDirection) {
                Text("Default").tag("")
                ForEach(screen.sortDirections, id: \.self) { Text($0 == "asc" ? "Oldest first" : $0 == "desc" ? "Newest first" : $0).tag($0) }
            }
            dateRow("Since", date: $screen.since)
            dateRow("Before", date: $screen.before)
            HStack {
                Spacer()
                Button("Apply") {
                    filtersShown = false
                    Task { await screen.refresh() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .padding(6)
    }

    private func dateRow(_ title: String, date: Binding<Date?>) -> some View {
        HStack {
            Toggle(title, isOn: Binding(get: { date.wrappedValue != nil },
                                        set: { date.wrappedValue = $0 ? Calendar.current.startOfDay(for: Date()) : nil }))
            if let value = date.wrappedValue {
                DatePicker(title, selection: Binding(get: { value }, set: { date.wrappedValue = $0 }), displayedComponents: .date)
                    .labelsHidden()
            }
        }
    }

    private var list: some View {
        CreativeCard("Generations", systemImage: "clock.arrow.circlepath") {
            if !screen.selection.isEmpty {
                Text("\(screen.selection.count) selected").font(.caption).foregroundStyle(.secondary)
                Picker("Format", selection: $screen.downloadFormat) {
                    ForEach(screen.downloadFormats, id: \.self) { Text($0 == "default" ? "As generated" : $0.uppercased()).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                Button("Download") { Task { await screen.downloadSelected() } }
                    .disabled(screen.downloadRunner.isRunning)
            }
        } content: {
            if screen.listRunner.isRunning, screen.items.isEmpty {
                ProgressView().frame(maxWidth: .infinity)
            } else if screen.items.isEmpty, screen.listRunner.phase == .succeeded {
                Text("Nothing matches.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(screen.items) { item in
                row(item)
                Divider()
            }
            if screen.hasMore {
                Button("Load more") { Task { await screen.loadMore() } }
                    .controlSize(.small)
                    .disabled(screen.listRunner.isRunning)
            }
            if let download = screen.download {
                ElevenLabsFileResult(url: download, contentType: download.pathExtension == "zip" ? "application/zip" : "audio/mpeg",
                                     bytes: (try? download.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            ElevenLabsRunnerOutput(runner: screen.listRunner, showsResult: false)
            ElevenLabsRunnerOutput(runner: screen.downloadRunner, showsResult: false)
            ElevenLabsRunnerOutput(runner: screen.deleteRunner, showsResult: false)
        }
    }

    private func row(_ item: HistoryItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("Select", isOn: Binding(
                get: { screen.selection.contains(item.id) },
                set: { if $0 { screen.selection.insert(item.id) } else { screen.selection.remove(item.id) } }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.summary).lineLimit(2)
                HStack(spacing: 8) {
                    Text(item.date, format: .dateTime.day().month().year().hour().minute())
                    if let voice = item.voiceName { Text(voice) }
                    if let model = item.modelID { Text(model) }
                    if let source = item.source { Text(source) }
                    if let characters = item.characters { Text("\(characters.formatted()) characters") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let audio = screen.audioFiles[item.id] {
                    ElevenLabsAudioPlayerView(url: audio).id(audio)
                }
            }
            Spacer(minLength: 6)
            HStack(spacing: 4) {
                if screen.audioFiles[item.id] == nil {
                    Button {
                        Task { await screen.fetchAudio(item) }
                    } label: {
                        Image(systemName: "play.circle")
                    }
                    .help("Fetch and play")
                    .accessibilityLabel("Play \(item.summary)")
                    .disabled(screen.audioRunner.isRunning)
                }
                Button {
                    Task { await screen.open(item) }
                } label: {
                    Image(systemName: "info.circle")
                }
                .help("Details")
                .accessibilityLabel("Details")
                Button {
                    screen.reuseInSpeech(item)
                } label: {
                    Image(systemName: "arrow.uturn.forward.circle")
                }
                .help("Open in Speech with the same text, voice and model")
                .accessibilityLabel("Open in Speech")
                .disabled(item.text == nil)
                Button {
                    Task { await screen.delete(item) }
                } label: {
                    Image(systemName: "trash")
                }
                .help("Delete from ElevenLabs")
                .accessibilityLabel("Delete")
            }
            .buttonStyle(.borderless)
        }
    }

    private func detailCard(_ item: HistoryItem) -> some View {
        CreativeCard("Details", systemImage: "info.circle") {
            Button {
                screen.closeDetail()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Close details")
        } content: {
            Text(item.summary).textSelection(.enabled)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                detailRow("When", item.date.formatted(date: .abbreviated, time: .shortened))
                detailRow("Voice", item.voiceName ?? item.voiceID)
                detailRow("Model", item.modelID)
                detailRow("Source", item.source)
                detailRow("Characters", item.characters.map { $0.formatted() })
                detailRow("Format", item.outputFormat ?? item.contentType)
                detailRow("Request", item.requestID)
                detailRow("Item", item.id)
            }
            .font(.callout)
            if let settings = screen.detailJSON?["settings"], settings != .null {
                ElevenLabsJSONTree(settings, label: "settings")
            }
            ElevenLabsRunnerOutput(runner: screen.detailRunner, showsResult: false)
        }
    }

    @ViewBuilder
    private func detailRow(_ title: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            GridRow {
                Text(title).foregroundStyle(.secondary)
                Text(value).textSelection(.enabled)
            }
        }
    }
}
