import Foundation
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
        // therefore remain compatible pending a source-backed provider allowlist; DNS
        // resolution/rebinding is the deliberately documented residual policy gap.
        #expect(policy.resolve("https://undocumented-cdn.example.net/a.mp3", relativeTo: base) != nil)
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
