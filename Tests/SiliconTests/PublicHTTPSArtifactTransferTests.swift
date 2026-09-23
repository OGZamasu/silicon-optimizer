import CArtifactHTTP
import CFNetwork
import Darwin
import Foundation
import Testing
@testable import SiliconRuntime

@Suite("Public HTTPS artifact transport", .serialized)
struct PublicHTTPSArtifactTransferTests {
    @Test func invalidTimeoutsFailBeforeNetworkOrFileCreation() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("silicon-timeout-preflight-\(UUID().uuidString)")
        let destination = directory.appendingPathComponent("audio.mp3")
        let url = URL(string: "https://cdn.example.com/audio.mp3")!
        for timeout in [Double.nan, .infinity, -1] {
            await #expect(throws: RemoteTransferError.self) {
                try await PublicHTTPSArtifactTransfer.download(
                    from: url, to: destination, maximumBytes: 256,
                    budget: RemoteByteBudget(limit: 256), timeout: timeout
                )
            }
        }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func configuredProxyFailsBeforeTransportIsCreated() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("silicon-proxy-preflight-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("audio.mp3")
        let counter = NetworkAttemptCounter()
        let url = URL(string: "https://cdn.example.com/audio.mp3")!
        let direct = [[kCFProxyTypeKey as String: kCFProxyTypeNone as String]]
        await #expect(throws: RemoteTransferError.self) {
            try await PublicHTTPSArtifactTransfer.download(
                from: url, to: destination, maximumBytes: 256,
                budget: RemoteByteBudget(limit: 256), timeout: 5,
                proxyCheck: { _ in
                    try PublicHTTPSArtifactTransfer.enforceDirect(
                        environment: ["HTTPS_PROXY": "http://proxy.example:8080"],
                        proxyEntries: direct, systemSettings: [:]
                    )
                },
                onNetworkAttempt: { counter.increment() }
            )
        }
        #expect(counter.value == 0)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect((try FileManager.default.contentsOfDirectory(atPath: directory.path)).isEmpty)
    }

    @Test func trustedHostnameTLSAndAudioBodySucceed() throws {
        let server = try FixtureTLSHTTPServer()
        let file = server.directory.appendingPathComponent("audio.partial")
        #expect(FileManager.default.createFile(atPath: file.path, contents: nil))
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }

        let job = try #require(server.job("/audio", fileDescriptor: handle.fileDescriptor))
        defer { silicon_artifact_job_destroy(job) }
        #expect(silicon_artifact_job_perform(job) == SILICON_ARTIFACT_SUCCESS)
        #expect(silicon_artifact_job_status(job) == 200)
        #expect(silicon_artifact_job_bytes(job) == 5)
        #expect(try Data(contentsOf: file) == Data("audio".utf8))
    }

    @Test func wrongTLSHostnameIsRejectedEvenWithTrustedCertificate() throws {
        let server = try FixtureTLSHTTPServer()
        let file = server.directory.appendingPathComponent("wrong-host.partial")
        #expect(FileManager.default.createFile(atPath: file.path, contents: nil))
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }

        let job = try #require(server.job(
            "/audio", hostname: "wrong.example.com", fileDescriptor: handle.fileDescriptor
        ))
        defer { silicon_artifact_job_destroy(job) }
        #expect(silicon_artifact_job_perform(job) == SILICON_ARTIFACT_NETWORK)
        #expect(silicon_artifact_job_bytes(job) == 0)
    }

    @Test func redirectBodyAndDisallowedContentTypeAreNotWritten() throws {
        let server = try FixtureTLSHTTPServer()
        let file = server.directory.appendingPathComponent("redirect.partial")
        #expect(FileManager.default.createFile(atPath: file.path, contents: nil))
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }

        let redirect = try #require(server.job("/redirect", fileDescriptor: handle.fileDescriptor))
        #expect(silicon_artifact_job_perform(redirect) == SILICON_ARTIFACT_REDIRECT)
        #expect(silicon_artifact_job_bytes(redirect) == 0)
        #expect(String(cString: silicon_artifact_job_location(redirect)) == "/audio")
        silicon_artifact_job_destroy(redirect)
        #expect(try Data(contentsOf: file).isEmpty)

        let badType = try #require(server.job("/bad-type", fileDescriptor: handle.fileDescriptor))
        defer { silicon_artifact_job_destroy(badType) }
        #expect(silicon_artifact_job_perform(badType) == SILICON_ARTIFACT_CONTENT_TYPE)
        #expect(silicon_artifact_job_bytes(badType) == 0)
        #expect(try Data(contentsOf: file).isEmpty)
    }

    @Test func redirectTargetIsRejectedBeforeTheNextRequest() throws {
        let server = try FixtureTLSHTTPServer()
        let file = server.directory.appendingPathComponent("private-redirect.partial")
        #expect(FileManager.default.createFile(atPath: file.path, contents: nil))
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }

        let job = try #require(server.job("/to-private", fileDescriptor: handle.fileDescriptor))
        defer { silicon_artifact_job_destroy(job) }
        #expect(silicon_artifact_job_perform(job) == SILICON_ARTIFACT_REDIRECT)
        #expect(silicon_artifact_job_bytes(job) == 0)
        let current = URL(string: "https://cdn.example.com:\(server.port)/to-private")!
        #expect(throws: RemoteTransferError.self) {
            try PublicHTTPSArtifactTransfer.redirectTarget(
                String(cString: silicon_artifact_job_location(job)), from: current, count: 0
            )
        }
        #expect(try Data(contentsOf: file).isEmpty)
    }

    @Test func sharedBudgetRejectsConcurrentArtifactBodiesBeforeWriting() throws {
        let server = try FixtureTLSHTTPServer()
        let budget = RemoteByteBudget(limit: 7)
        let first = server.directory.appendingPathComponent("budget-first.partial")
        let second = server.directory.appendingPathComponent("budget-second.partial")
        #expect(FileManager.default.createFile(atPath: first.path, contents: nil))
        #expect(FileManager.default.createFile(atPath: second.path, contents: nil))
        let firstHandle = try FileHandle(forWritingTo: first)
        let secondHandle = try FileHandle(forWritingTo: second)
        defer {
            try? firstHandle.close()
            try? secondHandle.close()
        }
        let firstJob = try #require(server.job(
            "/audio", fileDescriptor: firstHandle.fileDescriptor, budget: budget
        ))
        let secondJob = try #require(server.job(
            "/audio", fileDescriptor: secondHandle.fileDescriptor, budget: budget
        ))
        defer {
            silicon_artifact_job_destroy(firstJob)
            silicon_artifact_job_destroy(secondJob)
        }
        let queue = DispatchQueue(label: "artifact-budget-fixture", attributes: .concurrent)
        let group = DispatchGroup()
        group.enter()
        queue.async { _ = silicon_artifact_job_perform(firstJob); group.leave() }
        group.enter()
        queue.async { _ = silicon_artifact_job_perform(secondJob); group.leave() }
        #expect(group.wait(timeout: .now() + 10) == .success)

        let outcomes = [
            silicon_artifact_job_bytes(firstJob), silicon_artifact_job_bytes(secondJob),
        ].sorted()
        #expect(outcomes == [0, 5])
        #expect(budget.remaining == 2)
        #expect((try Data(contentsOf: first)).count + (try Data(contentsOf: second)).count == 5)
    }
}

private final class NetworkAttemptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

private final class FixtureTLSHTTPServer {
    let directory: URL
    let certificate: URL
    let port: UInt16
    private let process: Process

    init() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("silicon-artifact-tls-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        var initialized = false
        defer { if !initialized { try? FileManager.default.removeItem(at: temporaryDirectory) } }
        directory = temporaryDirectory
        certificate = directory.appendingPathComponent("cert.pem")
        let key = directory.appendingPathComponent("key.pem")

        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/openssl"),
              FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")
        else { throw RemoteTransferError.networkFailure }

        let openssl = Process()
        openssl.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        openssl.arguments = [
            "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key.path,
            "-out", certificate.path, "-days", "1", "-subj", "/CN=cdn.example.com",
            "-addext", "subjectAltName=DNS:cdn.example.com",
        ]
        openssl.standardOutput = Pipe()
        openssl.standardError = Pipe()
        try openssl.run()
        openssl.waitUntilExit()
        guard openssl.terminationStatus == 0 else { throw RemoteTransferError.networkFailure }

        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ArtifactTLSServer.py")
        process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", script.path, certificate.path, key.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        try process.run()

        var descriptor = pollfd(
            fd: output.fileHandleForReading.fileDescriptor,
            events: Int16(POLLIN), revents: 0
        )
        guard Darwin.poll(&descriptor, 1, 5_000) > 0 else {
            process.terminate()
            throw RemoteTransferError.networkFailure
        }
        let rawPort = output.fileHandleForReading.readData(ofLength: 6)
        guard let parsed = UInt16(String(decoding: rawPort, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)) else {
            process.terminate()
            throw RemoteTransferError.networkFailure
        }
        port = parsed
        initialized = true
    }

    func job(
        _ path: String, hostname: String = "cdn.example.com", fileDescriptor: Int32,
        budget: RemoteByteBudget? = nil
    ) -> OpaquePointer? {
        let url = "https://\(hostname):\(port)\(path)"
        let resolution = "\(hostname):\(port):127.0.0.1"
        return url.withCString { urlString in
            resolution.withCString { override in
                certificate.path.withCString { caFile in
                    silicon_artifact_job_create_test(
                        urlString, fileDescriptor, 256, 5_000, 0, override, caFile,
                        budget == nil ? nil : Self.consumeBytes,
                        budget.map { Unmanaged.passUnretained($0).toOpaque() }
                    )
                }
            }
        }
    }

    private static let consumeBytes: SiliconArtifactConsume = { context, count in
        guard let context else { return 0 }
        let budget = Unmanaged<RemoteByteBudget>.fromOpaque(context).takeUnretainedValue()
        do {
            try budget.consume(count)
            return 1
        } catch {
            return 0
        }
    }

    deinit {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        try? FileManager.default.removeItem(at: directory)
    }
}
