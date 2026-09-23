import Foundation
import Testing
@testable import SiliconCore
@testable import SiliconRuntime

/// GMI audio downloads refuse a proxied route, because the CDN's address cannot be checked
/// through a proxy. That refusal has to come before the job is submitted: finding out at the
/// download meant GMI had already done, and billed, the work — and the owner was told the
/// provider had answered 502.
@Suite("Cloud audio on a proxied Mac", .serialized)
struct CloudAudioDirectConnectionTests {

    private func runtime(proxied: Bool) -> CloudAudioRuntime {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GMIQueueStub.self]
        return CloudAudioRuntime(
            session: URLSession(configuration: configuration),
            requireDirectConnection: { _ in
                if proxied { throw RemoteTransferError.unverifiableProxy }
            }
        )
    }

    private func speak(on runtime: CloudAudioRuntime) async throws {
        _ = try await runtime.generate(
            CloudAudioRequest(
                model: "speech", kind: .speech, text: "hello",
                outputDirectory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("cloud-audio-proxy-\(UUID().uuidString)")
            ),
            base: try #require(CloudProvider.gmi.jobsBaseURL), apiKey: "test-key",
            onProgress: { _ in }
        )
    }

    @Test func aProxiedMacIsToldBeforeAnythingIsSubmitted() async throws {
        GMIQueueStub.requests.reset()
        do {
            try await speak(on: runtime(proxied: true))
            Issue.record("a proxied Mac submitted a job it could not fetch")
        } catch CloudAudioError.needsDirectConnection {
            // Expected.
        } catch {
            Issue.record("Expected the direct-connection refusal, got \(error)")
        }
        #expect(GMIQueueStub.requests.value == 0, "nothing reached GMI, so nothing was billed")

        let sentence = CloudAudioError.needsDirectConnection.localizedDescription
        #expect(!sentence.contains("provider answered"))
        #expect(sentence.contains("Proxies"), "it says where to change it")
        #expect(sentence.contains("Nothing was sent"))
    }

    /// The control: the same runtime on a direct route does submit. The stub then reports
    /// the job failed, so the test ends there without a download.
    @Test func aDirectMacStillSubmits() async throws {
        GMIQueueStub.requests.reset()
        do {
            try await speak(on: runtime(proxied: false))
            Issue.record("the stub's failed job answered")
        } catch CloudAudioError.jobFailed {
            // Expected: submitted, polled, reported failed.
        } catch {
            Issue.record("Expected the stub's job failure, got \(error)")
        }
        #expect(GMIQueueStub.requests.value >= 2)
    }

    @Test func aDownloadThisMacRefusedIsNotBlamedOnTheProvider() {
        let error = CloudAudioError.downloadFailed(
            RemoteTransferError.disallowedResolvedAddress.localizedDescription
        )
        #expect(!(error.errorDescription ?? "").contains("provider answered"))
        #expect((error.errorDescription ?? "").contains("did not download"))
    }
}

private final class RequestCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func reset() { lock.withLock { count = 0 } }
    func increment() { lock.withLock { count += 1 } }
}

/// GMI's queue, answered locally: a submission gets an id and every poll says it failed.
private final class GMIQueueStub: URLProtocol, @unchecked Sendable {
    static let requests = RequestCount()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.increment()
        let body = request.httpMethod == "POST"
            ? #"{"request_id":"job-1"}"#
            : #"{"status":"failed","outcome":{"message":"stub failure"}}"#
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
