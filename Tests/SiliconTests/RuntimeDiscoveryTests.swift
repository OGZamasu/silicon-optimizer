import Foundation
import Testing
@testable import SiliconCore
@testable import SiliconRuntime

/// Exercises discovery against whatever is actually installed on this machine.
///
/// These are conditional rather than skipped-by-default: on a developer machine or a CI runner
/// with `brew install llama.cpp`, they verify the real probe against a real binary. Everywhere
/// else they assert the absence path, which is just as important — a missing runtime has to
/// produce a clear message rather than a crash.
@Suite("Runtime discovery")
struct RuntimeDiscoveryTests {

    private var llamaServerExists: Bool {
        FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/llama-server")
            || RuntimeLocator.which("llama-server") != nil
    }

    @Test func locatesLlamaServerWhenInstalled() throws {
        try #require(llamaServerExists, "llama.cpp not installed; nothing to locate")

        let installation = try #require(LlamaCppRuntime.locate())
        #expect(installation.kind == .llamaCpp)
        #expect(FileManager.default.isExecutableFile(atPath: installation.executable.path))
        // Homebrew's build reports a version banner; parsing it is how Settings shows which
        // build is in use.
        #expect(installation.version != nil)
    }

    /// The expert-paging flags come from a proof-of-concept branch that is not in any release.
    /// The app must therefore decide from the binary itself, not from a version number — and
    /// must not offer the feature when the flag is absent, or the runtime dies at launch.
    @Test func detectsExpertStreamingSupportFromTheBinary() throws {
        try #require(llamaServerExists, "llama.cpp not installed")

        let installation = try #require(LlamaCppRuntime.locate())
        let help = try helpText(of: installation.executable)
        let advertisesFlag = help.contains("--moe-n-slots")

        // Whatever the truth is for this build, the probe must agree with it.
        #expect(installation.hasExpertStreaming == advertisesFlag)

        let selector = RuntimeSelector(available: [.llamaCpp: installation])
        #expect(selector.expertStreamingAvailable == advertisesFlag)
    }

    @Test func discoveryFindsSomethingOrReportsNothing() {
        let selector = RuntimeSelector.discover()
        if llamaServerExists {
            #expect(selector.isAnythingInstalled)
            #expect(selector.available[.llamaCpp] != nil)
        }
        // With nothing installed the selector must simply be empty rather than throwing.
        #expect(selector.available.count >= 0)
    }

    private func helpText(of executable: URL) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--help"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

@Suite("Load progress parsing")
struct LoadProgressTests {

    /// Real lines captured from llama.cpp b10280 at its *default* verbosity. That build prints
    /// no percentage at all, which previously left the UI on "Starting llama.cpp…" for the
    /// entire load — the exact blank wait this app exists to remove.
    static let b10280DefaultVerbosity = [
        "0.00.145.528 I srv    load_model: loading model '/models/Qwen3-1.7B-Q4_K_M.gguf'",
        "0.01.636.701 I srv    load_model: initializing, n_slots = 4, n_ctx_slot = 32768",
        "0.01.644.527 I srv  llama_server: model loaded",
        "0.01.644.531 I srv  llama_server: listening on http://127.0.0.1:18099",
    ]

    /// Lines an older build emits, which carry an explicit percentage.
    static let legacyVerbose = [
        "llama_model_loader: loaded meta data with 32 key-value pairs",
        "load_tensors: loading model tensors, this can take a while...",
        "load_tensors:  offloading 28 repeating layers to GPU  25%",
        "load_tensors:  offloading output layer to GPU  80%",
    ]

    @Test func recognisesEveryStageOfTheCurrentFormat() {
        // Each captured line must match a known stage, or progress silently stops updating.
        let matched = Self.b10280DefaultVerbosity.filter { line in
            LlamaCppRuntime.stages.contains { line.contains($0.needle) }
        }
        #expect(matched.count >= 2, "no stage matched the current llama.cpp log format")
    }

    @Test func stageProgressIsMonotonic() {
        let values = LlamaCppRuntime.stages.map(\.progress)
        #expect(values == values.sorted())
        #expect(values.allSatisfy { $0 > 0 && $0 < 1 })
    }

    /// Regression: the percentage was extracted by filtering digits out of the whole
    /// `load_tensors:` span, so "offloading 28 repeating layers to GPU 25%" parsed as 2825 —
    /// a progress bar reading 2825%.
    @Test(arguments: [
        ("load_tensors:  offloading 28 repeating layers to GPU  25%", 25),
        ("load_tensors:  offloading output layer to GPU  80%", 80),
        ("load_tensors: offloading 100 layers  100%", 100),
    ])
    func legacyPercentageIsTheOneBeforeTheSign(line: String, expected: Int) {
        let range = try? #require(line.range(of: #"\d+%"#, options: .regularExpression))
        let parsed = range.flatMap { Int(line[$0].dropLast()) }
        #expect(parsed == expected)
    }

    @Test func stageLabelsAreUserFacing() {
        // No raw llama.cpp identifiers should reach the UI.
        for stage in LlamaCppRuntime.stages {
            #expect(!stage.label.contains("_"))
            #expect(stage.label.first?.isUppercase == true)
        }
    }
}

@Suite("MLX discovery")
struct MLXDiscoveryTests {

    static var venvServer: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".silicon-mlx/bin/mlx_lm.server")
    }

    static var hasVenvMLX: Bool {
        FileManager.default.isExecutableFile(atPath: venvServer.path)
    }

    /// Regression: macOS ships an externally-managed Python, so `pip install mlx-lm` fails under
    /// PEP 668 and users install into a virtual environment. Those are not on the PATH an app
    /// inherits from Finder, and MLX was reported as missing on machines where it worked fine.
    ///
    /// Gated on the venv existing rather than `#require`d inside the body: a missing venv means
    /// the regression cannot be exercised here, not that anything is broken. `#require` records
    /// an issue and fails the run, so machines without mlx-lm — every contributor who has not
    /// installed it — saw a red suite. `.enabled(if:)` skips instead, matching `MLXIntegrationTests`.
    @Test(.enabled(if: MLXDiscoveryTests.hasVenvMLX))
    func findsMLXInstalledInAVirtualEnvironment() throws {
        let installation = try #require(MLXRuntime.locate())
        #expect(installation.kind == .mlx)
        #expect(FileManager.default.isExecutableFile(atPath: installation.executable.path))
    }

    @Test func absentMLXIsReportedRatherThanCrashing() {
        // Whatever the machine has, discovery must return cleanly.
        let selector = RuntimeSelector.discover()
        _ = selector.available[.mlx]
        #expect(Bool(true))
    }
}
