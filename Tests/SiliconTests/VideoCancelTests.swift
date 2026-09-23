import Foundation
import Testing
import SiliconControl
@testable import SiliconRuntime
@testable import SiliconUI

/// A node that renders one job and answers `POST /v1/jobs/{id}/cancel` however the test says.
private final class CancelNodeState: @unchecked Sendable {
    enum CancelAnswer { case body(Int, String), dropConnection }
    private let lock = NSLock()
    private var requests: [String] = []
    private var jobStatus = "running"
    private var answer = CancelAnswer.body(200, #"{"cancel":"cancelled","status":"cancelled","detail":"Cancelled; the renderer was stopped."}"#)
    private var statusAfterCancel: String?

    func reset(jobStatus: String = "running", answer: CancelAnswer, statusAfterCancel: String? = nil) {
        lock.withLock {
            requests = []; self.jobStatus = jobStatus; self.answer = answer
            self.statusAfterCancel = statusAfterCancel
        }
    }
    func setJobStatus(_ status: String) { lock.withLock { jobStatus = status } }
    func calls() -> [String] { lock.withLock { requests } }

    func response(to request: URLRequest) -> (Int, Data)? {
        lock.withLock {
            let path = request.url!.path
            requests.append("\(request.httpMethod ?? "GET") \(path)")
            if request.httpMethod == "POST", path == "/v1/text-to-video" {
                return (202, Data(#"{"job_id":"job-1"}"#.utf8))
            }
            if request.httpMethod == "POST", path.hasSuffix("/cancel") {
                if let next = statusAfterCancel { jobStatus = next }
                switch answer {
                case .dropConnection: return nil
                case .body(let code, let body): return (code, Data(body.utf8))
                }
            }
            if path.hasSuffix(".mp4") { return (200, Data("clip bytes".utf8)) }
            switch jobStatus {
            case "done": return (200, Data(#"{"status":"done","artifact":"/v1/artifacts/job-1.mp4"}"#.utf8))
            case "cancelled":
                return (200, Data(#"{"status":"cancelled","cancel":{"state":"cancelled","detail":"Cancelled; the renderer was stopped."}}"#.utf8))
            default: return (200, Data(#"{"status":"running","stage":"rendering motion on Apple GPU","progress":0.3}"#.utf8))
            }
        }
    }
}

private final class CancelNodeProtocol: URLProtocol, @unchecked Sendable {
    static let state = CancelNodeState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let (code, data) = Self.state.response(to: request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        let contentType = request.url!.path.hasSuffix(".mp4") ? "video/mp4" : "application/json"
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("Video render cancellation", .serialized, .redirectedConversationStore)
@MainActor
struct VideoCancelTests {
    private static let base = URL(string: "http://cancel.test")!
    private static let cancelled = CancelNodeState.CancelAnswer.body(
        200, #"{"cancel":"cancelled","status":"cancelled","detail":"Cancelled; the renderer was stopped."}"#
    )

    private func runtime() -> NodeVideoRuntime {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CancelNodeProtocol.self]
        return NodeVideoRuntime(session: URLSession(configuration: configuration), pollInterval: .milliseconds(20))
    }

    private func template() -> VideoRequest {
        VideoRequest(entryID: "ltx2-distilled", prompt: "A shot", seconds: 5, resolution: "720p",
                     outputDirectory: FileManager.default.temporaryDirectory
                        .appendingPathComponent("video-cancel-test-\(UUID())"))
    }

    private func peer(actions: [String]) -> AppModel.PeerStatus {
        AppModel.PeerStatus(name: "fixture", baseURL: Self.base.absoluteString, reachable: true,
                            capabilities: [.init(id: "ltx2-distilled", kind: "video", ready: true,
                                                 supportedJobActions: actions)])
    }

    /// A clip the node accepted and the app is not following any more (Stop following, or
    /// a lost connection): exactly the state a relaunch or a reconnect starts from.
    private func acceptedQueue(_ request: VideoRequest) throws -> (VideoBatchQueue, VideoQueueItem) {
        let queue = VideoBatchQueue(storeURL: request.outputDirectory.appendingPathComponent("queue.json"))
        let item = try queue.enqueueSingle(request)
        try queue.begin(item.id, nodeName: "fixture", nodeURL: Self.base)
        try queue.accepted(item.id, job: .init(id: "job-1"))
        try queue.fail(item.id, message: "Stopped following.")
        return (queue, try #require(queue.items.first))
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw VideoRuntimeError.failed("Test deadline") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func aNodeThatDoesNotAdvertiseCancelLeavesOnlyStopFollowing() async throws {
        CancelNodeProtocol.state.reset(answer: Self.cancelled)
        let request = template()
        defer { try? FileManager.default.removeItem(at: request.outputDirectory) }
        let (queue, item) = try acceptedQueue(request)
        let model = AppModel(videoQueue: queue, videoRuntime: runtime(), settings: .init())
        // An older node (silicon-node today) advertises no job actions; the lane alone is not enough.
        #expect(!AppModel.canCancelVideo(item, among: [peer(actions: [])]))
        #expect(AppModel.canCancelVideo(item, among: [peer(actions: ["cancel"])]))
        let elsewhere = AppModel.PeerStatus(name: "fixture", baseURL: "http://other.test", reachable: true,
                                            capabilities: peer(actions: ["cancel"]).capabilities)
        #expect(!AppModel.canCancelVideo(item, among: [elsewhere]), "only the node holding the receipt")
        do {
            _ = try await model.controlVideoQueue(.init(action: "cancel", id: item.id))
            Issue.record("An unadvertised cancel must be refused")
        } catch { #expect(error.localizedDescription.contains("stop_following")) }
        #expect(CancelNodeProtocol.state.calls().isEmpty)
        #expect(queue.items[0].cancel == nil && queue.items[0].canReconnect)
        #expect(await model.videoQueue().items[0].canCancel == false)
    }

    @Test func cancellingTheFollowedRenderEndsCancelledAndTheQueueMovesOn() async throws {
        CancelNodeProtocol.state.reset(answer: Self.cancelled, statusAfterCancel: "cancelled")
        let request = template()
        defer { try? FileManager.default.removeItem(at: request.outputDirectory) }
        let queue = VideoBatchQueue(storeURL: request.outputDirectory.appendingPathComponent("queue.json"))
        let first = try queue.enqueueSingle(request)
        let second = try queue.enqueueSingle(request)
        let model = AppModel(videoQueue: queue, videoRuntime: runtime(), settings: .init())
        let node = peer(actions: ["cancel"])
        // A synchronous control caller waiting on this clip is told, not left to time out.
        let waiter = Task { try await model.waitForQueuedVideo(first.id, timeout: 10) }
        let render = Task { await model.processNextQueuedVideo(peers: [node]) }
        try await waitUntil { queue.items[0].status == .rendering && model.activeVideoQueueID == first.id }
        let message = try await model.cancelVideoRender(first.id, peers: [node])
        #expect(message.contains("stopped this render"))
        await render.value
        do {
            _ = try await waiter.value
            Issue.record("A cancelled clip has no file to return")
        } catch { #expect(error.localizedDescription.contains("cancelled")) }
        #expect(queue.items[0].status == .cancelled)
        #expect(queue.items[0].cancel?.state == .confirmed)
        #expect(queue.items[0].nodeJob?.id == "job-1" && queue.items[0].file == nil)
        #expect(!queue.isPaused && queue.next?.id == second.id)
        #expect(CancelNodeProtocol.state.calls().filter { $0.hasPrefix("POST") }
                == ["POST /v1/text-to-video", "POST /v1/jobs/job-1/cancel"])
        // Terminal, and not re-dispatched after a relaunch.
        let restored = VideoBatchQueue(storeURL: queue.storeURL)
        #expect(restored.items[0].status == .cancelled && restored.next?.id == second.id)
        // Rendering it again is a deliberate new job, never the old receipt.
        try queue.retry(first.id)
        #expect(queue.items[0].status == .pending && queue.items[0].attempt == 2)
        #expect(queue.items[0].previousNodeJobs == ["job-1"] && queue.items[0].cancel == nil)
    }

    @Test func aRequestedCancelIsFollowedUntilTheNodeSaysHowItEnded() async throws {
        for ending in ["cancelled", "done"] {
            CancelNodeProtocol.state.reset(answer: .body(202, #"{"cancel":"requested","status":"running"}"#))
            let request = template()
            defer { try? FileManager.default.removeItem(at: request.outputDirectory) }
            let (queue, item) = try acceptedQueue(request)
            let model = AppModel(videoQueue: queue, videoRuntime: runtime(), settings: .init())
            let node = peer(actions: ["cancel"])
            _ = try await model.cancelVideoRender(item.id, peers: [node])
            // Accepted but not confirmed: follow the same job again, never submit.
            #expect(queue.items[0].cancel?.state == .requested)
            #expect(queue.items[0].status == .rendering && queue.items[0].nodeJob?.id == "job-1")
            // Across a relaunch the distinction survives.
            let relaunched = VideoBatchQueue(storeURL: queue.storeURL)
            #expect(relaunched.items[0].cancel?.state == .requested && relaunched.next?.id == item.id)
            CancelNodeProtocol.state.setJobStatus(ending)
            let later = AppModel(videoQueue: relaunched, videoRuntime: runtime(), settings: .init())
            await later.processNextQueuedVideo(peers: [node])
            if ending == "cancelled" {
                #expect(relaunched.items[0].status == .cancelled && relaunched.items[0].cancel?.state == .confirmed)
            } else {
                // Completion won the race: the clip is kept and says so.
                #expect(relaunched.items[0].status == .completed && relaunched.items[0].file != nil)
                #expect(relaunched.items[0].cancel?.state == .completed)
            }
            #expect(!CancelNodeProtocol.state.calls().contains("POST /v1/text-to-video"))
        }
    }

    @Test func aFailedOrRefusedCancelKeepsTheReceiptAndNeverRendersAgain() async throws {
        let answers: [(CancelNodeState.CancelAnswer, VideoCancelRecord.State)] = [
            (.dropConnection, .unknown),
            (.body(409, #"{"cancel":"unsupported","status":"running","detail":"Phosphene has already started this render."}"#), .unsupported),
            (.body(404, #"{"cancel":"unknown","status":"unknown","detail":"This node has no job with that ID."}"#), .unknown),
            // silicon-node's existing job action answers without a `cancel` field.
            (.body(200, #"{"ok":true}"#), .unknown),
        ]
        for (answer, expected) in answers {
            CancelNodeProtocol.state.reset(answer: answer)
            let request = template()
            defer { try? FileManager.default.removeItem(at: request.outputDirectory) }
            let (queue, item) = try acceptedQueue(request)
            let model = AppModel(videoQueue: queue, videoRuntime: runtime(), settings: .init())
            let node = peer(actions: ["cancel"])
            let message = try await model.cancelVideoRender(item.id, peers: [node])
            #expect(queue.items[0].cancel?.state == expected, "\(answer)")
            #expect(queue.items[0].status == .failed && queue.items[0].canReconnect)
            #expect(queue.items[0].nodeJob?.id == "job-1" && queue.items[0].attempt == 1)
            #expect(message.contains("may still be running") || message.contains("keeps rendering"))
            // Retrying reconnects to the same job; it cannot create a second render.
            try queue.retry(item.id)
            #expect(queue.items[0].status == .rendering && queue.items[0].previousNodeJobs.isEmpty)
            #expect(!CancelNodeProtocol.state.calls().contains("POST /v1/text-to-video"))
            // An unanswered cancel may be asked again; it is idempotent on the node.
            #expect(AppModel.canCancelVideo(queue.items[0], among: [node]))
        }
    }

    @Test func aCancelThatArrivesAfterCompletionKeepsTheClip() async throws {
        CancelNodeProtocol.state.reset(
            jobStatus: "done",
            answer: .body(409, #"{"cancel":"completed","status":"done","detail":"The render had already finished; its artifact is kept."}"#)
        )
        let request = template()
        defer { try? FileManager.default.removeItem(at: request.outputDirectory) }
        let (queue, item) = try acceptedQueue(request)
        let model = AppModel(videoQueue: queue, videoRuntime: runtime(), settings: .init())
        let node = peer(actions: ["cancel"])
        let message = try await model.cancelVideoRender(item.id, peers: [node])
        #expect(message.contains("Too late"))
        #expect(queue.items[0].cancel?.state == .completed && queue.items[0].canReconnect)
        #expect(!AppModel.canCancelVideo(queue.items[0], among: [node]))
        try queue.retry(item.id)
        await model.processNextQueuedVideo(peers: [node])
        #expect(queue.items[0].status == .completed && queue.items[0].file != nil)
        #expect(!CancelNodeProtocol.state.calls().contains("POST /v1/text-to-video"))
    }

    @Test func aCancelInterruptedByARelaunchIsUnknownNotConfirmed() throws {
        let request = template()
        defer { try? FileManager.default.removeItem(at: request.outputDirectory) }
        let (queue, item) = try acceptedQueue(request)
        try queue.beginCancel(item.id)
        #expect(queue.items[0].cancel?.state == .sending)
        let relaunched = VideoBatchQueue(storeURL: queue.storeURL)
        #expect(relaunched.items[0].cancel?.state == .unknown)
        #expect(relaunched.items[0].canReconnect && relaunched.items[0].nodeJob?.id == "job-1")
        // Only confirmed cancels leave with finished history.
        try relaunched.cancelled(item.id, detail: nil)
        try relaunched.clearFinished()
        #expect(relaunched.items.isEmpty)
    }

    @Test func theNodeAnswerIsReadFromItsCancelFieldAlone() async throws {
        let job = VideoNodeJob(id: "job-1")
        let cases: [(CancelNodeState.CancelAnswer, VideoCancelOutcome)] = [
            (Self.cancelled, .cancelled("Cancelled; the renderer was stopped.")),
            (.body(202, #"{"cancel":"requested"}"#), .requested(nil)),
            (.body(409, #"{"cancel":"failed","detail":"oom"}"#), .alreadyFailed("oom")),
            (.body(500, "Internal Server Error"), .unknown("The node did not confirm the cancel: Internal Server Error")),
        ]
        for (answer, expected) in cases {
            CancelNodeProtocol.state.reset(answer: answer)
            #expect(await runtime().cancelJob(job, node: Self.base, token: nil) == expected)
            #expect(CancelNodeProtocol.state.calls() == ["POST /v1/jobs/job-1/cancel"])
        }
        // A job ID that is not a single path segment is never sent anywhere.
        CancelNodeProtocol.state.reset(answer: Self.cancelled)
        #expect(await runtime().cancelJob(.init(id: "../stop"), node: Self.base, token: nil)
                == .unknown("The saved job ID cannot be sent to the node."))
        #expect(CancelNodeProtocol.state.calls().isEmpty)
    }
}
