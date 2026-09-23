import Foundation
import CArtifactHTTP
import CFNetwork
import Darwin
import Testing
@testable import SiliconRuntime

@Suite("Remote artifact security", .serialized)
struct RemoteArtifactSecurityTests {
    @Test func remoteIdentifiersRemainOnePathComponent() {
        let base = URL(string: "https://peer.example.com/v1/jobs")!

        #expect(RemotePathIdentifier.appending("job-123_~.x", to: base)?.path
            == "/v1/jobs/job-123_~.x")
        for invalid in ["", ".", "..", "../admin", "a/b", "a\\b", "%2e%2e", "x\ny"] {
            #expect(RemotePathIdentifier.appending(invalid, to: base) == nil)
        }
        #expect(RemotePathIdentifier.appending(
            String(repeating: "a", count: RemotePathIdentifier.maximumBytes + 1), to: base
        ) == nil)
    }

    @Test func peerURLsCannotChangeHostOrScheme() {
        let base = URL(string: "http://100.64.0.9:8790")!
        let policy = RemoteURLPolicy.peerHost(base)

        #expect(policy.resolve("/v1/files/a.mp4", relativeTo: base) != nil)
        #expect(policy.resolve("http://100.64.0.9:8081/a.mp4", relativeTo: base) != nil)
        #expect(policy.resolve("http://127.0.0.1:8081/a.mp4", relativeTo: base) == nil)
        #expect(policy.resolve("https://100.64.0.9/a.mp4", relativeTo: base) == nil)
        #expect(policy.resolve("file:///tmp/a.mp4", relativeTo: base) == nil)
    }

    @Test func providerArtifactsRejectLocalAndInsecureTargets() {
        let policy = RemoteURLPolicy.publicHTTPS
        let base = URL(string: "https://provider.example.com")!

        #expect(policy.resolve("https://cdn.example.com/a.mp3", relativeTo: base) != nil)
        #expect(policy.resolve("/result/a.mp3", relativeTo: base) != nil)
        #expect(policy.resolve("http://cdn.example.com/a.mp3", relativeTo: base) == nil)
        #expect(policy.resolve("https://127.0.0.1/a.mp3", relativeTo: base) == nil)
        #expect(policy.resolve("https://10.1.2.3/a.mp3", relativeTo: base) == nil)
        #expect(policy.resolve("https://169.254.169.254/latest", relativeTo: base) == nil)
        #expect(policy.resolve("https://127.1/a.mp3", relativeTo: base) == nil)
        #expect(policy.resolve("https://0177.0.0.1/a.mp3", relativeTo: base) == nil)
        #expect(policy.resolve("https://0x7f.0.0.1/a.mp3", relativeTo: base) == nil)
        #expect(policy.resolve("https://[::1]/a.mp3", relativeTo: base) == nil)
        #expect(policy.resolve("https://localhost/a.mp3", relativeTo: base) == nil)
        #expect(policy.resolve("https://artifact.test/a.mp3", relativeTo: base) == nil)

        // Special-use ranges that share a first octet with public space. Two of these used
        // to pass: the check listed two ranges per line, and a comma binds looser than `||`.
        for host in ["192.0.0.8", "192.0.2.1", "198.18.0.1", "198.19.255.254", "198.51.100.7"] {
            #expect(policy.resolve("https://\(host)/a.mp3", relativeTo: base) == nil, "\(host)")
        }
        for host in ["192.0.1.1", "198.17.0.1", "198.20.0.1"] {
            #expect(policy.resolve("https://\(host)/a.mp3", relativeTo: base) != nil, "\(host)")
        }

        // The provider does not publish CDN ownership in this repository. Public hostnames
        // remain compatible while the GMI audio transfer validates each connected address.
        #expect(policy.resolve("https://undocumented-cdn.example.net/a.mp3", relativeTo: base) != nil)
    }

    @Test func connectedAddressClassifierRejectsLocalAndTransitionRanges() {
        for address in [
            "127.0.0.1", "10.1.2.3", "172.16.0.1", "192.168.1.1", "169.254.169.254",
            "100.64.0.1", "0.0.0.0", "224.0.0.1", "192.0.2.1", "198.51.100.1",
            "::1", "fe80::1", "fd00::1", "::ffff:127.0.0.1", "64:ff9b::a00:1",
            "2001:db8::1", "2002:0a00:0001::1", "3fff::1",
            // NAT64: a synthesized address is judged by the IPv4 it embeds, so the tailnet's
            // CGNAT range and loopback stay out; the local-use prefix is never translated here.
            "64:ff9b::6440:9", "64:ff9b::7f00:1", "64:ff9b:1::a00:1",
        ] {
            #expect(address.withCString(silicon_artifact_public_ip) == 0)
        }
        for address in [
            "1.1.1.1", "8.8.8.8", "2606:4700:4700::1111", "2001:4860:4860::8888",
            // DNS64 on an IPv6-only network synthesizes this for an IPv4-only CDN.
            "64:ff9b::808:808",
        ] {
            #expect(address.withCString(silicon_artifact_public_ip) == 1)
        }
    }

    @Test func artifactProxyPolicyFailsClosed() throws {
        let typeKey = kCFProxyTypeKey as String
        #expect(PublicHTTPSArtifactTransfer.directOnly([[typeKey: kCFProxyTypeNone as String]]))
        #expect(!PublicHTTPSArtifactTransfer.directOnly([]))
        #expect(!PublicHTTPSArtifactTransfer.directOnly([[typeKey: kCFProxyTypeHTTP as String]]))
        #expect(!PublicHTTPSArtifactTransfer.directOnly([
            [typeKey: kCFProxyTypeNone as String], [typeKey: kCFProxyTypeSOCKS as String],
        ]))
        #expect(!PublicHTTPSArtifactTransfer.directOnly([
            [typeKey: kCFProxyTypeAutoConfigurationURL as String],
        ]))
        #expect(PublicHTTPSArtifactTransfer.proxyEnvironmentConfigured(["HTTPS_PROXY": "proxy:8080"]))
        #expect(!PublicHTTPSArtifactTransfer.proxyEnvironmentConfigured([:]))
        let direct = [[typeKey: kCFProxyTypeNone as String]]
        #expect(throws: RemoteTransferError.self) {
            try PublicHTTPSArtifactTransfer.enforceDirect(
                environment: ["HTTPS_PROXY": "proxy:8080"], proxyEntries: direct,
                systemSettings: [:]
            )
        }
        #expect(throws: RemoteTransferError.self) {
            try PublicHTTPSArtifactTransfer.enforceDirect(
                environment: [:], proxyEntries: direct,
                systemSettings: [kCFNetworkProxiesProxyAutoConfigEnable as String: 1]
            )
        }
        #expect(throws: RemoteTransferError.self) {
            try PublicHTTPSArtifactTransfer.enforceDirect(
                environment: [:], proxyEntries: direct,
                systemSettings: [kCFNetworkProxiesProxyAutoDiscoveryEnable as String: 1]
            )
        }
        try PublicHTTPSArtifactTransfer.enforceDirect(
            environment: [:], proxyEntries: direct, systemSettings: [:]
        )
        // WPAD or PAC on an interface that is not the primary one does not describe the
        // route this transfer takes, so it no longer locks the download out.
        try PublicHTTPSArtifactTransfer.enforceDirect(
            environment: [:], proxyEntries: direct,
            systemSettings: ["__SCOPED__": ["en1": [
                kCFNetworkProxiesProxyAutoDiscoveryEnable as String: 1,
                kCFNetworkProxiesProxyAutoConfigEnable as String: 1,
            ]]]
        )
    }

    @Test func audioRedirectsAreValidatedOnEveryHopAndBounded() throws {
        let current = URL(string: "https://cdn.example.com/music/result")!
        #expect(try PublicHTTPSArtifactTransfer.redirectTarget(
            "/next", from: current, count: 0
        ).absoluteString == "https://cdn.example.com/next")
        #expect(throws: RemoteTransferError.self) {
            try PublicHTTPSArtifactTransfer.redirectTarget(
                "http://10.0.0.1/admin", from: current, count: 0
            )
        }
        #expect(throws: RemoteTransferError.self) {
            try PublicHTTPSArtifactTransfer.redirectTarget(
                "https://127.0.0.1/private", from: current, count: 0
            )
        }
        #expect(throws: RemoteTransferError.self) {
            try PublicHTTPSArtifactTransfer.redirectTarget(
                "/loop", from: current, count: 20
            )
        }
    }

    @Test func rebindingToLoopbackIsRefusedBeforeOpeningSocket() async throws {
        let listener = try LoopbackConnectionCounter()
        defer { listener.stop() }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("silicon-artifact-ip-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("partial")
        #expect(FileManager.default.createFile(atPath: file.path, contents: nil))
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }

        let url = "https://\(listener.host):\(listener.port)/song.mp3"
        let override = "\(listener.host):\(listener.port):127.0.0.1"
        let job = url.withCString { address in
            override.withCString { resolution in
                silicon_artifact_job_create_test(
                    address, handle.fileDescriptor, 1_024, 2_000, 0,
                    resolution, nil, nil, nil
                )
            }
        }
        let unwrapped = try #require(job)
        defer { silicon_artifact_job_destroy(unwrapped) }
        #expect(silicon_artifact_job_perform(unwrapped) == SILICON_ARTIFACT_PRIVATE_ADDRESS)
        #expect(silicon_artifact_job_bytes(unwrapped) == 0)
        // The job has returned, so any connection it made is already counted.
        #expect(listener.accepted == 0, "Private DNS must be rejected before a TCP connection or HTTP GET")
    }

    /// What made the rebinding tests flaky in a full run: another suite's connection landing
    /// on the listener's port while the veto held. It must not read as the transfer's — and
    /// the transfer's own connection, let past the veto, must.
    @Test func aStrayConnectionOnTheListenersPortIsNotTheTransfers() throws {
        let listener = try LoopbackConnectionCounter()
        defer { listener.stop() }

        // Another suite's health poll that found this port: plain HTTP, not our ClientHello.
        let stray = socket(AF_INET, SOCK_STREAM, 0)
        #expect(stray >= 0)
        defer { close(stray) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = listener.port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(stray, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        #expect(connected == 0)
        let request = Array("GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8)
        #expect(write(stray, request, request.count) == request.count)
        _ = shutdown(stray, SHUT_WR)
        // The listener closes a connection only after deciding whose it is, so EOF here
        // means the stray has been judged.
        var buffer = [UInt8](repeating: 0, count: 64)
        while read(stray, &buffer, buffer.count) > 0 {}
        #expect(listener.accepted == 0)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("silicon-stray-control-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("partial")
        #expect(FileManager.default.createFile(atPath: file.path, contents: nil))
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        let url = "https://\(listener.host):\(listener.port)/song.mp3"
        let control = try #require(url.withCString { address in
            "\(listener.host):\(listener.port):127.0.0.1".withCString { override in
                "/etc/ssl/cert.pem".withCString { trusted in
                    silicon_artifact_job_create_test(
                        address, handle.fileDescriptor, 1_024, 2_000, 0, override, trusted,
                        nil, nil
                    )
                }
            }
        })
        defer { silicon_artifact_job_destroy(control) }
        _ = silicon_artifact_job_perform(control)
        #expect(listener.waitForConnections(1))
        #expect(listener.accepted == 1)
    }

    @Test func bearerCredentialsAreOriginBound() throws {
        let origin = URL(string: "http://peer.example.com:8790")!
        let policy = RemoteURLPolicy.peerHost(origin)
        var sameOrigin = URLRequest(url: URL(string: "http://peer.example.com:8790/v1")!)
        sameOrigin.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        #expect(policy.sanitized(sameOrigin, credentialOrigin: origin)?
            .value(forHTTPHeaderField: "Authorization") == "Bearer secret")

        var otherPort = URLRequest(url: URL(string: "http://peer.example.com:8081/v1")!)
        otherPort.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        #expect(policy.sanitized(otherPort, credentialOrigin: origin)?
            .value(forHTTPHeaderField: "Authorization") == nil)

        var otherHost = URLRequest(url: URL(string: "http://localhost:8081/v1")!)
        otherHost.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        #expect(policy.sanitized(otherHost, credentialOrigin: origin) == nil)

        let publicPolicy = RemoteURLPolicy.publicHTTPS
        let publicOrigin = URL(string: "https://api.example.com")!
        var privateRedirect = URLRequest(url: URL(string: "https://127.0.0.1/result")!)
        privateRedirect.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        #expect(publicPolicy.sanitized(privateRedirect, credentialOrigin: publicOrigin) == nil)
    }

    @Test func aggregateBudgetRejectsTheFirstBytePastTheLimit() throws {
        let budget = RemoteByteBudget(limit: 10)
        try budget.consume(6)
        #expect(budget.remaining == 4)
        #expect(throws: RemoteTransferError.self) { try budget.consume(5) }
        #expect(budget.remaining == 4)
    }

    @Test func controlBodiesAreBoundedWithoutTrustingContentLength() async {
        BoundedBodyURLProtocol.body = Data(repeating: 0x41, count: 65)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BoundedBodyURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let url = URL(string: "https://peer.example.com/status")!
        await #expect(throws: RemoteTransferError.self) {
            _ = try await RemoteHTTP.data(
                for: URLRequest(url: url), session: session,
                policy: .peerHost(url), successLimit: 64
            )
        }
    }

    @Test func artifactOverflowNeverPublishesAPartialFile() async throws {
        BoundedBodyURLProtocol.body = Data(repeating: 0x41, count: 65)
        BoundedBodyURLProtocol.contentType = "application/octet-stream"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BoundedBodyURLProtocol.self]
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("silicon-transfer-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("result.bin")
        let remote = URL(string: "https://cdn.example.com/result.bin")!

        await #expect(throws: RemoteTransferError.self) {
            _ = try await RemoteArtifactTransfer.download(
                from: remote, policy: .peerHost(remote), to: destination,
                maximumBytes: 64, budget: RemoteByteBudget(limit: 128), timeout: 5,
                allowedContentTypes: ["application/octet-stream"],
                sessionConfiguration: configuration
            )
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        #expect(leftovers.isEmpty)
    }
}

private final class BoundedBodyURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var contentType = "application/json"

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": Self.contentType]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// A loopback listener that counts this test's own connections and no one else's.
///
/// Suites running beside this one poll loopback ports they were handed a moment earlier —
/// a runtime's health check, say, after the runtime died without binding — and the kernel
/// can hand that same port to the next listener, this one. Counting every accepted
/// connection therefore saw strays: the veto held and the count still read 1. Every
/// connection the transfer under test can make opens with a TLS ClientHello naming `host`,
/// which is unique to this listener, so only a connection that says that name is counted.
///
/// The count is also settled before the transfer can see the connection end: a connection is
/// counted and only then closed, and the transfer only returns once it has seen the close.
/// So once a transfer has returned, its connection is in `accepted` — no sleep to guess how
/// long a handler takes to run.
final class LoopbackConnectionCounter: @unchecked Sendable {
    let host = "media-\(UUID().uuidString.prefix(8).lowercased()).example.net"
    let port: UInt16
    private let descriptor: Int32
    private let source: DispatchSourceRead
    private let condition = NSCondition()
    private var ours = 0

    /// Connections that named `host`.
    var accepted: Int {
        condition.lock()
        defer { condition.unlock() }
        return ours
    }

    init() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw RemoteTransferError.networkFailure }
        self.descriptor = descriptor
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                bind(descriptor, generic, length) == 0
                    && listen(descriptor, 16) == 0
                    && getsockname(descriptor, generic, &length) == 0
            }
        }
        guard bound, fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else {
            close(descriptor)
            throw RemoteTransferError.networkFailure
        }
        port = UInt16(bigEndian: address.sin_port)
        source = DispatchSource.makeReadSource(
            fileDescriptor: descriptor, queue: DispatchQueue(label: "loopback-counter")
        )
        source.setEventHandler { [weak self] in
            while case let client = accept(descriptor, nil, nil), client >= 0 {
                guard let self else {
                    close(client)
                    continue
                }
                DispatchQueue.global().async { self.inspect(client) }
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
    }

    /// Reads until the ClientHello names `host`, the peer stops sending, or two seconds
    /// pass; counts a match; then closes.
    private func inspect(_ client: Int32) {
        defer { close(client) }
        _ = fcntl(client, F_SETFL, 0)
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        _ = setsockopt(
            client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)
        )
        let name = Data(host.utf8)
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while received.count < 65_536, received.range(of: name) == nil {
            let count = read(client, &buffer, buffer.count)
            guard count > 0 else { break }
            received.append(contentsOf: buffer[0..<count])
        }
        guard received.range(of: name) != nil else { return }
        condition.lock()
        ours += 1
        condition.broadcast()
        condition.unlock()
    }

    /// Waits for this test's connections to reach `count` — on the event itself, with a
    /// deadline only for when it never comes.
    func waitForConnections(_ count: Int, within seconds: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        condition.lock()
        defer { condition.unlock() }
        while ours < count {
            if !condition.wait(until: deadline) { return ours >= count }
        }
        return true
    }

    func stop() { source.cancel() }
}
