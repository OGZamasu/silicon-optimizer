import Foundation
import Testing
@testable import SiliconUI

@Suite("Credential persistence")
struct CredentialPersistenceTests {
    private let key = "dev.siliconoptimizer.settings"

    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "SiliconOptimizer.CredentialTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    private func seedLegacy(_ defaults: UserDefaults) {
        defaults.set(Data(#"{"temperature":0.4,"huggingFaceToken":"hf_legacy"}"#.utf8), forKey: key)
    }

    private func saved(_ defaults: UserDefaults) throws -> Settings {
        let data = try #require(defaults.data(forKey: key))
        return try JSONDecoder().decode(Settings.self, from: data)
    }

    @Test func startupReadsOnceWithoutInteractionAndOrdinarySavesDoNotReadAgain() throws {
        try withDefaults { defaults in
            var reads = 0
            var settings = Settings.load(defaults: defaults) { interactive in
                #expect(!interactive)
                reads += 1
                return .found("hf_secure")
            }
            settings.lastTab = "chat"
            let savedTab = settings.save(defaults: defaults)
            #expect(savedTab)
            settings.harnessWebPort = 58857
            let savedPort = settings.save(defaults: defaults)
            #expect(savedPort)
            #expect(reads == 1)
            #expect(settings.huggingFaceToken == "hf_secure")
            let snapshot = try saved(defaults)
            #expect(snapshot.huggingFaceToken.isEmpty)
            #expect(snapshot.harnessWebPort == 58857)
        }
    }

    @Test(arguments: [CredentialReadResult.missing, .unavailable])
    func unavailableSecureTokenPreservesLegacyAcrossPreferenceSaves(result: CredentialReadResult) throws {
        try withDefaults { defaults in
            seedLegacy(defaults)
            var settings = Settings.load(defaults: defaults) { _ in result }
            #expect(settings.huggingFaceTokenNeedsAuthorization)
            #expect(settings.huggingFaceToken == "hf_legacy")
            settings.lastTab = "chat"
            // Even a new in-memory value may not replace the durable migration source.
            settings.huggingFaceToken = "hf_unsaved_draft"
            let didSave = settings.save(defaults: defaults)
            #expect(didSave)
            let snapshot = try saved(defaults)
            #expect(snapshot.huggingFaceToken == "hf_legacy")
            #expect(snapshot.lastTab == "chat")
        }
    }

    @Test func deniedReadWithoutLegacyDoesNotEraseOrInventACredential() throws {
        try withDefaults { defaults in
            let settings = Settings.load(defaults: defaults) { _ in .unavailable }
            #expect(settings.huggingFaceTokenNeedsAuthorization)
            #expect(settings.huggingFaceToken.isEmpty)
            let didSave = settings.save(defaults: defaults)
            #expect(didSave)
            let snapshot = try saved(defaults)
            #expect(snapshot.huggingFaceToken.isEmpty)
        }
    }

    @Test func newInstallNeedsNoCredentialAuthorization() {
        withDefaults { defaults in
            let settings = Settings.load(defaults: defaults) { _ in .missing }
            #expect(!settings.huggingFaceTokenNeedsAuthorization)
        }
    }

    @Test func authorizationStateIsNotPersistedInSettingsJSON() throws {
        try withDefaults { defaults in
            let settings = Settings.load(defaults: defaults) { _ in .unavailable }
            #expect(settings.huggingFaceTokenNeedsAuthorization)
            let didSave = settings.save(defaults: defaults)
            #expect(didSave)

            let data = try #require(defaults.data(forKey: key))
            let object = try JSONSerialization.jsonObject(with: data)
            let fields = try #require(object as? [String: Any])
            #expect(fields["huggingFaceTokenNeedsAuthorization"] == nil)
            let snapshot = try saved(defaults)
            #expect(!snapshot.huggingFaceTokenNeedsAuthorization)
        }
    }

    @Test func successfulReadRetiresOnlyTheLegacyCopy() throws {
        try withDefaults { defaults in
            seedLegacy(defaults)
            let settings = Settings.load(defaults: defaults) { _ in .found("hf_secure") }
            #expect(settings.huggingFaceToken == "hf_secure")
            let snapshot = try saved(defaults)
            #expect(snapshot.huggingFaceToken.isEmpty)
            #expect(snapshot.temperature == 0.4)
        }
    }

    @Test(arguments: ["hf_replacement", ""])
    func failedExplicitReplacementOrRemovalKeepsBothCopies(value: String) throws {
        try withDefaults { defaults in
            seedLegacy(defaults)
            var settings = Settings.load(defaults: defaults) { _ in .unavailable }
            let original = defaults.data(forKey: key)
            let didSave = settings.saveHuggingFaceToken(value, defaults: defaults) { _ in false }
            #expect(!didSave)
            #expect(settings.huggingFaceToken == "hf_legacy")
            #expect(settings.huggingFaceTokenNeedsAuthorization)
            #expect(defaults.data(forKey: key) == original)
            let snapshot = try saved(defaults)
            #expect(snapshot.huggingFaceToken == "hf_legacy")
        }
    }

    @Test(arguments: ["  hf_replacement\n", ""])
    func explicitSuccessfulReplacementOrRemovalRetiresLegacy(value: String) throws {
        try withDefaults { defaults in
            seedLegacy(defaults)
            var settings = Settings.load(defaults: defaults) { _ in .unavailable }
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            var writes = 0
            let didSave = settings.saveHuggingFaceToken(value, defaults: defaults) { token in
                writes += 1
                #expect(token == normalized)
                return true
            }
            #expect(didSave)
            #expect(writes == 1)
            #expect(settings.huggingFaceToken == normalized)
            #expect(!settings.huggingFaceTokenNeedsAuthorization)
            let snapshot = try saved(defaults)
            #expect(snapshot.huggingFaceToken.isEmpty)
        }
    }

    @Test func serializationFailureDoesNotWriteCredentialOrChangeState() {
        withDefaults { defaults in
            seedLegacy(defaults)
            var settings = Settings.load(defaults: defaults) { _ in .unavailable }
            settings.temperature = .nan
            let original = defaults.data(forKey: key)
            var writes = 0

            let didSave = settings.saveHuggingFaceToken("hf_replacement", defaults: defaults) { _ in
                writes += 1
                return true
            }

            #expect(!didSave)
            #expect(writes == 0)
            #expect(settings.huggingFaceToken == "hf_legacy")
            #expect(settings.huggingFaceTokenNeedsAuthorization)
            #expect(settings.temperature.isNaN)
            #expect(defaults.data(forKey: key) == original)
        }
    }

    @Test func explicitAuthorizationReadsOnceAndDoesNotRewriteExistingSecureToken() throws {
        try withDefaults { defaults in
            seedLegacy(defaults)
            var settings = Settings.load(defaults: defaults) { _ in .unavailable }
            var reads = 0
            let didAuthorize = settings.authorizeHuggingFaceToken(defaults: defaults, readCredential: { interactive in
                #expect(interactive)
                reads += 1
                return .found("hf_secure")
            }, writeCredential: { _ in
                Issue.record("Authorization must not rewrite an existing secure token")
                return false
            })
            #expect(didAuthorize)
            #expect(reads == 1)
            #expect(settings.huggingFaceToken == "hf_secure")
            let snapshot = try saved(defaults)
            #expect(snapshot.huggingFaceToken.isEmpty)
        }
    }

    @Test func explicitAuthorizationMigratesLegacyOnlyWhenSecureItemIsMissing() throws {
        try withDefaults { defaults in
            seedLegacy(defaults)
            var settings = Settings.load(defaults: defaults) { _ in .missing }
            let didAuthorize = settings.authorizeHuggingFaceToken(defaults: defaults, readCredential: { _ in .missing },
                writeCredential: { token in
                    #expect(token == "hf_legacy")
                    return true
                })
            #expect(didAuthorize)
            #expect(settings.huggingFaceToken == "hf_legacy")
            let snapshot = try saved(defaults)
            #expect(snapshot.huggingFaceToken.isEmpty)
        }
    }

    @Test func deniedExplicitAuthorizationNeverAttemptsReplacement() {
        withDefaults { defaults in
            seedLegacy(defaults)
            var settings = Settings.load(defaults: defaults) { _ in .unavailable }
            let original = defaults.data(forKey: key)
            let didAuthorize = settings.authorizeHuggingFaceToken(defaults: defaults, readCredential: { _ in .unavailable },
                writeCredential: { _ in
                    Issue.record("Denied read must not authorize replacement")
                    return false
                })
            #expect(!didAuthorize)
            #expect(settings.huggingFaceToken == "hf_legacy")
            #expect(defaults.data(forKey: key) == original)
        }
    }
}
