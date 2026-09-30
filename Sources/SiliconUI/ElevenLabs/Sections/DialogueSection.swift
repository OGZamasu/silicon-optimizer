import Foundation
import Observation
import SiliconElevenLabs
import SwiftUI

/// Text to dialogue: a script of lines, each with its own voice, performed as one
/// conversation.
struct DialogueSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        DialogueScreen(screen: CreativeSession.shared(for: model).dialogue)
    }
}

/// One line of the script.
struct DialogueLine: Identifiable, Hashable, Sendable {
    let id = UUID()
    var voiceID: String
    var text: String
}

@MainActor
@Observable
final class DialogueScreenModel: CreativeScreenModel {

    static let full = "text_to_dialogue"
    static let fullWithTimestamps = "text_to_dialogue_full_with_timestamps"
    static let stream = "text_to_dialogue_stream"
    static let streamWithTimestamps = "text_to_dialogue_stream_with_timestamps"
    static let operationIDs = [full, fullWithTimestamps, stream, streamWithTimestamps]

    static let controls: [CreativeControl] = [
        CreativeControl("Line voice", operationIDs, "inputs[].voice_id"),
        CreativeControl("Line text", operationIDs, "inputs[].text"),
        CreativeControl("Model", operationIDs, "model_id"),
        CreativeControl("Output format", operationIDs, "output_format"),
        CreativeControl("Stability", operationIDs, "settings.stability"),
        CreativeControl("Similarity", operationIDs, "settings.similarity"),
        CreativeControl("Language", operationIDs, "language_code"),
        CreativeControl("Seed", operationIDs, "seed"),
        CreativeControl("Text before", operationIDs, "previous_text"),
        CreativeControl("Text after", operationIDs, "future_text"),
        CreativeControl("Continue from the last take", operationIDs, "previous_request_ids"),
        CreativeControl("Lead into a later take", operationIDs, "next_request_ids"),
        CreativeControl("Text normalization", operationIDs, "apply_text_normalization"),
        CreativeControl("Professional voices as instant", operationIDs, "use_pvc_as_ivc"),
        CreativeControl("History and stitching", operationIDs, "enable_logging"),
        CreativeControl("Pronunciation dictionaries", operationIDs,
                        "pronunciation_dictionary_locators[].pronunciation_dictionary_id"),
        CreativeControl("Pronunciation dictionary version", operationIDs,
                        "pronunciation_dictionary_locators[].version_id"),
    ]

    let session: CreativeSession
    var lines: [DialogueLine] = [DialogueLine(voiceID: "", text: ""), DialogueLine(voiceID: "", text: "")]
    var modelID: String
    var outputFormat: String
    var delivery: SpeechScreenModel.Delivery = .whole
    var timestamps = false
    /// Send `settings` at all; otherwise each voice's own apply.
    var overridesSettings = false
    var stability: Double
    var similarity: Double

    var languageCode = ""
    var seed: Int?
    var previousText = ""
    var futureText = ""
    var continueFromLastTake = false
    var nextRequestID = ""
    var textNormalization: String
    var usePVCAsIVC = false
    var enableLogging = true
    var dictionaries: [CreativeDictionaryLocator] = []

    private(set) var takes: [CreativeTake] = []
    private(set) var words: [CreativeTimedWord] = []
    /// Which line each stretch of the newest take belongs to, from `voice_segments`.
    private(set) var segments: [VoiceSegmentTiming] = []
    private(set) var lastRunner: ElevenLabsRunner
    @ObservationIgnored private let runners: [String: ElevenLabsRunner]

    /// The on-screen line each input of the last run came from (blank lines are not sent, so
    /// the answer's input index is not the line number).
    private(set) var sentLines: [Int] = []

    /// The on-screen line (from 0) a segment of the newest take belongs to.
    func screenLine(of segment: VoiceSegmentTiming) -> Int {
        sentLines.indices.contains(segment.line) ? sentLines[segment.line] : segment.line
    }

    struct VoiceSegmentTiming: Hashable, Sendable {
        var line: Int
        var voiceID: String
        var start: Double
        var end: Double
    }

    init(session: CreativeSession) {
        self.session = session
        modelID = CreativeSpec.defaultString(Self.full, "model_id") ?? ""
        outputFormat = CreativeSpec.defaultString(Self.full, "output_format") ?? ""
        textNormalization = CreativeSpec.defaultString(Self.full, "apply_text_normalization") ?? ""
        stability = CreativeSpec.defaultNumber(Self.full, "settings.stability") ?? 0.5
        similarity = CreativeSpec.defaultNumber(Self.full, "settings.similarity") ?? 0.75
        var runners: [String: ElevenLabsRunner] = [:]
        for id in Self.operationIDs { runners[id] = session.runner(id, title: "Dialogue") }
        self.runners = runners
        lastRunner = runners[Self.full]!
    }

    var operationID: String {
        switch (delivery, timestamps) {
        case (.whole, false): Self.full
        case (.whole, true): Self.fullWithTimestamps
        case (.stream, false): Self.stream
        case (.stream, true): Self.streamWithTimestamps
        }
    }

    var runner: ElevenLabsRunner { runners[operationID]! }

    /// A stream plays as it arrives, timings or not (see Speech's `streamMode`).
    var streamMode: ElevenLabsRunner.StreamMode { delivery == .stream ? .play : .collect }

    /// The run in flight, or waiting for its confirmation, whichever operation it is: the
    /// pickers that choose the operation can change while it runs, and must not hand the Run
    /// row an idle runner (a second paid run, and a Cancel that no longer reaches the first).
    var busyRunner: ElevenLabsRunner? {
        Self.operationIDs.compactMap { runners[$0] }.first { $0.isRunning || $0.isAwaitingConfirmation }
    }

    /// What the Run row shows: the run in flight, so Cancel reaches it, else the chosen one.
    var activeRunner: ElevenLabsRunner { busyRunner ?? runner }

    /// Said while a run is in flight.
    static let busyProblem = "Wait for the current take to finish, or cancel it."
    var outputFormats: [String] { CreativeSpec.choices(operationID, "output_format") }
    var effectiveOutputFormat: String {
        outputFormats.contains(outputFormat)
            ? outputFormat : (CreativeSpec.defaultString(operationID, "output_format") ?? outputFormat)
    }
    var selectedModel: CreativeModel? { session.models.model(id: modelID) }
    var totalCharacters: Int { lines.reduce(0) { $0 + $1.text.count } }
    var estimatedCharacters: Int { selectedModel?.estimatedCost(characters: totalCharacters) ?? totalCharacters }
    var distinctVoices: Int { Set(lines.map(\.voiceID).filter { !$0.isEmpty }).count }
    var lastRequestID: String? { takes.first?.requestID }

    func range(_ name: String) -> ClosedRange<Double> {
        CreativeSpec.range(Self.full, "settings.\(name)") ?? 0...1
    }

    /// The most distinct voices one request takes, from the `inputs` description.
    static let maxVoices = 10
    /// The character count the `inputs` description recommends staying under.
    static let recommendedCharacters = 2000

    var problems: [String] {
        var problems: [String] = busyRunner == nil ? [] : [Self.busyProblem]
        let spoken = lines.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if spoken.isEmpty { problems.append("Write at least one line.") }
        if spoken.contains(where: { $0.voiceID.isEmpty }) { problems.append("Choose a voice for every line.") }
        if distinctVoices > Self.maxVoices { problems.append("A dialogue takes at most \(Self.maxVoices) different voices.") }
        for (name, text) in [("previous_text", previousText), ("future_text", futureText)] {
            if let limit = CreativeSpec.maxLength(Self.full, name), text.count > limit {
                problems.append("“\(name == "previous_text" ? "Text before" : "Text after")” takes at most \(limit) characters.")
            }
        }
        if let seed, let range = CreativeSpec.range(operationID, "seed"), !range.contains(Double(seed)) {
            problems.append("The seed must be between \(Int(range.lowerBound)) and \(Int(range.upperBound)).")
        }
        return problems
    }

    func arguments() -> [String: JSONValue] {
        let inputs: [JSONValue] = lines
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { ["text": .string($0.text), "voice_id": .string($0.voiceID)] }
        var arguments: [String: JSONValue] = [
            "inputs": .array(inputs),
            "output_format": .string(effectiveOutputFormat),
        ]
        if !modelID.isEmpty { arguments["model_id"] = .string(modelID) }
        if overridesSettings {
            arguments["settings"] = [
                "stability": .number(CreativeVoiceSettings.rounded(stability)),
                "similarity": .number(CreativeVoiceSettings.rounded(similarity)),
            ]
        }
        let language = languageCode.trimmingCharacters(in: .whitespaces)
        if !language.isEmpty { arguments["language_code"] = .string(language) }
        if let seed { arguments["seed"] = .number(Double(seed)) }
        if !previousText.isEmpty { arguments["previous_text"] = .string(previousText) }
        if !futureText.isEmpty { arguments["future_text"] = .string(futureText) }
        if continueFromLastTake, let lastRequestID { arguments["previous_request_ids"] = [.string(lastRequestID)] }
        let next = nextRequestID.trimmingCharacters(in: .whitespaces)
        if !next.isEmpty { arguments["next_request_ids"] = [.string(next)] }
        if !textNormalization.isEmpty, textNormalization != CreativeSpec.defaultString(operationID, "apply_text_normalization") {
            arguments["apply_text_normalization"] = .string(textNormalization)
        }
        if usePVCAsIVC { arguments["use_pvc_as_ivc"] = true }
        if !enableLogging { arguments["enable_logging"] = false }
        if !dictionaries.isEmpty { arguments["pronunciation_dictionary_locators"] = .array(dictionaries.map(\.json)) }
        return arguments
    }

    // MARK: - Editing the script

    func addLine() {
        // A new line answers the one before: the voice two lines up, if there is one.
        let voice = lines.count >= 2 ? lines[lines.count - 2].voiceID : (lines.last?.voiceID ?? "")
        lines.append(DialogueLine(voiceID: voice, text: ""))
    }

    func removeLine(_ id: DialogueLine.ID) {
        lines.removeAll { $0.id == id }
        if lines.isEmpty { lines.append(DialogueLine(voiceID: "", text: "")) }
    }

    func moveLine(_ id: DialogueLine.ID, by offset: Int) {
        guard let index = lines.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard lines.indices.contains(target) else { return }
        lines.swapAt(index, target)
    }

    /// Replaces the script with pasted text: one line per paragraph, `Name: words` giving the
    /// speaker. A name that matches a voice gets that voice; the same name always gets the
    /// same voice; unnamed lines keep the voice of the line before.
    func importScript(_ script: String) {
        var voiceForName: [String: String] = [:]
        var parsed: [DialogueLine] = []
        for raw in script.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            var name: String?
            var text = line
            if let colon = line.firstIndex(of: ":"), line.distance(from: line.startIndex, to: colon) <= 32 {
                let candidate = line[..<colon].trimmingCharacters(in: .whitespaces)
                if !candidate.isEmpty, !candidate.contains(where: { "[(".contains($0) }) {
                    name = candidate
                    text = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
            }
            let voice: String
            if let name {
                let key = name.lowercased()
                if let known = voiceForName[key] {
                    voice = known
                } else {
                    let match = session.voices.voices.first { $0.name.lowercased() == key }
                        ?? session.voices.voices.first { $0.name.lowercased().hasPrefix(key) }
                    voice = match?.id ?? ""
                    voiceForName[key] = voice
                }
            } else {
                voice = parsed.last?.voiceID ?? ""
            }
            parsed.append(DialogueLine(voiceID: voice, text: text))
        }
        if !parsed.isEmpty { lines = parsed }
    }

    // MARK: - Running

    func generate() async {
        guard busyRunner == nil, problems.isEmpty else { return }
        let runner = runner
        guard CreativeRunGate.isKnown(runner) else { return }
        runner.streamMode = streamMode
        lastRunner = runner
        let sent = lines.indices.filter { !lines[$0].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard let result = await runner.perform(arguments: arguments()) else { return }
        sentLines = sent
        words = CreativeTimeline.words(fromCharacterAlignments: CreativeTimeline.characterAlignments(in: result))
        segments = Self.voiceSegments(in: result)
        let names = lines.compactMap { session.voices.voice(id: $0.voiceID)?.name }
        var seen = Set<String>()
        let cast = names.filter { seen.insert($0).inserted }.joined(separator: ", ")
        if let take = CreativeTake(result: result, title: "Dialogue — \(cast.isEmpty ? "\(lines.count) lines" : cast)", runner: runner) {
            takes.insert(take, at: 0)
        }
    }

    func removeTake(_ take: CreativeTake) {
        takes.removeAll { $0.id == take.id }
    }

    /// `voice_segments` from a with-timestamps answer, or from each chunk of a streamed one.
    static func voiceSegments(in result: ElevenLabsResult) -> [VoiceSegmentTiming] {
        CreativeResults.jsonValues(in: result).flatMap { value in
            (value["voice_segments"].arrayValue ?? []).compactMap { segment -> VoiceSegmentTiming? in
                guard let line = segment["dialogue_input_index"].intValue,
                      let start = segment["start_time_seconds"].doubleValue,
                      let end = segment["end_time_seconds"].doubleValue else { return nil }
                return VoiceSegmentTiming(
                    line: line, voiceID: segment["voice_id"].stringValue ?? "", start: start, end: end
                )
            }
        }
    }
}

struct DialogueScreen: View {
    @Bindable var screen: DialogueScreenModel
    @State private var showsAdvanced = false
    @State private var pasting = false
    @State private var pasted = ""

    var body: some View {
        ElevenLabsSectionPage(.dialogue) {
            scriptCard
            CreativeCard("Model and output", systemImage: "waveform") {
                CreativeModelPicker(
                    title: "Model", selection: $screen.modelID, directory: screen.session.models,
                    include: \.canDoTextToSpeech
                )
                CreativeOutputFormatPicker(selection: $screen.outputFormat, choices: screen.outputFormats)
                Picker("Play", selection: $screen.delivery) {
                    ForEach(SpeechScreenModel.Delivery.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(screen.busyRunner != nil)
                Toggle("Word timings and who speaks when", isOn: $screen.timestamps)
                    .disabled(screen.busyRunner != nil)
            }
            settingsCard
            advanced
            CreativeRunRow(
                runner: screen.activeRunner, title: "Perform dialogue",
                estimatedCharacters: screen.estimatedCharacters, problems: screen.problems,
                note: screen.totalCharacters > DialogueScreenModel.recommendedCharacters
                    ? "Over \(DialogueScreenModel.recommendedCharacters.formatted()) characters in all; ElevenLabs recommends splitting longer scripts."
                    : nil
            ) {
                Task { await screen.generate() }
            }
            result
            CreativeTakesList(takes: Array(screen.takes.dropFirst())) { screen.removeTake($0) }
        }
        .sheet(isPresented: $pasting) { pasteSheet }
    }

    private var scriptCard: some View {
        CreativeCard("Script", systemImage: "text.bubble") {
            Text("\(screen.lines.count) lines · \(screen.distinctVoices) voices · \(screen.totalCharacters.formatted()) characters")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Button("Paste a script…") { pasting = true }.controlSize(.small)
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(screen.lines.enumerated()), id: \.element.id) { index, line in
                    lineRow(index: index, line: line)
                }
                Button {
                    screen.addLine()
                } label: {
                    Label("Add a line", systemImage: "plus")
                }
                .controlSize(.small)
            }
        }
    }

    private func lineRow(index: Int, line: DialogueLine) -> some View {
        let binding = Binding<DialogueLine>(
            get: { screen.lines.first { $0.id == line.id } ?? line },
            set: { new in
                if let position = screen.lines.firstIndex(where: { $0.id == line.id }) { screen.lines[position] = new }
            }
        )
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("\(index + 1)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, alignment: .trailing)
                ElevenLabsVoicePicker(selection: binding.voiceID, title: "Voice", directory: screen.session.voices)
                Spacer(minLength: 4)
                Button { screen.moveLine(line.id, by: -1) } label: { Image(systemName: "arrow.up") }
                    .buttonStyle(.borderless).disabled(index == 0)
                    .accessibilityLabel("Move line \(index + 1) up")
                Button { screen.moveLine(line.id, by: 1) } label: { Image(systemName: "arrow.down") }
                    .buttonStyle(.borderless).disabled(index == screen.lines.count - 1)
                    .accessibilityLabel("Move line \(index + 1) down")
                Button { screen.removeLine(line.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove line \(index + 1)")
            }
            TextField("Line \(index + 1)", text: binding.text, prompt: Text("What they say — audio tags like [laughs] work with v3"), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...6)
                .padding(.leading, 24)
        }
    }

    private var settingsCard: some View {
        CreativeCard("Dialogue settings", systemImage: "slider.horizontal.3") {
            Toggle("Override the voices' saved settings", isOn: $screen.overridesSettings)
            Group {
                CreativeSlider(
                    title: "Stability", value: $screen.stability, range: screen.range("stability"), step: 0.01,
                    defaultValue: CreativeSpec.defaultNumber(DialogueScreenModel.full, "settings.stability"),
                    low: "More expressive", high: "More consistent"
                )
                CreativeSlider(
                    title: "Similarity", value: $screen.similarity, range: screen.range("similarity"), step: 0.01,
                    defaultValue: CreativeSpec.defaultNumber(DialogueScreenModel.full, "settings.similarity"),
                    low: "Looser", high: "Closer to the voices"
                )
            }
            .disabled(!screen.overridesSettings)
            .opacity(screen.overridesSettings ? 1 : 0.55)
        }
    }

    private var advanced: some View {
        CreativeCard {
            DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
                VStack(alignment: .leading, spacing: 12) {
                    LabeledContent("Language") {
                        TextField("Language", text: $screen.languageCode, prompt: Text("Automatic (ISO 639-1)"))
                            .textFieldStyle(.roundedBorder).labelsHidden().frame(maxWidth: 240)
                    }
                    CreativeOptionalIntegerField(title: "Seed", value: $screen.seed, range: CreativeSpec.range(screen.operationID, "seed"))
                    CreativeChoicePicker(
                        title: "Text normalization", selection: $screen.textNormalization,
                        choices: CreativeSpec.choices(screen.operationID, "apply_text_normalization")
                    )
                    Toggle("Continue from the last take", isOn: $screen.continueFromLastTake)
                        .disabled(screen.lastRequestID == nil)
                    TextField("Text before", text: $screen.previousText, prompt: Text("Up to \(CreativeSpec.maxLength(DialogueScreenModel.full, "previous_text") ?? 100) characters that come before"))
                        .textFieldStyle(.roundedBorder)
                    TextField("Text after", text: $screen.futureText, prompt: Text("Up to \(CreativeSpec.maxLength(DialogueScreenModel.full, "future_text") ?? 100) characters that come after"))
                        .textFieldStyle(.roundedBorder)
                    TextField("Next take", text: $screen.nextRequestID, prompt: Text("Request id of a later take this leads into"))
                        .textFieldStyle(.roundedBorder)
                    CreativeDictionaryPicker(locators: $screen.dictionaries, directory: screen.session.dictionaries, maxItems: 3)
                    Toggle("Use professional voices' instant versions", isOn: $screen.usePVCAsIVC)
                    Toggle("Keep in history (off is zero-retention, enterprise only)", isOn: $screen.enableLogging)
                }
                .padding(.top, 8)
            }
        }
    }

    @ViewBuilder
    private var result: some View {
        let runner = screen.lastRunner
        if runner.phase != .idle || screen.takes.first != nil {
            CreativeCard("Result", systemImage: "play.circle") {
                if let take = screen.takes.first {
                    if screen.words.isEmpty {
                        CreativeAudioResult(take: take)
                    } else {
                        CreativeTimedPlayer(url: take.file, words: screen.words, title: take.title, showsSpeakers: false, contentType: take.contentType, outputFormat: take.outputFormat)
                            .id(take.file)
                    }
                    if !screen.segments.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Who speaks when").font(.caption.weight(.semibold))
                            ForEach(Array(screen.segments.enumerated()), id: \.offset) { _, segment in
                                Text("\(CreativeTimeline.clock(segment.start))–\(CreativeTimeline.clock(segment.end))  line \(screen.screenLine(of: segment) + 1) · \(screen.session.voices.voice(id: segment.voiceID)?.name ?? segment.voiceID)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let meta = runner.result?.meta { ElevenLabsMetaLine(meta: meta) }
                }
                ElevenLabsRunnerOutput(runner: runner, showsResult: false)
            }
        }
    }

    private var pasteSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Paste a script").font(.title3.weight(.semibold))
            Text("One line per paragraph. Start a line with a name and a colon — “Rachel: Hello there” — and a voice with that name is chosen; the same name keeps the same voice.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ElevenLabsTextArea(text: $pasted, prompt: "Rachel: Hello there.\nAdam: Hi! [laughs]", minHeight: 200)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { pasting = false }
                    .keyboardShortcut(.cancelAction)
                Button("Replace the script") {
                    screen.importScript(pasted)
                    pasted = ""
                    pasting = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
