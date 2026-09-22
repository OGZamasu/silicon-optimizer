import Foundation
import Testing
import os
@testable import SiliconUI

/// The Hugging Face token lives in the Keychain, and reading it can block on a consent dialog:
/// every freshly built app has a new code identity, and macOS asks before handing it a token an
/// earlier build stored. Reading on the main thread at launch parked the whole app behind that
/// dialog — no window, no control server, no handshake file for the MCP. These pin the fix: the
/// launch path never touches the Keychain, and the deferred read cannot lose a credential.
///
/// Serialized because the Keychain seam is process-wide; the fake stands in for the real one
/// only for the duration of each test.
@Suite("Hugging Face credential loading", .serialized)
@MainActor
struct CredentialLoadingTests {

    /// An in-memory Keychain that counts every call made to it.
    final class FakeKeychain: Sendable {
        private struct State {
            var stored: String?
            var reads = 0
            var writes = 0
            var refuses: Bool
        }
        private let state: OSAllocatedUnfairLock<State>

        init(stored: String? = nil, refuses: Bool = false) {
            state = OSAllocatedUnfairLock(initialState: State(stored: stored, refuses: refuses))
        }

        var stored: String? { state.withLock { $0.stored } }
        var reads: Int { state.withLock { $0.reads } }
        var writes: Int { state.withLock { $0.writes } }

        var access: KeychainAccess {
            KeychainAccess(
                readHuggingFaceToken: { [state] in
                    state.withLock { state in
                        state.reads += 1
                        if state.refuses { return .unavailable(errSecAuthFailed) }
                        guard let token = state.stored, !token.isEmpty else { return .absent }
                        return .found(token)
                    }
                },
                writeHuggingFaceToken: { [state] token in
                    state.withLock { state in
                        state.writes += 1
                        if state.refuses { return false }
                        state.stored = token.isEmpty ? nil : token
                        return true
                    }
                }
            )
        }
    }

    /// Runs `body` against `keychain` instead of the real one, restoring the real one after so
    /// no other test can stray into the user's Keychain.
    private func withKeychain<T>(
        _ keychain: FakeKeychain, _ body: () async throws -> T
    ) async rethrows -> T {
        let previous = CredentialStore.replaceAccess(with: keychain.access)
        defer { CredentialStore.replaceAccess(with: previous) }
        return try await body()
    }

    /// Runs `body` with `document` as the saved settings, then puts back whatever was there.
    private func withSettingsDocument<T>(
        _ document: Data?, _ body: () async throws -> T
    ) async rethrows -> T {
        let defaults = UserDefaults.standard
        let previous = defaults.data(forKey: Settings.defaultsKey)
        if let document {
            defaults.set(document, forKey: Settings.defaultsKey)
        } else {
            defaults.removeObject(forKey: Settings.defaultsKey)
        }
        defer {
            if let previous {
                defaults.set(previous, forKey: Settings.defaultsKey)
            } else {
                defaults.removeObject(forKey: Settings.defaultsKey)
            }
        }
        return try await body()
    }

    private let legacyDocument = Data(
        #"{"temperature":0.4,"huggingFaceToken":"hf_legacy_plaintext"}"#.utf8
    )

    // MARK: - The launch path

    /// The whole point: `Settings.load()` runs on the main thread at launch, and must come back
    /// without asking the Keychain anything.
    @Test func loadNeverTouchesTheKeychain() async {
        let keychain = FakeKeychain(stored: "hf_in_keychain")
        await withKeychain(keychain) {
            await withSettingsDocument(legacyDocument) {
                let settings = Settings.load()
                #expect(keychain.reads == 0)
                #expect(keychain.writes == 0)
                #expect(!settings.isHuggingFaceTokenResolved)
                // The document's own copy is what it has until the Keychain answers.
                #expect(settings.huggingFaceToken == "hf_legacy_plaintext")
                #expect(settings.temperature == 0.4)
            }
            await withSettingsDocument(nil) {
                let settings = Settings.load()
                #expect(keychain.reads == 0)
                #expect(!settings.isHuggingFaceTokenResolved)
                #expect(settings.huggingFaceToken.isEmpty)
            }
        }
    }

    /// Saving before the Keychain has answered must not push the placeholder into it: an empty
    /// one would delete the token the user stored.
    @Test func savingAnUnresolvedPlaceholderLeavesTheKeychainAlone() async {
        let keychain = FakeKeychain(stored: "hf_in_keychain")
        await withKeychain(keychain) {
            await withSettingsDocument(nil) {
                var settings = Settings()
                settings.lastTab = "Models"
                #expect(settings.save())
                #expect(keychain.writes == 0)
                #expect(keychain.stored == "hf_in_keychain")
                #expect(Settings.load().lastTab == "Models")
            }
        }
    }

    /// A legacy plaintext copy is the only copy there is until it is migrated, so a save in the
    /// meantime keeps it in the document rather than redacting it into nothing.
    @Test func legacyCopySurvivesSavesUntilMigrated() async throws {
        let keychain = FakeKeychain()
        try await withKeychain(keychain) {
            try await withSettingsDocument(legacyDocument) {
                var settings = Settings.load()
                settings.lastTab = "Models"
                #expect(settings.save())
                #expect(keychain.writes == 0)

                let reloaded = Settings.load()
                #expect(reloaded.huggingFaceToken == "hf_legacy_plaintext")
                #expect(reloaded.lastTab == "Models")

                // Once resolved, the document is redacted and the Keychain has the token.
                settings.huggingFaceToken = "hf_typed"
                #expect(settings.isHuggingFaceTokenResolved)
                #expect(settings.save())
                #expect(keychain.stored == "hf_typed")
                let text = String(
                    decoding: try #require(UserDefaults.standard.data(forKey: Settings.defaultsKey)),
                    as: UTF8.self
                )
                #expect(!text.contains("hf_typed"))
                #expect(!text.contains("hf_legacy_plaintext"))
            }
        }
    }

    /// Clearing the field is a real instruction, and the only way the token leaves the Keychain.
    @Test func aResolvedEmptyTokenDeletesTheStoredOne() async {
        let keychain = FakeKeychain(stored: "hf_in_keychain")
        await withKeychain(keychain) {
            await withSettingsDocument(nil) {
                var settings = Settings()
                settings.huggingFaceToken = ""
                #expect(settings.save())
                #expect(keychain.stored == nil)
            }
        }
    }

    // MARK: - The deferred read

    @Test func resolutionPrefersTheKeychainOverALegacyCopy() async {
        let keychain = FakeKeychain(stored: "hf_in_keychain")
        await withKeychain(keychain) {
            let resolution = Settings.resolveHuggingFaceToken(migrating: "hf_legacy_plaintext")
            #expect(resolution == .token("hf_in_keychain"))
            #expect(keychain.reads == 1)
            #expect(keychain.writes == 0)
        }
    }

    @Test func resolutionMigratesALegacyCopyIntoAnEmptyKeychain() async {
        let keychain = FakeKeychain()
        await withKeychain(keychain) {
            let resolution = Settings.resolveHuggingFaceToken(migrating: "  hf_legacy_plaintext\n")
            #expect(resolution == .token("hf_legacy_plaintext"))
            #expect(keychain.stored == "hf_legacy_plaintext")
        }
    }

    @Test func resolutionWithNothingAnywhereIsAnEmptyToken() async {
        let keychain = FakeKeychain()
        await withKeychain(keychain) {
            #expect(Settings.resolveHuggingFaceToken(migrating: "") == .token(""))
            #expect(keychain.writes == 0)
        }
    }

    /// A dismissed consent dialog, or a locked Keychain, settles nothing: the placeholder stays,
    /// the legacy copy stays in the document, and nothing is written over the real token.
    @Test func aRefusingKeychainLeavesTheCredentialUnresolved() async {
        let keychain = FakeKeychain(stored: "hf_in_keychain", refuses: true)
        await withKeychain(keychain) {
            #expect(Settings.resolveHuggingFaceToken(migrating: "hf_legacy_plaintext") == .unavailable)
            #expect(Settings.resolveHuggingFaceToken(migrating: "") == .unavailable)
            #expect(keychain.writes == 0)
        }
    }

    // MARK: - The app

    /// The app comes up with a placeholder, asks the Keychain in the background, and anything
    /// that needs the token waits for that answer rather than running without it.
    @Test func appModelAdoptsTheTokenAfterLaunch() async {
        let keychain = FakeKeychain(stored: "hf_in_keychain")
        await withKeychain(keychain) {
            await withSettingsDocument(nil) {
                let model = AppModel()
                #expect(keychain.reads == 0)
                #expect(!model.settings.isHuggingFaceTokenResolved)

                model.loadHuggingFaceToken()
                let token = await model.huggingFaceToken()
                #expect(token == "hf_in_keychain")
                #expect(model.settings.huggingFaceToken == "hf_in_keychain")
                #expect(model.settings.isHuggingFaceTokenResolved)
                #expect(keychain.reads == 1)
            }
        }
    }

    /// A token typed into Settings before the Keychain answered is the one the user wants.
    @Test func aTypedTokenIsNeverOverwrittenByTheKeychain() async {
        let keychain = FakeKeychain(stored: "hf_in_keychain")
        await withKeychain(keychain) {
            await withSettingsDocument(nil) {
                let model = AppModel()
                model.settings.huggingFaceToken = "hf_typed"
                model.loadHuggingFaceToken()
                #expect(await model.huggingFaceToken() == "hf_typed")
                #expect(keychain.reads == 0)
            }
        }
    }

    /// Injected settings are how tests and previews stay out of the user's Keychain.
    @Test func injectedSettingsNeverReachTheKeychain() async {
        let keychain = FakeKeychain(stored: "hf_in_keychain")
        await withKeychain(keychain) {
            let model = AppModel(settings: .init())
            model.loadHuggingFaceToken()
            #expect(await model.huggingFaceToken() == nil)
            #expect(keychain.reads == 0)
            #expect(!model.settings.isHuggingFaceTokenResolved)
        }
    }
}
