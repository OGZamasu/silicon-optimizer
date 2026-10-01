import Foundation
import Testing
@testable import SiliconElevenLabs
@testable import SiliconUI

/// Agents: changes whose answer was lost though they may have been carried out (a 500 after
/// the work). Creates of something real are held until the owner has checked, and their list is
/// read again; a save is read again into the editor's base, the owner's edits kept.
extension AgentsSectionsTests {
    @MainActor final class LostDone { var value = false }

    /// Runs `action`, confirming every question `runners` put up.
    func confirming(_ runners: [ElevenLabsRunner], _ action: @escaping @MainActor () async -> Void) async throws {
        let done = LostDone()
        let task = Task { await action(); done.value = true }
        try await waitUntil {
            for runner in runners where runner.isAwaitingConfirmation { runner.confirm() }
            return done.value
        }
        await task.value
    }

    /// A rig whose first answer to each of `losing` is lost (a 500), the work done.
    func losingRig(_ losing: Set<String>, refusing: Set<String> = []) -> AgentsFixtures.Rig {
        final class Seen: @unchecked Sendable {
            let lock = NSLock()
            var answered: Set<String> = []
        }
        let seen = Seen()
        return AgentsFixtures.Rig { request in
            let operationID = request.operationID
            if refusing.contains(operationID) {
                return .jsonText(#"{"detail":{"status":"invalid","message":"Not allowed"}}"#, status: 422)
            }
            let lose = seen.lock.withLock { losing.contains(operationID) && seen.answered.insert(operationID).inserted }
            if lose { return .jsonText(#"{"detail":"Internal error"}"#, status: 500) }
            return try await AgentsFixtures.reply(request)
        }
    }

    struct LostCreate {
        var operationID: String
        var listOperationID: String
        var fill: @MainActor (AgentsPlatformStore) -> Void
        var create: @MainActor (AgentsPlatformStore) async -> Void
    }

    var lostCreates: [LostCreate] {
        [
            LostCreate(operationID: AgentsOp.createAgent, listOperationID: AgentsOp.listAgents, fill: { store in
                store.agents.startCreating()
                store.agents.newDraft.name = "Front desk"
            }, create: { await $0.agents.create() }),
            LostCreate(operationID: AgentsOp.createTool, listOperationID: AgentsOp.listTools, fill: { store in
                store.tools.startCreating()
                store.tools.newTool.name = "lookup_order"
                store.tools.newTool.description = "Finds an order by its number"
                store.tools.newTool.url = "https://api.example.com/orders"
            }, create: { await $0.tools.create() }),
            LostCreate(operationID: AgentsOp.createSecret, listOperationID: AgentsOp.listSecrets, fill: { store in
                store.secrets.newName = "crm_api_key_2"
                store.secrets.newValue = "crm-secret-fixture"
            }, create: { await $0.secrets.create() }),
            LostCreate(operationID: AgentsOp.createEnvironmentVariable, listOperationID: AgentsOp.listEnvironmentVariables,
                       fill: { store in
                store.secrets.newVariableLabel = "CRM_KEY"
                store.secrets.newVariableType = "secret"
                store.secrets.newVariableValues = [("production", AgentsFixtures.secretID)]
            }, create: { await $0.secrets.createVariable() }),
            LostCreate(operationID: AgentsOp.createMCPServer, listOperationID: AgentsOp.listMCPServers, fill: { store in
                store.mcpServers.newName = "Order system"
                store.mcpServers.newURL = "https://mcp.example.com/sse"
            }, create: { await $0.mcpServers.create() }),
            LostCreate(operationID: AgentsOp.importPhoneNumber, listOperationID: AgentsOp.listPhoneNumbers, fill: { store in
                store.phoneNumbers.importLabel = "Support line"
                store.phoneNumbers.importNumber = "+15550103"
                store.phoneNumbers.twilioSID = "AC0000"
                store.phoneNumbers.twilioToken = "twilio-token-fixture"
            }, create: { await $0.phoneNumbers.importNumberNow() }),
        ]
    }

    /// An agent, a tool, a secret, an environment variable, an MCP server or an imported number,
    /// carried out but answered with a 500: it may exist. Its list is read again at once, the
    /// form keeps what was typed, and a second create is held — nothing is sent — until the
    /// owner says they have checked; then it goes. (Before: no read, nothing held, and a second
    /// create made a second one.)
    @Test func createsWhoseAnswerWasLostAreHeldUntilTheOwnerHasChecked() async throws {
        for lost in lostCreates {
            let rig = losingRig([lost.operationID])
            defer { rig.clean() }
            let store = rig.store
            let runners = [store.calls.runner(lost.operationID)]
            lost.fill(store)
            let listsBefore = rig.requests(lost.listOperationID).count
            try await confirming(runners) { await lost.create(store) }
            #expect(rig.requests(lost.operationID).count == 1, "\(lost.operationID)")
            #expect(rig.requests(lost.listOperationID).count > listsBefore, "\(lost.operationID): its list was not read after a lost answer")
            #expect(store.calls.holds.notice(lost.operationID)?.contains("was lost, so it may have been made") == true,
                    "\(lost.operationID): \(store.calls.holds.notice(lost.operationID) ?? "not held")")
            try await confirming(runners) { await lost.create(store) }
            #expect(rig.requests(lost.operationID).count == 1, "\(lost.operationID): a second one was sent after the first one's answer was lost")
            store.calls.holds.acknowledge(lost.operationID)
            lost.fill(store)
            try await confirming(runners) { await lost.create(store) }
            #expect(rig.requests(lost.operationID).count == 2, "\(lost.operationID): not sent once checked")
            #expect(store.calls.holds.notice(lost.operationID) == nil)
        }
    }

    /// A create ElevenLabs refused made nothing: nothing is held.
    @Test func aRefusedAgentsCreateHoldsNothing() async throws {
        let rig = losingRig([], refusing: [AgentsOp.createSecret])
        defer { rig.clean() }
        let model = rig.store.secrets
        model.newName = "crm_api_key_2"
        model.newValue = "crm-secret-fixture"
        let runners = [rig.store.calls.runner(AgentsOp.createSecret)]
        try await confirming(runners) { await model.create() }
        #expect(rig.store.calls.holds.notice(AgentsOp.createSecret) == nil, "a refused create was held")
        try await confirming(runners) { await model.create() }
        #expect(rig.requests(AgentsOp.createSecret).count == 2)
    }

    /// One field of a pretend agent or MCP server that patches set; the first patch's answer is lost.
    final class LostPatch: @unchecked Sendable {
        let lock = NSLock()
        var value: JSONValue
        var answersToLose = 1
        init(_ value: JSONValue) { self.value = value }
        /// Takes `field` from the patch; true when its answer is to be lost.
        func patch(_ request: ElevenLabsRequest, field: String) -> Bool {
            let data: Data = if case .data(let data) = request.body { data } else { Data() }
            let body = (try? JSONValue(data: data)) ?? .null
            return lock.withLock {
                if body[field] != .null { value = body[field] }
                defer { answersToLose = max(0, answersToLose - 1) }
                return answersToLose > 0
            }
        }
        var current: JSONValue { lock.withLock { value } }
    }

    nonisolated static func setting(_ field: String, _ value: JSONValue, in json: JSONValue, under: String? = nil) -> JSONValue {
        guard case .object(var fields) = json else { return json }
        if let under, case .object(var inner) = fields[under] ?? .null {
            inner[field] = value
            fields[under] = .object(inner)
        } else {
            fields[field] = value
        }
        return .object(fields)
    }

    /// A tag added to the agent and saved: carried out, answer lost. The agent is read again into
    /// the editor's base, the edits kept — so nothing shows as unsaved — and the editor says so.
    /// Then Revert and a tag added in place keep the one the lost save added. (Before: the base
    /// stayed the agent before the save; Revert went back to it, and the next save took the
    /// added tag away.)
    @Test func anAgentSaveWhoseAnswerWasLostIsReadAgainIntoTheEditorsBase() async throws {
        let state = LostPatch(["support", "english"])
        let rig = AgentsFixtures.Rig { request in
            switch request.operationID {
            case AgentsOp.updateAgent:
                if state.patch(request, field: "tags") { return .jsonText(#"{"detail":"Internal error"}"#, status: 500) }
                return .json(Self.setting("tags", state.current, in: AgentsFixtures.agent))
            case AgentsOp.getAgent:
                return .json(Self.setting("tags", state.current, in: AgentsFixtures.agent))
            default:
                return try await AgentsFixtures.reply(request)
            }
        }
        defer { rig.clean() }
        let model = rig.store.agents
        await model.select(AgentsFixtures.agentID)
        let runners = [rig.store.calls.runner(AgentsOp.updateAgent, slot: AgentsFixtures.agentID)]
        let readsBefore = rig.requests(AgentsOp.getAgent).count
        model.draft.tags.append("billing")
        try await confirming(runners) { await model.save() }
        #expect(state.current == ["support", "english", "billing"])
        #expect(rig.requests(AgentsOp.getAgent).count == readsBefore + 1, "the agent was not read again after a lost answer")
        #expect(model.loaded?.tags == ["support", "english", "billing"], "the editor's base is the agent from before the save")
        #expect(!model.isDirty)
        #expect(model.lostSaveNote == AgentsModel.lostSaveMessage("Support"))
        model.revert()
        model.draft.tags.append("priority")
        try await confirming(runners) { await model.save() }
        #expect(state.current == ["support", "english", "billing", "priority"],
                "the next save took back the tag the lost save added: \(state.current)")
    }

    /// An MCP server's timeout changed and saved: carried out, answer lost. The server is read
    /// again into the form's base, the edit kept; setting the timeout back is then a change, and
    /// goes. (Before: against the stale base, setting it back looked like no change — nothing was
    /// sent, and the server kept the timeout the owner had undone.)
    @Test func anMCPServerSaveWhoseAnswerWasLostIsReadAgainIntoTheFormsBase() async throws {
        let state = LostPatch(30)
        let rig = AgentsFixtures.Rig { request in
            switch request.operationID {
            case AgentsOp.updateMCPServer:
                if state.patch(request, field: "response_timeout_secs") {
                    return .jsonText(#"{"detail":"Internal error"}"#, status: 500)
                }
                return .json(Self.setting("response_timeout_secs", state.current, in: AgentsFixtures.mcpServer, under: "config"))
            case AgentsOp.getMCPServer:
                return .json(Self.setting("response_timeout_secs", state.current, in: AgentsFixtures.mcpServer, under: "config"))
            default:
                return try await AgentsFixtures.reply(request)
            }
        }
        defer { rig.clean() }
        let model = rig.store.mcpServers
        await model.select(AgentsFixtures.serverID)
        let runners = [rig.store.calls.runner(AgentsOp.updateMCPServer, slot: AgentsFixtures.serverID)]
        let readsBefore = rig.requests(AgentsOp.getMCPServer).count
        model.settings.timeoutSeconds = 45
        try await confirming(runners) { await model.saveSettings() }
        #expect(state.current == 45)
        #expect(rig.requests(AgentsOp.getMCPServer).count == readsBefore + 1, "the server was not read again after a lost answer")
        #expect(model.settings.timeoutSeconds == 45)
        model.settings.timeoutSeconds = 30
        try await confirming(runners) { await model.saveSettings() }
        #expect(rig.requests(AgentsOp.updateMCPServer).count == 2, "setting the timeout back was not sent")
        #expect(state.current == 30)
    }
}
