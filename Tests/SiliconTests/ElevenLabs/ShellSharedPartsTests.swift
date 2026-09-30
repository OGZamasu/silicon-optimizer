import Foundation
import Testing
import SiliconElevenLabs
@testable import SiliconUI

/// What the section builders asked the shared parts for: confirmations the pane always shows,
/// and section state (and the voices list) that never outlives its account.
@Suite("ElevenLabs shared parts")
@MainActor
struct ShellSharedPartsTests {

    // MARK: - Confirmation hosted by the pane

    @Test func thePaneShowsARunnersQuestionWithoutTheSectionHostingIt() async throws {
        let fixture = ShellExplorerTests.Fixture(replies: [.json(["status": "ok"])])
        defer { fixture.clean() }
        let runner = try #require(ElevenLabsRunner(operationID: "delete_voice", context: fixture.context))
        #expect(!runner.presentsOwnConfirmation)
        let running = Task { await runner.perform(arguments: ["voice_id": "v9"]) }
        try await ShellExplorerTests.waitUntil { runner.phase == .awaitingConfirmation }
        #expect(fixture.pane.confirming === runner)
        fixture.pane.confirming?.decline()
        _ = await running.value
        #expect(fixture.pane.confirming == nil)
        #expect(fixture.transport.requests.isEmpty)
    }

    @Test func twoQuestionsAreAskedOneAfterTheOther() async throws {
        let fixture = ShellExplorerTests.Fixture(replies: [.json(["status": "ok"]), .json(["status": "ok"])])
        defer { fixture.clean() }
        let first = try #require(ElevenLabsRunner(operationID: "delete_voice", context: fixture.context))
        let second = try #require(ElevenLabsRunner(operationID: "delete_voice", context: fixture.context))
        let one = Task { await first.perform(arguments: ["voice_id": "a"]) }
        try await ShellExplorerTests.waitUntil { first.phase == .awaitingConfirmation }
        let two = Task { await second.perform(arguments: ["voice_id": "b"]) }
        try await ShellExplorerTests.waitUntil { second.phase == .awaitingConfirmation }
        #expect(fixture.pane.confirming === first)
        first.confirm()
        _ = await one.value
        #expect(fixture.pane.confirming === second)
        second.decline()
        _ = await two.value
        #expect(fixture.pane.confirming == nil)
        #expect(fixture.transport.requests.map(\.url.lastPathComponent) == ["a"])
    }

    @Test func aRunnerWithNoPaneAsksItsOwnHost() {
        let runner = ElevenLabsRunner(operation: ShellInterfaceTests.operation(id: "x"), context: .init(client: { nil }))
        #expect(runner.presentsOwnConfirmation)
    }

    // MARK: - Section state

    @Test func sectionStateLastsUntilTheAccountChanges() {
        let box = ClientBox()
        box.client = Self.client()
        let pane = ElevenLabsPaneState(defaults: nil, client: { box.client })
        let first = pane.state(for: .speech) { Marker() }
        #expect(pane.state(for: .speech) { Marker() } === first)
        #expect(pane.state(for: .music) { Marker() } !== first)
        #expect(pane.state(key: "shared") { Marker() } === pane.state(key: "shared") { Marker() })

        // Another region or key means another client: everything starts over.
        box.client = Self.client(region: .eu)
        #expect(pane.state(for: .speech) { Marker() } !== first)

        let again = pane.state(for: .speech) { Marker() }
        pane.reset()
        #expect(pane.state(for: .speech) { Marker() } !== again)

        let beforeDisconnect = pane.state(for: .speech) { Marker() }
        box.client = nil
        #expect(pane.state(for: .speech) { Marker() } !== beforeDisconnect)
    }

    @Test func theVoicesListIsFetchedAgainForAnotherAccount() async {
        let box = ClientBox()
        let transport = FakeElevenLabsTransport { request in
            .json(["voices": [["voice_id": request.url.host == "api.eu.residency.elevenlabs.io" ? "eu-voice" : "global-voice",
                               "name": "V"]], "has_more": false])
        }
        let sink = TemporaryFileSink()
        defer { transport.removeTemporaryFiles(); sink.removeAll() }
        box.client = Self.client(transport: transport, sink: sink)
        let directory = ElevenLabsVoiceDirectory(client: { box.client })
        await directory.loadIfNeeded()
        #expect(directory.voices.map(\.id) == ["global-voice"])
        box.client = Self.client(region: .eu, transport: transport, sink: sink)
        await directory.loadIfNeeded()
        #expect(directory.voices.map(\.id) == ["eu-voice"])
    }

    // MARK: - Helpers

    final class Marker {}

    @MainActor final class ClientBox {
        var client: ElevenLabsClient?
    }

    static func client(
        region: ElevenLabsRegion = .global, transport: FakeElevenLabsTransport? = nil, sink: TemporaryFileSink? = nil
    ) -> ElevenLabsClient {
        ElevenLabsClient(
            credentials: FakeCredentialSource(key: "fixture-key-shared-0001"), region: region,
            transport: transport ?? FakeElevenLabsTransport(replies: []), sink: sink ?? TemporaryFileSink()
        )
    }
}
