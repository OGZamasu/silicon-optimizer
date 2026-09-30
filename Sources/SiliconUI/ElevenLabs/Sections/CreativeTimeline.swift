import Foundation
import SiliconElevenLabs

/// A word and when it is heard: from a speech answer's character alignment, a transcript, or
/// a forced alignment.
struct CreativeTimedWord: Hashable, Sendable {
    var text: String
    var start: Double
    var end: Double
    /// `speaker_0`, `agent`… from diarization, or a channel.
    var speaker: String?
    /// A non-speech sound the transcript tagged, like "(laughter)".
    var isEvent = false
    /// How confident a forced alignment was (lower is better); nil elsewhere.
    var loss: Double?
}

/// Words grouped into lines to read or subtitle: one speaker, no long pause inside.
struct CreativeSegment: Identifiable, Hashable, Sendable {
    var id: Int
    var start: Double
    var end: Double
    var speaker: String?
    var words: [CreativeTimedWord]

    var text: String { CreativeTimeline.join(words.map(\.text)) }
}

/// Reading timings out of ElevenLabs answers and writing them back out as subtitles.
enum CreativeTimeline {

    // MARK: - Reading

    /// Words from one or more character alignments (`characters`,
    /// `character_start_times_seconds`, `character_end_times_seconds`), in order. A streamed
    /// answer sends one per chunk; when a chunk's times start over from zero, they are moved
    /// to follow the chunk before.
    static func words(fromCharacterAlignments alignments: [JSONValue]) -> [CreativeTimedWord] {
        var characters: [(text: String, start: Double, end: Double)] = []
        for alignment in alignments {
            let texts = (alignment["characters"].arrayValue ?? []).map { $0.stringValue ?? "" }
            let starts = (alignment["character_start_times_seconds"].arrayValue ?? []).compactMap(\.doubleValue)
            let ends = (alignment["character_end_times_seconds"].arrayValue ?? []).compactMap(\.doubleValue)
            let count = min(texts.count, starts.count, ends.count)
            guard count > 0 else { continue }
            let previousEnd = characters.last?.end ?? 0
            let offset = !characters.isEmpty && starts[0] + 0.001 < previousEnd ? previousEnd : 0
            for index in 0..<count {
                characters.append((texts[index], starts[index] + offset, ends[index] + offset))
            }
        }
        var words: [CreativeTimedWord] = []
        var current: CreativeTimedWord?
        for character in characters {
            if character.text.allSatisfy(\.isWhitespace) {
                if let word = current { words.append(word) }
                current = nil
                continue
            }
            if current == nil {
                current = CreativeTimedWord(text: character.text, start: character.start, end: character.end)
            } else {
                current?.text += character.text
                current?.end = character.end
            }
        }
        if let word = current { words.append(word) }
        return words
    }

    /// The character alignments inside an answer: the JSON of a with-timestamps call, or each
    /// chunk of a streamed one. `normalized_alignment` is used only where `alignment` is absent.
    static func characterAlignments(in result: ElevenLabsResult) -> [JSONValue] {
        CreativeResults.jsonValues(in: result).compactMap { value in
            for key in ["alignment", "normalized_alignment"] where value[key]["characters"] != .null {
                return value[key]
            }
            return nil
        }
    }

    /// The words of a transcript (`SpeechToTextChunkResponseModel`, or a multichannel answer's
    /// `transcripts`), spacing left out, audio events kept and marked, sorted by time.
    static func words(fromTranscript transcript: JSONValue) -> [CreativeTimedWord] {
        let chunks = transcript["transcripts"].arrayValue ?? [transcript]
        let multichannel = chunks.count > 1
        var words: [CreativeTimedWord] = []
        for chunk in chunks {
            let channel = chunk["channel_index"].intValue
            for word in chunk["words"].arrayValue ?? [] {
                let type = word["type"].stringValue ?? "word"
                guard type != "spacing", let text = word["text"].stringValue, !text.isEmpty else { continue }
                let speaker = word["speaker_id"].stringValue
                    ?? (multichannel ? channel.map { "channel_\($0)" } : nil)
                words.append(CreativeTimedWord(
                    text: text, start: word["start"].doubleValue ?? words.last?.end ?? 0,
                    end: word["end"].doubleValue ?? word["start"].doubleValue ?? words.last?.end ?? 0,
                    speaker: speaker, isEvent: type == "audio_event"
                ))
            }
        }
        return multichannel ? words.sorted { $0.start < $1.start } : words
    }

    /// The words of a forced alignment (`ForcedAlignmentResponseModel`), each with its loss.
    static func words(fromForcedAlignment alignment: JSONValue) -> [CreativeTimedWord] {
        (alignment["words"].arrayValue ?? []).compactMap { word in
            guard let text = word["text"].stringValue, !text.allSatisfy(\.isWhitespace) else { return nil }
            return CreativeTimedWord(
                text: text, start: word["start"].doubleValue ?? 0, end: word["end"].doubleValue ?? 0,
                loss: word["loss"].doubleValue
            )
        }
    }

    // MARK: - Grouping

    /// Words grouped into segments: a new one at every change of speaker, at a pause longer
    /// than `maxGap`, after a sentence once a segment has a few words, and past `maxWords` or
    /// `maxDuration` — short enough to read as a subtitle.
    static func segments(
        _ words: [CreativeTimedWord], maxGap: Double = 1.0, maxWords: Int = 18, maxDuration: Double = 7
    ) -> [CreativeSegment] {
        var segments: [CreativeSegment] = []
        var current: [CreativeTimedWord] = []
        func close() {
            guard let first = current.first, let last = current.last else { return }
            segments.append(CreativeSegment(
                id: segments.count, start: first.start, end: last.end, speaker: first.speaker, words: current
            ))
            current = []
        }
        for word in words {
            if let last = current.last, let first = current.first {
                let sentenceEnded = last.text.last.map { ".!?…".contains($0) } ?? false
                if word.speaker != first.speaker || word.start - last.end > maxGap
                    || current.count >= maxWords || word.end - first.start > maxDuration
                    || (sentenceEnded && current.count >= 4) {
                    close()
                }
            }
            current.append(word)
        }
        close()
        return segments
    }

    /// The index of the word being heard at `time`, if any.
    static func wordIndex(at time: Double, in words: [CreativeTimedWord]) -> Int? {
        guard !words.isEmpty else { return nil }
        var low = 0, high = words.count - 1
        while low <= high {
            let middle = (low + high) / 2
            if words[middle].end < time { low = middle + 1 }
            else if words[middle].start > time { high = middle - 1 }
            else { return middle }
        }
        return nil
    }

    /// Words joined as text, with no space before punctuation.
    static func join(_ texts: [String]) -> String {
        var result = ""
        for text in texts {
            if !result.isEmpty, let first = text.first, !",.;:!?…)”’".contains(first) {
                result += " "
            }
            result += text
        }
        return result
    }

    // MARK: - Writing

    /// SubRip subtitles.
    static func srt(_ segments: [CreativeSegment], speakers: Bool = true) -> String {
        segments.enumerated().map { index, segment in
            "\(index + 1)\n\(timestamp(segment.start, separator: ",")) --> \(timestamp(segment.end, separator: ","))\n"
                + line(segment, speakers: speakers)
        }.joined(separator: "\n\n") + (segments.isEmpty ? "" : "\n")
    }

    /// WebVTT subtitles.
    static func vtt(_ segments: [CreativeSegment], speakers: Bool = true) -> String {
        "WEBVTT\n\n" + segments.map { segment in
            "\(timestamp(segment.start, separator: ".")) --> \(timestamp(segment.end, separator: "."))\n"
                + (speakers && segment.speaker != nil
                   ? "<v \(speakerName(segment.speaker))>\(segment.text)" : segment.text)
        }.joined(separator: "\n\n") + (segments.isEmpty ? "" : "\n")
    }

    /// Plain text, a paragraph per segment, speaker names when there are several speakers.
    static func plainText(_ segments: [CreativeSegment], speakers: Bool = true) -> String {
        segments.map { line($0, speakers: speakers) }.joined(separator: "\n")
    }

    /// The words and their times as JSON.
    static func json(_ words: [CreativeTimedWord]) -> JSONValue {
        .array(words.map { word in
            var object: [String: JSONValue] = [
                "text": .string(word.text), "start": .number(word.start), "end": .number(word.end),
            ]
            if let speaker = word.speaker { object["speaker"] = .string(speaker) }
            if word.isEvent { object["event"] = true }
            if let loss = word.loss { object["loss"] = .number(loss) }
            return .object(object)
        })
    }

    private static func line(_ segment: CreativeSegment, speakers: Bool) -> String {
        guard speakers, segment.speaker != nil else { return segment.text }
        return "\(speakerName(segment.speaker)): \(segment.text)"
    }

    /// `speaker_0` → "Speaker 1", `channel_1` → "Channel 2", `agent` → "Agent".
    static func speakerName(_ id: String?) -> String {
        guard let id, !id.isEmpty else { return "Speaker" }
        for (prefix, title) in [("speaker_", "Speaker"), ("channel_", "Channel")] where id.hasPrefix(prefix) {
            if let number = Int(id.dropFirst(prefix.count)) { return "\(title) \(number + 1)" }
        }
        return ElevenLabsFormField.humanized(id)
    }

    /// `01:02:03,450` (SRT) or `01:02:03.450` (VTT).
    static func timestamp(_ seconds: Double, separator: String) -> String {
        let total = max(0, Int((seconds * 1000).rounded()))
        let hours = total / 3_600_000
        let minutes = total / 60_000 % 60
        let secs = total / 1000 % 60
        let millis = total % 1000
        return String(format: "%02d:%02d:%02d%@%03d", hours, minutes, secs, separator, millis)
    }

    /// `1:05.2`, for a time shown beside a line.
    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let tenths = Int((seconds * 10).rounded(.down))
        return String(format: "%d:%02d.%d", tenths / 600, tenths / 10 % 60, tenths % 10)
    }
}

/// Reading the pieces of an `ElevenLabsResult` the creative screens care about.
enum CreativeResults {
    /// Every JSON value in the answer: the body, each event, each JSON part.
    static func jsonValues(in result: ElevenLabsResult) -> [JSONValue] {
        switch result {
        case .json(let value, _): [value]
        case .events(let events, _): events
        case .parts(let parts, _): parts.compactMap { if case .json(let value) = $0 { value } else { nil } }
        case .file, .text: []
        }
    }

    /// The first JSON value in the answer.
    static func json(in result: ElevenLabsResult?) -> JSONValue? {
        result.flatMap { jsonValues(in: $0).first }
    }

    /// The first audio (or other media) file the answer wrote.
    static func audioFile(in result: ElevenLabsResult?) -> (url: URL, contentType: String, bytes: Int)? {
        guard let result else { return nil }
        switch result {
        case .file(let url, let type, let bytes, _):
            return (url, type, bytes)
        case .parts(let parts, _):
            for part in parts {
                if case .file(let url, let type, let bytes) = part { return (url, type, bytes) }
            }
            return nil
        case .json, .text, .events:
            return nil
        }
    }

    /// Every file the answer wrote, with its type.
    static func files(in result: ElevenLabsResult?) -> [(url: URL, contentType: String, bytes: Int)] {
        guard let result else { return [] }
        switch result {
        case .file(let url, let type, let bytes, _): return [(url, type, bytes)]
        case .parts(let parts, _):
            return parts.compactMap { if case .file(let url, let type, let bytes) = $0 { (url, type, bytes) } else { nil } }
        case .json, .text, .events: return []
        }
    }

    /// The request id ElevenLabs gave the answer: what `previous_request_ids` refers to.
    static func requestID(of result: ElevenLabsResult?) -> String? {
        guard let meta = result?.meta else { return nil }
        return meta.requestID ?? meta.headers["request-id"] ?? meta.headers["x-request-id"]
    }
}
