import Foundation
import Testing
@testable import SiliconCatalog
@testable import SiliconControl
import SiliconPlanner
@testable import SiliconRuntime
@testable import SiliconUI

/// Stands in for MFLUX and the 3D backends: every render it is handed waits until the test
/// finishes or fails it, and it remembers how many were ever running at once — which is the
/// number the render queues exist to keep at one.
actor HeldRenders {
    private var images: [AsyncThrowingStream<ImageEvent, any Error>.Continuation] = []
    private var meshes: [AsyncThrowingStream<MeshEvent, any Error>.Continuation] = []
    private var outputs: [URL] = []
    private var prompts: [String] = []
    private var settled: Set<Int> = []
    private var open = 0
    private(set) var mostAtOnce = 0
    /// The settings each 3D render was handed, in order.
    private(set) var meshConfigurations: [MeshConfiguration] = []
    /// `PaidLanes.allowed` as each render saw it when it started, by prompt (or, for a
    /// mesh, the subject image's name). Read on the render's own task, which is where a
    /// paid call it made would read it.
    private(set) var paidLanes: [String: Bool] = [:]

    var started: [String] { prompts }

    func begin(_ request: ImageRequest) -> (Int, AsyncThrowingStream<ImageEvent, any Error>) {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: ImageEvent.self)
        images.append(continuation)
        meshes.append(AsyncThrowingStream.makeStream(of: MeshEvent.self).continuation)
        return (opened(request.output, prompt: request.prompt, stage: continuation), stream)
    }

    func begin(_ request: MeshRequest) -> (Int, AsyncThrowingStream<MeshEvent, any Error>) {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: MeshEvent.self)
        meshes.append(continuation)
        meshConfigurations.append(request.configuration)
        images.append(AsyncThrowingStream.makeStream(of: ImageEvent.self).continuation)
        let output = request.outputDirectory.appendingPathComponent(request.baseName + ".glb")
        continuation.yield(.stage("Sampling"))
        return (opened(output, prompt: request.image.lastPathComponent, stage: nil), stream)
    }

    private func opened(
        _ output: URL, prompt: String,
        stage: AsyncThrowingStream<ImageEvent, any Error>.Continuation?
    ) -> Int {
        outputs.append(output)
        prompts.append(prompt)
        paidLanes[prompt] = PaidLanes.allowed
        open += 1
        mostAtOnce = max(mostAtOnce, open)
        stage?.yield(.stage("Loading the model…"))
        return outputs.count - 1
    }

    /// Writes the file the render would have written, and says so.
    func finish(_ index: Int) throws {
        guard settled.insert(index).inserted else { return }
        open -= 1
        let output = outputs[index]
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("render".utf8).write(to: output)
        images[index].yield(.finished(ImageResult(
            image: output, elapsed: 2, peakMemory: nil, stepsPerSecond: 1
        )))
        images[index].finish()
        meshes[index].yield(.finished(MeshResult(
            baseName: output.deletingPathExtension().lastPathComponent, glb: output, obj: nil,
            textures: [], sourceImage: nil, modelName: "held", elapsed: 3
        )))
        meshes[index].finish()
    }

    func fail(_ index: Int, _ error: any Error) {
        guard settled.insert(index).inserted else { return }
        open -= 1
        images[index].finish(throwing: error)
        meshes[index].finish(throwing: error)
    }

    func output(_ index: Int) -> URL { outputs[index] }
}

actor HeldImageRuntime: ImageRuntime {
    nonisolated let kind: ImageRuntimeKind = .mflux
    nonisolated static func locate() -> RuntimeInstallation? { nil }
    var state: RuntimeState = .idle
    private let renders: HeldRenders
    private var index: Int?

    init(_ renders: HeldRenders) { self.renders = renders }

    func generate(
        _ request: ImageRequest, model: InstalledModel
    ) async throws -> AsyncThrowingStream<ImageEvent, any Error> {
        let (index, stream) = await renders.begin(request)
        self.index = index
        return stream
    }

    /// What terminating mflux looks like from here: the stream ends in an error.
    func cancel() async {
        if let index { await renders.fail(index, ImageRuntimeError.cancelled) }
    }
}

actor HeldMeshRuntime: MeshRuntime {
    var state: RuntimeState = .idle
    private let renders: HeldRenders
    private var index: Int?

    init(_ renders: HeldRenders) { self.renders = renders }

    func generate(_ request: MeshRequest) async throws -> AsyncThrowingStream<MeshEvent, any Error> {
        let (index, stream) = await renders.begin(request)
        self.index = index
        return stream
    }

    func cancel() async {
        if let index { await renders.fail(index, MeshRuntimeError.cancelled) }
    }
}

/// A render asked for over the control API — by a phone, a swarm peer or an MCP tool — goes
/// through the same queue as the one typed into the Mac's own composer: one at a time,
/// shown in the tab, stopped by its Stop button, and kept awake for.
/// Time-limited because what is under test is whether anything hangs: a caller left waiting
/// on a render that is not coming must fail here, not stall the run.
@Suite(
    "Control-API renders use the render queues",
    .serialized, .timeLimit(.minutes(1)), .redirectedConversationStore
)
@MainActor
struct ControlRenderQueueTests {

    private struct Fixture {
        let model: AppModel
        let renders: HeldRenders
        let folder: URL
        let subject: URL
    }

    private func fixture() throws -> Fixture {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("control-render-queue-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var settings = Settings()
        settings.imageOutputDirectory = folder.appendingPathComponent("Images").path
        settings.meshOutputDirectory = folder.appendingPathComponent("Meshes").path
        // "Configured" is all the LATO.2 lane checks before a render, and the held runtime
        // below stands in for it, so nothing is ever sent here.
        settings.lato2ServiceURL = "http://127.0.0.1:9"
        // And no local 3D engine is installed here, whatever this machine has elsewhere.
        settings.trellisBaseDirectory = folder.appendingPathComponent("engines").path
        let model = AppModel(
            videoQueue: VideoBatchQueue(storeURL: folder.appendingPathComponent("queue.json")),
            settings: settings
        )
        // Belt and braces: if a render ever reached MFLUX itself, this is an executable
        // that does not exist, so it fails at once instead of running a real model.
        model.imageRuntime = RuntimeInstallation(
            kind: .mlx, executable: folder.appendingPathComponent("absent/mflux-generate"),
            version: nil, hasExpertStreaming: false, source: .userPath
        )
        // Nothing a render here finishes with is published into the owner's media table.
        model.eventMediaRegistry = MediaRegistry(url: nil)
        let renders = HeldRenders()
        model.makeImageRuntime = { _ in HeldImageRuntime(renders) }
        model.meshRuntimeFactory = { _ in HeldMeshRuntime(renders) }
        let subject = folder.appendingPathComponent("kettle.png")
        try Data("png".utf8).write(to: subject)
        return Fixture(model: model, renders: renders, folder: folder, subject: subject)
    }

    private func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// What a call was answered with, or a failure after a few seconds — never a test that
    /// waits for ever on a render that is not coming. `Task.value` does not listen for
    /// cancellation, so the time limit alone cannot end that wait.
    private func answer<Value: Sendable>(
        _ call: Task<Value, any Error>, within limit: Duration = .seconds(10)
    ) async throws -> Value {
        let settled = FirstAnswer<Value>()
        let result = await withCheckedContinuation { continuation in
            settled.arm(continuation)
            Task { settled.give(await call.result) }
            Task {
                try? await Task.sleep(for: limit)
                settled.give(.failure(CallNeverAnswered()))
            }
        }
        return try result.get()
    }

    private func imageRequest(_ prompt: String) -> ControlAPI.ImageRequest {
        ControlAPI.ImageRequest(
            prompt: prompt, modelID: DiffusionCatalog.flux2Klein4B.id,
            width: 256, height: 256, steps: 2, localOnly: true
        )
    }

    // MARK: - Images

    @Test func aControlImageWaitsBehindTheComposersAndNeverRunsBesideIt() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }

        f.model.imagePrompt = "a lighthouse"
        f.model.generateImage()
        try await waitUntil { await f.renders.started == ["a lighthouse"] }

        let call = Task { try await f.model.generateImage(imageRequest("a harbour")) }
        try await waitUntil { f.model.imageQueue.map(\.prompt) == ["a harbour"] }
        // Queued, not started beside the first — and the first one's progress is still on
        // screen rather than reset to idle by a render that finished or failed next to it.
        #expect(await f.renders.started == ["a lighthouse"])
        #expect(f.model.isGeneratingImage)
        #expect(f.model.imageState.stageLine != nil)

        try await f.renders.finish(0)
        try await waitUntil { await f.renders.started.count == 2 }
        #expect(f.model.currentImageJob?.prompt == "a harbour")
        try await f.renders.finish(1)

        let reply = try await answer(call)
        #expect(reply.path == (await f.renders.output(1)).path)
        #expect(reply.model == DiffusionCatalog.flux2Klein4B.name)
        #expect(await f.renders.mostAtOnce == 1)
        #expect(f.model.generatedImages.count == 2)
        try await waitUntil { !f.model.isGeneratingImage }
    }

    @Test func twoControlImagesTakeTurns() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }

        let first = Task { try await f.model.generateImage(imageRequest("one")) }
        try await waitUntil { await f.renders.started == ["one"] }
        let second = Task { try await f.model.generateImage(imageRequest("two")) }
        try await waitUntil { f.model.imageQueue.count == 1 }
        #expect(await f.renders.started == ["one"])

        try await f.renders.finish(0)
        _ = try await answer(first)
        try await waitUntil { await f.renders.started.count == 2 }
        try await f.renders.finish(1)
        _ = try await answer(second)
        #expect(await f.renders.mostAtOnce == 1)
    }

    @Test func stopAtTheMacStopsAControlImageAndAnswersItsCaller() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }

        let call = Task { try await f.model.generateImage(imageRequest("a harbour")) }
        try await waitUntil { await f.renders.started.count == 1 }
        // Something that must stay awake, and that the tab can see.
        #expect(f.model.isGeneratingImage)
        #expect(f.model.currentImageJob?.prompt == "a harbour")

        f.model.cancelImage()
        await #expect(throws: QueuedRenderError.stoppedOnMac) { try await answer(call) }
        try await waitUntil { !f.model.isGeneratingImage }
        #expect(f.model.imageState.stageLine == nil)
    }

    @Test func aControlImageTakenOutOfTheQueueAnswersItsCaller() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }

        f.model.imagePrompt = "a lighthouse"
        f.model.generateImage()
        try await waitUntil { await f.renders.started.count == 1 }
        let removed = Task { try await f.model.generateImage(imageRequest("removed")) }
        let cleared = Task { try await f.model.generateImage(imageRequest("cleared")) }
        try await waitUntil { f.model.imageQueue.count == 2 }

        let id = try #require(f.model.imageQueue.first { $0.prompt == "removed" }?.id)
        f.model.removeQueuedImageJob(id)
        await #expect(throws: QueuedRenderError.removedFromQueue) { try await answer(removed) }
        f.model.clearImageQueue()
        await #expect(throws: QueuedRenderError.removedFromQueue) { try await answer(cleared) }

        try await f.renders.finish(0)
        try await waitUntil { !f.model.isGeneratingImage }
        #expect(await f.renders.started == ["a lighthouse"])
    }

    /// The caller is told why in its answer. A modal alert on the Mac for a render a phone
    /// asked for would wait for somebody who is not there.
    @Test func aFailedControlImageIsAnsweredNotAlerted() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }

        let call = Task { try await f.model.generateImage(imageRequest("a harbour")) }
        try await waitUntil { await f.renders.started.count == 1 }
        await f.renders.fail(0, ImageRuntimeError.generationFailed("Ran out of memory."))
        await #expect(throws: ImageRuntimeError.self) { try await answer(call) }
        #expect(f.model.alert == nil)
        try await waitUntil { !f.model.isGeneratingImage }
    }

    // MARK: - What /events says when one ends

    /// The Images and 3D queues are one frame each on `/events`, for the job running now.
    /// When it ends the frame stays and says how — with the file to fetch when it made one —
    /// rather than simply no longer being sent, which left a phone showing it running.
    @Test func aFinishedImageIsAnnouncedAsCompletedWithItsFile() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        // In memory: a test must not add entries to the owner's own media table.
        let registry = MediaRegistry(url: nil)

        let call = Task { try await f.model.generateImage(imageRequest("a harbour")) }
        try await waitUntil { await f.renders.started.count == 1 }
        let running = await f.model.buddyEventSnapshot(registry: registry)
        #expect(running.jobs["image"]?.status == "running")

        try await f.renders.finish(0)
        _ = try await answer(call)
        try await waitUntil { !f.model.isGeneratingImage }
        let finished = await f.model.buddyEventSnapshot(registry: registry)
        let frame = try #require(finished.jobs["image"])
        #expect(frame.status == "completed")
        #expect(frame.mediaID != nil)
        #expect(frame.mediaID == (await registry.id(forPath: (await f.renders.output(0)).path)))

        // Which the watcher sends as one `job` frame: finished, not removed.
        let sent = BuddyEventPump.changes(from: running, to: finished).compactMap { event in
            if case .job(let job) = event { job } else { nil }
        }
        #expect(sent.map(\.status) == ["completed"])
    }

    @Test func aStoppedOrFailedRenderIsAnnouncedAsSuch() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        let registry = MediaRegistry(url: nil)

        f.model.imagePrompt = "a lighthouse"
        f.model.generateImage()
        try await waitUntil { await f.renders.started.count == 1 }
        f.model.cancelImage()
        try await waitUntil { !f.model.isGeneratingImage }
        let stopped = try #require(
            await f.model.buddyEventSnapshot(registry: registry).jobs["image"]
        )
        #expect(stopped.status == "cancelled")
        #expect(stopped.reason == QueuedRenderError.stoppedOnMac.localizedDescription)
        #expect(stopped.mediaID == nil)

        f.model.selectedMeshModel = MeshCatalog.lato2.id
        f.model.meshInputImage = f.subject
        f.model.generateMesh()
        try await waitUntil { await f.renders.started.count == 2 }
        await f.renders.fail(1, MeshRuntimeError.generationFailed("The service ran out of memory."))
        try await waitUntil { !f.model.isGeneratingMesh }
        let failed = try #require(
            await f.model.buddyEventSnapshot(registry: registry).jobs["mesh"]
        )
        #expect(failed.status == "failed")
        #expect(failed.reason == "The service ran out of memory.")
    }

    // MARK: - The paid lanes

    /// Each job runs with the paid lanes as its own caller had them. The task that runs a
    /// job is started by the job that finished before it, and a task keeps its creator's
    /// task-locals — so without this a swarm node's render shut the lanes for the owner's
    /// next render, and the owner's opened them for the peer's.
    @Test func aPeersRenderDoesNotShutThePaidLanesForTheOwnersNext() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }

        let peer = Task {
            try await PaidLanes.$allowed.withValue(false) {
                try await f.model.generateImage(imageRequest("peer"))
            }
        }
        try await waitUntil { await f.renders.started == ["peer"] }
        f.model.imagePrompt = "owner"
        f.model.generateImage()
        try await f.renders.finish(0)
        _ = try await answer(peer)
        try await waitUntil { await f.renders.started.count == 2 }
        try await f.renders.finish(1)
        try await waitUntil { !f.model.isGeneratingImage }

        #expect(await f.renders.paidLanes["peer"] == false)
        #expect(await f.renders.paidLanes["owner"] == true)
    }

    @Test func theOwnersRenderDoesNotOpenThePaidLanesForAPeersNext() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }

        f.model.imagePrompt = "owner"
        f.model.generateImage()
        try await waitUntil { await f.renders.started == ["owner"] }
        let peer = Task {
            try await PaidLanes.$allowed.withValue(false) {
                try await f.model.generateImage(imageRequest("peer"))
            }
        }
        try await waitUntil { f.model.imageQueue.count == 1 }
        try await f.renders.finish(0)
        try await waitUntil { await f.renders.started.count == 2 }
        try await f.renders.finish(1)
        _ = try await answer(peer)

        #expect(await f.renders.paidLanes["owner"] == true)
        #expect(await f.renders.paidLanes["peer"] == false)
    }

    @Test func aPeersMeshDoesNotShutThePaidLanesForTheOwnersNext() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        let ownersSubject = f.folder.appendingPathComponent("owner.png")
        try Data("png".utf8).write(to: ownersSubject)

        let peer = Task {
            try await PaidLanes.$allowed.withValue(false) {
                try await f.model.generateMesh(ControlAPI.MeshRequest(
                    imagePath: f.subject.path, modelID: MeshCatalog.lato2.id
                ))
            }
        }
        try await waitUntil { await f.renders.started.count == 1 }
        f.model.selectedMeshModel = MeshCatalog.lato2.id
        f.model.meshInputImage = ownersSubject
        f.model.generateMesh()
        try await f.renders.finish(0)
        _ = try await answer(peer)
        try await waitUntil { await f.renders.started.count == 2 }
        try await f.renders.finish(1)
        try await waitUntil { !f.model.isGeneratingMesh }

        #expect(await f.renders.paidLanes[f.subject.lastPathComponent] == false)
        #expect(await f.renders.paidLanes["owner.png"] == true)
    }

    // MARK: - Meshes

    @Test func aControlMeshWaitsBehindTheComposersAndNeverRunsBesideIt() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }

        f.model.selectedMeshModel = MeshCatalog.lato2.id
        f.model.meshInputImage = f.subject
        f.model.generateMesh()
        try await waitUntil { await f.renders.started.count == 1 }

        let call = Task {
            try await f.model.generateMesh(ControlAPI.MeshRequest(
                imagePath: f.subject.path, modelID: MeshCatalog.lato2.id
            ))
        }
        try await waitUntil { f.model.meshQueue.count == 1 }
        #expect(await f.renders.started.count == 1)
        #expect(f.model.isGeneratingMesh)
        #expect(f.model.meshState.stageLine != nil)

        try await f.renders.finish(0)
        try await waitUntil { await f.renders.started.count == 2 }
        try await f.renders.finish(1)

        let reply = try await answer(call)
        #expect(reply.glbPath == (await f.renders.output(1)).path)
        #expect(await f.renders.mostAtOnce == 1)
        #expect(f.model.meshResults.count == 2)
    }

    @Test func stopAtTheMacStopsAControlMeshAndAnswersItsCaller() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }

        let call = Task {
            try await f.model.generateMesh(ControlAPI.MeshRequest(
                imagePath: f.subject.path, modelID: MeshCatalog.lato2.id
            ))
        }
        try await waitUntil { await f.renders.started.count == 1 }
        #expect(f.model.isGeneratingMesh)
        f.model.cancelMesh()
        await #expect(throws: QueuedRenderError.stoppedOnMac) { try await answer(call) }
        try await waitUntil { !f.model.isGeneratingMesh }
    }

    /// Every knob a caller can turn reaches a backend's command line, so each is held to what
    /// the backends take — refused before anything is queued, rather than handed on.
    @Test func meshSettingsOutsideWhatTheBackendsTakeAreRefused() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        let hunyuan = MeshCatalog.hunyuanMini.id

        let subject = f.subject.path
        let trellis = MeshCatalog.trellis2.id
        for request in [
            ControlAPI.MeshRequest(imagePath: subject, modelID: hunyuan, octree: 100_000),
            ControlAPI.MeshRequest(imagePath: subject, modelID: hunyuan, octree: 0),
            ControlAPI.MeshRequest(imagePath: subject, modelID: hunyuan, steps: 1_000_000),
            ControlAPI.MeshRequest(imagePath: subject, modelID: hunyuan, steps: 0),
            ControlAPI.MeshRequest(imagePath: subject, modelID: hunyuan, quantize: 3),
            ControlAPI.MeshRequest(imagePath: subject, modelID: trellis, textureSize: 700),
            ControlAPI.MeshRequest(imagePath: subject, modelID: trellis, textureSize: 0),
            ControlAPI.MeshRequest(imagePath: subject, modelID: trellis, pipelineType: "--help"),
        ] {
            await #expect(throws: ControlHostError.self) { _ = try await f.model.planMesh(request) }
            await #expect(throws: ControlHostError.self) {
                _ = try await f.model.generateMesh(request)
            }
        }
        #expect(await f.renders.started.isEmpty)

        // What the 3D tab itself sends is still fine.
        _ = try await f.model.planMesh(ControlAPI.MeshRequest(
            modelID: hunyuan, steps: 30, quantize: 8, octree: 256
        ))
        _ = try await f.model.planMesh(ControlAPI.MeshRequest(
            modelID: MeshCatalog.trellis2.id, pipelineType: "1024_cascade", textureSize: 2048
        ))
    }

    /// The phone apps send one set of 3D settings whatever the model — the Android app
    /// offers a 4096 px texture for all of them. A setting the chosen model never reads is
    /// left alone rather than refused, which is what the 3D tab does too; before the bounds
    /// existed these rendered, and a client already in people's hands must keep rendering.
    @Test func settingsAModelDoesNotReadAreLeftAlone() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }

        for model in [MeshCatalog.hunyuanMini.id, MeshCatalog.lato2.id] {
            _ = try await f.model.planMesh(ControlAPI.MeshRequest(
                modelID: model, pipelineType: "--help", textureSize: 4096
            ))
        }
        // Nor does the octree reach anything but the Hunyuan decode.
        _ = try await f.model.planMesh(ControlAPI.MeshRequest(
            modelID: MeshCatalog.lato2.id, steps: 1_000_000, quantize: 3, octree: 100_000
        ))

        let call = Task {
            try await f.model.generateMesh(ControlAPI.MeshRequest(
                imagePath: f.subject.path, modelID: MeshCatalog.lato2.id, textureSize: 4096,
                octree: 100_000
            ))
        }
        try await waitUntil { await f.renders.started.count == 1 }
        try await f.renders.finish(0)
        _ = try await answer(call)
        // Nothing the model does not read was passed on as the caller wrote it.
        let handed = try #require(await f.renders.meshConfigurations.first)
        #expect(handed.textureSize == MeshConfiguration().textureSize)
        #expect(handed.octree == MeshConfiguration().octree)
    }

    /// A model that does bake textures is given the largest it bakes when asked for more —
    /// taken down with a note, not refused.
    @Test func aTextureLargerThanTheModelBakesIsTakenDownWithANote() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        // TRELLIS.2 counts as set up when its environment exists.
        let python = f.folder.appendingPathComponent("engines/trellis-mac/.venv/bin/python")
        try FileManager.default.createDirectory(
            at: python.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data().write(to: python)

        let request = ControlAPI.MeshRequest(
            imagePath: f.subject.path, modelID: MeshCatalog.trellis2.id, textureSize: 4096
        )
        let plan = try await f.model.planMesh(request)
        #expect(plan.notes.first?.contains("2048 px") == true)

        let call = Task { try await f.model.generateMesh(request) }
        try await waitUntil { await f.renders.started.count == 1 }
        try await f.renders.finish(0)
        let reply = try await answer(call)
        #expect(reply.warning?.contains("2048 px") == true)
        #expect(await f.renders.meshConfigurations.first?.textureSize == 2048)
    }
}

private struct CallNeverAnswered: Error {}

/// Hands on whichever result arrives first, once.
private final class FirstAnswer<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result<Value, any Error>, Never>?

    func arm(_ continuation: CheckedContinuation<Result<Value, any Error>, Never>) {
        lock.withLock { self.continuation = continuation }
    }

    func give(_ result: Result<Value, any Error>) {
        let waiting = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(returning: result)
    }
}
