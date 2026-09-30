import Foundation
import Testing
@testable import SiliconElevenLabs

/// The typed helpers are `call` with the right operation and the spec's own argument names.
@Suite("ElevenLabs typed helpers")
struct CoreHelperTests {

    typealias Rig = CoreClientTests.Rig

    @Test func readsGoToTheirOperations() async throws {
        let rig = Rig { request in
            switch request.url.path {
            case "/v1/models": .json([["model_id": "eleven_v3"]])
            case "/v1/voices": .json(["voices": [["voice_id": "v1"]]])
            case "/v2/voices": .json(["voices": [], "has_more": false])
            case "/v1/voices/v1": .json(["voice_id": "v1"])
            case "/v1/history": .json(["history": []])
            default: .jsonText("{}", status: 404)
            }
        }
        defer { rig.cleanUp() }
        #expect(try await rig.client.models() == [["model_id": "eleven_v3"]])
        #expect(try await rig.client.voices(show_legacy: true)["voices"][0]["voice_id"] == "v1")
        _ = try await rig.client.searchVoices(search: "calm", extra: ["page_size": 5])
        #expect(try await rig.client.voice(voice_id: "v1", with_settings: true)["voice_id"] == "v1")
        _ = try await rig.client.history(page_size: 20, voice_id: "v1")
        let sent = rig.transport.requests.map { "\($0.operationID) \($0.url.path)?\($0.url.query ?? "")" }
        #expect(sent == [
            "get_models /v1/models?",
            "get_voices /v1/voices?show_legacy=true",
            "get_user_voices_v2 /v2/voices?page_size=5&search=calm",
            "get_voice_by_id /v1/voices/v1?with_settings=true",
            "get_speech_history /v1/history?page_size=20&voice_id=v1",
        ])
    }

    @Test func speechHelpersSendTheSpecsFields() async throws {
        let clip = Data([9, 9, 9])
        let rig = Rig { request in
            request.url.path.hasSuffix("/with-timestamps")
                ? .json(["audio_base64": .string(clip.base64EncodedString()), "alignment": ["characters": ["h"]]])
                : .audio(clip, chunks: [clip])
        }
        defer { rig.cleanUp() }
        let whole = try await rig.client.textToSpeech(
            voice_id: "v1", text: "hello", model_id: "eleven_flash_v2_5", output_format: "mp3_44100_128",
            voice_settings: ["stability": 0.4], extra: ["seed": 7]
        )
        #expect(whole.files.count == 1)
        let timed = try await rig.client.textToSpeechWithTimestamps(voice_id: "v1", text: "hello")
        #expect(try ElevenLabsClient.json(timed)["alignment"]["characters"] == ["h"])
        #expect(timed.files.count == 1)
        var streamed = Data()
        for try await chunk in rig.client.streamTextToSpeech(voice_id: "v1", text: "hello") {
            if case .audio(let data) = chunk { streamed.append(data) }
        }
        #expect(streamed == clip)

        let first = rig.transport.recorded[0]
        #expect(first.request.operationID == "text_to_speech_full")
        #expect(first.request.url.path == "/v1/text-to-speech/v1")
        #expect(first.request.url.query == "output_format=mp3_44100_128")
        #expect(try JSONValue(data: first.body) == ["text": "hello", "model_id": "eleven_flash_v2_5",
                                                     "voice_settings": ["stability": 0.4], "seed": 7])
        #expect(rig.transport.requests.map(\.operationID) == [
            "text_to_speech_full", "text_to_speech_full_with_timestamps", "text_to_speech_stream",
        ])
    }

    @Test func soundMusicAndHistoryHelpersSendTheSpecsFields() async throws {
        let rig = Rig { request in
            switch request.operationID {
            case "compose_plan": .json(["sections": []])
            case "download_speech_history_items": .init(status: 200, headers: ["content-type": "application/zip"], body: Data("PK".utf8))
            default: .audio(Data([1]))
            }
        }
        defer { rig.cleanUp() }
        _ = try await rig.client.soundEffect(text: "rain on a tin roof", duration_seconds: 4, prompt_influence: 0.3, loop: true)
        _ = try await rig.client.composeMusic(prompt: "lofi beat", music_length_ms: 30_000)
        #expect(try await rig.client.composeMusicPlan(prompt: "lofi beat", music_length_ms: 30_000) == ["sections": []])
        _ = try await rig.client.historyAudio(history_item_id: "h1")
        let zip = try await rig.client.downloadHistory(history_item_ids: ["h1", "h2"])
        #expect(zip.files.first?.pathExtension == "zip")

        let bodies = rig.transport.recorded.map { ($0.request.operationID, try? JSONValue(data: $0.body)) }
        #expect(bodies[0].0 == "sound_generation")
        #expect(bodies[0].1 == ["text": "rain on a tin roof", "duration_seconds": 4, "prompt_influence": 0.3, "loop": true])
        #expect(bodies[1].0 == "generate")
        #expect(bodies[1].1 == ["prompt": "lofi beat", "music_length_ms": 30_000])
        #expect(bodies[2].0 == "compose_plan")
        #expect(rig.transport.requests[3].url.path == "/v1/history/h1/audio")
        #expect(bodies[4].1 == ["history_item_ids": ["h1", "h2"]])
    }

    @Test func uploadHelpersSendTheirFileField() async throws {
        let rig = Rig { request in
            request.operationID == "speech_to_text" ? .json(["text": "hello"]) : .audio(Data([2]))
        }
        defer { rig.cleanUp() }
        let file = try CoreClientTests.scratchFile("take.wav", bytes: Data(repeating: 1, count: 32))
        defer { CoreClientTests.removeScratch(file) }
        #expect(try await rig.client.speechToText(file: ElevenLabsFile(url: file), model_id: "scribe_v1",
                                                  extra: ["diarize": true])["text"] == "hello")
        _ = try await rig.client.isolateAudio(audio: ElevenLabsFile(url: file))
        for recorded in rig.transport.recorded {
            let body = String(decoding: recorded.body, as: UTF8.self)
            #expect(body.contains("filename=\"take.wav\""))
        }
        #expect(String(decoding: rig.transport.recorded[0].body, as: UTF8.self).contains("name=\"file\""))
        #expect(String(decoding: rig.transport.recorded[1].body, as: UTF8.self).contains("name=\"audio\""))
    }

    @Test func aHelperThatExpectsJSONSaysSoWhenItGetsAFile() async {
        let rig = Rig { _ in .audio(Data([1])) }
        defer { rig.cleanUp() }
        await #expect(throws: ElevenLabsError.self) { try await rig.client.models() }
    }
}
