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

    @Test("a fresh Mac clones, makes a venv, installs, and skips Remotion when there is no npm")
    func planFresh() throws {
        var env = try makeEnvironment()
        defer { cleanUp(env) }
        env.pythons = [URL(fileURLWithPath: "/opt/homebrew/bin/python3.12")]

        let (steps, notes) = try OpenMontageLink.plan(in: env)
        #expect(steps.first?.arguments.first == "clone")
        #expect(steps.first?.optional == false, "no checkout is a hard failure, not a skip")
        #expect(steps.contains { $0.arguments == ["-m", "venv", ".venv"] })
        #expect(steps.contains { $0.arguments.contains("requirements.txt") && !$0.optional })
        #expect(steps.contains { $0.arguments.contains("piper-tts") && $0.optional })
        #expect(!steps.contains { $0.executable.lastPathComponent == "npm" })
        #expect(notes.contains { $0.contains("Remotion") }, "a skipped step is said, not silent")
        #expect(notes.contains { $0.contains("npm ci") })
        #expect(!notes.contains { $0.contains("Set up again") })

        // With an npm, Remotion is a step — optional, in its own directory.
        env.npm = URL(fileURLWithPath: "/usr/local/bin/npm")
        let (withNpm, quiet) = try OpenMontageLink.plan(in: env)
        let remotion = withNpm.first { $0.executable.lastPathComponent == "npm" }
        #expect(remotion?.optional == true)
        #expect(remotion?.arguments == ["ci", "--silent", "--no-audit", "--no-fund"])
        #expect(remotion?.workingDirectory.lastPathComponent == "remotion-composer")
        #expect(quiet.isEmpty)
    }

    @Test("an existing checkout is not pulled or cloned during setup")
    func planExisting() throws {
        var env = try makeEnvironment()
        defer { cleanUp(env) }
        env.pythons = [URL(fileURLWithPath: "/usr/bin/python3")]
        env.npm = URL(fileURLWithPath: "/usr/local/bin/npm")
        let checkout = try makeCheckout(in: env)
        // A venv already there is not made again.
        try FileManager.default.createDirectory(
            at: checkout.appendingPathComponent(".venv/bin"), withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: checkout.appendingPathComponent(".venv/bin/python").path, contents: Data(),
            attributes: [.posixPermissions: 0o755])

        let (steps, notes) = try OpenMontageLink.plan(in: env)
        #expect(!steps.contains { $0.executable == env.git })
        #expect(!steps.contains { $0.executable == env.npm }, "npm ci would replace user-managed node_modules")
        #expect(!steps.contains { $0.arguments == ["-m", "venv", ".venv"] })
        #expect(steps.contains { $0.arguments.contains("requirements.txt") })
        #expect(notes.contains { $0.contains("Remotion dependencies were left unchanged") })
    }

    @Test("no Python at all is an error the button can show, not a crash mid-install")
    func planNoPython() throws {
        let env = try makeEnvironment()
        defer { cleanUp(env) }
        #expect(throws: OpenMontageLink.LinkError.self) { try OpenMontageLink.plan(in: env) }
    }
}
