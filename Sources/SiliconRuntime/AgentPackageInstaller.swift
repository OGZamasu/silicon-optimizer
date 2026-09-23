import Foundation
import Darwin

/// The package identity and entry point are fixed by the app, not by the current project.
struct AgentPackage: Sendable {
    let id: String
    let name: String
    let version: String
    let binPath: String
    let requirement: String?

    init(id: String, name: String, version: String, binPath: String,
         requirement: String? = nil) {
        self.id = id
        self.name = name
        self.version = version
        self.binPath = binPath
        self.requirement = requirement
    }

    var spec: String { "\(name)@\(version)" }
    var installRequirement: String { requirement ?? version }

    static let harness = Self(
        id: "harness", name: "@deepseek-ai/dsh", version: "0.1.0-rc.7",
        binPath: "node_modules/@deepseek-ai/dsh/lib/bin.js"
    )
    static let qwen = Self(
        id: "qwen", name: "@qwen-code/qwen-code", version: "0.21.14",
        binPath: "node_modules/@qwen-code/qwen-code/cli-entry.js"
    )
    static let codex = Self(
        id: "codex", name: "@openai/codex", version: "0.148.0",
        binPath: "node_modules/@openai/codex/bin/codex.js"
    )
    static let pi = Self(
        id: "pi", name: "@earendil-works/pi-coding-agent", version: "0.84.2",
        binPath: "node_modules/@earendil-works/pi-coding-agent/dist/cli.js"
    )
}

enum AgentPackageInstallError: LocalizedError {
    case missingManifest(String)
    case invalidLock(String)
    case npmUnavailable(String)
    case npmTooOld(String)
    case npmFailed(String, Int32, String)
    case npmTimedOut(String)
    case missingBin(String)

    var errorDescription: String? {
        switch self {
        case .missingManifest(let name):
            return "The verified \(name) package manifest is missing from the app."
        case .invalidLock(let name):
            return "The bundled \(name) package lock is incomplete or does not match its package."
        case .npmUnavailable(let path):
            return "npm 11.19 or newer is required beside the selected Node.js "
                + "(expected at \(path))."
        case .npmTooOld(let found):
            return "Verified agent packages need npm 11.19.0 or newer to enforce the audited "
                + "install-script allowlist (found \(found)). Update npm with "
                + "`npm install -g npm@11.19.0` (and Node.js if required), then try again."
        case .npmFailed(let name, let status, let detail):
            return "Could not install the verified \(name) package (npm ci exited \(status)). "
                + "The first install needs network access unless npm has cached every "
                + "locked artifact.\(detail.isEmpty ? "" : "\n\(detail)")"
        case .npmTimedOut(let name):
            return "Installing the verified \(name) package timed out."
        case .missingBin(let name):
            return "The verified \(name) package did not contain its expected entry point."
        }
    }
}

struct InstalledAgentPackage: Sendable {
    let bin: URL
    let directory: URL
}

/// Reinstalls from the bundled integrity lock before every launch. The fresh directory
/// prevents a previous agent run or a project-local package from becoming the next binary.
/// A normal stop/exit removes it; force-quit can leave an orphaned tree. We deliberately
/// do not age-delete old trees here, since another app instance may still be running one.
enum AgentPackageInstaller {
    static func install(
        _ package: AgentPackage, node: URL, sourceRoot: URL? = nil,
        destinationRoot: URL? = nil, allowLocalArtifacts: Bool = false
    ) async throws -> InstalledAgentPackage {
        let installation = Task.detached(priority: .userInitiated) {
            try installSynchronously(
                package, node: node, sourceRoot: sourceRoot,
                destinationRoot: destinationRoot, allowLocalArtifacts: allowLocalArtifacts
            )
        }
        return try await withTaskCancellationHandler {
            try await installation.value
        } onCancel: {
            installation.cancel()
        }
    }

    private static func installSynchronously(
        _ package: AgentPackage, node: URL, sourceRoot: URL?,
        destinationRoot: URL?, allowLocalArtifacts: Bool
    ) throws -> InstalledAgentPackage {
        let manager = FileManager.default
        let manifests = sourceRoot ?? defaultSourceRoot()
        let source = manifests.appendingPathComponent(package.id, isDirectory: true)
        let manifest = source.appendingPathComponent("package.json")
        let lock = source.appendingPathComponent("package-lock.json")
        guard manager.fileExists(atPath: manifest.path), manager.fileExists(atPath: lock.path)
        else { throw AgentPackageInstallError.missingManifest(package.name) }
        try validateLock(package, manifest: manifest, lock: lock,
                         allowLocalArtifacts: allowLocalArtifacts)

        let root = destinationRoot ?? manager.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("SiliconOptimizer/agent-packages", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appendingPathComponent("\(package.id)-\(UUID().uuidString)",
                                              isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        var installedSuccessfully = false
        defer {
            if !installedSuccessfully { try? manager.removeItem(at: staging) }
        }
        try manager.copyItem(at: manifest, to: staging.appendingPathComponent("package.json"))
        try manager.copyItem(at: lock, to: staging.appendingPathComponent("package-lock.json"))

        let npm = node.deletingLastPathComponent().appendingPathComponent("npm")
        guard manager.isExecutableFile(atPath: npm.path)
        else { throw AgentPackageInstallError.npmUnavailable(npm.path) }
        let globalConfig = staging.appendingPathComponent("empty-global.npmrc")
        try Data().write(to: globalConfig)
        let npmEnvironment = sanitizedNpmEnvironment(
            node: node, home: staging, globalConfig: globalConfig,
            cache: root.appendingPathComponent("cache", isDirectory: true)
        )
        try requireAuditedNpmVersion(npm, in: staging, environment: npmEnvironment)
        let log = staging.appendingPathComponent("npm-install.log")
        try Data().write(to: log)
        let logHandle = try FileHandle(forWritingTo: log)
        let process = Process()
        process.executableURL = npm
        process.arguments = ["ci", "--prefer-offline", "--no-audit", "--no-fund"]
        process.currentDirectoryURL = staging
        process.environment = npmEnvironment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = logHandle
        process.standardError = logHandle
        do {
            try process.run()
            let deadline = Date().addingTimeInterval(600)
            while process.isRunning && Date() < deadline && !Task<Never, Never>.isCancelled {
                Thread.sleep(forTimeInterval: 0.1)
            }
            if process.isRunning {
                process.terminate()
                let grace = Date().addingTimeInterval(3)
                while process.isRunning && Date() < grace {
                    Thread.sleep(forTimeInterval: 0.1)
                }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit()
            if Task<Never, Never>.isCancelled { throw CancellationError() }
            if Date() >= deadline { throw AgentPackageInstallError.npmTimedOut(package.name) }
        } catch {
            try? logHandle.close()
            throw error
        }
        try? logHandle.close()
        if process.terminationStatus != 0 {
            let output = (try? Data(contentsOf: log)) ?? Data()
            let detail = String(decoding: output.suffix(2_000), as: UTF8.self)
            throw AgentPackageInstallError.npmFailed(
                package.name, process.terminationStatus, detail
            )
        }
        try manager.removeItem(at: log)
        try manager.removeItem(at: globalConfig)

        let bin = staging.appendingPathComponent(package.binPath)
        let resolved = bin.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolved.hasPrefix(staging.standardizedFileURL.path + "/"),
              (try? bin.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              manager.isReadableFile(atPath: bin.path)
        else { throw AgentPackageInstallError.missingBin(package.name) }
        installedSuccessfully = true
        return InstalledAgentPackage(bin: bin, directory: staging)
    }

    /// Discovery uses a credential-free, bounded probe before ranking Node candidates.
    /// The install repeats the check so a changed npm binary cannot be silently accepted.
    static func supportsAuditedNpm(beside node: URL) -> Bool {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent(
            "silicon-npm-probe-\(UUID().uuidString)", isDirectory: true
        )
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: false)
            defer { try? manager.removeItem(at: directory) }
            let globalConfig = directory.appendingPathComponent("empty-global.npmrc")
            try Data().write(to: globalConfig)
            let environment = sanitizedNpmEnvironment(
                node: node, home: directory, globalConfig: globalConfig,
                cache: directory.appendingPathComponent("cache", isDirectory: true)
            )
            let npm = node.deletingLastPathComponent().appendingPathComponent("npm")
            let result = try probeNpmVersion(npm, in: directory, environment: environment)
            return result.status == 0 && isAuditedNpmVersion(result.output)
        } catch {
            return false
        }
    }

    /// No gateway bearer or inherited npm credentials reach dependency scripts or probes.
    private static func sanitizedNpmEnvironment(
        node: URL, home: URL, globalConfig: URL, cache: URL
    ) -> [String: String] {
        [
            "HOME": home.path,
            "PATH": "\(node.deletingLastPathComponent().path):/usr/bin:/bin:/usr/sbin:/sbin",
            "NPM_CONFIG_USERCONFIG": "/dev/null",
            "NPM_CONFIG_GLOBALCONFIG": globalConfig.path,
            "NPM_CONFIG_CACHE": cache.path,
            "NPM_CONFIG_ENGINE_STRICT": "true",
            "NPM_CONFIG_STRICT_ALLOW_SCRIPTS": "true",
            "NPM_CONFIG_UPDATE_NOTIFIER": "false",
        ]
    }

    /// Early npm 11 releases predate the audited lifecycle-script controls. Accept only
    /// the tested 11.19.0 policy behavior or a newer release, never just a major version.
    private static func requireAuditedNpmVersion(
        _ npm: URL, in directory: URL, environment: [String: String]
    ) throws {
        let result = try probeNpmVersion(npm, in: directory, environment: environment)
        guard result.status == 0, isAuditedNpmVersion(result.output) else {
            throw AgentPackageInstallError.npmTooOld(
                result.output.isEmpty ? "unknown" : result.output
            )
        }
    }

    private static func isAuditedNpmVersion(_ output: String) -> Bool {
        let components = output.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3,
              let major = Int(components[0]),
              let minor = Int(components[1]),
              let patch = Int(components[2])
        else { return false }
        return (major, minor, patch) >= (11, 19, 0)
    }

    private static func probeNpmVersion(
        _ npm: URL, in directory: URL, environment: [String: String]
    ) throws -> (output: String, status: Int32) {
        let log = directory.appendingPathComponent("npm-version.log")
        try Data().write(to: log)
        let handle = try FileHandle(forWritingTo: log)
        let process = Process()
        process.executableURL = npm
        process.arguments = ["--version"]
        process.currentDirectoryURL = directory
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = handle
        do {
            try process.run()
            let deadline = Date().addingTimeInterval(10)
            while process.isRunning && Date() < deadline && !Task<Never, Never>.isCancelled {
                Thread.sleep(forTimeInterval: 0.1)
            }
            if process.isRunning {
                process.terminate()
                let grace = Date().addingTimeInterval(1)
                while process.isRunning && Date() < grace {
                    Thread.sleep(forTimeInterval: 0.1)
                }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit()
        } catch {
            try? handle.close()
            throw error
        }
        try? handle.close()
        let output = String(decoding: (try? Data(contentsOf: log)) ?? Data(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try? FileManager.default.removeItem(at: log)
        if Task<Never, Never>.isCancelled { throw CancellationError() }
        return (output, process.terminationStatus)
    }

    private static func defaultSourceRoot() -> URL {
        let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("agent-packages", isDirectory: true)
        if Bundle.main.bundleURL.pathExtension.lowercased() == "app" {
            // A signed app must never fall back to a mutable build checkout.
            return bundled ?? Bundle.main.bundleURL
                .appendingPathComponent("Contents/Resources/agent-packages", isDirectory: true)
        }
        // A SwiftPM `swift run` executable has no assembled .app resources.
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SiliconRuntime
            .deletingLastPathComponent()  // Sources
            .deletingLastPathComponent()  // repository
            .appendingPathComponent("Resources/agent-packages", isDirectory: true)
    }

    private static func validateLock(
        _ package: AgentPackage, manifest: URL, lock: URL, allowLocalArtifacts: Bool
    ) throws {
        guard let manifestJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest))
                as? [String: Any],
              let manifestDependencies = manifestJSON["dependencies"] as? [String: String],
              manifestDependencies.count == 1,
              manifestDependencies[package.name] == package.installRequirement,
              let lockJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: lock))
                as? [String: Any],
              let lockfileVersion = lockJSON["lockfileVersion"] as? Int,
              lockfileVersion >= 2,
              let packages = lockJSON["packages"] as? [String: [String: Any]],
              let root = packages[""],
              let lockedDependencies = root["dependencies"] as? [String: String],
              lockedDependencies == manifestDependencies,
              let top = packages["node_modules/\(package.name)"],
              top["version"] as? String == package.version
        else { throw AgentPackageInstallError.invalidLock(package.name) }

        for (path, entry) in packages where !path.isEmpty {
            guard path.hasPrefix("node_modules/"),
                  path.split(separator: "/", omittingEmptySubsequences: false)
                      .allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  let integrity = entry["integrity"] as? String,
                  integrity.hasPrefix("sha512-"),
                  let resolved = entry["resolved"] as? String,
                  let url = URL(string: resolved),
                  (url.scheme == "https" && url.host != nil)
                    || (allowLocalArtifacts && url.scheme == "file")
            else { throw AgentPackageInstallError.invalidLock(package.name) }
        }
    }
}
