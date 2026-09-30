import Foundation
import Observation
import SiliconElevenLabs
import SwiftUI

/// Voice isolation: speech lifted out of noise and music, with the earlier isolations the
/// account keeps.
struct IsolationSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        IsolationScreen(screen: CreativeSession.shared(for: model).isolation)
    }
}

/// An earlier isolation, as the history lists it.
struct IsolationHistoryItem: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var created: Date?
    var format: String?
    var duration: Double?
    var processing: Bool

    init?(json: JSONValue) {
        guard let id = json["id"].stringValue else { return nil }
        self.id = id
        title = json["title"].stringValue ?? "Untitled"
        created = json["created_at_unix"].doubleValue.map { Date(timeIntervalSince1970: $0) }
        format = json["format"].stringValue
        duration = json["duration_seconds"].doubleValue
        processing = json["processing"].boolValue ?? false
    }

    init(id: String, title: String, created: Date? = nil, format: String? = nil, duration: Double? = nil, processing: Bool = false) {
        self.id = id
        self.title = title
        self.created = created
        self.format = format
        self.duration = duration
        self.processing = processing
    }
}

@MainActor
@Observable
final class IsolationScreenModel: CreativeScreenModel {

    static let full = "audio_isolation"
    static let stream = "audio_isolation_stream"
    static let history = "get_audio_isolation_history"
    static let delete = "delete_audio_isolation_history_item"
    static let operationIDs = [full, stream, history, delete]

    static let controls: [CreativeControl] = [
        CreativeControl("Recording", [full, stream], "audio"),
        CreativeControl("Input is raw 16 kHz PCM", [full, stream], "file_format"),
        CreativeControl("History search", [history], "search"),
        CreativeControl("History page", [history], "page"),
        CreativeControl("History page size", [history], "page_size"),
        CreativeControl("Delete", [delete], "history_item_id"),
    ]

    let session: CreativeSession
    var source: URL?
    var delivery: SpeechScreenModel.Delivery = .whole
    var rawPCMInput = false

    var search = ""
    private(set) var items: [IsolationHistoryItem] = []
    private(set) var page = 1
    private(set) var hasMore = false
    private(set) var takes: [CreativeTake] = []
    private(set) var sources: [CreativeTake.ID: URL] = [:]
    private(set) var lastRunner: ElevenLabsRunner

    @ObservationIgnored private let runners: [String: ElevenLabsRunner]
    let historyRunner: ElevenLabsRunner
    let deleteRunner: ElevenLabsRunner

    /// Items asked for per request. Without a search the history has no pages — `page` only
    /// counts with one — so "Load more" asks for a bigger first page instead, up to the
    /// spec's maximum.
    private(set) var pageSize: Int

    static var pageSizeRange: ClosedRange<Double> { CreativeSpec.range(history, "page_size") ?? 1...100 }

    init(session: CreativeSession) {
        self.session = session
        let full = session.runner(Self.full, title: "Voice isolation")
        runners = [Self.full: full, Self.stream: session.runner(Self.stream, title: "Voice isolation")]
        lastRunner = full
        pageSize = Int(min(max(50, Self.pageSizeRange.lowerBound), Self.pageSizeRange.upperBound))
        historyRunner = session.runner(Self.history, records: false)
        deleteRunner = session.runner(Self.delete, records: false)
    }

    var operationID: String { delivery == .stream ? Self.stream : Self.full }
    var runner: ElevenLabsRunner { runners[operationID]! }
    var pcmFormatValue: String? { CreativeSpec.choices(operationID, "file_format").first { $0.hasPrefix("pcm") } }

    var problems: [String] { source == nil ? ["Choose a recording."] : [] }

    func arguments() -> [String: JSONValue] {
        var arguments: [String: JSONValue] = [:]
        if rawPCMInput, let pcm = pcmFormatValue { arguments["file_format"] = .string(pcm) }
        return arguments
    }

    func files() -> [String: [ElevenLabsFile]] {
        source.map { ["audio": [ElevenLabsFile(url: $0)]] } ?? [:]
    }

    func isolate() async {
        guard problems.isEmpty else { return }
        let runner = runner
        guard CreativeRunGate.isKnown(runner) else { return }
        runner.streamMode = delivery == .stream ? .play : .collect
        lastRunner = runner
        guard let result = await runner.perform(arguments: arguments(), files: files()) else { return }
        if let take = CreativeTake(result: result, title: "Isolated — \(source?.lastPathComponent ?? "recording")") {
            takes.insert(take, at: 0)
            sources[take.id] = source
        }
    }

    func removeTake(_ take: CreativeTake) {
        takes.removeAll { $0.id == take.id }
        sources[take.id] = nil
    }

    // MARK: - History

    /// The arguments for a history page. `page` counts only with a search, as the spec says.
    func historyArguments(page: Int) -> [String: JSONValue] {
        var arguments: [String: JSONValue] = ["page_size": .number(Double(pageSize))]
        let term = search.trimmingCharacters(in: .whitespaces)
        if !term.isEmpty {
            arguments["search"] = .string(term)
            arguments["page"] = .number(Double(page))
        }
        return arguments
    }

    /// The first page again, for the search as it stands.
    func refreshHistory() async {
        await loadHistory(page: 1)
    }

    /// The next page with a search; without one, a bigger first page.
    func loadMoreHistory() async {
        if search.trimmingCharacters(in: .whitespaces).isEmpty {
            pageSize = min(pageSize * 2, Int(Self.pageSizeRange.upperBound))
            await loadHistory(page: 1)
        } else {
            await loadHistory(page: page + 1)
        }
    }

    private func loadHistory(page: Int) async {
        guard CreativeRunGate.isKnown(historyRunner) else { return }
        guard case .json(let value, _)? = await historyRunner.perform(arguments: historyArguments(page: page)) else { return }
        let fetched = (value["items"].arrayValue ?? []).compactMap(IsolationHistoryItem.init(json:))
        items = page == 1 ? fetched : items + fetched.filter { item in !items.contains { $0.id == item.id } }
        self.page = page
        let searching = !search.trimmingCharacters(in: .whitespaces).isEmpty
        hasMore = (value["has_more"].boolValue ?? false)
            && (searching || pageSize < Int(Self.pageSizeRange.upperBound))
    }

    /// Deletes an earlier isolation, after the shell's confirmation naming it.
    func delete(_ item: IsolationHistoryItem) async {
        guard CreativeRunGate.isKnown(deleteRunner) else { return }
        let done = await deleteRunner.perform(
            arguments: ["history_item_id": .string(item.id)],
            subject: "the isolation “\(item.title)”",
            consequence: "ElevenLabs will delete this isolation from your history. This cannot be undone."
        )
        if done != nil { items.removeAll { $0.id == item.id } }
    }
}

struct IsolationScreen: View {
    @Bindable var screen: IsolationScreenModel

    var body: some View {
        ElevenLabsSectionPage(.isolation) {
            CreativeCard("Recording", systemImage: "waveform") {
                CreativeFileField(title: "Audio or video with speech in it", url: $screen.source)
                Picker("Play", selection: $screen.delivery) {
                    ForEach(SpeechScreenModel.Delivery.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("The recording is raw 16-bit, 16 kHz mono PCM (lower latency)", isOn: $screen.rawPCMInput)
                    .disabled(screen.pcmFormatValue == nil)
            }
            CreativeRunRow(
                runner: screen.runner, title: "Isolate the voice", problems: screen.problems,
                note: screen.source.flatMap(CreativeMedia.duration(of:)).map {
                    "Billed by the recording's length: \(ElevenLabsAudioPlayerView.clock($0))."
                }
            ) {
                Task { await screen.isolate() }
            }
            result
            CreativeTakesList(takes: Array(screen.takes.dropFirst())) { screen.removeTake($0) }
            historyCard
        }
    }

    @ViewBuilder
    private var result: some View {
        let runner = screen.lastRunner
        if runner.phase != .idle || screen.takes.first != nil {
            CreativeCard("Before and after", systemImage: "arrow.left.arrow.right") {
                if let take = screen.takes.first {
                    if let original = screen.sources[take.id] {
                        ElevenLabsAudioPlayerView(url: original, title: "Before — \(original.lastPathComponent)").id(original)
                    }
                    CreativeAudioResult(take: take, title: "After — voice only")
                    HStack {
                        Button("Transcribe this") {
                            screen.session.transcription.source = take.file
                            screen.session.open(.transcription)
                        }
                        Button("Change its voice") {
                            screen.session.voiceChanger.source = take.file
                            screen.session.open(.voiceChanger)
                        }
                    }
                    .controlSize(.small)
                    if let meta = runner.result?.meta { ElevenLabsMetaLine(meta: meta) }
                }
                ElevenLabsRunnerOutput(runner: runner, showsResult: false)
            }
        }
    }

    private var historyCard: some View {
        CreativeCard("Earlier isolations", systemImage: "clock.arrow.circlepath") {
            if screen.historyRunner.isRunning { ProgressView().controlSize(.small) }
            Button("Refresh") { Task { await screen.refreshHistory() } }
                .controlSize(.small)
                .disabled(screen.historyRunner.isRunning)
        } content: {
            TextField("Search", text: $screen.search, prompt: Text("Search titles"))
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await screen.refreshHistory() } }
            if screen.items.isEmpty, screen.historyRunner.phase == .succeeded {
                Text("Nothing here yet.").font(.callout).foregroundStyle(.secondary)
            } else if screen.items.isEmpty, screen.historyRunner.phase == .idle {
                Text("Refresh to list the isolations this account has made.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(screen.items) { item in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title).lineLimit(1)
                        HStack(spacing: 6) {
                            if let created = item.created { Text(created, format: .dateTime.day().month().hour().minute()) }
                            if let duration = item.duration { Text(ElevenLabsAudioPlayerView.clock(duration)) }
                            if let format = item.format { Text(format) }
                            if item.processing { Text("processing").foregroundStyle(.orange) }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 6)
                    Button {
                        Task { await screen.delete(item) }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Delete from ElevenLabs")
                    .accessibilityLabel("Delete \(item.title)")
                    .disabled(screen.deleteRunner.isRunning || screen.deleteRunner.isAwaitingConfirmation)
                }
            }
            if screen.hasMore {
                Button("Load more") { Task { await screen.loadMoreHistory() } }
                    .controlSize(.small)
                    .disabled(screen.historyRunner.isRunning)
            }
            ElevenLabsRunnerOutput(runner: screen.historyRunner, showsResult: false)
            ElevenLabsRunnerOutput(runner: screen.deleteRunner, showsResult: false)
        }
    }
}
