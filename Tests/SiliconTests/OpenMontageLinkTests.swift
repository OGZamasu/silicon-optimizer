import Foundation
import Testing
@testable import SiliconControl

/// The Set up button downloads a repository and installs a Python environment into the
/// user's home. These pin the parts that decide *what* it does before it does anything:
/// how the state of a checkout is read, which interpreter is chosen, what steps are
/// planned, and that linking touches only the provider's own files.
@Suite("OpenMontage link")
struct OpenMontageLinkTests {

    /// A throwaway home, and a fake bundle directory holding a provider at some version.
    private func makeEnvironment(providerVersion: String? = "1") throws -> OpenMontageLink.Environment {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openmontage-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        var source: URL?
        if let providerVersion {
            let bundle = root.appendingPathComponent("bundle/openmontage", isDirectory: true)
            try FileManager.default.createDirectory(
                at: bundle.appendingPathComponent("tools/silicon"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: bundle.appendingPathComponent("skills/core"), withIntermediateDirectories: true)
            try "print('hi')".write(
                to: bundle.appendingPathComponent("tools/silicon/silicon_image.py"),
                atomically: true, encoding: .utf8)
            try "# skill".write(
                to: bundle.appendingPathComponent("skills/core/silicon-optimizer.md"),
                atomically: true, encoding: .utf8)
            try "\(providerVersion)\n".write(
                to: bundle.appendingPathComponent("VERSION"), atomically: true, encoding: .utf8)
            source = bundle
        }

        return OpenMontageLink.Environment(
            home: home, providerSource: source,
            npm: nil, pythons: [], git: URL(fileURLWithPath: "/usr/bin/git"))
    }

    private func cleanUp(_ env: OpenMontageLink.Environment) {
        try? FileManager.default.removeItem(at: env.home.deletingLastPathComponent())
    }

    /// A checkout that looks cloned, without cloning anything.
    private func makeCheckout(in env: OpenMontageLink.Environment) throws -> URL {
        let checkout = OpenMontageLink.checkoutURL(in: env)
        try FileManager.default.createDirectory(
            at: checkout.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "FAL_KEY=\n".write(
            to: checkout.appendingPathComponent(".env.example"), atomically: true, encoding: .utf8)
        return checkout
    }

    // MARK: - Reading the state

    @Test("nothing on disk is not installed")
    func fresh() throws {
        let env = try makeEnvironment()
        defer { cleanUp(env) }
        #expect(OpenMontageLink.detect(in: env) == .notInstalled)
    }

    @Test("a build without the provider can do nothing, and says why")
    func noProvider() throws {
        let env = try makeEnvironment(providerVersion: nil)
        defer { cleanUp(env) }
        guard case .unavailable(let reason) = OpenMontageLink.detect(in: env) else {
            Issue.record("expected unavailable"); return
        }
        #expect(reason.contains("build-app.sh"))
    }

    @Test("linking installs the provider, an .env, and a marker — and then reads as ready")
    func link() throws {
        let env = try makeEnvironment()
        defer { cleanUp(env) }
        let checkout = try makeCheckout(in: env)

        #expect(OpenMontageLink.detect(in: env) == .checkoutWithoutProvider)
        try OpenMontageLink.installProvider(in: env)

        let files = FileManager.default
        #expect(files.fileExists(atPath: checkout.appendingPathComponent("tools/silicon/silicon_image.py").path))
        #expect(files.fileExists(atPath: checkout.appendingPathComponent("skills/core/silicon-optimizer.md").path))
        #expect(files.fileExists(atPath: checkout.appendingPathComponent(".env").path), "OpenMontage wants an .env; its example is the seed")
        #expect(OpenMontageLink.detect(in: env) == .ready(providerVersion: "1"))
    }

    @Test("an existing .env is never overwritten — it holds the user's keys")
    func envIsSacred() throws {
        let env = try makeEnvironment()
        defer { cleanUp(env) }
        let checkout = try makeCheckout(in: env)
        let dotenv = checkout.appendingPathComponent(".env")
        try "FAL_KEY=real-secret\n".write(to: dotenv, atomically: true, encoding: .utf8)

        try OpenMontageLink.installProvider(in: env)
        #expect(try String(contentsOf: dotenv, encoding: .utf8) == "FAL_KEY=real-secret\n")
    }

    @Test("a newer provider in the app reads as outdated in the checkout")
    func outdated() throws {
        let env = try makeEnvironment()
        defer { cleanUp(env) }
        _ = try makeCheckout(in: env)
        try OpenMontageLink.installProvider(in: env)

        try "2\n".write(
            to: env.providerSource!.appendingPathComponent("VERSION"), atomically: true, encoding: .utf8)
        #expect(OpenMontageLink.detect(in: env) == .providerOutdated(installed: "1", available: "2"))

        // Relinking replaces the old files rather than merging over them.
        try FileManager.default.removeItem(
            at: env.providerSource!.appendingPathComponent("tools/silicon/silicon_image.py"))
        try "x".write(
            to: env.providerSource!.appendingPathComponent("tools/silicon/silicon_video.py"),
            atomically: true, encoding: .utf8)
        try OpenMontageLink.installProvider(in: env)
        let tools = OpenMontageLink.checkoutURL(in: env).appendingPathComponent("tools/silicon")
        #expect(!FileManager.default.fileExists(atPath: tools.appendingPathComponent("silicon_image.py").path),
                "a file dropped from the provider must not linger in the checkout")
        #expect(FileManager.default.fileExists(atPath: tools.appendingPathComponent("silicon_video.py").path))
        #expect(OpenMontageLink.detect(in: env) == .ready(providerVersion: "2"))
    }

    // MARK: - Choosing tools

    @Test("the Python with the best wheel coverage wins, whatever the order")
    func python() {
        let urls = { (names: [String]) in names.map { URL(fileURLWithPath: "/opt/homebrew/bin/\($0)") } }
        // 3.14 is newest and worst: torch wheels are not there yet.
        #expect(OpenMontageLink.pickPython(from: urls(["python3", "python3.13", "python3.12"]))?.lastPathComponent == "python3.12")
        #expect(OpenMontageLink.pickPython(from: urls(["python3.13", "python3.11"]))?.lastPathComponent == "python3.11")
        #expect(OpenMontageLink.pickPython(from: urls(["python3"]))?.lastPathComponent == "python3")
        #expect(OpenMontageLink.pickPython(from: []) == nil)
    }

    // MARK: - The plan

    @Test("a fresh Mac fetches the reviewed commit, checks it, and installs only locked packages")
    func planFresh() throws {
        var env = try makeEnvironment()
        defer { cleanUp(env) }
        env.pythons = [URL(fileURLWithPath: "/opt/homebrew/bin/python3.12")]
        let checkout = OpenMontageLink.checkoutURL(in: env)
        let commit = PinnedInstall.openMontage.commit

        let (steps, notes) = try OpenMontageLink.plan(in: env)
        // Marked unfinished before anything lands in the folder, and done only at the end.
        let marker = checkout.appendingPathComponent(OpenMontageLink.setupMarkerName).path
        #expect(steps.prefix(2).map(\.arguments) == [["-p", checkout.path], [marker]])
        #expect(steps.last?.arguments == ["-f", marker])
        #expect(steps.last?.optional == false)
        // The pinned commit, by id — never a branch, never a pull.
        #expect(steps.dropFirst(2).first?.arguments == ["init", "--quiet", checkout.path])
        #expect(steps.contains { $0.arguments.contains("fetch") && $0.arguments.last == commit })
        #expect(!steps.contains { $0.arguments.contains("clone") || $0.arguments.contains("pull") })
        // Checked before anything in it runs: the check comes before the first Python step.
        let check = try #require(steps.firstIndex { $0.label.hasPrefix("Checking OpenMontage") })
        let venv = try #require(steps.firstIndex { $0.arguments == ["-m", "venv", ".venv"] })
        #expect(steps[check].arguments.suffix(3) == [checkout.path, commit, "OpenMontage"])
        #expect(check < venv)
        #expect(steps[..<venv].allSatisfy { !$0.optional }, "a missing or wrong checkout is fatal")

        // Python packages come from the app's hash lock for this Python, wheels only; the
        // checkout's own requirements.txt is never handed to pip.
        let pip = steps.filter { $0.arguments.starts(with: ["-m", "pip", "install"]) }
        #expect(pip.count == 2)
        for step in pip {
            #expect(step.arguments.contains("--require-hashes"))
            #expect(step.arguments.contains("--only-binary"))
            #expect(!step.arguments.contains("requirements.txt"))
            let lock = try #require(step.arguments.last)
            #expect(lock.hasPrefix(env.locks.path))
            #expect(lock.hasSuffix("-py3.12.txt"))
            #expect(FileManager.default.fileExists(atPath: lock), "\(lock) must ship with the app")
        }
        #expect(pip[0].optional == false)
        #expect(pip[1].optional == true && pip[1].arguments.last!.hasSuffix("piper-py3.12.txt"))

        #expect(!steps.contains { $0.executable.lastPathComponent == "npm" })
        #expect(notes.contains { $0.contains("Remotion") }, "a skipped step is said, not silent")
        #expect(notes.contains { $0.contains("npm ci") })
        #expect(!notes.contains { $0.contains("Set up again") })

        // With an npm, Remotion is a step — optional, in its own directory, from the
        // reviewed commit's lockfile.
        env.npm = URL(fileURLWithPath: "/usr/local/bin/npm")
        let (withNpm, quiet) = try OpenMontageLink.plan(in: env)
        let remotion = withNpm.first { $0.executable.lastPathComponent == "npm" }
        #expect(remotion?.optional == true)
        #expect(remotion?.arguments == ["ci", "--silent", "--no-audit", "--no-fund"])
        #expect(remotion?.workingDirectory.lastPathComponent == "remotion-composer")
        #expect(quiet.isEmpty)
    }

    @Test("an existing checkout is checked against the reviewed commit, not pulled or cloned")
    func planExisting() throws {
        var env = try makeEnvironment()
        defer { cleanUp(env) }
        env.pythons = [URL(fileURLWithPath: "/usr/bin/python3")]
        env.npm = URL(fileURLWithPath: "/usr/local/bin/npm")
        let checkout = try makeCheckout(in: env)
        // A venv already there is not made again, and its own version picks the lock.
        try FileManager.default.createDirectory(
            at: checkout.appendingPathComponent(".venv/bin"), withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: checkout.appendingPathComponent(".venv/bin/python").path, contents: Data(),
            attributes: [.posixPermissions: 0o755])
        try "home = /opt/homebrew/bin\nversion = 3.11.9\n".write(
            to: checkout.appendingPathComponent(".venv/pyvenv.cfg"), atomically: true, encoding: .utf8)

        let (steps, notes) = try OpenMontageLink.plan(in: env)
        #expect(!steps.contains { $0.executable == env.git }, "never fetched or pulled")
        #expect(steps.first?.label.hasPrefix("Checking OpenMontage") == true,
                "checked before anything runs from the checkout")
        #expect(steps.first?.arguments.contains(env.git!.path) == true)
        #expect(!steps.contains { $0.executable == env.npm }, "npm ci would replace user-managed node_modules")
        #expect(!steps.contains { $0.arguments == ["-m", "venv", ".venv"] })
        #expect(steps.contains { $0.arguments.last?.hasSuffix("requirements-py3.11.txt") == true })
        #expect(notes.contains { $0.contains("Remotion dependencies were left unchanged") })
    }

    /// What a fetch that failed after `git init` leaves: a repository with no commit in it.
    /// It must not read as someone's own clone — only Link would be offered, and linking marks
    /// a folder with nothing in it "Linked" — and Set up must fetch into it, not stop at a
    /// check of a revision it never got.
    @Test("a failed fetch leaves a setup to finish, not an empty checkout to link")
    func failedFetch() throws {
        var env = try makeEnvironment()
        defer { cleanUp(env) }
        env.pythons = [URL(fileURLWithPath: "/opt/homebrew/bin/python3.12")]
        env.npm = URL(fileURLWithPath: "/usr/local/bin/npm")
        let checkout = OpenMontageLink.checkoutURL(in: env)
        try FileManager.default.createDirectory(
            at: checkout.appendingPathComponent(".git/objects"), withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(
            to: checkout.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)

        #expect(OpenMontageLink.detect(in: env) == .notInstalled)

        let (steps, _) = try OpenMontageLink.plan(in: env)
        let commit = PinnedInstall.openMontage.commit
        #expect(steps.contains { $0.arguments.contains("fetch") && $0.arguments.last == commit })
        #expect(steps.contains { $0.arguments.contains("checkout") && $0.arguments.last == commit })
        #expect(steps.contains { $0.arguments == ["-m", "venv", ".venv"] })
        #expect(steps.contains { $0.executable == env.npm }, "Remotion is this setup's to install")
        #expect(steps.last?.arguments.last?.hasSuffix(OpenMontageLink.setupMarkerName) == true)
    }

    /// A setup that got the source but failed installing its dependencies is still this app's
    /// unfinished setup: Set up again, not Link.
    @Test("a setup that failed after the checkout is finished by Set up, not linked")
    func failedAfterCheckout() throws {
        var env = try makeEnvironment()
        defer { cleanUp(env) }
        env.pythons = [URL(fileURLWithPath: "/opt/homebrew/bin/python3.12")]
        let checkout = try makeCheckout(in: env)
        try Data().write(to: checkout.appendingPathComponent(OpenMontageLink.setupMarkerName))

        #expect(OpenMontageLink.detect(in: env) == .notInstalled)
        let (steps, _) = try OpenMontageLink.plan(in: env)
        #expect(steps.contains { $0.arguments.contains("fetch") },
                "a checkout this app made is brought to the reviewed commit, not only checked")
        #expect(steps.contains { $0.arguments == ["-m", "venv", ".venv"] })

        // What the last step and the provider do once everything else has succeeded.
        try FileManager.default.removeItem(
            at: checkout.appendingPathComponent(OpenMontageLink.setupMarkerName))
        try OpenMontageLink.installProvider(in: env)
        #expect(OpenMontageLink.detect(in: env) == .ready(providerVersion: "1"))
    }

    @Test("a Python the locks were not made for is refused before anything runs")
    func planUnlockedPython() throws {
        var env = try makeEnvironment()
        defer { cleanUp(env) }
        for names in [["python3"], ["python3.14"], ["python3.9"]] {
            env.pythons = names.map { URL(fileURLWithPath: "/opt/homebrew/bin/\($0)") }
            #expect(throws: PinnedInstall.PlanError.self) { try OpenMontageLink.plan(in: env) }
        }
    }

    @Test("a folder already at ~/OpenMontage that is not a checkout is never written over")
    func planFolderInTheWay() throws {
        var env = try makeEnvironment()
        defer { cleanUp(env) }
        env.pythons = [URL(fileURLWithPath: "/opt/homebrew/bin/python3.12")]
        let folder = OpenMontageLink.checkoutURL(in: env)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "mine".write(to: folder.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        #expect(throws: OpenMontageLink.LinkError.self) { try OpenMontageLink.plan(in: env) }
    }

    @Test("no Python at all is an error the button can show, not a crash mid-install")
    func planNoPython() throws {
        let env = try makeEnvironment()
        defer { cleanUp(env) }
        #expect(throws: OpenMontageLink.LinkError.self) { try OpenMontageLink.plan(in: env) }
    }
}
