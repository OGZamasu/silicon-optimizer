import AVFoundation
import Observation
import SiliconElevenLabs
import SwiftUI

/// A voice the account can use, as the voices list describes it.
struct ElevenLabsVoice: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    /// "premade", "cloned", "generated", "professional"…
    var category: String?
    var description: String?
    /// accent, age, gender, use case…
    var labels: [String: String]
    /// A public sample. Played with no key; https only.
    var previewURL: URL?

    init(id: String, name: String, category: String? = nil, description: String? = nil,
         labels: [String: String] = [:], previewURL: URL? = nil) {
        self.id = id
        self.name = name
        self.category = category
        self.description = description
        self.labels = labels
        self.previewURL = previewURL
    }

    /// From a `VoiceResponseModel`; nil without an id.
    init?(json: JSONValue) {
        guard let id = json["voice_id"].stringValue, !id.isEmpty else { return nil }
        self.id = id
        name = json["name"].stringValue ?? id
        category = json["category"].stringValue
        description = json["description"].stringValue
        labels = (json["labels"].objectValue ?? [:]).compactMapValues(\.stringValue)
        previewURL = json["preview_url"].stringValue.flatMap(URL.init(string:)).flatMap {
            $0.scheme == "https" ? $0 : nil
        }
    }

    /// "British · middle aged · narration": the labels worth a glance.
    var labelSummary: String {
        ["accent", "age", "gender", "use_case", "descriptive"]
            .compactMap { labels[$0] }
            .map { $0.replacingOccurrences(of: "_", with: " ") }
            .joined(separator: " · ")
    }
}

/// Every voice the account can use, fetched once per session and shared by every picker.
@MainActor
@Observable
final class ElevenLabsVoiceDirectory {
    private(set) var voices: [ElevenLabsVoice] = []
    private(set) var loading = false
    private(set) var loaded = false
    private(set) var error: String?
    /// The voice whose preview is playing.
    private(set) var previewing: String?

    /// Pages fetched at most, 100 voices each: an account with more is searched, not listed.
    static let pageLimit = 10

    @ObservationIgnored private let client: @MainActor () -> ElevenLabsClient?
    /// The client the list was fetched with: another one (a new key, another region) means
    /// another account's voices.
    @ObservationIgnored private var loadedFor: ObjectIdentifier?
    @ObservationIgnored private var previewPlayer: AVPlayer?
    @ObservationIgnored private var previewEnd: (any NSObjectProtocol)?

    init(client: @escaping @MainActor () -> ElevenLabsClient?) {
        self.client = client
    }

    func voice(id: String) -> ElevenLabsVoice? {
        voices.first { $0.id == id }
    }

    func loadIfNeeded() async {
        if loaded, loadedFor != client().map(ObjectIdentifier.init) { reset() }
        guard !loaded, !loading else { return }
        await refresh()
    }

    /// Fetches the list again: `GET /v2/voices`, a page at a time.
    func refresh() async {
        guard !loading else { return }
        guard let client = client() else {
            error = ElevenLabsError.notLinked.description
            return
        }
        loading = true
        defer { loading = false }
        do {
            voices = try await Self.fetch(with: client)
            loaded = true
            loadedFor = ObjectIdentifier(client)
            error = nil
        } catch {
            self.error = ElevenLabsRunnerFailure(error).message
        }
    }

    /// Replaces the list — for a section that has just fetched voices itself, and for tests.
    func set(_ voices: [ElevenLabsVoice]) {
        self.voices = voices
        loaded = true
        loadedFor = client().map(ObjectIdentifier.init)
        error = nil
    }

    func reset() {
        stopPreview()
        voices = []
        loaded = false
        loadedFor = nil
        error = nil
    }

    static func fetch(with client: ElevenLabsClient) async throws -> [ElevenLabsVoice] {
        var voices: [ElevenLabsVoice] = []
        var token: String?
        for _ in 0..<pageLimit {
            var arguments: [String: JSONValue] = ["page_size": 100]
            if let token { arguments["next_page_token"] = .string(token) }
            guard case .json(let page, _) = try await client.call("get_user_voices_v2", arguments: arguments) else {
                break
            }
            voices += (page["voices"].arrayValue ?? []).compactMap(ElevenLabsVoice.init(json:))
            token = page["next_page_token"].stringValue
            guard page["has_more"].boolValue == true, token != nil else { break }
        }
        return voices
    }

    // MARK: - Previews

    /// Plays `voice`'s public sample, or stops it if it is the one playing.
    func togglePreview(_ voice: ElevenLabsVoice) {
        if previewing == voice.id {
            stopPreview()
            return
        }
        stopPreview()
        guard let url = voice.previewURL else { return }
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        previewEnd = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopPreview() }
        }
        previewPlayer = player
        previewing = voice.id
        player.play()
    }

    func stopPreview() {
        previewPlayer?.pause()
        previewPlayer = nil
        if let previewEnd { NotificationCenter.default.removeObserver(previewEnd) }
        previewEnd = nil
        previewing = nil
    }
}

/// Picks a voice: a button naming the chosen one, opening a searchable list grouped by kind,
/// each with its sample to play.
struct ElevenLabsVoicePicker: View {
    /// Optional: a picker handed its own `directory` needs no app model (previews, tests).
    @Environment(AppModel.self) private var model: AppModel?
    @Binding var selection: String
    var title: String
    /// Which voices to offer; all of them when nil.
    var include: ((ElevenLabsVoice) -> Bool)?
    /// A directory other than the pane's — for previews and tests.
    var directory: ElevenLabsVoiceDirectory?
    /// When given, the first choice in the list, meaning "no particular voice" — it sets the
    /// selection to "" (a filter's "Any voice", say).
    var noneTitle: String?

    @State private var choosing = false
    @State private var search = ""

    init(
        selection: Binding<String>, title: String = "Voice",
        include: ((ElevenLabsVoice) -> Bool)? = nil, directory: ElevenLabsVoiceDirectory? = nil,
        noneTitle: String? = nil
    ) {
        _selection = selection
        self.title = title
        self.include = include
        self.directory = directory
        self.noneTitle = noneTitle
    }

    /// The directory to show: the one given, else the pane's. With neither, an empty one.
    private var voices: ElevenLabsVoiceDirectory {
        directory ?? model?.elevenLabsPane.voices ?? Self.empty
    }

    @MainActor private static let empty = ElevenLabsVoiceDirectory(client: { nil })

    var body: some View {
        let voices = voices
        LabeledContent(title) {
            HStack(spacing: 6) {
                Button {
                    choosing = true
                } label: {
                    HStack(spacing: 4) {
                        Text(voices.voice(id: selection)?.name
                             ?? (selection.isEmpty ? (noneTitle ?? "Choose a voice") : selection))
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down").font(.caption2)
                    }
                }
                .popover(isPresented: $choosing, arrowEdge: .bottom) { list(voices) }
                if let voice = voices.voice(id: selection), voice.previewURL != nil {
                    previewButton(voice, in: voices)
                }
                if voices.loading { ProgressView().controlSize(.small) }
            }
        }
        .task { await voices.loadIfNeeded() }
    }

    private func list(_ voices: ElevenLabsVoiceDirectory) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Search voices", text: $search)
                    .textFieldStyle(.roundedBorder)
                Button {
                    Task { await voices.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Fetch the voices list again")
                .disabled(voices.loading)
            }
            if let error = voices.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            List {
                if let noneTitle {
                    HStack(spacing: 8) {
                        Image(systemName: selection.isEmpty ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selection.isEmpty ? Color.accentColor : .secondary)
                        Text(noneTitle)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selection = ""
                        choosing = false
                    }
                }
                ForEach(grouped(voices), id: \.0) { category, members in
                    Section(category) {
                        ForEach(members) { voice in
                            row(voice, in: voices)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .frame(width: 380, height: 360)
            if voices.voices.isEmpty, !voices.loading, voices.error == nil {
                Text("No voices yet.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
    }

    private func row(_ voice: ElevenLabsVoice, in voices: ElevenLabsVoiceDirectory) -> some View {
        HStack(spacing: 8) {
            Image(systemName: voice.id == selection ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(voice.id == selection ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(voice.name).lineLimit(1)
                if !voice.labelSummary.isEmpty {
                    Text(voice.labelSummary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if voice.previewURL != nil { previewButton(voice, in: voices) }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            selection = voice.id
            choosing = false
        }
    }

    private func previewButton(_ voice: ElevenLabsVoice, in voices: ElevenLabsVoiceDirectory) -> some View {
        Button {
            voices.togglePreview(voice)
        } label: {
            Image(systemName: voices.previewing == voice.id ? "stop.circle" : "play.circle")
        }
        .buttonStyle(.borderless)
        .help(voices.previewing == voice.id ? "Stop the sample" : "Play \(voice.name)'s sample")
        .accessibilityLabel(voices.previewing == voice.id ? "Stop sample" : "Play sample")
    }

    /// The matching voices, grouped by category in a fixed order.
    private func grouped(_ voices: ElevenLabsVoiceDirectory) -> [(String, [ElevenLabsVoice])] {
        let words = search.lowercased().split(whereSeparator: \.isWhitespace)
        let matching = voices.voices.filter { voice in
            guard include?(voice) ?? true else { return false }
            guard !words.isEmpty else { return true }
            let haystack = ([voice.name, voice.category ?? "", voice.description ?? ""] + Array(voice.labels.values))
                .joined(separator: " ").lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
        let order = ["cloned", "professional", "generated", "premade"]
        let groups = Dictionary(grouping: matching) { $0.category ?? "other" }
        return groups.keys
            .sorted { (order.firstIndex(of: $0) ?? order.count, $0) < (order.firstIndex(of: $1) ?? order.count, $1) }
            .map { ($0.capitalized, groups[$0]!.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) }
    }
}
