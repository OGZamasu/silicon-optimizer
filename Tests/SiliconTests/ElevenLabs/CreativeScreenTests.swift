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
        #expect(take.outputFormat == "wav_44100", "the take keeps the format the run asked for")
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
        #expect(arguments["seed"] == nil, "the spec takes no seed with a prompt")

        music.load(plan: Self.planJSON)
        music.usesPlan = true
        arguments = music.composeArguments()
        #expect(arguments["prompt"] == nil)
        #expect(arguments["seed"] == 3, "the seed goes with a plan")
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

    /// Which options go with a prompt and which only with a plan is the spec's, in words: a
    /// spec that changes them fails here, and the screen keeps to them in both ways of composing.
    @Test func whatGoesWithAPromptOrAPlanIsWhatTheSpecSays() throws {
        for id in MusicScreenModel.composeIDs {
            for (argument, evidence) in MusicScreenModel.promptOnly + MusicScreenModel.planOnly
            where CreativeSpec.has(id, argument) {
                let schema = try #require(CreativeSpec.schema(id, argument))
                let text = (schema["description"].stringValue ?? "") + " "
                    + (CreativeSpec.normalized(schema)["description"].stringValue ?? "")
                #expect(text.contains(evidence), "\(id).\(argument) no longer says “\(evidence)”")
            }
        }
        let rig = CreativeRig()
        defer { rig.clean() }
        let music = rig.session.music
        music.prompt = "Lo-fi"
        music.usesLength = true
        music.forceInstrumental = true
        music.generationMode = "loop"
        music.seed = 9
        music.respectSectionsDurations = false
        music.load(plan: Self.planJSON)
        for usesPlan in [false, true] {
            music.usesPlan = usesPlan
            for delivery in MusicScreenModel.Delivery.allCases {
                music.delivery = delivery
                let arguments = music.composeArguments()
                for (argument, _) in MusicScreenModel.promptOnly where usesPlan {
                    #expect(arguments[argument] == nil, "\(argument) sent with a plan")
                }
                for (argument, _) in MusicScreenModel.planOnly where !usesPlan {
                    #expect(arguments[argument] == nil, "\(argument) sent with a prompt")
                }
                #expect((arguments["prompt"] != nil) != usesPlan)
            }
        }
    }

    /// Music's default format is the spec's "auto" (always MP3). Sent, it reached the stream
    /// player as a format it cannot decode, so "Streamed" never played live; it is now left for
    /// ElevenLabs to apply, and the player decodes the MP3 it gets.
    @Test func aStreamedSongInTheDefaultFormatPlaysAsItArrives() async throws {
        let rig = CreativeRig()
        defer { rig.clean() }
        let music = rig.session.music
        #expect(music.outputFormat == "auto")
        music.prompt = "Lo-fi"
        #expect(music.composeArguments()["output_format"] == nil)
        music.outputFormat = "mp3_44100_128"
        #expect(music.composeArguments()["output_format"] == "mp3_44100_128")
        music.outputFormat = "opus_48000_64"
        music.delivery = .stream
        #expect(!music.streamsLive)
        music.outputFormat = "auto"
        #expect(music.streamsLive)

        rig.always(MusicScreenModel.composeStream, .init(
            status: 200, headers: ["content-type": "audio/mpeg"], body: Data(count: 300),
            chunks: [Data(count: 100), Data(count: 100), Data(count: 100)], delay: .seconds(5)
        ))
        let running = Task { await music.composeSong() }
        let runner = music.runner(MusicScreenModel.composeStream)
        try await CreativeRig.waitUntil { runner.streamPlayer != nil }
        #expect(runner.streamPlayer?.problem == nil, "\(runner.streamPlayer?.problem ?? "")")
        #expect(rig.requests(MusicScreenModel.composeStream).first?.request.url.query == nil)
        runner.cancel()
        await running.value
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

    // MARK: - Isolation

    @Test func isolationPagesItsHistoryOnlyWithASearchAndConfirmsDeletes() async throws {
        let rig = CreativeRig()
        defer { rig.clean() }
        rig.always(IsolationScreenModel.history, .json(["items": [
            ["id": "iso1", "title": "Interview", "created_at_unix": 1_790_000_000, "format": "mp3", "duration_seconds": 64,
             "download_url": nil, "icon_url": nil, "source_video_url": nil, "supports_video": false, "processing": false,
             "video_processing_failed": false, "preview_b64": nil],
        ], "has_more": true]))
        let isolation = rig.session.isolation
        #expect(isolation.historyArguments(page: 3) == ["page_size": 50])
        isolation.search = "inter"
        #expect(isolation.historyArguments(page: 3) == ["page_size": 50, "search": "inter", "page": 3])
        isolation.search = ""
        await isolation.refreshHistory()
        #expect(isolation.items.map(\.title) == ["Interview"])
        #expect(isolation.hasMore)
        await isolation.loadMoreHistory()
        #expect(isolation.pageSize == 100, "without a search, more means a bigger first page")

        let deleting = Task { await isolation.delete(isolation.items[0]) }
        try await CreativeRig.waitUntil { isolation.deleteRunner.phase == .awaitingConfirmation }
        #expect(isolation.deleteRunner.confirmation?.title == "Delete the isolation “Interview”?")
        isolation.deleteRunner.decline()
        await deleting.value
        #expect(rig.requests(IsolationScreenModel.delete).isEmpty)
        #expect(isolation.items.count == 1)
    }

    @Test func anIsolationKeepsTheRecordingItCameFrom() async throws {
        let rig = CreativeRig()
        defer { rig.clean() }
        rig.always(IsolationScreenModel.full, .audio(CreativeRig.wavData(seconds: 0.5), contentType: "audio/wav"))
        let isolation = rig.session.isolation
        isolation.source = rig.wav(named: "noisy.wav")
        await isolation.isolate()
        let take = try #require(isolation.takes.first)
        #expect(isolation.sources[take.id]?.lastPathComponent == "noisy.wav")
        #expect(rig.lastMultipart(IsolationScreenModel.full)?.contains(#"name="audio"; filename="noisy.wav""#) == true)
    }

    // MARK: - Transcription

    @Test func transcriptionChecksTheRulesItsArgumentsState() {
        let rig = CreativeRig()
        defer { rig.clean() }
        let stt = rig.session.transcription
        #expect(stt.modelID == "scribe_v2")
        #expect(stt.problems == ["Choose a file to transcribe."])
        stt.sourceKind = .link
        stt.sourceLink = "http://example.com/a.mp3"
        #expect(stt.problems == ["Paste an https link to the audio or video."])
        stt.sourceLink = "https://example.com/a.mp3"
        stt.detectSpeakerRoles = true
        #expect(stt.problems.contains("Speaker roles need “Who is speaking” on."))
        stt.diarize = true
        stt.entityRedaction = ["pii"]
        #expect(stt.problems.contains { $0.hasPrefix("Only detected entities") })
        stt.entityDetection = ["pii", "pci"]
        stt.transcriptEdit = "Fix names"
        #expect(stt.problems.contains { $0.hasPrefix("An edit instruction cannot") })
        stt.transcriptEdit = ""
        stt.webhookMetadata = "[1]"
        #expect(stt.problems.contains("Webhook metadata must be a JSON object."))
        stt.webhookMetadata = #"{"job": 1}"#
        #expect(stt.problems.isEmpty)
    }

    @Test func transcriptionWithEveryOptionSendsOnlyWhatTheOperationTakes() throws {
        let rig = CreativeRig()
        defer { rig.clean() }
        let stt = rig.session.transcription
        stt.source = rig.wav()
        stt.languageCode = "en"
        stt.tagAudioEvents = false
        stt.timestampsGranularity = "character"
        stt.diarize = true
        stt.usesDiarizationThreshold = true
        stt.useSpeakerLibrary = true
        stt.keyterms = ["ElevenLabs", "Scribe"]
        stt.entityDetection = ["pii", "phi"]
        stt.entityRedaction = ["pii"]
        stt.entityRedactionMode = "redacted"
        stt.additionalFormats = ["srt", "pdf"]
        stt.usesTemperature = true
        stt.temperature = 0.5
        stt.seed = 1
        stt.noVerbatim = true
        stt.rawPCMInput = true
        stt.sendsToWebhook = true
        stt.webhookID = "wh1"
        stt.webhookMetadata = #"{"job": 1}"#
        stt.enableLogging = false
        let arguments = stt.arguments()
        #expect(arguments["entity_detection"] == ["phi", "pii"])
        #expect(arguments["entity_redaction"] == "pii")
        #expect(arguments["diarization_threshold"] != nil)
        #expect(arguments["additional_formats"]?.arrayValue?.count == 2)
        #expect(arguments["webhook_metadata"] == .string(#"{"job": 1}"#))
        let operation = try #require(ElevenLabsCatalog.operation(TranscriptionScreenModel.convert))
        #expect(CreativeSpec.unknownArguments(arguments, for: operation).isEmpty)
        #expect(rig.client.validate(operation.id, arguments: arguments, files: stt.files()).isEmpty)
        stt.numSpeakers = 3
        #expect(stt.arguments()["diarization_threshold"] == nil, "the threshold only goes with an open speaker count")
        #expect(TranscriptionScreenModel.entitySelection(["all", "pii"]) == "all")
    }

    @Test func aTranscriptIsShownWithSpeakersEntitiesAndExports() async throws {
        let rig = CreativeRig()
        defer { rig.clean() }
        rig.always(TranscriptionScreenModel.convert, .json([
            "language_code": "en", "language_probability": 0.98, "text": "Hi Ann. Hello.",
            "transcription_id": "tr-1", "audio_duration_secs": 2,
            "words": [
                ["text": "Hi", "start": 0.0, "end": 0.2, "type": "word", "speaker_id": "speaker_0", "logprob": 0],
                ["text": "Ann.", "start": 0.3, "end": 0.6, "type": "word", "speaker_id": "speaker_0", "logprob": 0],
                ["text": "Hello.", "start": 1.0, "end": 1.4, "type": "word", "speaker_id": "speaker_1", "logprob": 0],
            ],
            "entities": [["text": "Ann", "entity_type": "person_name", "start_char": 3, "end_char": 6]],
            "additional_formats": [["requested_format": "srt", "file_extension": "srt", "content_type": "text/srt",
                                    "is_base64_encoded": true, "content": .string(Data("1\n".utf8).base64EncodedString())]],
        ]))
        let stt = rig.session.transcription
        stt.source = rig.wav(named: "call.wav")
        stt.diarize = true
        await stt.transcribe()
        #expect(stt.runner.phase == .succeeded, "\(stt.runner.errorMessage ?? "")")
        #expect(stt.words.map(\.speaker) == ["speaker_0", "speaker_0", "speaker_1"])
        #expect(stt.entities == [TranscriptEntity(text: "Ann", type: "person_name", start: 3, end: 6)])
        #expect(stt.exports.first?.data == Data("1\n".utf8))
        #expect(stt.records.map(\.id) == ["tr-1"])
        #expect(stt.transcriptAudio?.lastPathComponent == "call.wav")
        #expect(stt.fullText == "Hi Ann. Hello.")
        #expect(rig.lastMultipart(TranscriptionScreenModel.convert)?.contains(#"name="diarize""#) == true)
    }

    @Test func aTranscriptSentToAWebhookIsKeptToFetchLater() async throws {
        let rig = CreativeRig()
        defer { rig.clean() }
        rig.always(TranscriptionScreenModel.convert, .json(["message": "Accepted", "request_id": "r", "transcription_id": "tr-2"]))
        rig.always(TranscriptionScreenModel.get, .json(["language_code": "en", "language_probability": 1, "text": "Later.",
                                                        "words": [], "transcription_id": "tr-2"]))
        let stt = rig.session.transcription
        stt.sourceKind = .link
        stt.sourceLink = "https://example.com/talk.mp3"
        stt.sendsToWebhook = true
        await stt.transcribe()
        #expect(stt.records.first?.pending == true)
        #expect(stt.transcript == nil)
        await stt.open("tr-2")
        #expect(stt.fullText == "Later.")
        #expect(stt.records.first?.pending == false)
        #expect(rig.requests(TranscriptionScreenModel.get).first?.request.url.path == "/v1/speech-to-text/transcripts/tr-2")

        let deleting = Task { await stt.delete(stt.records[0]) }
        try await CreativeRig.waitUntil { stt.deleteRunner.phase == .awaitingConfirmation }
        #expect(stt.deleteRunner.confirmation?.title == "Delete the transcript “https://example.com/talk.mp3”?")
        stt.deleteRunner.decline()
        await deleting.value
        #expect(rig.requests(TranscriptionScreenModel.delete).isEmpty)
    }

    /// Every price the notes quote is the spec's, word for word, from the pinned snapshot (the
    /// catalog shortens long descriptions): a price change in the spec fails here.
    @Test func thePricesTheCostNotesQuoteAreTheSpecs() throws {
        #expect(!CreativeRig.rawSpec.isEmpty, "the pinned spec could not be read")
        for surcharge in TranscriptionScreenModel.surcharges {
            let text = CreativeRig.rawBodyDescription(TranscriptionScreenModel.convert, surcharge.argument)
            #expect(text.contains(surcharge.evidence), "\(surcharge.argument) no longer says “\(surcharge.evidence)”")
            #expect(surcharge.evidence.contains("\(surcharge.percent)%"))
        }
        for rule in TranscriptionScreenModel.priceRules {
            let text = CreativeRig.rawBodyDescription(TranscriptionScreenModel.convert, rule.argument)
            #expect(text.contains(rule.evidence), "\(rule.argument) no longer says “\(rule.evidence)”")
        }
        #expect(TranscriptionScreenModel.priceRules.contains { $0.evidence.contains("maximum of \(TranscriptionScreenModel.maxChannels) channels") })
        #expect(TranscriptionScreenModel.priceRules.contains {
            $0.evidence.contains("more than \(TranscriptionScreenModel.keytermMinimumAbove) keyterms")
                && $0.evidence.contains("\(TranscriptionScreenModel.keytermMinimumSeconds) seconds")
        })
        #expect(TranscriptionScreenModel.surcharges.contains { $0.evidence.contains("at least \(TranscriptionScreenModel.editMinimumSeconds) seconds") })
        let upload = try #require(CreativeRig.rawOperation(MusicScreenModel.upload))
        let uploadText = upload["description"] as? String ?? ""
        for price in MusicScreenModel.uploadPrice {
            #expect(uploadText.contains(price.evidence), "upload no longer says “\(price.evidence)”")
        }
    }

    /// The transcription note follows the choices: each channel at full length with one speaker
    /// per channel, then the surcharges that apply, with their minimums.
    @Test func theTranscriptionCostNoteFollowsTheChoices() throws {
        let rig = CreativeRig()
        defer { rig.clean() }
        let stt = rig.session.transcription
        stt.source = rig.wav(named: "call.wav", seconds: 2, channels: 2)
        #expect(stt.costNote == nil)
        #expect(stt.billedSeconds == 2)
        stt.useMultiChannel = true
        #expect(stt.billedChannels == 2)
        #expect(stt.billedSeconds == 4)
        #expect(stt.costNote?.contains("each of the 2 channels is billed at the full length") == true)
        stt.useMultiChannel = false
        stt.keyterms = ["Scribe"]
        stt.entityDetection = ["pii"]
        stt.entityRedaction = ["pii"]
        #expect(stt.costNote == "On the base cost: +20% key terms, +30% entity detection, +30% redaction.")
        stt.keyterms = (0...100).map { "term\($0)" }
        #expect(stt.costNote?.contains("at least 20 s billed with over 100 terms") == true)
        stt.keyterms = []
        stt.entityDetection = []
        stt.entityRedaction = []
        stt.diarize = true
        stt.detectSpeakerRoles = true
        stt.transcriptEdit = "Fix names"
        #expect(stt.costNote == "On the base cost: +10% speaker roles, +30% edit instruction (on at least 10 s).")
        stt.sourceKind = .link
        stt.sourceLink = "https://example.com/a.mp3"
        stt.useMultiChannel = true
        #expect(stt.billedSeconds == nil)
        #expect(stt.costNote?.contains("each channel (up to 5) is billed at the full length") == true)
        #expect(MusicScreenModel.uploadCostNote.hasPrefix("Costs as much as generating a song this long"))
    }

    // MARK: - Alignment

    @Test func anAlignmentComesBackAsTimedWordsWithTheirFit() async throws {
        let rig = CreativeRig()
        defer { rig.clean() }
        rig.always(AlignmentScreenModel.align, .json(["loss": 0.12, "characters": [["text": "H", "start": 0, "end": 0.1]], "words": [
            ["text": "Hello", "start": 0.1, "end": 0.5, "loss": 0.05],
            ["text": "world", "start": 0.6, "end": 1.0, "loss": 0.3],
        ]]))
        let alignment = rig.session.alignment
        #expect(alignment.problems.count == 2)
        alignment.source = rig.wav(named: "read.wav")
        alignment.text = "Hello world"
        await alignment.align()
        #expect(alignment.words.map(\.text) == ["Hello", "world"])
        #expect(alignment.loss == 0.12)
        #expect(alignment.weakestWords.first?.text == "world")
        #expect(alignment.alignedAudio?.lastPathComponent == "read.wav")
        let body = try #require(rig.lastMultipart(AlignmentScreenModel.align))
        #expect(body.contains(#"name="text""#) && body.contains("Hello world"))
    }

    @Test func alignmentCanTakeTheTranscriptOnScreen() {
        let rig = CreativeRig()
        defer { rig.clean() }
        let audio = rig.wav()
        rig.session.transcription.show(["text": "From Scribe.", "words": []], title: "t", audio: audio)
        rig.session.alignment.useTranscriptionText()
        #expect(rig.session.alignment.text == "From Scribe.")
        #expect(rig.session.alignment.source == audio)
    }

    // MARK: - History

    @Test func historyFiltersBecomeArgumentsAndPagesFollowTheLastItem() async throws {
        let rig = CreativeRig()
        defer { rig.clean() }
        rig.queue(HistoryScreenModel.list,
                  .json(["history": [Self.historyItem("h1"), Self.historyItem("h2")], "has_more": true, "last_history_item_id": "h2"]),
                  .json(["history": [Self.historyItem("h3")], "has_more": false]))
        let history = rig.session.history
        history.search = "hello"
        history.voiceID = "voice-rachel"
        history.source = "TTS"
        history.sortDirection = "asc"
        history.since = Date(timeIntervalSince1970: 1_700_000_000)
        let arguments = history.listArguments()
        #expect(arguments["date_after_unix"] == 1_700_000_000)
        #expect(arguments["page_size"] == 100)
        #expect(CreativeSpec.unknownArguments(arguments, for: try #require(ElevenLabsCatalog.operation(HistoryScreenModel.list))).isEmpty)
        await history.refresh()
        #expect(history.items.map(\.id) == ["h1", "h2"])
        #expect(history.hasMore)
        await history.loadMore()
        #expect(history.items.map(\.id) == ["h1", "h2", "h3"])
        #expect(!history.hasMore)
        let query = try #require(rig.requests(HistoryScreenModel.list).last?.request.url.query)
        #expect(query.contains("start_after_history_item_id=h2"))
        #expect(history.items[0].characters == 12)
    }

    @Test func historyItemsPlayDownloadDeleteAndGoBackToSpeech() async throws {
        let rig = CreativeRig()
        defer { rig.clean() }
        rig.always(HistoryScreenModel.list, .json(["history": [Self.historyItem("h1"), Self.historyItem("h2")], "has_more": false]))
        rig.always(HistoryScreenModel.audio, .audio(CreativeRig.wavData(seconds: 0.3), contentType: "audio/wav"))
        rig.always(HistoryScreenModel.download, .init(status: 200, headers: ["content-type": "application/zip"], body: Data("PK".utf8)))
        let history = rig.session.history
        await history.refresh()
        await history.fetchAudio(history.items[0])
        #expect(history.audioFiles["h1"] != nil)
        history.selection = ["h2", "h1"]
        history.downloadFormat = "wav"
        #expect(history.downloadArguments() == ["history_item_ids": ["h1", "h2"], "output_format": "wav"])
        await history.downloadSelected()
        #expect(history.download?.pathExtension == "zip")

        let deleting = Task { await history.delete(history.items[1]) }
        try await CreativeRig.waitUntil { history.deleteRunner.phase == .awaitingConfirmation }
        #expect(history.deleteRunner.confirmation?.title == "Delete the history item “Hello from h2”?")
        history.deleteRunner.decline()
        await deleting.value
        #expect(rig.requests(HistoryScreenModel.delete).isEmpty)

        history.reuseInSpeech(history.items[0])
        #expect(rig.session.speech.text == "Hello from h1")
        #expect(rig.session.speech.voiceID == "voice-rachel")
        #expect(rig.session.speech.modelID == "eleven_flash_v2_5")
    }

    // MARK: - Models

    @Test func modelsAreReadAndFilteredByWhatTheyCanDoAndSpeak() async {
        let rig = CreativeRig()
        defer { rig.clean() }
        rig.always(ModelsScreenModel.list, .json(CreativeRig.modelsJSON))
        let screen = rig.session.modelsScreen
        await screen.directory.loadIfNeeded()
        #expect(screen.shown.count == 3)
        screen.required = [.voiceConversion]
        #expect(screen.shown.map(\.id) == ["eleven_english_sts_v2"])
        screen.required = []
        screen.search = "japanese"
        #expect(screen.shown.map(\.id) == ["eleven_multilingual_v2"])
        let flash = rig.session.models.model(id: "eleven_flash_v2_5")
        #expect(flash?.characterCostMultiplier == 0.5)
        #expect(flash?.languageSummary == ListFormatter.localizedString(byJoining: ["English", "French"]))
        await screen.directory.loadIfNeeded()
        #expect(rig.requests(ModelsScreenModel.list).count == 1, "fetched once per session")
        screen.useForSpeech(flash!)
        #expect(rig.session.speech.modelID == "eleven_flash_v2_5")
    }

    // MARK: - One paid run at a time

    /// Changing how a take is delivered while one runs used to hand the Run row an idle runner:
    /// Generate came back, a second paid request went out, and Cancel no longer reached the
    /// first. Now the row keeps the run in flight, a second start is refused, and Cancel stops it.
    @Test func switchingWhatRunsMidRunNeitherBillsTwiceNorLosesCancel() async throws {
        let rig = CreativeRig()
        defer { rig.clean() }
        var slow = FakeElevenLabsTransport.Reply.audio(CreativeRig.wavData(seconds: 0.2), contentType: "audio/wav")
        slow.delay = .seconds(5)
        for id in [SpeechScreenModel.full, DialogueScreenModel.full, VoiceChangerScreenModel.full,
                   IsolationScreenModel.full, MusicScreenModel.compose] {
            rig.always(id, slow)
        }

        let speech = rig.session.speech
        speech.voiceID = "voice-rachel"
        speech.text = "Hi."
        try await Self.oneRunAtATime(
            rig: rig, operations: SpeechScreenModel.operationIDs, start: { await speech.generate() },
            busy: { speech.busyRunner }, active: { speech.activeRunner },
            flip: { speech.timestamps = true; speech.delivery = .stream },
            refused: { speech.problems.contains(SpeechScreenModel.busyProblem) }
        )

        let dialogue = rig.session.dialogue
        dialogue.lines = [DialogueLine(voiceID: "voice-rachel", text: "Hi."), DialogueLine(voiceID: "voice-adam", text: "Hello.")]
        try await Self.oneRunAtATime(
            rig: rig, operations: DialogueScreenModel.operationIDs, start: { await dialogue.generate() },
            busy: { dialogue.busyRunner }, active: { dialogue.activeRunner },
            flip: { dialogue.timestamps = true },
            refused: { dialogue.problems.contains(DialogueScreenModel.busyProblem) }
        )

        let changer = rig.session.voiceChanger
        changer.source = rig.wav(named: "me.wav")
        changer.voiceID = "voice-adam"
        try await Self.oneRunAtATime(
            rig: rig, operations: VoiceChangerScreenModel.operationIDs, start: { await changer.generate() },
            busy: { changer.busyRunner }, active: { changer.activeRunner },
            flip: { changer.delivery = .stream },
            refused: { changer.problems.contains(VoiceChangerScreenModel.busyProblem) }
        )

        let isolation = rig.session.isolation
        isolation.source = rig.wav(named: "noisy.wav")
        try await Self.oneRunAtATime(
            rig: rig, operations: [IsolationScreenModel.full, IsolationScreenModel.stream], start: { await isolation.isolate() },
            busy: { isolation.busyRunner }, active: { isolation.activeRunner },
            flip: { isolation.delivery = .stream },
            refused: { isolation.problems.contains(IsolationScreenModel.busyProblem) }
        )

        let music = rig.session.music
        music.prompt = "Lo-fi"
        try await Self.oneRunAtATime(
            rig: rig, operations: MusicScreenModel.composeIDs, start: { await music.composeSong() },
            busy: { music.busyRunner }, active: { music.activeComposeRunner },
            flip: { music.delivery = .detailed },
            refused: { music.composeProblems.contains(MusicScreenModel.busyProblem) }
        )
    }

    /// Starts a run, flips what would run, tries again, and cancels from what the Run row shows.
    static func oneRunAtATime(
        rig: CreativeRig, operations: [String], start: @escaping @MainActor () async -> Void,
        busy: @MainActor () -> ElevenLabsRunner?, active: @MainActor () -> ElevenLabsRunner,
        flip: @MainActor () -> Void, refused: @MainActor () -> Bool
    ) async throws {
        func sent() -> Int { operations.reduce(0) { $0 + rig.requests($1).count } }
        let first = Task { await start() }
        try await CreativeRig.waitUntil { busy() != nil && sent() == 1 }
        let running = try #require(busy())
        flip()
        #expect(active() === running, "the Run row must keep showing the run in flight")
        #expect(refused(), "the screen must say why it cannot start another")
        await start()
        #expect(sent() == 1, "\(operations[0]): a second paid request went out while the first ran")
        active().cancel()
        await first.value
        #expect(running.phase == .cancelled, "\(operations[0]): Cancel did not reach the run in flight")
        #expect(busy() == nil)
    }

    // MARK: - Controls

    @Test func finelySteppedSlidersRoundInsteadOfDrawingTicks() {
        #expect(abs(CreativeSlider.snapped(0.337, to: 0.01, in: 0...1) - 0.34) < 1e-9)
        #expect(CreativeSlider.snapped(1.3, to: 0.01, in: 0.7...1.2) == 1.2)
        #expect(abs(CreativeSlider.snapped(15.4, to: 1, in: 3...120) - 15) < 1e-9)
        #expect(CreativeSlider.snapped(0.123, to: nil, in: 0...1) == 0.123)
    }

    @Test func outputFormatsAreNamedAndRawTakesPlayAtTheirRate() {
        #expect(CreativeOutputFormat.title("mp3_44100_128") == "MP3 · 44.1 kHz · 128 kbps")
        #expect(CreativeOutputFormat.title("mp3_22050_32") == "MP3 · 22.05 kHz · 32 kbps")
        #expect(CreativeOutputFormat.title("pcm_16000") == "PCM · 16 kHz")
        #expect(CreativeOutputFormat.title("ulaw_8000") == "μ-law · 8 kHz")
        #expect(CreativeOutputFormat.title("auto") == "Automatic")
        // Streams: the shell's player decodes MP3 and raw PCM as they arrive, nothing else.
        #expect(CreativeOutputFormat.playsLive("mp3_44100_128"))
        #expect(CreativeOutputFormat.playsLive("pcm_24000"))
        #expect(!CreativeOutputFormat.playsLive("ulaw_8000"))
        #expect(!CreativeOutputFormat.playsLive("opus_48000_64"))
        #expect(!CreativeOutputFormat.playsLive("auto"), "the stream player cannot read a format named auto")
        // A finished raw take goes to the shell's raw player, at the rate the run asked for.
        #expect(CreativeAudioResult(url: URL(fileURLWithPath: "take.pcm"), contentType: "audio/pcm").isRaw)
        #expect(CreativeAudioResult(url: URL(fileURLWithPath: "take.ulaw"), contentType: "application/octet-stream").isRaw)
        #expect(!CreativeAudioResult(url: URL(fileURLWithPath: "take.mp3"), contentType: "audio/mpeg").isRaw)
        #expect(CreativeTimedPlayer.rawFormat(url: URL(fileURLWithPath: "take.pcm"), contentType: "audio/pcm", outputFormat: "pcm_22050")
                == ElevenLabsRawAudio.Format(encoding: .pcm16, sampleRate: 22_050))
        #expect(CreativeTimedPlayer.rawFormat(url: URL(fileURLWithPath: "take.ulaw"), contentType: "audio/basic", outputFormat: nil)
                == ElevenLabsRawAudio.Format(encoding: .ulaw, sampleRate: 8_000))
        #expect(CreativeTimedPlayer.rawFormat(url: URL(fileURLWithPath: "take.mp3"), contentType: "audio/mpeg", outputFormat: "mp3_44100_128") == nil)
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

    /// The session lives in the pane's section store, so another account's client — a new key,
    /// a region change — starts every creative screen over, and a disconnect drops it too.
    @Test func anotherAccountStartsTheScreensOver() {
        let transport = FakeElevenLabsTransport(replies: [])
        func client() -> ElevenLabsClient {
            ElevenLabsClient(credentials: FakeCredentialSource(key: "k"), region: .global,
                             transport: transport, sink: TemporaryFileSink())
        }
        let holder = ClientHolder(client())
        let pane = ElevenLabsPaneState(defaults: nil, client: { holder.client })
        let context = ElevenLabsRunner.Context(client: { holder.client })
        let linked = CreativeSession.shared(in: pane, context: context)
        linked.speech.text = "Mine"
        #expect(CreativeSession.shared(in: pane, context: context) === linked)
        holder.client = client()
        let other = CreativeSession.shared(in: pane, context: context)
        #expect(other !== linked)
        #expect(other.speech.text.isEmpty)
        pane.reset()
        #expect(CreativeSession.shared(in: pane, context: context) !== other, "a disconnect drops it")
    }

    @MainActor final class ClientHolder {
        var client: ElevenLabsClient?
        init(_ client: ElevenLabsClient) { self.client = client }
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
