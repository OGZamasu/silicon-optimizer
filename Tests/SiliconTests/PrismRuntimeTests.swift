import CryptoKit
import Foundation
import Network
import Testing
@testable import SiliconCatalog
@testable import SiliconCore
@testable import SiliconPlanner
@testable import SiliconRuntime

/// PrismML's fork is fetched, not found: reviewed archive selection, the
/// download → digest verification → unpack → probe → swap sequence, and runtime selection.
@Suite("PrismML runtime")
struct PrismRuntimeTests {

    static let isArm64: Bool = {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }()

    @Test func usesOnlyReviewedPlatformArchives() {
        let arm = PrismRuntime.pinnedPick(suffix: "-bin-macos-arm64.tar.gz")
        #expect(arm.tag == "prism-b10685-7dffb15")
        #expect(arm.name == "llama-prism-b10685-7dffb15-bin-macos-arm64.tar.gz")
        #expect(arm.url.absoluteString
                == "https://github.com/PrismML-Eng/llama.cpp/releases/download/"
                + "prism-b10685-7dffb15/llama-prism-b10685-7dffb15-bin-macos-arm64.tar.gz")
        #expect(arm.sha256 == "7fffa7a40c74f3e9bd78f3f2f9f12f9befb7b13af45d5a69c239cf3fd37b9045")
        let x64 = PrismRuntime.pinnedPick(suffix: "-bin-macos-x64.tar.gz")
        #expect(x64.name == "llama-prism-b10685-7dffb15-bin-macos-x64.tar.gz")
        #expect(x64.sha256 == "b674befce466c4938e7e70a7b13009c7df2e76b072525495a78851c987a5121a")
    }

    /// The whole fetch against a loopback server standing in for GitHub: download the
    /// reviewed tarball, verify its digest, unpack, probe, swap, and find it again.
    @Test(.enabled(if: PrismRuntimeTests.isArm64))
    func installsFromAReleaseAndFindsItself() async throws {
        let server = try LoopbackServer()
        defer { server.stop() }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("prism-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        // A stand-in release: a script that answers --version and carries the ternary
        // type name the probe looks for, packed the way the fork ships it (one flat folder).
        let payload = scratch.appendingPathComponent("payload/llama-prism-test", isDirectory: true)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        let script = payload.appendingPathComponent("llama-server")
        try Data("""
            #!/bin/sh
            # types: q4_K tq1_0 pq2_0 ptq1_0
            echo 'version: 0.2.0-dev (build 1, commit abc)'

            """.utf8).write(to: script)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: script.path
        )
        let tarball = scratch.appendingPathComponent("llama-prism-test-bin-macos-arm64.tar.gz")
        try Self.run("/usr/bin/tar", [
            "-czf", tarball.path, "-C", payload.deletingLastPathComponent().path,
            "llama-prism-test",
        ])
        let archive = try Data(contentsOf: tarball)
        server.set("/download/llama-prism-test-bin-macos-arm64.tar.gz", archive,
                   contentType: "application/gzip")
        let pick = PrismRuntime.Pick(
            tag: "prism-test", name: "llama-prism-test-bin-macos-arm64.tar.gz",
            url: URL(string: "http://127.0.0.1:\(server.port)/download/llama-prism-test-bin-macos-arm64.tar.gz")!,
            size: Int64(archive.count), sha256: Self.sha256(archive)
        )

        let root = scratch.appendingPathComponent("root", isDirectory: true)
        let stages = StageLog()
        let installation = try await PrismRuntime.install(
            root: root, pick: pick
        ) { stages.add($0.stage) }

        #expect(installation.kind == .llamaCppPrism)
        #expect(installation.hasPrismTernary)
        #expect(installation.version == "prism-test")
        #expect(installation.source == .managed)
        #expect(installation.executable.path.hasSuffix("root/bin/llama-server"))
        #expect(stages.all.contains { $0.contains("Downloading prism-test") })
        #expect(stages.all.contains { $0.contains("Verifying prism-test archive") })
        #expect(stages.all.contains { $0.contains("Checking") })

        // Found again on the next launch, without the network.
        #expect(PrismRuntime.managedInstallation(root: root, expected: pick)?.executable
                == installation.executable)
        // A stock build in the same place would not count.
        try Data("#!/bin/sh\necho 'version: 1 (abc)' # tq1_0 only\n".utf8).write(to: root.appendingPathComponent("bin/llama-server"))
        #expect(PrismRuntime.managedInstallation(root: root, expected: pick) == nil)
        // And nothing is left after removal.
        try PrismRuntime.remove(root: root)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func refusesChangedArchiveBeforeUnpackingOrLaunching() async throws {
        let server = try LoopbackServer()
        defer { server.stop() }
        let actual = Data("unreviewed archive".utf8)
        server.set("/tampered.tar.gz", actual, contentType: "application/gzip")
        let pick = PrismRuntime.Pick(
            tag: "prism-test", name: "tampered.tar.gz",
            url: URL(string: "http://127.0.0.1:\(server.port)/tampered.tar.gz")!,
            size: Int64(actual.count), sha256: Self.sha256(Data("reviewed archive".utf8))
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("prism-reject-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: PrismRuntime.InstallError.self) {
            try await PrismRuntime.install(root: root, pick: pick) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func refusesLegacyManagedCopyBeforeProbingIt() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("prism-legacy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let marker = root.appendingPathComponent("probe-ran")
        let script = bin.appendingPathComponent("llama-server")
        try Data("#!/bin/sh\n# ptq1_0\ntouch '\(marker.path)'\necho 'version: old'\n".utf8)
            .write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let pick = PrismRuntime.pinnedPick()
        try Data("""
            {"tag":"\(pick.tag)","asset":"\(pick.name)","installedAt":0}
            """.utf8).write(to: root.appendingPathComponent("prism.json"))

        #expect(PrismRuntime.managedInstallation(root: root) == nil)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    /// Against the real pinned GitHub release: the digest matches, the tarball unpacks
    /// flat, the binary launches, and the ternary types are in it.
    ///
    ///     SILICON_NETWORK_TESTS=1 swift test --filter fetchesTheRealForkFromGitHub
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SILICON_NETWORK_TESTS"] == "1"))
    func fetchesTheRealForkFromGitHub() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("prism-real-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let stages = StageLog()
        let installation = try await PrismRuntime.install(root: root) { stages.add($0.stage) }
        #expect(installation.hasPrismTernary)
        #expect(installation.version?.hasPrefix("prism-b") == true, "\(installation.version ?? "nil")")
        let banner = RuntimeLocator.run(installation.executable, arguments: ["--version"]) ?? ""
        #expect(banner.contains("build"), "\(banner)")
        print("fetched \(installation.version ?? "?") → \(banner.split(separator: "\n").first ?? "")")
        print("stages: \(stages.all)")
    }

    @Test func selectorPrefersTheForkForTernaryModels() throws {
        let stock = RuntimeInstallation(
            kind: .llamaCpp, executable: URL(fileURLWithPath: "/opt/homebrew/bin/llama-server"),
            version: "b1", hasExpertStreaming: true, source: .homebrew
        )
        let fork = RuntimeInstallation(
            kind: .llamaCppPrism, executable: URL(fileURLWithPath: "/tmp/prism/bin/llama-server"),
            version: "prism-test", hasExpertStreaming: false, hasPrismTernary: true,
            source: .managed
        )
        let bonsai = InstalledModel(
            id: "bonsai", name: "Bonsai 2 27B", catalogID: "bonsai-2-27b",
            quantization: .ptq1_0, format: .gguf,
            primaryFile: URL(fileURLWithPath: "/models/Ternary-Bonsai-2-27B-PTQ1_0.gguf"),
            allFiles: [URL(fileURLWithPath: "/models/Ternary-Bonsai-2-27B-PTQ1_0.gguf")],
            projectorFile: nil, sizeOnDisk: .gib(5.5), installedAt: Date(),
            shape: ModelCatalog.bonsai2_27B.shape, capabilities: []
        )
        let qwen = InstalledModel(
            id: "qwen", name: "Qwen3 8B", catalogID: "qwen3-8b", quantization: .q4_K_M,
            format: .gguf, primaryFile: URL(fileURLWithPath: "/models/q.gguf"),
            allFiles: [URL(fileURLWithPath: "/models/q.gguf")], projectorFile: nil,
            sizeOnDisk: .gib(5), installedAt: Date(), shape: ModelCatalog.qwen3_8B.shape,
            capabilities: []
        )

        let both = RuntimeSelector(available: [.llamaCpp: stock, .llamaCppPrism: fork])
        let selection = try both.select(model: bonsai, configuration: LoadConfiguration())
        #expect(selection.kind == .llamaCppPrism)
        #expect(selection.installation.executable == fork.executable)
        // Ordinary GGUFs never go to the fork.
        let ordinary = try both.select(model: qwen, configuration: LoadConfiguration())
        #expect(ordinary.kind == .llamaCpp)
        #expect(ordinary.installation.executable == stock.executable)
        // The fork alone still serves a ternary model — no main build required for it.
        let onlyFork = RuntimeSelector(available: [.llamaCppPrism: fork])
        #expect(try onlyFork.select(model: bonsai, configuration: LoadConfiguration()).kind
                == .llamaCppPrism)
        #expect(throws: RuntimeError.self) {
            try onlyFork.select(model: qwen, configuration: LoadConfiguration())
        }
        // Discovery constructs a llama.cpp runtime for the fork, not a third engine.
        #expect(both.makeRuntime(for: selection) is LlamaCppRuntime)
    }

    // MARK: - Fixtures

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private final class StageLog: @unchecked Sendable {
        private let lock = NSLock()
        private var stages: [String] = []
        func add(_ stage: String) { lock.lock(); stages.append(stage); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return stages }
    }

    private static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "\(executable) \(arguments) failed")
    }

    /// Serves GET over loopback from an in-memory table, one response per connection —
    /// enough to stand in for both the releases API and the tarball download.
    private final class LoopbackServer: @unchecked Sendable {
        private let listener: NWListener
        private let lock = NSLock()
        private var files: [String: (Data, String)] = [:]
        private(set) var port: UInt16 = 0

        init() throws {
            let parameters = NWParameters.tcp
            parameters.requiredInterfaceType = .loopback
            listener = try NWListener(using: parameters, on: .any)
            let ready = DispatchSemaphore(value: 0)
            listener.stateUpdateHandler = { state in
                if case .ready = state { ready.signal() }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.serve(connection)
            }
            listener.start(queue: DispatchQueue(label: "loopback-server"))
            ready.wait()
            port = listener.port?.rawValue ?? 0
        }

        func stop() { listener.cancel() }

        func set(_ path: String, _ data: Data, contentType: String) {
            lock.lock(); files[path] = (data, contentType); lock.unlock()
        }

        private func serve(_ connection: NWConnection) {
            connection.start(queue: DispatchQueue(label: "loopback-conn"))
            var head = Data()
            func readMore() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
                    [weak self] data, _, _, error in
                    guard let self, error == nil, let data else { connection.cancel(); return }
                    head.append(data)
                    if let end = head.range(of: Data("\r\n\r\n".utf8)) {
                        self.respond(connection, head: head.subdata(in: 0..<end.lowerBound))
                    } else {
                        readMore()
                    }
                }
            }
            readMore()
        }

        private func respond(_ connection: NWConnection, head: Data) {
            let request = String(decoding: head, as: UTF8.self)
            let path = request.split(separator: "\r\n").first?
                .split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            lock.lock()
            let hit = files[path]
            lock.unlock()
            var response: Data
            if let (body, type) = hit {
                response = Data("HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
                response.append(body)
            } else {
                response = Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
            }
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}
