import Foundation

/// Typed doors to the operations the curated panes and MCP tools use most. Each is `call`
/// with its operation id and arguments spelled out; labels are the spec's own argument names,
/// so what a helper sends is what "Show API call" and the explorer show. `extra` carries any
/// other argument the operation takes, by its spec name.
extension ElevenLabsClient {

    // MARK: - Models and voices

    /// `GET /v1/models`: the models this account can use, with what each supports.
    public func models() async throws -> JSONValue {
        try Self.json(await call("get_models"))
    }

    /// `GET /v1/voices`: every voice on the account.
    public func voices(show_legacy: Bool? = nil) async throws -> JSONValue {
        try Self.json(await call("get_voices", arguments: Self.arguments(["show_legacy": show_legacy.map(JSONValue.bool)])))
    }

    /// `GET /v2/voices`: voices searched, filtered and paged (`search`, `voice_type`,
    /// `category`, `page_size`, `next_page_token`… in `extra`).
    public func searchVoices(search: String? = nil, extra: [String: JSONValue] = [:]) async throws -> JSONValue {
        try Self.json(await call("get_user_voices_v2",
                                 arguments: Self.arguments(["search": search.map(JSONValue.string)], extra)))
    }

    /// `GET /v1/voices/{voice_id}`.
    public func voice(voice_id: String, with_settings: Bool? = nil) async throws -> JSONValue {
        try Self.json(await call("get_voice_by_id", arguments: Self.arguments([
            "voice_id": .string(voice_id), "with_settings": with_settings.map(JSONValue.bool),
        ])))
    }

    // MARK: - Speech

    /// `POST /v1/text-to-speech/{voice_id}`: the whole clip, written through the file sink.
    /// Billable.
    public func textToSpeech(
        voice_id: String, text: String, model_id: String? = nil, output_format: String? = nil,
        voice_settings: JSONValue? = nil, extra: [String: JSONValue] = [:]
    ) async throws -> ElevenLabsResult {
        try await call("text_to_speech_full", arguments: Self.speech(
            voice_id: voice_id, text: text, model_id: model_id, output_format: output_format,
            voice_settings: voice_settings, extra: extra
        ))
    }

    /// `POST /v1/text-to-speech/{voice_id}/with-timestamps`: the clip as a file plus the
    /// character alignment, as `.parts`. Billable.
    public func textToSpeechWithTimestamps(
        voice_id: String, text: String, model_id: String? = nil, output_format: String? = nil,
        voice_settings: JSONValue? = nil, extra: [String: JSONValue] = [:]
    ) async throws -> ElevenLabsResult {
        try await call("text_to_speech_full_with_timestamps", arguments: Self.speech(
            voice_id: voice_id, text: text, model_id: model_id, output_format: output_format,
            voice_settings: voice_settings, extra: extra
        ))
    }

    /// `POST /v1/text-to-speech/{voice_id}/stream`: audio chunks as they are generated, for
    /// playback that starts before the clip is done. Billable.
    public nonisolated func streamTextToSpeech(
        voice_id: String, text: String, model_id: String? = nil, output_format: String? = nil,
        voice_settings: JSONValue? = nil, extra: [String: JSONValue] = [:]
    ) -> AsyncThrowingStream<ElevenLabsChunk, any Error> {
        stream("text_to_speech_stream", arguments: Self.speech(
            voice_id: voice_id, text: text, model_id: model_id, output_format: output_format,
            voice_settings: voice_settings, extra: extra
        ))
    }

    // MARK: - Sound and music

    /// `POST /v1/sound-generation`: a sound effect from a description. Billable.
    public func soundEffect(
        text: String, duration_seconds: Double? = nil, prompt_influence: Double? = nil,
        loop: Bool? = nil, model_id: String? = nil, output_format: String? = nil,
        extra: [String: JSONValue] = [:]
    ) async throws -> ElevenLabsResult {
        try await call("sound_generation", arguments: Self.arguments([
            "text": .string(text), "duration_seconds": duration_seconds.map(JSONValue.number),
            "prompt_influence": prompt_influence.map(JSONValue.number), "loop": loop.map(JSONValue.bool),
            "model_id": model_id.map(JSONValue.string), "output_format": output_format.map(JSONValue.string),
        ], extra))
    }

    /// `POST /v1/music`: a song from a prompt or a composition plan. Billable.
    public func composeMusic(
        prompt: String? = nil, composition_plan: JSONValue? = nil, music_length_ms: Int? = nil,
        model_id: String? = nil, output_format: String? = nil, extra: [String: JSONValue] = [:]
    ) async throws -> ElevenLabsResult {
        try await call("generate", arguments: Self.arguments([
            "prompt": prompt.map(JSONValue.string), "composition_plan": composition_plan,
            "music_length_ms": music_length_ms.map { .number(Double($0)) },
            "model_id": model_id.map(JSONValue.string), "output_format": output_format.map(JSONValue.string),
        ], extra))
    }

    /// `POST /v1/music/plan`: a composition plan (sections, styles, lyrics) to edit before
    /// composing.
    public func composeMusicPlan(
        prompt: String, music_length_ms: Int? = nil, model_id: String? = nil,
        extra: [String: JSONValue] = [:]
    ) async throws -> JSONValue {
        try Self.json(await call("compose_plan", arguments: Self.arguments([
            "prompt": .string(prompt), "music_length_ms": music_length_ms.map { .number(Double($0)) },
            "model_id": model_id.map(JSONValue.string),
        ], extra)))
    }

    // MARK: - Audio in

    /// `POST /v1/speech-to-text`: a transcript of a file (Scribe). `diarize`,
    /// `language_code`, `timestamps_granularity`, `keyterms`… in `extra`. Billable.
    public func speechToText(
        file: ElevenLabsFile, model_id: String, extra: [String: JSONValue] = [:]
    ) async throws -> JSONValue {
        try Self.json(await call("speech_to_text",
                                 arguments: Self.arguments(["model_id": .string(model_id)], extra),
                                 files: ["file": [file]]))
    }

    /// `POST /v1/audio-isolation`: the voice in a recording with the background removed.
    /// Billable.
    public func isolateAudio(audio: ElevenLabsFile, extra: [String: JSONValue] = [:]) async throws -> ElevenLabsResult {
        try await call("audio_isolation", arguments: extra, files: ["audio": [audio]])
    }

    // MARK: - History

    /// `GET /v1/history`: generated items, newest first (`page_size`, `voice_id`, `search`…).
    public func history(
        page_size: Int? = nil, start_after_history_item_id: String? = nil, voice_id: String? = nil,
        extra: [String: JSONValue] = [:]
    ) async throws -> JSONValue {
        try Self.json(await call("get_speech_history", arguments: Self.arguments([
            "page_size": page_size.map { .number(Double($0)) },
            "start_after_history_item_id": start_after_history_item_id.map(JSONValue.string),
            "voice_id": voice_id.map(JSONValue.string),
        ], extra)))
    }

    /// `GET /v1/history/{history_item_id}/audio`: one item's audio, to a file.
    public func historyAudio(history_item_id: String) async throws -> ElevenLabsResult {
        try await call("get_audio_full_from_speech_history_item",
                       arguments: ["history_item_id": .string(history_item_id)])
    }

    /// `POST /v1/history/download`: one item's audio, or several as a zip.
    public func downloadHistory(history_item_ids: [String], output_format: String? = nil) async throws -> ElevenLabsResult {
        try await call("download_speech_history_items", arguments: Self.arguments([
            "history_item_ids": .array(history_item_ids.map(JSONValue.string)),
            "output_format": output_format.map(JSONValue.string),
        ]))
    }

    // MARK: - Plumbing

    /// The JSON of a result that should be JSON, or an error naming what came instead.
    public static func json(_ result: ElevenLabsResult) throws -> JSONValue {
        switch result {
        case .json(let value, _): return value
        case .parts(let parts, _):
            for part in parts { if case .json(let value) = part { return value } }
            fallthrough
        default:
            throw ElevenLabsError.api(status: result.meta.status, code: "unexpected_answer",
                                      message: "ElevenLabs answered with something other than JSON.",
                                      requestID: result.meta.requestID)
        }
    }

    static func arguments(
        _ named: [String: JSONValue?], _ extra: [String: JSONValue] = [:]
    ) -> [String: JSONValue] {
        var result = extra
        for (name, value) in named { if let value { result[name] = value } }
        return result
    }

    static func speech(
        voice_id: String, text: String, model_id: String?, output_format: String?,
        voice_settings: JSONValue?, extra: [String: JSONValue]
    ) -> [String: JSONValue] {
        arguments([
            "voice_id": .string(voice_id), "text": .string(text), "model_id": model_id.map(JSONValue.string),
            "output_format": output_format.map(JSONValue.string), "voice_settings": voice_settings,
        ], extra)
    }
}
