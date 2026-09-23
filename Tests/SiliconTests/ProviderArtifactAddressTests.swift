import CArtifactHTTP
import Foundation
import Testing
@testable import SiliconCore
@testable import SiliconRuntime

/// Issue #74: a provider-supplied artifact URL must not reach a private or loopback address
/// through DNS, on any hop, before a byte is read.
@Suite("Provider artifact addresses", .serialized, .timeLimit(.minutes(2)))
struct ProviderArtifactAddressTests {
    /// URLSession could only ever screen the URL text, so the provider policy is refused by
    /// the URLSession transports rather than quietly enforced by half.
    @Test func urlSessionTransportsRefuseTheProviderPolicyBeforeAnyRequest() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderStubProtocol.self]
        let session = URLSession(configuration: configuration)
        let url = URL(string: "https://cdn.example.com/audio.mp3")!
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("silicon-provider-policy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        ProviderStubProtocol.state.reset(artifactURL: url.absoluteString)

        await #expect(throws: RemoteTransferError.self) {
            _ = try await RemoteHTTP.data(
                for: URLRequest(url: url), session: session, policy: .publicHTTPS
            )
        }
        await #expect(throws: RemoteTransferError.self) {
            _ = try await RemoteArtifactTransfer.download(
                from: url, policy: .publicHTTPS, to: directory.appendingPathComponent("a.mp3"),
                maximumBytes: 64, budget: RemoteByteBudget(limit: 64), timeout: 5,
                allowedContentTypes: ["audio/*"], sessionConfiguration: configuration
            )
        }
        #expect(ProviderStubProtocol.state.requests == 0)
        #expect(!FileManager.default.fileExists(atPath: directory.path))

        // The control: the same stub does answer a policy URLSession can enforce, so the
        // zero above is the refusal and not a stub that never saw anything.
        _ = try await RemoteHTTP.data(
            for: URLRequest(url: url), session: session, policy: .sameOrigin(url)
        )
        #expect(ProviderStubProtocol.state.requests == 1)
    }

    /// The whole GMI audio path, from the provider's answer to the file on disk: the artifact
    /// URL names a public-looking host whose DNS answer is 127.0.0.1.
    @Test func aProviderArtifactThatResolvesToLoopbackIsRefusedBeforeAnyByte() async throws {
        let listener = try LoopbackConnectionCounter()
        defer { listener.stop() }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("silicon-provider-rebind-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let artifact = "https://media.example.net:\(listener.port)/audio.mp3"
        ProviderStubProtocol.state.reset(artifactURL: artifact)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderStubProtocol.self]
        let runtime = CloudAudioRuntime(
            session: URLSession(configuration: configuration),
            artifactDownload: { url, destination, maximumBytes, budget, timeout in
                try await PublicHTTPSArtifactTransfer.download(
                    from: url, to: destination, maximumBytes: maximumBytes, budget: budget,
                    timeout: timeout, proxyCheck: { _ in }, onNetworkAttempt: {},
                    makeJob: Self.everyNameIsLoopback
                )
            }
        )
        let base = try #require(CloudProvider.gmi.jobsBaseURL)
        do {
            _ = try await runtime.generate(
                CloudAudioRequest(model: "speech", kind: .speech, text: "hello",
                                  outputDirectory: directory),
                base: base, apiKey: "test-key", onProgress: { _ in }
            )
            Issue.record("A loopback answer for the artifact host must not be downloaded")
        } catch CloudAudioError.downloadFailed(let message) {
            // This Mac's refusal, reported as this Mac's — not as a provider answer.
            #expect(message == RemoteTransferError.disallowedResolvedAddress.localizedDescription)
        } catch {
            Issue.record("Expected the resolved-address refusal, got \(error)")
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(listener.accepted == 0, "No TCP connection, so no request and no body")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        #expect(leftovers.isEmpty)

        // The control: let the job past the veto and the listener is reached at once.
        let trust = directory.appendingPathComponent("unused-ca.pem").path
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("silicon-provider-control-\(UUID().uuidString)")
        #expect(FileManager.default.createFile(atPath: scratch.path, contents: nil))
        defer { try? FileManager.default.removeItem(at: scratch) }
        let handle = try FileHandle(forWritingTo: scratch)
        defer { try? handle.close() }
        let control = try #require(artifact.withCString { address in
            "media.example.net:\(listener.port):127.0.0.1".withCString { override in
                trust.withCString { caFile in
                    silicon_artifact_job_create_test(
                        address, handle.fileDescriptor, 64, 2_000, 0, override, caFile, nil, nil
                    )
                }
            }
        })
        defer { silicon_artifact_job_destroy(control) }
        _ = silicon_artifact_job_perform(control)
        try await Task.sleep(for: .milliseconds(100))
        #expect(listener.accepted >= 1)
    }

    /// Every hop's name answers 127.0.0.1 and nothing is trusted beyond production's rules,
    /// which is a rebinding attacker's DNS with the real veto left in place.
    private static let everyNameIsLoopback: PublicHTTPSArtifactTransfer.JobFactory = {
        url, descriptor, limit, timeout, reserve, consume, context in
        guard let components = URLComponents(string: url), let host = components.host
        else { return nil }
        let resolution = "\(host):\(components.port ?? 443):127.0.0.1"
        return url.withCString { address in
            resolution.withCString { override in
                silicon_artifact_job_create_test(
                    address, descriptor, limit, timeout, reserve, override, nil, consume, context
                )
            }
        }
    }
}

private final class ProviderStubState: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var artifact = ""

    var requests: Int { lock.withLock { count } }
    var artifactURL: String { lock.withLock { artifact } }

    func reset(artifactURL: String) {
        lock.withLock {
            count = 0
            artifact = artifactURL
        }
    }

    func record() { lock.withLock { count += 1 } }
}

/// GMI's queue, answered locally: a submission gets an id, and the first poll reports
/// success with whatever artifact URL the test chose.
private final class ProviderStubProtocol: URLProtocol, @unchecked Sendable {
    static let state = ProviderStubState()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.state.record()
        let outcome = #"{"status":"success","outcome":{"audio_url":"\#(Self.state.artifactURL)"}}"#
        let body = Data((request.httpMethod == "POST" ? #"{"request_id":"job-1"}"# : outcome).utf8)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
