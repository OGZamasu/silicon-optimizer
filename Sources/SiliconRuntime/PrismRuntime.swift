import CryptoKit
import Foundation
import SiliconCore

/// PrismML's llama.cpp fork — the runtime Bonsai's ternary GGUFs need, fetched on demand.
///
/// Bundling it would ship a second copy of llama.cpp to everyone for one model family, so
/// the app fetches a reviewed fork build from GitHub the first time someone installs a model
/// that needs it: about 12 MB, into Application Support. The archive's checked-in SHA-256 is
/// verified before unpacking or launching it; the runtime probe then checks the ternary types.
/// The release tarball is flat and `@loader_path`-relative, so nothing is relocated or re-signed.
public enum PrismRuntime {

    public static let repository = "PrismML-Eng/llama.cpp"

    /// Update this tag and both digests together after reviewing a new release's build.
    public static let pinnedTag = "prism-b10685-7dffb15"

    /// SHA-256 values of the release archives at pinnedTag, recorded from GitHub's release
    /// asset metadata. These are reviewed source data, not values accepted from the network.
    static let pinnedDigests = [
        "-bin-macos-arm64.tar.gz": "7fffa7a40c74f3e9bd78f3f2f9f12f9befb7b13af45d5a69c239cf3fd37b9045",
        "-bin-macos-x64.tar.gz": "b674befce466c4938e7e70a7b13009c7df2e76b072525495a78851c987a5121a",
    ]

    /// What this Mac wants: the plain Metal build. The `kleidiai` variant is CPU-tuned.
    static var assetSuffix: String {
        #if arch(arm64)
        "-bin-macos-arm64.tar.gz"
        #else
        "-bin-macos-x64.tar.gz"
        #endif
    }

    public static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SiliconOptimizer/runtimes/llama-prism", isDirectory: true)
    }

    public struct Progress: Sendable {
        public var stage: String
    }

    public enum InstallError: LocalizedError {
        case download(String)
        case integrityMismatch(String)
        case badArchive(String)
        case wouldNotLaunch(String)
        case notTheFork(String)

        public var errorDescription: String? {
            switch self {
            case .download(let detail):
                "Downloading PrismML's build failed: \(detail)"
            case .integrityMismatch(let name):
                "The downloaded \(name) did not match its reviewed SHA-256 digest."
            case .badArchive(let detail):
                "The downloaded build could not be unpacked: \(detail)"
            case .wouldNotLaunch(let detail):
                "The downloaded llama-server would not start: \(detail)"
            case .notTheFork(let tag):
                "The \(tag) build doesn't carry PrismML's ternary types, so it isn't the fork."
            }
        }
    }

    // MARK: - Reviewed release

    struct Pick: Equatable {
        var tag: String
        var name: String
        var url: URL
        var size: Int64
        var sha256: String
    }

    static func pinnedPick(suffix: String = assetSuffix) -> Pick {
        guard let digest = pinnedDigests[suffix] else {
            preconditionFailure("No reviewed PrismML archive for \(suffix)")
        }
        let name = "llama-\(pinnedTag)\(suffix)"
        return Pick(
            tag: pinnedTag, name: name,
            url: URL(string: "https://github.com/\(repository)/releases/download/\(pinnedTag)/\(name)")!,
            size: 0, sha256: digest
        )
    }

    // MARK: - Install

    struct Record: Codable {
        var tag: String
        var asset: String
        var archiveSHA256: String
        var installedAt: Date
    }

    /// Fetches the fork into `root/bin` and returns it as an installation. Downloads land in
    /// a staging folder and the live copy is swapped in one move, so a failed fetch never
    /// leaves half an engine behind.
    @discardableResult
    public static func install(
        root: URL = defaultRoot,
        session: URLSession = .shared,
        progress: @escaping @Sendable (Progress) -> Void
    ) async throws -> RuntimeInstallation {
        try await install(root: root, pick: pinnedPick(), session: session, progress: progress)
    }

    /// Internal seam for exercising the verified download path against a local fixture.
    @discardableResult
    static func install(
        root: URL,
        pick: Pick,
        session: URLSession = .shared,
        progress: @escaping @Sendable (Progress) -> Void
    ) async throws -> RuntimeInstallation {
        let sizeNote = pick.size > 0 ? " (\(Bytes(pick.size).formatted))" : ""
        progress(Progress(stage: "Downloading \(pick.tag)\(sizeNote)"))
        let downloaded: URL
        let response: URLResponse
        do {
            (downloaded, response) = try await session.download(from: pick.url)
        } catch {
            throw InstallError.download(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw InstallError.download("\(pick.name) came back with status \(status)")
        }

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("llama-prism-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let archive = staging.appendingPathComponent(pick.name)
        try FileManager.default.moveItem(at: downloaded, to: archive)

        progress(Progress(stage: "Verifying \(pick.tag) archive"))
        guard try sha256Hex(of: archive) == pick.sha256 else {
            throw InstallError.integrityMismatch(pick.name)
        }

        progress(Progress(stage: "Unpacking \(pick.tag)"))
        let unpacked = staging.appendingPathComponent("unpacked", isDirectory: true)
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        try extract(archive, into: unpacked)
        guard let server = findServer(in: unpacked) else {
            throw InstallError.badArchive("no llama-server inside \(pick.name)")
        }

        progress(Progress(stage: "Checking the build"))
        guard RuntimeLocator.supportsPrismTernary(server) else {
            throw InstallError.notTheFork(pick.tag)
        }
        let banner = RuntimeLocator.run(server, arguments: ["--version"]) ?? ""
        guard banner.lowercased().contains("version") else {
            throw InstallError.wouldNotLaunch(
                banner.isEmpty ? "no output from --version" : banner
            )
        }

        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let incoming = root.appendingPathComponent("bin.incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: incoming)
        try FileManager.default.moveItem(at: server.deletingLastPathComponent(), to: incoming)
        try? FileManager.default.removeItem(at: bin)
        try FileManager.default.moveItem(at: incoming, to: bin)
        let record = Record(
            tag: pick.tag, asset: pick.name, archiveSHA256: pick.sha256, installedAt: Date()
        )
        try JSONEncoder().encode(record).write(to: root.appendingPathComponent("prism.json"))

        guard let installation = managedInstallation(root: root, expected: pick) else {
            throw InstallError.wouldNotLaunch("the installed copy failed its probe")
        }
        return installation
    }

    /// The copy the app fetched, only if its install record proves it came through the
    /// reviewed archive path. Older installs lack this record field and must be re-fetched.
    public static func managedInstallation(root: URL = defaultRoot) -> RuntimeInstallation? {
        managedInstallation(root: root, expected: pinnedPick())
    }

    static func managedInstallation(root: URL, expected: Pick) -> RuntimeInstallation? {
        guard let recordData = try? Data(contentsOf: root.appendingPathComponent("prism.json")),
              let record = try? JSONDecoder().decode(Record.self, from: recordData),
              record.tag == expected.tag,
              record.asset == expected.name,
              record.archiveSHA256 == expected.sha256
        else { return nil }
        let server = root.appendingPathComponent("bin/llama-server")
        guard FileManager.default.isExecutableFile(atPath: server.path),
              RuntimeLocator.supportsPrismTernary(server)
        else { return nil }
        let help = RuntimeLocator.capabilities(of: server)
        return RuntimeInstallation(
            kind: .llamaCppPrism, executable: server,
            version: record.tag,
            hasExpertStreaming: help.hasExpertStreaming, hasPrismTernary: true,
            source: .managed
        )
    }

    public static func remove(root: URL = defaultRoot) throws {
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    // MARK: - Helpers

    static func sha256Hex(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func extract(_ archive: URL, into directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xzf", archive.path, "-C", directory.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw InstallError.badArchive(
                String(decoding: output, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    static func findServer(in directory: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return nil }
        for case let url as URL in enumerator where url.lastPathComponent == "llama-server" {
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }
}
