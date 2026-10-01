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
}
