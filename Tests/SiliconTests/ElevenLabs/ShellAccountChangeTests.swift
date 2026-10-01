import Foundation
import Testing
@testable import SiliconElevenLabs
@testable import SiliconUI

/// Nothing from one account outlives it into the next. A question asked for account A is
/// declined when A goes: confirming it later would run it with B's key. A run in flight is
/// cancelled and its late answer or refusal lands nowhere. And while a request that may be
/// billed is still on the wire, the region cannot switch under it: a fresh runner on the same
/// account could send it again. Probe shapes from the shell critic (P3, P5, R4c).
@Suite("ElevenLabs account changes")
@MainActor
struct ShellAccountChangeTests {

    typealias Gate = ShellRunnerGenerationTests.Gate

    @Test func aQuestionAskedForOneAccountIsDeclinedWhenItGoes() async throws {
        let (model, transport, _) = ShellSettingsTests.model(linkedKey: "fixture-key-account-a-0001") { request in
            if request.url.path.hasPrefix("/v1/user") { return ShellSettingsTests.accountAnswer(request) }
            return .json(["status": "ok"])
        }
        defer { ShellSettingsTests.clean(model, transport) }
        let runner = try #require(ElevenLabsRunner(operationID: "delete_voice", model: model))
        let running = Task { await runner.perform(arguments: ["voice_id": "voice-of-account-a"]) }
        try await ShellExplorerTests.waitUntil { runner.phase == .awaitingConfirmation }
        #expect(model.elevenLabsPane.confirming === runner)

        model.disconnectElevenLabs()
        #expect(model.elevenLabsPane.confirming == nil)
        #expect(await running.value == nil)
        #expect(runner.phase == .idle)

        await model.elevenLabsLink.pendingRemoval?.value
        _ = try await model.linkElevenLabs(key: "fixture-key-account-b-0002")
        runner.confirm()
        #expect(transport.requests.filter { $0.method == "DELETE" }.isEmpty)
    }

    @Test func aRunInFlightWhenTheAccountChangesLandsNowhere() async throws {
        let gate = Gate()
        let (model, transport, _) = ShellSettingsTests.model(linkedKey: "fixture-key-account-a-0001") { request in
            if request.url.path.hasPrefix("/v1/user") { return ShellSettingsTests.accountAnswer(request) }
            await gate.wait()
            return .jsonText(#"{"detail":{"status":"invalid_api_key","message":"Invalid API key"}}"#, status: 401)
        }
        defer { ShellSettingsTests.clean(model, transport) }
        let runner = try #require(ElevenLabsRunner(operationID: "get_models", model: model))
        let running = Task { await runner.perform(arguments: [:]) }
        try await ShellExplorerTests.waitUntil { runner.phase == .running }

        model.disconnectElevenLabs()
        #expect(runner.phase == .cancelled)
        await model.elevenLabsLink.pendingRemoval?.value
        _ = try await model.linkElevenLabs(key: "fixture-key-account-b-0002")

        gate.open()
        #expect(await running.value == nil)
        #expect(model.elevenLabsPane.recents.isEmpty)
        #expect(model.elevenLabsPane.connectionProblem == nil, "account A's refused key raised B's banner")
    }

    @Test func aBillableRunCutOffByDisconnectSaysItMayHaveBeenBilled() async throws {
        let gate = Gate()
        let (model, transport, _) = ShellSettingsTests.model(linkedKey: "fixture-key-account-a-0001") { _ in
            await gate.wait()
            return .audio(Data([1]))
        }
        defer { ShellSettingsTests.clean(model, transport) }
        let runner = try #require(ElevenLabsRunner(operationID: "text_to_speech_full", model: model))
        let running = Task { await runner.perform(arguments: ["voice_id": "v1", "text": "Hi"]) }
        try await ShellExplorerTests.waitUntil { runner.phase == .running }
        #expect(model.elevenLabsPane.billableRunsInFlight == 1)
        model.disconnectElevenLabs()
        #expect(runner.cancellationNote == ElevenLabsRunner.cancelledAfterSendingMessage)
        // Still on the wire until the request ends.
        #expect(model.elevenLabsPane.billableRunsInFlight == 1)
        gate.open()
        _ = await running.value
        #expect(model.elevenLabsPane.billableRunsInFlight == 0)
        #expect(model.elevenLabsPane.recents.isEmpty)
    }

    /// Global → US keeps the key, and would rebuild every runner. With a billable request
    /// still in flight that would hand out an idle runner that could send it again, so the
    /// switch is refused until it ends.
    @Test func theRegionDoesNotSwitchUnderABillableRunInFlight() async throws {
        let gate = Gate()
        let counter = ShellRunnerGenerationTests.Counter()
        let (model, transport, _) = ShellSettingsTests.model(linkedKey: "fixture-key-region-0001") { request in
            if request.url.path.hasPrefix("/v1/user") { return ShellSettingsTests.accountAnswer(request) }
            if counter.next() == 1 { await gate.wait() }
            return .audio(Data([7]))
        }
        defer { ShellSettingsTests.clean(model, transport) }
        let pane = model.elevenLabsPane
        let first = try #require(pane.explorer(context: .app(model)).session(for: "text_to_speech_full"))
        let arguments: [String: JSONValue] = ["voice_id": "v1", "text": "Hi"]
        let running = Task { await first.runner.perform(arguments: arguments) }
        try await ShellExplorerTests.waitUntil {
            first.runner.phase == .running && transport.requests.contains { $0.url.path.hasPrefix("/v1/text-to-speech") }
        }

        let connection = ElevenLabsConnectionModel()
        connection.requestRegion(.us, model: model)
        #expect(connection.pendingRegionChange == nil)
        #expect(connection.regionNotice == ElevenLabsConnectionModel.busyAccountMessage)
        await connection.switchRegionKeepingKey(model: model)
        #expect(model.elevenLabsRegion == .global)

        let second = try #require(pane.explorer(context: .app(model)).session(for: "text_to_speech_full"))
        #expect(second.runner === first.runner)
        #expect(await second.runner.perform(arguments: arguments) == nil)
        #expect(transport.requests.filter { $0.url.path.hasPrefix("/v1/text-to-speech") }.count == 1)

        gate.open()
        _ = await running.value
        #expect(pane.billableRunsInFlight == 0)
        connection.requestRegion(.us, model: model)
        #expect(connection.pendingRegionChange?.to == .us)
    }

    @Test func aNewKeyIsRefusedWhileABillableRunIsInFlight() async throws {
        let gate = Gate()
        let (model, transport, store) = ShellSettingsTests.model(linkedKey: ShellSettingsTests.key) { request in
            if request.url.path.hasPrefix("/v1/user") { return ShellSettingsTests.accountAnswer(request) }
            await gate.wait()
            return .audio(Data([1]))
        }
        defer { ShellSettingsTests.clean(model, transport) }
        let runner = try #require(ElevenLabsRunner(operationID: "text_to_speech_full", model: model))
        let running = Task { await runner.perform(arguments: ["voice_id": "v1", "text": "Hi"]) }
        try await ShellExplorerTests.waitUntil { runner.phase == .running }
        let connection = ElevenLabsConnectionModel()
        #expect(await connection.connect(key: ShellSettingsTests.candidate, model: model) == false)
        #expect(connection.failure == ElevenLabsConnectionModel.busyAccountMessage)
        #expect(store.key == ShellSettingsTests.key)
        gate.open()
        _ = await running.value
    }
}

/// The same guarantees wherever the account change is noticed — in the section store, not
/// only in `reset()` — and by the runner itself when a question is answered after the account
/// or region moved. Probe shapes from the agents critic and the creative critic (C1).
@Suite("ElevenLabs account changes, wherever they are noticed")
@MainActor
struct ShellAccountChangeDetectionTests {

    typealias Box = ShellSharedPartsTests.ClientBox

    @Test func theSectionStoreNoticingAnotherAccountDeclinesItsQuestions() async throws {
        let box = Box()
        let transport = FakeElevenLabsTransport(replies: [.json(["status": "ok"])])
        let sink = TemporaryFileSink()
        defer { transport.removeTemporaryFiles(); sink.removeAll() }
        box.client = ShellSharedPartsTests.client(transport: transport, sink: sink)
        let pane = ElevenLabsPaneState(defaults: nil, client: { box.client })
        _ = pane.state(for: .agentBatchCalls) { ShellSharedPartsTests.Marker() }
        let runner = try #require(ElevenLabsRunner(
            operationID: "delete_voice", context: .init(client: { box.client }, sink: { sink }, pane: pane)
        ))
        let running = Task { await runner.perform(arguments: ["voice_id": "v1"]) }
        try await ShellExplorerTests.waitUntil { runner.phase == .awaitingConfirmation }

        box.client = ShellSharedPartsTests.client(region: .us, transport: transport, sink: sink)
        _ = pane.state(for: .agentBatchCalls) { ShellSharedPartsTests.Marker() }
        #expect(pane.confirming == nil)
        #expect(await running.value == nil)
        runner.confirm()
        #expect(transport.requests.isEmpty)
    }

    /// With no pane to notice anything, the runner checks for itself when the answer comes.
    @Test func anAnswerGivenAfterTheRegionMovedSendsNothing() async throws {
        let box = Box()
        let transport = FakeElevenLabsTransport(replies: [.json(["status": "ok"])])
        let sink = TemporaryFileSink()
        defer { transport.removeTemporaryFiles(); sink.removeAll() }
        box.client = ShellSharedPartsTests.client(transport: transport, sink: sink)
        let runner = try #require(ElevenLabsRunner(operationID: "delete_voice", context: .init(client: { box.client }, sink: { sink })))
        let running = Task { await runner.perform(arguments: ["voice_id": "v1"]) }
        try await ShellExplorerTests.waitUntil { runner.phase == .awaitingConfirmation }
        box.client = ShellSharedPartsTests.client(region: .us, transport: transport, sink: sink)
        runner.confirm()
        #expect(await running.value == nil)
        #expect(runner.failure == .accountChanged)
        #expect(transport.requests.isEmpty)
    }

    /// The agents critic's probe: a batch-call question on screen, Global → US in Settings,
    /// then the old question confirmed — it must not place calls through the old client.
    @Test func aBatchQuestionDoesNotSurviveARegionSwitch() async throws {
        let (model, transport, _) = ShellSettingsTests.model(linkedKey: "fixture-key-batch-0001") { request in
            if request.url.path.hasPrefix("/v1/user") { return ShellSettingsTests.accountAnswer(request) }
            return .json(["id": "batch-1"])
        }
        defer { ShellSettingsTests.clean(model, transport) }
        let runner = try #require(ElevenLabsRunner(operationID: "create_batch_call", model: model))
        #expect(runner.operation.risk == .realWorld)
        let arguments: [String: JSONValue] = [
            "call_name": "Monday", "agent_id": "agent-1",
            "recipients": [["phone_number": "+15555550100"], ["phone_number": "+15555550101"]],
        ]
        let running = Task { await runner.perform(arguments: arguments, subject: "2 phone calls with “Front desk”") }
        try await ShellExplorerTests.waitUntil { runner.phase == .awaitingConfirmation || runner.phase == .failed }
        if runner.phase == .failed {
            // The client refused the empty arguments before asking; give it what it needs.
            Issue.record("create_batch_call needs arguments for this test: \(runner.problems)")
            return
        }
        let connection = ElevenLabsConnectionModel()
        connection.requestRegion(.us, model: model)
        await connection.switchRegionKeepingKey(model: model)
        #expect(model.elevenLabsRegion == .us)
        runner.confirm()
        _ = await running.value
        #expect(transport.requests.filter { $0.url.path.contains("batch-calling") }.isEmpty)
    }

    @Test func aBillableRequestCutOffByAnAccountChangeLeavesANotice() async throws {
        let gate = ShellRunnerGenerationTests.Gate()
        let (model, transport, _) = ShellSettingsTests.model(linkedKey: "fixture-key-account-a-0001") { _ in
            await gate.wait()
            return .audio(Data([1]))
        }
        defer { ShellSettingsTests.clean(model, transport) }
        let runner = try #require(ElevenLabsRunner(operationID: "text_to_speech_full", model: model))
        let running = Task { await runner.perform(arguments: ["voice_id": "v1", "text": "Hi"]) }
        try await ShellExplorerTests.waitUntil { runner.phase == .running }
        #expect(model.elevenLabsPane.previousAccountNotice == nil)
        model.disconnectElevenLabs()
        #expect(model.elevenLabsPane.previousAccountNotice == ElevenLabsPaneState.previousAccountMessage)
        gate.open()
        _ = await running.value
    }

    @Test func aReadCutOffLeavesNoNotice() async throws {
        let gate = ShellRunnerGenerationTests.Gate()
        let (model, transport, _) = ShellSettingsTests.model(linkedKey: "fixture-key-account-a-0001") { _ in
            await gate.wait()
            return .json(["models": []])
        }
        defer { ShellSettingsTests.clean(model, transport) }
        let runner = try #require(ElevenLabsRunner(operationID: "get_models", model: model))
        let running = Task { await runner.perform(arguments: [:]) }
        try await ShellExplorerTests.waitUntil { runner.phase == .running }
        model.disconnectElevenLabs()
        #expect(model.elevenLabsPane.previousAccountNotice == nil)
        gate.open()
        _ = await running.value
    }

    /// C1: an account is its client object, not its address — a freed client's address can be
    /// handed to the next one. Every replacement must read as another account.
    @Test func everyNewClientIsAnotherAccountEvenAtARecycledAddress() {
        let box = Box()
        let pane = ElevenLabsPaneState(defaults: nil, client: { box.client })
        box.client = ShellSharedPartsTests.client()
        var previous = pane.state(for: .speech) { ShellSharedPartsTests.Marker() }
        var kept = 0
        for _ in 0..<200 {
            box.client = nil
            box.client = ShellSharedPartsTests.client()
            let now = pane.state(for: .speech) { ShellSharedPartsTests.Marker() }
            if now === previous { kept += 1 }
            previous = now
        }
        #expect(kept == 0, "\(kept) of 200 new clients were taken for the old account")
    }
}
