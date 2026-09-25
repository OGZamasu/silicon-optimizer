import CryptoKit
import Foundation
import Testing
@testable import SiliconCatalog
@testable import SiliconControl
@testable import SiliconRuntime

/// The installers #72's pinning did not reach — MFLUX and the voice tools, LuxTTS, face
/// tracking, Laya — and the voice models those tools fetch when they run. The same rule
/// as the media tools: the locks the app ships, the plans that use them, and — against
/// real git, curl and pip — that a changed commit, file or wheel is refused.
@Suite("Pinned tool installers", .serialized)
struct PinnedToolInstallTests {

    static let lockRoot = PinnedInstall.defaultLockRoot()
    static let repository = lockRoot.deletingLastPathComponent().deletingLastPathComponent()

    static let spaCyModel = "https://github.com/explosion/spacy-models/releases/download/"
        + "en_core_web_sm-3.8.0/en_core_web_sm-3.8.0-py3-none-any.whl"
    static func piperPhonemize(_ python: String) -> String {
        let tag = "cp" + python.replacingOccurrences(of: ".", with: "")
        return "https://github.com/csukuangfj/piper-phonemize/releases/download/v1.4.7/"
            + "piper_phonemize-1.4.7-\(tag)-\(tag)-macosx_11_0_arm64.whl"
    }

    /// Every lock a plan can name, per directory, and nothing else.
    static let expectedLocks: [String: [String]] = [
        PinnedInstall.mlxEnvironmentLocks:
            PinnedInstall.mfluxPythons.map { "mflux-py\($0).txt" }
            + PinnedInstall.voicePythons.flatMap { ["voice-py\($0).txt", "build-py\($0).txt"] },
        PinnedInstall.luxTTS.lockDirectory:
            PinnedInstall.luxTTSPythons.flatMap { ["requirements-py\($0).txt", "build-py\($0).txt"] },
        PinnedInstall.trackerLocks: PinnedInstall.trackerPythons.map { "requirements-py\($0).txt" },
        PinnedInstall.layaLocks: PinnedInstall.layaPythons.map { "requirements-py\($0).txt" },
    ]

    // MARK: - The locks

    /// Every requirement is an exact version with at least one SHA-256, or — for the two
    /// wheels that are not on PyPI — that exact release URL with its SHA-256; and nothing in
    /// a lock can point pip at an index, a page of links or a checkout.
    @Test func everyLockIsFullyPinnedAndHashed() throws {
        for (directory, files) in Self.expectedLocks {
            let folder = Self.lockRoot.appendingPathComponent(directory)
            let present = try FileManager.default.contentsOfDirectory(atPath: folder.path)
                .filter { $0.hasSuffix(".txt") }
            #expect(Set(present) == Set(files), "\(directory)")

            for file in files {
                let text = try String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8)
                let python = try #require(file.firstMatch(of: /py(3\.\d+)\.txt$/)?.1).description
                let urls = [Self.spaCyModel, Self.piperPhonemize(python)]
                let requirements = try PinnedInstallTests.requirements(in: text)
                #expect(!requirements.isEmpty, "\(file)")
                for requirement in requirements {
                    let exact = requirement.range(
                        of: #"^[A-Za-z0-9._-]+(\[[a-z,]+\])?==[A-Za-z0-9.+!_-]+ "#, options: .regularExpression
                    ) != nil
                    let reviewedURL = urls.contains { requirement.contains(" @ \($0) ") }
                    #expect(exact || reviewedURL, "\(directory)/\(file): not pinned: \(requirement.prefix(100))")
                    #expect(requirement.range(of: #"--hash=sha256:[0-9a-f]{64}"#, options: .regularExpression) != nil,
                            "\(directory)/\(file): no hash: \(requirement.prefix(80))")
                    #expect(!requirement.contains("git+") && !requirement.contains("file:"))
                }
                let directives = text.split(separator: "\n").filter { $0.hasPrefix("-") }
                #expect(directives.isEmpty, "\(directory)/\(file): \(directives)")
                if directory == PinnedInstall.luxTTS.lockDirectory {
                    #expect(text.contains("\n# Source: \(PinnedInstall.luxTTS.repository) \(PinnedInstall.luxTTS.commit)\n"),
                            "\(file) was not resolved from the pinned LuxTTS commit")
                }
            }
        }
    }

    /// What each installer asks for is the version reviewed — and that the laya-mlx the
    /// lock installs is the wheel whose digest the app already checks.
    @Test func theLocksHoldTheReviewedVersions() throws {
        func lock(_ kind: String, _ directory: String, _ python: String) throws -> [String: String] {
            try PinnedInstallTests.pins(PinnedInstall.lock(kind, directory: directory, python: python, in: Self.lockRoot))
        }
        for python in PinnedInstall.mfluxPythons {
            let mflux = try lock("mflux", PinnedInstall.mlxEnvironmentLocks, python)
            // 0.20.0 is the first with Qwen-Image 2.1 (`mflux-generate-qwen-2.1`), and it
            // needs MLX 0.32.
            #expect(mflux["mflux"] == "0.20.0")
            #expect(mflux["mlx"]?.hasPrefix("0.32.") == true, "\(python): \(mflux["mlx"] ?? "no mlx")")
        }
        for python in PinnedInstall.voicePythons {
            let voice = try lock("voice", PinnedInstall.mlxEnvironmentLocks, python)
            for (name, version) in ["mlx-audio": "0.5.0", "mlx-speech": "0.5.2", "misaki": "0.7.4",
                                    "spacy": "3.8.13", "phonemizer": "3.4.0", "espeakng-loader": "0.2.4",
                                    "num2words": "0.5.14"] {
                #expect(voice[name] == version, "\(name) for \(python)")
            }
            let text = try String(contentsOf: PinnedInstall.lock(
                "voice", directory: PinnedInstall.mlxEnvironmentLocks, python: python, in: Self.lockRoot
            ), encoding: .utf8)
            #expect(text.contains("en-core-web-sm @ \(Self.spaCyModel)"))
        }
        for python in PinnedInstall.trackerPythons {
            let tracker = try lock("requirements", PinnedInstall.trackerLocks, python)
            #expect(tracker["mediapipe"] == "0.10.35", "the 1.x wheels abort in the landmarker graph")
            #expect(tracker["python-osc"] != nil && tracker["opencv-python"] != nil)
        }
        for python in PinnedInstall.layaPythons {
            let url = PinnedInstall.lock("requirements", directory: PinnedInstall.layaLocks, python: python, in: Self.lockRoot)
            #expect(try PinnedInstallTests.pins(url)["laya-mlx"] == LayaPackage.version)
            let laya = try #require(try PinnedInstallTests.requirements(in: String(contentsOf: url, encoding: .utf8))
                .first { $0.hasPrefix("laya-mlx==") })
            #expect(laya.contains("--hash=sha256:\(LayaPackage.wheelSHA256)"), "\(python)")
        }
    }

    /// MFLUX and the voice tools share one environment, so a package both need is at one
    /// version in both locks — installing either never moves the other's. Build tools are
    /// the versions the main lock resolved against.
    @Test func sharedAndBuildLocksAgree() throws {
        for python in PinnedInstall.voicePythons {
            let mflux = try PinnedInstallTests.pins(PinnedInstall.lock("mflux", directory: PinnedInstall.mlxEnvironmentLocks, python: python, in: Self.lockRoot))
            let voice = try PinnedInstallTests.pins(PinnedInstall.lock("voice", directory: PinnedInstall.mlxEnvironmentLocks, python: python, in: Self.lockRoot))
            let build = try PinnedInstallTests.pins(PinnedInstall.lock("build", directory: PinnedInstall.mlxEnvironmentLocks, python: python, in: Self.lockRoot))
            for (name, version) in voice where mflux[name] != nil {
                #expect(mflux[name] == version, "\(python): the voice tools would move MFLUX's \(name)")
            }
            #expect(build["setuptools"] != nil && build["setuptools"] == voice["setuptools"])
        }
        for python in PinnedInstall.luxTTSPythons {
            let main = try PinnedInstallTests.pins(PinnedInstall.lock("requirements", for: PinnedInstall.luxTTS, python: python, in: Self.lockRoot))
            let build = try PinnedInstallTests.pins(PinnedInstall.lock("build", for: PinnedInstall.luxTTS, python: python, in: Self.lockRoot))
            #expect(build["setuptools"] == main["setuptools"], "\(python)")
            // LinaCodec's pyproject asks for uv_build >=0.9.6,<0.10.0.
            let uvBuild = try #require(build["uv-build"]).split(separator: ".").compactMap { Int($0) }
            #expect(uvBuild.count == 3 && uvBuild[0] == 0 && uvBuild[1] == 9 && uvBuild[2] >= 6, "\(uvBuild)")
            // LinaCodec itself is installed from its verified checkout; what it depends on
            // is here, hash-checked.
            #expect(main["linacodec"] == nil)
            for dependency in ["torch", "torchaudio", "vocos", "jsonargparse", "huggingface-hub",
                               "safetensors", "soundfile", "tqdm", "numpy"] {
                #expect(main[dependency] != nil, "\(python): \(dependency)")
            }
            #expect(try String(contentsOf: PinnedInstall.lock("requirements", for: PinnedInstall.luxTTS, python: python, in: Self.lockRoot), encoding: .utf8)
                .contains("piper-phonemize @ \(Self.piperPhonemize(python))"))
        }
    }

    /// The locks hold to the versions that are installed and working (Scripts/lock-inputs),
    /// so a rerun over a working environment changes nothing. The exceptions: Laya's 3.11
    /// NumPy, which the tested version does not support, and LinaCodec's build backend, which
    /// an isolated build used and threw away, so no environment shows it (it is held to
    /// LinaCodec's own range above).
    @Test func theLocksAreTheTestedVersions() throws {
        let inputs = Self.repository.appendingPathComponent("Scripts/lock-inputs")
        let tested: [String: String] = [
            PinnedInstall.mlxEnvironmentLocks: "silicon-mlx-tested.txt",
            PinnedInstall.luxTTS.lockDirectory: "luxtts-tested.txt",
            PinnedInstall.trackerLocks: "tracker-tested.txt",
            PinnedInstall.layaLocks: "laya-tested.txt",
        ]
        for (directory, files) in Self.expectedLocks {
            let known = try PinnedInstallTests.pins(inputs.appendingPathComponent(tested[directory]!))
            for file in files {
                for (name, version) in try PinnedInstallTests.pins(Self.lockRoot.appendingPathComponent("\(directory)/\(file)")) {
                    if directory == PinnedInstall.layaLocks, file.hasSuffix("3.11.txt"), name == "numpy" { continue }
                    if file.hasPrefix("build-"), name == "uv-build" { continue }
                    #expect(known[name] == version, "\(directory)/\(file): \(name)==\(version) was not tested")
                }
            }
        }
    }

    // MARK: - The plans

    static let homebrew314 = URL(fileURLWithPath: "/opt/homebrew/bin/python3.14")
    static let git = URL(fileURLWithPath: "/usr/bin/git")

    /// The commands that install Python packages, and whether each is hash-checked.
    static func installs(_ plan: [PinnedInstall.Command]) -> [PinnedInstall.Command] {
        plan.filter { $0.arguments.starts(with: ["-m", "pip", "install"]) }
    }

    @Test func mfluxInstallsOnlyItsLockIntoTheSharedEnvironment() throws {
        let root = try PinnedInstallTests.scratch("mflux-plan")
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = try MFluxRuntime.installPlan(basePython: Self.homebrew314, locks: Self.lockRoot, environment: root)
        #expect(plan.first?.arguments == ["-m", "venv", root.path])
        #expect(plan.first?.executable == Self.homebrew314)
        let installs = Self.installs(plan)
        #expect(installs.count == 1)
        let arguments = try #require(installs.first).arguments
        #expect(arguments.contains("--require-hashes") && arguments.contains(":all:"))
        #expect(arguments.last!.hasSuffix("silicon-mlx/mflux-py3.14.txt"))
        #expect(!plan.contains { $0.arguments.contains("--upgrade") || $0.arguments.contains("mflux") })
        #expect(installs.first?.executable == root.appendingPathComponent("bin/python3"))
    }

    @Test func theVoiceToolsInstallBuildToolsThenTheirLock() throws {
        let root = try PinnedInstallTests.scratch("voice-plan")
        defer { try? FileManager.default.removeItem(at: root) }
        try PinnedInstallTests.fakeEnvironment(at: root, version: "3.14.6")
        let plan = try VoiceRuntime.toolsInstallPlan(basePython: nil, locks: Self.lockRoot, environment: root)
        #expect(!plan.contains { $0.arguments.contains("venv") }, "an existing environment is kept")
        let installs = Self.installs(plan)
        try #require(installs.count == 2 && installs.count == plan.count)
        #expect(installs[0].arguments.last!.hasSuffix("silicon-mlx/build-py3.14.txt"))
        #expect(installs[1].arguments.last!.hasSuffix("silicon-mlx/voice-py3.14.txt"))
        #expect(installs[1].arguments.contains("--no-build-isolation"), "docopt builds with the locked setuptools")
        #expect(installs.allSatisfy { $0.arguments.contains("--require-hashes") })
    }

    /// The voice lock is held to MFLUX's current lock, so over an environment where MFLUX is
    /// installed — perhaps an older MFLUX an older app put there, whose MLX range the voice
    /// lock's MLX falls outside — MFLUX's own lock goes in first, and the two can never end up
    /// on versions that were not locked together. Without MFLUX there is nothing to keep in step.
    @Test func theVoiceToolsReinstallMFLUXsLockFirstWhereMFLUXIs() throws {
        let root = try PinnedInstallTests.scratch("voice-over-mflux")
        try requireTemporaryDirectory(root)
        defer { removeTemporaryDirectory(root) }
        let environment = root.appendingPathComponent("env")
        try PinnedInstallTests.fakeEnvironment(at: environment, version: "3.14.6")
        FileManager.default.createFile(
            atPath: environment.appendingPathComponent("bin/mflux-generate").path, contents: Data(),
            attributes: [.posixPermissions: 0o755]
        )
        let plan = try VoiceRuntime.toolsInstallPlan(
            basePython: nil, locks: Self.lockRoot, environment: environment
        )
        #expect(!plan.contains { $0.arguments.contains("venv") }, "a covered environment is kept")
        let locks = Self.installs(plan).map { URL(fileURLWithPath: $0.arguments.last!).lastPathComponent }
        #expect(locks == ["mflux-py3.14.txt", "build-py3.14.txt", "voice-py3.14.txt"])
        #expect(Self.installs(plan).allSatisfy { $0.arguments.contains("--require-hashes") })
        // MFLUX's is wheels only, as its own install is.
        #expect(Self.installs(plan).first?.arguments.contains(":all:") == true)

        // And the two locks it installs agree on every package they share.
        let mflux = try PinnedInstallTests.pins(PinnedInstall.lock(
            "mflux", directory: PinnedInstall.mlxEnvironmentLocks, python: "3.14", in: Self.lockRoot
        ))
        let voice = try PinnedInstallTests.pins(PinnedInstall.lock(
            "voice", directory: PinnedInstall.mlxEnvironmentLocks, python: "3.14", in: Self.lockRoot
        ))
        #expect(voice["mlx"] != nil && voice["mlx"] == mflux["mlx"])

        let without = root.appendingPathComponent("no-mflux")
        try PinnedInstallTests.fakeEnvironment(at: without, version: "3.14.6")
        let voiceOnly = try VoiceRuntime.toolsInstallPlan(
            basePython: nil, locks: Self.lockRoot, environment: without
        )
        #expect(!Self.installs(voiceOnly).contains { $0.arguments.last!.hasSuffix("mflux-py3.14.txt") })
    }

    @Test func luxTTSFetchesBothSourcesByCommitAndInstallsLinaCodecOffline() throws {
        let root = try PinnedInstallTests.scratch("luxtts-plan")
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = try VoiceRuntime.luxTTSInstallPlan(
            basePython: URL(fileURLWithPath: "/opt/homebrew/bin/python3.13"), git: Self.git,
            locks: Self.lockRoot, environment: root
        )
        #expect(plan.first?.arguments == ["-m", "venv", root.path])
        #expect(!plan.contains { $0.arguments.contains("clone") || $0.arguments.contains("--find-links") })
        #expect(!plan.contains { $0.arguments.contains { $0.hasSuffix("luxtts/requirements.txt") } },
                "the clone's own requirements are never handed to pip")
        for source in [PinnedInstall.luxTTS, PinnedInstall.linaCodec] {
            #expect(plan.contains { $0.arguments.contains("fetch") && $0.arguments.last == source.commit })
        }
        let checks = plan.indices.filter { plan[$0].label.hasPrefix("Checking") }
        try #require(checks.count == 3, "both sources after fetching, and LinaCodec again before it is installed")
        let installs = plan.indices.filter { plan[$0].arguments.starts(with: ["-m", "pip", "install"]) }
        try #require(installs.count == 3)
        #expect(installs.allSatisfy { $0 > checks[1] })
        #expect(plan[installs[0]].arguments.last!.hasSuffix("luxtts/build-py3.13.txt"))
        #expect(plan[installs[1]].arguments.last!.hasSuffix("luxtts/requirements-py3.13.txt"))
        #expect(plan[installs[1]].arguments.contains("--no-build-isolation"))
        #expect(installs.prefix(2).allSatisfy { plan[$0].arguments.contains("--require-hashes") })
        // LinaCodec: straight after its second check, from the checkout, offline, alone.
        let linaCodec = plan[installs[2]].arguments
        #expect(installs[2] == checks[2] + 1)
        #expect(linaCodec.last == root.appendingPathComponent("linacodec").path)
        for flag in ["--no-deps", "--no-index", "--no-build-isolation"] { #expect(linaCodec.contains(flag)) }
        #expect(plan[checks[2]].arguments.contains(PinnedInstall.linaCodec.commit))
    }

    @Test func trackingFetchesNumberedModelsByDigest() throws {
        let root = try PinnedInstallTests.scratch("tracker-plan")
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = try TrackerRuntime.installPlan(basePython: Self.homebrew314, locks: Self.lockRoot, environment: root)
        let installs = Self.installs(plan)
        try #require(installs.count == 1)
        #expect(installs[0].arguments.contains("--require-hashes") && installs[0].arguments.contains(":all:"))
        #expect(installs[0].arguments.last!.hasSuffix("tracker/requirements-py3.14.txt"))
        let fetches = plan.filter { $0.label.hasPrefix("Fetching") }
        let expected = [
            (PinnedInstall.trackerFaceModel, "face_landmarker.task"),
            (PinnedInstall.trackerPoseModel, "pose_landmarker.task"),
            (PinnedInstall.trackerHandModel, "hand_landmarker.task"),
        ]
        #expect(fetches.count == expected.count)
        for (command, (file, name)) in zip(fetches, expected) {
            #expect(command.arguments[3] == root.appendingPathComponent("models/\(name)").path)
            #expect(command.arguments[4].hasPrefix("https://storage.googleapis.com/mediapipe-models/"))
            #expect(command.arguments[4].contains("/float16/1/") && !command.arguments[4].contains("latest"))
            #expect(command.arguments[5] == file.sha256)
            #expect(command.arguments[6] == "=https")
        }
        // The runtime still reads the models where the old installer put them.
        #expect(TrackerRuntime.model.lastPathComponent == "face_landmarker.task")
        #expect(TrackerRuntime.poseModel.lastPathComponent == "pose_landmarker.task")
        #expect(TrackerRuntime.handModel.lastPathComponent == "hand_landmarker.task")
    }

    /// macOS's own 3.9 — the one every one of these used to be installed on — and anything
    /// else the locks do not cover is refused before a command runs: as the base of a new
    /// environment, and over one an older install left when there is no covered Python to
    /// make it again with.
    @Test func aPythonTheLocksDoNotCoverIsRefused() throws {
        let root = try PinnedInstallTests.scratch("python-refused")
        defer { try? FileManager.default.removeItem(at: root) }
        typealias Plan = (URL?, URL) throws -> [PinnedInstall.Command]
        let plans: [(String, [String], Plan)] = [
            ("MFLUX", PinnedInstall.mfluxPythons, { try MFluxRuntime.installPlan(basePython: $0, locks: Self.lockRoot, environment: $1) }),
            ("voice", PinnedInstall.voicePythons, { try VoiceRuntime.toolsInstallPlan(basePython: $0, locks: Self.lockRoot, environment: $1) }),
            ("LuxTTS", PinnedInstall.luxTTSPythons, { try VoiceRuntime.luxTTSInstallPlan(basePython: $0, git: Self.git, locks: Self.lockRoot, environment: $1) }),
            ("tracker", PinnedInstall.trackerPythons, { try TrackerRuntime.installPlan(basePython: $0, locks: Self.lockRoot, environment: $1) }),
        ]
        for (tool, supported, plan) in plans {
            let fresh = root.appendingPathComponent("\(tool)-fresh")
            for python in [nil, "/usr/bin/python3", "/opt/homebrew/bin/python3", "/opt/homebrew/bin/python3.9",
                           "/opt/homebrew/bin/python3.11", "/opt/homebrew/bin/python3.15"] {
                #expect(throws: PinnedInstall.PlanError.self, "\(tool) \(python ?? "none")") {
                    try plan(python.map { URL(fileURLWithPath: $0) }, fresh)
                }
            }
            let old = root.appendingPathComponent("\(tool)-old")
            try PinnedInstallTests.fakeEnvironment(at: old, version: "3.9.6")
            #expect(throws: PinnedInstall.PlanError.self, "\(tool) over a 3.9 environment") {
                try plan(URL(fileURLWithPath: "/usr/bin/python3"), old)
            }
            // …and one it does cover decides by its own version, whatever the base is.
            let covered = root.appendingPathComponent("\(tool)-covered")
            try PinnedInstallTests.fakeEnvironment(at: covered, version: supported.first! + ".2")
            let kept = try plan(nil, covered)
            #expect(!kept.contains { $0.arguments.contains("venv") })
            #expect(Self.installs(kept).allSatisfy { $0.arguments.last!.hasSuffix("py\(supported.first!).txt")
                || $0.arguments.contains("--no-index") })
        }
        let error = PinnedInstall.PlanError.unsupportedPython(tool: "The voice tools", found: "3.12", supported: PinnedInstall.voicePythons)
        #expect(error.localizedDescription.contains("3.13 or 3.14") && error.localizedDescription.contains("python@3.14"))
    }

    /// An environment an older install made with a Python no lock covers is the app's own, and
    /// is made again with a covered interpreter, rather than refused on every install with
    /// advice — install a newer Python — that nothing would then use. Everything the plan
    /// keeps inside it comes back: LuxTTS's checkouts are fetched from `git init` up.
    @Test func anEnvironmentTheLocksDoNotCoverIsMadeAgain() throws {
        let root = try PinnedInstallTests.scratch("python-remade")
        defer { try? FileManager.default.removeItem(at: root) }
        typealias Plan = (URL?, URL) throws -> [PinnedInstall.Command]
        let plans: [(String, Plan)] = [
            ("MFLUX", { try MFluxRuntime.installPlan(basePython: $0, locks: Self.lockRoot, environment: $1) }),
            ("voice", { try VoiceRuntime.toolsInstallPlan(basePython: $0, locks: Self.lockRoot, environment: $1) }),
            ("LuxTTS", { try VoiceRuntime.luxTTSInstallPlan(basePython: $0, git: Self.git, locks: Self.lockRoot, environment: $1) }),
            ("tracker", { try TrackerRuntime.installPlan(basePython: $0, locks: Self.lockRoot, environment: $1) }),
        ]
        for (tool, plan) in plans {
            for old in ["3.9.6", "3.15.0"] {
                let environment = root.appendingPathComponent("\(tool)-\(old)")
                try PinnedInstallTests.fakeEnvironment(at: environment, version: old)
                for checkout in ["luxtts", "linacodec"] {
                    try FileManager.default.createDirectory(
                        at: environment.appendingPathComponent("\(checkout)/.git"),
                        withIntermediateDirectories: true
                    )
                }
                let commands = try plan(Self.homebrew314, environment)
                #expect(commands.first?.executable == Self.homebrew314, "\(tool) over \(old)")
                #expect(commands.first?.arguments == ["-m", "venv", "--clear", environment.path],
                        "\(tool) over \(old)")
                #expect(!Self.installs(commands).isEmpty)
                #expect(Self.installs(commands).allSatisfy {
                    $0.arguments.last!.hasSuffix("py3.14.txt") || $0.arguments.contains("--no-index")
                }, "\(tool) over \(old) installed another Python's lock")
                if tool == "LuxTTS" {
                    for checkout in ["luxtts", "linacodec"] {
                        let path = environment.appendingPathComponent(checkout).path
                        let initialise = commands.firstIndex { $0.arguments == ["init", "--quiet", path] }
                        let fetch = commands.firstIndex { $0.arguments.starts(with: ["-C", path, "fetch"]) }
                        #expect(initialise != nil && fetch != nil && initialise! < fetch!,
                                "\(checkout) is cleared with the environment and must be made again")
                    }
                }
            }
        }
    }

    /// MFLUX and the voice tools share one environment. Making it again for one clears the
    /// other out of it, so the other goes back in — MFLUX's locks cover every Python the voice
    /// tools' do, and the voice tools go back only when theirs cover the new one.
    @Test func remakingTheSharedEnvironmentPutsBackWhatWasInIt() throws {
        let root = try PinnedInstallTests.scratch("shared-remade")
        defer { try? FileManager.default.removeItem(at: root) }
        func locks(_ plan: [PinnedInstall.Command]) -> [String] {
            Self.installs(plan).map { URL(fileURLWithPath: $0.arguments.last!).lastPathComponent }
        }

        // MFLUX installed on 3.12, then the voice tools, whose floor is 3.13.
        let mflux312 = root.appendingPathComponent("mflux-3.12")
        try PinnedInstallTests.fakeEnvironment(at: mflux312, version: "3.12.9")
        FileManager.default.createFile(
            atPath: mflux312.appendingPathComponent("bin/mflux-generate").path, contents: Data(),
            attributes: [.posixPermissions: 0o755]
        )
        let voice = try VoiceRuntime.toolsInstallPlan(
            basePython: Self.homebrew314, locks: Self.lockRoot, environment: mflux312
        )
        #expect(voice.first?.arguments == ["-m", "venv", "--clear", mflux312.path])
        #expect(locks(voice) == ["mflux-py3.14.txt", "build-py3.14.txt", "voice-py3.14.txt"])

        // The voice tools on macOS's 3.9, from before the locks, then MFLUX.
        let voice39 = root.appendingPathComponent("voice-3.9")
        try PinnedInstallTests.fakeEnvironment(at: voice39, version: "3.9.6")
        try FileManager.default.createDirectory(
            at: voice39.appendingPathComponent("lib/python3.9/site-packages/mlx_audio"),
            withIntermediateDirectories: true
        )
        let mflux = try MFluxRuntime.installPlan(
            basePython: Self.homebrew314, locks: Self.lockRoot, environment: voice39
        )
        #expect(mflux.first?.arguments == ["-m", "venv", "--clear", voice39.path])
        #expect(locks(mflux) == ["mflux-py3.14.txt", "build-py3.14.txt", "voice-py3.14.txt"])
        // …and made with 3.12, which the voice locks do not cover, only MFLUX goes in.
        let on312 = try MFluxRuntime.installPlan(
            basePython: URL(fileURLWithPath: "/opt/homebrew/bin/python3.12"),
            locks: Self.lockRoot, environment: voice39
        )
        #expect(locks(on312) == ["mflux-py3.12.txt"])
    }

    /// The Python an environment was made from has been uninstalled (`brew uninstall
    /// python@3.12`): its `bin/python3` still links to it, dangling. A plain `venv` over that
    /// leaves the link as it is and every install fails at its first pip, so it is made again
    /// like any other environment that cannot run — and what shared it goes back in.
    @Test func anEnvironmentWhosePythonWasUninstalledIsMadeAgain() throws {
        let root = try PinnedInstallTests.scratch("python-uninstalled")
        defer { try? FileManager.default.removeItem(at: root) }
        func orphaned(_ name: String) throws -> URL {
            let environment = root.appendingPathComponent(name, isDirectory: true)
            let bin = environment.appendingPathComponent("bin", isDirectory: true)
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            try "home = \(root.path)/gone/bin\nversion = 3.12.9\n".write(
                to: environment.appendingPathComponent("pyvenv.cfg"),
                atomically: true, encoding: .utf8
            )
            try FileManager.default.createSymbolicLink(
                atPath: bin.appendingPathComponent("python3.12").path,
                withDestinationPath: root.appendingPathComponent("gone/bin/python3.12").path
            )
            try FileManager.default.createSymbolicLink(
                atPath: bin.appendingPathComponent("python3").path,
                withDestinationPath: "python3.12"
            )
            FileManager.default.createFile(
                atPath: bin.appendingPathComponent("mflux-generate").path, contents: Data(),
                attributes: [.posixPermissions: 0o755]
            )
            try FileManager.default.createDirectory(
                at: environment.appendingPathComponent("lib/python3.12/site-packages/mlx_audio"),
                withIntermediateDirectories: true
            )
            return environment
        }
        func locks(_ plan: [PinnedInstall.Command]) -> [String] {
            Self.installs(plan).map { URL(fileURLWithPath: $0.arguments.last!).lastPathComponent }
        }

        // 3.12 is a version MFLUX's locks cover; the environment is still unusable.
        let forMFlux = try orphaned("mflux")
        let mflux = try MFluxRuntime.installPlan(
            basePython: Self.homebrew314, locks: Self.lockRoot, environment: forMFlux
        )
        #expect(mflux.first?.arguments == ["-m", "venv", "--clear", forMFlux.path])
        #expect(locks(mflux) == ["mflux-py3.14.txt", "build-py3.14.txt", "voice-py3.14.txt"])

        let forVoice = try orphaned("voice")
        let voice = try VoiceRuntime.toolsInstallPlan(
            basePython: Self.homebrew314, locks: Self.lockRoot, environment: forVoice
        )
        #expect(voice.first?.arguments == ["-m", "venv", "--clear", forVoice.path])
        #expect(locks(voice) == ["mflux-py3.14.txt", "build-py3.14.txt", "voice-py3.14.txt"])

        let forTracker = try orphaned("tracker")
        let tracker = try TrackerRuntime.installPlan(
            basePython: Self.homebrew314, locks: Self.lockRoot, environment: forTracker
        )
        #expect(tracker.first?.arguments == ["-m", "venv", "--clear", forTracker.path])
    }

    @Test func theNewestCoveredInterpreterIsTheBase() {
        let installed: Set<String> = ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/opt/homebrew/bin/python3.13",
                                      "/usr/local/bin/python3.14", "/opt/homebrew/bin/python3.12"]
        let pick = { (versions: [String]) in
            PinnedInstall.basePython(for: versions, isExecutable: installed.contains)?.path
        }
        #expect(pick(["3.12", "3.13", "3.14"]) == "/usr/local/bin/python3.14")
        #expect(pick(["3.12", "3.13"]) == "/opt/homebrew/bin/python3.13")
        #expect(pick(["3.11"]) == nil, "never a bare python3 of unknown version")
        #expect(PinnedInstall.basePython(for: ["3.13"], isExecutable: { $0 == "/Library/Frameworks/Python.framework/Versions/3.13/bin/python3.13" })?.path
                == "/Library/Frameworks/Python.framework/Versions/3.13/bin/python3.13")
    }

    // MARK: - Laya

    @Test func layaTakesOnlyAnInterpreterItsLocksCover() {
        #expect(LayaRuntime.locatePython(candidates: ["/usr/bin/python3"], version: { _ in (3, 15) }) == nil)
        #expect(LayaRuntime.locatePython(candidates: ["/usr/bin/python3"], version: { _ in (3, 10) }) == nil)
        #expect(LayaRuntime.locatePython(candidates: ["/usr/bin/python3"], version: { _ in (3, 11) })?.path == "/usr/bin/python3")
        #expect(LayaPackage.lockedPythons == PinnedInstall.layaPythons)
    }

    /// An environment an older install made with a Python no lock covers is left as it is
    /// and named, before anything is downloaded into it.
    @Test func layaRefusesAnEnvironmentItsLocksDoNotCover() async throws {
        let library = try PinnedInstallTests.scratch("laya-old-python")
        defer { try? FileManager.default.removeItem(at: library) }
        let environment = LayaRuntime.environmentDirectory(library: library)
        try PinnedInstallTests.fakeEnvironment(at: environment, version: "3.10.14")
        let pip = environment.appendingPathComponent("bin/pip")
        try "#!/bin/sh\necho ran >> \"$(dirname \"$0\")/pip.marker\"\n".write(to: pip, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pip.path)

        let runtime = LayaRuntime(locks: Self.lockRoot)
        await runtime.configure(library: { library }, script: { nil })
        await #expect(throws: LayaInstallError.unsupportedPython(found: "3.10", environment: environment.path)) {
            try await runtime.install(checkpoint: .english) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: environment.appendingPathComponent("bin/pip.marker").path))
    }

    // MARK: - LinaCodec against real pip

    /// A source tree with its own tiny build backend, so building it needs nothing installed.
    private func package(named name: String, requires: [String], at directory: URL) throws {
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(name), withIntermediateDirectories: true)
        try "VALUE = 1\n".write(to: directory.appendingPathComponent("\(name)/__init__.py"), atomically: true, encoding: .utf8)
        try """
            [build-system]
            requires = []
            build-backend = "backend"
            backend-path = ["."]
            """.write(to: directory.appendingPathComponent("pyproject.toml"), atomically: true, encoding: .utf8)
        let requirements = requires.map { "Requires-Dist: \($0)\\n" }.joined()
        try """
            import os, zipfile
            NAME = "\(name)"
            META = "Metadata-Version: 2.1\\nName: \(name)\\nVersion: 1.0\\n\(requirements)"
            def _info(d):
                os.makedirs(d, exist_ok=True)
                open(os.path.join(d, "METADATA"), "w").write(META)
                open(os.path.join(d, "WHEEL"), "w").write("Wheel-Version: 1.0\\nGenerator: t\\nRoot-Is-Purelib: true\\nTag: py3-none-any\\n")
            def get_requires_for_build_wheel(config_settings=None): return []
            def prepare_metadata_for_build_wheel(directory, config_settings=None):
                _info(os.path.join(directory, NAME + "-1.0.dist-info")); return NAME + "-1.0.dist-info"
            def build_wheel(directory, config_settings=None, metadata_directory=None):
                wheel = NAME + "-1.0-py3-none-any.whl"
                with zipfile.ZipFile(os.path.join(directory, wheel), "w") as z:
                    z.write(os.path.join(NAME, "__init__.py"), NAME + "/__init__.py")
                    z.writestr(NAME + "-1.0.dist-info/METADATA", META)
                    z.writestr(NAME + "-1.0.dist-info/WHEEL", "Wheel-Version: 1.0\\nGenerator: t\\nRoot-Is-Purelib: true\\nTag: py3-none-any\\n")
                    z.writestr(NAME + "-1.0.dist-info/RECORD", "".join(
                        f"{name},,\\n" for name in (NAME + "/__init__.py", NAME + "-1.0.dist-info/METADATA",
                                                   NAME + "-1.0.dist-info/WHEEL", NAME + "-1.0.dist-info/RECORD")))
                return wheel
            """.write(to: directory.appendingPathComponent("backend.py"), atomically: true, encoding: .utf8)
    }

    /// The one install that cannot be hash-checked by pip is fenced the other way: the tree
    /// is the commit git just verified, and pip is given no index to fetch anything from and
    /// no license to install what the tree declares it needs.
    @Test(.enabled(if: PinnedInstallTests.pythonWithVenv != nil && PinnedInstallTests.hasGit))
    func aVerifiedCheckoutInstallsOfflineWithoutItsDependencies() throws {
        let root = try PinnedInstallTests.scratch("linacodec")
        defer { try? FileManager.default.removeItem(at: root) }
        let upstream = root.appendingPathComponent("upstream")
        try package(named: "codecpkg", requires: ["some-dependency-nobody-reviewed"], at: upstream)
        try PinnedInstallTests.git(["init", "--quiet"], in: upstream)
        try PinnedInstallTests.git(["config", "uploadpack.allowAnySHA1InWant", "true"], in: upstream)
        try PinnedInstallTests.git(["add", "."], in: upstream)
        try PinnedInstallTests.git(["commit", "--quiet", "-m", "reviewed"], in: upstream)
        let source = PinnedInstall.Source(
            name: "Codec", repository: upstream.absoluteString,
            commit: try PinnedInstallTests.git(["rev-parse", "HEAD"], in: upstream), lockDirectory: "x"
        )
        let venv = root.appendingPathComponent("venv")
        let made = try PinnedInstallTests.run([PinnedInstall.Command(
            label: "venv", executable: PinnedInstallTests.pythonWithVenv!, arguments: ["-m", "venv", venv.path]
        )])
        try #require(made.status == 0, "\(made.output)")
        let python = venv.appendingPathComponent("bin/python")
        let checkout = root.appendingPathComponent("checkout")
        let offline = ["PIP_CONFIG_FILE": "/dev/null", "PIP_CACHE_DIR": root.appendingPathComponent("cache").path]
        let steps = PinnedInstall.fetch(source, into: checkout, git: PinnedInstallTests.gitURL) + [
            PinnedInstall.verify(source, in: checkout, git: PinnedInstallTests.gitURL),
            PinnedInstall.pipInstallVerifiedCheckout(python: python, checkout: checkout, label: "install"),
        ]
        let imports = { (module: String) throws -> Bool in
            try PinnedInstallTests.run([PinnedInstall.Command(label: "import", executable: python, arguments: ["-c", "import \(module)"])]).status == 0
        }

        // Edited after the fetch: the check before the install stops it.
        #expect(try PinnedInstallTests.run(Array(steps.dropLast(2)), environment: offline).status == 0)
        try "VALUE = 2\n".write(to: checkout.appendingPathComponent("codecpkg/__init__.py"), atomically: true, encoding: .utf8)
        let edited = try PinnedInstallTests.run(Array(steps.suffix(2)), environment: offline)
        #expect(edited.status != 0 && edited.output.contains("is not the reviewed revision"), "\(edited.output)")
        #expect(try !imports("codecpkg"))

        // The reviewed tree installs, and the dependency it declares is not fetched.
        let clean = try PinnedInstallTests.run(steps, environment: offline)
        #expect(clean.status == 0, "\(clean.output)")
        #expect(try imports("codecpkg"))
    }

    // MARK: - Voice models

    /// Every local voice model runs with the repositories it reads pinned — its own first,
    /// since that is the one the command names.
    @Test func everyVoiceRunReadsOnlyPinnedRepositories() throws {
        let local = VoiceCatalog.all.filter { [.mlxAudio, .mlxSpeech, .luxTTS].contains($0.backend) }
        #expect(local.count == 7)
        for entry in local {
            let repositories = VoiceRuntime.pinnedRepositories(for: entry, request: nil)
            #expect(!repositories.isEmpty, "\(entry.id)")
            if entry.backend != .mlxSpeech { #expect(repositories.first == entry.repo, "\(entry.id)") }
            for repository in repositories {
                let model = try PinnedInstall.HubModel.load(repository, from: Self.lockRoot)
                #expect(model.revision.count == 40 && model.revision.allSatisfy(\.isHexDigit), "\(repository)")
                #expect(!model.files.isEmpty)
                for file in model.files {
                    #expect(file.sha256.count == 64 && file.sha256.allSatisfy(\.isHexDigit), "\(repository)/\(file.path)")
                    #expect(file.size >= 0 && !file.path.hasPrefix("/") && !file.path.contains(".."))
                }
            }
        }
        // mlx-speech resolves its alias to this repository.
        #expect(VoiceRuntime.pinnedRepositories(for: VoiceCatalog.mossSoundEffect, request: nil).first
                == "appautomaton/openmoss-sound-effect-mlx")
        // Kokoro's voices come from a repository mlx-audio names itself; every voice the app
        // offers is in it.
        let voices = try PinnedInstall.HubModel.load("prince-canuma/Kokoro-82M", from: Self.lockRoot).files.map(\.path)
        #expect(Set(voices) == Set(VoiceCatalog.kokoro.voices.map { "voices/\($0).safetensors" }))
    }

    /// CSM with no reference speaks with the stock prompt from its own pinned repository —
    /// not the gated sesame/csm-1b nobody can pin — and Whisper turbo writes its transcript.
    @Test func csmWithoutAReferenceUsesItsPinnedPrompt() throws {
        let csm = try PinnedInstall.HubModel.load(VoiceCatalog.csm.repo, from: Self.lockRoot)
        #expect(csm.files.contains { $0.path == VoiceRuntime.csmDefaultPrompt })
        let prompt = URL(fileURLWithPath: "/cache/hub/prompt.wav")
        let bare = SpeechRequest(entryID: "csm-1b", text: "Hi", outputDirectory: URL(fileURLWithPath: "/tmp/out"))
        let arguments = VoiceRuntime.mlxAudioSpeakArguments(
            entry: VoiceCatalog.csm, request: bare, scratch: URL(fileURLWithPath: "/tmp/s"), defaultReference: prompt
        )
        #expect(arguments.contains("--ref_audio") && arguments.contains(prompt.path) && !arguments.contains("--ref_text"))
        #expect(VoiceRuntime.pinnedRepositories(for: VoiceCatalog.csm, request: bare).contains(VoiceCatalog.whisperTurbo.repo))
        #expect(!VoiceRuntime.pinnedRepositories(for: VoiceCatalog.csm, request: nil).contains("sesame/csm-1b"))

        var own = bare
        own.referenceAudio = URL(fileURLWithPath: "/tmp/me.wav")
        own.referenceText = "what I said"
        let mine = VoiceRuntime.mlxAudioSpeakArguments(
            entry: VoiceCatalog.csm, request: own, scratch: URL(fileURLWithPath: "/tmp/s"), defaultReference: prompt
        )
        #expect(mine.contains("/tmp/me.wav") && !mine.contains(prompt.path))
        #expect(!VoiceRuntime.pinnedRepositories(for: VoiceCatalog.csm, request: own).contains(VoiceCatalog.whisperTurbo.repo))
        // Kokoro has no reference to default.
        #expect(!VoiceRuntime.mlxAudioSpeakArguments(
            entry: VoiceCatalog.kokoro, request: bare, scratch: URL(fileURLWithPath: "/tmp/s"), defaultReference: nil
        ).contains("--ref_audio"))
    }

    @Test func voiceModelsRunOffline() {
        let cache = URL(fileURLWithPath: "/Volumes/Big/Local Models/Engine Cache")
        let environment = VoiceRuntime.childEnvironment(hubCache: cache)
        #expect(environment["HF_HUB_OFFLINE"] == "1" && environment["TRANSFORMERS_OFFLINE"] == "1")
        #expect(environment["HF_HUB_CACHE"] == cache.path + "/hub")
        #expect(VoiceRuntime.childEnvironment()["HF_HUB_OFFLINE"] == "1")
        #expect(VoiceRuntime.hubDirectory(hubCache: nil, environment: ["HF_HOME": "/x/hf"]).path == "/x/hf/hub")
        #expect(VoiceRuntime.hubDirectory(hubCache: nil, environment: ["HF_HUB_CACHE": "/y", "HF_HOME": "/x"]).path == "/y")
        #expect(VoiceRuntime.hubDirectory(hubCache: nil, environment: [:]).path.hasSuffix("/.cache/huggingface/hub"))
        #expect(VoiceRuntime.diagnosis(from: "huggingface_hub.errors.LocalEntryNotFoundError: offline")
            .contains("only load reviewed files"))
    }

    // MARK: - Voice models against real curl

    /// A Hub stand-in: `<server>/<repository>/resolve/<revision>/<path>`.
    private func serve(_ files: [String: Data], repository: String, revision: String, at server: URL) throws -> PinnedInstall.HubModel {
        var records: [PinnedInstall.HubModel.File] = []
        for (path, data) in files.sorted(by: { $0.key < $1.key }) {
            let url = server.appendingPathComponent("\(repository)/resolve/\(revision)/\(path)")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            records.append(.init(path: path, sha256: PinnedInstallTests.sha256(data), size: Int64(data.count)))
        }
        return PinnedInstall.HubModel(repository: repository, revision: revision, files: records)
    }

    @Test func aPinnedModelIsPutInPlaceTheWayTheHubCacheLaysItOut() throws {
        let root = try PinnedInstallTests.scratch("hub-files")
        defer { try? FileManager.default.removeItem(at: root) }
        let server = root.appendingPathComponent("server"), hub = root.appendingPathComponent("hub")
        let revision = String(repeating: "a1", count: 20)
        let weights = Data("reviewed weights".utf8), config = Data("{\"reviewed\": true}".utf8)
        // An empty file too: some repositories ship an empty `__init__.py`.
        var model = try serve(["model.safetensors": weights, "voices/one.safetensors": config, "pkg/__init__.py": Data()],
                              repository: "org/model", revision: revision, at: server)
        func fetch(_ model: PinnedInstall.HubModel) throws -> PinnedInstallTests.Outcome {
            try PinnedInstallTests.run(model.fetchCommands(hub: hub, server: server, protocols: "=file"))
        }

        // A changed file upstream: refused, and nothing is left in the cache.
        var changed = model
        changed.files[0].sha256 = PinnedInstallTests.sha256(Data("other weights".utf8))
        let refused = try fetch(changed)
        #expect(refused.status != 0 && refused.output.contains("did not match its reviewed SHA-256"), "\(refused.output)")
        let snapshot = model.snapshot(hub: hub)
        #expect(!FileManager.default.fileExists(atPath: snapshot.appendingPathComponent("model.safetensors").path))
        let blobs = (try? FileManager.default.contentsOfDirectory(atPath: model.cacheDirectory(hub: hub).appendingPathComponent("blobs").path)) ?? []
        #expect(blobs.isEmpty, "\(blobs)")

        // The reviewed files: blobs by digest, the snapshot linking to them relatively.
        #expect(try fetch(model).status == 0)
        for file in model.files {
            let entry = snapshot.appendingPathComponent(file.path)
            let link = try FileManager.default.destinationOfSymbolicLink(atPath: entry.path)
            #expect(link.hasPrefix("../") && link.hasSuffix("blobs/\(file.sha256)"), "\(link)")
            #expect(PinnedInstallTests.sha256(try Data(contentsOf: entry)) == file.sha256)
        }
        #expect(try Data(contentsOf: snapshot.appendingPathComponent("voices/one.safetensors")) == config)

        // A copy an older download of another revision left is used, not fetched: the
        // server is gone and it still succeeds.
        try FileManager.default.removeItem(at: server)
        try FileManager.default.removeItem(at: snapshot)
        #expect(try fetch(model).status == 0)
        #expect(try Data(contentsOf: snapshot.appendingPathComponent("model.safetensors")) == weights)

        // A tampered file under the snapshot is found; with nothing right to put back and
        // nowhere to fetch from, it fails — and the model does not run.
        try FileManager.default.removeItem(at: snapshot.appendingPathComponent("model.safetensors"))
        try Data("tampered".utf8).write(to: snapshot.appendingPathComponent("model.safetensors"))
        try Data("tampered too".utf8).write(to: model.cacheDirectory(hub: hub).appendingPathComponent("blobs/\(model.files[0].sha256)"))
        #expect(try fetch(model).status != 0)
        model = try serve(["model.safetensors": weights, "voices/one.safetensors": config, "pkg/__init__.py": Data()],
                          repository: "org/model", revision: revision, at: server)
        #expect(try fetch(model).status == 0)
        #expect(try Data(contentsOf: snapshot.appendingPathComponent("model.safetensors")) == weights)
    }

    /// The runtime end to end: files put in place and `main` pointed at the pinned commit
    /// before a model runs; a second run touches nothing; a file that changed afterwards is
    /// checked again; a repository with no reviewed manifest does not run.
    @Test func theRuntimePreparesPinnedModelsBeforeRunning() async throws {
        let root = try PinnedInstallTests.scratch("hub-runtime")
        defer { try? FileManager.default.removeItem(at: root) }
        let server = root.appendingPathComponent("server"), engine = root.appendingPathComponent("Engine Cache")
        let locks = root.appendingPathComponent("locks")
        let revision = String(repeating: "b2", count: 20)
        let model = try serve(["config.json": Data("{}".utf8), "model.safetensors": Data("weights".utf8)],
                              repository: "org/voice", revision: revision, at: server)
        let manifest = PinnedInstall.HubModel.manifest("org/voice", in: locks)
        try FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(model).write(to: manifest)
        let hub = VoiceRuntime.hubDirectory(hubCache: engine)
        // What an older, unpinned run left: `main` at some other commit.
        let refs = model.cacheDirectory(hub: hub).appendingPathComponent("refs")
        try FileManager.default.createDirectory(at: refs, withIntermediateDirectories: true)
        try Data(String(repeating: "c3", count: 20).utf8).write(to: refs.appendingPathComponent("main"))

        let runtime = VoiceRuntime(locks: locks, hubServer: server, hubProtocols: "=file")
        try await runtime.preparePinnedModels(["org/voice"], hubCache: engine) { _ in }
        #expect(try String(contentsOf: refs.appendingPathComponent("main"), encoding: .utf8) == revision)
        #expect(VoiceRuntime.isInPlace(model, hub: hub))

        try FileManager.default.removeItem(at: server)
        try await runtime.preparePinnedModels(["org/voice"], hubCache: engine) { _ in }

        // Replaced after it was checked: the next run checks it again, and without the
        // reviewed bytes anywhere it refuses to run.
        let weights = model.snapshot(hub: hub).appendingPathComponent("model.safetensors").resolvingSymlinksInPath()
        try Data("swapped!".utf8).write(to: weights)
        #expect(!VoiceRuntime.isInPlace(model, hub: hub))
        await #expect(throws: VoiceRuntimeError.self) {
            try await runtime.preparePinnedModels(["org/voice"], hubCache: engine) { _ in }
        }
        await #expect(throws: VoiceRuntimeError.self) {
            try await runtime.preparePinnedModels(["org/unreviewed"], hubCache: engine) { _ in }
        }
    }
}
