import Foundation
import Testing
@testable import SiliconRuntime

private struct FreeVideoReply: Sendable {
    var status = 200
    var data: Data
    var type = "application/json"
    init(_ value: [String: Any], status: Int = 200) {
        self.status = status
        self.data = try! JSONSerialization.data(withJSONObject: value)
    }
    init(data: Data, type: String) { self.data = data; self.type = type }
}

private final class FreeVideoHTTPState: @unchecked Sendable {
    static let shared = FreeVideoHTTPState()
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    private var responder: @Sendable (URLRequest) throws -> FreeVideoReply = { _ in .init([:]) }
    func reset(_ responder: @escaping @Sendable (URLRequest) throws -> FreeVideoReply) {
        lock.withLock { requests = []; self.responder = responder }
    }
    func reply(_ request: URLRequest) throws -> FreeVideoReply {
        let responder = lock.withLock { requests.append(request); return self.responder }
        return try responder(request)
    }
    var seen: [URLRequest] { lock.withLock { requests } }
}

private final class FreeVideoHTTPStub: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let reply = try FreeVideoHTTPState.shared.reply(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": reply.type])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private final class FreeVideoProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []
    func append(_ text: String) { lock.withLock { messages.append(text) } }
    var values: [String] { lock.withLock { messages } }
}

@Suite("FreeVideo native ComfyUI transport", .serialized, .timeLimit(.minutes(2)))
struct FreeVideoRuntimeTests {
    private let base = URL(string: "http://127.0.0.1:8188")!
    private var state: FreeVideoHTTPState { .shared }

    private func runtime() -> FreeVideoRuntime {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FreeVideoHTTPStub.self]
        return FreeVideoRuntime(session: URLSession(configuration: configuration), pollInterval: .milliseconds(1))
    }

    private static func ready(_ request: URLRequest, ready: Bool = true) -> FreeVideoReply? {
        switch request.url?.path {
        case "/freevideo/launcher": .init(["protocol": 1])
        case "/object_info/FreeVideoGenerate": .init(["FreeVideoGenerate": ["input": ["required": [
            "text": ["STRING"], "width": ["INT"], "height": ["INT"], "seconds": ["FLOAT"], "seed": ["INT"]]]]])
        case "/freevideo/setup": .init(["discovery": ["ready": ready, "detail": ready ? "Prepared CUDA engine" : "Install / repair required"]])
        default: nil
        }
    }

    private static func body(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            data = Data()
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                data?.append(contentsOf: bytes.prefix(count))
            }
        }
        let requiredData = try #require(data)
        return try #require(JSONSerialization.jsonObject(with: requiredData) as? [String: Any])
    }

    private static func success(id: String, node: String, name: String = "video.mp4", folder: String = "FreeVideo/date/job") -> FreeVideoReply {
        .init([id: ["status": ["completed": true, "status_str": "success"], "outputs": [node: [
            "images": [["filename": name, "subfolder": folder, "type": "output"]], "animated": [true]]]]])
    }

    private static var mp4: Data { Data([0, 0, 0, 24]) + Data("ftypisom".utf8) + Data(repeating: 0, count: 12) }

    @Test func readinessRequiresPluginNodeAndPreparedEngine() async throws {
        state.reset { request in Self.ready(request, ready: false) ?? .init([:]) }
        let status = try await runtime().check(node: base)
        #expect(!status.ready)
        #expect(status.detail == "Install / repair required")
        do {
            _ = try await runtime().submit(.init(prompt: "A wave", seed: 9), node: base)
            Issue.record("An unprepared engine must not accept a workflow")
        } catch FreeVideoError.notReady { }
        #expect(!state.seen.contains { $0.url?.path == "/prompt" })
        #expect(!state.seen.contains { $0.url?.path.contains("/setup/") == true })

        state.reset { request in
            request.url?.path == "/object_info/FreeVideoGenerate" ? .init([:]) : Self.ready(request) ?? .init([:])
        }
        await #expect(throws: FreeVideoError.self) { try await runtime().check(node: base) }
    }

    @Test func requestAndEndpointValidationHappensBeforeSending() async throws {
        state.reset { _ in .init([:]) }
        for text in ["file:///tmp/comfy", "http://name:secret@localhost:8188", "https://host/path?token=secret", "http://host/#part", "http://host/a/../b"] {
            #expect(throws: FreeVideoError.self) { try FreeVideoRuntime.validatedBaseURL(text) }
        }
        #expect(try FreeVideoRuntime.validatedBaseURL(" http://localhost:8188/comfy ").path == "/comfy")
        for request in [FreeVideoRequest(prompt: " ", seed: 1),
                        .init(prompt: "shot", width: 777, seed: 1),
                        .init(prompt: "shot", seconds: .nan, seed: 1),
                        .init(prompt: "shot", seconds: 16, seed: 1)] {
            await #expect(throws: FreeVideoError.self) { try await runtime().submit(request, node: base) }
        }
        #expect(state.seen.isEmpty)
    }

    @Test func nativeGraphPreservesSettingsAndUsesUniqueProgressIDs() async throws {
        state.reset { request in Self.ready(request) ?? .init(["prompt_id": UUID().uuidString]) }
        let client = runtime()
        let request = FreeVideoRequest(prompt: "Ocean, with the sound of waves", width: 1344, height: 768, seconds: 10, seed: 42, twoPass: false)
        let first = try await client.submit(request, node: base)
        let second = try await client.submit(request, node: base)
        #expect(first.nodeID != second.nodeID)
        let posted = try Self.body(#require(state.seen.first { $0.url?.path == "/prompt" }))
        let graph = try #require(posted["prompt"] as? [String: Any])
        let node = try #require(graph[first.nodeID] as? [String: Any])
        #expect(node["class_type"] as? String == "FreeVideoGenerate")
        let inputs = try #require(node["inputs"] as? [String: Any])
        #expect(inputs["text"] as? String == request.prompt)
        #expect(inputs["width"] as? Int == 1344)
        #expect(inputs["height"] as? Int == 768)
        #expect(inputs["seconds"] as? Double == 10)
        #expect(inputs["seed"] as? Int == 42)
        #expect(inputs["two_pass"] as? Bool == false)
    }

    @Test func firstAndLastFramesUseFreeVideoMediaUploadAndAssets() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.png")
        let last = directory.appendingPathComponent("last.png")
        try Data([137, 80, 78, 71]).write(to: first)
        try Data([137, 80, 78, 71]).write(to: last)
        state.reset { request in
            if request.url?.path == "/freevideo/media/upload" { return .init(["file": "freevideo/uuid/frame.png", "bytes": 4]) }
            return Self.ready(request) ?? .init(["prompt_id": "job-frames"])
        }
        let job = try await runtime().submit(.init(prompt: "The camera moves between frames", seed: 1, firstFrame: first, lastFrame: last), node: base)
        #expect(state.seen.filter { $0.url?.path == "/freevideo/media/upload" }.count == 2)
        let post = try Self.body(#require(state.seen.first { $0.url?.path == "/prompt" }))
        let graph = try #require(post["prompt"] as? [String: Any])
        let generator = try #require(graph[job.nodeID] as? [String: Any])
        let generatorInputs = try #require(generator["inputs"] as? [String: Any])
        #expect((generatorInputs["media"] as? [Any])?.first as? String == job.nodeID + "_media")
        let media = try #require(graph[job.nodeID + "_media"] as? [String: Any])
        #expect(media["class_type"] as? String == "FreeVideoMedia")
        let serialized = try #require((media["inputs"] as? [String: Any])?["assets"] as? String)
        let assets = try #require(JSONSerialization.jsonObject(with: Data(serialized.utf8)) as? [[String: String]])
        #expect(assets.map { $0["role"] } == ["first", "last"])
    }

    @Test func ambiguousSubmissionCannotBecomeAnAutomaticRetry() async throws {
        for reply in [FreeVideoReply([:], status: 200), .init(["error": "failed"], status: 500), .init(["prompt_id": "../prompt"])] {
            state.reset { request in Self.ready(request) ?? reply }
            do {
                _ = try await runtime().submit(.init(prompt: "A shot", seed: 1), node: base)
                Issue.record("Missing/unsafe receipt or server failure is an unknown submission")
            } catch FreeVideoError.submissionUnknown { }
            #expect(state.seen.filter { $0.url?.path == "/prompt" }.count == 1)
        }
        state.reset { request in
            if let readiness = Self.ready(request) { return readiness }
            throw URLError(.timedOut)
        }
        do { _ = try await runtime().submit(.init(prompt: "shot", seed: 1), node: base) }
        catch FreeVideoError.submissionUnknown { }
        #expect(state.seen.filter { $0.url?.path == "/prompt" }.count == 1)
    }

    @Test func rejectedWorkflowExplainsItsActualNodeValidationError() async throws {
        state.reset { request in
            Self.ready(request) ?? .init([
                "error": ["type": "prompt_outputs_failed_validation", "message": "Prompt outputs failed validation"],
                "node_errors": ["node": ["errors": [["message": "Custom validation failed", "details": "FreeVideo setup is incomplete. Open FreeVideo Settings and click Install / repair."]]]]
            ], status: 400)
        }
        do {
            _ = try await runtime().submit(.init(prompt: "A shot", seed: 1), node: base)
            Issue.record("Rejected workflow should fail explicitly")
        } catch FreeVideoError.server(let message) {
            #expect(message.contains("FreeVideo setup is incomplete"))
            #expect(message.contains("Install / repair"))
        }
        #expect(state.seen.filter { $0.url?.path == "/prompt" }.count == 1)
    }

    @Test func savedReceiptDownloadsItsOwnNativePreviewWithoutSubmitting() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        // A finished old job still downloads even after its original follow deadline.
        let job = FreeVideoJob(id: "saved-job", nodeID: "silicon_own", submittedAt: .distantPast)
        state.reset { request in
            request.url?.path == "/view" ? .init(data: Self.mp4, type: "video/mp4") : Self.success(id: job.id, node: job.nodeID, name: "video with spaces.mp4")
        }
        let result = try await runtime().follow(job, node: base, outputDirectory: directory, onProgress: { _ in })
        #expect(result.jobID == job.id)
        #expect(try Data(contentsOf: result.file) == Self.mp4)
        #expect(result.file.deletingLastPathComponent().path == directory.path)
        #expect(RecentVideoFiles.scan(in: directory).map(\.path).contains(result.file.resolvingSymlinksInPath().path))
        #expect(!state.seen.contains { $0.httpMethod == "POST" })
        let viewURL = try #require(state.seen.first { $0.url?.path == "/view" }?.url)
        let query = try #require(URLComponents(url: viewURL, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.first { $0.name == "filename" }?.value == "video with spaces.mp4")
        #expect(query.first { $0.name == "type" }?.value == "output")
    }

    @Test func progressDoesNotUseOtherClientsNode() async throws {
        let job = FreeVideoJob(id: "job-progress", nodeID: "silicon_own")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        state.reset { request in
            if request.url?.path == "/history/job-progress" {
                let count = FreeVideoHTTPState.shared.seen.filter { $0.url?.path == request.url?.path }.count
                return count == 1 ? .init([:]) : Self.success(id: job.id, node: job.nodeID)
            }
            if request.url?.path == "/queue" {
                let row: [Any] = [0, job.id, [job.nodeID: ["class_type": "FreeVideoGenerate"]]]
                return .init(["queue_running": [row]])
            }
            if request.url?.path == "/freevideo/progress" { return .init(["progress": [
                ["node": "unrelated", "label": "Another person's render"], ["node": job.nodeID, "label": "Sampling this shot"]]]) }
            return .init(data: Self.mp4, type: "video/mp4")
        }
        let progress = FreeVideoProgressRecorder()
        _ = try await runtime().follow(job, node: base, outputDirectory: directory, onProgress: progress.append)
        #expect(progress.values.contains("Sampling this shot"))
        #expect(!progress.values.contains("Another person's render"))
    }

    @Test func historyErrorsAndMissingJobsKeepTheirMeaning() async throws {
        let job = FreeVideoJob(id: "job-error", nodeID: "node")
        for event in ["execution_error", "execution_interrupted"] {
            state.reset { _ in .init([job.id: ["status": ["status_str": "error", "completed": false,
                "messages": [[event, ["exception_message": "CUDA out of memory"]] as [Any]]]]]) }
            do {
                _ = try await runtime().follow(job, node: base, outputDirectory: .temporaryDirectory, onProgress: { _ in })
                Issue.record("Terminal history must fail without downloading")
            } catch FreeVideoError.cancelled { #expect(event == "execution_interrupted") }
            catch FreeVideoError.server(let message) { #expect(message.contains("CUDA out of memory")) }
            #expect(!state.seen.contains { $0.url?.path == "/view" })
        }
        state.reset { _ in .init([:]) }
        do { _ = try await runtime().follow(job, node: base, outputDirectory: .temporaryDirectory, onProgress: { _ in }) }
        catch FreeVideoError.missingJob { }
        #expect(!state.seen.contains { $0.httpMethod == "POST" })
    }

    @Test func outputPathsCannotEscapeComfyOutputOrSelectAnotherNodesResult() throws {
        for (name, folder) in [("../secret.mp4", "FreeVideo"), ("video.mp4", "../../input"),
                               ("video.mp4", "/absolute"), ("video.mp4", "%2e%2e"),
                               ("video.mp4", "C:\\output"), ("video.png", "FreeVideo")] {
            let data = Self.success(id: "job", node: "node", name: name, folder: folder).data
            let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let record = try #require(root["job"] as? [String: Any])
            #expect(throws: FreeVideoError.self) { try FreeVideoRuntime.outputURL(record, nodeID: "node", base: base) }
        }
        #expect(throws: FreeVideoError.self) {
            try FreeVideoRuntime.outputURL(["outputs": ["different-node": ["images": []]]], nodeID: "node", base: base)
        }
        #expect(throws: FreeVideoError.self) {
            try FreeVideoRuntime.outputURL(["outputs": ["node": ["images": [["filename": "video.mp4", "subfolder": "", "type": "input"]]]]], nodeID: "node", base: base)
        }
    }

    @Test func cancellationTargetsExactlyOneJobAndNeverInterruptsWholeServer() async throws {
        let job = FreeVideoJob(id: "cancel-me", nodeID: "silicon_specific")
        for outcome in [FreeVideoCancelOutcome.cancelled, .cancelling, .finished] {
            state.reset { _ in .init(["status": outcome.rawValue]) }
            let returned = try await runtime().cancel(job, node: base)
            #expect(returned == outcome)
            let request = try #require(state.seen.first)
            #expect(request.url?.path == "/freevideo/cancel")
            let body = try Self.body(request)
            #expect(body["prompt_id"] as? String == job.id)
            #expect(body["node_id"] as? String == job.nodeID)
            #expect(state.seen.count == 1)
        }
        state.reset { _ in .init([:]) }
        await #expect(throws: FreeVideoError.self) {
            try await runtime().cancel(.init(id: "../interrupt", nodeID: "node"), node: base)
        }
        #expect(state.seen.isEmpty)
    }
}
