import Foundation
import Testing
@testable import SiliconRuntime

/// The fixtures here are built and installed with the Node and npm this Mac has, because the
/// allowlist and integrity checks are npm's own. Where a test only needs `node --version` to
/// answer, its `node` is a script that does just that: the Node discovery finds can be a
/// version manager's shim, which given the fresh `HOME` the installer probes with first
/// downloads a whole runtime — slow, not offline, and not the thing under test. The real
/// Node's probes get a minute for the same reason.
@Suite("Verified agent packages", .serialized, .longVersionProbes,
       .enabled(if: HarnessRuntime.locateNode(
           minimumVersion: CodexRuntime.minimumNodeVersion, requiresNpm11: true
       ).node != nil))
struct AgentPackageInstallerTests {
    private struct Fixture {
        let root: URL
        let sourceRoot: URL
        let destinationRoot: URL
        let project: URL
        let package: AgentPackage
        let node: URL
    }

    /// A local package whose own postinstall writes `marker` — a dependency install script
    /// that no allowlist names.
    private func scriptedDependency(in root: URL, marker: URL, node: URL) throws -> URL {
        let source = root.appendingPathComponent("scripted-dep", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "name": "scripted-dep", "version": "1.0.0",
            "scripts": ["postinstall": "node -e \"require('fs').writeFileSync('\(marker.path)','ran')\""],
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: source.appendingPathComponent("package.json"))
        try "module.exports = 1\n".write(
            to: source.appendingPathComponent("index.js"), atomically: true, encoding: .utf8
        )
        let npm = node.deletingLastPathComponent().appendingPathComponent("npm")
        _ = try run(npm, ["pack", "--pack-destination", root.path, "--ignore-scripts",
                      "--offline", "--no-audit", "--no-fund"], in: source, node: node)
        return root.appendingPathComponent("scripted-dep-1.0.0.tgz")
    }

    private func fixture(
        checkInstallEnvironment: Bool = false, scriptMarker: URL? = nil
    ) throws -> Fixture {
        let node = try #require(HarnessRuntime.locateNode(
            minimumVersion: CodexRuntime.minimumNodeVersion, requiresNpm11: true
        ).node)
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(
            "silicon-agent-package-test-\(UUID().uuidString)", isDirectory: true
        )
        let packageSource = root.appendingPathComponent("package", isDirectory: true)
        let packageBin = packageSource.appendingPathComponent("bin", isDirectory: true)
        let sourceRoot = root.appendingPathComponent("manifests", isDirectory: true)
        let manifestDirectory = sourceRoot.appendingPathComponent("fixture", isDirectory: true)
        let destinationRoot = root.appendingPathComponent("installed", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        for directory in [packageBin, manifestDirectory, destinationRoot, project] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        var packageManifest: [String: Any] = [
            "name": "fixture-agent", "version": "1.0.0",
            "bin": ["fixture-agent": "bin/agent.js"],
        ]
        if let scriptMarker {
            let dependency = try scriptedDependency(in: root, marker: scriptMarker, node: node)
            packageManifest["dependencies"] = ["scripted-dep": dependency.absoluteString]
        }
        try JSONSerialization.data(
            withJSONObject: packageManifest, options: [.prettyPrinted, .sortedKeys]
        ).write(to: packageSource.appendingPathComponent("package.json"))
        try "process.stdout.write('verified:' + process.cwd())\n".write(
            to: packageBin.appendingPathComponent("agent.js"), atomically: true, encoding: .utf8
        )
        let npm = node.deletingLastPathComponent().appendingPathComponent("npm")
        _ = try run(npm, ["pack", "--pack-destination", root.path, "--ignore-scripts",
                      "--offline", "--no-audit", "--no-fund"], in: packageSource, node: node)
        let archive = root.appendingPathComponent("fixture-agent-1.0.0.tgz")
        let requirement = archive.absoluteString
        var rootManifest: [String: Any] = [
            "name": "silicon-fixture-sidecar", "private": true, "version": "1.0.0",
            "dependencies": ["fixture-agent": requirement],
        ]
        if checkInstallEnvironment {
            // Root scripts are included in the trusted manifest and run under the same
            // production npm configuration as approved dependency lifecycle scripts.
            rootManifest["scripts"] = ["preinstall": "node -e \"for(const n of ['SILICON_GATEWAY_KEY','OPENAI_API_KEY','QWEN_SERVER_TOKEN','CODEX_HOME']) if(process.env[n]) process.exit(42); require('fs').writeFileSync('install-script-ran','yes')\""]
        }
        let manifest = try JSONSerialization.data(
            withJSONObject: rootManifest, options: [.prettyPrinted, .sortedKeys]
        )
        try manifest.write(to: manifestDirectory.appendingPathComponent("package.json"))
        _ = try run(npm, ["install", "--package-lock-only", "--ignore-scripts", "--offline",
                      "--no-audit", "--no-fund"], in: manifestDirectory, node: node)
        return Fixture(
            root: root, sourceRoot: sourceRoot, destinationRoot: destinationRoot,
            project: project,
            package: AgentPackage(
                id: "fixture", name: "fixture-agent", version: "1.0.0",
                binPath: "node_modules/fixture-agent/bin/agent.js",
                requirement: requirement
            ),
            node: node
        )
    }

    /// A `node` that answers `--version` with `version` and does nothing else, in `bin`.
    private func scriptedNode(in bin: URL, version: String = "v24.0.0") throws -> URL {
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let node = bin.appendingPathComponent("node")
        try "#!/bin/sh\necho \(version)\n".write(to: node, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: node.path)
        return node
    }

    private func run(
        _ executable: URL, _ arguments: [String], in directory: URL, node: URL
    ) throws -> String {
        let process = Process()
        let output = Pipe()
        let globalConfig = directory.appendingPathComponent("empty-global.npmrc")
        try Data().write(to: globalConfig)
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = [
            "HOME": directory.path,
            "PATH": "\(node.deletingLastPathComponent().path):/usr/bin:/bin",
            "NPM_CONFIG_USERCONFIG": "/dev/null",
            "NPM_CONFIG_GLOBALCONFIG": globalConfig.path,
            "NPM_CONFIG_CACHE": directory.appendingPathComponent(".npm-cache").path,
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(),
                          as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "Fixture npm", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: text])
        }
        return text
    }

    @Test func projectLocalPackageCannotReplaceVerifiedBinary() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let local = fixture.project.appendingPathComponent(
            "node_modules/fixture-agent/bin", isDirectory: true
        )
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try "process.stdout.write('hijacked')\n".write(
            to: local.appendingPathComponent("agent.js"), atomically: true, encoding: .utf8
        )
        let installed = try await AgentPackageInstaller.install(
            fixture.package, node: fixture.node, sourceRoot: fixture.sourceRoot,
            destinationRoot: fixture.destinationRoot, allowLocalArtifacts: true
        )
        let output = try run(
            fixture.node, [installed.bin.path], in: fixture.project, node: fixture.node
        )
        #expect(output.hasPrefix("verified:"))
        #expect(output.hasSuffix("/project"))
        #expect(installed.bin.path.hasPrefix(fixture.destinationRoot.path + "/"))
    }

    @Test func integrityMismatchPreventsInstallation() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let lock = fixture.sourceRoot.appendingPathComponent("fixture/package-lock.json")
        var document = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: lock)) as? [String: Any]
        )
        var packages = try #require(document["packages"] as? [String: [String: Any]])
        var entry = try #require(packages["node_modules/fixture-agent"])
        entry["integrity"] = "sha512-" + String(repeating: "A", count: 88)
        packages["node_modules/fixture-agent"] = entry
        document["packages"] = packages
        try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
            .write(to: lock)

        do {
            _ = try await AgentPackageInstaller.install(
                fixture.package, node: fixture.node, sourceRoot: fixture.sourceRoot,
                destinationRoot: fixture.destinationRoot, allowLocalArtifacts: true
            )
            Issue.record("npm accepted a tarball whose bytes did not match the locked integrity")
        } catch {
            #expect(error is AgentPackageInstallError)
        }
        let entries = try FileManager.default.contentsOfDirectory(atPath: fixture.destinationRoot.path)
        #expect(!entries.contains { $0.hasPrefix("fixture-") })
    }

    @Test func nestedArtifactWithoutIntegrityIsRejectedBeforeNpmRuns() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let lock = fixture.sourceRoot.appendingPathComponent("fixture/package-lock.json")
        var document = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: lock)) as? [String: Any]
        )
        var packages = try #require(document["packages"] as? [String: [String: Any]])
        packages["node_modules/fixture-agent/node_modules/unsafe"] = [
            "version": "1.0.0",
            "resolved": "https://registry.npmjs.org/unsafe/-/unsafe-1.0.0.tgz",
        ]
        document["packages"] = packages
        try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
            .write(to: lock)

        let fakeBin = fixture.root.appendingPathComponent("fake-bin", isDirectory: true)
        let fakeNode = try scriptedNode(in: fakeBin)
        let marker = fixture.root.appendingPathComponent("npm-was-called")
        let fakeNpm = fakeBin.appendingPathComponent("npm")
        try "#!/bin/sh\n/usr/bin/touch \"\(marker.path)\"\nexit 1\n".write(
            to: fakeNpm, atomically: true, encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: fakeNpm.path
        )
        do {
            _ = try await AgentPackageInstaller.install(
                fixture.package, node: fakeNode, sourceRoot: fixture.sourceRoot,
                destinationRoot: fixture.destinationRoot, allowLocalArtifacts: true
            )
            Issue.record("accepted an unverified transitive package")
        } catch AgentPackageInstallError.invalidLock {
            #expect(!FileManager.default.fileExists(atPath: marker.path))
        }
    }

    @Test func npmLifecycleCannotReadGatewayOrAgentSecrets() async throws {
        let fixture = try fixture(checkInstallEnvironment: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let names = ["SILICON_GATEWAY_KEY", "OPENAI_API_KEY", "QWEN_SERVER_TOKEN", "CODEX_HOME"]
        let previous = names.map { ($0, ProcessInfo.processInfo.environment[$0]) }
        for name in names { setenv(name, "test-secret", 1) }
        defer {
            for (name, value) in previous {
                if let value { setenv(name, value, 1) }
                else { unsetenv(name) }
            }
        }
        let installed = try await AgentPackageInstaller.install(
            fixture.package, node: fixture.node, sourceRoot: fixture.sourceRoot,
            destinationRoot: fixture.destinationRoot, allowLocalArtifacts: true
        )
        #expect(FileManager.default.fileExists(atPath: installed.bin.path))
        #expect(FileManager.default.fileExists(atPath: installed.directory
            .appendingPathComponent("install-script-ran").path))
    }

    /// The allowlist is the one control between a locked dependency's install script and
    /// this Mac. A dependency with a script no allowlist names stops the install, and the
    /// script never runs.
    @Test func aDependencyInstallScriptOffTheAllowlistStopsTheInstall() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
            "silicon-script-marker-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: scratch) }
        let fixture = try fixture(scriptMarker: scratch)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let lock = try String(
            contentsOf: fixture.sourceRoot.appendingPathComponent("fixture/package-lock.json"),
            encoding: .utf8
        )
        #expect(lock.contains("\"hasInstallScript\": true"), "the fixture must carry a dependency script")

        do {
            _ = try await AgentPackageInstaller.install(
                fixture.package, node: fixture.node, sourceRoot: fixture.sourceRoot,
                destinationRoot: fixture.destinationRoot, allowLocalArtifacts: true
            )
            Issue.record("an install script no allowlist names was allowed to install")
        } catch AgentPackageInstallError.npmFailed(_, _, let detail) {
            #expect(detail.contains("allowScripts") || detail.contains("install scripts"), "\(detail)")
        }
        #expect(!FileManager.default.fileExists(atPath: scratch.path), "the script ran")
        let entries = try FileManager.default.contentsOfDirectory(atPath: fixture.destinationRoot.path)
        #expect(!entries.contains { $0.hasPrefix("fixture-") })
    }

    /// A start after the first uses the verified tree as it is: no npm at all (the npm here
    /// fails if it is called), the same directory, and per-launch folders from before are gone.
    @Test func aVerifiedTreeIsReusedWithoutRunningNpmAgain() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let first = try await AgentPackageInstaller.install(
            fixture.package, node: fixture.node, sourceRoot: fixture.sourceRoot,
            destinationRoot: fixture.destinationRoot, allowLocalArtifacts: true
        )
        #expect(!first.reused)

        // What the per-launch design left behind: a tree whose app has quit.
        let exited = Process()
        exited.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try exited.run()
        exited.waitUntilExit()
        let leftover = fixture.destinationRoot.appendingPathComponent("fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        try Data("\(exited.processIdentifier)\n".utf8)
            .write(to: leftover.appendingPathComponent(AgentPackageInstaller.ownerFileName))

        // Answering with the Node line the tree was installed for, which is part of its key.
        let record = try #require(JSONSerialization.jsonObject(with: Data(contentsOf:
            first.directory.appendingPathComponent(AgentPackageInstaller.manifestFileName)
        )) as? [String: Any])
        let nodeLine = try #require((record["identity"] as? [String: Any])?["node"] as? String)
        let (fakeNode, npmCalled) = try failingNpm(beside: fixture, answering: "v\(nodeLine).0.0")
        let second = try await AgentPackageInstaller.install(
            fixture.package, node: fakeNode, sourceRoot: fixture.sourceRoot,
            destinationRoot: fixture.destinationRoot, allowLocalArtifacts: true
        )
        #expect(second.reused)
        #expect(second.directory == first.directory)
        #expect(second.bin == first.bin)
        #expect(!FileManager.default.fileExists(atPath: npmCalled.path), "npm ran for a verified tree")
        #expect(!FileManager.default.fileExists(atPath: leftover.path))
    }

    /// A tree that differs from its record in any way — changed bytes, an added file, a
    /// missing one — is installed again from the lock before anything in it runs.
    @Test(arguments: ["changed", "added", "removed"])
    func aChangedTreeIsInstalledAgain(_ change: String) async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let first = try await AgentPackageInstaller.install(
            fixture.package, node: fixture.node, sourceRoot: fixture.sourceRoot,
            destinationRoot: fixture.destinationRoot, allowLocalArtifacts: true
        )
        let original = try Data(contentsOf: first.bin)
        let package = first.directory.appendingPathComponent("node_modules/fixture-agent")
        switch change {
        case "changed":
            var bytes = original
            bytes[bytes.startIndex] ^= 0x01  // same size, different bytes
            try bytes.write(to: first.bin)
        case "added":
            try "process.exit(0)\n".write(
                to: package.appendingPathComponent("planted.js"), atomically: true, encoding: .utf8
            )
        default:
            try FileManager.default.removeItem(at: package.appendingPathComponent("package.json"))
        }

        let second = try await AgentPackageInstaller.install(
            fixture.package, node: fixture.node, sourceRoot: fixture.sourceRoot,
            destinationRoot: fixture.destinationRoot, allowLocalArtifacts: true
        )
        #expect(!second.reused)
        #expect(try Data(contentsOf: second.bin) == original)
        #expect(!FileManager.default.fileExists(atPath: package.appendingPathComponent("planted.js").path))
        #expect(FileManager.default.fileExists(atPath: package.appendingPathComponent("package.json").path))
    }

    /// A different bundled lock — an app update — gets its own tree; the old one is removed.
    @Test func aDifferentLockGetsANewTreeAndTheOldOneGoes() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let first = try await AgentPackageInstaller.install(
            fixture.package, node: fixture.node, sourceRoot: fixture.sourceRoot,
            destinationRoot: fixture.destinationRoot, allowLocalArtifacts: true
        )
        let lock = fixture.sourceRoot.appendingPathComponent("fixture/package-lock.json")
        let document = try JSONSerialization.jsonObject(with: Data(contentsOf: lock))
        try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]).write(to: lock)

        let second = try await AgentPackageInstaller.install(
            fixture.package, node: fixture.node, sourceRoot: fixture.sourceRoot,
            destinationRoot: fixture.destinationRoot, allowLocalArtifacts: true
        )
        #expect(!second.reused)
        #expect(second.directory != first.directory)
        #expect(!FileManager.default.fileExists(atPath: first.directory.path))
        #expect(FileManager.default.fileExists(atPath: second.bin.path))
    }

    /// A Node answering `version`, beside an npm that records being called and fails.
    private func failingNpm(
        beside fixture: Fixture, answering version: String
    ) throws -> (node: URL, marker: URL) {
        let fakeBin = fixture.root.appendingPathComponent("failing-npm-bin", isDirectory: true)
        let fakeNode = try scriptedNode(in: fakeBin, version: version)
        let marker = fixture.root.appendingPathComponent("npm-was-called")
        let fakeNpm = fakeBin.appendingPathComponent("npm")
        try "#!/bin/sh\n/usr/bin/touch \"\(marker.path)\"\nexit 1\n".write(
            to: fakeNpm, atomically: true, encoding: .utf8
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeNpm.path)
        return (fakeNode, marker)
    }

    @Test(arguments: ["10.9.3", "11.0.0", "11.18.9"])
    func npmBeforeAuditedReleaseCannotBypassInstallScriptAllowlist(_ version: String) async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let fakeBin = fixture.root.appendingPathComponent("fake-bin", isDirectory: true)
        let fakeNode = try scriptedNode(in: fakeBin)
        let marker = fixture.root.appendingPathComponent("npm-ci-was-called")
        let fakeNpm = fakeBin.appendingPathComponent("npm")
        try "#!/bin/sh\nif [ \"$1\" = --version ]; then echo \(version); exit 0; fi\n/usr/bin/touch \"\(marker.path)\"\nexit 1\n".write(
            to: fakeNpm, atomically: true, encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: fakeNpm.path
        )
        do {
            _ = try await AgentPackageInstaller.install(
                fixture.package, node: fakeNode, sourceRoot: fixture.sourceRoot,
                destinationRoot: fixture.destinationRoot, allowLocalArtifacts: true
            )
            Issue.record("npm \(version) bypassed the lifecycle allowlist preflight")
        } catch AgentPackageInstallError.npmTooOld(let found) {
            #expect(found == version)
            #expect(!FileManager.default.fileExists(atPath: marker.path))
        }
    }

    @Test func cancellingNpmRemovesIncompleteInstallation() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let fakeBin = fixture.root.appendingPathComponent("fake-bin", isDirectory: true)
        let fakeNode = try scriptedNode(in: fakeBin)
        let marker = fixture.root.appendingPathComponent("npm-started")
        let fakeNpm = fakeBin.appendingPathComponent("npm")
        try "#!/bin/sh\nif [ \"$1\" = --version ]; then echo 11.19.0; exit 0; fi\n/usr/bin/touch \"\(marker.path)\"\nexec /bin/sleep 30\n".write(
            to: fakeNpm, atomically: true, encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: fakeNpm.path
        )
        // Woken by the fixture folder changing, not by a timer. npm starts behind
        // `node --version`, `npm --version` and the first launch of a script macOS has never
        // seen, and on a loaded machine that has taken longer than the ten seconds this used
        // to allow — so the wait is for the thing itself, and the deadline only bounds a hang.
        let (events, post) = AsyncStream.makeStream(of: InstallEvent.self)
        let watcher = try FolderWatcher(fixture.root) { post.yield(.folderChanged) }
        defer { watcher.cancel() }
        let task = Task {
            // An install that ends before npm ever starts has nothing to wait for.
            defer { post.yield(.installEnded) }
            return try await AgentPackageInstaller.install(
                fixture.package, node: fakeNode, sourceRoot: fixture.sourceRoot,
                destinationRoot: fixture.destinationRoot, allowLocalArtifacts: true
            )
        }
        let giveUp = Task {
            try? await Task.sleep(for: .seconds(120))
            post.finish()
        }
        defer { giveUp.cancel() }
        post.yield(.folderChanged)
        for await event in events {
            if FileManager.default.fileExists(atPath: marker.path) || event == .installEnded {
                break
            }
        }
        #expect(FileManager.default.fileExists(atPath: marker.path), "npm ci never started")
        // Cancelling has to stop npm, not wait it out: the fake one sleeps for thirty seconds,
        // so an install that only noticed when npm exited by itself would still end in
        // `CancellationError` and a clean folder. The bound is on the kill path — a signal,
        // a poll at most a tenth of a second later, three seconds' grace — with room to spare.
        let cancelled = ContinuousClock.now
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("cancelled npm install still succeeded")
        } catch is CancellationError {
            #expect(ContinuousClock.now - cancelled < .seconds(10), "npm was not stopped")
            let entries = try FileManager.default.contentsOfDirectory(
                atPath: fixture.destinationRoot.path
            )
            #expect(!entries.contains { $0.hasPrefix("fixture-") })
        }
    }
}

/// Gives every version probe in a suite a minute: see "Verified agent packages".
struct LongVersionProbes: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(
        for test: Test, testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        try await AgentPackageInstaller.$versionProbeDeadline.withValue(60) {
            try await function()
        }
    }
}

extension Trait where Self == LongVersionProbes {
    static var longVersionProbes: Self { Self() }
}

/// What the npm cancellation test waits for.
private enum InstallEvent: Sendable { case folderChanged, installEnded }

/// Calls `changed` whenever an entry is added to or removed from `folder`.
private final class FolderWatcher: @unchecked Sendable {
    private let source: any DispatchSourceFileSystemObject

    init(_ folder: URL, changed: @escaping @Sendable () -> Void) throws {
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: .write, queue: .global()
        )
        source.setEventHandler(handler: changed)
        source.setCancelHandler { close(descriptor) }
        source.resume()
    }

    func cancel() { source.cancel() }
}

/// What the app ships and how it tidies up, checked without npm, so these run everywhere.
@Suite("Bundled agent package locks")
struct BundledAgentPackageLockTests {
    static let packages: [AgentPackage] = [.harness, .qwen, .codex, .pi]

    private static let sourceRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // SiliconTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // repository
        .appendingPathComponent("Resources/agent-packages", isDirectory: true)

    private static func files(_ package: AgentPackage) -> (manifest: URL, lock: URL) {
        let directory = sourceRoot.appendingPathComponent(package.id, isDirectory: true)
        return (directory.appendingPathComponent("package.json"),
                directory.appendingPathComponent("package-lock.json"))
    }

    /// The locks the app bundles pass the same check a launch makes: the package and version
    /// each runtime names, every entry from the public registry with a SHA-512 integrity.
    @Test(arguments: packages.map(\.id))
    func eachBundledLockPassesTheLaunchCheck(_ id: String) throws {
        let package = try #require(Self.packages.first { $0.id == id })
        let (manifest, lock) = Self.files(package)
        try AgentPackageInstaller.validateLock(
            package, manifest: manifest, lock: lock, allowLocalArtifacts: false
        )
    }

    /// A strict install fails on an install script the allowlist does not name, and an
    /// allowlist entry is pinned to one version — so the two must describe the same
    /// packages, or a version bump either breaks every launch or approves nothing.
    @Test(arguments: packages.map(\.id))
    func theInstallScriptAllowlistNamesExactlyTheLockedScripts(_ id: String) throws {
        let package = try #require(Self.packages.first { $0.id == id })
        let (manifest, lock) = Self.files(package)
        let manifestJSON = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any]
        )
        let allowed = Set(((manifestJSON["allowScripts"] as? [String: Bool]) ?? [:])
            .filter(\.value).keys)
        let lockJSON = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: lock)) as? [String: Any]
        )
        let packages = try #require(lockJSON["packages"] as? [String: [String: Any]])
        var scripted = Set<String>()
        for (path, entry) in packages where entry["hasInstallScript"] as? Bool == true {
            let name = (entry["name"] as? String)
                ?? String(path.components(separatedBy: "node_modules/").last ?? "")
            scripted.insert("\(name)@\(entry["version"] as? String ?? "")")
        }
        #expect(allowed == scripted)
    }

    @Test func aLockPointingAwayFromTheRegistryIsRefused() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "silicon-lock-host-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (manifest, lock) = Self.files(.codex)
        let copiedManifest = directory.appendingPathComponent("package.json")
        let copiedLock = directory.appendingPathComponent("package-lock.json")
        try FileManager.default.copyItem(at: manifest, to: copiedManifest)
        let text = try String(contentsOf: lock, encoding: .utf8)
        #expect(text.contains("https://registry.npmjs.org/@openai/codex/-/codex-0.148.0.tgz"))
        try text.replacingOccurrences(
            of: "https://registry.npmjs.org/@openai/codex/-/codex-0.148.0.tgz",
            with: "https://registry.example.invalid/@openai/codex/-/codex-0.148.0.tgz"
        ).write(to: copiedLock, atomically: true, encoding: .utf8)

        #expect(throws: AgentPackageInstallError.self) {
            try AgentPackageInstaller.validateLock(
                .codex, manifest: copiedManifest, lock: copiedLock, allowLocalArtifacts: false
            )
        }
    }

    /// Quitting the app kills the sidecar without waiting to delete its tree, so trees are
    /// cleared at the next install instead: those whose owner is gone, and ownerless ones
    /// old enough to be a launch that died. Live owners, fresh claims and the cache stay.
    @Test func abandonedInstallTreesAreClearedAndLiveOnesKept() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(
            "silicon-agent-trees-\(UUID().uuidString)", isDirectory: true
        )
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }

        let exited = Process()
        exited.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try exited.run()
        exited.waitUntilExit()

        func tree(_ name: String, owner: Int32?, created: Date? = nil) throws -> URL {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            try manager.createDirectory(
                at: directory.appendingPathComponent("node_modules"),
                withIntermediateDirectories: true
            )
            if let owner {
                try Data("\(owner)\n".utf8).write(
                    to: directory.appendingPathComponent(AgentPackageInstaller.ownerFileName)
                )
            }
            if let created {
                try manager.setAttributes([.creationDate: created], ofItemAtPath: directory.path)
            }
            return directory
        }
        let now = Date()
        let live = try tree("harness-\(UUID().uuidString)", owner: getpid())
        let abandoned = try tree("codex-\(UUID().uuidString)", owner: exited.processIdentifier)
        let beingCreated = try tree("qwen-\(UUID().uuidString)", owner: nil)
        let diedCreating = try tree(
            "pi-\(UUID().uuidString)", owner: nil, created: now.addingTimeInterval(-7_200)
        )
        let cache = try tree("cache", owner: nil, created: now.addingTimeInterval(-7_200))

        AgentPackageInstaller.pruneAbandonedInstallations(in: root, now: now)

        #expect(manager.fileExists(atPath: live.path))
        #expect(!manager.fileExists(atPath: abandoned.path))
        #expect(manager.fileExists(atPath: beingCreated.path))
        #expect(!manager.fileExists(atPath: diedCreating.path))
        #expect(manager.fileExists(atPath: cache.path))
    }

    /// Node 22 ships npm 10: that Node is new enough and its npm is not, and the message
    /// has to say which one to update. The fixture's version probe gets a minute — under
    /// load a forked script can miss the default three seconds, and a skipped candidate
    /// leaves nothing to say anything about.
    @Test func aNodeRejectedForItsNpmSaysWhatToDo() throws {
        try HarnessRuntime.$nodeProbeDeadline.withValue(60) {
            try nodeRejectedForItsNpmSaysWhatToDo()
        }
    }

    private func nodeRejectedForItsNpmSaysWhatToDo() throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent(
            "silicon-npm-rejection-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? manager.removeItem(at: directory) }
        func candidate(_ name: String, node: String, npm: String) throws -> String {
            let folder = directory.appendingPathComponent(name, isDirectory: true)
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            for (tool, output) in [("node", "v\(node)"), ("npm", npm)] {
                let url = folder.appendingPathComponent(tool)
                try "#!/bin/sh\necho \(output)\n".write(to: url, atomically: true, encoding: .utf8)
                try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
            return folder.appendingPathComponent("node").path
        }

        let oldNpm = try candidate("old-npm", node: "22.22.0", npm: "10.9.8")
        var npmRejected = HarnessRuntime.pick(
            from: [oldNpm], includingRejected: nil,
            minimumVersion: HarnessRuntime.harnessMinimumNodeVersion, requiresNpm11: true
        )
        #expect(npmRejected.node == nil)
        #expect(npmRejected.rejectedPath == oldNpm, "the fixture's version probe did not answer")
        #expect(npmRejected.rejectedForNpm)
        // This one lives in a folder nobody installs Node into: another tool's. Its npm is
        // not the user's to upgrade, so the message points at Settings instead.
        #expect(npmRejected.rejectionSentence?.contains("Settings") == true)
        #expect(npmRejected.rejectionSentence?.contains("npm install -g") == false)
        // The same rejection for a Homebrew Node says how to update its npm.
        npmRejected.rejectedPath = "/opt/homebrew/bin/node"
        #expect(npmRejected.rejectionSentence?.contains("npm install -g npm@11") == true)

        let oldNode = try candidate("old-node", node: "20.10.0", npm: "11.19.0")
        let nodeRejected = HarnessRuntime.pick(
            from: [oldNode], includingRejected: nil,
            minimumVersion: HarnessRuntime.harnessMinimumNodeVersion, requiresNpm11: true
        )
        #expect(nodeRejected.node == nil)
        #expect(nodeRejected.rejectedPath == oldNode, "the fixture's version probe did not answer")
        #expect(!nodeRejected.rejectedForNpm)
        #expect(nodeRejected.rejectionSentence?.contains("incompatible") == true)
    }

    @Test func onlyAUsersOwnNodeIsCalledGeneralPurpose() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(HarnessRuntime.isGeneralPurposeNode("/opt/homebrew/bin/node"))
        #expect(HarnessRuntime.isGeneralPurposeNode("/usr/local/bin/node"))
        #expect(HarnessRuntime.isGeneralPurposeNode("\(home)/.nvm/versions/node/v24.1.0/bin/node"))
        #expect(HarnessRuntime.isGeneralPurposeNode("\(home)/.volta/bin/node"))
        #expect(!HarnessRuntime.isGeneralPurposeNode("\(home)/.hermes/node/bin/node"))
        #expect(!HarnessRuntime.isGeneralPurposeNode("/Applications/Some.app/Contents/Resources/node"))
    }

    /// The record a start checks against: exactly the tree's entries, sizes, bytes and links,
    /// for this lock and Node line. Checked without npm, so it runs everywhere.
    @Test func aTreeVerifiesOnlyAsRecorded() throws {
        let manager = FileManager.default
        let tree = manager.temporaryDirectory.appendingPathComponent(
            "silicon-tree-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? manager.removeItem(at: tree) }
        let module = tree.appendingPathComponent("node_modules/agent", isDirectory: true)
        try manager.createDirectory(at: module, withIntermediateDirectories: true)
        try "console.log(1)\n".write(to: module.appendingPathComponent("index.js"), atomically: true, encoding: .utf8)
        try "{}\n".write(to: tree.appendingPathComponent("package-lock.json"), atomically: true, encoding: .utf8)
        let bin = tree.appendingPathComponent("node_modules/.bin", isDirectory: true)
        try manager.createDirectory(at: bin, withIntermediateDirectories: true)
        try manager.createSymbolicLink(atPath: bin.appendingPathComponent("agent").path,
                                       withDestinationPath: "../agent/index.js")
        let identity = AgentPackageInstaller.TreeIdentity(package: "agent@1.0.0", lock: "abc", node: "24")
        try AgentPackageInstaller.writeManifest(of: tree, identity: identity)
        #expect(try AgentPackageInstaller.verifyTree(tree, expected: identity))

        var other = identity
        other.lock = "def"
        #expect(try !AgentPackageInstaller.verifyTree(tree, expected: other), "another lock")
        other = identity
        other.node = "22"
        #expect(try !AgentPackageInstaller.verifyTree(tree, expected: other), "another Node line")

        let index = module.appendingPathComponent("index.js")
        try "console.log(2)\n".write(to: index, atomically: true, encoding: .utf8)
        #expect(try !AgentPackageInstaller.verifyTree(tree, expected: identity), "same size, other bytes")
        try "console.log(1)\n".write(to: index, atomically: true, encoding: .utf8)
        #expect(try AgentPackageInstaller.verifyTree(tree, expected: identity))

        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: index.path)
        #expect(try !AgentPackageInstaller.verifyTree(tree, expected: identity), "a changed mode")
        try manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: index.path)
        #expect(try AgentPackageInstaller.verifyTree(tree, expected: identity))

        try "x".write(to: module.appendingPathComponent("extra.js"), atomically: true, encoding: .utf8)
        #expect(try !AgentPackageInstaller.verifyTree(tree, expected: identity), "an added file")
        try manager.removeItem(at: module.appendingPathComponent("extra.js"))

        try manager.removeItem(at: bin.appendingPathComponent("agent"))
        try manager.createSymbolicLink(atPath: bin.appendingPathComponent("agent").path,
                                       withDestinationPath: "/tmp/elsewhere.js")
        #expect(try !AgentPackageInstaller.verifyTree(tree, expected: identity), "a moved link")
        try manager.removeItem(at: bin.appendingPathComponent("agent"))
        #expect(try !AgentPackageInstaller.verifyTree(tree, expected: identity), "a missing entry")

        try manager.removeItem(at: tree.appendingPathComponent(AgentPackageInstaller.manifestFileName))
        #expect(try !AgentPackageInstaller.verifyTree(tree, expected: identity), "no record")
    }
}

/// The verified tree is keyed by the Node's major version, and a start deletes the trees for
/// other keys. A start whose `node --version` never answered — Stop pressed during "Looking
/// for Node.js…", or a Node slow to launch — must not make up a key and delete the real tree
/// with it. Checked with a stand-in `node` and `npm`, so no real npm runs.
@Suite("Agent package trees and an unanswered Node probe", .serialized)
struct AgentPackageTreeProbeTests {
    private struct Stage {
        let root: URL
        let sourceRoot: URL
        let destinationRoot: URL
        let node: URL
        let slowNode: URL
        let killedNode: URL
        let probing: URL
        let package = AgentPackage(
            id: "fixture", name: "fixture-agent", version: "1.0.0",
            binPath: "node_modules/fixture-agent/bin/agent.js"
        )

        init() throws {
            let manager = FileManager.default
            let root = manager.temporaryDirectory.appendingPathComponent(
                "silicon-agent-probe-\(UUID().uuidString)", isDirectory: true
            )
            self.root = root
            sourceRoot = root.appendingPathComponent("manifests", isDirectory: true)
            destinationRoot = root.appendingPathComponent("installed", isDirectory: true)
            let manifests = sourceRoot.appendingPathComponent("fixture", isDirectory: true)
            try manager.createDirectory(at: manifests, withIntermediateDirectories: true)
            try manager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
            let dependencies = ["fixture-agent": "1.0.0"]
            try JSONSerialization.data(withJSONObject: [
                "name": "silicon-fixture-sidecar", "private": true, "version": "1.0.0",
                "dependencies": dependencies,
            ], options: [.sortedKeys]).write(to: manifests.appendingPathComponent("package.json"))
            try JSONSerialization.data(withJSONObject: [
                "lockfileVersion": 3,
                "packages": [
                    "": ["dependencies": dependencies],
                    "node_modules/fixture-agent": [
                        "version": "1.0.0",
                        "resolved": "https://registry.npmjs.org/fixture-agent/-/fixture-agent-1.0.0.tgz",
                        "integrity": "sha512-" + String(repeating: "A", count: 86) + "==",
                    ],
                ],
            ], options: [.sortedKeys]).write(to: manifests.appendingPathComponent("package-lock.json"))

            // A Node that answers at once, and one that takes a minute to (and says when it has
            // started to). Beside each, an npm whose `ci` lays out the package's entry point.
            let probing = root.appendingPathComponent("probing")
            self.probing = probing
            func tools(_ name: String, nodeScript: String) throws -> URL {
                let bin = root.appendingPathComponent(name, isDirectory: true)
                try manager.createDirectory(at: bin, withIntermediateDirectories: true)
                let npm = """
                    #!/bin/sh
                    if [ "$1" = --version ]; then echo 11.19.0; exit 0; fi
                    /bin/mkdir -p node_modules/fixture-agent/bin
                    echo "process.exit(0)" > node_modules/fixture-agent/bin/agent.js
                    """
                for (tool, script) in [("node", nodeScript), ("npm", npm)] {
                    let url = bin.appendingPathComponent(tool)
                    try "\(script)\n".write(to: url, atomically: true, encoding: .utf8)
                    try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
                }
                return bin.appendingPathComponent("node")
            }
            node = try tools("fast", nodeScript: "#!/bin/sh\necho v24.3.0")
            slowNode = try tools("slow", nodeScript: """
                #!/bin/sh
                : > "\(probing.path)"
                exec /bin/sleep 60
                """)
            killedNode = try tools("killed", nodeScript: "#!/bin/sh\nkill -9 $$")
        }

        func install(node: URL) async throws -> InstalledAgentPackage {
            try await AgentPackageInstaller.install(
                package, node: node, sourceRoot: sourceRoot, destinationRoot: destinationRoot
            )
        }
    }

    @Test func stoppingDuringTheNodeProbeKeepsTheVerifiedTree() async throws {
        let stage = try Stage()
        defer { try? FileManager.default.removeItem(at: stage.root) }
        let first = try await stage.install(node: stage.node)
        #expect(!first.reused)

        let start = Task { try await stage.install(node: stage.slowNode) }
        let deadline = Date().addingTimeInterval(30)
        while !FileManager.default.fileExists(atPath: stage.probing.path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(FileManager.default.fileExists(atPath: stage.probing.path), "the probe never started")
        start.cancel()
        await #expect(throws: CancellationError.self) { try await start.value }

        #expect(FileManager.default.fileExists(atPath: first.bin.path),
                "a cancelled start deleted the verified tree")
        let again = try await stage.install(node: stage.node)
        #expect(again.reused, "the next start installed from scratch")
        #expect(again.directory == first.directory)
    }

    /// Killed by a signal — `killall node`, memory pressure, a code-signing kill — a probe has
    /// not answered either.
    @Test func aNodeProbeKilledBySignalKeepsTheVerifiedTree() async throws {
        let stage = try Stage()
        defer { try? FileManager.default.removeItem(at: stage.root) }
        let first = try await stage.install(node: stage.node)

        await #expect(throws: AgentPackageInstallError.self) {
            try await stage.install(node: stage.killedNode)
        }
        #expect(FileManager.default.fileExists(atPath: first.bin.path),
                "a probe killed by a signal deleted the verified tree")
        let entries = try FileManager.default.contentsOfDirectory(atPath: stage.destinationRoot.path)
        #expect(entries.filter { $0.hasPrefix("fixture-") } == [first.directory.lastPathComponent],
                "a tree was made for a Node version nobody read")
    }

    @Test func aNodeProbeThatTimesOutKeepsTheVerifiedTree() async throws {
        let stage = try Stage()
        defer { try? FileManager.default.removeItem(at: stage.root) }
        let first = try await stage.install(node: stage.node)

        await #expect(throws: AgentPackageInstallError.self) {
            try await stage.install(node: stage.slowNode)
        }
        #expect(FileManager.default.fileExists(atPath: first.bin.path),
                "a start whose Node never answered deleted the verified tree")
        let entries = try FileManager.default.contentsOfDirectory(atPath: stage.destinationRoot.path)
        #expect(entries.filter { $0.hasPrefix("fixture-") } == [first.directory.lastPathComponent],
                "a tree was made for a Node version nobody read")
    }
}
