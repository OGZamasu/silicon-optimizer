import Foundation

// Byte-level formats: multipart bodies going out, multipart/mixed and streamed JSON and SSE
// coming back. Nothing here knows about keys, hosts or operations.

// MARK: - multipart/form-data

enum MultipartWriter {
    /// Writes `parts` as a `multipart/form-data` body into `file`, copying each upload from disk
    /// a megabyte at a time. Returns the Content-Type header value, boundary included.
    static func write(_ parts: [MultipartPart], to file: URL) throws -> String {
        let boundary = "SiliconOptimizer-\(UUID().uuidString)"
        guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
            throw ElevenLabsError.network("could not create a temporary upload file")
        }
        let output = try FileHandle(forWritingTo: file)
        defer { try? output.close() }
        func emit(_ text: String) throws { try output.write(contentsOf: Data(text.utf8)) }

        for part in parts {
            try emit("--\(boundary)\r\n")
            switch part.value {
            case .text(let text):
                try emit("Content-Disposition: form-data; name=\"\(quoted(part.name))\"\r\n\r\n")
                try emit(text)
            case .file(let upload, _):
                try emit("Content-Disposition: form-data; name=\"\(quoted(part.name))\"; filename=\"\(quoted(upload.filename))\"\r\n")
                try emit("Content-Type: \(upload.contentType.filter { !$0.isNewline })\r\n\r\n")
                let input = try FileHandle(forReadingFrom: upload.url)
                defer { try? input.close() }
                while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                    try Task.checkCancellation()
                    try output.write(contentsOf: chunk)
                }
            }
            try emit("\r\n")
        }
        try emit("--\(boundary)--\r\n")
        return "multipart/form-data; boundary=\(boundary)"
    }

    /// A header parameter value: quotes and line breaks cannot end it early.
    static func quoted(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "%22")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }
}

// MARK: - multipart/mixed

/// Splits a `multipart/mixed` answer (music `compose_detailed`: a JSON part and an audio part).
enum MultipartMixed {
    struct Part {
        var headers: [String: String]
        var body: Data
        var contentType: String { headers["content-type"] ?? "application/octet-stream" }
        var filename: String? {
            guard let disposition = headers["content-disposition"],
                  let range = disposition.range(of: "filename=") else { return nil }
            return disposition[range.upperBound...]
                .split(separator: ";").first
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) }
        }
    }

    static func boundary(fromContentType contentType: String?) -> String? {
        guard let contentType else { return nil }
        for parameter in contentType.split(separator: ";").dropFirst() {
            let pair = parameter.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if pair.count == 2, pair[0].lowercased() == "boundary" {
                return pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return nil
    }

    /// The parts of `data` (memory-mapped by the caller, so a large song is paged in rather
    /// than copied). Tolerates LF as well as CRLF line ends.
    static func split(_ data: Data, boundary: String) -> [Part] {
        let delimiter = Data("--\(boundary)".utf8)
        var parts: [Part] = []
        var searchStart = data.startIndex
        guard var current = data.range(of: delimiter, in: searchStart..<data.endIndex) else { return [] }
        while true {
            var start = current.upperBound
            // `--boundary--` closes the body.
            if data[start...].starts(with: Data("--".utf8)) { break }
            start = skipLineEnd(data, from: start)
            searchStart = start
            guard let next = data.range(of: delimiter, in: searchStart..<data.endIndex) else { break }
            var end = next.lowerBound
            // The line end before the delimiter belongs to the delimiter.
            if end > start, data[end - 1] == 0x0A { end -= 1 }
            if end > start, data[end - 1] == 0x0D { end -= 1 }
            let chunk = data[start..<end]
            if let split = headerEnd(chunk) {
                let headerText = String(decoding: chunk[chunk.startIndex..<split.lowerBound], as: UTF8.self)
                var headers: [String: String] = [:]
                for line in headerText.split(whereSeparator: \.isNewline) {
                    let pair = line.split(separator: ":", maxSplits: 1)
                    if pair.count == 2 {
                        headers[pair[0].trimmingCharacters(in: .whitespaces).lowercased()] =
                            pair[1].trimmingCharacters(in: .whitespaces)
                    }
                }
                parts.append(Part(headers: headers, body: Data(chunk[split.upperBound...])))
            }
            current = next
        }
        return parts
    }

    private static func skipLineEnd(_ data: Data, from index: Data.Index) -> Data.Index {
        var index = index
        if index < data.endIndex, data[index] == 0x0D { index += 1 }
        if index < data.endIndex, data[index] == 0x0A { index += 1 }
        return index
    }

    private static func headerEnd(_ chunk: Data) -> Range<Data.Index>? {
        chunk.range(of: Data("\r\n\r\n".utf8)) ?? chunk.range(of: Data("\n\n".utf8))
    }
}

// MARK: - Server-sent events

/// Incremental `text/event-stream` parser: feed bytes as they arrive, take whole events out.
struct ServerSentEventParser {
    struct Event: Equatable {
        var name: String?
        var data: String
        var id: String?
    }

    private var buffer = Data()
    private var name: String?
    private var id: String?
    private var dataLines: [String] = []

    mutating func feed(_ bytes: Data) -> [Event] {
        buffer.append(bytes)
        var events: [Event] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var line = buffer[buffer.startIndex..<newline]
            if line.last == 0x0D { line = line.dropLast() }
            buffer = Data(buffer[(newline + 1)...])
            if let event = consume(String(decoding: line, as: UTF8.self)) { events.append(event) }
        }
        return events
    }

    /// Whatever is left when the stream ends.
    mutating func finish() -> [Event] {
        var events: [Event] = []
        if !buffer.isEmpty {
            if let event = consume(String(decoding: buffer, as: UTF8.self)) { events.append(event) }
            buffer = Data()
        }
        if let event = consume("") { events.append(event) }
        return events
    }

    private mutating func consume(_ line: String) -> Event? {
        if line.isEmpty {
            defer { name = nil; dataLines = [] }
            guard !dataLines.isEmpty else { return nil }
            return Event(name: name, data: dataLines.joined(separator: "\n"), id: id)
        }
        if line.hasPrefix(":") { return nil }
        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[line.startIndex..<colon]
            value = line[line.index(after: colon)...]
            if value.first == " " { value = value.dropFirst() }
        } else {
            field = Substring(line)
            value = ""
        }
        switch field {
        case "event": name = String(value)
        case "data": dataLines.append(String(value))
        case "id": id = String(value)
        default: break
        }
        return nil
    }
}

// MARK: - Streamed JSON

/// Incremental parser for a body of JSON values one after another — newline-delimited or
/// simply concatenated — as the `…/stream/with-timestamps` variants send.
struct JSONStreamParser {
    private var buffer = Data()
    private var depth = 0
    private var inString = false
    private var escaped = false
    private var start: Int?
    private var scanned = 0

    mutating func feed(_ bytes: Data) -> [JSONValue] {
        buffer.append(bytes)
        var values: [JSONValue] = []
        var consumedUpTo = 0
        let bytes = [UInt8](buffer)
        var index = scanned
        while index < bytes.count {
            let byte = bytes[index]
            if inString {
                if escaped { escaped = false }
                else if byte == 0x5C { escaped = true }
                else if byte == 0x22 { inString = false }
            } else {
                switch byte {
                case 0x22: inString = true
                case 0x7B, 0x5B:
                    if depth == 0 { start = index }
                    depth += 1
                case 0x7D, 0x5D:
                    depth -= 1
                    if depth == 0, let begin = start {
                        if let value = try? JSONValue.parse(Data(bytes[begin...index])) {
                            values.append(value)
                        }
                        start = nil
                        consumedUpTo = index + 1
                    }
                default: break
                }
            }
            index += 1
        }
        if depth == 0 { consumedUpTo = bytes.count }
        buffer = Data(bytes[consumedUpTo...])
        scanned = index - consumedUpTo
        if let begin = start { start = begin - consumedUpTo }
        return values
    }
}

// MARK: - Audio carried as base64

enum Base64Audio {
    /// Field names that carry base64 audio in ElevenLabs answers.
    static let fieldNames: Set<String> = ["audio_base64", "audio_base_64", "audio_base64_chunk"]

    /// Takes base64 audio out of `value`: returns the value with each such field replaced by
    /// `<field>_bytes` (its decoded length), and the decoded audio in document order.
    static func extract(from value: JSONValue, eventName: String? = nil) -> (JSONValue, [Data]) {
        var found: [Data] = []
        let cleaned = strip(value, eventIsAudio: eventName?.contains("audio") == true, depth: 0, into: &found)
        return (cleaned, found)
    }

    private static func strip(
        _ value: JSONValue, eventIsAudio: Bool, depth: Int, into found: inout [Data]
    ) -> JSONValue {
        guard depth < 6 else { return value }
        switch value {
        case .object(let object):
            var result: [String: JSONValue] = [:]
            for key in object.keys.sorted() {
                let inner = object[key]!
                if case .string(let text) = inner,
                   fieldNames.contains(key) || (eventIsAudio && key.contains("audio") && text.count > 64),
                   let audio = Data(base64Encoded: text, options: .ignoreUnknownCharacters) {
                    found.append(audio)
                    result["\(key)_bytes"] = .number(Double(audio.count))
                } else {
                    result[key] = strip(inner, eventIsAudio: eventIsAudio, depth: depth + 1, into: &found)
                }
            }
            return .object(result)
        case .array(let array):
            return .array(array.map { strip($0, eventIsAudio: eventIsAudio, depth: depth + 1, into: &found) })
        case .null, .bool, .number, .string:
            return value
        }
    }
}

// MARK: - File types

enum ElevenLabsFileTypes {
    /// An extension for a content type, falling back to the operation's `output_format`
    /// argument (`mp3_44100_128`, `pcm_16000`, `opus_48000_32`, `wav_…`, `ulaw_8000`…).
    static func fileExtension(contentType: String?, outputFormat: String?) -> String {
        let type = (contentType ?? "").split(separator: ";").first.map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        } ?? ""
        switch type {
        case "audio/mpeg", "audio/mp3": return "mp3"
        case "audio/wav", "audio/x-wav", "audio/wave": return "wav"
        case "audio/ogg", "audio/opus": return "opus"
        case "audio/flac": return "flac"
        case "audio/mp4", "audio/aac", "audio/x-m4a": return "m4a"
        case "audio/basic", "audio/x-mulaw", "audio/ulaw": return "ulaw"
        case "audio/pcm", "audio/l16": return "pcm"
        case "video/mp4": return "mp4"
        case "application/zip", "application/x-zip", "application/x-zip-compressed": return "zip"
        case "text/csv": return "csv"
        case "text/plain": return "txt"
        case "text/html": return "html"
        case "application/json": return "json"
        case "application/pls+xml": return "pls"
        case "image/png": return "png"
        case "image/jpeg": return "jpg"
        default: break
        }
        if let format = outputFormat?.lowercased() {
            for (prefix, ext) in [("mp3", "mp3"), ("pcm", "pcm"), ("opus", "opus"), ("wav", "wav"),
                                  ("ulaw", "ulaw"), ("alaw", "alaw"), ("flac", "flac")]
            where format.hasPrefix(prefix) {
                return ext
            }
        }
        if type.hasPrefix("audio/") { return "mp3" }
        return "bin"
    }
}
