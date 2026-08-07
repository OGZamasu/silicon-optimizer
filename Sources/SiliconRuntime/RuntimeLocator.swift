import Foundation
import SiliconCore

/// Finds runtime binaries on the machine.
///
/// The app prefers a copy it ships itself, because that is the only way to guarantee the build
/// has the flags the planner wants to use. Failing that it falls back to Homebrew and then PATH,
/// and records which build it found so Advanced mode can show it.
public enum RuntimeLocator {

    /// Overridable by the user in Settings when they keep a custom build.
    public nonisolated(unsafe) static var customPaths: [RuntimeKind: URL] = [:]

    public static func locateLlamaServer() -> RuntimeInstallation? {
        for (url, source) in llamaCandidates() where isExecutable(url) {
            let help = capabilities(of: url)
            return RuntimeInstallation(
                kind: .llamaCpp,
                executable: url,
                version: help.version,
                hasExpertStreaming: help.hasExpertStreaming,
                source: source
            )
        }
        return nil
    }

    public static func locateMLXServer() -> RuntimeInstallation? {
        for url in mlxCandidates() where isExecutable(url) {
            let source: RuntimeInstallation.Source
            if url == customPaths[.mlx] {
                source = .userPath
            } else if url.path.hasPrefix("/opt/homebrew") {
                source = .homebrew
            } else {
                source = .systemPath
            }
            return RuntimeInstallation(
                kind: .mlx, executable: url, version: nil,
                hasExpertStreaming: false, source: source
            )
        }
        return nil
    }

    /// Where `mlx_lm.server` plausibly lives.
    ///
    /// macOS ships an externally-managed Python, so `pip install mlx-lm` fails with PEP 668 and
    /// essentially every user ends up in a virtual environment or pipx. Those are not on the
    /// PATH an app inherits from Finder, so searching only PATH and Homebrew reports MLX as
    /// missing on machines where it is installed and working.
    private static func mlxCandidates() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var results: [URL?] = [customPaths[.mlx]]

        // Common virtual-environment and pipx locations, plus the one this app's docs suggest.
        let relativeDirectories = [
            ".silicon-mlx/bin",     // the venv our own setup instructions create
            ".local/bin",           // pipx
            ".venv/bin",
            "venv/bin",
            "miniconda3/bin",
            "anaconda3/bin",
            "mambaforge/bin",
        ]
        for directory in relativeDirectories {
            results.append(home.appendingPathComponent("\(directory)/mlx_lm.server"))
        }

        results.append(URL(fileURLWithPath: "/opt/homebrew/bin/mlx_lm.server"))
        results.append(URL(fileURLWithPath: "/usr/local/bin/mlx_lm.server"))

        // `~/Library/Python/<version>/bin` from a `pip install --user`.
        let userPython = home.appendingPathComponent("Library/Python")
        if let versions = try? FileManager.default.contentsOfDirectory(
            at: userPython, includingPropertiesForKeys: nil
        ) {
            for version in versions {
                results.append(version.appendingPathComponent("bin/mlx_lm.server"))
            }
        }

        // Finally the login shell's PATH, which is what the user sees in Terminal.
        results.append(which("mlx_lm.server"))
        return results.compactMap { $0 }
    }

    // MARK: - Candidates

    private static func llamaCandidates() -> [(URL, RuntimeInstallation.Source)] {
        var results: [(URL, RuntimeInstallation.Source)] = []

        if let custom = customPaths[.llamaCpp] {
            results.append((custom, .userPath))
        }
        // A build shipped inside the app bundle takes priority: it is the one we tested against.
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "llama-server") {
            results.append((bundled, .bundled))
        }
        let resources = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/bin/llama-server")
        results.append((resources, .bundled))

        results.append((URL(fileURLWithPath: "/opt/homebrew/bin/llama-server"), .homebrew))
        results.append((URL(fileURLWithPath: "/usr/local/bin/llama-server"), .homebrew))

        if let onPath = which("llama-server") {
            results.append((onPath, .systemPath))
        }
        return results
    }

    private static func isExecutable(_ url: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: url.path)
    }

    /// Resolves a name through the login shell's PATH, which is what the user would get in
    /// Terminal — the app's own PATH is much narrower when launched from Finder.
    static func which(_ name: String) -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v \(name)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let path = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return path.isEmpty ? nil : URL(fileURLWithPath: path)
        } catch {
            return nil
        }
    }

    // MARK: - Capability probing

    struct Capabilities {
        var version: String?
        var hasExpertStreaming: Bool
    }

    /// Asks the binary what it can do.
    ///
    /// Two invocations, because llama.cpp splits the information: `--version` prints the build
    /// banner (to stderr) and `--help` lists the flags. Parsing help output is inelegant, but it
    /// is the only reliable way to tell whether a build carries the expert-paging patch — that
    /// feature lives on a proof-of-concept branch and has no version number of its own.
    static func capabilities(of executable: URL) -> Capabilities {
        let help = run(executable, arguments: ["--help"]) ?? ""
        let banner = run(executable, arguments: ["--version"]) ?? ""
        return Capabilities(
            version: parseVersion(from: banner),
            hasExpertStreaming: help.contains("--moe-n-slots")
        )
    }

    /// Runs a short-lived probe, merging stdout and stderr.
    private static func run(_ executable: URL, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
            // Read before waiting: a probe that fills the pipe buffer would otherwise deadlock
            // against a process that never exits.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        } catch {
            return nil
        }
    }

    private static func parseVersion(from banner: String) -> String? {
        // llama.cpp prints "version: 10280 (61881b1f7)".
        guard let range = banner.range(
            of: #"version:\s*\S+(\s*\([0-9a-f]+\))?"#, options: .regularExpression
        ) else { return nil }
        return String(banner[range])
            .replacingOccurrences(of: "version:", with: "")
            .trimmingCharacters(in: .whitespaces)
    }
}
