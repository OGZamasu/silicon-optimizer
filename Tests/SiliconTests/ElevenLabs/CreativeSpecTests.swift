import Foundation
import SiliconElevenLabs
import Testing
@testable import SiliconUI

/// The creative screens against the pinned catalog: every control names a real argument of
/// a real operation, every operation of the ten sections is reachable from its screen, and
/// every range or value the schema leaves out still has its evidence in the spec.
@Suite("ElevenLabs creative sections against the catalog")
@MainActor
struct CreativeSpecTests {

    /// The screen model built for each creative section.
    static func model(for section: ElevenLabsSection) -> (any CreativeScreenModel.Type)? {
        switch section {
        case .speech: SpeechScreenModel.self
        case .dialogue: DialogueScreenModel.self
        case .voiceChanger: VoiceChangerScreenModel.self
        case .soundEffects: SoundEffectsScreenModel.self
        case .music: MusicScreenModel.self
        case .isolation: IsolationScreenModel.self
        case .transcription: TranscriptionScreenModel.self
        case .alignment: AlignmentScreenModel.self
        default: nil
        }
    }

    @Test(arguments: [ElevenLabsSection.speech, .dialogue, .voiceChanger, .soundEffects, .music, .isolation, .transcription, .alignment])
    func everyControlSetsARealArgumentOfARealOperation(section: ElevenLabsSection) throws {
        let model = try #require(Self.model(for: section))
        for control in model.controls {
            #expect(!control.operations.isEmpty, "\(section): “\(control.label)” names no operation")
            for operation in control.operations {
                #expect(ElevenLabsCatalog.operation(operation) != nil,
                        "\(section): “\(control.label)” is sent to \(operation), which the catalog does not have")
                #expect(CreativeSpec.has(operation, control.argument),
                        "\(section): “\(control.label)” sets \(control.argument), which \(operation) does not take")
            }
        }
    }

    @Test(arguments: [ElevenLabsSection.speech, .dialogue, .voiceChanger, .soundEffects, .music, .isolation, .transcription, .alignment])
    func everyOperationOfTheSectionIsReachableFromItsScreen(section: ElevenLabsSection) throws {
        let model = try #require(Self.model(for: section))
        let claimed = Set(section.operations.map(\.id))
        #expect(!claimed.isEmpty, "\(section) has no operations in the catalog")
        let reached = Set(model.operationIDs)
        #expect(claimed.subtracting(reached).isEmpty,
                "\(section) does not reach \(claimed.subtracting(reached).sorted())")
        for id in model.operationIDs {
            #expect(ElevenLabsCatalog.operation(id) != nil, "\(section) runs \(id), which the catalog does not have")
        }
    }

    /// The operations a screen reaches outside its own section are reads it needs (voice
    /// settings, pronunciation dictionaries) — never something that spends or changes.
    @Test func operationsBorrowedFromOtherSectionsAreFreeReads() throws {
        for id in ["get_voice_settings", "get_pronunciation_dictionaries_metadata"] {
            let operation = try #require(ElevenLabsCatalog.operation(id))
            #expect(operation.risk == .read)
            #expect(!operation.billable)
        }
    }

    // MARK: - Ranges and values the schema leaves out

    @Test(arguments: Array(CreativeSpec.fallbackRanges.keys))
    func everyFallbackRangeStillHasItsEvidence(key: String) throws {
        let fallback = try #require(CreativeSpec.fallbackRanges[key])
        let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
        // A wildcard applies only where the operation's own schema leaves the range out.
        let operations = parts[0] == "*"
            ? Self.operationsTaking(parts[1]).filter { CreativeSpec.schemaRange($0, parts[1]) == nil }
            : [parts[0]]
        #expect(!operations.isEmpty, "\(key) matches no operation")
        switch fallback.evidence {
        case .description(let snippet):
            for operation in operations {
                let schema = try #require(CreativeSpec.schema(operation, parts[1]))
                let text = (schema["description"].stringValue ?? "") + " "
                    + (CreativeSpec.normalized(schema)["description"].stringValue ?? "")
                #expect(text.contains(snippet), "\(operation).\(parts[1])'s description no longer says “\(snippet)”")
            }
        case .boundedIn(let operationID, let property):
            let bounds = Self.bounds(of: property, in: try #require(ElevenLabsCatalog.operation(operationID)))
            #expect(bounds.contains(fallback.range),
                    "\(operationID) no longer bounds \(property) at \(fallback.range): \(bounds)")
        }
    }

    @Test func aRangeInTheSchemaWinsOverTheFallback() {
        // `stability` is bounded in the schema itself; `speed` only by the fallback.
        #expect(CreativeSpec.schemaRange("text_to_speech_full", "voice_settings.stability") == 0...1)
        #expect(CreativeSpec.schemaRange("text_to_speech_full", "voice_settings.speed") == nil)
        #expect(CreativeSpec.range("text_to_speech_full", "voice_settings.speed") == 0.7...1.2)
        #expect(CreativeSpec.range("generate", "music_length_ms") == 3000...600_000)
        // Seeds differ by family: the schema's own for music, each description's elsewhere.
        #expect(CreativeSpec.range("generate", "seed") == 0...2_147_483_647)
        #expect(CreativeSpec.range("text_to_speech_full", "seed") == 0...4_294_967_295)
        #expect(CreativeSpec.range("speech_to_speech_full", "seed") == 0...4_294_967_295)
        #expect(CreativeSpec.range("speech_to_text", "seed") == 0...2_147_483_647)
    }

    @Test(arguments: Array(CreativeSpec.documentedValues.keys))
    func everyDocumentedValueIsStillInTheDescription(key: String) throws {
        let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
        let schema = try #require(CreativeSpec.schema(parts[0], parts[1]))
        let text = (schema["description"].stringValue ?? "") + " "
            + (CreativeSpec.normalized(schema)["description"].stringValue ?? "")
        for (value, evidence) in CreativeSpec.documentedValues[key] ?? [] {
            #expect(text.contains(evidence), "\(key): the description no longer lists \(value)")
        }
    }

    /// Dialogue's two limits come from the `inputs` description.
    @Test func dialogueLimitsAreTheOnesTheSpecStates() throws {
        let schema = try #require(CreativeSpec.schema(DialogueScreenModel.full, "inputs"))
        let text = schema["description"].stringValue ?? ""
        #expect(text.contains("maximum number of unique voice IDs is \(DialogueScreenModel.maxVoices)"))
        #expect(text.contains(DialogueScreenModel.recommendedCharacters.formatted(.number.locale(Locale(identifier: "en_US")))))
    }

    // MARK: - The lookups themselves

    @Test func argumentsAreFoundAcrossParametersBodiesListsAndUnions() {
        #expect(CreativeSpec.has("text_to_speech_full", "voice_id"))                     // path
        #expect(CreativeSpec.has("text_to_speech_full", "output_format"))                // query
        #expect(CreativeSpec.has("text_to_speech_full", "voice_settings.stability"))     // nested, nullable
        #expect(CreativeSpec.has("text_to_dialogue", "inputs[].voice_id"))               // list items
        #expect(CreativeSpec.has("speech_to_text", "additional_formats[].format"))       // union items
        #expect(!CreativeSpec.has("text_to_speech_full", "voice_settings.loudness"))
        #expect(!CreativeSpec.has("text_to_speech_full", "voice"))
        #expect(!CreativeSpec.has("no_such_operation", "text"))
    }

    @Test func choicesDefaultsAndExamplesComeFromTheSchema() {
        #expect(CreativeSpec.choices("text_to_speech_full", "output_format").contains("wav_44100"))
        #expect(!CreativeSpec.choices("text_to_speech_stream", "output_format").contains("wav_44100"))
        #expect(CreativeSpec.defaultString("text_to_speech_full", "output_format") == "mp3_44100_128")
        #expect(CreativeSpec.defaultNumber("sound_generation", "prompt_influence") == 0.3)
        #expect(CreativeSpec.defaultNumber("text_to_speech_full", "voice_settings.stability") == 0.5)
        #expect(CreativeSpec.examples("speech_to_text", "model_id").contains("scribe_v2"))
        #expect(Set(CreativeSpec.variantTags("speech_to_text", "additional_formats[]", tag: "format"))
                .isSuperset(of: ["srt", "txt", "pdf"]))
        #expect(CreativeSpec.excludesLowerBound("generate", "finetune_strength"))
    }

    @Test func unknownArgumentsAreNamedDownToTheNestedKey() throws {
        let operation = try #require(ElevenLabsCatalog.operation("text_to_speech_full"))
        let unknown = CreativeSpec.unknownArguments([
            "voice_id": "v", "text": "Hi", "voice": "v",
            "voice_settings": ["stability": 0.5, "loudness": 2],
            "pronunciation_dictionary_locators": [["pronunciation_dictionary_id": "d", "revision": "r"]],
        ], for: operation)
        #expect(unknown == ["pronunciation_dictionary_locators[].revision", "voice", "voice_settings.loudness"])
    }

    // MARK: - Helpers

    /// Every operation in the catalog that takes `path`.
    static func operationsTaking(_ path: String) -> [String] {
        ElevenLabsCatalog.all.map(\.id).filter { CreativeSpec.has($0, path) }
    }

    /// Every `minimum...maximum` a property named `property` carries anywhere in `operation`.
    static func bounds(of property: String, in operation: ElevenLabsOperation) -> [ClosedRange<Double>] {
        var found: [ClosedRange<Double>] = []
        func walk(_ value: JSONValue) {
            switch value {
            case .object(let object):
                if let properties = object["properties"]?.objectValue, let target = properties[property] {
                    let concrete = CreativeSpec.normalized(target)
                    if let low = concrete["minimum"].doubleValue, let high = concrete["maximum"].doubleValue {
                        found.append(low...high)
                    }
                }
                object.values.forEach(walk)
            case .array(let array):
                array.forEach(walk)
            default:
                break
            }
        }
        walk(operation.body?.schema ?? .null)
        return found
    }
}
