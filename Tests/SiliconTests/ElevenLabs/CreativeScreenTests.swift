import Foundation
import SiliconElevenLabs
import Testing
@testable import SiliconUI

/// Each creative screen's model: what it sends for what the owner chose, what it refuses to
/// send, and what it makes of the answer — end to end through the client and the in-memory
/// transport.
@Suite("ElevenLabs creative screens")
@MainActor
struct CreativeScreenTests {

    // MARK: - Speech

    @Test func speechStartsFromTheSpecsDefaultsAndSendsOnlyWhatWasChosen() {
        let rig = CreativeRig()
        defer { rig.clean() }
        let speech = rig.session.speech
        #expect(speech.modelID == "eleven_multilingual_v2")
        #expect(speech.outputFormat == "mp3_44100_128")
        #expect(speech.problems == ["Choose a voice.", "Write something to say."])
        speech.voiceID = "voice-rachel"
        speech.text = "Hello there."
        #expect(speech.problems.isEmpty)
        #expect(speech.arguments() == [
            "voice_id": "voice-rachel", "text": "Hello there.", "output_format": "mp3_44100_128",
            "model_id": "eleven_multilingual_v2",
        ])
    }

    @Test func speechWithEveryOptionSendsOnlyArgumentsTheOperationsTake() throws {
        let rig = CreativeRig()
        defer { rig.clean() }
        let speech = rig.session.speech
        speech.voiceID = "voice-rachel"
        speech.text = "Hello."
        speech.settings.overrides = true
        speech.settings.stability = 0.334
        speech.languageCode = "en"
        speech.seed = 42
        speech.previousText = "Before."
        speech.nextText = "After."
        speech.nextRequestID = "req-next"
        speech.textNormalization = "on"
        speech.languageNormalization = true
        speech.usePVCAsIVC = true
        speech.enableLogging = false
        speech.latencyOptimization = 2
        speech.dictionaries = [CreativeDictionaryLocator(dictionaryID: "dict", versionID: "v1", name: "Names")]
        for delivery in SpeechScreenModel.Delivery.allCases {
            for timestamps in [false, true] {
                speech.delivery = delivery
                speech.timestamps = timestamps
                let operation = try #require(ElevenLabsCatalog.operation(speech.operationID))
                let arguments = speech.arguments()
                #expect(CreativeSpec.unknownArguments(arguments, for: operation).isEmpty)
                #expect(rig.client.validate(operation.id, arguments: arguments).isEmpty, "\(operation.id)")
            }
        }
        let arguments = speech.arguments()
        #expect(arguments["voice_settings"]?["stability"] == 0.33)
        #expect(arguments["pronunciation_dictionary_locators"] == [["pronunciation_dictionary_id": "dict", "version_id": "v1"]])
        #expect(arguments["enable_logging"] == false)
        #expect(arguments["next_request_ids"] == ["req-next"])
    }

    @Test func streamingFallsBackToTheSpecsDefaultWhenTheFormatIsNotStreamable() {
        let rig = CreativeRig()
        defer { rig.clean() }
        let speech = rig.session.speech
        speech.outputFormat = "wav_44100"
        #expect(speech.effectiveOutputFormat == "wav_44100")
        speech.delivery = .stream
        #expect(speech.operationID == SpeechScreenModel.stream)
        #expect(!speech.outputFormats.contains("wav_44100"))
        #expect(speech.effectiveOutputFormat == "mp3_44100_128")
    }

    @Test func aModelThatCannotUseStyleIsNotSentStyle() {
        let rig = CreativeRig()
        defer { rig.clean() }
        rig.session.models.set(CreativeRig.modelsJSON.arrayValue!.compactMap(CreativeModel.init(json:)))
        let speech = rig.session.speech
        speech.modelID = "eleven_flash_v2_5"
        speech.settings.overrides = true
        let settings = speech.arguments()["voice_settings"]
        #expect(settings?["style"] == .null)
        #expect(settings?["stability"] == 0.5)
        #expect(settings?["speed"] == 1)
        speech.text = String(repeating: "a", count: 40_001)
        speech.voiceID = "v"
        #expect(speech.problems.contains { $0.contains("40,000") })
        #expect(speech.estimatedCharacters == 20_001)
    }

    @Test func speechWithTimingsPlaysBackTheWordsAndContinuesFromTheTake() async throws {
        let rig = CreativeRig()
        defer { rig.clean() }
        let audio = CreativeRig.wavData(seconds: 1).base64EncodedString()
        rig.always(SpeechScreenModel.fullWithTimestamps, .json(
            ["audio_base64": .string(audio), "alignment": CreativeRig.alignment(for: "Hello there.")],
            headers: ["request-id": "req-1", "character-cost": "12"]
        ))
        let speech = rig.session.speech
        speech.voiceID = "voice-rachel"
        speech.text = "Hello there."
        speech.timestamps = true
        speech.outputFormat = "wav_44100"
        await speech.generate()
        #expect(speech.lastRunner.phase == .succeeded, "\(speech.lastRunner.errorMessage ?? "")")
        let request = try #require(rig.requests(SpeechScreenModel.fullWithTimestamps).first)
        #expect(request.request.url.absoluteString
                == "https://api.elevenlabs.io/v1/text-to-speech/voice-rachel/with-timestamps?output_format=wav_44100")
        #expect(rig.transport.hostViolations.isEmpty)
        #expect(speech.words.map(\.text) == ["Hello", "there."])
        let take = try #require(speech.takes.first)
        #expect(take.requestID == "req-1")
        #expect(take.characterCost == 12)
        #expect(FileManager.default.fileExists(atPath: take.file.path))

        speech.continueFromLastTake = true
        #expect(speech.arguments()["previous_request_ids"] == ["req-1"])
    }

    @Test func speechCanBeLoadedFromTheVoicesSavedSettings() async {
        let rig = CreativeRig()
        defer { rig.clean() }
        rig.always("get_voice_settings", .json(["stability": 0.8, "similarity_boost": 0.2, "style": 0.4, "speed": 1.5, "use_speaker_boost": false]))
        let settings = rig.session.speech.settings
        await settings.loadSaved(voiceID: "voice-adam")
        #expect(settings.overrides)
        #expect(settings.stability == 0.8)
        #expect(settings.similarityBoost == 0.2)
        #expect(settings.speed == 1.2, "clamped to the range the spec gives")
        #expect(!settings.useSpeakerBoost)
        #expect(rig.requests("get_voice_settings").first?.request.url.path == "/v1/voices/voice-adam/settings")
    }

    @Test func withNothingToSayNothingIsSent() async {
        let rig = CreativeRig()
        defer { rig.clean() }
        await rig.session.speech.generate()
        #expect(rig.transport.requests.isEmpty)
    }

    // MARK: - Dialogue

    @Test func aDialogueSendsItsLinesAndSkipsEmptyOnes() throws {
        let rig = CreativeRig()
        defer { rig.clean() }
        let dialogue = rig.session.dialogue
        #expect(dialogue.modelID == "eleven_v3")
        dialogue.lines = [
            DialogueLine(voiceID: "voice-rachel", text: "Hi!"),
            DialogueLine(voiceID: "voice-adam", text: "Hello."),
            DialogueLine(voiceID: "", text: "  "),
        ]
        #expect(dialogue.problems.isEmpty)
        dialogue.overridesSettings = true
        dialogue.futureText = "Next."
        dialogue.seed = 7
        let arguments = dialogue.arguments()
        #expect(arguments["inputs"] == [["text": "Hi!", "voice_id": "voice-rachel"], ["text": "Hello.", "voice_id": "voice-adam"]])
        #expect(arguments["settings"] == ["stability": 0.5, "similarity": 0.75])
        for delivery in SpeechScreenModel.Delivery.allCases {
            for timestamps in [false, true] {
                dialogue.delivery = delivery
                dialogue.timestamps = timestamps
                let operation = try #require(ElevenLabsCatalog.operation(dialogue.operationID))
                #expect(CreativeSpec.unknownArguments(dialogue.arguments(), for: operation).isEmpty)
                #expect(rig.client.validate(operation.id, arguments: dialogue.arguments()).isEmpty)
            }
        }
        dialogue.previousText = String(repeating: "x", count: 101)
        #expect(dialogue.problems.contains { $0.contains("100") })
    }

    @Test func aPastedScriptGivesEachNamedSpeakerTheirVoice() {
        let rig = CreativeRig()
        defer { rig.clean() }
        rig.voices.set(CreativeRig.sampleVoices)
        let dialogue = rig.session.dialogue
        dialogue.importScript("""
        Rachel: Did you hear that?
        Adam: Hear what?
        (pause)
        rachel: That noise. [whispers]
        Narrator: Silence.
        """)
        #expect(dialogue.lines.map(\.voiceID) == ["voice-rachel", "voice-adam", "voice-adam", "voice-rachel", ""])
        #expect(dialogue.lines.map(\.text) == ["Did you hear that?", "Hear what?", "(pause)", "That noise. [whispers]", "Silence."])
        #expect(dialogue.problems == ["Choose a voice for every line."])
    }

    @Test func aDialogueWithTimingsSaysWhoSpeaksWhen() async {
        let rig = CreativeRig()
        defer { rig.clean() }
        rig.always(DialogueScreenModel.fullWithTimestamps, .json([
            "audio_base64": .string(CreativeRig.wavData(seconds: 1).base64EncodedString()),
            "alignment": CreativeRig.alignment(for: "Hi! Hello."),
            "voice_segments": [
                ["voice_id": "voice-rachel", "start_time_seconds": 0, "end_time_seconds": 0.3,
                 "character_start_index": 0, "character_end_index": 3, "dialogue_input_index": 0],
                ["voice_id": "voice-adam", "start_time_seconds": 0.3, "end_time_seconds": 0.8,
                 "character_start_index": 4, "character_end_index": 10, "dialogue_input_index": 1],
            ],
        ]))
        let dialogue = rig.session.dialogue
        dialogue.lines = [DialogueLine(voiceID: "voice-rachel", text: "Hi!"), DialogueLine(voiceID: "voice-adam", text: "Hello.")]
        dialogue.timestamps = true
        await dialogue.generate()
        #expect(dialogue.lastRunner.phase == .succeeded, "\(dialogue.lastRunner.errorMessage ?? "")")
        #expect(dialogue.segments.map(\.line) == [0, 1])
        #expect(dialogue.words.map(\.text) == ["Hi!", "Hello."])
        #expect(dialogue.takes.count == 1)
    }

    @Test func dialogueLinesMoveAndTheLastOneCannotBeRemoved() {
        let rig = CreativeRig()
        defer { rig.clean() }
        let dialogue = rig.session.dialogue
        dialogue.lines = [DialogueLine(voiceID: "a", text: "1"), DialogueLine(voiceID: "b", text: "2")]
        dialogue.addLine()
        #expect(dialogue.lines.last?.voiceID == "a", "a new line answers the one before")
        dialogue.moveLine(dialogue.lines[0].id, by: 1)
        #expect(dialogue.lines.map(\.text) == ["2", "1", ""])
        for line in dialogue.lines { dialogue.removeLine(line.id) }
        #expect(dialogue.lines.count == 1)
    }

    // MARK: - Voice changer

    @Test func theVoiceChangerUploadsTheRecordingAndSendsSettingsAsJSONText() async throws {
        let rig = CreativeRig()
        defer { rig.clean() }
        rig.always(VoiceChangerScreenModel.full, .audio(CreativeRig.wavData(seconds: 0.5), contentType: "audio/wav"))
        let changer = rig.session.voiceChanger
        #expect(changer.modelID == "eleven_english_sts_v2")
        #expect(changer.problems.count == 2)
        changer.source = rig.wav(named: "me.wav")
        changer.voiceID = "voice-adam"
        changer.settings.overrides = true
        changer.removeBackgroundNoise = true
        changer.rawPCMInput = true
        let arguments = changer.arguments()
        let settingsText = try #require(arguments["voice_settings"]?.stringValue)
        #expect(try JSONValue(data: Data(settingsText.utf8))["stability"] == 0.5)
        #expect(arguments["file_format"] == "pcm_s16le_16")
        for id in VoiceChangerScreenModel.operationIDs {
            #expect(rig.client.validate(id, arguments: arguments, files: changer.files()).isEmpty, "\(id)")
        }
        changer.rawPCMInput = false
        await changer.generate()
        #expect(changer.lastRunner.phase == .succeeded, "\(changer.lastRunner.errorMessage ?? "")")
        let body = try #require(rig.lastMultipart(VoiceChangerScreenModel.full))
        #expect(body.contains(#"filename="me.wav""#))
        #expect(body.contains(#"name="remove_background_noise""#))
        let take = try #require(changer.takes.first)
        #expect(changer.sources[take.id]?.lastPathComponent == "me.wav")
    }

    // MARK: - Sound effects

    @Test func aSoundEffectLeavesTheLengthToTheModelUnlessSet() async throws {
        let rig = CreativeRig()
        defer { rig.clean() }
        rig.always(SoundEffectsScreenModel.generate, .audio(CreativeRig.wavData(seconds: 0.5), contentType: "audio/wav"))
        let effects = rig.session.soundEffects
        #expect(effects.promptInfluence == 0.3)
        #expect(effects.durationRange == 0.5...30)
        effects.text = "Door creak"
        #expect(effects.arguments()["duration_seconds"] == nil)
        effects.automaticDuration = false
        effects.duration = 2.349
        effects.loop = true
        let arguments = effects.arguments()
        #expect(arguments["duration_seconds"] == 2.3)
        #expect(arguments["loop"] == true)
        #expect(rig.client.validate(SoundEffectsScreenModel.generate, arguments: arguments).isEmpty)
        await effects.generate()
        await effects.generate()
        #expect(effects.takes.count == 2, "each take is kept to compare")
        #expect(rig.lastBody(SoundEffectsScreenModel.generate)?["text"] == "Door creak")
    }

    // MARK: - Music

    @Test func composingFromAPlanLeavesOutWhatOnlyGoesWithAPrompt() throws {
        let rig = CreativeRig()
        defer { rig.clean() }
        let music = rig.session.music
        music.prompt = "Lo-fi beat"
        music.usesLength = true
        music.lengthSeconds = 90
        music.forceInstrumental = true
        music.seed = 3
        music.generationMode = "loop"
        var arguments = music.composeArguments()
        #expect(arguments["prompt"] == "Lo-fi beat")
        #expect(arguments["music_length_ms"] == 90_000)
        #expect(arguments["composition_plan"] == nil)

        music.load(plan: Self.planJSON)
        music.usesPlan = true
        arguments = music.composeArguments()
        #expect(arguments["prompt"] == nil)
        #expect(arguments["seed"] == nil)
        #expect(arguments["music_length_ms"] == nil)
        #expect(arguments["force_instrumental"] == nil)
        #expect(arguments["composition_plan"]?["sections"][0]["section_name"] == "Intro")
        for delivery in MusicScreenModel.Delivery.allCases {
            music.delivery = delivery
            music.finetuneID = "ft"
            music.withWaveform = true
            let operation = try #require(ElevenLabsCatalog.operation(music.composeOperationID))
            let arguments = music.composeArguments()
            #expect(CreativeSpec.unknownArguments(arguments, for: operation).isEmpty, "\(operation.id)")
            #expect(rig.client.validate(operation.id, arguments: arguments).isEmpty, "\(operation.id)")
        }
    }

    @Test func aPlanRoundTripsAndKeepsWhatItDoesNotEdit() throws {
        let plan = try #require(MusicPlan(json: Self.planJSON))
        #expect(plan.sections.map(\.name) == ["Intro", "Chorus"])
        #expect(plan.totalMs == 25_000)
        #expect(plan.json["sections"][1]["source_from"] == ["song_id": "s1"])
        #expect(MusicPlan(json: plan.json) == plan)
        #expect(plan.problems().isEmpty)
        var broken = plan
        broken.sections[0].durationMs = 500
        broken.sections[1].name = ""
        #expect(broken.problems().contains { $0.contains("between 3 and 120 seconds") })
        #expect(broken.problems().contains("Section 2 needs a name."))
        #expect(MusicPlan(json: ["chunks": []]) == nil, "the chunks shape is edited as JSON")
    }

    @Test func aPlanIsMadeAndOpensInTheEditor() async {
        let rig = CreativeRig()
        defer { rig.clean() }
        rig.always(MusicScreenModel.plan, .json(Self.planJSON))
        let music = rig.session.music
        music.planPrompt = "A short song"
        await music.makePlan()
        #expect(music.plan?.sections.count == 2)
        music.composeFromPlan()
        #expect(music.tab == .compose)
        #expect(music.usesPlan)
        #expect(music.composeProblems.isEmpty)

        rig.always(MusicScreenModel.plan, .json(["chunks": [["type": "generation"]]]))
        music.planFromCurrent = true
        await music.makePlan()
        #expect(music.plan == nil)
        #expect(music.planJSON.contains("chunks"))
        #expect(rig.lastBody(MusicScreenModel.plan)?["source_composition_plan"]["sections"] != .null)
    }

    @Test func aDetailedSongShowsItsLyricsTimings() {
        let rig = CreativeRig()
        defer { rig.clean() }
        let music = rig.session.music
        music.readDetails(.parts([
            .json(["composition_plan": Self.planJSON, "song_metadata": ["title": "T"],
                   "words_timestamps": [["word": "la", "start_ms": 500, "end_ms": 900]],
                   "waveform_visual": [1, 3, 2]]),
            .file(URL(fileURLWithPath: "/dev/null"), contentType: "audio/mpeg", bytes: 0),
        ], ElevenLabsMeta(status: 200)))
        #expect(music.songWords.map(\.text) == ["la"])
        #expect(music.songWords.first?.start == 0.5)
        #expect(music.songWaveform == [1, 3, 2])
        music.editReturnedPlan()
        #expect(music.tab == .plan)
        #expect(music.plan?.sections.count == 2)
    }

    @Test func stemsVideoAndUploadSendTheirFiles() async throws {
        let rig = CreativeRig()
        defer { rig.clean() }
        let music = rig.session.music
        #expect(music.stemVariation == "six_stems_v1")
        music.stemsSource = rig.wav(named: "song.wav")
        #expect(rig.client.validate(MusicScreenModel.stems, arguments: music.stemsArguments(),
                                    files: ["file": [ElevenLabsFile(url: music.stemsSource!)]]).isEmpty)
        music.videos = [rig.scratch.appendingPathComponent("a.mp4")]
        music.videoTags = ["upbeat"]
        music.videoDescription = "Happy"
        #expect(music.videoProblems.isEmpty)
        #expect(CreativeSpec.unknownArguments(music.videoArguments(), for: try #require(ElevenLabsCatalog.operation(MusicScreenModel.videoToMusic))).isEmpty)

        rig.always(MusicScreenModel.upload, .json(["song_id": "song-9", "composition_plan": Self.planJSON]))
        music.uploadSource = rig.wav(named: "mine.wav")
        music.extractPlan = "music_v1"
        await music.uploadSong()
        #expect(music.uploadedSongID == "song-9")
        #expect(music.plan?.sections.first?.name == "Intro")
        #expect(rig.lastMultipart(MusicScreenModel.upload)?.contains(#"name="extract_composition_plan""#) == true)
    }

    @Test func aFineTuneIsListedEditedByWhatChangedAndDeletedOnlyWhenConfirmed() async throws {
        let rig = CreativeRig()
        defer { rig.clean() }
        let finetune: JSONValue = ["id": "ft1", "name": "Synth dreams", "tags": ["synth"], "model_id": "music_v1",
                                   "created_at": "2026-09-01T00:00:00Z", "visibility": "private", "created_by": "self",
                                   "status": "completed", "training_progress": 1]
        rig.always(MusicScreenModel.listFinetunes, .json(["finetunes": [finetune], "next_cursor": nil, "has_more": false]))
        rig.always(MusicScreenModel.getFinetune, .json(finetune))
        let music = rig.session.music
        music.finetuneCreatorFilter = "self"
        await music.refreshFinetunes()
        #expect(music.finetunes.map(\.name) == ["Synth dreams"])
        #expect(rig.requests(MusicScreenModel.listFinetunes).last?.request.url.query?.contains("created_by=self") == true)
        await music.select(music.finetunes[0])
        #expect(music.editProblems == ["Nothing has changed."])
        music.editName = "Synth nights"
        #expect(music.updateArguments() == ["finetune_id": "ft1", "name": "Synth nights"])
        #expect(music.editProblems.isEmpty)

        let deleting = Task { await music.deleteSelectedFinetune() }
        let runner = music.runner(MusicScreenModel.deleteFinetune)
        try await CreativeRig.waitUntil { runner.phase == .awaitingConfirmation }
        #expect(runner.confirmation?.title == "Delete the fine-tune “Synth dreams”?")
        runner.decline()
        await deleting.value
        #expect(rig.requests(MusicScreenModel.deleteFinetune).isEmpty)
        #expect(music.selectedFinetune != nil)
    }

    @Test func aNewFineTuneNeedsANameAGenreAndTracks() throws {
        let rig = CreativeRig()
        defer { rig.clean() }
        let music = rig.session.music
        music.newName = "abc"
        #expect(music.createProblems.contains("The name needs at least 5 characters."))
        #expect(music.createProblems.contains("Name the primary genre."))
        #expect(music.createProblems.contains("Add the tracks to train on."))
        music.newName = "My band"
        music.newGenre = "rock"
        music.newFiles = [rig.wav()]
        #expect(music.createProblems.isEmpty)
        #expect(rig.client.validate(MusicScreenModel.createFinetune, arguments: music.createArguments(),
                                    files: ["files": music.newFiles.map { ElevenLabsFile(url: $0) }]).isEmpty)
    }

    // MARK: - Controls

    @Test func finelySteppedSlidersRoundInsteadOfDrawingTicks() {
        #expect(abs(CreativeSlider.snapped(0.337, to: 0.01, in: 0...1) - 0.34) < 1e-9)
        #expect(CreativeSlider.snapped(1.3, to: 0.01, in: 0.7...1.2) == 1.2)
        #expect(abs(CreativeSlider.snapped(15.4, to: 1, in: 3...120) - 15) < 1e-9)
        #expect(CreativeSlider.snapped(0.123, to: nil, in: 0...1) == 0.123)
    }

    @Test func outputFormatsAreNamedAndRawOnesSayTheyCannotBePlayedHere() {
        #expect(CreativeOutputFormat.title("mp3_44100_128") == "MP3 · 44.1 kHz · 128 kbps")
        #expect(CreativeOutputFormat.title("mp3_22050_32") == "MP3 · 22.05 kHz · 32 kbps")
        #expect(CreativeOutputFormat.title("pcm_16000") == "PCM · 16 kHz")
        #expect(CreativeOutputFormat.title("ulaw_8000") == "μ-law · 8 kHz")
        #expect(CreativeOutputFormat.title("auto") == "Automatic")
        #expect(CreativeOutputFormat.playabilityNote("mp3_44100_128") == nil)
        #expect(CreativeOutputFormat.playabilityNote("opus_48000_64") == nil)
        for raw in ["pcm_44100", "ulaw_8000", "alaw_8000"] {
            #expect(CreativeOutputFormat.playabilityNote(raw) != nil, "\(raw)")
        }
    }

    // MARK: - Session

    @Test func oneSessionPerAppModelKeepsEachScreensState() {
        let first = AppModel(settings: .init())
        let second = AppModel(settings: .init())
        let session = CreativeSession.shared(for: first)
        session.speech.text = "Kept"
        #expect(CreativeSession.shared(for: first).speech.text == "Kept")
        #expect(CreativeSession.shared(for: second) !== session)
        #expect(session.voices === first.elevenLabsPane.voices)
    }

    @Test func anotherAccountStartsTheScreensOver() {
        let model = AppModel(settings: .init())
        let transport = FakeElevenLabsTransport(replies: [])
        func client() -> ElevenLabsClient {
            ElevenLabsClient(credentials: FakeCredentialSource(key: "k"), region: .global,
                             transport: transport, sink: TemporaryFileSink())
        }
        let unlinked = CreativeSession.shared(for: model, client: nil)
        let first = client()
        let linked = CreativeSession.shared(for: model, client: first)
        #expect(linked === unlinked, "the session made before a client existed is kept for it")
        linked.speech.text = "Mine"
        #expect(CreativeSession.shared(for: model, client: first) === linked)
        #expect(CreativeSession.shared(for: model, client: nil) === linked, "a moment without a client changes nothing")
        let second = client()
        let other = CreativeSession.shared(for: model, client: second)
        #expect(other !== linked)
        #expect(other.speech.text.isEmpty)
    }

    // MARK: - Fixtures

    static let planJSON: JSONValue = [
        "positive_global_styles": ["lo-fi", "warm"],
        "negative_global_styles": ["harsh"],
        "sections": [
            ["section_name": "Intro", "positive_local_styles": ["piano"], "negative_local_styles": [],
             "duration_ms": 10_000, "lines": []],
            ["section_name": "Chorus", "positive_local_styles": [], "negative_local_styles": [],
             "duration_ms": 15_000, "lines": ["La la la"], "source_from": ["song_id": "s1"]],
        ],
    ]

    static func historyItem(_ id: String) -> JSONValue {
        ["history_item_id": .string(id), "request_id": .string("req-\(id)"), "voice_id": "voice-rachel",
         "model_id": "eleven_flash_v2_5", "voice_name": "Rachel", "voice_category": "premade",
         "text": .string("Hello from \(id)"), "date_unix": 1_790_000_000, "character_count_change_from": 100,
         "character_count_change_to": 112, "content_type": "audio/mpeg", "state": "created", "source": "TTS"]
    }
}
