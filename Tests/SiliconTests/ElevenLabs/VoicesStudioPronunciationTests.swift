import Foundation
import Testing
@testable import SiliconElevenLabs
@testable import SiliconUI

/// Pronunciation dictionaries: rules shaped as the spec's alias or phoneme union, incomplete
/// rows named before anything is sent, a dictionary from a PLS file, rule edits, and the PLS
/// download of the latest version.
@Suite("ElevenLabs pronunciation section")
@MainActor
struct VoicesStudioPronunciationTests {

    static func dictionary(_ id: String, rules: [JSONValue] = []) -> JSONValue {
        ["id": .string(id), "latest_version_id": "ver1", "latest_version_rules_num": .number(Double(rules.count)),
         "name": "Place names", "permission_on_resource": "admin", "created_by": "u1",
         "creation_time_unix": 1_780_000_000, "description": "How to say the towns.", "rules": .array(rules)]
    }

    @Test func rulesAreAliasesOrPhonemesAndIncompleteOnesAreNamed() throws {
        let fixture = VoicesStudioFixture()
        defer { fixture.clean() }
        let model = PronunciationSectionModel(environment: fixture.environment)
        #expect(model.createArguments().3 == ["Give the dictionary a name.", "Write at least one rule."])
        model.newName = "Place names"
        var alias = PronunciationRule()
        alias.stringToReplace = "Worcestershire"
        alias.alias = "Wooster-sheer"
        var phoneme = PronunciationRule()
        phoneme.kind = .phoneme
        phoneme.stringToReplace = "Edinburgh"
        phoneme.phoneme = "ˈɛdɪnbərə"
        phoneme.wordBoundaries = false
        var incomplete = PronunciationRule()
        incomplete.stringToReplace = "Loughborough"
        model.rules = [alias, phoneme, incomplete, PronunciationRule()]
        #expect(model.createArguments().3 == ["Rule 3 needs the text to replace and its alias."])
        model.rules.remove(at: 2)
        let (arguments, files, operation, problems) = model.createArguments()
        #expect(problems.isEmpty)
        #expect(operation == "add_from_rules")
        #expect(files.isEmpty)
        #expect(arguments["rules"] == [
            ["string_to_replace": "Worcestershire", "type": "alias", "alias": "Wooster-sheer",
             "case_sensitive": true, "word_boundaries": true],
            ["string_to_replace": "Edinburgh", "type": "phoneme", "phoneme": "ˈɛdɪnbərə", "alphabet": "ipa",
             "case_sensitive": true, "word_boundaries": false],
        ])
        #expect(fixture.client.validate(operation, arguments: arguments).isEmpty)
    }

    @Test func aDictionaryFromALexiconUploadsTheFile() throws {
        let scratch = try VoicesStudioScratch()
        defer { scratch.remove() }
        let fixture = VoicesStudioFixture()
        defer { fixture.clean() }
        let model = PronunciationSectionModel(environment: fixture.environment)
        model.newName = "Imported"
        model.newFromFile = true
        #expect(model.createArguments().3 == ["Choose the .pls file."])
        model.newFile = [try scratch.file("names.pls")]
        model.newAccess = "viewer"
        let (arguments, files, operation, problems) = model.createArguments()
        #expect(problems.isEmpty)
        #expect(operation == "add_from_file")
        #expect(files["file"]?.first?.contentType == "application/pls+xml")
        #expect(fixture.client.validate(operation, arguments: arguments, files: files).isEmpty)
    }

    @Test func markedRulesAreRemovedByTheStringTheyReplace() async throws {
        let rules: [JSONValue] = [
            ["string_to_replace": "Leicester", "type": "alias", "alias": "Lester", "case_sensitive": true, "word_boundaries": true],
            ["string_to_replace": "Bicester", "type": "alias", "alias": "Bister", "case_sensitive": true, "word_boundaries": true],
        ]
        let fixture = VoicesStudioFixture([
            "get_pronunciation_dictionary_metadata": [.json(Self.dictionary("d1", rules: rules)), .json(Self.dictionary("d1"))],
            "remove_rules": [.json(["id": "d1", "version_id": "ver2", "version_rules_num": 1])],
        ])
        defer { fixture.clean() }
        let model = PronunciationSectionModel(environment: fixture.environment)
        await model.select("d1")
        #expect(model.selected?.rules.map(\.summary) == ["Leicester → Lester", "Bicester → Bister"])
        model.marked = ["Bicester"]
        await model.removeMarked()
        #expect(fixture.body("remove_rules") == ["rule_strings": ["Bicester"]])
        #expect(model.marked.isEmpty)
    }

    @Test func theLatestVersionDownloadsAsAPLSFile() async throws {
        let fixture = VoicesStudioFixture([
            "get_pronunciation_dictionary_version_pls": [.init(status: 200, headers: ["content-type": "text/plain"],
                                                               body: Data("<lexicon/>".utf8))],
        ])
        defer { fixture.clean() }
        let model = PronunciationSectionModel(environment: fixture.environment)
        model.load(dictionaries: [], selected: try #require(PronunciationDictionary(json: Self.dictionary("d1"))))
        await model.downloadPLS()
        #expect(fixture.path("get_pronunciation_dictionary_version_pls") == "/v1/pronunciation-dictionaries/d1/ver1/download")
        let file = try #require(model.download)
        #expect(try String(contentsOf: file.url, encoding: .utf8) == "<lexicon/>")
    }

    @Test func archivingAndRenamingGoThroughTheSamePatch() async throws {
        let fixture = VoicesStudioFixture([
            "patch_pronunciation_dictionary": [.json(Self.dictionary("d1")), .json(Self.dictionary("d1"))],
            "get_pronunciation_dictionary_metadata": [.json(Self.dictionary("d1")), .json(Self.dictionary("d1"))],
        ])
        defer { fixture.clean() }
        let model = PronunciationSectionModel(environment: fixture.environment)
        model.load(dictionaries: [], selected: try #require(PronunciationDictionary(json: Self.dictionary("d1"))))
        await model.setArchived(true)
        #expect(fixture.body("patch_pronunciation_dictionary") == ["archived": true])
        model.rename = "Towns"
        await model.saveName()
        #expect(fixture.body("patch_pronunciation_dictionary") == ["name": "Towns"])
    }
}
