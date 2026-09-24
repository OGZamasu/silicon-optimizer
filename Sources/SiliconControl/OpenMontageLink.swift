import Foundation

/// Sets up OpenMontage — the open-source agentic video studio — and links it to this app.
///
/// OpenMontage has no orchestrator of its own: a coding agent reads its skills and drives
/// its tools. This app ships four such agents, and every one of them can reach this app's
/// images, video and meshes. So "linking" means three things: get OpenMontage onto this
/// Mac the way its own `make setup` would, drop this app in as a provider so its tools
/// appear in OpenMontage's catalogue at a cost of $0, and point an agent at the checkout.
///
/// Like `AgentBridge`, this half is pure: it inspects and plans, and returns steps for the
/// app to run. Nothing here launches a process, so all of it is testable in a throwaway
/// home directory.
public enum OpenMontageLink {

    public static var repository: String { PinnedInstall.openMontage.repository }

    /// Written into the checkout root when the provider is installed, holding the version
    /// of the provider that was copied. Comparing it with the bundle's copy is how "your
    /// provider is behind the app" gets noticed.
    public static let markerName = ".silicon-optimizer-provider"

    /// Written into the checkout by Set up before anything else and removed by its last step.
    /// A setup that stopped partway — a fetch that failed after `git init` left an empty
    /// repository, or a dependency install that failed after the checkout — otherwise looked
    /// exactly like someone's own clone: only Link was offered, and linking marked a folder
    /// with no source or environment in it "Linked".
    public static let setupMarkerName = ".silicon-optimizer-setup"

    /// The files that make up the provider, relative to both the bundle's source directory
    /// and the checkout. The tests directory is deliberately not among them.
    static let providerPaths = ["tools/silicon", "skills/core/silicon-optimizer.md"]

    // MARK: - Environment

    /// Where things live on *this* run. Injectable so tests never touch a real home.
    public struct Environment: Sendable {
        public var home: URL
        /// The bundle's `Resources/openmontage`, or nil for a bare `swift run` with no bundle.
        public var providerSource: URL?
        /// npm, if one was found — beside a Node this app trusts, or in the usual places.
        /// Nil means the Remotion step is skipped with a note, never attempted with
        /// whatever npm happens to be on PATH.
        public var npm: URL?
        /// Every Python interpreter found on this Mac, in no particular order.
        public var pythons: [URL]
        public var git: URL?
        /// The reviewed dependency locks (`PinnedInstall.defaultLockRoot()` in the app).
        public var locks: URL

        public init(
            home: URL, providerSource: URL?, npm: URL? = nil,
            pythons: [URL] = [], git: URL? = nil,
            locks: URL = PinnedInstall.defaultLockRoot()
        ) {
            self.home = home
            self.providerSource = providerSource
            self.npm = npm
            self.pythons = pythons
            self.git = git
            self.locks = locks
        }
    }

    // MARK: - Status

    public enum Status: Equatable, Sendable {
        /// No checkout on this Mac.
        case notInstalled
        /// Checkout, dependencies, and a provider that matches the bundle's.
        case ready(providerVersion: String)
        /// The provider in the checkout is older than the one this build carries.
        case providerOutdated(installed: String, available: String)
        /// Someone cloned OpenMontage themselves; only the provider is missing.
        case checkoutWithoutProvider
        /// Nothing can be done from here; the text says why.
        case unavailable(String)
    }

    /// `~/OpenMontage`. Visible on purpose — the user will `cd` here and run an agent in it,
    /// and a checkout buried in Application Support is a checkout nobody finds.
    public static func checkoutURL(in env: Environment) -> URL {
        env.home.appendingPathComponent("OpenMontage", isDirectory: true)
    }

    public static func detect(in env: Environment) -> Status {
        guard let source = env.providerSource,
              let available = providerVersion(at: source.appendingPathComponent("VERSION"))
        else {
            return .unavailable(
                "This build has no OpenMontage provider in it. Builds made with "
                + "Scripts/build-app.sh include it."
            )
        }
        guard env.git != nil else {
            return .unavailable(
                "git wasn't found. Install the Xcode command line tools "
                + "(xcode-select --install) and this button appears."
            )
        }

        let checkout = checkoutURL(in: env)
        // An unfinished setup is offered Set up again, which picks up where it stopped.
        guard FileManager.default.fileExists(atPath: checkout.appendingPathComponent(".git").path),
              !isUnfinishedSetup(checkout)
        else { return .notInstalled }

        guard let installed = providerVersion(at: checkout.appendingPathComponent(markerName))
        else { return .checkoutWithoutProvider }

        return installed == available
            ? .ready(providerVersion: installed)
            : .providerOutdated(installed: installed, available: available)
    }

    /// Whether `checkout` is a setup of this app's that did not finish: its marker is there, or
    /// nothing is but a repository — what a failed fetch left before the marker existed.
    static func isUnfinishedSetup(_ checkout: URL) -> Bool {
        let files = FileManager.default
        if files.fileExists(atPath: checkout.appendingPathComponent(setupMarkerName).path) {
            return true
        }
        guard files.fileExists(atPath: checkout.appendingPathComponent(".git").path),
              let contents = try? files.contentsOfDirectory(atPath: checkout.path)
        else { return false }
        return contents.allSatisfy { $0 == ".git" || $0 == ".DS_Store" }
    }

    static func providerVersion(at url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Tool discovery

    /// Prefers the interpreter most likely to have wheels for everything OpenMontage pulls
    /// in. torch and diffusers lag new Python releases by months, so the newest interpreter
    /// is the *worst* choice, and a bare `python3` may be anything.
    public static func pickPython(from candidates: [URL]) -> URL? {
        let preference = ["python3.12", "python3.11", "python3.13", "python3.10", "python3"]
        for wanted in preference {
            if let match = candidates.first(where: { $0.lastPathComponent == wanted }) {
                return match
            }
        }
        return candidates.first
    }

    // MARK: - The plan

    /// One command the app should run, in order. `optional` steps may fail without
    /// stopping the setup — Remotion and Piper are OpenMontage's own "[skip]" cases.
    public struct Step: Equatable, Sendable {
        public var label: String
        public var executable: URL
        public var arguments: [String]
        public var workingDirectory: URL
        public var optional: Bool

        public init(
            label: String, executable: URL, arguments: [String],
            workingDirectory: URL, optional: Bool = false
        ) {
            self.label = label
            self.executable = executable
            self.arguments = arguments
            self.workingDirectory = workingDirectory
            self.optional = optional
        }
    }

    public enum LinkError: LocalizedError {
        case noGit
        case noPython
        case noProviderInBuild
        case checkoutInTheWay

        public var errorDescription: String? {
            switch self {
            case .noGit:
                "git wasn't found. Install the Xcode command line tools (xcode-select --install)."
            case .noPython:
                "No Python 3 was found. Install one with `brew install python@3.12`."
            case .noProviderInBuild:
                "This build has no OpenMontage provider in it."
            case .checkoutInTheWay:
                "~/OpenMontage already exists and is not a Git checkout. Move it aside and "
                    + "run Set up again."
            }
        }
    }

    /// Setup steps the app runs itself — with the Python picked for wheel coverage rather
    /// than recency, and npm from beside a Node this app trusts. The source is the reviewed
    /// commit in `PinnedInstall.openMontage`, checked before anything in it is used, and the
    /// Python packages are the hash-locked set for that commit and that Python. An existing
    /// checkout's Git revision and Remotion dependencies are not updated by this plan: it is
    /// checked against the reviewed commit, and setup stops if it is anything else. A setup
    /// of this app's that stopped partway is not an existing checkout: it is set up again,
    /// marked as unfinished from the first step until the last.
    public static func plan(in env: Environment) throws -> (steps: [Step], notes: [String]) {
        guard let git = env.git else { throw LinkError.noGit }

        let checkout = checkoutURL(in: env)
        let venv = checkout.appendingPathComponent(".venv", isDirectory: true)
        let venvPython = venv.appendingPathComponent("bin/python")
        let source = PinnedInstall.openMontage
        var steps: [Step] = []
        var notes: [String] = []
        let unfinishedSetup = isUnfinishedSetup(checkout)
        let existingCheckout = !unfinishedSetup && FileManager.default.fileExists(
            atPath: checkout.appendingPathComponent(".git").path)
        let existingVenv = FileManager.default.isExecutableFile(atPath: venvPython.path)
        // A clone would have refused a folder that is already there; fetching into it would
        // not, and must not write over someone's files. What an unfinished setup left is this
        // app's own.
        if !existingCheckout, !unfinishedSetup,
           let contents = try? FileManager.default.contentsOfDirectory(atPath: checkout.path),
           !contents.isEmpty {
            throw LinkError.checkoutInTheWay
        }

        // The locks are per Python version, so the version must be known before anything
        // runs: the environment's own when there is one, otherwise the chosen interpreter's.
        let interpreter = pickPython(from: env.pythons)
        if !existingVenv && interpreter == nil { throw LinkError.noPython }
        let version = existingVenv
            ? PinnedInstall.pythonVersion(ofVirtualEnvironment: venv)
            : interpreter.flatMap(PinnedInstall.pythonVersion(ofInterpreter:))
        guard let version, PinnedInstall.openMontagePythons.contains(version) else {
            throw PinnedInstall.PlanError.unsupportedPython(
                tool: source.name, found: version, supported: PinnedInstall.openMontagePythons
            )
        }

        let setupMarker = checkout.appendingPathComponent(setupMarkerName)
        if !existingCheckout {
            let label = "Preparing ~/OpenMontage"
            steps.append(Step(
                label: label, executable: URL(fileURLWithPath: "/bin/mkdir"),
                arguments: ["-p", checkout.path], workingDirectory: env.home
            ))
            steps.append(Step(
                label: label, executable: URL(fileURLWithPath: "/usr/bin/touch"),
                arguments: [setupMarker.path], workingDirectory: env.home
            ))
        }

        let pinned = existingCheckout
            ? [PinnedInstall.verify(source, in: checkout, git: git)]
            : PinnedInstall.fetch(source, into: checkout, git: git)
        steps += pinned.map {
            Step(label: $0.label, executable: $0.executable, arguments: $0.arguments,
                 workingDirectory: $0.workingDirectory ?? env.home)
        }

        if !existingVenv, let interpreter {
            steps.append(Step(
                label: "Creating a Python environment (\(interpreter.lastPathComponent))",
                executable: interpreter, arguments: ["-m", "venv", ".venv"],
                workingDirectory: checkout
            ))
        }

        // Wheels only: every package has one for Apple Silicon at these versions, and a
        // source build would fetch unpinned build tools.
        let dependencies = PinnedInstall.pipInstall(
            python: venvPython,
            lock: PinnedInstall.lock("requirements", for: source, python: version, in: env.locks),
            label: "Installing Python dependencies — a few minutes the first time",
            onlyBinary: true
        )
        steps.append(Step(
            label: dependencies.label, executable: dependencies.executable,
            arguments: dependencies.arguments, workingDirectory: checkout
        ))

        let piper = PinnedInstall.pipInstall(
            python: venvPython,
            lock: PinnedInstall.lock("piper", for: source, python: version, in: env.locks),
            label: "Installing Piper, the free offline voice",
            onlyBinary: true
        )
        steps.append(Step(
            label: piper.label, executable: piper.executable,
            arguments: piper.arguments, workingDirectory: checkout, optional: true
        ))

        if existingCheckout {
            // `npm ci` removes node_modules, so leave a user-managed checkout's Remotion
            // dependencies alone. The settings UI only offers setup before the clone.
            notes.append("Existing Remotion dependencies were left unchanged in ~/OpenMontage.")
        } else if let npm = env.npm {
            // `npm ci` installs exactly the reviewed commit's package-lock.json, whose
            // integrity hashes npm checks for every package.
            steps.append(Step(
                label: "Installing Remotion, the composition engine",
                executable: npm, arguments: ["ci", "--silent", "--no-audit", "--no-fund"],
                workingDirectory: checkout.appendingPathComponent("remotion-composer"),
                optional: true
            ))
        } else {
            notes.append(
                "npm wasn't found, so Remotion was skipped — OpenMontage falls back to FFmpeg. "
                + "Install Node from nodejs.org, then run `npm ci` in "
                + "~/OpenMontage/remotion-composer to add it."
            )
        }

        if !existingCheckout {
            // Reached only when every step that is not optional succeeded.
            steps.append(Step(
                label: "Finishing the setup", executable: URL(fileURLWithPath: "/bin/rm"),
                arguments: ["-f", setupMarker.path], workingDirectory: env.home
            ))
        }

        return (steps, notes)
    }

    // MARK: - The provider

    /// Copies this build's provider into the checkout, refreshes the marker, and gives
    /// OpenMontage an `.env` if it has none. File operations only; the checkout must exist.
    public static func installProvider(in env: Environment) throws {
        guard let source = env.providerSource,
              let version = providerVersion(at: source.appendingPathComponent("VERSION"))
        else { throw LinkError.noProviderInBuild }

        let files = FileManager.default
        let checkout = checkoutURL(in: env)

        for relative in providerPaths {
            let from = source.appendingPathComponent(relative)
            let to = checkout.appendingPathComponent(relative)
            try files.createDirectory(
                at: to.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            // Replace, never merge: a file we removed from the provider must not linger.
            if files.fileExists(atPath: to.path) { try files.removeItem(at: to) }
            try files.copyItem(at: from, to: to)
        }

        // OpenMontage reads keys from .env and its setup copies the example in; without one
        // its provider preflight complains about a missing file rather than missing keys.
        let dotenv = checkout.appendingPathComponent(".env")
        let example = checkout.appendingPathComponent(".env.example")
        if !files.fileExists(atPath: dotenv.path), files.fileExists(atPath: example.path) {
            try files.copyItem(at: example, to: dotenv)
        }

        try version.write(
            to: checkout.appendingPathComponent(markerName), atomically: true, encoding: .utf8
        )
    }
}
