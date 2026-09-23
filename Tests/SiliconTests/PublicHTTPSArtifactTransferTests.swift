import CArtifactHTTP
import CFNetwork
import Darwin
import Foundation
import Testing
@testable import SiliconRuntime

@Suite("Public HTTPS artifact transport", .serialized, .timeLimit(.minutes(2)))
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

    @Test func everyRedirectHopRunsThroughTheVetoAndTheArtifactIsPublishedOnce() async throws {
        let server = try FixtureTLSHTTPServer()
        let output = server.directory.appendingPathComponent("out")
        let destination = output.appendingPathComponent("audio.mp3")
        let counter = NetworkAttemptCounter()
        let published = try await PublicHTTPSArtifactTransfer.download(
            from: URL(string: "https://cdn.example.com:\(server.port)/redirect")!,
            to: destination, maximumBytes: 256, budget: RemoteByteBudget(limit: 256),
            timeout: 5, proxyCheck: { _ in }, onNetworkAttempt: { counter.increment() },
            makeJob: server.hopJobs
        )
        #expect(published == destination)
        #expect(try Data(contentsOf: destination) == Data("audio".utf8))
        #expect(counter.value == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path) == ["audio.mp3"])
    }

    /// DNS rebinding across a redirect: the first hop is a real (fixture) CDN, and the name it
    /// hands the client on to looks public but answers 127.0.0.1. The second hop has to be
    /// refused when its socket is opened, before a TCP connection, a request or a body byte.
    @Test func aRedirectToANameThatResolvesToLoopbackIsRefusedBeforeConnecting() async throws {
        let server = try FixtureTLSHTTPServer()
        let listener = try LoopbackConnectionCounter()
        defer { listener.stop() }
        let output = server.directory.appendingPathComponent("out")
        let destination = output.appendingPathComponent("audio.mp3")
        let target = "https://media.example.net:\(listener.port)/audio.mp3"
        let escaped = try #require(
            target.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
        )
        let counter = NetworkAttemptCounter()

        do {
            _ = try await PublicHTTPSArtifactTransfer.download(
                from: URL(string: "https://cdn.example.com:\(server.port)/bounce?to=\(escaped)")!,
                to: destination, maximumBytes: 256, budget: RemoteByteBudget(limit: 256),
                timeout: 5, proxyCheck: { _ in }, onNetworkAttempt: { counter.increment() },
                makeJob: server.hopJobs
            )
            Issue.record("A hop whose name answers with loopback must not be downloaded")
        } catch RemoteTransferError.disallowedResolvedAddress {
            // Expected: the veto, not a TLS or network failure after connecting.
        } catch {
            Issue.record("Expected the resolved-address veto, got \(error)")
        }
        #expect(counter.value == 2, "The first hop ran; the second was attempted and refused")
        try await Task.sleep(for: .milliseconds(100))
        #expect(listener.accepted == 0)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)

        // The control: with the fixture's loopback exemption the same address is reachable,
        // so the zero above is the veto's doing and not an unreachable listener.
        let scratch = server.directory.appendingPathComponent("control.partial")
        #expect(FileManager.default.createFile(atPath: scratch.path, contents: nil))
        let handle = try FileHandle(forWritingTo: scratch)
        defer { try? handle.close() }
        let control = try #require(target.withCString { address in
            "media.example.net:\(listener.port):127.0.0.1".withCString { override in
                server.certificate.path.withCString { trusted in
                    silicon_artifact_job_create_test(
                        address, handle.fileDescriptor, 256, 2_000, 0, override, trusted, nil, nil
                    )
                }
            }
        })
        defer { silicon_artifact_job_destroy(control) }
        _ = silicon_artifact_job_perform(control)
        try await Task.sleep(for: .milliseconds(100))
        #expect(listener.accepted >= 1)
    }

    @Test func cancellingMidBodyRemovesThePartialAndPublishesNothing() async throws {
        let server = try FixtureTLSHTTPServer()
        let output = server.directory.appendingPathComponent("out")
        let destination = output.appendingPathComponent("audio.mp3")
        let started = ContinuousClock.now
        let transfer = Task {
            try await PublicHTTPSArtifactTransfer.download(
                from: URL(string: "https://cdn.example.com:\(server.port)/stall")!,
                to: destination, maximumBytes: 16_384, budget: RemoteByteBudget(limit: 16_384),
                timeout: 60, proxyCheck: { _ in }, onNetworkAttempt: {},
                makeJob: server.hopJobs
            )
        }
        // In flight means bytes on disk: the fixture sends half the body, then stalls for 30s.
        #expect(await pollUntil { partialBytes(in: output) >= 4_096 })
        transfer.cancel()
        await #expect(throws: CancellationError.self) { try await transfer.value }
        #expect(ContinuousClock.now - started < .seconds(15), "Cancelled, not waited out")
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
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

/// Bytes in the transfer's hidden `.partial` files — what an in-flight download has on disk.
func partialBytes(in directory: URL) -> Int {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    return names.filter { $0.hasSuffix(".partial") }.reduce(0) { total, name in
        let path = directory.appendingPathComponent(name).path
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? Int
        return total + (size ?? 0)
    }
}

func pollUntil(
    within limit: Duration = .seconds(10), _ condition: @Sendable () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: limit)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
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

/// A loopback HTTPS server with a throwaway certificate for `cdn.example.com`. Shared with
/// the cloud audio cancellation tests, which drive the same transport through the app.
final class FixtureTLSHTTPServer: @unchecked Sendable {
    let directory: URL
    let certificate: URL
    let port: UInt16
    private let process: Process
    /// The server's stdin. Nothing is written; holding it open is what keeps the server
    /// alive, so it exits on its own if this process ends without running `deinit`.
    private let lifeline = Pipe()
    /// Signalled when the server exits. `waitUntilExit` spins the calling thread's run loop
    /// for a notification delivered to the launching thread's, so an async test that
    /// resumed on another cooperative thread would wait in `deinit` forever.
    private let exited = DispatchSemaphore(value: 0)

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
        // Not the test run's own stderr: a server that outlived this process would hold it
        // open, and `swift test` waits for EOF on it before it reports anything.
        process.standardError = FileHandle.nullDevice
        process.standardInput = lifeline
        process.terminationHandler = { [exited] _ in exited.signal() }
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

    /// Hop jobs for `PublicHTTPSArtifactTransfer.download`. `cdn.example.com` on this port
    /// resolves here and trusts the fixture certificate, standing in for a public CDN; every
    /// other name resolves to 127.0.0.1 without that trust, which is what a rebinding answer
    /// looks like to the production veto. Nothing here can reach the real network. The
    /// factory holds the server, so a transfer in progress keeps its fixture running.
    var hopJobs: PublicHTTPSArtifactTransfer.JobFactory {
        { url, descriptor, limit, timeout, reserve, consume, context in
            guard let components = URLComponents(string: url), let host = components.host
            else { return nil }
            let resolution = "\(host):\(components.port ?? 443):127.0.0.1"
            let fixture = host == "cdn.example.com" && components.port == Int(self.port)
            return url.withCString { address in
                resolution.withCString { override in
                    guard fixture else {
                        return silicon_artifact_job_create_test(
                            address, descriptor, limit, timeout, reserve, override, nil,
                            consume, context
                        )
                    }
                    return self.certificate.path.withCString { caFile in
                        silicon_artifact_job_create_test(
                            address, descriptor, limit, timeout, reserve, override, caFile,
                            consume, context
                        )
                    }
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
        if process.isRunning { process.terminate() }
        _ = exited.wait(timeout: .now() + 5)
        try? FileManager.default.removeItem(at: directory)
    }
}
