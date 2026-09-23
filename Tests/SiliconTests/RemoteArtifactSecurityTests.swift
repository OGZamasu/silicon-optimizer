import Foundation
import CArtifactHTTP
import CFNetwork
import Network
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
                systemSettings: ["__SCOPED__": ["en0": [
                    kCFNetworkProxiesProxyAutoDiscoveryEnable as String: 1,
                ]]]
            )
        }
        try PublicHTTPSArtifactTransfer.enforceDirect(
            environment: [:], proxyEntries: direct, systemSettings: [:]
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

        let url = "https://cdn.example.com:\(listener.port)/song.mp3"
        let override = "cdn.example.com:\(listener.port):127.0.0.1"
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
        try await Task.sleep(for: .milliseconds(100))
        #expect(listener.accepted == 0, "Private DNS must be rejected before a TCP connection or HTTP GET")
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
                from: remote, policy: .publicHTTPS, to: destination,
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

final class LoopbackConnectionCounter: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var count = 0
    private(set) var port: UInt16 = 0

    var accepted: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        listener = try NWListener(using: parameters, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.lock.lock()
            self.count += 1
            self.lock.unlock()
            connection.cancel()
        }
        listener.start(queue: DispatchQueue(label: "artifact-ip-fixture"))
        guard ready.wait(timeout: .now() + 5) == .success else {
            listener.cancel()
            throw RemoteTransferError.networkFailure
        }
        port = listener.port?.rawValue ?? 0
    }

    func stop() { listener.cancel() }
}
