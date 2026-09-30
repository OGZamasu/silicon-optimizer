import Foundation
import Observation
import SiliconElevenLabs
import SwiftUI

/// Forced alignment: a recording and its exact words in, the time of every word and character
/// out — to follow along, check, and export as subtitles.
struct AlignmentSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        AlignmentScreen(screen: CreativeSession.shared(for: model).alignment)
    }
}

@MainActor
@Observable
final class AlignmentScreenModel: CreativeScreenModel {

    static let align = "forced_alignment"
    static let operationIDs = [align]

    static let controls: [CreativeControl] = [
        CreativeControl("Recording", operationIDs, "file"),
        CreativeControl("Transcript", operationIDs, "text"),
    ]

    let session: CreativeSession
    let runner: ElevenLabsRunner
    var source: URL?
    var text = ""

    private(set) var words: [CreativeTimedWord] = []
    private(set) var characterCount = 0
    /// The alignment's overall loss: lower means the words fit the audio better.
    private(set) var loss: Double?
    /// The recording the words on screen were aligned to.
    private(set) var alignedAudio: URL?

    init(session: CreativeSession) {
        self.session = session
        runner = session.runner(Self.align, title: "Forced alignment")
    }

    var problems: [String] {
        var problems: [String] = []
        if source == nil { problems.append("Choose the recording.") }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { problems.append("Paste what is said in it.") }
        return problems
    }

    func arguments() -> [String: JSONValue] {
        ["text": .string(text)]
    }

    func files() -> [String: [ElevenLabsFile]] {
        source.map { ["file": [ElevenLabsFile(url: $0)]] } ?? [:]
    }

    func align() async {
        guard problems.isEmpty, CreativeRunGate.isKnown(runner) else { return }
        let audio = source
        guard case .json(let value, _)? = await runner.perform(arguments: arguments(), files: files()) else { return }
        show(value, audio: audio)
    }

    func show(_ value: JSONValue, audio: URL?) {
        words = CreativeTimeline.words(fromForcedAlignment: value)
        characterCount = value["characters"].arrayValue?.count ?? 0
        loss = value["loss"].doubleValue
        alignedAudio = audio
    }

    /// The words that fit worst, for a second look: the highest loss first.
    var weakestWords: [CreativeTimedWord] {
        Array(words.filter { $0.loss != nil }.sorted { ($0.loss ?? 0) > ($1.loss ?? 0) }.prefix(5))
    }

    /// Takes the text of the transcript on the Transcription screen.
    func useTranscriptionText() {
        let text = session.transcription.fullText
        if !text.isEmpty { self.text = text }
        if source == nil, let audio = session.transcription.transcriptAudio { source = audio }
    }
}

struct AlignmentScreen: View {
    @Bindable var screen: AlignmentScreenModel

    var body: some View {
        ElevenLabsSectionPage(.alignment) {
            CreativeCard("Recording", systemImage: "waveform") {
                CreativeFileField(title: "Audio or video", url: $screen.source)
            }
            CreativeCard("What is said", systemImage: "text.alignleft") {
                Button("Use the transcript") { screen.useTranscriptionText() }
                    .controlSize(.small)
                    .disabled(screen.session.transcription.fullText.isEmpty)
                    .help("Take the text of the transcript open under Transcription")
            } content: {
                ElevenLabsTextArea(text: $screen.text, prompt: "The exact words spoken in the recording", minHeight: 120)
            }
            CreativeRunRow(
                runner: screen.runner, title: "Align",
                estimatedSeconds: screen.source.flatMap(CreativeMedia.duration(of:)), problems: screen.problems
            ) {
                Task { await screen.align() }
            }
            ElevenLabsRunnerOutput(runner: screen.runner, showsResult: false)
            if !screen.words.isEmpty {
                CreativeCard("Timings", systemImage: "text.alignleft") {
                    Menu("Export") {
                        let segments = CreativeTimeline.segments(screen.words)
                        Button("SRT subtitles…") { CreativeExport.save(CreativeTimeline.srt(segments, speakers: false), suggestedName: "alignment.srt", type: CreativeExport.srtType) }
                        Button("WebVTT subtitles…") { CreativeExport.save(CreativeTimeline.vtt(segments, speakers: false), suggestedName: "alignment.vtt", type: CreativeExport.vttType) }
                        Button("Words as JSON…") { CreativeExport.save(CreativeTimeline.json(screen.words).jsonString(pretty: true), suggestedName: "alignment.json", type: .json) }
                    }
                    .fixedSize()
                } content: {
                    HStack(spacing: 12) {
                        Text("\(screen.words.count.formatted()) words")
                        Text("\(screen.characterCount.formatted()) characters")
                        if let loss = screen.loss { Text(String(format: "Loss %.3f", loss)).help("Lower means the words fit the audio better") }
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    if let audio = screen.alignedAudio, CreativeMedia.isAudio(audio) {
                        CreativeTimedPlayer(url: audio, words: screen.words, showsSpeakers: false).id(audio)
                    } else {
                        CreativeTranscriptView(segments: CreativeTimeline.segments(screen.words), showsSpeakers: false)
                    }
                    if !screen.weakestWords.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Worst fits").font(.caption.weight(.semibold))
                            ForEach(Array(screen.weakestWords.enumerated()), id: \.offset) { _, word in
                                Text("“\(word.text)” at \(CreativeTimeline.clock(word.start)) — loss \(String(format: "%.3f", word.loss ?? 0))")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }
}
