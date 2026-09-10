import Foundation
import Testing
import SiliconControl
@testable import SiliconRuntime
@testable import SiliconUI

private final class QueueHTTPState: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [String] = []
    private var receiptSaved = false
    private var code = 200
    private var terminalFailure = false

    func reset(code: Int = 200, failure: Bool = false) {
        lock.withLock { requests = []; receiptSaved = false; self.code = code; terminalFailure = failure }
    }
    func saved() { lock.withLock { receiptSaved = true } }
    func calls() -> [String] { lock.withLock { requests } }
    func response(to request: URLRequest) -> (Int, Data) {
        lock.withLock {
            let path = request.url!.path
            requests.append("\(request.httpMethod ?? "GET") \(path)")
            if request.httpMethod == "POST" { return (202, Data(#"{"job_id":"original-job"}"#.utf8)) }
            if path.hasSuffix(".mp4") { return (200, Data("downloaded clip bytes".utf8)) }
            if requests.contains(where: { $0.hasPrefix("POST") }) && !receiptSaved {
                return (200, Data(#"{"status":"failed","error":"poll happened before receipt persistence"}"#.utf8))
            }
            if terminalFailure { return (200, Data(#"{"status":"failed","error":"renderer failed"}"#.utf8)) }
            if code != 200 { return (code, Data(#"{"error":"Job missing or credentials refused"}"#.utf8)) }
            return (code, Data(#"{"status":"done","files":["/artifacts/clip.mp4"]}"#.utf8))
        }
    }
}

private final class QueueHTTPProtocol: URLProtocol, @unchecked Sendable {
    static let state = QueueHTTPState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (code, data) = Self.state.response(to: request)
        let contentType = request.url!.path.hasSuffix(".mp4") ? "video/mp4" : "application/json"
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("Video queue node recovery", .serialized)
struct VideoQueueRuntimeTests {
    private func runtime() -> NodeVideoRuntime {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [QueueHTTPProtocol.self]
        return NodeVideoRuntime(session: URLSession(configuration: configuration))
    }
    private func request() -> VideoRequest {
        VideoRequest(entryID: "hailuo-h3", prompt: "A shot", seconds: 10, resolution: "480p",
                     outputDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("video-recovery-test-\(UUID())"),
                     seed: 42, h3Turbo: false, clientID: "client-job")
    }

    @Test func saveReceiptBeforePollingANewJob() async throws {
        QueueHTTPProtocol.state.reset()
        let request = request()
        defer { try? FileManager.default.removeItem(at: request.outputDirectory) }
        let result = try await runtime().generate(request, node: URL(string: "http://queue.test")!, token: nil,
                                                  onSubmitted: { receipt in
            #expect(receipt.id == "original-job")
            QueueHTTPProtocol.state.saved()
        }, onProgress: { _ in })
        #expect(FileManager.default.fileExists(atPath: result.file.path))
        #expect(QueueHTTPProtocol.state.calls() == ["POST /v1/text-to-video", "GET /v1/jobs/original-job", "GET /artifacts/clip.mp4"])
    }

    @Test func oldCompletedJobDownloadsWithoutAnyNewPost() async throws {
        QueueHTTPProtocol.state.reset()
        let request = request()
        defer { try? FileManager.default.removeItem(at: request.outputDirectory) }
        let result = try await runtime().generate(request, node: URL(string: "http://queue.test")!, token: nil,
                                                  resuming: .init(id: "saved-job", submittedAt: .distantPast),
                                                  onSubmitted: { _ in Issue.record("A resumed job must never submit again") },
                                                  onProgress: { _ in })
        #expect(QueueHTTPProtocol.state.calls() == ["GET /v1/jobs/saved-job", "GET /artifacts/clip.mp4"])
        #expect(try Data(contentsOf: result.file) == Data("downloaded clip bytes".utf8))
    }

    @Test func confirmedNodeFailureIsNotAnUncertainNetworkFailure() async throws {
        QueueHTTPProtocol.state.reset(failure: true)
        await #expect(throws: VideoNodeFailed.self) {
            try await runtime().generate(request(), node: URL(string: "http://queue.test")!, token: nil,
                                         resuming: .init(id: "failed-job"), onProgress: { _ in })
        }
    }

    @Test(arguments: [401, 403, 404]) func missingJobOrCredentialsStopWithoutWaitingTwelveHours(code: Int) async throws {
        QueueHTTPProtocol.state.reset(code: code)
        await #expect(throws: VideoRuntimeError.self) {
            try await runtime().generate(request(), node: URL(string: "http://queue.test")!, token: nil,
                                         resuming: .init(id: "missing-job"), onProgress: { _ in })
        }
        #expect(QueueHTTPProtocol.state.calls().count == 1)
    }

    @Test func failedReceiptPersistenceStopsBeforePolling() async throws {
        QueueHTTPProtocol.state.reset()
        await #expect(throws: CocoaError.self) {
            try await runtime().generate(request(), node: URL(string: "http://queue.test")!, token: nil,
                                         onSubmitted: { _ in throw CocoaError(.fileWriteOutOfSpace) }, onProgress: { _ in })
        }
        #expect(QueueHTTPProtocol.state.calls() == ["POST /v1/text-to-video"])
    }

    @Test @MainActor func applicationDrainsVariationsSeriallyIntoTheirBatchFolder() async throws {
        QueueHTTPProtocol.state.reset()
        // The mock's persistence ordering assertion is independently exercised above.
        QueueHTTPProtocol.state.saved()
        let template = request()
        defer { try? FileManager.default.removeItem(at: template.outputDirectory) }
        let queue = VideoBatchQueue(storeURL: template.outputDirectory.appendingPathComponent("queue.json"))
        try queue.enqueue(prompts: ["A honey badger sails."], variations: 2, title: "Test movie", template: template, baseSeed: 91)
        let model = AppModel(videoQueue: queue, videoRuntime: runtime(), settings: .init())
        let peer = AppModel.PeerStatus(name: "fixture", baseURL: "http://queue.test", reachable: true,
                                      capabilities: [.init(id: "hailuo-h3", kind: "video", ready: true,
                                                           supportedParameters: ["seed", "h3_turbo"])])
        await model.processNextQueuedVideo(peers: [peer])
        #expect(queue.items.map(\.status) == [.completed, .pending])
        await model.processNextQueuedVideo(peers: [peer])
        #expect(queue.items.map(\.status) == [.completed, .completed])
        #expect(model.videoResults.count == 2)
        #expect(QueueHTTPProtocol.state.calls().filter { $0.hasPrefix("POST") }.count == 2)
        #expect(queue.items[0].request.seed == 91 && queue.items[1].request.seed == 92)
        #expect(queue.items[0].file != queue.items[1].file)
        #expect(queue.items.allSatisfy { item in
            item.file.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        })
        #expect(!model.isGeneratingVideo && model.activeVideoQueueID == nil)
        let restored = VideoBatchQueue(storeURL: queue.storeURL)
        #expect(restored.next == nil)
    }

    @Test @MainActor func olderNodeCannotSilentlyIgnoreSamplingControls() async throws {
        QueueHTTPProtocol.state.reset()
        let template = request()
        defer { try? FileManager.default.removeItem(at: template.outputDirectory) }
        let queue = VideoBatchQueue(storeURL: template.outputDirectory.appendingPathComponent("queue.json"))
        try queue.enqueue(prompts: ["A shot"], variations: 1, title: "", template: template)
        let model = AppModel(videoQueue: queue, videoRuntime: runtime(), settings: .init())
        let peer = AppModel.PeerStatus(name: "old-node", baseURL: "http://queue.test", reachable: true,
                                      capabilities: [.init(id: "hailuo-h3", kind: "video", ready: true)])
        await model.processNextQueuedVideo(peers: [peer])
        #expect(QueueHTTPProtocol.state.calls().isEmpty)
        #expect(queue.next?.status == .pending)
        #expect(model.videoQueueMessage?.contains("does not advertise") == true)
    }

    @Test @MainActor func unwritableBatchFolderDoesNotStartAGPURender() async throws {
        QueueHTTPProtocol.state.reset()
        var template = request()
        let root = template.outputDirectory
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let notADirectory = root.appendingPathComponent("not-a-directory")
        try Data("fixture".utf8).write(to: notADirectory)
        template.outputDirectory = notADirectory
        let queue = VideoBatchQueue(storeURL: root.appendingPathComponent("queue.json"))
        try queue.enqueue(prompts: ["A shot"], variations: 1, title: "", template: template)
        let model = AppModel(videoQueue: queue, videoRuntime: runtime(), settings: .init())
        let peer = AppModel.PeerStatus(name: "fixture", baseURL: "http://queue.test", reachable: true,
                                      capabilities: [.init(id: "hailuo-h3", kind: "video", ready: true,
                                                           supportedParameters: ["h3_turbo"])])
        await model.processNextQueuedVideo(peers: [peer])
        #expect(QueueHTTPProtocol.state.calls().isEmpty)
        #expect(queue.isPaused && queue.items.first?.status == .pending)
        #expect(model.videoQueueMessage?.contains("Cannot write the batch folder") == true)
    }

    @Test @MainActor func singleComposerRemainsUsableDuringRenderingAndPreservesPausedQueue() throws {
        QueueHTTPProtocol.state.reset()
        let template = request()
        defer { try? FileManager.default.removeItem(at: template.outputDirectory) }
        let queue = VideoBatchQueue(storeURL: template.outputDirectory.appendingPathComponent("queue.json"))
        try queue.setPaused(true)
        var settings = Settings()
        settings.videoOutputDirectory = template.outputDirectory.path
        let model = AppModel(videoQueue: queue, videoRuntime: runtime(), settings: settings)
        defer { model.videoQueueTask?.cancel() }
        model.selectedVideoModel = "hailuo-h3"
        model.videoSeconds = 15
        model.videoResolution = "720p"
        model.videoSampling = .full
        model.isGeneratingVideo = true
        model.activeVideoQueueID = "already-rendering"
        model.videoStage = "Denoising"
        model.videoProgress = 0.5
        model.videoPrompt = "A honey badger learns about chips."
        model.generateVideo()
        #expect(queue.items.count == 1)
        #expect(model.videoPrompt.isEmpty && model.videoError == nil)
        #expect(model.settings.expandedVideoPanels.contains(VideoPanel.queue.rawValue))
        #expect(model.isGeneratingVideo && model.activeVideoQueueID == "already-rendering")
        #expect(model.videoStage == "Denoising" && model.videoProgress == 0.5)
        model.videoPrompt = "A second clip"
        model.videoSeconds = 10
        model.videoResolution = "480p"
        model.videoSampling = .turbo
        model.generateVideo()
        #expect(queue.items.count == 2)
        #expect(queue.items[0].request.seconds == 15 && queue.items[0].request.h3Turbo == false)
        #expect(queue.items[1].request.seconds == 10 && queue.items[1].request.h3Turbo == true)
        #expect(queue.isPaused && queue.next == nil)
        #expect(QueueHTTPProtocol.state.calls().isEmpty)
    }

    @Test @MainActor func failedSingleEnqueueKeepsTheDraftAndDoesNotStartTheWorker() throws {
        let template = request()
        defer { try? FileManager.default.removeItem(at: template.outputDirectory) }
        let queue = VideoBatchQueue(storeURL: template.outputDirectory.appendingPathComponent("queue.json"),
                                    persist: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
        var settings = Settings()
        settings.videoOutputDirectory = template.outputDirectory.path
        let model = AppModel(videoQueue: queue, videoRuntime: runtime(), settings: settings)
        model.selectedVideoModel = "hailuo-h3"
        model.videoPrompt = "Keep this draft"
        model.generateVideo()
        #expect(model.videoPrompt == "Keep this draft")
        #expect(model.videoError != nil && queue.items.isEmpty && model.videoQueueTask == nil)
        #expect(!model.isGeneratingVideo)
    }

    @Test @MainActor func controlWaitReturnsQueuedFileAfterSerialDispatch() async throws {
        QueueHTTPProtocol.state.reset()
        QueueHTTPProtocol.state.saved()
        let template = request()
        defer { try? FileManager.default.removeItem(at: template.outputDirectory) }
        let queue = VideoBatchQueue(storeURL: template.outputDirectory.appendingPathComponent("queue.json"))
        try queue.enqueue(prompts: ["first batch clip"], variations: 1, title: "Movie", template: template)
        let model = AppModel(videoQueue: queue, videoRuntime: runtime(), settings: .init())
        let single = try model.enqueueSingleVideo(template)
        // Drive the real worker with a mock peer without reading or changing the user's swarm.
        model.videoQueueTask?.cancel()
        let waiter = Task { try await model.waitForQueuedVideo(single.id, timeout: 10) }
        let peer = AppModel.PeerStatus(name: "fixture", baseURL: "http://queue.test", reachable: true,
                                      capabilities: [.init(id: "hailuo-h3", kind: "video", ready: true,
                                                           supportedParameters: ["seed", "h3_turbo"])])
        await model.processNextQueuedVideo(peers: [peer])
        #expect(queue.items.map(\.status) == [.completed, .pending])
        await model.processNextQueuedVideo(peers: [peer])
        let response = try await waiter.value
        #expect(response.file == queue.items.last?.file?.path)
        #expect(response.model == "hailuo-h3" && response.node == "fixture")
        #expect(queue.items.map(\.status) == [.completed, .completed])
        #expect(QueueHTTPProtocol.state.calls().filter { $0.hasPrefix("POST") }.count == 2)
    }

    @Test @MainActor func stoppedControlWaitsLeaveSavedClipsIntact() async throws {
        let template = request()
        defer { try? FileManager.default.removeItem(at: template.outputDirectory) }
        let queue = VideoBatchQueue(storeURL: template.outputDirectory.appendingPathComponent("queue.json"))
        let single = try queue.enqueueSingle(template)
        let model = AppModel(videoQueue: queue, videoRuntime: runtime(), settings: .init())
        do {
            _ = try await model.waitForQueuedVideo(single.id, timeout: 0)
            Issue.record("A bounded wait must expire")
        } catch {
            #expect(error.localizedDescription.contains(single.id))
            #expect(error.localizedDescription.contains("before submitting again"))
        }
        try queue.setPaused(true)
        do {
            _ = try await model.waitForQueuedVideo(single.id)
            Issue.record("A paused pending clip must not hang a synchronous caller")
        } catch { #expect(error.localizedDescription.contains("paused queue")) }
        #expect(queue.items.first?.status == .pending && queue.items.first?.nodeJob == nil)
        #expect(queue.isPaused)
    }
}
