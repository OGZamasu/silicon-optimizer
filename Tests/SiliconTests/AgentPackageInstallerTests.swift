import Foundation
import Testing
@testable import SiliconRuntime

@Suite("Verified agent packages", .serialized,
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

    private func fixture(checkInstallEnvironment: Bool = false) throws -> Fixture {
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
        let packageManifest: [String: Any] = [
            "name": "fixture-agent", "version": "1.0.0",
            "bin": ["fixture-agent": "bin/agent.js"],
        ]
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
        try FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)
        let fakeNode = fakeBin.appendingPathComponent("node")
        try FileManager.default.createSymbolicLink(at: fakeNode, withDestinationURL: fixture.node)
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

    @Test func eachLaunchGetsItsOwnVerifiedDirectory() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let first = try await AgentPackageInstaller.install(
            fixture.package, node: fixture.node, sourceRoot: fixture.sourceRoot,
            destinationRoot: fixture.destinationRoot, allowLocalArtifacts: true
        )
        let second = try await AgentPackageInstaller.install(
            fixture.package, node: fixture.node, sourceRoot: fixture.sourceRoot,
            destinationRoot: fixture.destinationRoot, allowLocalArtifacts: true
        )
        #expect(first.directory != second.directory)
        #expect(FileManager.default.fileExists(atPath: first.bin.path))
        #expect(FileManager.default.fileExists(atPath: second.bin.path))
    }

    @Test(arguments: ["10.9.3", "11.0.0", "11.18.9"])
    func npmBeforeAuditedReleaseCannotBypassInstallScriptAllowlist(_ version: String) async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let fakeBin = fixture.root.appendingPathComponent("fake-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)
        let fakeNode = fakeBin.appendingPathComponent("node")
        try FileManager.default.createSymbolicLink(at: fakeNode, withDestinationURL: fixture.node)
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
        try FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)
        let fakeNode = fakeBin.appendingPathComponent("node")
        try FileManager.default.createSymbolicLink(at: fakeNode, withDestinationURL: fixture.node)
        let marker = fixture.root.appendingPathComponent("npm-started")
        let fakeNpm = fakeBin.appendingPathComponent("npm")
        try "#!/bin/sh\nif [ \"$1\" = --version ]; then echo 11.19.0; exit 0; fi\n/usr/bin/touch \"\(marker.path)\"\nexec /bin/sleep 30\n".write(
            to: fakeNpm, atomically: true, encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: fakeNpm.path
        )
        let task = Task {
            try await AgentPackageInstaller.install(
                fixture.package, node: fakeNode, sourceRoot: fixture.sourceRoot,
                destinationRoot: fixture.destinationRoot, allowLocalArtifacts: true
            )
        }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: marker.path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(FileManager.default.fileExists(atPath: marker.path))
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("cancelled npm install still succeeded")
        } catch is CancellationError {
            let entries = try FileManager.default.contentsOfDirectory(
                atPath: fixture.destinationRoot.path
            )
            #expect(!entries.contains { $0.hasPrefix("fixture-") })
        }
    }
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
    /// has to say which one to update.
    @Test func aNodeRejectedForItsNpmSaysToUpdateNpm() throws {
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
        let npmRejected = HarnessRuntime.pick(
            from: [oldNpm], includingRejected: nil,
            minimumVersion: HarnessRuntime.harnessMinimumNodeVersion, requiresNpm11: true
        )
        #expect(npmRejected.node == nil)
        #expect(npmRejected.rejectedForNpm)
        #expect(npmRejected.rejectionSentence?.contains("npm install -g npm@11") == true)

        let oldNode = try candidate("old-node", node: "20.10.0", npm: "11.19.0")
        let nodeRejected = HarnessRuntime.pick(
            from: [oldNode], includingRejected: nil,
            minimumVersion: HarnessRuntime.harnessMinimumNodeVersion, requiresNpm11: true
        )
        #expect(nodeRejected.node == nil)
        #expect(!nodeRejected.rejectedForNpm)
        #expect(nodeRejected.rejectionSentence?.contains("incompatible") == true)
    }
}
