import Foundation
import Network
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
        BuddyTestStore.redirect()
        let redirected = ProcessInfo.processInfo.environment["SILICON_CONVERSATIONS_PATH"]
        #expect(redirected?.contains("silicon-test-conversations") == true)
        return AppModel(settings: .init())
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

        // A finished download stops being mentioned rather than being announced as gone;
        // the phone's own list is what forgets it.
        var without = moved
        without.downloads = [:]
        #expect(BuddyEventPump.changes(from: moved, to: without).isEmpty)
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

        let model = AppModel(settings: .init())
        let hub = BuddyEventHub()
        let handshakeURL = directory.appendingPathComponent("control.json")
        let server = ControlServer(
            host: model, handshakeURL: handshakeURL,
            buddy: BuddyRegistry(url: directory.appendingPathComponent("buddy.json")),
            events: hub, discoverTailnetAddress: { nil }
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
