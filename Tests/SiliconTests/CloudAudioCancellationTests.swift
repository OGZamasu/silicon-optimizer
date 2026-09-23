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
    private var overlappingReplies = false
    private var pollsByID: [String: Int] = [:]
    private var artifactOrigin = "https://cdn.example.com"

    /// `artifactOrigin` is the TLS fixture's: audio downloads go through the resolved-address
    /// transport, not URLSession, so this stub answers only submission and polling.
    func reset(holding phase: CloudAudioPhase?, artifactOrigin: String) {
        lock.withLock {
            heldPhase = phase
            started = [:]
            stopped = [:]
            overlappingReplies = false
            pollsByID = [:]
            self.artifactOrigin = artifactOrigin
        }
    }

    func enableOverlappingReplies(artifactOrigin: String) {
        reset(holding: nil, artifactOrigin: artifactOrigin)
        lock.withLock { overlappingReplies = true }
    }

    /// The fixture stalls mid-body on `/stall`, which is how a download is held.
    func artifactURL() -> String {
        lock.withLock { artifactOrigin + (heldPhase == .download ? "/stall" : "/audio") }
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

    func hasStarted(_ phase: CloudAudioPhase) -> Bool {
        lock.withLock { (started[phase] ?? 0) > 0 }
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
        let phase: CloudAudioPhase = request.httpMethod == "POST" ? .submit : .poll
        self.phase = phase
        if Self.state.didStart(phase, url: request.url) { return }

        let body: Data
        switch phase {
        case .submit:
            let id = Self.state.usesOverlappingReplies()
                ? "job-\(Self.state.count(.submit))" : "job-1"
            body = Data("{\"request_id\":\"\(id)\"}".utf8)
        case .poll, .download:
            if Self.state.usesOverlappingReplies(),
               request.url?.lastPathComponent == "job-1",
               Self.state.pollCount("job-1") == 1 {
                body = Data(#"{"status":"queued"}"#.utf8)
            } else {
                body = Data(
                    #"{"status":"success","outcome":{"audio_url":"\#(Self.state.artifactURL())"}}"#
                        .utf8
                )
            }
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        if let phase { Self.state.didStop(phase) }
    }
}

@Suite(
    "Cloud audio cancellation", .serialized, .redirectedConversationStore,
    // Every wait in here has its own deadline; this bounds one that regresses into a hang.
    .timeLimit(.minutes(2))
)
struct CloudAudioCancellationTests {
    /// The runtime the app would build, except that the provider is a URLProtocol stub and
    /// the artifact host is the local TLS fixture reached through the real transport.
    private func runtime(_ server: FixtureTLSHTTPServer) -> CloudAudioRuntime {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudAudioStubProtocol.self]
        return CloudAudioRuntime(
            session: URLSession(configuration: configuration),
            artifactDownload: { url, destination, maximumBytes, budget, timeout in
                _ = CloudAudioStubState.shared.didStart(.download, url: url)
                defer { CloudAudioStubState.shared.didStop(.download) }
                return try await PublicHTTPSArtifactTransfer.download(
                    from: url, to: destination, maximumBytes: maximumBytes, budget: budget,
                    timeout: timeout, proxyCheck: { _ in }, onNetworkAttempt: {},
                    makeJob: server.hopJobs
                )
            }
        )
    }

    @MainActor private func model(
        directory: URL, server: FixtureTLSHTTPServer
    ) throws -> AppModel {
        var settings = Settings()
        settings.voiceOutputDirectory = directory.path
        let model = AppModel(cloudAudioRuntime: runtime(server), settings: settings)
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

    /// Reached means in flight: a held request for the provider phases, and body bytes in
    /// the transfer's partial file for the download.
    private func reached(_ phase: CloudAudioPhase, in directory: URL) -> Bool {
        phase == .download
            ? partialBytes(in: directory) >= 4_096
            : CloudAudioStubState.shared.hasStarted(phase)
    }

    @Test(arguments: CloudAudioPhase.allCases)
    @MainActor func cancelStopsEachNetworkPhaseAndAllowsRetry(
        phase: CloudAudioPhase
    ) async throws {
        let server = try FixtureTLSHTTPServer()
        let origin = "https://cdn.example.com:\(server.port)"
        CloudAudioStubState.shared.reset(holding: phase, artifactOrigin: origin)
        let directory = server.directory.appendingPathComponent("voice")
        let model = try model(directory: directory, server: server)

        model.speak()
        let reachedPhase = await pollUntil { reached(phase, in: directory) }
        #expect(reachedPhase, "The request should reach \(phase.rawValue) before cancellation")
        let cancelled = ContinuousClock.now
        model.cancelVoice()
        #expect(await waitUntil { !model.isSpeaking })
        // The fixture holds a download for 30 seconds; stopping well inside that is the
        // transfer being cut short rather than finished and thrown away.
        #expect(ContinuousClock.now - cancelled < .seconds(5))
        #expect(await pollUntil { CloudAudioStubState.shared.hasStopped(phase) })
        #expect(model.speechResults.isEmpty)
        #expect(model.voiceError == "Cancelled.")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        #expect(leftovers.isEmpty, "Cancelled downloads must not leave partial or published audio")

        // A delayed signal to the old actor job must not poison a new request.
        CloudAudioStubState.shared.reset(holding: nil, artifactOrigin: origin)
        model.speak()
        #expect(await waitUntil { !model.isSpeaking && model.speechResults.count == 1 })
        #expect(model.voiceError == nil)
        #expect(model.speechResults.count == 1)
        if let audio = model.speechResults.first?.audio {
            #expect(try Data(contentsOf: audio) == Data("audio".utf8))
        }
        #expect(CloudAudioStubState.shared.count(.download) == 1)
    }

    /// The runtime's own signal has to stop work in flight, not just be noticed at the next
    /// checkpoint: a held request or download would otherwise run on to its timeout.
    @Test(arguments: CloudAudioPhase.allCases)
    func cancellingTheJobStopsItsWorkWithoutTheCallerBeingCancelled(
        phase: CloudAudioPhase
    ) async throws {
        let server = try FixtureTLSHTTPServer()
        CloudAudioStubState.shared.reset(
            holding: phase, artifactOrigin: "https://cdn.example.com:\(server.port)"
        )
        let runtime = runtime(server)
        let directory = server.directory.appendingPathComponent("direct")
        let base = try #require(CloudProvider.gmi.jobsBaseURL)
        let jobID = UUID()
        let job = Task {
            try await runtime.generate(
                CloudAudioRequest(model: "held", kind: .speech, text: "held",
                                  outputDirectory: directory),
                base: base, apiKey: "test-key", jobID: jobID, onProgress: { _ in }
            )
        }
        #expect(await pollUntil { reached(phase, in: directory) })

        let cancelled = ContinuousClock.now
        await runtime.cancel(jobID: jobID)
        do {
            _ = try await job.value
            Issue.record("A cancelled job must not return audio")
        } catch CloudAudioError.cancelled {
            // Expected, whichever layer stopped first.
        } catch {
            Issue.record("Expected a cancellation error, received \(error)")
        }
        #expect(ContinuousClock.now - cancelled < .seconds(5))
        #expect(await pollUntil { CloudAudioStubState.shared.hasStopped(phase) })
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        #expect(leftovers.isEmpty)
    }

    // MARK: - Cancel stops its own job, not the transcription beside it

    /// A harmless child standing in for a voice model, run through `VoiceRuntime`'s own
    /// plumbing: it reports a stage, then waits to be stopped.
    private func standIn(
        _ model: AppModel, stage: String, started: StageLatch
    ) -> Task<String, Error> {
        Task {
            try await model.voiceRuntime.run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "echo 'stage: \(stage)'; exec sleep 30"],
                onStage: { if $0 == stage { started.open() } }
            )
        }
    }

    /// Whether a task is still going after the time a wrongly aimed `terminate` needs to
    /// land and the runtime's 200 ms wait loop needs to notice.
    private func stillRunning(_ task: Task<String, Error>) async -> Bool {
        let finished = StageLatch()
        let watcher = Task { _ = try? await task.value; finished.open() }
        try? await Task.sleep(for: .seconds(1))
        watcher.cancel()
        return !finished.isOpen
    }

    @Test @MainActor func cancellingACloudJobLeavesATranscriptionRunning() async throws {
        let server = try FixtureTLSHTTPServer()
        CloudAudioStubState.shared.reset(
            holding: .poll, artifactOrigin: "https://cdn.example.com:\(server.port)"
        )
        let directory = server.directory.appendingPathComponent("voice")
        let model = try model(directory: directory, server: server)
        let transcribing = StageLatch()
        let transcription = standIn(model, stage: "transcribing", started: transcribing)
        defer { transcription.cancel() }
        #expect(await pollUntil { transcribing.isOpen })

        model.speak()
        #expect(await pollUntil { CloudAudioStubState.shared.hasStarted(.poll) })
        model.cancelVoice()
        #expect(await waitUntil { !model.isSpeaking })
        #expect(model.voiceError == "Cancelled.")
        #expect(await stillRunning(transcription), "the transcription was not the cloud job")
    }

    @Test @MainActor func cancellingALocalJobStopsItAndNotTheTranscription() async throws {
        let server = try FixtureTLSHTTPServer()
        let model = try model(directory: server.directory, server: server)
        let speaking = StageLatch()
        let transcribing = StageLatch()
        model.startLocalVoiceJob {
            _ = try await model.voiceRuntime.run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "echo 'stage: speaking'; exec sleep 30"],
                onStage: { if $0 == "speaking" { speaking.open() } }
            )
            throw VoiceRuntimeError.failed("the stand-in makes no audio")
        }
        #expect(await pollUntil { speaking.isOpen })
        // Started second, so it is the process `VoiceRuntime.cancel()` would have hit.
        let transcription = standIn(model, stage: "transcribing", started: transcribing)
        defer { transcription.cancel() }
        #expect(await pollUntil { transcribing.isOpen })

        model.cancelVoice()
        #expect(await waitUntil { !model.isSpeaking }, "the speech job itself stopped")
        #expect(model.voiceError == "Cancelled.")
        #expect(model.speechResults.isEmpty)
        #expect(await stillRunning(transcription), "the transcription was not the speech job")
    }

    @Test func cancellingAnOlderOverlappingJobLeavesTheNewerOneAlone() async throws {
        let server = try FixtureTLSHTTPServer()
        CloudAudioStubState.shared.enableOverlappingReplies(
            artifactOrigin: "https://cdn.example.com:\(server.port)"
        )
        let runtime = runtime(server)
        let directory = server.directory.appendingPathComponent("overlap")
        let base = try #require(CloudProvider.gmi.jobsBaseURL)
        let firstID = UUID()
        let first = Task {
            try await runtime.generate(
                CloudAudioRequest(model: "first", kind: .speech, text: "first",
                                  outputDirectory: directory),
                base: base, apiKey: "test-key", jobID: firstID, onProgress: { _ in }
            )
        }
        #expect(await pollUntil { CloudAudioStubState.shared.pollCount("job-1") == 1 })

        let second = Task {
            try await runtime.generate(
                CloudAudioRequest(model: "second", kind: .speech, text: "second",
                                  outputDirectory: directory),
                base: base, apiKey: "test-key", jobID: UUID(), onProgress: { _ in }
            )
        }
        #expect(await pollUntil { CloudAudioStubState.shared.pollCount("job-2") == 1 })
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

/// Opens once and stays open; read from any thread.
private final class StageLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    var isOpen: Bool { lock.withLock { opened } }
    func open() { lock.withLock { opened = true } }
}
