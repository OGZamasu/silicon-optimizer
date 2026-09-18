import Foundation
import SiliconCore

/// PrismML's llama.cpp fork — the runtime Bonsai's ternary GGUFs need, fetched on demand.
///
/// Bundling it would ship a second copy of llama.cpp to everyone for one model family, so
/// the app fetches the fork's macOS build from its GitHub releases the first time someone
/// installs a model that needs it: about 12 MB, into Application Support, verified by
/// launching it and checking the ternary type names are really in the binary. The release
/// tarball is flat and `@loader_path`-relative, so nothing is relocated or re-signed.
public enum PrismRuntime {

    public static let repository = "PrismML-Eng/llama.cpp"

    /// Known-good release, used when the API is unreachable or the newest tag hasn't
    /// finished uploading its macOS build (assets land over an hour or so after the tag).
    public static let pinnedTag = "prism-b10685-7dffb15"

    public static var releasesURL: URL {
        URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=10")!
    }

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
        case badArchive(String)
        case wouldNotLaunch(String)
        case notTheFork(String)

        public var errorDescription: String? {
            switch self {
            case .download(let detail):
                "Downloading PrismML's build failed: \(detail)"
            case .badArchive(let detail):
                "The downloaded build could not be unpacked: \(detail)"
            case .wouldNotLaunch(let detail):
                "The downloaded llama-server would not start: \(detail)"
            case .notTheFork(let tag):
                "The \(tag) build doesn't carry PrismML's ternary types, so it isn't the fork."
            }
        }
    }

    // MARK: - Release resolution

    struct Release: Decodable {
        var tagName: String
        var draft: Bool
        var prerelease: Bool
        var assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case draft, prerelease, assets
        }
    }

    struct Asset: Decodable {
        var name: String
        var downloadURL: URL
        var size: Int64

        enum CodingKeys: String, CodingKey {
            case name, size
            case downloadURL = "browser_download_url"
        }
    }

    struct Pick: Equatable {
        var tag: String
        var name: String
        var url: URL
        var size: Int64
    }

    /// The newest published release that actually has this Mac's build attached — a fresh
    /// tag can sit for a while with only some platforms uploaded.
    static func pick(from releases: [Release], suffix: String = assetSuffix) -> Pick? {
        for release in releases where !release.draft && !release.prerelease {
            if let asset = release.assets.first(where: {
                $0.name.hasPrefix("llama-prism-") && $0.name.hasSuffix(suffix)
            }) {
                return Pick(
                    tag: release.tagName, name: asset.name, url: asset.downloadURL,
                    size: asset.size
                )
            }
        }
        return nil
    }

    static func pinnedPick(suffix: String = assetSuffix) -> Pick {
        let name = "llama-\(pinnedTag)\(suffix)"
        return Pick(
            tag: pinnedTag, name: name,
            url: URL(string: "https://github.com/\(repository)/releases/download/\(pinnedTag)/\(name)")!,
            size: 0
        )
    }

    static func resolve(releasesURL: URL, session: URLSession) async -> Pick {
        var request = URLRequest(url: releasesURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        guard let (data, _) = try? await session.data(for: request),
              let releases = try? JSONDecoder().decode([Release].self, from: data),
              let pick = pick(from: releases)
        else { return pinnedPick() }
        return pick
    }

    // MARK: - Install

    struct Record: Codable {
        var tag: String
        var asset: String
        var installedAt: Date
    }

    /// Fetches the fork into `root/bin` and returns it as an installation. Downloads land in
    /// a staging folder and the live copy is swapped in one move, so a failed fetch never
    /// leaves half an engine behind.
    @discardableResult
    public static func install(
        root: URL = defaultRoot,
        releasesURL: URL = releasesURL,
        session: URLSession = .shared,
        progress: @escaping @Sendable (Progress) -> Void
    ) async throws -> RuntimeInstallation {
        progress(Progress(stage: "Finding the newest PrismML build"))
        let pick = await resolve(releasesURL: releasesURL, session: session)

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
        let record = Record(tag: pick.tag, asset: pick.name, installedAt: Date())
        try JSONEncoder().encode(record).write(to: root.appendingPathComponent("prism.json"))

        guard let installation = managedInstallation(root: root) else {
            throw InstallError.wouldNotLaunch("the installed copy failed its probe")
        }
        return installation
    }

    /// The copy the app fetched, if it is there and still the fork.
    public static func managedInstallation(root: URL = defaultRoot) -> RuntimeInstallation? {
        let server = root.appendingPathComponent("bin/llama-server")
        guard FileManager.default.isExecutableFile(atPath: server.path),
              RuntimeLocator.supportsPrismTernary(server)
        else { return nil }
        let help = RuntimeLocator.capabilities(of: server)
        let record = (try? Data(contentsOf: root.appendingPathComponent("prism.json")))
            .flatMap { try? JSONDecoder().decode(Record.self, from: $0) }
        return RuntimeInstallation(
            kind: .llamaCppPrism, executable: server,
            version: record?.tag ?? help.version,
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
