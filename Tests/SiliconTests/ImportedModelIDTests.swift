import Foundation
import Testing
@testable import SiliconCatalog
@testable import SiliconControl

/// An imported model's id is `external:` and its file's absolute path, and it reached the
/// swarm on three surfaces: `GET /installed`, `GET /status` and the `status` frames on
/// `/events`. A phone and this Mac's own tools load by that id, so they keep it; the swarm,
/// which cannot load anything here, is told one token for it on all three.
@Suite("Imported model ids and the swarm")
struct ImportedModelIDTests {

    private static let swarmToken = "test-shared-swarm-secret"
    private static let importedID =
        ModelLibrary.externalIDPrefix + NSHomeDirectory() + "/Models/qwen-local-q4.gguf"

    @Test func theSwarmIsToldOneTokenForAnImportedModelOnEverySurface() async throws {
        try await BuddyMediaFixture.withServer(swarmToken: Self.swarmToken) { fixture in
            await fixture.host.setInstalled(
                [Self.installed(Self.importedID), Self.installed("qwen3-4b")],
                status: Self.status(loaded: Self.importedID)
            )
            let phone = try await fixture.pair()

            var tokens: Set<String> = []
            for client in [fixture.phone, fixture.local] {
                let installed = try await Self.read(
                    [ControlAPI.InstalledModel].self, client, "/installed"
                )
                let status = try await Self.read(ControlAPI.Status.self, client, "/status")
                let frame = try await Self.firstStatusFrame(client, token: Self.swarmToken)

                let token = try #require(installed.first { $0.isLoaded }?.id)
                #expect(token.hasPrefix(ImportedModelID.prefix))
                #expect(token.count == ImportedModelID.prefix.count + 16)
                #expect(installed.map(\.id).contains("qwen3-4b"))
                #expect(status.loadedModelID == token)
                #expect(status.loadedModelName == "qwen-local-q4")
                #expect(frame.contains("\"loadedModelID\":\"\(token)\""))
                tokens.insert(token)
            }
            // The same model is the same token, whichever listener asked.
            #expect(tokens.count == 1)

            // A phone loads by the id, so it is told the id — on the same routes.
            let ownInstalled = try await Self.decode(
                [ControlAPI.InstalledModel].self,
                fixture.phone.call("GET", "/installed", token: phone.token)
            )
            #expect(ownInstalled.map(\.id).contains(Self.importedID))
            let phoneStatus = try await Self.decode(
                ControlAPI.Status.self, fixture.phone.call("GET", "/status", token: phone.token)
            )
            #expect(phoneStatus.loadedModelID == Self.importedID)
            let phoneFrame = try await Self.firstStatusFrame(fixture.phone, token: phone.token)
            #expect(phoneFrame.replacingOccurrences(of: "\\/", with: "/")
                .contains(Self.importedID))
            // And so is this Mac's own token.
            let local = try await Self.decode(
                ControlAPI.Status.self,
                fixture.local.call("GET", "/status", token: fixture.local.token)
            )
            #expect(local.loadedModelID == Self.importedID)
        }
    }

    /// A load's ending names models too: the one a failure belongs to, each load this Mac
    /// stopped, and the load that replaced it. Every one of them is the token for the swarm,
    /// the same token `loadedModelID` gets, on both listeners and on `/events` — and the id
    /// for a phone and for this Mac, which load by it.
    @Test func theSwarmIsToldTheTokenInALoadsEndingToo() async throws {
        let other = ModelLibrary.externalIDPrefix + NSHomeDirectory() + "/Models/gemma-local.gguf"
        var ending = Self.status(loaded: Self.importedID)
        ending.failure = .init(
            reason: "exited", detail: "error loading model", runtime: "llama.cpp",
            exitStatus: 1, at: "2026-09-19T11:04:38Z", modelID: other
        )
        ending.interruptedLoads = [
            .init(modelID: other, reason: "replaced", replacedBy: Self.importedID,
                  at: "2026-09-19T11:04:30Z"),
            .init(modelID: "qwen3-4b", reason: "cancelled", at: "2026-09-19T11:04:20Z"),
        ]
        try await BuddyMediaFixture.withServer(swarmToken: Self.swarmToken) { fixture in
            await fixture.host.setInstalled([Self.installed(Self.importedID)], status: ending)
            let phone = try await fixture.pair()
            let token = ImportedModelID.forPeers(Self.importedID)
            let otherToken = ImportedModelID.forPeers(other)

            for client in [fixture.phone, fixture.local] {
                let status = try await Self.read(ControlAPI.Status.self, client, "/status")
                let frame = try await Self.firstStatusFrame(client, token: Self.swarmToken)
                let pushed = try JSONDecoder().decode(ControlAPI.Status.self, from: Data(frame.utf8))
                for told in [status, pushed] {
                    #expect(told.loadedModelID == token)
                    #expect(told.failure?.modelID == otherToken)
                    #expect(told.interruptedLoads?.map(\.modelID) == [otherToken, "qwen3-4b"])
                    #expect(told.interruptedLoads?.map(\.replacedBy) == [token, nil])
                    // Nothing else about the ending changes.
                    #expect(told.failure?.reason == "exited")
                    #expect(told.failure?.detail == nil)
                    #expect(told.interruptedLoads?.map(\.reason) == ["replaced", "cancelled"])
                }
            }

            // A phone and this Mac load by the id, so the ending names it as it is.
            let phoneStatus = try await Self.decode(
                ControlAPI.Status.self, fixture.phone.call("GET", "/status", token: phone.token)
            )
            let phoneFrame = try JSONDecoder().decode(
                ControlAPI.Status.self,
                from: Data(try await Self.firstStatusFrame(fixture.phone, token: phone.token).utf8)
            )
            let local = try await Self.decode(
                ControlAPI.Status.self,
                fixture.local.call("GET", "/status", token: fixture.local.token)
            )
            for told in [phoneStatus, phoneFrame, local] {
                #expect(told.failure?.modelID == other)
                #expect(told.interruptedLoads?.map(\.modelID) == [other, "qwen3-4b"])
                #expect(told.interruptedLoads?.first?.replacedBy == Self.importedID)
            }
        }
    }

    /// What `forPeers` does to a status: the id wherever it appears, the home folder in the
    /// state line, the runtime's log withheld — and nothing to a model that was downloaded.
    @Test func aPeersStatusNamesNoPathAndLeavesACatalogModelAlone() {
        var status = Self.status(loaded: Self.importedID)
        status.state = "Could not start \(Self.importedID): \(NSHomeDirectory())/Library/x.log"
        status.failure = .init(reason: "exited", detail: "llama-server: bad file", at: "now")
        let peer = status.forPeers
        let token = ImportedModelID.forPeers(Self.importedID)
        #expect(peer.loadedModelID == token)
        #expect(peer.state == "Could not start \(token): ~/Library/x.log")
        #expect(peer.failure?.detail == nil)
        #expect(peer.failure?.reason == "exited")

        #expect(Self.status(loaded: "qwen3-4b").forPeers.loadedModelID == "qwen3-4b")
        // And in a load's ending, where a catalog model is left alone just the same.
        var ended = Self.status(loaded: "qwen3-4b")
        ended.failure = .init(reason: "exited", at: "now", modelID: Self.importedID)
        ended.interruptedLoads = [.init(
            modelID: "qwen3-4b", reason: "replaced", replacedBy: Self.importedID, at: "now"
        )]
        #expect(ended.forPeers.failure?.modelID == token)
        #expect(ended.forPeers.interruptedLoads?.first?.modelID == "qwen3-4b")
        #expect(ended.forPeers.interruptedLoads?.first?.replacedBy == token)
        #expect(Self.status(loaded: "qwen3-4b").forPeers.interruptedLoads == nil)
        #expect(ImportedModelID.forPeers("qwen3-4b") == "qwen3-4b")
        // Stable for the same model, different for a different one.
        #expect(ImportedModelID.forPeers(Self.importedID) == token)
        #expect(ImportedModelID.forPeers(Self.importedID + "x") != token)
    }

    /// The hub sends each audience its own shape of one status frame.
    @Test func theEventHubTellsOnlyThePeerTheToken() async throws {
        let hub = BuddyEventHub()
        let peer = await hub.subscribe(as: .peer)
        let phone = await hub.subscribe(as: .device(id: "phone", scope: .full))
        let mac = await hub.subscribe(as: .thisMac)
        await hub.post(.status(Self.status(loaded: Self.importedID)))

        func loadedID(
            _ subscription: (id: UUID, stream: AsyncStream<BuddyEvent.Frame>)
        ) async throws -> String? {
            var iterator = subscription.stream.makeAsyncIterator()
            let frame = try #require(await iterator.next())
            #expect(frame.name == "status")
            return try JSONDecoder().decode(ControlAPI.Status.self, from: frame.data).loadedModelID
        }
        #expect(try await loadedID(peer) == ImportedModelID.forPeers(Self.importedID))
        #expect(try await loadedID(phone) == Self.importedID)
        #expect(try await loadedID(mac) == Self.importedID)
        for subscription in [peer, phone, mac] { await hub.cancel(subscription.id) }
    }

    /// The same, for the ids a load's ending carries.
    @Test func theEventHubTellsOnlyThePeerTheTokenForALoadsEnding() async throws {
        let hub = BuddyEventHub()
        let peer = await hub.subscribe(as: .peer)
        let chat = await hub.subscribe(as: .device(id: "phone", scope: .chat))
        let mac = await hub.subscribe(as: .thisMac)
        var ending = Self.status(loaded: "qwen3-4b")
        ending.failure = .init(reason: "exited", detail: "log", at: "now", modelID: Self.importedID)
        ending.interruptedLoads = [.init(
            modelID: Self.importedID, reason: "replaced", replacedBy: "qwen3-4b", at: "now"
        )]
        await hub.post(.status(ending))

        func told(
            _ subscription: (id: UUID, stream: AsyncStream<BuddyEvent.Frame>)
        ) async throws -> ControlAPI.Status {
            var iterator = subscription.stream.makeAsyncIterator()
            let frame = try #require(await iterator.next())
            return try JSONDecoder().decode(ControlAPI.Status.self, from: frame.data)
        }
        let token = ImportedModelID.forPeers(Self.importedID)
        let peerSaw = try await told(peer)
        #expect(peerSaw.failure?.modelID == token)
        #expect(peerSaw.interruptedLoads?.first?.modelID == token)
        #expect(peerSaw.interruptedLoads?.first?.replacedBy == "qwen3-4b")
        // A chat-scope phone loses the log and keeps the ids; this Mac keeps both.
        let chatSaw = try await told(chat)
        #expect(chatSaw.failure?.modelID == Self.importedID)
        #expect(chatSaw.failure?.detail == nil)
        #expect(chatSaw.interruptedLoads?.first?.modelID == Self.importedID)
        let macSaw = try await told(mac)
        #expect(macSaw.failure?.modelID == Self.importedID)
        #expect(macSaw.failure?.detail == "log")
        for subscription in [peer, chat, mac] { await hub.cancel(subscription.id) }
    }

    /// Two modules, one word: the library writes it, the control server looks for it.
    @Test func theLibraryAndTheServerAgreeWhatAnImportedIdLooksLike() {
        #expect(ModelLibrary.externalIDPrefix == ImportedModelID.prefix)
    }

    // MARK: - Helpers

    private static func installed(_ id: String) -> ControlAPI.InstalledModel {
        .init(
            id: id, name: id == importedID ? "qwen-local-q4" : id, quantization: "Q4_K_M",
            sizeOnDiskBytes: 1, isLoaded: id == importedID, supportsVision: false
        )
    }

    private static func status(loaded id: String) -> ControlAPI.Status {
        .init(
            state: "Ready", loadedModelID: id,
            loadedModelName: id == importedID ? "qwen-local-q4" : id,
            contextLength: 8192, expertStreaming: false, lastGenerationTokensPerSecond: nil
        )
    }

    /// A swarm route's answer, after checking the path is nowhere in it.
    private static func read<Answer: Decodable>(
        _ type: Answer.Type, _ client: TestClient, _ path: String
    ) async throws -> Answer {
        let (status, data) = try await client.call("GET", path, token: swarmToken)
        #expect(status == 200, "\(path)")
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\\/", with: "/")
        #expect(!text.contains(NSHomeDirectory()), "\(path) named the home folder")
        return try JSONDecoder().decode(type, from: data)
    }

    private static func decode<Answer: Decodable>(
        _ type: Answer.Type, _ reply: (Int, Data)
    ) throws -> Answer {
        #expect(reply.0 == 200)
        return try JSONDecoder().decode(type, from: reply.1)
    }

    /// The first `status` frame on `/events`, raw. For the swarm, checked for the path too.
    private static func firstStatusFrame(_ client: TestClient, token: String) async throws -> String {
        let frames = try await client.events("GET", "/events", token: token, body: nil) {
            $0.contains { $0.name == "status" }
        }
        let frame = try #require(frames.first { $0.name == "status" }).data
        if token == swarmToken {
            #expect(!frame.replacingOccurrences(of: "\\/", with: "/").contains(NSHomeDirectory()))
        }
        return frame
    }
}
