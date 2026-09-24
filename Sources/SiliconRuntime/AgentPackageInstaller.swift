import CryptoKit
import Darwin
import Foundation

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
    case versionProbeTimedOut(String)
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
                + "`npm install -g npm@11` (and Node.js if required), then try again."
        case .npmFailed(let name, let status, let detail):
            return "Could not install the verified \(name) package (npm ci exited \(status)). "
                + "The first install needs network access unless npm has cached every "
                + "locked artifact.\(detail.isEmpty ? "" : "\n\(detail)")"
        case .npmTimedOut(let name):
            return "Installing the verified \(name) package timed out."
        case .versionProbeTimedOut(let path):
            return "\(path) did not report its version within ten seconds. On a busy Mac, or "
                + "the first time macOS sees a new Node.js, that can happen once — try again."
        case .missingBin(let name):
            return "The verified \(name) package did not contain its expected entry point."
        }
    }
}

struct InstalledAgentPackage: Sendable {
    let bin: URL
    /// The verified tree `bin` lives in. It is kept between launches and shared by them; a
    /// runtime never deletes it.
    let directory: URL
    /// Whether this start reused a tree that verified, rather than running `npm ci`.
    let reused: Bool
}

/// One verified tree per bundled lock. The first start installs it from the bundled
/// integrity lock with a strict `npm ci` in a fresh directory, so neither a previous agent
/// run nor a project-local package can become the binary, and records every file's size
/// and SHA-256. Each later start checks the tree against that record and uses it; any
/// difference, or a different lock or Node line, installs it again. The check is a fraction
/// of a second for Codex's and Qwen Code's trees and a few seconds for the harness's ~30,000
/// files on an internal SSD, where a strict reinstall of the same tree takes tens of seconds
/// and writes 100–280 MB. It still fails closed on a tree that was changed.
///
/// Per-launch folders from before this, and installs that never finished, record the app
/// process that made them and are removed once that process is gone.
enum AgentPackageInstaller {
    /// Names the process that owns an unfinished install, as a decimal pid.
    static let ownerFileName = ".silicon-owner"
    /// The record of a finished tree: every entry's size and SHA-256, and what it was
    /// installed from.
    static let manifestFileName = ".silicon-verified.json"

    static func install(
        _ package: AgentPackage, node: URL, sourceRoot: URL? = nil,
        destinationRoot: URL? = nil, allowLocalArtifacts: Bool = false
    ) async throws -> InstalledAgentPackage {
        let cancellation = InstallCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // A thread of its own rather than a task. Everything below waits on child
                // processes with a blocking poll — `node --version`, `npm --version`, then
                // `npm ci` for up to ten minutes — and a thread of the cooperative pool held
                // that long is one no other task in the process can have. On a loaded
                // machine that was enough to make this install's own first steps start late.
                let thread = Thread {
                    continuation.resume(with: Result {
                        try installSynchronously(
                            package, node: node, sourceRoot: sourceRoot,
                            destinationRoot: destinationRoot,
                            allowLocalArtifacts: allowLocalArtifacts,
                            isCancelled: cancellation.isCancelled
                        )
                    })
                }
                thread.name = "Agent package install"
                thread.qualityOfService = .userInitiated
                thread.start()
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    /// Whether the caller of an install has given up on it. The install runs on a thread,
    /// where `Task.isCancelled` has no task to ask about, so this is what its polling loops
    /// read instead.
    private final class InstallCancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        func cancel() { lock.withLock { cancelled = true } }

        @Sendable func isCancelled() -> Bool { lock.withLock { cancelled } }
    }

    private static func installSynchronously(
        _ package: AgentPackage, node: URL, sourceRoot: URL?,
        destinationRoot: URL?, allowLocalArtifacts: Bool, isCancelled: () -> Bool
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
        pruneAbandonedInstallations(in: root)

        // The tree is keyed by what decides its contents: the bundled manifest and lock, and
        // the Node line whose ABI any native module was built or chosen for.
        let lockDigest = sha256Hex(try Data(contentsOf: manifest) + Data(contentsOf: lock))
        // A probe that was cancelled or timed out throws rather than reading as "unknown": the
        // key it would make names no tree there is, and the prune below would take that as
        // licence to delete the verified one.
        let nodeLine = try nodeMajorVersion(node, in: root, isCancelled: isCancelled) ?? "unknown"
        let key = String(sha256Hex(Data("\(lockDigest)\nnode \(nodeLine)\n".utf8)).prefix(16))
        let tree = root.appendingPathComponent("\(package.id)-\(key)", isDirectory: true)
        let expected = TreeIdentity(package: package.spec, lock: lockDigest, node: nodeLine)
        defer { pruneStaleTrees(of: package, keeping: tree, in: root) }

        if manager.fileExists(atPath: tree.path) {
            if try verifyTree(tree, expected: expected) {
                return InstalledAgentPackage(
                    bin: try entryPoint(package, in: tree), directory: tree, reused: true
                )
            }
            try discard(tree, in: root)
        }

        let staging = try installFresh(
            package, node: node, manifest: manifest, lock: lock, root: root,
            isCancelled: isCancelled
        )
        var installedSuccessfully = false
        defer {
            if !installedSuccessfully { try? manager.removeItem(at: staging) }
        }
        _ = try entryPoint(package, in: staging)
        try manager.removeItem(at: staging.appendingPathComponent(ownerFileName))
        try writeManifest(of: staging, identity: expected)
        do {
            try manager.moveItem(at: staging, to: tree)
        } catch {
            // Another copy of the app finished the same tree first. Use it if it verifies.
            guard manager.fileExists(atPath: tree.path), try verifyTree(tree, expected: expected)
            else { throw error }
            return InstalledAgentPackage(
                bin: try entryPoint(package, in: tree), directory: tree, reused: true
            )
        }
        installedSuccessfully = true
        return InstalledAgentPackage(
            bin: try entryPoint(package, in: tree), directory: tree, reused: false
        )
    }

    /// Runs the strict `npm ci` into a new owned directory and returns it.
    private static func installFresh(
        _ package: AgentPackage, node: URL, manifest: URL, lock: URL, root: URL,
        isCancelled: () -> Bool
    ) throws -> URL {
        let manager = FileManager.default
        let staging = root.appendingPathComponent("\(package.id)-\(UUID().uuidString)",
                                              isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        var succeeded = false
        defer {
            if !succeeded { try? manager.removeItem(at: staging) }
        }
        // Claimed before anything else lands in it, so a pruner in another launch never
        // mistakes this tree for one left behind.
        try Data("\(getpid())\n".utf8).write(to: staging.appendingPathComponent(ownerFileName))
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
        try requireAuditedNpmVersion(
            npm, in: staging, environment: npmEnvironment, isCancelled: isCancelled
        )
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
            // A quit mid-install must not leave npm running; the registry's reaper sees it.
            ChildProcessRegistry.register(pid: process.processIdentifier)
            defer { ChildProcessRegistry.unregister(pid: process.processIdentifier) }
            let deadline = Date().addingTimeInterval(600)
            while process.isRunning && Date() < deadline && !isCancelled() {
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
            if isCancelled() { throw CancellationError() }
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
        succeeded = true
        return staging
    }

    /// The package's entry point, which must be a regular file inside `tree` — both sides
    /// resolved, so a symlinked Application Support compares like with like.
    private static func entryPoint(_ package: AgentPackage, in tree: URL) throws -> URL {
        let bin = tree.appendingPathComponent(package.binPath)
        let resolvedTree = tree.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedBin = bin.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedBin.hasPrefix(resolvedTree + "/"),
              (try? bin.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              FileManager.default.isReadableFile(atPath: bin.path)
        else { throw AgentPackageInstallError.missingBin(package.name) }
        return bin
    }

    // MARK: - The verified tree

    /// What a tree was installed from; a tree for anything else is not reused.
    struct TreeIdentity: Codable, Equatable {
        var package: String
        var lock: String
        var node: String
    }

    private struct TreeManifest: Codable {
        struct Entry: Codable, Equatable {
            var size: Int64?
            var sha256: String?
            var link: String?
            /// Permission bits: an executable bit is as much a part of the tree as bytes.
            var mode: Int?
        }
        var identity: TreeIdentity
        var entries: [String: Entry]
    }

    /// Records every file (size, permissions and SHA-256) and symlink (target) under `tree`.
    static func writeManifest(of tree: URL, identity: TreeIdentity) throws {
        let record = TreeManifest(identity: identity, entries: try entries(of: tree))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(record).write(to: tree.appendingPathComponent(manifestFileName))
    }

    /// Whether `tree` is exactly what its record says and the record is for `expected`:
    /// the same entries, no more and no fewer, each the same size and bytes. Anything that
    /// cannot be read counts as a difference.
    static func verifyTree(_ tree: URL, expected: TreeIdentity) throws -> Bool {
        guard let data = try? Data(contentsOf: tree.appendingPathComponent(manifestFileName)),
              let record = try? JSONDecoder().decode(TreeManifest.self, from: data),
              record.identity == expected
        else { return false }
        // Sizes and links first: cheap, and a different set of entries fails before any
        // hashing starts.
        guard let found = try? entries(of: tree, hashing: false),
              found.count == record.entries.count
        else { return false }
        for (path, entry) in found {
            guard let recorded = record.entries[path],
                  recorded.size == entry.size, recorded.link == entry.link,
                  recorded.mode == entry.mode
            else { return false }
        }
        for (path, recorded) in record.entries where recorded.sha256 != nil {
            try Task.checkCancellation()
            guard let actual = try? sha256Hex(of: tree.appendingPathComponent(path)),
                  actual == recorded.sha256
            else { return false }
        }
        return true
    }

    /// Every entry under `root` except the manifest, keyed by relative path. Anything but a
    /// regular file, a symlink or a directory makes the tree unusable.
    private static func entries(
        of root: URL, hashing: Bool = true
    ) throws -> [String: TreeManifest.Entry] {
        let manager = FileManager.default
        let base = root.standardizedFileURL.path + "/"
        // An unreadable directory ends the walk early; that must fail the tree, not
        // shorten its record.
        final class Failure: @unchecked Sendable { var happened = false }
        let failure = Failure()
        guard let enumerator = manager.enumerator(
            at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey,
                                                    .isDirectoryKey, .fileSizeKey],
            options: [], errorHandler: { _, _ in failure.happened = true; return false }
        ) else { throw CocoaError(.fileReadUnknown) }
        var result: [String: TreeManifest.Entry] = [:]
        for case let url as URL in enumerator {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(base) else { throw CocoaError(.fileReadUnknown) }
            let relative = String(path.dropFirst(base.count))
            if relative == manifestFileName { continue }
            let values = try url.resourceValues(
                forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey]
            )
            if values.isSymbolicLink == true {
                result[relative] = .init(
                    link: try manager.destinationOfSymbolicLink(atPath: url.path)
                )
            } else if values.isRegularFile == true {
                let permissions = try manager.attributesOfItem(atPath: url.path)[.posixPermissions]
                result[relative] = .init(
                    size: Int64(values.fileSize ?? 0),
                    sha256: hashing ? try sha256Hex(of: url) : nil,
                    mode: (permissions as? NSNumber)?.intValue
                )
            } else if values.isDirectory != true {
                throw CocoaError(.fileReadUnknown)
            }
        }
        if failure.happened { throw CocoaError(.fileReadUnknown) }
        if !hashing {
            // Presence of a hash is compared from the record's side.
            return result.mapValues { .init(size: $0.size, sha256: nil, link: $0.link, mode: $0.mode) }
        }
        return result
    }

    private static func sha256Hex(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Moves a tree that failed verification out of the way before deleting it, so a
    /// half-deleted tree is never found under the verified name.
    private static func discard(_ tree: URL, in root: URL) throws {
        let aside = root.appendingPathComponent("discarded-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.moveItem(at: tree, to: aside)
        try? FileManager.default.removeItem(at: aside)
    }

    /// Removes this package's trees for other locks or Node lines — an app update or a Node
    /// switch left them — and any discarded tree a crash interrupted.
    private static func pruneStaleTrees(of package: AgentPackage, keeping tree: URL, in root: URL) {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: root.path) else { return }
        let prefix = "\(package.id)-"
        for name in names where name != tree.lastPathComponent {
            let isOldTree = name.hasPrefix(prefix) && name.count == prefix.count + 16
                && name.dropFirst(prefix.count).allSatisfy { $0.isHexDigit && !$0.isUppercase }
            if isOldTree || name.hasPrefix("discarded-") {
                try? manager.removeItem(at: root.appendingPathComponent(name))
            }
        }
    }

    /// The Node's major version, which fixes the ABI of any native module in the tree. Nil
    /// when the Node answered with something else; a probe that never answered throws.
    private static func nodeMajorVersion(
        _ node: URL, in directory: URL, isCancelled: () -> Bool
    ) throws -> String? {
        let result = try probeVersion(node, in: directory, environment: [
            "HOME": directory.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        ], isCancelled: isCancelled)
        guard result.status == 0, result.output.hasPrefix("v"),
              let major = result.output.dropFirst().split(separator: ".").first
        else { return nil }
        return String(major)
    }

    /// Removes per-launch trees and unfinished installs nobody can be using: their owner
    /// process has exited, or they never got an owner and are over an hour old (a launch
    /// that died while creating one). A live owner — this app, or another copy of it —
    /// keeps its trees; a reused pid only postpones a removal. The npm cache is not a tree.
    static func pruneAbandonedInstallations(in root: URL, now: Date = Date()) {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey]
        ) else { return }
        for entry in entries where isInstallationName(entry.lastPathComponent) {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { continue }
            let owner = (try? String(
                contentsOf: entry.appendingPathComponent(ownerFileName), encoding: .utf8
            )).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            if let owner {
                if owner > 0, kill(owner, 0) == 0 || errno == EPERM { continue }
            } else {
                let created = (try? entry.resourceValues(forKeys: [.creationDateKey]))?
                    .creationDate ?? now
                guard now.timeIntervalSince(created) > 3600 else { continue }
            }
            try? manager.removeItem(at: entry)
        }
    }

    /// `<package id>-<UUID>`: an install in progress, or a per-launch tree from before.
    private static func isInstallationName(_ name: String) -> Bool {
        guard name.count > 37 else { return false }
        return name.dropLast(36).hasSuffix("-") && UUID(uuidString: String(name.suffix(36))) != nil
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
            let result = try probeVersion(
                npm, in: directory, environment: environment,
                isCancelled: { Task<Never, Never>.isCancelled }
            )
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
        _ npm: URL, in directory: URL, environment: [String: String],
        isCancelled: () -> Bool
    ) throws {
        let result = try probeVersion(
            npm, in: directory, environment: environment, isCancelled: isCancelled
        )
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

    /// `<executable> --version`, bounded, in `directory`, with only `environment`. Throws
    /// `CancellationError` when cancelled and `versionProbeTimedOut` when it had to be killed:
    /// neither is an answer, and a caller must not read one into it.
    private static func probeVersion(
        _ executable: URL, in directory: URL, environment: [String: String],
        isCancelled: () -> Bool
    ) throws -> (output: String, status: Int32) {
        let log = directory.appendingPathComponent("version-\(UUID().uuidString).log")
        try Data().write(to: log)
        let handle = try FileHandle(forWritingTo: log)
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--version"]
        process.currentDirectoryURL = directory
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = handle
        var timedOut = false
        do {
            try process.run()
            let deadline = Date().addingTimeInterval(10)
            while process.isRunning && Date() < deadline && !isCancelled() {
                Thread.sleep(forTimeInterval: 0.1)
            }
            if process.isRunning {
                timedOut = !isCancelled()
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
        if isCancelled() { throw CancellationError() }
        if timedOut { throw AgentPackageInstallError.versionProbeTimedOut(executable.path) }
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

    static func validateLock(
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
                  // Every reviewed artifact came from the public registry; a lock that
                  // points anywhere else is not the lock that was reviewed.
                  (url.scheme == "https" && url.host == "registry.npmjs.org")
                    || (allowLocalArtifacts && url.scheme == "file")
            else { throw AgentPackageInstallError.invalidLock(package.name) }
        }
    }
}
