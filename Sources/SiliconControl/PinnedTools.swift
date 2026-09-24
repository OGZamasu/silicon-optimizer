import Foundation

/// The other optional installers held to the same rule as the media tools: LuxTTS and its
/// LinaCodec at reviewed commits, MFLUX and the voice tools (which share one environment),
/// face tracking and Laya, each installing only a hash-locked set of Python packages, and
/// tracking's models by digest. The locks are in `Resources/pinned-installs` beside the
/// media tools', rebuilt by the same `Scripts/lock-media-installers.sh`.
extension PinnedInstall {

    // MARK: - LuxTTS

    public static let luxTTS = Source(
        name: "LuxTTS", repository: "https://github.com/ysharma3501/LuxTTS.git",
        commit: "28ae6a61151684fffc9d1a7aa15eafa02286fe0b", lockDirectory: "luxtts"
    )

    /// LuxTTS's requirements name this as a git dependency on a moving branch, which pip's
    /// hash checking refuses outright. It is fetched by commit and verified like any other
    /// pinned source instead, and installed without its dependencies — those are in LuxTTS's
    /// lock, read from its pyproject at this commit.
    public static let linaCodec = Source(
        name: "LinaCodec", repository: "https://github.com/ysharma3501/LinaCodec.git",
        commit: "c0ae7c7285e121475c27592cfbb600624b714290", lockDirectory: "luxtts"
    )

    /// torch and piper_phonemize, from the same lock, have no builds before 3.12 at these
    /// versions.
    public static let luxTTSPythons = ["3.12", "3.13", "3.14"]

    // MARK: - The shared MLX environment

    /// MFLUX and the voice tools share `~/.silicon-mlx`, and their locks are resolved
    /// together — the voice set within MFLUX's versions — so installing either over the
    /// other moves nothing. `mflux-py*`, `voice-py*` and the voice tools' `build-py*`.
    public static let mlxEnvironmentLocks = "silicon-mlx"
    public static let mfluxPythons = ["3.12", "3.13", "3.14"]
    /// mlx-speech, for sound effects, needs 3.13.
    public static let voicePythons = ["3.13", "3.14"]

    // MARK: - Face tracking

    public static let trackerLocks = "tracker"
    public static let trackerPythons = ["3.12", "3.13", "3.14"]

    static func mediaPipeModel(_ path: String, _ name: String, sha256: String, size: Int64) -> File {
        File(
            path: name,
            url: URL(string: "https://storage.googleapis.com/mediapipe-models/\(path)/\(name)")!,
            sha256: sha256, size: size
        )
    }

    /// The landmarker models, by their numbered release rather than `latest` — the body and
    /// hand models used to be fetched from `latest`, which Google may replace at any time.
    public static let trackerFaceModel = mediaPipeModel(
        "face_landmarker/face_landmarker/float16/1", "face_landmarker.task",
        sha256: "64184e229b263107bc2b804c6625db1341ff2bb731874b0bcc2fe6544e0bc9ff", size: 3_758_596
    )
    public static let trackerPoseModel = mediaPipeModel(
        "pose_landmarker/pose_landmarker_lite/float16/1", "pose_landmarker_lite.task",
        sha256: "59929e1d1ee95287735ddd833b19cf4ac46d29bc7afddbbf6753c459690d574a", size: 5_777_746
    )
    public static let trackerHandModel = mediaPipeModel(
        "hand_landmarker/hand_landmarker/float16/1", "hand_landmarker.task",
        sha256: "fbc2a30080c3c557093b5ddfc334698132eb341044ccee322ccf8bcf3607cde1", size: 7_819_105
    )

    // MARK: - Laya

    public static let layaLocks = "laya"
    public static let layaPythons = ["3.11", "3.12", "3.13", "3.14"]

    // MARK: - Locks and interpreters

    /// `<root>/<directory>/<kind>-py<version>.txt`, for a tool whose package list is the app's
    /// own rather than an upstream project's.
    public static func lock(_ kind: String, directory: String, python: String, in root: URL) -> URL {
        root.appendingPathComponent(directory, isDirectory: true)
            .appendingPathComponent("\(kind)-py\(python).txt")
    }

    /// The newest interpreter the locks cover, from where Homebrew and python.org put one —
    /// never a bare `python3`, whose version its name does not say, and never macOS's own
    /// 3.9, which none of these tools' locks can serve.
    public static func basePython(
        for versions: [String],
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> URL? {
        for version in versions.reversed() {
            for directory in [
                "/opt/homebrew/bin", "/usr/local/bin",
                "/Library/Frameworks/Python.framework/Versions/\(version)/bin",
            ] {
                let path = "\(directory)/python\(version)"
                if isExecutable(path) { return URL(fileURLWithPath: path) }
            }
        }
        return nil
    }

    /// The environment a tool installs into, and the version its locks are chosen by: an
    /// existing environment's own when the locks cover it, and otherwise the base
    /// interpreter's, which makes it — or makes it again.
    ///
    /// Again, because an environment here is the app's, not the user's. One an older install
    /// made with a Python no lock covers — macOS's own 3.9, which all of these were once
    /// installed on, or the shared environment's 3.12 under the voice tools' 3.13 floor — was
    /// refused on every install, with advice to install a Python that nothing would then use.
    /// Only with no covered interpreter to make it from is a plan refused, before a single
    /// command runs; and then installing one is advice that works.
    public static func environment(
        _ environment: URL, tool: String, supported: [String], basePython: URL?
    ) throws -> (python: URL, version: String, commands: [Command]) {
        let python = environment.appendingPathComponent("bin/python3")
        let existing = FileManager.default.isExecutableFile(atPath: python.path)
        let found = existing ? pythonVersion(ofVirtualEnvironment: environment) : nil
        if let found, supported.contains(found) { return (python, found, []) }
        let version = basePython.flatMap(pythonVersion(ofInterpreter:))
        guard let basePython, let version, supported.contains(version) else {
            throw PlanError.unsupportedPython(
                tool: tool, found: existing ? found : version, supported: supported
            )
        }
        guard existing else {
            return (python, version, [Command(
                label: "Making its Python environment",
                executable: basePython, arguments: ["-m", "venv", environment.path]
            )])
        }
        // `--clear` empties the folder first: packages built for another Python are no use to
        // this one, and a plan that kept anything else in there has to make it again.
        return (python, version, [Command(
            label: "Making its Python environment again, with Python \(version)",
            executable: basePython, arguments: ["-m", "venv", "--clear", environment.path]
        )])
    }

    /// Whether `environment(_:tool:supported:basePython:)` would make `environment` again —
    /// it is there, made with a Python `supported` does not include — and so clear out
    /// whatever else is installed in it.
    public static func needsRemaking(_ environment: URL, supported: [String]) -> Bool {
        let python = environment.appendingPathComponent("bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path) else { return false }
        guard let found = pythonVersion(ofVirtualEnvironment: environment) else { return true }
        return !supported.contains(found)
    }

    /// Installs a checkout that `verify` has just proved is the pinned commit, and nothing
    /// else: no dependencies (the lock installed them, hash-checked), no index (nothing is
    /// downloaded), no isolated build (the locked build backend already in the environment
    /// builds it). pip cannot hash a directory, so this is the one install without
    /// `--require-hashes`; git's own object ids stand in for the hash.
    public static func pipInstallVerifiedCheckout(
        python: URL, checkout: URL, label: String
    ) -> Command {
        Command(
            label: label, executable: python,
            arguments: ["-m", "pip", "install", "--quiet", "--disable-pip-version-check",
                        "--no-deps", "--no-index", "--no-build-isolation", checkout.path]
        )
    }
}

// MARK: - Hub models the runtimes read

extension PinnedInstall {

    /// One Hugging Face repository at one commit: the files a runtime reads from it, each with
    /// its SHA-256. Generated by `Scripts/pin-hub-models.sh` into
    /// `Resources/pinned-installs/models`.
    public struct HubModel: Codable, Sendable, Equatable {
        public struct File: Codable, Sendable, Equatable {
            public var path: String
            public var sha256: String
            public var size: Int64
        }

        public var repository: String
        public var revision: String
        public var files: [File]

        /// `<root>/models/<org>--<name>.json`.
        public static func manifest(_ repository: String, in root: URL) -> URL {
            root.appendingPathComponent("models", isDirectory: true)
                .appendingPathComponent(repository.replacingOccurrences(of: "/", with: "--") + ".json")
        }

        public static func load(_ repository: String, from root: URL) throws -> HubModel {
            let model = try JSONDecoder().decode(
                HubModel.self, from: Data(contentsOf: manifest(repository, in: root))
            )
            guard model.repository == repository else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return model
        }

        /// Hugging Face's own layout under a hub cache: `models--org--name`.
        public func cacheDirectory(hub: URL) -> URL {
            hub.appendingPathComponent(
                "models--" + repository.replacingOccurrences(of: "/", with: "--"), isDirectory: true
            )
        }

        public func snapshot(hub: URL) -> URL {
            cacheDirectory(hub: hub).appendingPathComponent("snapshots/\(revision)", isDirectory: true)
        }

        /// Puts every file into the hub cache at the pinned commit, checked, the way Hugging
        /// Face lays it out: the bytes in `blobs/<sha256>`, and the snapshot's entry a
        /// relative link to them. A file already there and right is left alone; a blob an
        /// earlier download of any revision left, if it is right, is linked rather than
        /// fetched again; anything else is fetched from `server` by commit and kept only if
        /// its SHA-256 matches. `refs/main` is not written here — only once every file is in
        /// place, by the caller.
        public func fetchCommands(
            hub: URL, server: URL = URL(string: "https://huggingface.co")!,
            protocols: String = "=https"
        ) -> [Command] {
            let repository = cacheDirectory(hub: hub)
            let snapshot = snapshot(hub: hub)
            return files.map { file in
                let depth = file.path.split(separator: "/").count + 1  // + snapshots/<revision>
                let target = String(repeating: "../", count: depth) + "blobs/\(file.sha256)"
                let url = server.appendingPathComponent(self.repository)
                    .appendingPathComponent("resolve/\(revision)")
                    .appendingPathComponent(file.path)
                return Command(
                    label: "Checking \((file.path as NSString).lastPathComponent)",
                    executable: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", fetchHubFileScript, "fetch-hub-file",
                                repository.appendingPathComponent("blobs/\(file.sha256)").path,
                                snapshot.appendingPathComponent(file.path).path,
                                target, url.absoluteString, file.sha256, protocols]
                )
            }
        }
    }

    static let fetchHubFileScript = #"""
        set -eu
        blob="$1"; dest="$2"; target="$3"; url="$4"; want="$5"; protocols="$6"
        digest() { /usr/bin/shasum -a 256 "$1" | /usr/bin/cut -d ' ' -f 1; }
        if [ -f "$dest" ] && [ "$(digest "$dest")" = "$want" ]; then exit 0; fi
        /bin/mkdir -p "$(/usr/bin/dirname "$blob")" "$(/usr/bin/dirname "$dest")"
        if ! { [ -f "$blob" ] && [ "$(digest "$blob")" = "$want" ]; }; then
            echo "Downloading $(/usr/bin/basename "$dest")"
            part="$blob.part"
            # Made first, so an empty file (an empty __init__.py) is one curl need not write.
            : > "$part"
            /usr/bin/curl --fail --location --silent --show-error --retry 3 \
                --proto "$protocols" --proto-redir "$protocols" --output "$part" "$url"
            got="$(digest "$part")"
            if [ "$got" != "$want" ]; then
                /bin/rm -f "$part"
                echo "$(/usr/bin/basename "$dest") did not match its reviewed SHA-256 (got $got); discarded."
                exit 1
            fi
            /bin/mv -f "$part" "$blob"
        fi
        /bin/rm -f "$dest"
        /bin/ln -s "$target" "$dest" 2>/dev/null || /bin/cp "$blob" "$dest"
        """#
}
