import Foundation
import Network
import SiliconCatalog
import SiliconCore
import Testing
@testable import SiliconControl
@testable import SiliconRuntime
@testable import SiliconUI

/// The Mac's own half: the conversation store a phone reads and writes, what the `/events`
/// watcher decides is news, and the Settings section's state.
@Suite("Silicon Buddy on the Mac", .redirectedConversationStore)
@MainActor
struct BuddyAppModelTests {

    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("buddy-\(UUID()).json")
    }

    /// An `AppModel` built here schedules the same debounced save as the real one, and its
    /// default target is the owner's own chat history. The suite trait redirects that before
    /// any test runs; this checks it actually took, because the cost of it not having is a
    /// stranger's chat history.
    private func isolatedModel() -> AppModel {
        let model = BuddyTestStore.model()
        let redirected = ProcessInfo.processInfo.environment["SILICON_CONVERSATIONS_PATH"]
        #expect(redirected?.contains("silicon-test-conversations") == true)
        return model
    }

    // MARK: - Conversations

    @Test func aConversationStartedFromAPhoneIsTheMacsOwn() async throws {
        let model = isolatedModel()
        let summary = await model.createConversation(title: "Weekend plans")

        #expect(summary.title == "Weekend plans" && summary.messageCount == 0)
        #expect(await model.conversationList().map(\.id) == [summary.id])

        // At the top of the sidebar, but a second one must not move the cursor out from
        // under whoever is typing at the Mac.
        let selected = model.selectedConversationID
        let second = await model.createConversation(title: "Something else")
        #expect(model.conversations.first?.id.uuidString == second.id)
        #expect(model.selectedConversationID == selected)

        // An untitled request keeps the Mac's own placeholder rather than inventing one.
        let blank = await model.createConversation(title: "   ")
        #expect(blank.title == Conversation.untitled)
    }

    @Test func aTranscriptComesBackWithoutItsImages() async throws {
        let model = isolatedModel()
        let summary = await model.createConversation(title: "Kitchen")
        let index = try #require(model.conversations.firstIndex { $0.id.uuidString == summary.id })
        model.conversations[index].messages = [
            ChatMessage(
                role: .user, content: "What is this?",
                images: ["data:image/png;base64,iVBORw0KGgo="]
            ),
            ChatMessage(role: .assistant, content: "A kettle."),
        ]

        let detail = try await model.conversation(id: summary.id)
        #expect(detail.messages.map(\.role) == ["user", "assistant"])
        #expect(detail.messages.first?.content == "What is this?")
        let json = try String(decoding: JSONEncoder().encode(detail), as: UTF8.self)
        #expect(!json.contains("iVBORw0KGgo="))

        // The summary's timestamp follows the transcript, not the day it was created.
        let listed = try #require(await model.conversationList().first)
        #expect(listed.messageCount == 2)
        #expect(listed.updatedAt == ControlAPI.timestamp(
            model.conversations[index].messages[1].createdAt
        ))
    }

    @Test func anUnknownConversationIsNamedRatherThanCrashed() async {
        let model = isolatedModel()
        let missing = UUID().uuidString
        await #expect(throws: BuddyHostError.noSuchConversation(missing)) {
            _ = try await model.conversation(id: missing)
        }
    }

    /// Nothing streams without a model, and nothing is written to the transcript either —
    /// a phone that asks too early must not leave an empty exchange behind.
    @Test func streamingWithoutALoadedModelChangesNothing() async throws {
        let model = isolatedModel()
        let summary = await model.createConversation(title: "Too early")

        await #expect(throws: ControlHostError.self) {
            _ = try await model.chatStream(.init(messages: [.init(role: "user", content: "hi")]))
        }
        await #expect(throws: ControlHostError.self) {
            _ = try await model.replyInConversation(
                id: summary.id, to: .init(content: "hi")
            )
        }
        let detail = try await model.conversation(id: summary.id)
        #expect(detail.messages.isEmpty)
    }

    /// The bug this replaced: the busy check asked which conversation was *selected*, so a
    /// Mac answering in A with B on screen let a phone post into A — carrying a half-written
    /// reply as context — and falsely refused B.
    @Test func aBusyConversationIsTheBusyOneWhateverIsOnScreen() async throws {
        let model = isolatedModel()
        let busy = await model.createConversation(title: "Being answered")
        let idle = await model.createConversation(title: "Not being answered")
        let busyID = try #require(UUID(uuidString: busy.id))
        let idleID = try #require(UUID(uuidString: idle.id))

        // Whichever thread is on screen, the answer is about the thread being answered.
        model.selectedConversationID = idleID
        BuddyGenerations.shared.begin(busyID)
        defer { BuddyGenerations.shared.end(busyID) }

        #expect(model.isAnswering(busyID))
        #expect(!model.isAnswering(idleID))
        #expect(try await model.conversation(id: busy.id).isGenerating)
        #expect(try await model.conversation(id: idle.id).isGenerating == false)

        await #expect(throws: BuddyHostError.conversationBusy(busy.id)) {
            _ = try await model.replyInConversation(id: busy.id, to: .init(content: "again"))
        }
        // The idle one is refused for a different reason entirely — no model is loaded —
        // which is how this test tells "busy" apart from "everything is refused".
        await #expect(throws: ControlHostError.self) {
            _ = try await model.replyInConversation(id: idle.id, to: .init(content: "hello"))
        }

        BuddyGenerations.shared.end(busyID)
        #expect(!model.isAnswering(busyID))
        await #expect(throws: ControlHostError.self) {
            _ = try await model.replyInConversation(id: busy.id, to: .init(content: "again"))
        }
    }

    /// The window that made the watcher wedge: it reads `subscriberCount` across an await,
    /// and a phone connecting during it calls `start`, which finds a handle that is not yet
    /// free and returns. Comparing the start counter is what makes the loop notice.
    @Test func theWatcherKeepsGoingIfSomeoneArrivedWhileItWasDeciding() {
        let pump = BuddyEventPump()
        let requestsAtCheck = pump.startRequestCount

        // Nobody reading, nobody asked: stop.
        #expect(pump.shouldStop(subscribers: 0, requestsAtCheck: requestsAtCheck))
        // Somebody reading: carry on, whatever the counter says.
        #expect(!pump.shouldStop(subscribers: 1, requestsAtCheck: requestsAtCheck))
        // Nobody reading yet, but a start landed while we were finding that out — which is
        // exactly the subscriber whose `start` call was turned away.
        #expect(!pump.shouldStop(subscribers: 0, requestsAtCheck: requestsAtCheck - 1))
    }

    // MARK: - What a subscriber is told

    /// Every phone is owed an opening, not only the one that started the watcher. One that
    /// subscribes while it is already running — a second device, or the same phone back
    /// from a dropped connection — used to hear only what changed after it arrived, and a
    /// Mac sitting still changes nothing: no status, no downloads, no renders.
    @Test func aPhoneThatJoinsARunningWatcherIsToldTheCurrentState() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("buddy-opening-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        BuddyTestStore.redirect()
        let model = AppModel(
            videoQueue: VideoBatchQueue(storeURL: folder.appendingPathComponent("queue.json")),
            settings: .init()
        )
        let hub = BuddyEventHub()
        let pump = BuddyEventPump()
        defer { pump.stop() }
        // In memory: nothing here may add entries to the owner's media table.
        let registry = MediaRegistry(url: nil)

        let first = await hub.subscribe(as: .device(id: "first", scope: .full))
        pump.start(watching: model, hub: hub, interval: .milliseconds(20), registry: registry)
        #expect(await Self.nextFrame(of: first.stream, within: .seconds(5)) == "status")
        // Long enough for several readings in which nothing moves.
        try await Task.sleep(for: .milliseconds(200))

        // What the server does for every stream it opens: subscribe, then ask it to watch.
        let second = await hub.subscribe(as: .device(id: "second", scope: .chat))
        pump.start(watching: model, hub: hub, interval: .milliseconds(20), registry: registry)
        #expect(await Self.nextFrame(of: second.stream, within: .seconds(5)) == "status")
        // And the first, which has it already, is not sent it again.
        #expect(await Self.nextFrame(of: first.stream, within: .milliseconds(300)) == nil)
    }

    /// The name of the next frame on a subscription, or nil if none comes in time.
    private static func nextFrame(
        of stream: AsyncStream<BuddyEvent.Frame>, within limit: Duration
    ) async -> String? {
        let reader = Task { () -> String? in
            for await frame in stream { return frame.name }
            return nil
        }
        // Cancelling the read ends it with nil, which is the answer when nothing came.
        let timer = Task {
            try? await Task.sleep(for: limit)
            reader.cancel()
        }
        defer { timer.cancel() }
        return await reader.value
    }

    @Test func theWatcherAnnouncesOnlyWhatMoved() {
        let idle = ControlAPI.Status(
            state: "idle", loadedModelID: nil, loadedModelName: nil, contextLength: nil,
            expertStreaming: false, lastGenerationTokensPerSecond: nil
        )
        let loaded = ControlAPI.Status(
            state: "running", loadedModelID: "qwen3-coder", loadedModelName: "Qwen3-Coder",
            contextLength: 16_384, expertStreaming: false, lastGenerationTokensPerSecond: 89
        )
        let download = ControlAPI.DownloadEvent(
            id: "qwen3-coder", name: "Qwen3-Coder", fraction: 0.25,
            bytesReceived: 250, bytesExpected: 1000, bytesPerSecond: 50
        )
        let job = ControlAPI.JobEvent(
            id: "clip-1", kind: "video", status: "running", title: "Opening shot", fraction: 0.4
        )

        // A phone that has just connected knows nothing, so the first reading is all news.
        let first = BuddyEventPump.Snapshot(
            status: idle, downloads: ["qwen3-coder": download], jobs: ["clip-1": job]
        )
        #expect(BuddyEventPump.changes(from: nil, to: first).map(\.name)
            == ["status", "download", "job"])
        #expect(BuddyEventPump.changes(from: first, to: first).isEmpty)

        var moved = first
        moved.status = loaded
        moved.downloads["qwen3-coder"]?.fraction = 0.5
        #expect(BuddyEventPump.changes(from: first, to: moved).map(\.name)
            == ["status", "download"])

        // A download that has gone from the reading is announced once more, as over — a
        // phone holds on to it until a frame says so — and is not mentioned after that.
        var without = moved
        without.downloads = [:]
        #expect(BuddyEventPump.changes(from: moved, to: without).map(\.name) == ["download"])
        #expect(BuddyEventPump.changes(from: without, to: without).isEmpty)
    }

    /// What leaves the reading is news as well. A phone keeps every transfer and render it
    /// was told about until a frame says it is over, so one that simply stopped being
    /// mentioned stayed "happening now" on it for ever. Each gets exactly one closing frame
    /// — a download as it ended, a render taken out of the queue as cancelled — and one
    /// whose last frame already said it was over gets none.
    @Test func whatLeavesTheReadingIsAnnouncedAsOverOnce() {
        let idle = ControlAPI.Status(
            state: "idle", loadedModelID: nil, loadedModelName: nil, contextLength: nil,
            expertStreaming: false, lastGenerationTokensPerSecond: nil
        )
        let fetching = ControlAPI.DownloadEvent(
            id: "qwen3-coder@Q4_K_M", name: "Qwen3-Coder", fraction: 0.4,
            bytesReceived: 400, bytesExpected: 1000, bytesPerSecond: 50
        )
        let broken = ControlAPI.DownloadEvent(
            id: "flux2-klein-4b", name: "FLUX.2 klein", fraction: 0.1, bytesReceived: 10,
            bytesExpected: 100, bytesPerSecond: 0, error: "The network went away."
        )
        let waiting = ControlAPI.JobEvent(
            id: "clip-1", kind: "video", status: "pending", title: "Opening shot"
        )
        let rendering = ControlAPI.JobEvent(
            id: "clip-2", kind: "video", status: "rendering", title: "The tram",
            fraction: 0.5, stage: "video-denoise 15/30"
        )
        let done = ControlAPI.JobEvent(
            id: "clip-3", kind: "video", status: "completed", title: "The river",
            mediaID: "bWVkaWEtY2xpcC1leGFt"
        )
        let before = BuddyEventPump.Snapshot(
            status: idle,
            downloads: [fetching.id: fetching, broken.id: broken],
            jobs: [waiting.id: waiting, rendering.id: rendering, done.id: done]
        )
        let after = BuddyEventPump.Snapshot(status: idle, downloads: [:], jobs: [:])

        func downloads(_ events: [BuddyEvent]) -> [ControlAPI.DownloadEvent] {
            events.compactMap { if case .download(let download) = $0 { download } else { nil } }
        }
        func jobs(_ events: [BuddyEvent]) -> [ControlAPI.JobEvent] {
            events.compactMap { if case .job(let job) = $0 { job } else { nil } }
        }

        let stopped = BuddyEventPump.changes(from: before, to: after)
        #expect(downloads(stopped).map(\.id) == [fetching.id])
        #expect(downloads(stopped).first?.error == BuddyEventPump.downloadStopped)
        #expect(downloads(stopped).first?.bytesPerSecond == 0)
        #expect(jobs(stopped).map(\.id) == [waiting.id, rendering.id])
        for job in jobs(stopped) {
            #expect(job.status == "cancelled")
            #expect(job.reason == BuddyEventPump.removedFromQueue)
            #expect(job.fraction == nil && job.stage == nil && job.mediaID == nil)
        }

        // A transfer that arrived says so, the way a phone model's does: all of it, nothing
        // wrong.
        let arrived = downloads(
            BuddyEventPump.changes(from: before, to: after, settling: BuddyEventPump.arrived)
        )
        #expect(arrived.first?.fraction == 1)
        #expect(arrived.first?.bytesReceived == 1000)
        #expect(arrived.first?.error == nil)

        #expect(BuddyEventPump.changes(from: after, to: after).isEmpty)
    }

    /// How a download that left the transfer list ended is read off what is installed now:
    /// the model it was fetching is here, or it is not.
    @Test func aDownloadThatLeftIsSettledByWhatIsInstalledNow() throws {
        BuddyTestStore.redirect()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("buddy-settle-\(UUID())")
        let model = AppModel(
            videoQueue: VideoBatchQueue(storeURL: folder.appendingPathComponent("queue.json")),
            settings: .init()
        )
        model.installedModels = [InstalledModel(
            id: "qwen3-coder@Q4_K_M", name: "Qwen3-Coder", catalogID: "qwen3-coder",
            quantization: .q4_K_M, format: .gguf,
            primaryFile: folder.appendingPathComponent("qwen3-coder.gguf"), allFiles: [],
            projectorFile: nil, sizeOnDisk: .zero, installedAt: Date(), shape: nil,
            capabilities: []
        )]
        func last(_ id: String) -> ControlAPI.DownloadEvent {
            .init(
                id: id, name: id, fraction: 0.97, bytesReceived: 970, bytesExpected: 1000,
                bytesPerSecond: 80
            )
        }

        let arrived = model.settledDownload(last("qwen3-coder@Q4_K_M"))
        #expect(arrived.fraction == 1 && arrived.error == nil)
        let stopped = model.settledDownload(last("qwen3-coder@Q8_0"))
        #expect(stopped.error == BuddyEventPump.downloadStopped)
        #expect(stopped.fraction == 0.97)
    }

    /// TRELLIS.2 counts as able to run once its environment is set up — it fetches its own
    /// 13 GB of weights mid-run if they are not there. A weights download stopped at the
    /// Mac leaves exactly that state, and must reach a phone as stopped, not arrived.
    @Test func aStoppedWeightsDownloadForARunnableModelIsNotArrived() throws {
        var settings = Settings()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("buddy-trellis-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        settings.trellisBaseDirectory = folder.path
        let python = folder.appendingPathComponent("trellis-mac/.venv/bin/python")
        try FileManager.default.createDirectory(
            at: python.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data().write(to: python)
        let model = BuddyTestStore.model(settings: settings)
        let installation = model.meshInstallation(for: MeshCatalog.trellis2)
        try #require(installation.isInstalled && installation.missing == .weights)

        let settled = model.settledDownload(.init(
            id: MeshCatalog.trellis2.id, name: MeshCatalog.trellis2.name, fraction: 0.3,
            bytesReceived: 3, bytesExpected: 10, bytesPerSecond: 1
        ))
        #expect(settled.error == BuddyEventPump.downloadStopped)
        #expect(settled.fraction == 0.3)
    }

    // MARK: - The Settings section

    /// A phone sending a hundred photographs is refused before any of them reach a model.
    @Test func attachmentsHaveACeiling() async throws {
        let model = isolatedModel()
        let summary = await model.createConversation(title: "Album")
        let many = (0..<BuddyLimits.imagesPerMessage + 1).map { "data:image/png;base64,\($0)" }
        #expect(BuddyLimits.refusal(forImages: many)?.contains("At most") == true)
        let huge = [String(repeating: "a", count: BuddyLimits.imageCharacters + 1)]
        #expect(BuddyLimits.refusal(forImages: huge)?.contains("too large") == true)
        #expect(BuddyLimits.refusal(forImages: ["data:image/png;base64,AAA"]) == nil)

        // Refused before the transcript is touched, like every other early refusal.
        await #expect(throws: ControlHostError.self) {
            _ = try await model.replyInConversation(
                id: summary.id, to: .init(content: "look", images: many)
            )
        }
        #expect(try await model.conversation(id: summary.id).messages.isEmpty)
    }

    @Test func theToggleDrivesTheRegisterAndPairingRefusesWhileItIsOff() async {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let center = BuddyCenter(registry: BuddyRegistry(url: file))

        await center.refresh(server: nil)
        #expect(!center.allowsTailnetDevices && center.devices.isEmpty)

        await center.pairDevice(server: nil)
        #expect(center.invitation == nil)
        #expect(center.problem?.contains("Turn Silicon Buddy on first") == true)

        await center.setAllowsTailnetDevices(true, server: nil)
        #expect(center.allowsTailnetDevices)
        // On, but with no listener there is no address to put in a QR — so no QR.
        await center.pairDevice(server: nil)
        #expect(center.invitation == nil)
        #expect(center.problem?.isEmpty == false)

        await center.setAllowsTailnetDevices(false, server: nil)
        #expect(await BuddyRegistry(url: file).allowsTailnetDevices == false)
    }

    @Test func aPairedDeviceIsListedAndCanBeRevokedFromTheWindow() async {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let registry = BuddyRegistry(url: file)
        let center = BuddyCenter(registry: registry)

        await registry.setAllowsTailnetDevices(true)
        let invitation = await registry.invite(host: "100.64.0.9", port: 8788)
        guard case .paired(let response) = await registry.pair(
            .init(code: invitation.code, deviceName: "Galaxy S24 Ultra", platform: "android"),
            from: "100.64.0.20", macName: "Studio", port: 8788
        ) else { Issue.record("pairing should succeed"); return }

        await center.refresh(server: nil)
        #expect(center.devices.map(\.name) == ["Galaxy S24 Ultra"])
        #expect(center.devices.map(\.scope) == ["full"])
        await center.revoke(response.deviceID)
        #expect(center.devices.isEmpty)
    }

    @Test func theQRCarriesTheLinkAPhoneCanActOn() throws {
        let url = BuddyPairing.pairingURL(host: "100.64.0.9", port: 8788, code: "123456")
        #expect(url == "siliconbuddy://pair?host=100.64.0.9&port=8788&code=123456")

        let components = try #require(URLComponents(string: url))
        #expect(components.scheme == "siliconbuddy")
        #expect(components.queryItems?.first { $0.name == "code" }?.value == "123456")

        let image = try #require(BuddyCenter.qrCode(for: url))
        // Scaled up, because the generator's native output is a few dozen pixels wide and a
        // camera cannot read that off a screen.
        #expect(image.width > 100 && image.width == image.height)
    }

    // MARK: - A code minted underneath the open sheet

    @Test func theSheetShowsTheScopeOfTheCodeRatherThanItsOwnPicker() async {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let registry = BuddyRegistry(url: file)
        let center = BuddyCenter(registry: registry)
        await registry.setAllowsTailnetDevices(true)

        let sheet = BuddyPairingSheet(buddy: center, server: nil, onClose: {})
        // Nothing on screen yet, so the picker can only offer what the next code would be.
        #expect(sheet.displayedScope == .full)

        // Minted underneath the open sheet — this is `POST /buddy/invitations`, which does
        // not go anywhere near the picker and carries a scope of its own.
        await registry.invite(host: "100.64.0.9", port: 8788, scope: .chat)
        await center.refresh(server: nil)
        #expect(center.invitation?.scope == .chat)
        #expect(sheet.displayedScope == .chat)
        #expect(BuddyPairingSheet.grantLine(.chat).contains("chat only"))

        // And the window's own last answer does not get to argue with it. This is the bug
        // the sheet had: a picker saying "full control" over a code that pairs chat-only.
        center.nextScope = .full
        #expect(sheet.displayedScope == .chat)

        // A code minted the other way round moves it back, for the same reason.
        await registry.invite(host: "100.64.0.9", port: 8788, scope: .full)
        await center.refresh(server: nil)
        #expect(sheet.displayedScope == .full)
        #expect(BuddyPairingSheet.grantLine(.full).contains("full control"))
    }

    @Test func aCodeIsBlankedWhenItsOwnExpiryArrives() async throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let registry = BuddyRegistry(url: file)
        let center = BuddyCenter(registry: registry)
        await registry.setAllowsTailnetDevices(true)

        // Long enough that a loaded machine cannot let it lapse between here and the
        // refresh below — an invitation already dead by then would never be adopted, and
        // this test would be checking nothing.
        let opened = await registry.invite(host: "100.64.0.9", port: 8788, lifetime: 3)
        await center.refresh(server: nil)
        #expect(center.invitation?.code == opened.code)

        // Adopting a code arms its expiry, whichever way the code arrived: the window must
        // never show a QR the server would now refuse. Polled rather than slept through, so
        // a slow machine costs time instead of a false failure.
        let deadline = ContinuousClock.now + .seconds(30)
        while center.invitation != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(center.invitation == nil)
    }

    @Test func aSupersededExpiryDoesNotBlankTheCodeThatReplacedIt() async throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let registry = BuddyRegistry(url: file)
        let center = BuddyCenter(registry: registry)
        await registry.setAllowsTailnetDevices(true)

        // On screen, and dying shortly — but not so shortly that a loaded machine could
        // let it lapse before the refresh below adopts it.
        let first = await registry.invite(host: "100.64.0.9", port: 8788, lifetime: 3)
        await center.refresh(server: nil)
        #expect(center.invitation?.code == first.code)

        // Minted underneath the sheet, replacing it with a code that has minutes to live.
        let second = await registry.invite(
            host: "100.64.0.9", port: 8788, scope: .chat, lifetime: 300
        )
        #expect(second.code != first.code)

        // The sheet's poll picks the new one up, which has to re-arm the expiry: the timer
        // still counting down belongs to a code that no longer exists.
        let paired = await center.followPairing(server: nil)
        #expect(!paired)
        #expect(center.invitation?.code == second.code)

        // Well past the first code's expiry, measured from the deadline itself rather than
        // guessed at. The live code is still on screen.
        let past = first.expiresAt.timeIntervalSinceNow + 1
        if past > 0 { try await Task.sleep(for: .seconds(past)) }
        #expect(first.expiresAt < Date())
        #expect(center.invitation?.code == second.code)
        #expect(center.invitation?.scope == .chat)

        await center.cancelInvitation()
        #expect(center.invitation == nil)
    }

    @Test func aDeviceThatHasNeverCalledInSaysSo() {
        let paired = ControlAPI.BuddyDeviceSummary(
            id: "a", name: "iPad mini", platform: "ipados",
            pairedAt: ControlAPI.timestamp(Date()), lastSeen: nil
        )
        #expect(BuddySettingsSection.describe(paired).contains("never seen"))
        #expect(BuddySettingsSection.describe(paired).contains("full control"))
        var seen = paired
        seen.lastSeen = ControlAPI.timestamp(Date())
        seen.scope = "chat"
        #expect(BuddySettingsSection.describe(seen).contains("last seen"))
        #expect(BuddySettingsSection.describe(seen).contains("chat only"))
    }
}

/// Points the conversation store at a scratch file, once, before any `AppModel` in this
/// process can write. The app reads the variable on every save, so setting it here is
/// enough — and the alternative is a test run silently replacing someone's chat history.
enum BuddyTestStore {
    private static let redirected: Bool = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("silicon-test-conversations-\(UUID()).json")
        setenv("SILICON_CONVERSATIONS_PATH", url.path, 1)
        return true
    }()

    static func redirect() { _ = redirected }

    /// An `AppModel` that reads and writes nothing of the owner's.
    ///
    /// `AppModel(settings:)` alone opens the owner's own video queue, and the `/events`
    /// watcher reads that queue and publishes every finished file in it into the shared
    /// media table — which it then saves, to the owner's `media.json`. So this one has an
    /// empty queue, output folders, a media table and a Hugging Face cache of its own, all
    /// under a temporary folder nothing else uses, and the conversation store redirected as
    /// every suite's is.
    @MainActor
    static func model(settings: Settings = .init()) -> AppModel {
        redirect()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("buddy-model-\(UUID())")
        var settings = settings
        settings.imageOutputDirectory = folder.appendingPathComponent("Images").path
        settings.meshOutputDirectory = folder.appendingPathComponent("Meshes").path
        settings.videoOutputDirectory = folder.appendingPathComponent("Videos").path
        let model = AppModel(
            videoQueue: VideoBatchQueue(storeURL: folder.appendingPathComponent("queue.json")),
            settings: settings
        )
        model.eventMediaRegistry = MediaRegistry(url: nil)
        model.trellisHubCache = folder.appendingPathComponent("hub")
        return model
    }
}

/// Applied to every suite that builds an `AppModel`, because any of them can schedule the
/// debounced save — and swift-testing has no bundle-wide hook to put this behind. The trait
/// runs before each test in the suite; the redirect itself happens once.
struct RedirectedConversationStore: SuiteTrait, TestTrait {
    func prepare(for test: Test) async throws { BuddyTestStore.redirect() }
}

extension Trait where Self == RedirectedConversationStore {
    static var redirectedConversationStore: Self { Self() }
}

/// The one test that runs the whole chain: a real `AppModel` as the host, a real control
/// server, and a real socket. Serialized because the event pump is a process-wide singleton
/// — it has to be, since `AppModel` is `@Observable` and an extension cannot hold its task.
@Suite("Silicon Buddy live events", .serialized, .redirectedConversationStore)
@MainActor
struct BuddyLiveEventTests {

    @Test func aChangeOnTheMacReachesASubscriberAsAStatusFrame() async throws {
        BuddyTestStore.redirect()
        BuddyEventPump.shared.stop()
        defer { BuddyEventPump.shared.stop() }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("buddy-live-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let model = BuddyTestStore.model()
        let hub = BuddyEventHub()
        let handshakeURL = directory.appendingPathComponent("control.json")
        let server = ControlServer(
            host: model, handshakeURL: handshakeURL,
            buddy: BuddyRegistry(url: directory.appendingPathComponent("buddy.json")),
            events: hub, media: MediaRegistry(url: nil),
            uploadsRoot: directory.appendingPathComponent("uploads"),
            postersRoot: directory.appendingPathComponent("posters"),
            discoverTailnetAddress: { nil }
        )
        try await server.start()
        defer { Task { await server.stop() } }

        let deadline = ContinuousClock.now + .seconds(5)
        while !FileManager.default.fileExists(atPath: handshakeURL.path) {
            guard ContinuousClock.now < deadline else { throw BuddyLiveError.timeout }
            try await Task.sleep(for: .milliseconds(20))
        }
        let handshake = try JSONDecoder().decode(
            ControlAPI.Handshake.self, from: try Data(contentsOf: handshakeURL)
        )

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        // Moved while the stream is open, so the frame that carries it can only have come
        // from the watcher noticing — not from the snapshot taken at connect.
        let changing = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            model.lastGeneration = GenerationMetrics(
                promptTokens: 12, generatedTokens: 34, generationTokensPerSecond: 77.5
            )
        }
        defer { changing.cancel() }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(handshake.port)/events")!)
        request.setValue("Bearer \(handshake.token)", forHTTPHeaderField: "Authorization")

        // Read inside a task, so cancelling it really hangs up: breaking out of the loop
        // leaves the URLSession task — and therefore the subscription — alive.
        let reading = Task { () -> Bool in
            let (bytes, response) = try await session.bytes(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            var name = ""
            for try await line in bytes.lines {
                if line.hasPrefix("event: ") {
                    name = String(line.dropFirst("event: ".count))
                } else if line.hasPrefix("data: "), name == "status" {
                    let payload = Data(line.dropFirst("data: ".count).utf8)
                    let status = try JSONDecoder().decode(ControlAPI.Status.self, from: payload)
                    if status.lastGenerationTokensPerSecond == 77.5 { return true }
                }
            }
            return false
        }
        #expect(try await reading.value)
        reading.cancel()

        // And the watcher stops on its own once nobody is reading, rather than sampling the
        // app once a second for the rest of the session.
        let idle = ContinuousClock.now + .seconds(10)
        while BuddyEventPump.shared.isRunning, ContinuousClock.now < idle {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(!BuddyEventPump.shared.isRunning)
    }
}

private enum BuddyLiveError: Error { case timeout }
