import CryptoKit
import Foundation
import Testing
@testable import SiliconControl
@testable import SiliconRuntime

/// The optional media installers run other people's code, so what they fetch is pinned:
/// a reviewed commit, a hash-locked dependency set, digest-checked weights. These pin the
/// locks the app ships, the plans that use them, and — against real git, curl, pip and uv —
/// that a moved commit, a changed file or a changed wheel is refused before it runs.
@Suite("Pinned media installers", .serialized)
struct PinnedInstallTests {

    static let lockRoot = PinnedInstall.defaultLockRoot()

    /// Every lock a plan can name, and nothing else.
    static let expectedLocks: [(source: PinnedInstall.Source, files: [String])] = [
        (PinnedInstall.openMontage, PinnedInstall.openMontagePythons.flatMap {
            ["requirements-py\($0).txt", "piper-py\($0).txt"]
        }),
        (PinnedInstall.livePortrait, ["requirements-py3.11.txt", "build-py3.11.txt"]),
        (PinnedInstall.deepLiveCam, PinnedInstall.deepLiveCamPythons.flatMap {
            ["requirements-py\($0).txt", "build-py\($0).txt"]
        }),
    ]

    // MARK: - The locks

    /// Each lock names the upstream commit it was resolved from, and that is the commit the
    /// app fetches; every requirement is an exact version with at least one SHA-256; and
    /// nothing in it can point pip somewhere unreviewed.
    @Test func everyLockIsFullyPinnedAndNamesTheReviewedCommit() throws {
        for (source, files) in Self.expectedLocks {
            let directory = Self.lockRoot.appendingPathComponent(source.lockDirectory)
            let present = try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .filter { $0.hasSuffix(".txt") }
            #expect(Set(present) == Set(files), "\(source.lockDirectory)")

            for file in files {
                let text = try String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8)
                #expect(text.contains("\n# Source: \(source.repository) \(source.commit)\n"),
                        "\(file) was not resolved from the pinned \(source.name) commit")
                let requirements = try Self.requirements(in: text)
                #expect(!requirements.isEmpty, "\(file)")
                for requirement in requirements {
                    #expect(requirement.range(of: #"^[A-Za-z0-9._-]+==[A-Za-z0-9.+!_-]+ "#,
                                              options: .regularExpression) != nil,
                            "\(file): not an exact pin: \(requirement.prefix(80))")
                    #expect(requirement.range(of: #"--hash=sha256:[0-9a-f]{64}"#,
                                              options: .regularExpression) != nil,
                            "\(file): no hash: \(requirement.prefix(80))")
                }
                let directives = text.split(separator: "\n").map(String.init)
                    .filter { $0.hasPrefix("-") }
                var allowed = ["--index-url https://pypi.org/simple"]
                if source == PinnedInstall.livePortrait {
                    allowed.append("--extra-index-url https://download.pytorch.org/whl/cpu")
                }
                #expect(directives.allSatisfy(allowed.contains), "\(file): \(directives)")
            }
        }
    }

    /// Build tools are installed first and then used for the source-only packages, so they
    /// must be the very versions the main lock resolved against.
    @Test func buildToolsAreTheVersionsTheMainLockNames() throws {
        let pairs = [
            (PinnedInstall.livePortrait, PinnedInstall.livePortraitPython),
        ] + PinnedInstall.deepLiveCamPythons.map { (PinnedInstall.deepLiveCam, $0) }
        for (source, python) in pairs {
            let build = try Self.pins(PinnedInstall.lock("build", for: source, python: python, in: Self.lockRoot))
            let main = try Self.pins(PinnedInstall.lock("requirements", for: source, python: python, in: Self.lockRoot))
            #expect(build["setuptools"] != nil, "\(source.name) \(python)")
            for (name, version) in build where main[name] != nil {
                #expect(main[name] == version, "\(source.name) \(python): \(name)")
            }
        }
        for python in PinnedInstall.openMontagePythons {
            let main = try Self.pins(PinnedInstall.lock(
                "requirements", for: PinnedInstall.openMontage, python: python, in: Self.lockRoot
            ))
            let piper = try Self.pins(PinnedInstall.lock(
                "piper", for: PinnedInstall.openMontage, python: python, in: Self.lockRoot
            ))
            #expect(piper["piper-tts"] != nil)
            for (name, version) in piper where main[name] != nil {
                #expect(main[name] == version, "Piper would move \(name) in OpenMontage's \(python) environment")
            }
        }
    }

    // MARK: - The plans

    @Test func livePortraitInstallsTheReviewedCommitLockedPackagesAndCheckedWeights() throws {
        let root = try Self.scratch("liveportrait-plan")
        defer { try? FileManager.default.removeItem(at: root) }
        let uv = URL(fileURLWithPath: "/opt/homebrew/bin/uv")
        let git = URL(fileURLWithPath: "/usr/bin/git")
        let plan = PortraitAnimator.installPlan(uv: uv, git: git, locks: Self.lockRoot, environment: root)
        let commit = PinnedInstall.livePortrait.commit

        #expect(!plan.contains { $0.arguments.contains("clone") || $0.executable.lastPathComponent == "hf" })
        #expect(plan.contains { $0.arguments.contains("fetch") && $0.arguments.last == commit })
        let check = try #require(plan.firstIndex { $0.label.hasPrefix("Checking") })
        let installs = plan.indices.filter { plan[$0].arguments.starts(with: ["pip", "install"]) }
        #expect(installs.count == 2)
        #expect(installs.allSatisfy { $0 > check }, "nothing is installed from an unchecked checkout")
        let build = plan[installs[0]].arguments, main = plan[installs[1]].arguments
        #expect(build.last!.hasSuffix("liveportrait/build-py3.11.txt"))
        #expect(main.last!.hasSuffix("liveportrait/requirements-py3.11.txt"))
        #expect(build.contains("--require-hashes") && main.contains("--require-hashes"))
        #expect(main.contains("--no-build-isolation"), "imageio-ffmpeg builds with the locked setuptools")
        #expect(plan.contains { $0.arguments == ["venv", "--clear", "--python", "3.11", root.appendingPathComponent("venv").path] })

        let weights = plan.filter { $0.label.hasPrefix("Fetching") }
        #expect(weights.count == PinnedInstall.livePortraitWeights.count)
        for (command, file) in zip(weights, PinnedInstall.livePortraitWeights) {
            #expect(command.arguments[3] == root.appendingPathComponent("LivePortrait/pretrained_weights/\(file.path)").path)
            #expect(command.arguments[4].hasPrefix("https://huggingface.co/KlingTeam/LivePortrait/resolve/82a4fa6735ca58432b6ce39301b4b9ee066dea47/"))
            #expect(command.arguments[5] == file.sha256)
            #expect(command.arguments[6] == "=https")
        }
    }

    @Test func aLivePortraitRerunKeepsItsEnvironment() throws {
        let root = try Self.scratch("liveportrait-rerun")
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.fakeEnvironment(at: root.appendingPathComponent("venv"), version: "3.11.13")
        let plan = PortraitAnimator.installPlan(
            uv: URL(fileURLWithPath: "/opt/homebrew/bin/uv"), git: URL(fileURLWithPath: "/usr/bin/git"),
            locks: Self.lockRoot, environment: root
        )
        #expect(!plan.contains { $0.arguments.first == "venv" })
    }

    @Test func deepLiveCamInstallsTheReviewedCommitLockedPackagesAndCheckedModels() throws {
        let root = try Self.scratch("facecam-plan")
        defer { try? FileManager.default.removeItem(at: root) }
        let models = root.appendingPathComponent("insightface/buffalo_l")
        let plan = try FaceCamRuntime.installPlan(
            basePython: URL(fileURLWithPath: "/opt/homebrew/bin/python3.13"),
            git: URL(fileURLWithPath: "/usr/bin/git"), locks: Self.lockRoot,
            environment: root, faceAnalyserModels: models
        )
        let commit = PinnedInstall.deepLiveCam.commit
        #expect(plan.first?.arguments == ["-m", "venv", root.path])
        #expect(!plan.contains { $0.arguments.contains("clone") })
        #expect(plan.contains { $0.arguments.contains("fetch") && $0.arguments.last == commit })
        let check = try #require(plan.firstIndex { $0.label.hasPrefix("Checking") })
        let installs = plan.indices.filter { plan[$0].arguments.starts(with: ["-m", "pip", "install"]) }
        #expect(installs.count == 2 && installs.allSatisfy { $0 > check })
        #expect(plan[installs[0]].arguments.last!.hasSuffix("deep-live-cam/build-py3.13.txt"))
        #expect(plan[installs[1]].arguments.last!.hasSuffix("deep-live-cam/requirements-py3.13.txt"))
        #expect(plan[installs[1]].arguments.contains("--no-build-isolation"), "insightface builds with the locked tools")
        #expect(installs.allSatisfy { plan[$0].arguments.contains("--require-hashes") })

        // Every model is in place, checked, before the project's own downloader — which
        // skips certificate checks on macOS — could reach for it.
        let fetches = plan.filter { $0.label.hasPrefix("Fetching") }
        let expected = [(PinnedInstall.deepLiveCamSwapper,
                         root.appendingPathComponent("Deep-Live-Cam/models/inswapper_128.onnx"))]
            + PinnedInstall.deepLiveCamFaceAnalyser.map {
                ($0, models.appendingPathComponent(($0.path as NSString).lastPathComponent))
            }
        #expect(fetches.count == expected.count)
        for (command, (file, destination)) in zip(fetches, expected) {
            #expect(command.arguments[3] == destination.path)
            #expect(command.arguments[4].hasPrefix("https://huggingface.co/hacksider/deep-live-cam/resolve/581e70b61240b7928404c17900437f47cfe94133/"))
            #expect(command.arguments[5] == file.sha256)
        }
        let preCheck = try #require(plan.firstIndex {
            $0.executable.lastPathComponent == "python3" && $0.arguments.first == "-c"
        })
        #expect(plan.indices.filter { plan[$0].label.hasPrefix("Fetching") }.allSatisfy { $0 < preCheck })
    }

    @Test func deepLiveCamRefusesAPythonItsLocksDoNotCover() throws {
        let root = try Self.scratch("facecam-python")
        defer { try? FileManager.default.removeItem(at: root) }
        for python in ["/usr/bin/python3", "/opt/homebrew/bin/python3.11", "/opt/homebrew/bin/python3.14"] {
            #expect(throws: PinnedInstall.PlanError.self) {
                try FaceCamRuntime.installPlan(
                    basePython: URL(fileURLWithPath: python), git: URL(fileURLWithPath: "/usr/bin/git"),
                    locks: Self.lockRoot, environment: root
                )
            }
        }
        // An environment left by an older install decides by its own version, not the base.
        try Self.fakeEnvironment(at: root, version: "3.12.8")
        let plan = try FaceCamRuntime.installPlan(
            basePython: URL(fileURLWithPath: "/usr/bin/python3"), git: URL(fileURLWithPath: "/usr/bin/git"),
            locks: Self.lockRoot, environment: root
        )
        #expect(plan.contains { $0.arguments.last?.hasSuffix("requirements-py3.12.txt") == true })
        #expect(!plan.contains { $0.arguments.contains("venv") })
    }

    @Test func pythonVersionsComeFromNamesAndEnvironments() throws {
        #expect(PinnedInstall.pythonVersion(ofInterpreter: URL(fileURLWithPath: "/x/python3.12")) == "3.12")
        #expect(PinnedInstall.pythonVersion(ofInterpreter: URL(fileURLWithPath: "/x/python3")) == nil)
        #expect(PinnedInstall.pythonVersion(ofInterpreter: URL(fileURLWithPath: "/x/python3.12-config")) == nil)
        let root = try Self.scratch("pyvenv")
        defer { try? FileManager.default.removeItem(at: root) }
        for (line, version) in [("version = 3.13.7", "3.13"), ("version_info = 3.11", "3.11"),
                                ("version_info = 3.12.4.final.0", "3.12")] {
            try "home = /x\n\(line)\n".write(to: root.appendingPathComponent("pyvenv.cfg"), atomically: true, encoding: .utf8)
            #expect(PinnedInstall.pythonVersion(ofVirtualEnvironment: root) == version)
        }
    }

    // MARK: - Against real git

    /// A throwaway upstream with two commits; the pin is the first.
    private func upstream(in root: URL) throws -> (source: PinnedInstall.Source, first: String, second: String) {
        let upstream = root.appendingPathComponent("upstream")
        try FileManager.default.createDirectory(at: upstream, withIntermediateDirectories: true)
        try Self.git(["init", "--quiet"], in: upstream)
        // Serving an unadvertised commit by id is what GitHub does; a local upstream needs
        // telling.
        try Self.git(["config", "uploadpack.allowAnySHA1InWant", "true"], in: upstream)
        try "reviewed\n".write(to: upstream.appendingPathComponent("tool.py"), atomically: true, encoding: .utf8)
        try Self.git(["add", "tool.py"], in: upstream)
        try Self.git(["commit", "--quiet", "-m", "reviewed"], in: upstream)
        let first = try Self.git(["rev-parse", "HEAD"], in: upstream)
        try "moved on\n".write(to: upstream.appendingPathComponent("tool.py"), atomically: true, encoding: .utf8)
        try Self.git(["commit", "--quiet", "-am", "later"], in: upstream)
        let second = try Self.git(["rev-parse", "HEAD"], in: upstream)
        let source = PinnedInstall.Source(
            name: "Fixture", repository: upstream.absoluteString, commit: first, lockDirectory: "fixture"
        )
        return (source, first, second)
    }

    @Test(.enabled(if: PinnedInstallTests.hasGit))
    func aFreshInstallLandsOnThePinnedCommitNotTheBranch() throws {
        let root = try Self.scratch("git-fresh")
        defer { try? FileManager.default.removeItem(at: root) }
        let (source, first, _) = try upstream(in: root)
        let checkout = root.appendingPathComponent("checkout")

        let outcome = try Self.run(PinnedInstall.fetch(source, into: checkout, git: Self.gitURL))
        #expect(outcome.status == 0, "\(outcome.output)")
        #expect(try Self.git(["rev-parse", "HEAD"], in: checkout) == first)
        #expect(try String(contentsOf: checkout.appendingPathComponent("tool.py"), encoding: .utf8) == "reviewed\n")
    }

    @Test(.enabled(if: PinnedInstallTests.hasGit))
    func aCheckoutThatWasEditedOrMovedIsRefused() throws {
        let root = try Self.scratch("git-moved")
        defer { try? FileManager.default.removeItem(at: root) }
        let (source, _, _) = try upstream(in: root)
        let checkout = root.appendingPathComponent("checkout")
        #expect(try Self.run(PinnedInstall.fetch(source, into: checkout, git: Self.gitURL)).status == 0)
        let verify = PinnedInstall.verify(source, in: checkout, git: Self.gitURL)
        #expect(try Self.run([verify]).status == 0)

        try "edited\n".write(to: checkout.appendingPathComponent("tool.py"), atomically: true, encoding: .utf8)
        let edited = try Self.run([verify])
        #expect(edited.status != 0, "an edited tracked file")
        #expect(edited.output.contains("is not the reviewed revision \(source.commit)"), "\(edited.output)")

        try Self.git(["-c", "user.name=t", "-c", "user.email=t@example.invalid",
                      "commit", "--quiet", "-am", "someone else's"], in: checkout)
        #expect(try Self.run([verify]).status != 0, "a different commit")

        // And the next install puts the reviewed bytes back.
        #expect(try Self.run(PinnedInstall.fetch(source, into: checkout, git: Self.gitURL)).status == 0)
        #expect(try String(contentsOf: checkout.appendingPathComponent("tool.py"), encoding: .utf8) == "reviewed\n")
    }

    @Test(.enabled(if: PinnedInstallTests.hasGit))
    func aCommitUpstreamDoesNotHaveIsRefusedBeforeAnythingIsCheckedOut() throws {
        let root = try Self.scratch("git-missing")
        defer { try? FileManager.default.removeItem(at: root) }
        var (source, _, _) = try upstream(in: root)
        source.commit = "0123456789abcdef0123456789abcdef01234567"
        let checkout = root.appendingPathComponent("checkout")

        #expect(try Self.run(PinnedInstall.fetch(source, into: checkout, git: Self.gitURL)).status != 0)
        #expect(!FileManager.default.fileExists(atPath: checkout.appendingPathComponent("tool.py").path))
    }

    @Test(.enabled(if: PinnedInstallTests.hasGit))
    func anOlderInstallsCheckoutOfTheBranchIsMovedToThePin() throws {
        let root = try Self.scratch("git-existing")
        defer { try? FileManager.default.removeItem(at: root) }
        let (source, first, second) = try upstream(in: root)
        let checkout = root.appendingPathComponent("checkout")
        // What an older version did: a shallow clone of whatever the branch was.
        try Self.git(["clone", "--quiet", "--depth", "1", source.repository, checkout.path], in: root)
        #expect(try Self.git(["rev-parse", "HEAD"], in: checkout) == second)

        #expect(try Self.run(PinnedInstall.fetch(source, into: checkout, git: Self.gitURL)).status == 0)
        #expect(try Self.git(["rev-parse", "HEAD"], in: checkout) == first)
    }

    // MARK: - Against real curl

    @Test func aFileIsKeptOnlyWithItsReviewedDigest() throws {
        let root = try Self.scratch("fetch-file")
        defer { try? FileManager.default.removeItem(at: root) }
        let served = root.appendingPathComponent("served.onnx")
        let bytes = Data("the reviewed model".utf8)
        try bytes.write(to: served)
        let good = PinnedInstall.File(path: "served.onnx", url: served, sha256: Self.sha256(bytes), size: Int64(bytes.count))
        let destination = root.appendingPathComponent("models/model.onnx")
        func fetch(_ file: PinnedInstall.File) throws -> Outcome {
            try Self.run([PinnedInstall.fetch(file, to: destination, label: "model", protocols: "=file")])
        }

        var changed = good
        changed.sha256 = Self.sha256(Data("a different model".utf8))
        let refused = try fetch(changed)
        #expect(refused.status != 0)
        #expect(refused.output.contains("did not match its reviewed SHA-256"), "\(refused.output)")
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(!FileManager.default.fileExists(atPath: destination.path + ".part"))

        #expect(try fetch(good).status == 0)
        #expect(try Data(contentsOf: destination) == bytes)
        #expect(!FileManager.default.fileExists(atPath: destination.path + ".part"))

        // A correct copy is not fetched again (the source is gone and it still succeeds)...
        try FileManager.default.removeItem(at: served)
        #expect(try fetch(good).status == 0)
        // ...and a wrong one left by an unchecked download is replaced.
        try Data("tampered".utf8).write(to: destination)
        try bytes.write(to: served)
        #expect(try fetch(good).status == 0)
        #expect(try Data(contentsOf: destination) == bytes)
    }

    @Test func onlyHTTPSIsFetchedOutsideTests() {
        let command = PinnedInstall.fetch(
            PinnedInstall.deepLiveCamSwapper, to: URL(fileURLWithPath: "/tmp/x"), label: "x"
        )
        #expect(command.arguments.last == "=https")
        #expect(PinnedInstall.fetchFileScript.contains("--proto-redir \"$protocols\""))
    }

    // MARK: - Against real pip and uv

    /// A one-file wheel, built by hand so nothing is downloaded.
    private func wheel(named name: String, requires: [String] = [], in directory: URL) throws -> URL {
        let build = directory.appendingPathComponent("build-\(name)")
        let package = build.appendingPathComponent(name)
        let info = build.appendingPathComponent("\(name)-1.0.dist-info")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: info, withIntermediateDirectories: true)
        try "VALUE = 1\n".write(to: package.appendingPathComponent("__init__.py"), atomically: true, encoding: .utf8)
        let metadata = "Metadata-Version: 2.1\nName: \(name)\nVersion: 1.0\n"
            + requires.map { "Requires-Dist: \($0)\n" }.joined()
        try metadata.write(to: info.appendingPathComponent("METADATA"), atomically: true, encoding: .utf8)
        try "Wheel-Version: 1.0\nGenerator: test\nRoot-Is-Purelib: true\nTag: py3-none-any\n"
            .write(to: info.appendingPathComponent("WHEEL"), atomically: true, encoding: .utf8)
        try "\(name)/__init__.py,,\n\(name)-1.0.dist-info/METADATA,,\n\(name)-1.0.dist-info/WHEEL,,\n\(name)-1.0.dist-info/RECORD,,\n"
            .write(to: info.appendingPathComponent("RECORD"), atomically: true, encoding: .utf8)
        let wheel = directory.appendingPathComponent("\(name)-1.0-py3-none-any.whl")
        let zip = try Self.run([PinnedInstall.Command(
            label: "zip", executable: URL(fileURLWithPath: "/usr/bin/zip"),
            arguments: ["-q", "-r", wheel.path, name, "\(name)-1.0.dist-info"], workingDirectory: build
        )])
        #expect(zip.status == 0, "\(zip.output)")
        return wheel
    }

    private func lock(_ lines: [(name: String, sha256: String)], at url: URL) throws {
        try lines.map { "\($0.name)==1.0 \\\n    --hash=sha256:\($0.sha256)\n" }.joined()
            .write(to: url, atomically: true, encoding: .utf8)
    }

    @Test(.enabled(if: PinnedInstallTests.pythonWithVenv != nil))
    func pipRefusesAWheelWhoseBytesChangedAndInstallsTheReviewedOne() throws {
        let root = try Self.scratch("pip")
        defer { try? FileManager.default.removeItem(at: root) }
        let wheels = root.appendingPathComponent("wheels")
        try FileManager.default.createDirectory(at: wheels, withIntermediateDirectories: true)
        let reviewed = try wheel(named: "reviewedpkg", in: wheels)
        let dependent = try wheel(named: "dependentpkg", requires: ["reviewedpkg"], in: wheels)
        let venv = root.appendingPathComponent("venv")
        let made = try Self.run([PinnedInstall.Command(
            label: "venv", executable: Self.pythonWithVenv!, arguments: ["-m", "venv", venv.path]
        )])
        try #require(made.status == 0, "\(made.output)")
        let python = venv.appendingPathComponent("bin/python")
        let offline = ["PIP_NO_INDEX": "1", "PIP_FIND_LINKS": wheels.path,
                       "PIP_CONFIG_FILE": "/dev/null", "PIP_CACHE_DIR": root.appendingPathComponent("cache").path]
        let lockFile = root.appendingPathComponent("lock.txt")
        let install = PinnedInstall.pipInstall(python: python, lock: lockFile, label: "pip", onlyBinary: true)
        func imports(_ module: String) throws -> Bool {
            try Self.run([PinnedInstall.Command(label: "import", executable: python,
                                                arguments: ["-c", "import \(module)"])]).status == 0
        }

        try lock([("reviewedpkg", Self.sha256(Data("some other wheel".utf8)))], at: lockFile)
        let changed = try Self.run([install], environment: offline)
        #expect(changed.status != 0)
        #expect(changed.output.contains("HASHES"), "\(changed.output)")
        #expect(try !imports("reviewedpkg"))

        // A dependency the lock does not name cannot slip in beside a pinned package.
        try lock([("dependentpkg", Self.sha256(try Data(contentsOf: dependent)))], at: lockFile)
        #expect(try Self.run([install], environment: offline).status != 0)
        #expect(try !imports("dependentpkg"))

        try lock([("reviewedpkg", Self.sha256(try Data(contentsOf: reviewed)))], at: lockFile)
        let clean = try Self.run([install], environment: offline)
        #expect(clean.status == 0, "\(clean.output)")
        #expect(try imports("reviewedpkg"))
    }

    @Test(.enabled(if: PinnedInstallTests.pythonWithVenv != nil && PinnedInstallTests.uv != nil))
    func uvRefusesAWheelWhoseBytesChangedAndInstallsTheReviewedOne() throws {
        let root = try Self.scratch("uv")
        defer { try? FileManager.default.removeItem(at: root) }
        let wheels = root.appendingPathComponent("wheels")
        try FileManager.default.createDirectory(at: wheels, withIntermediateDirectories: true)
        let reviewed = try wheel(named: "reviewedpkg", in: wheels)
        let dependent = try wheel(named: "dependentpkg", requires: ["reviewedpkg"], in: wheels)
        let venv = root.appendingPathComponent("venv")
        let offline = ["UV_OFFLINE": "1", "UV_NO_CONFIG": "1", "UV_PYTHON_DOWNLOADS": "never",
                       "UV_CACHE_DIR": root.appendingPathComponent("cache").path]
        let made = try Self.run([PinnedInstall.Command(
            label: "venv", executable: Self.uv!, arguments: ["venv", "--python", Self.pythonWithVenv!.path, venv.path]
        )], environment: offline)
        try #require(made.status == 0, "\(made.output)")
        let python = venv.appendingPathComponent("bin/python3")
        let lockFile = root.appendingPathComponent("lock.txt")
        var install = PinnedInstall.uvPipInstall(
            uv: Self.uv!, python: python, lock: lockFile, label: "uv", noBuildIsolation: true, anyIndex: true
        )
        // Offline: the local wheels stand in for the index. Everything else is the command
        // the installer runs.
        install.arguments += ["--no-index", "--find-links", wheels.path]

        try lock([("reviewedpkg", Self.sha256(Data("some other wheel".utf8)))], at: lockFile)
        let changed = try Self.run([install], environment: offline)
        #expect(changed.status != 0)
        #expect(changed.output.lowercased().contains("hash"), "\(changed.output)")
        func imports(_ module: String) throws -> Bool {
            try Self.run([PinnedInstall.Command(label: "import", executable: python,
                                                arguments: ["-c", "import \(module)"])]).status == 0
        }
        #expect(try !imports("reviewedpkg"))

        // A dependency the lock does not name cannot slip in beside a pinned package.
        try lock([("dependentpkg", Self.sha256(try Data(contentsOf: dependent)))], at: lockFile)
        #expect(try Self.run([install], environment: offline).status != 0)
        #expect(try !imports("dependentpkg"))

        try lock([("reviewedpkg", Self.sha256(try Data(contentsOf: reviewed)))], at: lockFile)
        let clean = try Self.run([install], environment: offline)
        #expect(clean.status == 0, "\(clean.output)")
        #expect(try imports("reviewedpkg"))
    }

    // MARK: - Fixtures

    struct Outcome {
        var status: Int32
        var output: String
    }

    static let gitURL = URL(fileURLWithPath: "/usr/bin/git")
    static let hasGit: Bool = (try? run([PinnedInstall.Command(
        label: "git", executable: gitURL, arguments: ["--version"]
    )]).status) == 0

    static let pythonWithVenv: URL? = [
        "/opt/homebrew/bin/python3.13", "/opt/homebrew/bin/python3.12", "/usr/local/bin/python3.12",
        "/usr/bin/python3",
    ].map { URL(fileURLWithPath: $0) }.first { candidate in
        FileManager.default.isExecutableFile(atPath: candidate.path)
            && (try? run([PinnedInstall.Command(label: "probe", executable: candidate,
                                                arguments: ["-c", "import venv, ensurepip"])]).status) == 0
    }

    static let uv: URL? = ["/opt/homebrew/bin/uv", "/usr/local/bin/uv"]
        .map { URL(fileURLWithPath: $0) }
        .first { FileManager.default.isExecutableFile(atPath: $0.path) }

    /// Runs commands in order, stopping at the first failure, the way the installers do.
    static func run(_ commands: [PinnedInstall.Command], environment extra: [String: String] = [:]) throws -> Outcome {
        var combined = ""
        for command in commands {
            let process = Process()
            process.executableURL = command.executable
            process.arguments = command.arguments
            if let directory = command.workingDirectory { process.currentDirectoryURL = directory }
            var environment = ProcessInfo.processInfo.environment
            environment["GIT_CONFIG_NOSYSTEM"] = "1"
            environment["GIT_TERMINAL_PROMPT"] = "0"
            environment["PIP_DISABLE_PIP_VERSION_CHECK"] = "1"
            for (key, value) in extra { environment[key] = value }
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            combined += String(decoding: data, as: UTF8.self)
            if process.terminationStatus != 0 { return Outcome(status: process.terminationStatus, output: combined) }
        }
        return Outcome(status: 0, output: combined)
    }

    @discardableResult
    static func git(_ arguments: [String], in directory: URL) throws -> String {
        let outcome = try run([PinnedInstall.Command(
            label: "git", executable: gitURL,
            arguments: ["-c", "user.name=test", "-c", "user.email=test@example.invalid"] + arguments,
            workingDirectory: directory
        )])
        guard outcome.status == 0 else {
            throw NSError(domain: "git", code: Int(outcome.status),
                          userInfo: [NSLocalizedDescriptionKey: outcome.output])
        }
        return outcome.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func scratch(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinned-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Looks like a virtual environment of `version` to the planner; nothing runs in it.
    static func fakeEnvironment(at root: URL, version: String) throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("bin"), withIntermediateDirectories: true
        )
        FileManager.default.createFile(
            atPath: root.appendingPathComponent("bin/python3").path, contents: Data(),
            attributes: [.posixPermissions: 0o755]
        )
        try "home = /x\nversion = \(version)\n".write(
            to: root.appendingPathComponent("pyvenv.cfg"), atomically: true, encoding: .utf8
        )
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The requirement lines of a lock, each joined with its `\`-continued hash lines.
    static func requirements(in text: String) throws -> [String] {
        text.replacingOccurrences(of: "\\\n", with: " ")
            .split(separator: "\n").map(String.init)
            .filter { !$0.hasPrefix("#") && !$0.hasPrefix("-") && !$0.trimmingCharacters(in: .whitespaces).isEmpty
                && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
    }

    /// name → version for every requirement in a lock.
    static func pins(_ url: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        for line in try requirements(in: String(contentsOf: url, encoding: .utf8)) {
            let pin = line.split(separator: " ").first ?? ""
            let parts = pin.components(separatedBy: "==")
            if parts.count == 2 { result[parts[0].lowercased()] = parts[1] }
        }
        return result
    }
}
