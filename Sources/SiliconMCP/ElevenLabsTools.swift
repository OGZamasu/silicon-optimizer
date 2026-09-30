import Foundation
import SiliconControl

/// What the ElevenLabs tools need from the control API: a GET and a POST that answer JSON.
/// `ControlClient` in the bridge; a fake under test. This process never holds the key — it only
/// ever talks to the app, and the app answers with credentials masked.
protocol ElevenLabsChannel: Sendable {
    func elevenLabsGet(_ path: String) async throws -> JSONValue
    func elevenLabsPost(_ path: String, _ body: JSONValue) async throws -> JSONValue
}

extension ControlClient: ElevenLabsChannel {
    func elevenLabsGet(_ path: String) async throws -> JSONValue { try await get(path) }

    func elevenLabsPost(_ path: String, _ body: JSONValue) async throws -> JSONValue {
        try await post(path, body)
    }
}

/// The ElevenLabs tools: eleven for the common jobs, and three — search, describe, call — that
/// reach every operation the API has. One tool per operation would be four hundred tools.
///
/// Every tool goes through `POST /elevenlabs/call` (or the two catalog GETs), so the app's
/// risk gate and redaction apply to all of them the same way. Argument names are the spec's.
enum ElevenLabsTools {

    // MARK: - Arguments

    /// One argument of a curated tool.
    struct Argument: Sendable {
        enum Kind: Sendable {
            case string
            case number(ClosedRange<Double>?)
            case integer(ClosedRange<Double>?)
            case boolean
            case object
            /// An object, or the same thing already written as a JSON string.
            case objectOrString
            /// An absolute path on this Mac, uploaded in the multipart field of the same name.
            case path
            /// Several, in one multipart field that takes a list of files.
            case paths
        }

        var name: String
        var kind: Kind
        var required = false
        var choices: [String]? = nil
        var description: String

        var schema: JSONValue {
            var object: [String: JSONValue] = ["description": .string(description)]
            switch kind {
            case .string, .path:
                object["type"] = "string"
            case .number(let range), .integer(let range):
                if case .integer = kind { object["type"] = "integer" } else { object["type"] = "number" }
                if let range {
                    object["minimum"] = .number(range.lowerBound)
                    object["maximum"] = .number(range.upperBound)
                }
            case .boolean:
                object["type"] = "boolean"
            case .object:
                object["type"] = "object"
            case .objectOrString:
                object["type"] = .array(["object", "string"])
            case .paths:
                object["type"] = "array"
                object["items"] = ["type": "string"]
                object["minItems"] = 1
            }
            if let choices { object["enum"] = .array(choices.map(JSONValue.string)) }
            return .object(object)
        }
    }

    /// A curated tool: the operation it calls, its arguments, and how its answer reads.
    struct Curated: Sendable {
        var name: String
        var operation: String
        var description: String
        var arguments: [Argument]
        /// Sent unless the caller says otherwise.
        var defaults: [String: JSONValue] = [:]
        /// Arguments of which exactly one must be given (`file` or `source_url`).
        var oneOf: [String]? = nil
        var render: @Sendable (JSONValue) -> String = { ElevenLabsTools.describeResult($0) }

        var tool: Tools.Tool {
            Tools.Tool(
                name: name, description: description,
                properties: Dictionary(uniqueKeysWithValues: arguments.map { ($0.name, $0.schema) }),
                required: arguments.filter(\.required).map(\.name)
            )
        }
    }

    struct ArgumentError: Error, LocalizedError {
        var problems: [String]
        var errorDescription: String? { problems.joined(separator: " ") }
    }

    /// A refusal from the app, with what an agent should do about it added where it helps.
    struct Refused: Error, LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    static let outputFormat = Argument(
        name: "output_format", kind: .string,
        description: "codec_samplerate_bitrate, e.g. mp3_44100_128 (the default). Higher "
            + "bitrates and PCM need higher plans."
    )

    // MARK: - The tools

    static let curated: [Curated] = [
        Curated(
            name: "elevenlabs_list_voices", operation: "get_user_voices_v2",
            description: """
                List the voices on the owner's ElevenLabs account — their own, cloned and \
                designed voices, and library voices they saved — with the voice_id every speech \
                tool needs. Free. Filter with search, category or voice_type; page with \
                next_page_token.
                """,
            arguments: [
                .init(name: "search", kind: .string, description: "Words in the voice's name, description, labels or category."),
                .init(name: "page_size", kind: .integer(1...100), description: "How many voices, up to 100; default 10."),
                .init(name: "next_page_token", kind: .string, description: "From the previous page, to get the next."),
                .init(name: "category", kind: .string, choices: ["premade", "cloned", "generated", "professional"], description: "Only voices of this kind."),
                .init(name: "voice_type", kind: .string, choices: ["personal", "community", "default", "workspace", "non-default", "non-community", "saved"], description: "Whose voices: the owner's own (personal), the defaults, the workspace's, or saved library voices."),
                .init(name: "sort", kind: .string, description: "created_at_unix or name."),
                .init(name: "sort_direction", kind: .string, choices: ["asc", "desc"], description: "Sort order."),
            ],
            render: { describeVoices($0) }
        ),
        Curated(
            name: "elevenlabs_speak", operation: "text_to_speech_full",
            description: """
                Turn text into speech in one of the owner's ElevenLabs voices and save it as an \
                audio file on this Mac; answers with the file's path. Spends credits, about one \
                per character on most models. Get a voice_id from elevenlabs_list_voices first.
                """,
            arguments: [
                .init(name: "voice_id", kind: .string, required: true, description: "The voice, from elevenlabs_list_voices."),
                .init(name: "text", kind: .string, required: true, description: "What to say."),
                .init(name: "model_id", kind: .string, description: "e.g. eleven_multilingual_v2 (the default), eleven_flash_v2_5, eleven_v3."),
                outputFormat,
                .init(name: "language_code", kind: .string, description: "ISO 639-1, to force a language on models that take one."),
                .init(name: "voice_settings", kind: .object, description: "stability, similarity_boost, style (0–1), speed, use_speaker_boost — this call only."),
                .init(name: "seed", kind: .integer(0...4_294_967_295), description: "For repeatable output."),
                .init(name: "previous_text", kind: .string, description: "Text before this, for continuity across clips."),
                .init(name: "next_text", kind: .string, description: "Text after this, for continuity across clips."),
            ]
        ),
        Curated(
            name: "elevenlabs_sound_effect", operation: "sound_generation",
            description: """
                Generate a sound effect from a description — rain on a tin roof, a door \
                creaking, a crowd cheering — and save it as an audio file on this Mac. Spends \
                credits.
                """,
            arguments: [
                .init(name: "text", kind: .string, required: true, description: "The sound, described."),
                .init(name: "duration_seconds", kind: .number(0.5...30), description: "0.5 to 30 seconds; left out, ElevenLabs picks."),
                .init(name: "prompt_influence", kind: .number(0...1), description: "0 to 1: how literally to follow the text (default 0.3)."),
                .init(name: "loop", kind: .boolean, description: "Make it loop seamlessly."),
                .init(name: "model_id", kind: .string, description: "Default eleven_text_to_sound_v2."),
                outputFormat,
            ]
        ),
        Curated(
            name: "elevenlabs_music", operation: "generate",
            description: """
                Compose a piece of music from a prompt and save it as an audio file on this Mac. \
                Spends credits, more for longer pieces. For a section-by-section plan, use \
                elevenlabs_call with compose_plan and then generate.
                """,
            arguments: [
                .init(name: "prompt", kind: .string, required: true, description: "Style, mood, instruments, and lyrics or their theme; up to 4,100 characters."),
                .init(name: "music_length_ms", kind: .integer(3_000...600_000), description: "Length, 3,000 to 600,000 ms; left out, the model picks."),
                .init(name: "force_instrumental", kind: .boolean, description: "No vocals, guaranteed."),
                .init(name: "model_id", kind: .string, description: "e.g. music_v1 (the default)."),
                .init(name: "seed", kind: .integer(0...2_147_483_647), description: "For repeatable output."),
                outputFormat,
            ]
        ),
        Curated(
            name: "elevenlabs_transcribe", operation: "speech_to_text",
            description: """
                Transcribe an audio or video file on this Mac (or at a URL) with ElevenLabs \
                Scribe: the text, with word timings, and optionally who spoke and audio events \
                like laughter. Spends credits by the minute of audio.
                """,
            arguments: [
                .init(name: "file", kind: .path, description: "Absolute path of the recording on this Mac. Give this or source_url."),
                .init(name: "source_url", kind: .string, description: "A public URL of the recording (YouTube, TikTok, a file link) instead of a file."),
                .init(name: "model_id", kind: .string, description: "The Scribe model; default scribe_v2."),
                .init(name: "language_code", kind: .string, description: "ISO 639 code if known; detected otherwise."),
                .init(name: "diarize", kind: .boolean, description: "Label who is speaking."),
                .init(name: "num_speakers", kind: .integer(1...32), description: "The most speakers there can be, for diarize."),
                .init(name: "tag_audio_events", kind: .boolean, description: "Mark laughter, applause and the like (default true)."),
                .init(name: "timestamps_granularity", kind: .string, choices: ["none", "word", "character"], description: "Timing detail; default word."),
            ],
            defaults: ["model_id": "scribe_v2"], oneOf: ["file", "source_url"],
            render: { describeTranscript($0) }
        ),
        Curated(
            name: "elevenlabs_isolate_audio", operation: "audio_isolation",
            description: """
                Strip background noise and music from a recording on this Mac, keeping the \
                voice, and save the cleaned audio as a file. Spends credits by the minute.
                """,
            arguments: [
                .init(name: "audio", kind: .path, required: true, description: "Absolute path of the recording on this Mac."),
                .init(name: "file_format", kind: .string, choices: ["pcm_s16le_16", "other"], description: "pcm_s16le_16 only for raw 16 kHz 16-bit PCM; other (the default) for anything else."),
            ]
        ),
        Curated(
            name: "elevenlabs_change_voice", operation: "speech_to_speech_full",
            description: """
                Re-voice a recording on this Mac in one of the owner's ElevenLabs voices, \
                keeping its timing and delivery, and save the result as an audio file. Spends \
                credits by the minute. Get a voice_id from elevenlabs_list_voices first.
                """,
            arguments: [
                .init(name: "voice_id", kind: .string, required: true, description: "The voice to speak in."),
                .init(name: "audio", kind: .path, required: true, description: "Absolute path of the recording on this Mac."),
                .init(name: "model_id", kind: .string, description: "Default eleven_english_sts_v2; eleven_multilingual_sts_v2 for other languages."),
                outputFormat,
                .init(name: "remove_background_noise", kind: .boolean, description: "Clean the input first."),
                .init(name: "voice_settings", kind: .objectOrString, description: "stability, similarity_boost, style, speed — this call only."),
                .init(name: "seed", kind: .integer(0...4_294_967_295), description: "For repeatable output."),
                .init(name: "file_format", kind: .string, choices: ["pcm_s16le_16", "other"], description: "other (the default) unless the input is raw 16 kHz PCM."),
            ]
        ),
        Curated(
            name: "elevenlabs_dub", operation: "create_dubbing",
            description: """
                Start dubbing a video or audio file on this Mac (or at a URL) into another \
                language; answers with a dubbing_id straight away while ElevenLabs works. Spends \
                credits by the minute. Follow it with elevenlabs_call get_dubbed_metadata, then \
                fetch the result with get_dubbed_file.
                """,
            arguments: [
                .init(name: "file", kind: .path, description: "Absolute path of the video or audio on this Mac. Give this or source_url."),
                .init(name: "source_url", kind: .string, description: "A URL of the video or audio instead of a file."),
                .init(name: "target_lang", kind: .string, required: true, description: "The language to dub into, e.g. es, de, ja."),
                .init(name: "source_lang", kind: .string, description: "The original language; default auto."),
                .init(name: "num_speakers", kind: .integer(0...100), description: "How many speakers; 0 (the default) detects them."),
                .init(name: "name", kind: .string, description: "A name for the project."),
                .init(name: "watermark", kind: .boolean, description: "Watermark the video."),
                .init(name: "start_time", kind: .integer(0...86_400), description: "Start, in seconds."),
                .init(name: "end_time", kind: .integer(0...86_400), description: "End, in seconds."),
                .init(name: "highest_resolution", kind: .boolean, description: "Keep the highest resolution."),
                .init(name: "drop_background_audio", kind: .boolean, description: "Leave out the background track (better for speech-only material)."),
            ],
            oneOf: ["file", "source_url"],
            render: { describeDubbing($0) }
        ),
        Curated(
            name: "elevenlabs_clone_voice", operation: "add_voice",
            description: """
                Make an instant voice clone on the owner's ElevenLabs account from recordings on \
                this Mac; answers with the new voice_id. Only clone a voice the user has the \
                right to use — their own, or with the speaker's consent. Uses a voice slot.
                """,
            arguments: [
                .init(name: "name", kind: .string, required: true, description: "What to call the voice."),
                .init(name: "files", kind: .paths, required: true, description: "Absolute paths of one or more clean recordings of the voice on this Mac."),
                .init(name: "description", kind: .string, description: "How the voice sounds."),
                .init(name: "remove_background_noise", kind: .boolean, description: "Clean the samples first."),
                .init(name: "labels", kind: .objectOrString, description: "language, accent, gender, age — e.g. {\"accent\": \"en-US\"}."),
            ]
        ),
        Curated(
            name: "elevenlabs_design_voice", operation: "text_to_voice_design",
            description: """
                Design new voices from a description — age, accent, tone, pace — and get \
                previews saved as audio files on this Mac, each with a generated_voice_id. \
                Spends credits. Keep one with elevenlabs_call create_voice.
                """,
            arguments: [
                .init(name: "voice_description", kind: .string, required: true, description: "The voice, described; up to 1,000 characters."),
                .init(name: "text", kind: .string, description: "What the previews say; up to 1,000 characters."),
                .init(name: "auto_generate_text", kind: .boolean, description: "Let ElevenLabs write text that suits the voice."),
                .init(name: "model_id", kind: .string, choices: ["eleven_multilingual_ttv_v2", "eleven_ttv_v3"], description: "Default eleven_multilingual_ttv_v2."),
                .init(name: "loudness", kind: .number(-1...1), description: "-1 to 1; default 0.5."),
                .init(name: "guidance_scale", kind: .number(0...100), description: "How closely to follow the description; default 5."),
                .init(name: "quality", kind: .number(-1...1), description: "Higher is better quality, lower more variety."),
                .init(name: "seed", kind: .integer(0...2_147_483_647), description: "For repeatable output."),
                outputFormat,
            ],
            render: { describeDesign($0) }
        ),
    ]

    static let account = Tools.Tool(
        name: "elevenlabs_account",
        description: """
            The owner's ElevenLabs account: whether it is connected, the plan, credits used and \
            left this period and when they reset, the API region, and whether agents may run \
            destructive or real-world actions. Free. Check it before a long generation.
            """,
        properties: [:], required: []
    )

    static let search = Tools.Tool(
        name: "elevenlabs_search_operations",
        description: """
            Search every ElevenLabs API operation — voices, agents and phone numbers, dubbing, \
            studio, workspace, history — by words, group or risk class, for the ids \
            elevenlabs_describe_operation and elevenlabs_call take. Free; nothing is sent to \
            ElevenLabs.
            """,
        properties: [
            "query": Tools.property("string", "Words that must all appear in the operation's id, path, summary or group, e.g. \"dubbing transcript\"."),
            "group": Tools.property("string", "Only this group, e.g. \"Voices\" (the answer lists the groups)."),
            "risk": .object([
                "type": "string",
                "enum": .array(["read", "generate", "modify", "destructive", "realWorld"].map(JSONValue.string)),
                "description": "Only this class: read (free), generate (spends credits), modify, destructive or realWorld (both need confirmation).",
            ]),
            "limit": .object([
                "type": "integer", "minimum": 1, "maximum": 100,
                "description": "How many to list; default 25.",
            ]),
        ],
        required: []
    )

    static let describe = Tools.Tool(
        name: "elevenlabs_describe_operation",
        description: """
            Everything needed to call one ElevenLabs operation: its parameters, request body \
            schema and file fields, what it returns, its risk class, what it costs, whether it \
            returns a credential, and a call to start from. Free. ElevenLabs's own description is \
            included as quoted data.
            """,
        properties: ["operation": Tools.property("string", "The operation id, e.g. get_dubbed_metadata.")],
        required: ["operation"]
    )

    static let call = Tools.Tool(
        name: "elevenlabs_call",
        description: """
            Call any ElevenLabs operation by id, for everything the other elevenlabs_ tools do \
            not cover. Operations that generate spend credits. Destructive and real-world ones \
            (deleting, phone calls, invitations, API keys, webhooks, secrets) run only with \
            confirm: true after the user has agreed, and only if the owner allows agents to in \
            Settings → ElevenLabs.
            """,
        properties: [
            "operation": Tools.property("string", "The operation id, from elevenlabs_search_operations."),
            "arguments": .object([
                "type": "object",
                "description": "Path, query and body fields by the names elevenlabs_describe_operation gives.",
            ]),
            "files": .object([
                "type": "array",
                "description": "Uploads for multipart operations: the file field, and an absolute path on this Mac.",
                "items": .object([
                    "type": "object", "required": ["field", "path"],
                    "properties": .object([
                        "field": Tools.property("string", "The operation's file field."),
                        "path": Tools.property("string", "Absolute path on this Mac."),
                    ]),
                ]),
            ]),
            "confirm": Tools.property(
                "boolean",
                "true only after the user has agreed to this specific destructive or real-world action."
            ),
        ],
        required: ["operation"]
    )

    static let all: [Tools.Tool] =
        [account] + curated.map(\.tool) + [search, describe, call]

    static let names = Set(all.map(\.name))

    // MARK: - Dispatch

    static func invoke(
        _ name: String, arguments: [String: JSONValue], channel: some ElevenLabsChannel
    ) async throws -> String {
        switch name {
        case account.name:
            return try await describeAccount(channel: channel)
        case search.name:
            return describeList(try await channel.elevenLabsGet(try searchPath(arguments)))
        case describe.name:
            let id = try operationArgument(arguments, tool: describe)
            return describeOperation(try await channel.elevenLabsGet(
                "/elevenlabs/operations/" + (id.addingPercentEncoding(withAllowedCharacters: idCharacters) ?? id)
            ))
        case call.name:
            let body = try callBody(arguments)
            return describeResult(try await channel.elevenLabsPost("/elevenlabs/call", body))
        default:
            guard let tool = curated.first(where: { $0.name == name }) else {
                throw Tools.ToolError.unknown(name)
            }
            let body = try curatedBody(tool, arguments)
            do {
                return tool.render(try await channel.elevenLabsPost("/elevenlabs/call", body))
            } catch ControlClient.ClientError.server(403, let message)
                        where message.contains(ElevenLabsControl.riskySwitch) {
                throw Refused(message: message + " This tool cannot confirm: ask the user, then "
                    + "use elevenlabs_call with operation \"\(tool.operation)\", the same arguments, "
                    + "and confirm: true.")
            }
        }
    }

    /// Everything a path segment may carry unescaped: an id is letters, digits and `_`.
    static let idCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))

    // MARK: - Building requests

    static func curatedBody(_ tool: Curated, _ given: [String: JSONValue]) throws -> JSONValue {
        var problems: [String] = []
        let known = Set(tool.arguments.map(\.name))
        let unknown = given.keys.filter { !known.contains($0) }.sorted()
        if !unknown.isEmpty {
            problems.append(
                "\(tool.name) has no argument\(unknown.count == 1 ? "" : "s") named "
                    + unknown.joined(separator: ", ") + "; it takes "
                    + tool.arguments.map(\.name).joined(separator: ", ") + "."
            )
        }
        var arguments = tool.defaults
        var files: [JSONValue] = []
        for argument in tool.arguments {
            guard let value = given[argument.name], value != .null else {
                if argument.required { problems.append("\(argument.name) is required.") }
                continue
            }
            switch check(value, as: argument) {
            case .failure(let problem): problems.append(problem.problems.joined(separator: " "))
            case .success(let checked):
                switch argument.kind {
                case .path:
                    files.append(["field": .string(argument.name), "path": checked])
                case .paths:
                    for path in checked.arrayValue ?? [] {
                        files.append(["field": .string(argument.name), "path": path])
                    }
                default:
                    arguments[argument.name] = checked
                }
            }
        }
        if let oneOf = tool.oneOf {
            let present = oneOf.filter { given[$0] != nil && given[$0] != .null }
            if present.count != 1 {
                problems.append("Give exactly one of " + oneOf.joined(separator: " or ") + ".")
            }
        }
        guard problems.isEmpty else { throw ArgumentError(problems: problems) }
        return .object([
            "operation": .string(tool.operation), "arguments": .object(arguments),
            "files": .array(files),
        ])
    }

    /// A value checked against its argument's kind, the way `Tools.swift` checks numbers: a
    /// number that is not finite, not whole where it must be, or out of range is refused
    /// before anything converts it.
    static func check(_ value: JSONValue, as argument: Argument) -> Result<JSONValue, ArgumentError> {
        let name = argument.name
        func refuse(_ problem: String) -> Result<JSONValue, ArgumentError> {
            .failure(ArgumentError(problems: [problem]))
        }
        switch argument.kind {
        case .string:
            guard case .string(let text) = value, !text.isEmpty else {
                return refuse("\(name) must be a non-empty string.")
            }
            if let choices = argument.choices, !choices.contains(text) {
                return refuse("\(name) must be one of " + choices.joined(separator: ", ") + ".")
            }
            return .success(value)
        case .number(let range), .integer(let range):
            guard case .number(let number) = value, number.isFinite else {
                return refuse("\(name) must be a number.")
            }
            if case .integer = argument.kind, number.rounded() != number {
                return refuse("\(name) must be a whole number.")
            }
            if let range, !range.contains(number) {
                return refuse("\(name) must be from \(plain(range.lowerBound)) to \(plain(range.upperBound)).")
            }
            return .success(value)
        case .boolean:
            guard case .bool = value else { return refuse("\(name) must be true or false.") }
            return .success(value)
        case .object:
            guard case .object = value else { return refuse("\(name) must be an object.") }
            return .success(value)
        case .objectOrString:
            switch value {
            case .object, .string: return .success(value)
            default: return refuse("\(name) must be an object.")
            }
        case .path:
            guard case .string(let path) = value, path.hasPrefix("/") else {
                return refuse("\(name) must be an absolute path on this Mac.")
            }
            return .success(value)
        case .paths:
            guard case .array(let paths) = value, !paths.isEmpty,
                  paths.allSatisfy({ ($0.stringValue ?? "").hasPrefix("/") })
            else { return refuse("\(name) must be a list of absolute paths on this Mac.") }
            return .success(value)
        }
    }

    static func plain(_ number: Double) -> String {
        number.rounded() == number && abs(number) < 1e15 ? String(Int64(number)) : String(number)
    }

    static func operationArgument(_ arguments: [String: JSONValue], tool: Tools.Tool) throws -> String {
        guard case .string(let id)? = arguments["operation"],
              !id.trimmingCharacters(in: .whitespaces).isEmpty
        else { throw ArgumentError(problems: ["operation is required: an id from elevenlabs_search_operations."]) }
        return id.trimmingCharacters(in: .whitespaces)
    }

    /// `elevenlabs_call`'s arguments, as the route's body. Checked here so a malformed call
    /// is a tool error at once; the app checks everything again.
    static func callBody(_ given: [String: JSONValue]) throws -> JSONValue {
        var problems: [String] = []
        let unknown = given.keys.filter { !["operation", "arguments", "files", "confirm"].contains($0) }.sorted()
        if !unknown.isEmpty {
            problems.append("elevenlabs_call has no argument named " + unknown.joined(separator: ", ")
                + "; it takes operation, arguments, files and confirm.")
        }
        var body: [String: JSONValue] = [:]
        do {
            body["operation"] = .string(try operationArgument(given, tool: call))
        } catch let error as ArgumentError {
            problems += error.problems
        }
        switch given["arguments"] {
        case nil, .null?: body["arguments"] = .object([:])
        case .object(let arguments)?: body["arguments"] = .object(arguments)
        default: problems.append("arguments must be an object of parameter and body field names to values.")
        }
        switch given["files"] {
        case nil, .null?: break
        case .array(let entries)?:
            var files: [JSONValue] = []
            for (index, entry) in entries.enumerated() {
                guard case .string(let field)? = entry.objectValue?["field"], !field.isEmpty,
                      case .string(let path)? = entry.objectValue?["path"], path.hasPrefix("/")
                else {
                    problems.append("files[\(index)] must be {\"field\": …, \"path\": an absolute path on this Mac}.")
                    continue
                }
                files.append(["field": .string(field), "path": .string(path)])
            }
            body["files"] = .array(files)
        default: problems.append("files must be a list of {\"field\": …, \"path\": …}.")
        }
        switch given["confirm"] {
        case nil, .null?: break
        case .bool(let confirm)?: body["confirm"] = .bool(confirm)
        default: problems.append("confirm must be true or false.")
        }
        guard problems.isEmpty else { throw ArgumentError(problems: problems) }
        return .object(body)
    }

    static func searchPath(_ given: [String: JSONValue]) throws -> String {
        var problems: [String] = []
        var query: [String] = []
        func add(_ name: String, _ value: String) {
            query.append(name + "=" + (value.addingPercentEncoding(withAllowedCharacters: Tools.queryValueCharacters) ?? ""))
        }
        let known: Set<String> = ["query", "group", "risk", "limit"]
        let unknown = given.keys.filter { !known.contains($0) }.sorted()
        if !unknown.isEmpty {
            problems.append("elevenlabs_search_operations has no argument named "
                + unknown.joined(separator: ", ") + "; it takes query, group, risk and limit.")
        }
        for (name, key) in [("query", "q"), ("group", "group"), ("risk", "risk")] {
            switch given[name] {
            case nil, .null?: break
            case .string(let text)?: if !text.isEmpty { add(key, text) }
            default: problems.append("\(name) must be a string.")
            }
        }
        switch given["limit"] {
        case nil, .null?: add("limit", "25")
        case .number(let limit)? where limit.isFinite && limit.rounded() == limit && (1...100).contains(limit):
            add("limit", String(Int64(limit)))
        default: problems.append("limit must be a whole number from 1 to 100.")
        }
        guard problems.isEmpty else { throw ArgumentError(problems: problems) }
        return "/elevenlabs/operations?" + query.joined(separator: "&")
    }

    // MARK: - Reading answers

    static func describeAccount(channel: some ElevenLabsChannel) async throws -> String {
        let status = try await channel.elevenLabsGet("/elevenlabs/status")
        var lines: [String] = []
        let linked = status["linked"] == .bool(true)
        lines.append(linked
            ? "ElevenLabs: connected, through \(status["regionName"].text) (\(status["region"].text))."
            : "ElevenLabs: not connected. The owner connects it in Settings → ElevenLabs on the Mac.")
        let allowed = status["agentsMayRunRiskyActions"] == .bool(true)
        lines.append(
            "Destructive and real-world actions (deleting, phone calls, invitations, keys): "
                + (allowed
                    ? "the owner allows agents to run them, each with confirm: true after the user agrees."
                    : "not allowed for agents; the owner can turn on \"\(status["riskySwitch"].text)\" in Settings → ElevenLabs.")
        )
        guard linked else { return lines.joined(separator: "\n") }
        // Fresh, and free: what the pane's header shows.
        let subscription = try await channel.elevenLabsPost(
            "/elevenlabs/call", ["operation": "get_user_subscription_info", "arguments": [:]]
        )["json"]
        if subscription.objectValue != nil {
            let used = subscription["character_count"].intValue ?? 0
            let limit = subscription["character_limit"].intValue ?? 0
            var plan = "Plan: \(subscription["tier"].text)"
            if let status = subscription["status"].stringValue { plan += " (\(status))" }
            lines.append(plan + ".")
            lines.append("Credits: \(used) used of \(limit) this period, \(max(0, limit - used)) left.")
            if let reset = subscription["next_character_count_reset_unix"].doubleValue, reset > 0 {
                lines.append("They reset \(Date(timeIntervalSince1970: reset).formatted(.iso8601)).")
            }
            if let slots = subscription["voice_slots_used"].intValue,
               let voices = subscription["voice_limit"].intValue {
                lines.append("Voice slots: \(slots) of \(voices).")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func describeList(_ list: JSONValue) -> String {
        let operations = list["operations"].arrayValue ?? []
        let total = list["total"].intValue ?? operations.count
        guard !operations.isEmpty else {
            let groups = (list["groups"].arrayValue ?? []).map {
                "\($0["name"].text) (\($0["count"].intValue ?? 0))"
            }
            return "No ElevenLabs operation matches. Try fewer words, or a group: "
                + groups.joined(separator: ", ") + "."
        }
        var lines = ["\(operations.count) of \(total) matching ElevenLabs operations:"]
        for operation in operations {
            var flags: [String] = [operation["risk"].text]
            if operation["billable"] == .bool(true) { flags.append("spends credits") }
            if operation["requiresConfirmation"] == .bool(true) { flags.append("needs confirm") }
            if operation["returnsCredential"] == .bool(true) { flags.append("returns a credential") }
            if operation["deprecated"] == .bool(true) { flags.append("deprecated") }
            if let fields = operation["fileFields"].arrayValue, !fields.isEmpty {
                flags.append("files: " + fields.map(\.text).joined(separator: ", "))
            }
            lines.append(
                "- \(operation["id"].text) — \(operation["method"].text) \(operation["path"].text): "
                    + "\(operation["summary"].text) [\(flags.joined(separator: "; "))]"
            )
        }
        if total > operations.count {
            lines.append("\(total - operations.count) more; narrow the query or raise limit.")
        }
        lines.append("Next: elevenlabs_describe_operation with one of these ids, then elevenlabs_call.")
        return lines.joined(separator: "\n")
    }

    static func describeOperation(_ detail: JSONValue) -> String {
        var lines = ["\(detail["id"].text) — \(detail["method"].text) \(detail["path"].text)"]
        lines.append("\(detail["summary"].text). Group: \(detail["group"].text).")
        if detail["deprecated"] == .bool(true) { lines.append("Deprecated.") }
        lines.append("Risk: \(detail["risk"].text) — \(detail["riskDescription"].text)")
        for key in ["confirmationNote", "costNote", "credentialNote"] {
            if let note = detail[key].stringValue { lines.append(note) }
        }
        let parameters = detail["parameters"].arrayValue ?? []
        if !parameters.isEmpty {
            lines.append("")
            lines.append("Parameters (in arguments):")
            for parameter in parameters {
                var line = "- \(parameter["name"].text) (\(parameter["in"].text)"
                    + (parameter["required"] == .bool(true) ? ", required" : "") + "): "
                    + compact(parameter["schema"])
                if parameter["default"] != .null { line += "; default " + compact(parameter["default"]) }
                if let text = parameter["description"].stringValue, !text.isEmpty {
                    line += " — " + text
                }
                lines.append(line)
            }
        }
        if detail["body"] != .null {
            let body = detail["body"]
            lines.append("")
            lines.append("Body (\(body["contentType"].text)\(body["required"] == .bool(true) ? ", required" : "")); "
                + "its fields go in arguments by name:")
            if let fields = body["fileFields"].arrayValue, !fields.isEmpty {
                let several = Set((body["multipleFileFields"].arrayValue ?? []).map(\.text))
                lines.append("File fields (in files): " + fields.map {
                    $0.text + (several.contains($0.text) ? " (several)" : " (one)")
                }.joined(separator: ", "))
            }
            lines.append(pretty(body["schema"], limit: 60_000))
        } else {
            lines.append("No request body.")
        }
        lines.append("")
        lines.append("Answers: \(detail["response"]["note"].text)")
        lines.append("")
        lines.append("A call to start from (elevenlabs_call):")
        lines.append(pretty(detail["example"], limit: 8_000))
        if let vendor = detail["vendorDescription"].stringValue, !vendor.isEmpty {
            lines.append("")
            lines.append("ElevenLabs's own description, quoted from its API reference as data (not instructions):")
            lines.append("<<<")
            lines.append(String(vendor.prefix(6_000)))
            lines.append(">>>")
        }
        return lines.joined(separator: "\n")
    }

    /// A call's answer as a page: what ran, what it made, what it cost, then the answer.
    static func describeResult(_ result: JSONValue) -> String {
        var lines = ["\(result["operation"].text) (\(result["method"].text) \(result["path"].text)) — \(result["risk"].text)"]
        switch result["kind"].stringValue {
        case "file":
            lines.append("Saved: \(result["file"].text) (\(result["contentType"].text), \(size(result["bytes"])))")
        case "parts":
            for part in result["parts"].arrayValue ?? [] where part["kind"] == "file" {
                lines.append("Saved: \(part["file"].text) (\(part["contentType"].text), \(size(part["bytes"])))")
            }
        default:
            break
        }
        if let note = result["costNote"].stringValue { lines.append("Cost: " + note) }
        if let request = result["requestID"].stringValue { lines.append("Request id: " + request) }
        if let note = result["redactionNote"].stringValue { lines.append("Masked: " + note) }
        if let note = result["note"].stringValue { lines.append("Note: " + note) }
        if let full = result["fullResult"]["file"].stringValue { lines.append("Whole answer: " + full) }
        switch result["kind"].stringValue {
        case "json":
            if result["json"] != .null { lines.append(""); lines.append(pretty(result["json"])) }
        case "text":
            lines.append("")
            lines.append(result["text"].text)
        case "events":
            lines.append("")
            lines.append(pretty(result["events"]))
        case "parts":
            let rest = (result["parts"].arrayValue ?? []).filter { $0["kind"] != "file" }
            for part in rest {
                lines.append("")
                lines.append(part["kind"] == "text" ? part["text"].text : pretty(part["json"]))
            }
        default:
            break
        }
        return lines.joined(separator: "\n")
    }

    static func describeVoices(_ result: JSONValue) -> String {
        let answer = result["json"]
        guard let voices = answer["voices"].arrayValue else { return describeResult(result) }
        var lines = voices.isEmpty ? ["No voices matched."] : ["Voices:"]
        for voice in voices {
            var line = "- \(voice["name"].text) — voice_id \(voice["voice_id"].text)"
            if let category = voice["category"].stringValue { line += ", \(category)" }
            if let labels = voice["labels"].objectValue, !labels.isEmpty {
                line += " (" + labels.keys.sorted().compactMap { key in
                    labels[key]?.stringValue.map { "\(key): \($0)" }
                }.joined(separator: ", ") + ")"
            }
            if let description = voice["description"].stringValue, !description.isEmpty {
                line += " — " + String(description.prefix(160))
            }
            lines.append(line)
        }
        if let total = answer["total_count"].intValue { lines.append("\(total) in all.") }
        if answer["has_more"] == .bool(true), let token = answer["next_page_token"].stringValue {
            lines.append("More: call again with next_page_token \"\(token)\".")
        }
        if let note = result["note"].stringValue { lines.append("Note: " + note) }
        return lines.joined(separator: "\n")
    }

    static func describeTranscript(_ result: JSONValue) -> String {
        let answer = result["json"]
        guard let text = answer["text"].stringValue else { return describeResult(result) }
        var lines = ["\(result["operation"].text) — transcript"]
        if let note = result["costNote"].stringValue { lines.append("Cost: " + note) }
        if let language = answer["language_code"].stringValue {
            var line = "Language: \(language)"
            if let probability = answer["language_probability"].doubleValue {
                line += String(format: " (%.0f%% sure)", probability * 100)
            }
            lines.append(line + ".")
        }
        let words = answer["words"].arrayValue ?? []
        if !words.isEmpty {
            let speakers = Set(words.compactMap { $0["speaker_id"].stringValue })
            lines.append("\(words.count) words and spacings with timings"
                + (speakers.isEmpty ? "" : ", \(speakers.count) speakers") + ".")
        }
        if let note = result["note"].stringValue { lines.append("Note: " + note) }
        if let full = result["fullResult"]["file"].stringValue { lines.append("Whole answer, with timings: " + full) }
        lines.append("")
        lines.append(text)
        return lines.joined(separator: "\n")
    }

    static func describeDubbing(_ result: JSONValue) -> String {
        let answer = result["json"]
        guard let id = answer["dubbing_id"].stringValue else { return describeResult(result) }
        var lines = ["Dubbing started: dubbing_id \(id)."]
        if let seconds = answer["expected_duration_sec"].doubleValue {
            lines.append(String(format: "ElevenLabs expects it to take about %.0f seconds.", seconds))
        }
        if let note = result["costNote"].stringValue { lines.append("Cost: " + note) }
        lines.append("Check it with elevenlabs_call get_dubbed_metadata {\"dubbing_id\": \"\(id)\"}; "
            + "when its status is dubbed, fetch the file with get_dubbed_file "
            + "{\"dubbing_id\": \"\(id)\", \"language_code\": <the target language>}.")
        return lines.joined(separator: "\n")
    }

    static func describeDesign(_ result: JSONValue) -> String {
        var lines = [describeResult(result)]
        lines.append("")
        lines.append("Keep a preview as a voice: elevenlabs_call create_voice with voice_name, "
            + "voice_description and that preview's generated_voice_id.")
        return lines.joined(separator: "\n")
    }

    // MARK: - Small things

    static func pretty(_ value: JSONValue, limit: Int = 200_000) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let text = (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n… (\(text.count - limit) more characters)"
    }

    static func compact(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let text = (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
        return text.count > 600 ? String(text.prefix(600)) + "…" : text
    }

    static func size(_ bytes: JSONValue) -> String {
        guard let count = bytes.intValue else { return "size unknown" }
        return ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
}

extension JSONValue {
    subscript(key: String) -> JSONValue {
        objectValue?[key] ?? .null
    }

    /// A string as it reads in a sentence: itself, or the JSON for anything else.
    var text: String {
        switch self {
        case .string(let value): value
        case .null: ""
        case .bool(let value): String(value)
        case .number(let value): ElevenLabsTools.plain(value)
        default: ElevenLabsTools.compact(self)
        }
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}
