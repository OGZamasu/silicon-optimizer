import Foundation

// Tolerant reading of what the servers send. The sources disagree on spellings — `isFinal` and
// `is_final`, `contextId` and `context_id`, `charStartTimesMs` and `char_start_times_ms`, an
// `event_id` that is a number or a numeric string — so every read here accepts each spelling
// any source uses, and nothing fails on a field it does not know.

extension JSONValue {
    /// The first of `keys` that is present and not null.
    func first(_ keys: String...) -> JSONValue {
        for key in keys where self[key] != .null { return self[key] }
        return .null
    }

    /// A whole number, or a string holding one — how the SDKs read `event_id`.
    var looseInt: Int? {
        if let int = intValue { return int }
        if let text = stringValue?.trimmingCharacters(in: .whitespaces), let int = Int(text) { return int }
        return nil
    }

    /// `true` or `false`, from a bool or the strings "true"/"false".
    var looseBool: Bool? {
        if let bool = boolValue { return bool }
        switch stringValue?.lowercased() {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    var looseDouble: Double? {
        if let double = doubleValue { return double }
        return stringValue.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    }
}

/// Character timings for a piece of audio, relative to the start of that piece.
public struct ElevenLabsAlignment: Sendable, Equatable, Hashable {
    public var characters: [String]
    public var startTimesMs: [Int]
    public var durationsMs: [Int]

    public init(characters: [String], startTimesMs: [Int], durationsMs: [Int]) {
        self.characters = characters
        self.startTimesMs = startTimesMs
        self.durationsMs = durationsMs
    }

    /// Either spelling of the keys (camelCase from the schema, snake_case from the example
    /// frames and the agent socket). Nil when there is nothing usable; the three lists are cut
    /// to the shortest, so a mismatched answer never indexes past an end.
    public init?(json: JSONValue) {
        guard json.objectValue != nil else { return nil }
        let characters = (json.first("chars", "characters").arrayValue ?? []).compactMap(\.stringValue)
        let starts = (json.first("charStartTimesMs", "char_start_times_ms").arrayValue ?? []).compactMap(\.looseDouble)
        let durations = (json.first("charDurationsMs", "char_durations_ms").arrayValue ?? []).compactMap(\.looseDouble)
        let count = min(characters.count, starts.count, durations.count)
        guard count > 0 else { return nil }
        self.characters = Array(characters.prefix(count))
        startTimesMs = starts.prefix(count).map { Int($0.rounded()) }
        durationsMs = durations.prefix(count).map { Int($0.rounded()) }
    }

    public var text: String { characters.joined() }

    /// The same timings moved later by `offsetMs` — to lay chunk-relative timings on one clock.
    public func shifted(by offsetMs: Int) -> ElevenLabsAlignment {
        ElevenLabsAlignment(
            characters: characters, startTimesMs: startTimesMs.map { $0 + offsetMs }, durationsMs: durationsMs
        )
    }

    /// Words with the time each starts and ends, for display.
    public var words: [(word: String, startMs: Int, endMs: Int)] {
        var result: [(String, Int, Int)] = []
        var current = ""
        var start = 0
        var end = 0
        for index in characters.indices {
            let character = characters[index]
            if character.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if !current.isEmpty { result.append((current, start, end)) }
                current = ""
                continue
            }
            if current.isEmpty { start = startTimesMs[index] }
            current += character
            end = startTimesMs[index] + durationsMs[index]
        }
        if !current.isEmpty { result.append((current, start, end)) }
        return result
    }
}

/// Audio as the servers encode it: the name, and what it takes to play or send it.
public enum ElevenLabsAudioEncoding: Sendable, Hashable, CustomStringConvertible {
    /// Signed 16-bit little-endian mono at `rate` Hz.
    case pcm(rate: Int)
    /// 8-bit G.711 μ-law mono at 8 kHz.
    case ulaw
    /// MP3 at the given rate and bitrate, as `mp3_<rate>_<kbps>`.
    case mp3(rate: Int, kbps: Int)
    /// Opus in the given container, as `opus_<rate>_<kbps>`.
    case opus(rate: Int, kbps: Int)
    /// 8-bit G.711 A-law mono at 8 kHz.
    case alaw

    /// `pcm_16000`, `ulaw_8000`, `mp3_44100_128`… Nil for anything else.
    public init?(name: String) {
        let parts = name.lowercased().split(separator: "_").map(String.init)
        switch parts.first {
        case "pcm" where parts.count == 2:
            guard let rate = Int(parts[1]), rate > 0 else { return nil }
            self = .pcm(rate: rate)
        case "ulaw" where parts == ["ulaw", "8000"]:
            self = .ulaw
        case "alaw" where parts == ["alaw", "8000"]:
            self = .alaw
        case "mp3" where parts.count == 3:
            guard let rate = Int(parts[1]), let kbps = Int(parts[2]), rate > 0, kbps > 0 else { return nil }
            self = .mp3(rate: rate, kbps: kbps)
        case "opus" where parts.count == 3:
            guard let rate = Int(parts[1]), let kbps = Int(parts[2]), rate > 0, kbps > 0 else { return nil }
            self = .opus(rate: rate, kbps: kbps)
        default:
            return nil
        }
    }

    public var name: String {
        switch self {
        case .pcm(let rate): "pcm_\(rate)"
        case .ulaw: "ulaw_8000"
        case .alaw: "alaw_8000"
        case .mp3(let rate, let kbps): "mp3_\(rate)_\(kbps)"
        case .opus(let rate, let kbps): "opus_\(rate)_\(kbps)"
        }
    }

    public var description: String { name }

    public var sampleRate: Int {
        switch self {
        case .pcm(let rate): rate
        case .ulaw, .alaw: 8_000
        case .mp3(let rate, _), .opus(let rate, _): rate
        }
    }

    /// Bytes per second of audio, for the headerless encodings; nil for compressed ones.
    public var bytesPerSecond: Int? {
        switch self {
        case .pcm(let rate): rate * 2
        case .ulaw, .alaw: 8_000
        case .mp3, .opus: nil
        }
    }

    /// Seconds of audio in `bytes`, when the encoding says (headerless audio only).
    public func seconds(inBytes bytes: Int) -> Double? {
        bytesPerSecond.map { Double(bytes) / Double($0) }
    }
}

extension Data {
    /// Base64 that may have lost its padding or gained line breaks in transit.
    init?(looseBase64 text: String) {
        if let data = Data(base64Encoded: text) {
            self = data
            return
        }
        var cleaned = text.filter { !$0.isWhitespace }
        while cleaned.count % 4 != 0 { cleaned += "=" }
        guard let data = Data(base64Encoded: cleaned) else { return nil }
        self = data
    }
}
