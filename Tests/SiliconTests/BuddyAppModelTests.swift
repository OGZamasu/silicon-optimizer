import Foundation
import Testing
@testable import SiliconControl
@testable import SiliconRuntime
@testable import SiliconUI

/// The Mac's own half: the conversation store a phone reads and writes, what the `/events`
/// watcher decides is news, and the Settings section's state.
@Suite("Silicon Buddy on the Mac")
@MainActor
struct BuddyAppModelTests {

    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("buddy-\(UUID()).json")
    }

    // MARK: - Conversations

    @Test func aConversationStartedFromAPhoneIsTheMacsOwn() async throws {
        let model = AppModel(settings: .init())
        let summary = await model.createConversation(title: "Weekend plans")

        #expect(summary.title == "Weekend plans" && summary.messageCount == 0)
        // Selected, so the owner looking over sees what the phone started.
        #expect(model.selectedConversationID?.uuidString == summary.id)
        #expect(await model.conversationList().map(\.id) == [summary.id])

        // An untitled request keeps the Mac's own placeholder rather than inventing one.
        let blank = await model.createConversation(title: "   ")
        #expect(blank.title == Conversation.untitled)
    }

    @Test func aTranscriptComesBackWithoutItsImages() async throws {
        let model = AppModel(settings: .init())
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
        let model = AppModel(settings: .init())
        let missing = UUID().uuidString
        await #expect(throws: BuddyHostError.noSuchConversation(missing)) {
            _ = try await model.conversation(id: missing)
        }
    }

    /// Nothing streams without a model, and nothing is written to the transcript either —
    /// a phone that asks too early must not leave an empty exchange behind.
    @Test func streamingWithoutALoadedModelChangesNothing() async throws {
        let model = AppModel(settings: .init())
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

        let invitation = await registry.invite(host: "100.64.0.9", port: 8788)
        guard case .paired(let response) = await registry.pair(
            .init(code: invitation.code, deviceName: "Galaxy S24 Ultra", platform: "android"),
            from: "100.64.0.20", macName: "Studio", port: 8788
        ) else { Issue.record("pairing should succeed"); return }

        await center.refresh(server: nil)
        #expect(center.devices.map(\.name) == ["Galaxy S24 Ultra"])
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
        var seen = paired
        seen.lastSeen = ControlAPI.timestamp(Date())
        #expect(BuddySettingsSection.describe(seen).contains("last seen"))
    }
}
