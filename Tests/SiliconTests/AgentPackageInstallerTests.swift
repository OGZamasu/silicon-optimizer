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
