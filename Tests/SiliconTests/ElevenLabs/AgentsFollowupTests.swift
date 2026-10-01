import Foundation
import Testing
@testable import SiliconElevenLabs
@testable import SiliconUI

/// The agents critic's last nits, taken after the merge.
extension AgentsSectionsTests {

    /// A real-world send ElevenLabs refused with a 4xx (a 422 for a bad recipient list) placed
    /// nothing: the screen is ready again at once. A 408, a 429 or a 5xx does not say whether
    /// the calls went out, so the owner checks first, as after a lost answer.
    @Test func aRefusedBatchIsAKnownOutcomeAndATimeoutOrServerErrorIsNot() async throws {
        let cases: [(reply: FakeElevenLabsTransport.Reply, known: Bool)] = [
            (.jsonText(#"{"detail":{"status":"invalid_recipients","message":"Bad number"}}"#, status: 422), true),
            (.jsonText(#"{"detail":"Not found"}"#, status: 404), true),
            (.jsonText(#"{"detail":"Request timeout"}"#, status: 408), false),
            (.jsonText(#"{"detail":"busy"}"#, status: 429), false),
            (.jsonText(#"{"detail":"Internal error"}"#, status: 500), false),
        ]
        for (reply, known) in cases {
            let rig = AgentsFixtures.Rig(overriding: [AgentsOp.submitBatch: reply])
            defer { rig.clean() }
            await rig.store.directory.agents.refresh()
            await rig.store.directory.phoneNumbers.refresh()
            let model = rig.store.batchCalls
            fillBatch(model)
            let runner = rig.store.calls.runner(AgentsOp.submitBatch)
            let submitting = Task { await model.submit() }
            try await waitUntil { runner.isAwaitingConfirmation }
            runner.confirm()
            await submitting.value
            #expect(rig.requests(AgentsOp.submitBatch).count == 1)
            if known {
                #expect(model.submitGuard.canSend, "\(reply.status): a refusal placed nothing")
                #expect(model.submitGuard.warning == nil, "\(reply.status): \(model.submitGuard.warning ?? "")")
            } else {
                #expect(!model.submitGuard.canSend, "\(reply.status) does not say whether calls were placed")
                #expect(model.submitGuard.warning?.contains("may already have been placed") == true)
                #expect(model.submitGuard.warning?.contains("does not say whether it went out") == true)
            }
        }
    }

    /// A test whose details could not be fetched shows no editor: no empty, editable fields
    /// under "Could not load the test" (the Name field's placeholder read like a value). The
    /// editor is back once the test loads, and for a new test.
    @Test func aTestThatCannotBeLoadedShowsNoEditor() async throws {
        let rig = AgentsFixtures.Rig { request in
            if request.operationID == AgentsOp.getTest, request.url.lastPathComponent == "test_sim02" {
                return .init(status: 404, headers: ["content-type": "application/json"],
                             body: Data(#"{"detail":{"status":"not_found","message":"Not found"}}"#.utf8))
            }
            return try await AgentsFixtures.reply(request)
        }
        defer { rig.clean() }
        let model = rig.store.testing
        await model.select("test_sim02")
        #expect(model.editorTitle == "Could not load the test")
        #expect(!model.showsEditor, "the editor's fields are drawn under a test that did not load")
        await model.select(AgentsFixtures.testID)
        #expect(model.showsEditor)
        model.startCreating()
        #expect(model.showsEditor, "a new test has its editor")
    }

    /// Questions the shell would title "<the operation's summary>: <subject>?" ("Create MCP
    /// server tool approval: …", "Update tool: …") are worded by the screen instead. Each is
    /// declined: nothing is sent.
    @Test func questionsBuiltFromSummariesHaveTheirOwnTitles() async throws {
        let rig = AgentsFixtures.Rig()
        defer { rig.clean() }

        let servers = rig.store.mcpServers
        await servers.select(AgentsFixtures.serverID)
        await servers.loadTools()
        let tool = try #require(servers.tools.last)
        let approve = rig.store.calls.runner(AgentsOp.approveMCPTool, slot: "\(AgentsFixtures.serverID)/\(tool.name)")
        let approving = Task { await servers.setApproval(tool, autoApproved: true) }
        try await waitUntil { approve.isAwaitingConfirmation }
        #expect(approve.confirmation?.title == "Let “\(tool.name)” run without asking?")
        approve.decline()
        await approving.value

        servers.settings.approvalPolicy = "auto_approve_all"
        let update = rig.store.calls.runner(AgentsOp.updateMCPServer, slot: AgentsFixtures.serverID)
        let updating = Task { await servers.saveSettings() }
        try await waitUntil { update.isAwaitingConfirmation }
        #expect(update.confirmation?.title.hasPrefix("Let every tool on “") == true, "\(update.confirmation?.title ?? "")")
        #expect(update.confirmation?.title.hasSuffix("” run without asking?") == true)
        update.decline()
        await updating.value

        let tools = rig.store.tools
        await tools.select(AgentsFixtures.toolID)
        tools.editor.description = "Finds an order by its number, quickly"
        let save = rig.store.calls.runner(AgentsOp.updateTool, slot: AgentsFixtures.toolID)
        let saving = Task { await tools.save() }
        try await waitUntil { save.isAwaitingConfirmation }
        #expect(save.confirmation?.title == "Save the tool “lookup_order” calling api.example.com?")
        save.decline()
        await saving.value

        #expect(rig.requests(AgentsOp.approveMCPTool).isEmpty && rig.requests(AgentsOp.updateMCPServer).isEmpty
                && rig.requests(AgentsOp.updateTool).isEmpty)
    }

    /// The 2026-09-30 spec gave triage tickets a priority: one agent's tickets filter by it and
    /// sort most urgent first; a new ticket, and a change to one, can set it (and clear it).
    /// Every body sent resolves in the pinned spec.
    @Test func ticketsCarryAPriorityFromTheRefreshedSpec() async throws {
        var withPriority = AgentsFixtures.ticket
        if case .object(var fields) = withPriority {
            fields["priority"] = "high"
            withPriority = .object(fields)
        }
        let rig = AgentsFixtures.Rig(overriding: [
            AgentsOp.getTicket: .json(withPriority),
            AgentsOp.listAgentTickets: .json(["agent_conversation_tickets": [withPriority], "has_more": false]),
            AgentsOp.createManualTicket: .json(withPriority),
            AgentsOp.updateTicket: .json(withPriority),
        ])
        defer { rig.clean() }
        let model = rig.store.analytics
        #expect(AgentAnalyticsModel.priorities == ["low", "medium", "high", "urgent"])

        model.agentID = AgentsFixtures.agentID
        model.ticketScope = .agent
        model.ticketPriority = "urgent"
        model.ticketsByPriority = true
        await model.tickets.refresh()
        let query = URLComponents(url: try #require(rig.requests(AgentsOp.listAgentTickets).last?.request.url),
                                  resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.contains(URLQueryItem(name: "priorities", value: "urgent")))
        #expect(query.contains(URLQueryItem(name: "sort_by", value: "priority")))
        #expect(model.tickets.items.first?.priority == "high")

        model.ticketScope = .workspace
        await model.tickets.refresh()
        let workspace = URLComponents(url: try #require(rig.requests(AgentsOp.listTickets).last?.request.url),
                                      resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(!workspace.contains { $0.name == "priorities" || $0.name == "sort_by" },
                "the workspace list has neither parameter")

        model.newTicketComment = "Follow up on the refund window."
        model.newTicketPriority = "high"
        await model.createTicket()
        let created = try #require(rig.body(AgentsOp.createManualTicket))
        #expect(created["priority"] == "high")
        #expect(try AgentsSpec.shared().unresolved(body: created, operationID: AgentsOp.createManualTicket).isEmpty)
        #expect(model.newTicketPriority.isEmpty, "the form is cleared")

        await model.openTicket("tkt_1")
        #expect(model.ticket?.priority == "high")
        await model.updateTicket(priority: "low")
        let lowered = try #require(rig.body(AgentsOp.updateTicket))
        #expect(lowered == ["priority": "low"])
        #expect(try AgentsSpec.shared().unresolved(body: lowered, operationID: AgentsOp.updateTicket).isEmpty)
        await model.updateTicket(priority: "")
        #expect(rig.body(AgentsOp.updateTicket) == ["priority": .null], "None clears it")
    }
}
