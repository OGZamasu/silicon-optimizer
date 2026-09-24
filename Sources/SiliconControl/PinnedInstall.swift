import Foundation

/// The optional media tools — OpenMontage, LivePortrait, Deep-Live-Cam — are other people's
/// code, fetched and run on request. Each is bound here to one reviewed upstream commit and
/// a hash-locked dependency set, and its weights to a reviewed revision and digest, so what
/// runs is what was read: a moved branch, a replaced wheel or a swapped model is refused
/// before any of it executes. Bumping a pin is a review, not an edit — see
/// `Scripts/lock-media-installers.sh`, which rebuilds the locks from these commits.
///
/// Pure, like `OpenMontageLink`: this plans commands and never runs them.
public enum PinnedInstall {

    /// A source tree at one commit.
    public struct Source: Sendable, Equatable {
        public var name: String
        public var repository: String
        public var commit: String
        /// The directory under the lock root holding this tool's dependency locks.
        public var lockDirectory: String

        public var shortCommit: String { String(commit.prefix(7)) }
    }

    /// A file fetched from a fixed URL and kept only if its SHA-256 is the reviewed one.
    public struct File: Sendable, Equatable {
        /// Its path inside the repository it comes from.
        public var path: String
        public var url: URL
        public var sha256: String
        public var size: Int64
    }

    /// One process to run. Commands run in order and any failure stops the install.
    public struct Command: Sendable, Equatable {
        public var label: String
        public var executable: URL
        public var arguments: [String]
        public var workingDirectory: URL?

        public init(label: String, executable: URL, arguments: [String], workingDirectory: URL? = nil) {
            self.label = label
            self.executable = executable
            self.arguments = arguments
            self.workingDirectory = workingDirectory
        }
    }

    public enum PlanError: LocalizedError, Equatable {
        /// The interpreter is not one the tool's dependencies were locked for.
        case unsupportedPython(tool: String, found: String?, supported: [String])

        public var errorDescription: String? {
            switch self {
            case .unsupportedPython(let tool, let found, let supported):
                let versions = supported.count == 1
                    ? supported[0]
                    : supported.dropLast().joined(separator: ", ") + " or " + supported.last!
                let seen = found.map { "Python \($0) was found" } ?? "no Python of a known version was found"
                return "\(tool)'s reviewed dependencies are locked for Python \(versions), and "
                    + "\(seen). Install one with `brew install python@\(supported.last!)`."
            }
        }
    }

    // MARK: - The pins

    public static let openMontage = Source(
        name: "OpenMontage", repository: "https://github.com/calesthio/OpenMontage.git",
        commit: "08e2151fa02de28a5d6a312b3d575692bf147ad7", lockDirectory: "openmontage"
    )
    public static let livePortrait = Source(
        name: "LivePortrait", repository: "https://github.com/KwaiVGI/LivePortrait.git",
        commit: "9b294b3d0536135442ea73cb01e6cb3ca7029dd3", lockDirectory: "liveportrait"
    )
    public static let deepLiveCam = Source(
        name: "Deep-Live-Cam", repository: "https://github.com/hacksider/Deep-Live-Cam.git",
        commit: "d759e31b11d9432afdfddce698c0f7c9a715e086", lockDirectory: "deep-live-cam"
    )

    /// The Python versions each tool's dependencies are locked for, oldest first.
    public static let openMontagePythons = ["3.10", "3.11", "3.12", "3.13"]
    public static let livePortraitPython = "3.11"
    public static let deepLiveCamPythons = ["3.12", "3.13"]

    static func hubFile(
        _ repository: String, _ revision: String, _ path: String, sha256: String, size: Int64
    ) -> File {
        File(
            path: path,
            url: URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(path)")!,
            sha256: sha256, size: size
        )
    }

    /// Everything LivePortrait's human pipeline loads, relative to its `pretrained_weights`,
    /// from the Hub repository (moved from KwaiVGI, which still redirects) at a reviewed
    /// commit. The `.pth` files are pickles that torch 2.3 loads without `weights_only`, so a
    /// changed one is changed code: each is checked, not only the revision.
    public static let livePortraitWeights = [
        livePortraitWeight(
            "liveportrait/base_models/appearance_feature_extractor.pth",
            sha256: "5279bb8654293dbdf327030b397f107237dd9212fb11dd75b83dfb635211ceb5", size: 3_387_959
        ),
        livePortraitWeight(
            "liveportrait/base_models/motion_extractor.pth",
            sha256: "251e6a94ad667a1d0c69526d292677165110ef7f0cf0f6d199f0e414e8aa0ca5", size: 112_545_506
        ),
        livePortraitWeight(
            "liveportrait/base_models/spade_generator.pth",
            sha256: "4780afc7909a9f84e24c01d73b31a555ef651521a1fe3b2429bd04534d992aee", size: 221_813_590
        ),
        livePortraitWeight(
            "liveportrait/base_models/warping_module.pth",
            sha256: "2f61a6f265fe344f14132364859a78bdbbc2068577170693da57fb96d636e282", size: 182_180_086
        ),
        livePortraitWeight(
            "liveportrait/landmark.onnx",
            sha256: "31d22a5041326c31f19b78886939a634a5aedcaa5ab8b9b951a1167595d147db", size: 114_666_491
        ),
        livePortraitWeight(
            "liveportrait/retargeting_models/stitching_retargeting_module.pth",
            sha256: "3652d5a3f95099141a56986aaddec92fadf0a73c87a20fac9a2c07c32b28b611", size: 2_393_098
        ),
        livePortraitWeight(
            "insightface/models/buffalo_l/2d106det.onnx",
            sha256: "f001b856447c413801ef5c42091ed0cd516fcd21f2d6b79635b1e733a7109dbf", size: 5_030_888
        ),
        livePortraitWeight(
            "insightface/models/buffalo_l/det_10g.onnx",
            sha256: "5838f7fe053675b1c7a08b633df49e7af5495cee0493c7dcf6697200b85b5b91", size: 16_923_827
        ),
    ]

    static func livePortraitWeight(_ path: String, sha256: String, size: Int64) -> File {
        hubFile("KlingTeam/LivePortrait", "82a4fa6735ca58432b6ce39301b4b9ee066dea47", path,
                sha256: sha256, size: size)
    }

    /// Deep-Live-Cam's own downloader takes these from the moving `main` of its Hub
    /// repository, with certificate checking switched off on macOS. Fetched here first, at
    /// a reviewed commit and digest, its downloader finds them present and never runs.
    static func deepLiveCamWeight(_ path: String, sha256: String, size: Int64) -> File {
        hubFile("hacksider/deep-live-cam", "581e70b61240b7928404c17900437f47cfe94133", path,
                sha256: sha256, size: size)
    }

    /// The face swapper, which the project keeps in its own `models` folder.
    public static let deepLiveCamSwapper = deepLiveCamWeight(
        "inswapper_128.onnx",
        sha256: "e4a3f08c753cb72d04e10aa0f7dbe3deebbf39567d4ead6dce08e98aa49e16af", size: 554_253_681
    )

    /// The face analyser pack, which insightface reads from `~/.insightface/models/buffalo_l`.
    public static let deepLiveCamFaceAnalyser = [
        deepLiveCamWeight(
            "buffalo_l/buffalo_l/1k3d68.onnx",
            sha256: "df5c06b8a0c12e422b2ed8947b8869faa4105387f199c477af038aa01f9a45cc", size: 143_607_619
        ),
        deepLiveCamWeight(
            "buffalo_l/buffalo_l/2d106det.onnx",
            sha256: "f001b856447c413801ef5c42091ed0cd516fcd21f2d6b79635b1e733a7109dbf", size: 5_030_888
        ),
        deepLiveCamWeight(
            "buffalo_l/buffalo_l/det_10g.onnx",
            sha256: "5838f7fe053675b1c7a08b633df49e7af5495cee0493c7dcf6697200b85b5b91", size: 16_923_827
        ),
        deepLiveCamWeight(
            "buffalo_l/buffalo_l/genderage.onnx",
            sha256: "4fde69b1c810857b88c64a335084f1c3fe8f01246c9a191b48c7bb756d6652fb", size: 1_322_532
        ),
        deepLiveCamWeight(
            "buffalo_l/buffalo_l/w600k_r50.onnx",
            sha256: "4c06341c33c2ca1f86781dab0e829f88ad5b64be9fba56e56bc9ebdefc619e43", size: 174_383_860
        ),
    ]

    // MARK: - Locks

    /// Where the locks are: the app bundle's Resources, or the repository for `swift run`.
    public static func defaultLockRoot() -> URL {
        if Bundle.main.bundleURL.pathExtension.lowercased() == "app" {
            // A signed app must never fall back to a mutable build checkout.
            return Bundle.main.bundleURL
                .appendingPathComponent("Contents/Resources/pinned-installs", isDirectory: true)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SiliconControl
            .deletingLastPathComponent()  // Sources
            .deletingLastPathComponent()  // repository
            .appendingPathComponent("Resources/pinned-installs", isDirectory: true)
    }

    /// `<root>/<tool>/<kind>-py<version>.txt` — kind is `requirements`, `build` or `piper`.
    public static func lock(
        _ kind: String, for source: Source, python: String, in root: URL
    ) -> URL {
        root.appendingPathComponent(source.lockDirectory, isDirectory: true)
            .appendingPathComponent("\(kind)-py\(python).txt")
    }

    // MARK: - Python versions

    /// "3.12" from an interpreter named `python3.12`; nil for a bare `python3`, whose
    /// version the name does not say.
    public static func pythonVersion(ofInterpreter url: URL) -> String? {
        let name = url.lastPathComponent
        guard name.hasPrefix("python3."),
              let minor = Int(name.dropFirst("python3.".count))
        else { return nil }
        return "3.\(minor)"
    }

    /// "3.12" from a virtual environment's `pyvenv.cfg`, which venv and uv both write.
    public static func pythonVersion(ofVirtualEnvironment root: URL) -> String? {
        guard let text = try? String(
            contentsOf: root.appendingPathComponent("pyvenv.cfg"), encoding: .utf8
        ) else { return nil }
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[0] == "version" || parts[0] == "version_info"
            else { continue }
            let numbers = parts[1].split(separator: ".")
            if numbers.count >= 2, let major = Int(numbers[0]), let minor = Int(numbers[1]) {
                return "\(major).\(minor)"
            }
        }
        return nil
    }

    // MARK: - Commands

    /// Brings `directory` to exactly `source.commit`. A missing one is created; an existing
    /// one — app-managed, so local edits in it are not the user's — is moved to the commit.
    /// Fetching the commit by id, not cloning a branch, is the pin: git checks every object
    /// it receives against its id. The last command proves the result before anything in it
    /// is used.
    ///
    /// `git init` is always the first command. In an existing repository it changes nothing,
    /// and whether the repository will still be there is not known when the plan is made: an
    /// environment made again clears the checkouts kept inside it before this runs.
    public static func fetch(_ source: Source, into directory: URL, git: URL) -> [Command] {
        let label = "Downloading \(source.name) (reviewed revision \(source.shortCommit))"
        var commands = [Command(
            label: label, executable: git, arguments: ["init", "--quiet", directory.path]
        )]
        commands.append(Command(
            label: label, executable: git,
            arguments: ["-C", directory.path, "fetch", "--quiet", "--depth", "1",
                        source.repository, source.commit]
        ))
        commands.append(Command(
            label: label, executable: git,
            arguments: ["-C", directory.path, "-c", "advice.detachedHead=false", "checkout",
                        "--quiet", "--force", "--detach", source.commit]
        ))
        commands.append(verify(source, in: directory, git: git))
        return commands
    }

    /// Succeeds only when every tracked file in `directory` is the pinned commit's, byte for
    /// byte, whatever HEAD says; a checkout that has moved, or was edited, fails it — and
    /// says so, since `git diff --quiet` alone would fail in silence.
    public static func verify(_ source: Source, in directory: URL, git: URL) -> Command {
        Command(
            label: "Checking \(source.name) is the reviewed revision \(source.shortCommit)",
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", verifyScript, "verify-pinned", git.path, directory.path,
                        source.commit, source.name]
        )
    }

    static let verifyScript = #"""
        git="$1"; dir="$2"; commit="$3"; name="$4"
        if "$git" -C "$dir" diff --quiet --no-ext-diff --no-textconv "$commit" -- 2>/dev/null; then
            exit 0
        fi
        echo "$name in $dir is not the reviewed revision $commit, so nothing in it was run."
        exit 1
        """#

    /// Downloads `file` to `destination` and keeps it only if its SHA-256 is the reviewed
    /// one. A correct copy already there is left alone; a wrong one — from an unchecked
    /// download by an older version — is replaced. `protocols` is curl's `--proto` list;
    /// only tests widen it beyond https.
    public static func fetch(
        _ file: File, to destination: URL, label: String, protocols: String = "=https"
    ) -> Command {
        Command(
            label: label, executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", fetchFileScript, "fetch-verified", destination.path,
                        file.url.absoluteString, file.sha256, protocols]
        )
    }

    static let fetchFileScript = #"""
        set -eu
        dest="$1"; url="$2"; want="$3"; protocols="$4"
        digest() { /usr/bin/shasum -a 256 "$1" | /usr/bin/cut -d ' ' -f 1; }
        if [ -f "$dest" ] && [ "$(digest "$dest")" = "$want" ]; then exit 0; fi
        /bin/mkdir -p "$(/usr/bin/dirname "$dest")"
        part="$dest.part"
        /bin/rm -f "$part"
        /usr/bin/curl --fail --location --silent --show-error --retry 3 \
            --proto "$protocols" --proto-redir "$protocols" --output "$part" "$url"
        got="$(digest "$part")"
        if [ "$got" != "$want" ]; then
            /bin/rm -f "$part"
            echo "$(/usr/bin/basename "$dest") did not match its reviewed SHA-256 (got $got); discarded."
            exit 1
        fi
        /bin/mv -f "$part" "$dest"
        """#

    /// pip, run by the environment's own Python, installing exactly what `lock` names: every
    /// requirement pinned and every artifact checked against its hash before it is used.
    /// `onlyBinary` refuses source builds outright; `noBuildIsolation` builds the locked
    /// source packages with the environment's own, already locked, build tools instead of
    /// letting pip download unpinned ones.
    public static func pipInstall(
        python: URL, lock: URL, label: String,
        onlyBinary: Bool = false, noBuildIsolation: Bool = false
    ) -> Command {
        var arguments = ["-m", "pip", "install", "--quiet", "--disable-pip-version-check",
                         "--require-hashes"]
        if onlyBinary { arguments += ["--only-binary", ":all:"] }
        if noBuildIsolation { arguments += ["--no-build-isolation"] }
        arguments += ["-r", lock.path]
        return Command(label: label, executable: python, arguments: arguments)
    }

    /// The same, through uv, into the environment at `python`.
    public static func uvPipInstall(
        uv: URL, python: URL, lock: URL, label: String,
        noBuildIsolation: Bool = false, anyIndex: Bool = false
    ) -> Command {
        var arguments = ["pip", "install", "--python", python.path, "--require-hashes"]
        if noBuildIsolation { arguments += ["--no-build-isolation"] }
        // The lock names PyPI and PyTorch's index; a hash-pinned artifact is the same bytes
        // from either, so which index serves it is a matter of availability, not trust.
        if anyIndex { arguments += ["--index-strategy", "unsafe-best-match"] }
        arguments += ["-r", lock.path]
        return Command(label: label, executable: uv, arguments: arguments)
    }
}
