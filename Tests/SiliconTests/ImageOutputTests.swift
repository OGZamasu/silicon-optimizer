import Foundation
import Testing
@testable import SiliconUI

/// Generated images used to land in `FileManager.temporaryDirectory` — a per-boot path under
/// `/var/folders` that cannot be reached from Finder and that macOS may purge. These cover the
/// settings that replaced it.
@Suite("Generated image output location")
struct ImageOutputTests {

    @Test func defaultsToPicturesWhenUnset() {
        let settings = Settings()
        #expect(settings.imageOutputDirectory.isEmpty)
        let resolved = settings.resolvedImageOutputDirectory
        #expect(resolved.lastPathComponent == "Silicon Optimizer")
        #expect(resolved.deletingLastPathComponent().lastPathComponent == "Pictures")
    }

    @Test func honoursAnExplicitDirectory() {
        var settings = Settings()
        settings.imageOutputDirectory = "/Users/example/Renders"
        #expect(settings.resolvedImageOutputDirectory.path == "/Users/example/Renders")
    }

    /// A path typed by hand is far more likely to use `~` than a fully expanded home directory.
    @Test func expandsTheTilde() {
        var settings = Settings()
        settings.imageOutputDirectory = "~/Renders"
        let resolved = settings.resolvedImageOutputDirectory.path
        #expect(!resolved.hasPrefix("~"))
        #expect(resolved.hasSuffix("/Renders"))
    }

    /// Whitespace-only is the state left behind by selecting the field and deleting its contents,
    /// and must mean "default" rather than a directory literally named " ".
    @Test(arguments: ["", "   ", "\n", "  \t "])
    func treatsBlankAsUnset(_ blank: String) {
        var settings = Settings()
        settings.imageOutputDirectory = blank
        #expect(settings.resolvedImageOutputDirectory == Settings.defaultImageOutputDirectory)
    }

    @Test func filenameSortsChronologically() {
        let earlier = Settings.imageFilename(
            date: Date(timeIntervalSince1970: 1_000_000), uniqueSuffix: "AAAA"
        )
        let later = Settings.imageFilename(
            date: Date(timeIntervalSince1970: 2_000_000), uniqueSuffix: "AAAA"
        )
        // Browsing a folder of generated images by name should be browsing them by time.
        #expect(earlier < later)
        #expect(earlier.hasPrefix("silicon-"))
        #expect(earlier.hasSuffix(".png"))
    }

    /// A batch generates several images inside the same second, so the timestamp alone is not
    /// unique enough to name them by.
    @Test func filenamesInTheSameSecondDoNotCollide() {
        let instant = Date(timeIntervalSince1970: 1_700_000_000)
        let names = Set((0..<64).map { _ in Settings.imageFilename(date: instant) })
        #expect(names.count == 64)
    }

    @Test func honoursTheRequestedExtension() {
        #expect(Settings.imageFilename(extension: "jpg").hasSuffix(".jpg"))
    }

    /// The setting has to survive a relaunch, or it is a per-session preference pretending to be
    /// a persistent one.
    @Test func roundTripsThroughCoding() throws {
        var settings = Settings()
        settings.imageOutputDirectory = "/Volumes/Scratch/Images"
        let decoded = try JSONDecoder().decode(
            Settings.self, from: try JSONEncoder().encode(settings)
        )
        #expect(decoded.imageOutputDirectory == "/Volumes/Scratch/Images")
    }

    /// Settings written by an older build have no such key, and must decode rather than throw.
    @Test func decodesSettingsSavedBeforeThisOptionExisted() throws {
        let legacy = Data(#"{"temperature":0.7,"huggingFaceToken":""}"#.utf8)
        let decoded = try JSONDecoder().decode(Settings.self, from: legacy)
        #expect(decoded.imageOutputDirectory.isEmpty)
        #expect(decoded.resolvedImageOutputDirectory == Settings.defaultImageOutputDirectory)
    }

    /// The upgrade path, which is the one that actually hurts if it breaks.
    ///
    /// The synthesized decoder throws on a missing key even where a default exists, and
    /// `Settings.load()` turns any decode failure into a fresh `Settings()`. Adding a stored
    /// property would therefore have wiped every existing preference on first launch — the
    /// Hugging Face token most painfully, since it is not recoverable from anywhere else.
    @Test func addingAFieldDoesNotDiscardExistingPreferences() throws {
        let saved = Data("""
        {
          "temperature": 0.4,
          "topP": 0.9,
          "maxTokens": 2048,
          "reasoningEffort": "high",
          "launchAtLogin": true,
          "unloadWhenIdle": false,
          "idleUnloadMinutes": 15,
          "showAdvancedControls": true,
          "speedCalibrations": {"qwen3-8b": 1.18},
          "huggingFaceToken": "hf_previously_entered",
          "llamaServerPath": "/opt/homebrew/bin/llama-server",
          "mlxServerPath": ""
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(Settings.self, from: saved)

        #expect(decoded.huggingFaceToken == "hf_previously_entered")
        #expect(decoded.temperature == 0.4)
        #expect(decoded.maxTokens == 2048)
        #expect(decoded.reasoningEffort == "high")
        #expect(decoded.launchAtLogin)
        #expect(!decoded.unloadWhenIdle)
        #expect(decoded.idleUnloadMinutes == 15)
        #expect(decoded.speedCalibrations["qwen3-8b"] == 1.18)
        #expect(decoded.llamaServerPath == "/opt/homebrew/bin/llama-server")
        // And the new field lands on its default rather than failing the whole decode.
        #expect(decoded.imageOutputDirectory.isEmpty)
    }
}
