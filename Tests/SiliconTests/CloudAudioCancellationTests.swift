import Foundation
import Testing
@testable import SiliconCatalog
@testable import SiliconCore
@testable import SiliconRuntime
@testable import SiliconUI

enum CloudAudioPhase: String, Sendable, CaseIterable {
    case submit, poll, download
}

private final class CloudAudioStubState: @unchecked Sendable {
    static let shared = CloudAudioStubState()

    private let lock = NSLock()
    private var heldPhase: CloudAudioPhase?
    private var started: [CloudAudioPhase: Int] = [:]
    private var stopped: [CloudAudioPhase: Int] = [:]
    private var downloadChunkSent = false
    private var overlappingReplies = false
    private var pollsByID: [String: Int] = [:]

    func reset(holding phase: CloudAudioPhase?) {
        lock.withLock {
            heldPhase = phase
            started = [:]
            stopped = [:]
            downloadChunkSent = false
            overlappingReplies = false
            pollsByID = [:]
        }
    }

    func enableOverlappingReplies() {
        reset(holding: nil)
        lock.withLock { overlappingReplies = true }
    }

    func didStart(_ phase: CloudAudioPhase, url: URL?) -> Bool {
        lock.withLock {
            started[phase, default: 0] += 1
            if phase == .poll, let id = url?.lastPathComponent {
                pollsByID[id, default: 0] += 1
            }
            return heldPhase == phase
        }
    }

    func usesOverlappingReplies() -> Bool {
        lock.withLock { overlappingReplies }
    }

    func pollCount(_ id: String) -> Int {
        lock.withLock { pollsByID[id] ?? 0 }
    }

    func didStop(_ phase: CloudAudioPhase) {
        lock.withLock { stopped[phase, default: 0] += 1 }
    }

    func sentDownloadChunk() {
        lock.withLock { downloadChunkSent = true }
    }

    func hasStarted(_ phase: CloudAudioPhase) -> Bool {
        lock.withLock {
            (started[phase] ?? 0) > 0 && (phase != .download || downloadChunkSent)
        }
    }

    func hasStopped(_ phase: CloudAudioPhase) -> Bool {
        lock.withLock { (stopped[phase] ?? 0) > 0 }
    }

    func count(_ phase: CloudAudioPhase) -> Int {
        lock.withLock { started[phase] ?? 0 }
    }
}

private final class CloudAudioStubProtocol: URLProtocol, @unchecked Sendable {
    static let state = CloudAudioStubState.shared
    private var phase: CloudAudioPhase?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let phase: CloudAudioPhase = request.httpMethod == "POST"
            ? .submit : request.url?.host == "cdn.example.com" ? .download : .poll
        self.phase = phase
        let hold = Self.state.didStart(phase, url: request.url)
        if hold && phase != .download { return }

        let body: Data
        let contentType: String
        switch phase {
        case .submit:
            let id = Self.state.usesOverlappingReplies()
                ? "job-\(Self.state.count(.submit))" : "job-1"
            body = Data("{\"request_id\":\"\(id)\"}".utf8)
            contentType = "application/json"
        case .poll:
            if Self.state.usesOverlappingReplies(),
               request.url?.lastPathComponent == "job-1",
               Self.state.pollCount("job-1") == 1 {
                body = Data(#"{"status":"queued"}"#.utf8)
            } else {
                body = Data(#"{"status":"success","outcome":{"audio_url":"https://cdn.example.com/audio.mp3"}}"#.utf8)
            }
            contentType = "application/json"
        case .download:
            body = Data(repeating: 0x41, count: 4_096)
            contentType = "audio/mpeg"
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        if phase == .download { Self.state.sentDownloadChunk() }
        if !hold { client?.urlProtocolDidFinishLoading(self) }
    }

    override func stopLoading() {
        if let phase { Self.state.didStop(phase) }
    }
}

@Suite("Cloud audio cancellation", .serialized, .redirectedConversationStore)
struct CloudAudioCancellationTests {
    @MainActor private func model(directory: URL) throws -> AppModel {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudAudioStubProtocol.self]
        let runtime = CloudAudioRuntime(
            session: URLSession(configuration: configuration),
            artifactSessionConfiguration: configuration
        )
        var settings = Settings()
        settings.voiceOutputDirectory = directory.path
        let model = AppModel(cloudAudioRuntime: runtime, settings: settings)
        var credentials = CloudCredentials()
        credentials.set("test-key", for: .gmi)
        model.cloudCredentials = credentials
        model.selectedVoiceModel = try #require(
            VoiceCatalog.cloudEntries(for: .gmi, kind: .speak).first?.id
        )
        model.voiceText = "Please say hello"
        return model
    }

    @MainActor private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test(arguments: CloudAudioPhase.allCases)
    @MainActor func cancelStopsEachNetworkPhaseAndAllowsRetry(
        phase: CloudAudioPhase
    ) async throws {
        CloudAudioStubState.shared.reset(holding: phase)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloud-audio-cancel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try model(directory: directory)

        model.speak()
        let reachedPhase = await waitUntil { CloudAudioStubState.shared.hasStarted(phase) }
        #expect(reachedPhase, "The request should reach \(phase.rawValue) before cancellation")
        model.cancelVoice()
        #expect(await waitUntil { !model.isSpeaking })
        #expect(CloudAudioStubState.shared.hasStopped(phase))
        #expect(model.speechResults.isEmpty)
        #expect(model.voiceError == "Cancelled.")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        #expect(leftovers.isEmpty, "Cancelled downloads must not leave partial or published audio")

        // A delayed signal to the old actor job must not poison a new request.
        CloudAudioStubState.shared.reset(holding: nil)
        model.speak()
        #expect(await waitUntil { !model.isSpeaking && model.speechResults.count == 1 })
        #expect(model.voiceError == nil)
        #expect(model.speechResults.count == 1)
        if let audio = model.speechResults.first?.audio {
            #expect(FileManager.default.fileExists(atPath: audio.path))
        }
        #expect(CloudAudioStubState.shared.count(.download) == 1)
    }

    @Test @MainActor func cancellingAnOlderOverlappingJobLeavesTheNewerOneAlone() async throws {
        CloudAudioStubState.shared.enableOverlappingReplies()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudAudioStubProtocol.self]
        let runtime = CloudAudioRuntime(
            session: URLSession(configuration: configuration),
            artifactSessionConfiguration: configuration
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloud-audio-overlap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = try #require(CloudProvider.gmi.jobsBaseURL)
        let firstID = UUID()
        let first = Task {
            try await runtime.generate(
                CloudAudioRequest(model: "first", kind: .speech, text: "first",
                                  outputDirectory: directory),
                base: base, apiKey: "test-key", jobID: firstID, onProgress: { _ in }
            )
        }
        #expect(await waitUntil { CloudAudioStubState.shared.pollCount("job-1") == 1 })

        let second = Task {
            try await runtime.generate(
                CloudAudioRequest(model: "second", kind: .speech, text: "second",
                                  outputDirectory: directory),
                base: base, apiKey: "test-key", jobID: UUID(), onProgress: { _ in }
            )
        }
        #expect(await waitUntil { CloudAudioStubState.shared.pollCount("job-2") == 1 })
        await runtime.cancel(jobID: firstID)
        let newer = try await second.value
        #expect(FileManager.default.fileExists(atPath: newer.audio.path))
        do {
            _ = try await first.value
            Issue.record("The older job should be cancelled without publishing an artifact")
        } catch CloudAudioError.cancelled {
            // Expected: cancellation is scoped to the older identifier.
        } catch {
            Issue.record("Expected a cancellation error, received \(error)")
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(files == [newer.audio.lastPathComponent])
    }
}
