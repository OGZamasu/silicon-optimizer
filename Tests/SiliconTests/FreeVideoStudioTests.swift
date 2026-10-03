import Foundation
import SiliconRuntime
import Testing
@testable import SiliconUI

private actor FreeVideoStudioFake {
    enum Failure: Error { case offline }
    var submissions: [URL] = []
    var follows: [(URL, URL)] = []
    var cancellations: [URL] = []
    var failuresRemaining = 0
    var unknownSubmission = false
    var cancellation: FreeVideoCancelOutcome = .cancelled

    func failNextFollow() { failuresRemaining = 1 }
    func makeSubmissionUnknown() { unknownSubmission = true }
    func setCancellation(_ value: FreeVideoCancelOutcome) { cancellation = value }
    func counts() -> (Int, Int) { (submissions.count, follows.count) }
    func followed() -> [(URL, URL)] { follows }
    func cancelledAt() -> [URL] { cancellations }

    func submit(_ request: FreeVideoRequest, node: URL) throws -> FreeVideoJob {
        submissions.append(node)
        if unknownSubmission { throw FreeVideoError.submissionUnknown }
        return .init(id: "accepted-job", nodeID: "unique-node", submittedAt: Date())
    }

    func follow(_ job: FreeVideoJob, node: URL, directory: URL) throws -> FreeVideoResult {
        follows.append((node, directory))
        if failuresRemaining > 0 { failuresRemaining -= 1; throw Failure.offline }
        return .init(file: directory.appendingPathComponent("freevideo-test.mp4"), jobID: job.id)
    }

    func cancel(_ job: FreeVideoJob, node: URL) -> FreeVideoCancelOutcome {
        cancellations.append(node)
        return cancellation
    }

    nonisolated var client: FreeVideoStudioClient {
        .init(check: { _ in .init(ready: true, detail: "Ready") },
              submit: { try await self.submit($0, node: $1) },
              follow: { job, node, directory, progress in
                  progress("Rendering")
                  return try await self.follow(job, node: node, directory: directory)
              },
              cancel: { await self.cancel($0, node: $1) })
    }
}

/// Hold an accepted job at the network boundary so cancel and completion can race deterministically.
private actor FreeVideoStudioSuspendedClient {
    let cancellation: FreeVideoCancelOutcome
    var submissionCount = 0
    var followCount = 0
    var followContinuation: CheckedContinuation<FreeVideoResult, Never>?
    var followWaiters: [CheckedContinuation<Void, Never>] = []
    var result: FreeVideoResult?

    init(cancellation: FreeVideoCancelOutcome) { self.cancellation = cancellation }

    func submit() -> FreeVideoJob {
        submissionCount += 1
        return .init(id: "racing-job", nodeID: "racing-node")
    }

    func follow(_ job: FreeVideoJob, directory: URL) async -> FreeVideoResult {
        followCount += 1
        result = .init(file: directory.appendingPathComponent("late-result.mp4"), jobID: job.id)
        return await withCheckedContinuation { continuation in
            followContinuation = continuation
            for waiter in followWaiters { waiter.resume() }
            followWaiters.removeAll()
        }
    }

    func waitUntilFollowing() async {
        guard followContinuation == nil else { return }
        await withCheckedContinuation { followWaiters.append($0) }
    }

    func finishFollowing() {
        guard let continuation = followContinuation, let result else { return }
        followContinuation = nil
        continuation.resume(returning: result)
    }

    func counts() -> (Int, Int) { (submissionCount, followCount) }

    nonisolated var client: FreeVideoStudioClient {
        .init(check: { _ in .init(ready: true, detail: "Ready") },
              submit: { _, _ in await self.submit() },
              follow: { job, _, directory, _ in await self.follow(job, directory: directory) },
              cancel: { _, _ in self.cancellation })
    }
}

@Suite("FreeVideo studio")
@MainActor
struct FreeVideoStudioTests {
    private var outputDirectory: URL { URL(fileURLWithPath: "/tmp/freevideo-test-output") }

    @Test func changingTheEndpointInvalidatesReadiness() async {
        let studio = FreeVideoStudio(client: FreeVideoStudioFake().client)
        await studio.restore()
        await studio.checkConnection()
        #expect(studio.isReady)
        studio.endpoint = "http://another-computer:8188"
        #expect(!studio.isReady)
        #expect(studio.engineStatus == nil)
    }

    @Test func downloadRetryKeepsTheAcceptedEndpointAndDoesNotSubmitAgain() async {
        let fake = FreeVideoStudioFake()
        await fake.failNextFollow()
        let studio = FreeVideoStudio(client: fake.client)
        await studio.restore()
        await studio.checkConnection()
        studio.prompt = "A stream in a quiet forest"
        let acceptedAt = try! FreeVideoRuntime.validatedBaseURL(studio.endpoint)
        await studio.generate(outputDirectory: outputDirectory)
        #expect(studio.pending != nil)
        #expect(!studio.canGenerate)
        studio.endpoint = "http://new-computer:8188"
        await studio.resume()
        #expect(studio.pending == nil)
        #expect(studio.history.count == 1)
        #expect(studio.history.first?.endpoint == acceptedAt)
        let counts = await fake.counts()
        #expect(counts.0 == 1)
        #expect(counts.1 == 2)
        let followed = await fake.followed()
        #expect(followed.allSatisfy { $0.0 == acceptedAt && $0.1 == outputDirectory })
    }

    @Test func relaunchRestoresTheReceiptWithoutContactingTheEngine() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("freevideo-studio-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("studio.json")
        let fake = FreeVideoStudioFake()
        await fake.failNextFollow()
        let first = FreeVideoStudio(storageURL: file, client: fake.client)
        await first.restore()
        first.prompt = "A paper boat in a puddle"
        await first.checkConnection()
        await first.generate(outputDirectory: outputDirectory)
        #expect(first.pending != nil)
        let beforeRestore = await fake.counts()

        let restarted = FreeVideoStudio(storageURL: file, client: fake.client)
        await restarted.restore()
        #expect(restarted.pending?.job.id == "accepted-job")
        #expect(restarted.pending?.outputDirectory == outputDirectory)
        let afterRestore = await fake.counts()
        #expect(beforeRestore.0 == afterRestore.0)
        #expect(beforeRestore.1 == afterRestore.1)
        await restarted.resume()
        #expect(restarted.pending == nil)
        let completed = FreeVideoStudio(storageURL: file, client: fake.client)
        await completed.restore()
        #expect(completed.history.count == 1)
        #expect(completed.history.first?.prompt == first.prompt)
        #expect(completed.pending == nil)
    }

    @Test func anUnknownSubmissionBlocksAnotherRenderUntilAcknowledged() async {
        let fake = FreeVideoStudioFake()
        await fake.makeSubmissionUnknown()
        let studio = FreeVideoStudio(client: fake.client)
        await studio.restore()
        studio.prompt = "Sunlight across a mountain ridge"
        await studio.checkConnection()
        let sentTo = try! FreeVideoRuntime.validatedBaseURL(studio.endpoint)
        await studio.generate(outputDirectory: outputDirectory)
        #expect(studio.uncertainSubmission)
        #expect(studio.uncertainEndpoint == sentTo)
        #expect(!studio.canGenerate)
        await studio.generate(outputDirectory: outputDirectory)
        let counts = await fake.counts()
        #expect(counts.0 == 1)
        await studio.acknowledgeUnknownSubmission()
        #expect(!studio.uncertainSubmission)
        #expect(studio.uncertainEndpoint == nil)
        #expect(studio.canGenerate)
    }

    @Test func confirmedCancellationUsesTheFrozenEndpoint() async {
        let fake = FreeVideoStudioFake()
        await fake.failNextFollow()
        let studio = FreeVideoStudio(client: fake.client)
        await studio.restore()
        await studio.checkConnection()
        studio.prompt = "A kite beside the ocean"
        let acceptedAt = try! FreeVideoRuntime.validatedBaseURL(studio.endpoint)
        await studio.generate(outputDirectory: outputDirectory)
        studio.endpoint = "http://different-computer:8188"
        await studio.cancel()
        #expect(studio.pending == nil)
        #expect(await fake.cancelledAt() == [acceptedAt])
    }

    @Test func finishingCancellationFollowsTheJobInsteadOfDiscardingIt() async {
        let fake = FreeVideoStudioFake()
        await fake.failNextFollow()
        await fake.setCancellation(.finished)
        let studio = FreeVideoStudio(client: fake.client)
        await studio.restore()
        await studio.checkConnection()
        studio.prompt = "A lighthouse at dawn"
        await studio.generate(outputDirectory: outputDirectory)
        await studio.cancel()
        #expect(studio.history.count == 1)
        let counts = await fake.counts()
        #expect(counts.0 == 1)
        #expect(counts.1 == 2)
    }

    @Test func savingBeforeRestorationCannotOverwriteAnAcceptedJob() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("freevideo-early-save-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("studio.json")
        let receipt = FreeVideoPendingClip(
            job: .init(id: "existing-job", nodeID: "existing-node"),
            endpoint: URL(string: "http://existing-engine:8188")!, outputDirectory: outputDirectory,
            prompt: "Already accepted"
        )
        let snapshot = FreeVideoStudioSnapshot(endpoint: receipt.endpoint.absoluteString, pending: receipt)
        let store = FreeVideoStudioStore(url: file)
        try await store.save(snapshot)
        let original = try Data(contentsOf: file)
        let studio = FreeVideoStudio(storageURL: file, client: FreeVideoStudioFake().client)
        studio.endpoint = "http://accidental-new-value:8188"
        await studio.saveConnection()
        await studio.checkConnection()
        await studio.acknowledgeUnknownSubmission()
        #expect(try Data(contentsOf: file) == original)
        #expect(studio.engineStatus == nil)
        await studio.restore()
        #expect(studio.pending == receipt)
        #expect(studio.endpoint == receipt.endpoint.absoluteString)
    }

    @Test func aFailedRestoreCanLoadAgainAfterTheSavedFileIsRepaired() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("freevideo-retry-restore-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("studio.json")
        let malformed = Data("interrupted JSON".utf8)
        try malformed.write(to: file)
        let fake = FreeVideoStudioFake()
        let studio = FreeVideoStudio(storageURL: file, client: fake.client)
        await studio.restore()
        #expect(!studio.isRestored)
        #expect(!studio.isRestoring)
        #expect(studio.error != nil)
        await studio.saveConnection()
        #expect(try Data(contentsOf: file) == malformed)

        let receipt = FreeVideoPendingClip(
            job: .init(id: "recovered-job", nodeID: "recovered-node"),
            endpoint: URL(string: "http://recovered-engine:8188")!, outputDirectory: outputDirectory,
            prompt: "Recovered receipt"
        )
        try await FreeVideoStudioStore(url: file).save(
            .init(endpoint: receipt.endpoint.absoluteString, pending: receipt)
        )
        await studio.restore()
        #expect(studio.isRestored)
        #expect(studio.error == nil)
        #expect(studio.pending == receipt)
        let counts = await fake.counts()
        #expect(counts.0 == 0)
        #expect(counts.1 == 0)
    }

    @Test func confirmedCancellationCannotBeRevivedByALateFollowResult() async {
        let fake = FreeVideoStudioSuspendedClient(cancellation: .cancelled)
        let studio = FreeVideoStudio(client: fake.client)
        await studio.restore()
        await studio.checkConnection()
        studio.prompt = "A sailboat passing the harbor"
        let generation = Task { await studio.generate(outputDirectory: outputDirectory) }
        await fake.waitUntilFollowing()
        #expect(studio.pending != nil)
        await studio.cancel()
        #expect(studio.pending == nil)
        #expect(studio.history.isEmpty)
        await fake.finishFollowing()
        await generation.value
        #expect(studio.pending == nil)
        #expect(studio.history.isEmpty)
        #expect(studio.stage == FreeVideoCancelOutcome.cancelled.message)
        #expect(!studio.isBusy)
        let counts = await fake.counts()
        #expect(counts.0 == 1)
        #expect(counts.1 == 1)
    }

    @Test func aFinishedCancelKeepsTheReceiptUntilTheExistingFollowSavesItsResult() async {
        let fake = FreeVideoStudioSuspendedClient(cancellation: .finished)
        let studio = FreeVideoStudio(client: fake.client)
        await studio.restore()
        await studio.checkConnection()
        studio.prompt = "Clouds moving over a city skyline"
        let generation = Task { await studio.generate(outputDirectory: outputDirectory) }
        await fake.waitUntilFollowing()
        let receipt = studio.pending
        await studio.cancel()
        #expect(studio.pending == receipt)
        #expect(studio.history.isEmpty)
        #expect(studio.isBusy)
        let duringCancel = await fake.counts()
        #expect(duringCancel.0 == 1)
        #expect(duringCancel.1 == 1)
        await fake.finishFollowing()
        await generation.value
        #expect(studio.pending == nil)
        #expect(studio.history.count == 1)
        #expect(studio.history.first?.id == "racing-job")
        let finished = await fake.counts()
        #expect(finished.0 == 1)
        #expect(finished.1 == 1)
    }
}
