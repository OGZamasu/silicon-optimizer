import Foundation
import SiliconElevenLabs
import Testing
@testable import SiliconUI

/// The Agents Platform sections: that every control maps onto a real parameter of a real
/// operation in the pinned spec, that every agents operation is either on a screen or knowingly
/// left to the Explorer, and that the screens' view-models send what they should — and ask
/// first, in plain words, before anything that reaches a person or deletes something.
///
/// Hermetic: a real client over `FakeElevenLabsTransport`, a fake key, a scratch sink.
@Suite("ElevenLabs agents sections")
@MainActor
struct AgentsSectionsTests {

    // MARK: - Coverage

    @Test func everyOperationTheScreensRunIsInTheCatalogAndInAnAgentsSection() {
        let sections = Set(AgentsSections.all)
        for id in AgentsOp.native {
            guard let operation = ElevenLabsCatalog.operation(id) else {
                Issue.record("\(id) is not in the catalog")
                continue
            }
            let section = ElevenLabsSection.section(for: operation)
            #expect(section.map(sections.contains) == true, "\(id) belongs to \(String(describing: section))")
        }
        #expect(Set(AgentsOp.native).count == AgentsOp.native.count, "an operation is listed twice")
    }

    @Test func everyAgentsOperationIsOnAScreenOrLeftToTheExplorerWithAReason() {
        let claimed = Set(AgentsSections.all.flatMap(\.operations).map(\.id))
        let native = Set(AgentsOp.native)
        let explorer = Set(AgentsOp.explorerOnly.keys)
        #expect(claimed.count == 187, "the pinned spec's Agents Platform has 187 operations; now \(claimed.count)")
        #expect(native.isDisjoint(with: explorer))
        #expect(native.union(explorer) == claimed,
                "not placed: \(claimed.subtracting(native).subtracting(explorer).sorted()); not ours: \(native.union(explorer).subtracting(claimed).sorted())")
        for (id, reason) in AgentsOp.explorerOnly {
            #expect(ElevenLabsCatalog.operation(id) != nil, "\(id)")
            #expect(reason.count > 20, "\(id) needs a real reason")
        }
    }

    @Test func everyArgumentAScreenSendsIsARealParameterOfARealOperation() throws {
        let spec = try AgentsSpec.shared()
        let arguments = AgentsSections.arguments
        #expect(arguments.count > 400)
        for argument in arguments {
            #expect(AgentsOp.native.contains(argument.operationID), "\(argument) is not one of the screens' operations")
            #expect(spec.resolves(argument), "\(argument) is not in the pinned spec")
        }
    }

    /// The check above would pass anything if the walk were lax: here is what it must refuse.
    @Test func theSpecCheckRefusesWhatTheSpecDoesNotHave() throws {
        let spec = try AgentsSpec.shared()
        #expect(spec.resolves(AgentsArgument(AgentsOp.createAgent, "conversation_config.agent.prompt.prompt")))
        #expect(!spec.resolves(AgentsArgument(AgentsOp.createAgent, "conversation_config.agent.prompt.promptt")))
        #expect(!spec.resolves(AgentsArgument(AgentsOp.createAgent, "conversation_config.voice.voice_id")))
        #expect(!spec.resolves(AgentsArgument(AgentsOp.listAgents, "pagesize")))
        #expect(!spec.resolves(AgentsArgument("no_such_operation", "name")))
        #expect(spec.resolves(AgentsArgument(AgentsOp.submitBatch, "recipients[].phone_number")))
        #expect(!spec.resolves(AgentsArgument(AgentsOp.submitBatch, "recipients[].phone")))
        // Open maps take any name below them.
        #expect(spec.resolves(AgentsArgument(AgentsOp.twilioCall, "conversation_initiation_client_data.dynamic_variables.first_name")))
        #expect(spec.unresolved(body: ["call_name": "x", "recipient": []], operationID: AgentsOp.submitBatch) == ["recipient"])
    }

    @Test func menusAndRangesComeFromTheCatalog() {
        #expect(AgentsSchema.choices(AgentsOp.createAgent, "conversation_config.agent.prompt.llm").contains("gemini-2.5-flash"))
        #expect(!AgentsSchema.choices(AgentsOp.createAgent, "conversation_config.tts.model_id").isEmpty)
        #expect(AgentsSchema.range(AgentsOp.createAgent, "conversation_config.tts.speed", fallback: 0...9) == 0.7...1.2)
        #expect(AgentsSchema.range(AgentsOp.createAgent, "conversation_config.tts.stability", fallback: 0...9) == 0...1)
        #expect(AgentsSchema.choices(AgentsOp.listConversations, "call_successful").contains("success"))
        #expect(AgentsSchema.choices(AgentsOp.computeRAGIndex, "model").count == 2)
        #expect(AgentsSchema.choices(AgentsOp.createMCPServer, "config.transport").contains("SSE"))
        #expect(AgentsSchema.choices(AgentsOp.createMCPServer, "config.approval_policy").contains("auto_approve_all"))
        #expect(AgentsSchema.choices(AgentsOp.importPhoneNumber, "outbound_trunk_config.transport").contains("tls"))
        #expect(AgentsSchema.choices(AgentsOp.createTool, "tool_config.api_schema.method").contains("POST"))
        #expect(AgentsSchema.range(AgentsOp.twilioCall, "telephony_call_config.ringing_timeout_secs", fallback: 0...0) == 1...999)
        #expect(AgentsSchema.choices(AgentsOp.createProcedure, "type").contains("free_form"))
    }

    // MARK: - Agents

    @Test func anAgentLoadsIntoTheEditorAndSaveSendsOnlyWhatChanged() async throws {
        let rig = AgentsFixtures.Rig()
        defer { rig.clean() }
        let model = rig.store.agents
        await model.list.refresh()
        #expect(model.list.items.map(\.name) == ["Support", "Sales follow-up"])
        await model.select(AgentsFixtures.agentID)
        #expect(model.draft.prompt.hasPrefix("You are the support agent"))
        #expect(model.draft.llm == "gemini-2.5-flash")
        #expect(model.draft.knowledge.map(\.id) == [AgentsFixtures.documentID])
        #expect(!model.isDirty)
        // The shareable token in the answer is not shown, and not kept in the result on screen.
        let loadRunner = rig.store.calls.runner(AgentsOp.getAgent, slot: AgentsFixtures.agentID)
        #expect(loadRunner.credential == nil)
        #expect(!(loadRunner.result.flatMap(AgentsCalls.json(of:))?.jsonString().contains("tok_fixture_shareable") ?? false))

        model.draft.prompt = "Be brief."
        model.draft.speed = 1.1
        model.draft.toolIDs = []
        model.changeDescription = "Shorter prompt"
        #expect(model.isDirty)
        await model.save()
        #expect(model.questions.question == nil, "removing a tool connects nothing new, so nothing is asked")
        let body = try #require(rig.body(AgentsOp.updateAgent))
        #expect(body == [
            "conversation_config": [
                "agent": ["prompt": ["prompt": "Be brief.", "tool_ids": []]],
                "tts": ["speed": 1.1],
            ],
            "version_description": "Shorter prompt",
        ])
        let request = try #require(rig.requests(AgentsOp.updateAgent).last?.request)
        #expect(request.method == "PATCH")
        #expect(request.url.path == "/v1/convai/agents/\(AgentsFixtures.agentID)")
        // The patch's own schema leaves the configuration open; its fields are the create's.
        let spec = try AgentsSpec.shared()
        #expect(spec.unresolved(body: body, operationID: AgentsOp.updateAgent).isEmpty)
        #expect(spec.unresolved(body: ["conversation_config": body["conversation_config"]], operationID: AgentsOp.createAgent).isEmpty)
        #expect(rig.transport.hostViolations.isEmpty)
    }

    @Test func aNewAgentIsCreatedWithTheFormsFieldsInTheirPlaces() async throws {
        let rig = AgentsFixtures.Rig()
        defer { rig.clean() }
        let model = rig.store.agents
        model.startCreating()
        model.newDraft.name = "Front desk"
        model.newDraft.prompt = "Greet visitors."
        model.newDraft.voiceID = "voice_calm"
        await model.create()
        let body = try #require(rig.body(AgentsOp.createAgent))
        #expect(body["name"] == "Front desk")
        #expect(body["conversation_config"]["agent"]["prompt"]["prompt"] == "Greet visitors.")
        #expect(body["conversation_config"]["tts"]["voice_id"] == "voice_calm")
        #expect(try AgentsSpec.shared().unresolved(body: body, operationID: AgentsOp.createAgent).isEmpty)
        #expect(model.selectedID == "agent_new03")
        #expect(!model.creating)
    }

    @Test func deletingAnAgentNamesItAndSendsNothingWhenDeclined() async throws {
        let rig = AgentsFixtures.Rig()
        defer { rig.clean() }
        let model = rig.store.agents
        await model.select(AgentsFixtures.agentID)
        let deleting = Task { await model.delete() }
        let runner = rig.store.calls.runner(AgentsOp.deleteAgent, slot: AgentsFixtures.agentID)
        try await waitUntil { runner.isAwaitingConfirmation }
        #expect(runner.confirmation?.title == "Delete the agent “Support”?")
        #expect(runner.confirmation?.consequence.contains("Phone numbers") == true)
        #expect(rig.pane.confirming === runner, "the pane asks the question")
        runner.decline()
        await deleting.value
        #expect(rig.requests(AgentsOp.deleteAgent).isEmpty)
        #expect(model.selectedID == AgentsFixtures.agentID)
    }

    /// Review blocker 1: the fetched agent is masked (it carries a link token), so a draft built
    /// from it must leave the token out instead of sending the mask back as the token.
    @Test func aDraftLeavesCredentialsOutAndNeverSendsTheMask() async throws {
        let rig = AgentsFixtures.Rig()
        defer { rig.clean() }
        let model = rig.store.agents
        await model.select(AgentsFixtures.agentID)
        #expect(model.detailJSON["platform_settings"]["auth"]["shareable_token"] == .string(ElevenLabsRedaction.placeholder),
                "the fixture's agent has a link token, which the app only ever sees masked")
        model.draft.firstMessage = "Hi there!"
        await model.saveAsDraft()
        #expect(model.draftProblem == nil)
        let recorded = try #require(rig.requests(AgentsOp.createDraft).last)
        #expect(recorded.request.url.query?.contains("branch_id=agtbrch_main") == true)
        let body = try JSONValue(data: recorded.body)
        #expect(!body.jsonString().contains(ElevenLabsRedaction.placeholder))
        #expect(body["platform_settings"]["auth"].objectValue?["shareable_token"] == nil)
        #expect(body["platform_settings"]["auth"]["enable_auth"] == false, "the rest of the settings go as fetched")
        #expect(body["conversation_config"]["agent"]["first_message"] == "Hi there!")
        #expect(body["conversation_config"]["agent"]["prompt"]["llm"] == "gemini-2.5-flash")
    }

    /// An agent whose inline tool carries a literal header keeps it in a draft: the app's
    /// runner shows header values as they are, so they go back unchanged.
    @Test func aDraftKeepsAnInlineToolsHeaders() async throws {
        let rig = AgentsFixtures.Rig(overriding: [AgentsOp.getAgent: .json(AgentsFixtures.agentWithInlineToolHeader)])
        defer { rig.clean() }
        let model = rig.store.agents
        await model.select(AgentsFixtures.agentID)
        model.draft.firstMessage = "Hi there!"
        await model.saveAsDraft()
        #expect(model.draftProblem == nil)
        let body = try #require(rig.body(AgentsOp.createDraft))
        #expect(body["conversation_config"]["agent"]["prompt"]["tools"][0]["api_schema"]["request_headers"]
                == ["Authorization": "Bearer crm-fixture-token"])
        #expect(body["platform_settings"]["auth"].objectValue?["shareable_token"] == nil)
    }

    /// Should a masked value ever reach the editor, the draft is refused, naming where, and
    /// nothing is sent.
    @Test func aDraftIsRefusedWhenTheFetchedConfigurationHoldsAMask() async throws {
        let masked = AgentsJSON.setting(.string(ElevenLabsRedaction.placeholder),
                                        at: "conversation_config.agent.prompt.custom_llm.api_key", in: AgentsFixtures.agent)
        let rig = AgentsFixtures.Rig(overriding: [AgentsOp.getAgent: .json(masked)])
        defer { rig.clean() }
        let model = rig.store.agents
        await model.select(AgentsFixtures.agentID)
        model.draft.firstMessage = "Hi there!"
        await model.saveAsDraft()
        #expect(rig.requests(AgentsOp.createDraft).isEmpty)
        let problem = try #require(model.draftProblem)
        #expect(problem.hasPrefix("The fetched configuration has masked values (conversation_config.agent.prompt.custom_llm.api_key)"))
    }

    /// Round 2 (a): a value only partly masked ("Bearer ‹redacted›") is caught too.
    @Test func aDraftIsRefusedForAPartlyMaskedValue() async throws {
        let masked = AgentsJSON.setting(.string("Bearer " + ElevenLabsRedaction.placeholder),
                                        at: "conversation_config.agent.prompt.custom_llm.request_headers.Authorization",
                                        in: AgentsFixtures.agent)
        let rig = AgentsFixtures.Rig(overriding: [AgentsOp.getAgent: .json(masked)])
        defer { rig.clean() }
        let model = rig.store.agents
        await model.select(AgentsFixtures.agentID)
        model.draft.firstMessage = "Hi there!"
        await model.saveAsDraft()
        #expect(rig.requests(AgentsOp.createDraft).isEmpty)
        #expect(model.draftProblem?.contains("conversation_config.agent.prompt.custom_llm.request_headers.Authorization") == true)
    }

    /// Round 2 (d): a draft that newly gives the agent an MCP server asks as Save does.
    @Test func aDraftThatAddsAnMCPServerAsksFirst() async throws {
        let rig = AgentsFixtures.Rig()
        defer { rig.clean() }
        await rig.store.directory.mcpServers.refresh()
        let model = rig.store.agents
        await model.select(AgentsFixtures.agentID)
        model.draft.mcpServerIDs = [AgentsFixtures.serverID]
        await model.saveAsDraft()
        let question = try #require(model.questions.question)
        #expect(question.title == "Keep a draft that lets “Support” send callers' words to Order system (mcp.example.com)?")
        #expect(question.message.contains("Once this draft is merged or deployed"))
        #expect(rig.requests(AgentsOp.createDraft).isEmpty)
        await model.questions.answer(true)
        #expect(rig.requests(AgentsOp.createDraft).count == 1)
    }

    /// Round 2: merging a merge proposal changes its target (usually main) and asks first.
    @Test func mergingAProposalAsksNamingItsTargetAndWhatGoesLive() async throws {
        let rig = AgentsFixtures.Rig()
        defer { rig.clean() }
        let model = rig.store.agents
        await model.select(AgentsFixtures.agentID)
        let branches = model.branches
        await branches.load()
        await branches.openProposal("mp_1")
        branches.requestAcceptProposal(agentName: "Support")
        let question = try #require(model.questions.question)
        #expect(question.title == "Merge “Warmer greeting” (“Warmer tone”) into “Main” of “Support”?")
        #expect(question.message.contains("It answers 100 % of calls now."))
        await model.questions.answer(false)
        #expect(rig.requests(AgentsOp.acceptMergeProposal).isEmpty)
        branches.requestAcceptProposal(agentName: "Support")
        await model.questions.answer(true)
        #expect(rig.requests(AgentsOp.acceptMergeProposal).count == 1)
    }

    /// Review M-5: giving an agent an MCP server or a webhook tool starts sending callers' words
    /// out, so Save asks first, naming where.
    @Test func savingAnAgentWithANewMCPServerOrWebhookToolAsksFirst() async throws {
        let rig = AgentsFixtures.Rig()
        defer { rig.clean() }
        await rig.store.directory.mcpServers.refresh()
        await rig.store.directory.tools.refresh()
        let model = rig.store.agents
        await model.select(AgentsFixtures.agentID)
        model.draft.mcpServerIDs = [AgentsFixtures.serverID]
        await model.save()
        let question = try #require(model.questions.question)
        #expect(question.title == "Let “Support” send callers' words to Order system (mcp.example.com)?")
        #expect(rig.requests(AgentsOp.updateAgent).isEmpty, "nothing is sent before the answer")
        await model.questions.answer(false)
        #expect(rig.requests(AgentsOp.updateAgent).isEmpty)
        await model.save()
        await model.questions.answer(true)
        #expect(rig.body(AgentsOp.updateAgent)?["conversation_config"]["agent"]["prompt"]["mcp_server_ids"]
                == [.string(AgentsFixtures.serverID)])
    }

    /// Review BR-1: merging into main and moving traffic change what live callers hear.
    @Test func mergingIntoMainAndDeployingAskFirstNamingTheBranch() async throws {
        let rig = AgentsFixtures.Rig()
        defer { rig.clean() }
        let model = rig.store.agents
        await model.select(AgentsFixtures.agentID)
        let branches = model.branches
        await branches.load()
        branches.selectedBranchID = "agtbrch_tone"
        branches.requestMerge(agentName: "Support")
        #expect(model.questions.question?.title == "Merge “Warmer tone” into “Main” of “Support”?")
        await model.questions.answer(false)
        #expect(rig.requests(AgentsOp.mergeBranch).isEmpty)
        branches.requestMerge(agentName: "Support")
        await model.questions.answer(true)
        #expect(rig.requests(AgentsOp.mergeBranch).count == 1)

        branches.traffic = ["agtbrch_main": 80, "agtbrch_tone": 20]
        branches.requestDeploy(agentName: "Support")
        #expect(model.questions.question?.title == "Send “Support”'s callers to Main 80 % and Warmer tone 20 %?")
        #expect(rig.requests(AgentsOp.createDeployment).isEmpty)
        await model.questions.answer(true)
        #expect(rig.requests(AgentsOp.createDeployment).count == 1)
    }

    /// Review A-2: a show-once token belongs to the agent it was fetched for.
    @Test func aLinkTokenDoesNotFollowToAnotherAgent() async throws {
        let rig = AgentsFixtures.Rig()
        defer { rig.clean() }
        let model = rig.store.agents
        await model.select(AgentsFixtures.agentID)
        await model.sharing.fetchLink()
        let supportRunner = model.sharing.runner(AgentsOp.agentLink)
        #expect(supportRunner.credential != nil)
        await model.select(AgentsFixtures.salesAgentID)
        #expect(model.sharing.runner(AgentsOp.agentLink).credential == nil)
        #expect(supportRunner.credential == nil, "switching agents takes the token off screen for good")
    }

    // MARK: - Batch calls

    @Test func recipientsAreReadFromCSVWithVariablesOrFromPlainLines() {
        let csv = """
        phone_number,FirstName,Order
        +1 (555) 010-0111,Ana,1042

        "+15550112","Ben, Jr.",1043
        +15550112,Dupe,1
        not-a-number,Cy,9
        """
        let parsed = AgentsBatchRecipients.parse(csv, whatsApp: false)
        #expect(parsed.recipients.map(\.phoneNumber) == ["+15550100111", "+15550112"])
        #expect(parsed.recipients[1].variables == ["FirstName": "Ben, Jr.", "Order": "1043"], "names keep their case")
        #expect(parsed.duplicates == 1)
        #expect(parsed.problems == ["Line 6: “not-a-number” is not a phone number."], "line numbers count blank lines")

        let plain = AgentsBatchRecipients.parse("+15550121\n\n+15550122\n", whatsApp: false)
        #expect(plain.recipients.count == 2)
        #expect(plain.recipients.allSatisfy { $0.variables.isEmpty })
        #expect(AgentsBatchRecipients.parse("name,email\nA,a@example.com", whatsApp: false).problems.first?.contains("phone_number") == true)
        #expect(AgentsBatchRecipients.parse("PHONE_NUMBER,x\n+15550123,y", whatsApp: false).recipients.count == 1)
    }

    /// Round 2 (b): Windows line ends count once, so problems name the right line.
    @Test func windowsLineEndsCountAsOneLine() {
        let parsed = AgentsBatchRecipients.parse("phone_number,Name\r\n+15550131,Ana\r\nnope,Ben\r\n", whatsApp: false)
        #expect(parsed.recipients.count == 1)
        #expect(parsed.problems == ["Line 3: “nope” is not a phone number."])
    }

    /// Review B-3: only ASCII digits make a number; separators are refused, not merged.
    @Test func onlyPlainDigitsMakeAPhoneNumber() {
        for bad in ["+1555010019²", "+１５５５０１００１２３", "5550100;5550101", "+1555٠١٠٠١٢٣", "555-CALL-NOW"] {
            #expect(AgentsBatchRecipients.parse(bad, whatsApp: false).recipients.isEmpty, "\(bad)")
        }
        #expect(AgentsBatchRecipients.normalizedPhone("+1 (555) 010.0199") == "+15550100199")
    }

    /// Review B-4: the spec's limit on recipients is checked here, and a long problem list is cut.
    @Test func aBatchOverTheRecipientLimitIsRefusedAndProblemsAreCapped() {
        let limit = AgentsBatchRecipients.recipientLimit
        #expect(limit == 10_000)
        let many = (0...limit).map { String(format: "+1555%07d", $0) }.joined(separator: "\n")
        let parsed = AgentsBatchRecipients.parse(many, whatsApp: false)
        #expect(parsed.problems.first == "A batch takes at most 10,000 recipients; this list has 10,001.")
        let bad = Array(repeating: "x", count: 50).joined(separator: "\n")
        let shown = AgentsBatchRecipients.shown(AgentsBatchRecipients.parse(bad, whatsApp: false).problems)
        #expect(shown.count == AgentsBatchRecipients.problemLimit + 1)
        #expect(shown.last == "… and 30 more lines to fix.")
    }

    /// Review CSV-1: a file that is not UTF-8 is read as Windows Latin 1 and says so.
    @Test func aWindowsLatinCSVIsReadAndSaysSo() throws {
        let rig = AgentsFixtures.Rig()
        defer { rig.clean() }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("elevenlabs-agents-csv-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            if folder.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path
                == FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath().path {
                try? FileManager.default.removeItem(at: folder)
            }
        }
        let file = folder.appendingPathComponent("list.csv")
        try Data("phone_number,Name\n+15550131,Jos\u{E9}\n".data(using: .windowsCP1252)!).write(to: file)
        let model = rig.store.batchCalls
        model.importCSV(file)
        #expect(model.importProblem?.contains("not UTF-8") == true)
        #expect(model.parsed.recipients.first?.variables == ["Name": "José"])
    }

    @Test func submittingABatchSaysHowManyPeopleWhichAgentAndFromWhereBeforeCalling() async throws {
        let rig = AgentsFixtures.Rig()
        defer { rig.clean() }
        await rig.store.directory.agents.refresh()
        await rig.store.directory.phoneNumbers.refresh()
        let model = rig.store.batchCalls
        fillBatch(model)
        #expect(model.submitProblems.isEmpty)

        let wording = model.submitConfirmation()
        #expect(wording.consequence.contains("3 recipients"))
        #expect(wording.consequence.contains("Support line (+15550100) through Twilio"))
        #expect(wording.consequence.contains("billed by the minute"))

        // Declined: nothing is sent, and the form stays for another try.
        let runner = rig.store.calls.runner(AgentsOp.submitBatch)
        let declined = Task { await model.submit() }
        try await waitUntil { runner.isAwaitingConfirmation }
        #expect(runner.confirmation?.title == "Place 3 real phone calls with “Support”?")
        #expect(runner.confirmation?.confirmLabel == "Call now")
        #expect(runner.confirmation?.consequence == wording.consequence)
        #expect(runner.confirmation?.risk == .realWorld)
        runner.decline()
        await declined.value
        #expect(rig.requests(AgentsOp.submitBatch).isEmpty)
        #expect(model.submitGuard.canSend)

        // Confirmed: the recipients go with their variables.
        let confirmed = Task { await model.submit() }
        try await waitUntil { runner.isAwaitingConfirmation }
        runner.confirm()
        await confirmed.value
        let body = try #require(rig.body(AgentsOp.submitBatch))
        #expect(body["recipients"].arrayValue?.count == 3)
        #expect(body["recipients"][0] == ["phone_number": "+15550111",
                                          "conversation_initiation_client_data": ["dynamic_variables": ["FirstName": "Ana"]]])
        #expect(body["agent_phone_number_id"] == .string(AgentsFixtures.phoneID))
        #expect(body["call_name"] == "October renewals")
        #expect(try AgentsSpec.shared().unresolved(body: body, operationID: AgentsOp.submitBatch).isEmpty)
        #expect(model.selectedID == AgentsFixtures.batchID)
        #expect(model.recipientsText.isEmpty, "a sent batch leaves the form")
    }

    /// Review blocker 2: a cancelled wait does not stop a batch that is already on its way, so
    /// a second press must not send it again.
    @Test func aBatchCancelledOnTheWayCannotBeSubmittedAgainUnseen() async throws {
        var slow = FakeElevenLabsTransport.Reply.json(AgentsFixtures.answer(for: AgentsOp.submitBatch))
        slow.delay = .milliseconds(400)
        let rig = AgentsFixtures.Rig(overriding: [AgentsOp.submitBatch: slow])
        defer { rig.clean() }
        await rig.store.directory.agents.refresh()
        await rig.store.directory.phoneNumbers.refresh()
        let model = rig.store.batchCalls
        fillBatch(model)
        let runner = rig.store.calls.runner(AgentsOp.submitBatch)
        let first = Task { await model.submit() }
        try await waitUntil { runner.isAwaitingConfirmation }
        runner.confirm()
        try await waitUntil { runner.isRunning && rig.requests(AgentsOp.submitBatch).count == 1 }
        #expect(model.submitGuard.isSending, "no Cancel is offered: the screen shows it cannot be stopped")
        runner.cancel()
        await first.value
        #expect(model.submitGuard.warning?.contains("may already have been placed") == true)
        #expect(model.recipientsText.isEmpty && model.name.isEmpty, "the form is cleared")
        #expect(model.submitArguments() == nil)

        // Pressing again does nothing until the owner says they have looked.
        fillBatch(model)
        await model.submit()
        #expect(rig.requests(AgentsOp.submitBatch).count == 1)
        #expect(!runner.isAwaitingConfirmation)
        model.submitGuard.acknowledge()
        let second = Task { await model.submit() }
        try await waitUntil { runner.isAwaitingConfirmation }
        runner.decline()
        await second.value
        #expect(rig.requests(AgentsOp.submitBatch).count == 1)
    }

    /// Review blocker 2: a timeout or a failure from ElevenLabs is no proof the batch did not
    /// start; a refusal that names the arguments is.
    @Test func aTimedOutBatchNeedsTheOwnersAcknowledgementBeforeAnotherTry() async throws {
        let rig = AgentsFixtures.Rig(overriding: [AgentsOp.submitBatch: .failure(.network("The request timed out."))])
        defer { rig.clean() }
        await rig.store.directory.agents.refresh()
        await rig.store.directory.phoneNumbers.refresh()
        let model = rig.store.batchCalls
        fillBatch(model)
        let runner = rig.store.calls.runner(AgentsOp.submitBatch)
        let first = Task { await model.submit() }
        try await waitUntil { runner.isAwaitingConfirmation }
        runner.confirm()
        await first.value
        #expect(model.submitGuard.warning?.contains("timed out") == true)
        #expect(model.submitArguments() == nil)
        #expect(rig.requests(AgentsOp.listBatches).count >= 1, "the list is fetched again to look for it")
        fillBatch(model)
        #expect(model.submitArguments() == nil)
        model.submitGuard.acknowledge()
        #expect(model.submitArguments() != nil)
    }

    @Test func aBatchWithProblemsCannotBeSubmitted() {
        let rig = AgentsFixtures.Rig()
        defer { rig.clean() }
        let model = rig.store.batchCalls
        model.recipientsText = "+15550111\nabc"
        model.startLater = true
        model.startAt = Date(timeIntervalSince1970: 1_000)
        let problems = model.submitProblems
        #expect(problems.contains("Give the batch a name."))
        #expect(problems.contains("Choose the agent that will talk."))
        #expect(problems.contains("Choose the number to call from."))
        #expect(problems.contains("Line 2: “abc” is not a phone number."))
        #expect(problems.contains("The start time is in the past."))
        #expect(model.submitArguments() == nil)
    }

    @Test func retryCountsTheFailedAndUnansweredAndStopNamesTheBatch() async throws {
        let rig = AgentsFixtures.Rig()
        defer { rig.clean() }
        let model = rig.store.batchCalls
        await model.select(AgentsFixtures.batchID)
        #expect(model.recipients.count == 5)
        #expect(model.retryCount == 2)
        #expect(model.pendingCount == 2)
        let retry = try #require(model.retryConfirmation())
        #expect(retry.subject == "2 calls again to recipients of “October renewals” with “Support”")

        let runner = rig.store.calls.runner(AgentsOp.cancelBatch, slot: AgentsFixtures.batchID)
        let cancelling = Task { await model.cancel() }
        try await waitUntil { runner.isAwaitingConfirmation }
        #expect(runner.confirmation?.title.contains("“October renewals”") == true)
        #expect(runner.confirmation?.consequence.contains("are not placed") == true)
        runner.confirm()
        await cancelling.value
        #expect(rig.requests(AgentsOp.cancelBatch).count == 1)
        // Another batch's actions have their own runners.
        #expect(rig.store.calls.runner(AgentsOp.cancelBatch, slot: "btcal_sep02") !== runner)
    }

    // MARK: - Phone numbers

    @Test func anOutboundCallNamesTheNumbersAndTheAgentAndUsesTheProvidersOperation() async throws {
        let rig = AgentsFixtures.Rig()
        defer { rig.clean() }
        await rig.store.directory.agents.refresh()
        await rig.store.directory.phoneNumbers.refresh()
        let model = rig.store.phoneNumbers
        model.callFromID = AgentsFixtures.secondPhoneID
        model.callAgentID = AgentsFixtures.salesAgentID
        model.callTo = "+15550199"
        model.callVariables = "first_name = Ana\norder=1042\nnot a pair"
        let runner = rig.store.calls.runner(AgentsOp.sipTrunkCall)
        let calling = Task { await model.placeCall() }
        try await waitUntil { runner.isAwaitingConfirmation }
        #expect(runner.confirmation?.title == "Place a call to +15550199 with “Sales follow-up”?")
        #expect(runner.confirmation?.confirmLabel == "Call now")
        #expect(runner.confirmation?.consequence.contains("Outbound (+15550101) through SIP trunk") == true)
        runner.confirm()
        await calling.value
        let body = try #require(rig.body(AgentsOp.sipTrunkCall))
        #expect(body["to_number"] == "+15550199")
        #expect(body["conversation_initiation_client_data"]["dynamic_variables"] == ["first_name": "Ana", "order": "1042"])
        #expect(try AgentsSpec.shared().unresolved(body: body, operationID: AgentsOp.sipTrunkCall).isEmpty)
        #expect(rig.requests(AgentsOp.twilioCall).isEmpty)
        #expect(model.callTo.isEmpty, "a placed call leaves the form")
    }

    /// Review P-2 and blocker 2: the call's busy state belongs to the screen, not to the
    /// provider's runner, and an unknown outcome blocks another call until acknowledged.
    @Test func switchingTheFromNumberDuringACallCannotStartASecond() async throws {
        var slow = FakeElevenLabsTransport.Reply.json(AgentsFixtures.answer(for: AgentsOp.twilioCall))
        slow.delay = .milliseconds(400)
        let rig = AgentsFixtures.Rig(overriding: [AgentsOp.twilioCall: slow])
        defer { rig.clean() }
        await rig.store.directory.agents.refresh()
        await rig.store.directory.phoneNumbers.refresh()
        let model = rig.store.phoneNumbers
        model.callFromID = AgentsFixtures.phoneID
        model.callAgentID = AgentsFixtures.agentID
        model.callTo = "+15550199"
        let twilio = rig.store.calls.runner(AgentsOp.twilioCall)
        let first = Task { await model.placeCall() }
        try await waitUntil { twilio.isAwaitingConfirmation }
        twilio.confirm()
        try await waitUntil { twilio.isRunning }
        model.callFromID = AgentsFixtures.secondPhoneID
        #expect(!model.callGuard.canSend)
        await model.placeCall()
        #expect(rig.requests(AgentsOp.sipTrunkCall).isEmpty)
        twilio.cancel()
        await first.value
        #expect(model.callGuard.warning?.contains("may already have been placed") == true)
        #expect(model.callTo.isEmpty)
        model.callTo = "+15550198"
        await model.placeCall()
        #expect(rig.requests(AgentsOp.sipTrunkCall).isEmpty)
    }

    @Test func importingANumberNeverShowsTheProviderToken() async throws {
        let rig = AgentsFixtures.Rig()
        defer { rig.clean() }
        let model = rig.store.phoneNumbers
        model.importLabel = "Support line"
        model.importNumber = "+15550103"
        model.twilioSID = "AC0000"
        model.twilioToken = "twilio-token-fixture"
        let runner = rig.store.calls.runner(AgentsOp.importPhoneNumber)
        let importing = Task { await model.importNumberNow() }
        try await waitUntil { runner.isAwaitingConfirmation }
        let shown = try #require(runner.apiCall?.body).jsonString()
        #expect(!shown.contains("twilio-token-fixture"), "Show API call and curl carry the mask, not the token")
        #expect(shown.contains("AC0000"))
        runner.confirm()
        await importing.value
        #expect(model.twilioToken.isEmpty, "the token leaves the form once sent")
        let body = try #require(rig.body(AgentsOp.importPhoneNumber))
        #expect(body["provider"] == "twilio")
        #expect(body["token"] == "twilio-token-fixture", "ElevenLabs gets the real token")
        #expect(try AgentsSpec.shared().unresolved(body: body, operationID: AgentsOp.importPhoneNumber).isEmpty)
    }

    // MARK: - Secrets

    @Test func aSecretsValueIsSentOnceMaskedOnScreenAndForgotten() async throws {
        let rig = AgentsFixtures.Rig()
        defer { rig.clean() }
        let model = rig.store.secrets
        model.newName = "crm_api_key_2"
        model.newValue = "crm-secret-fixture"
        let runner = rig.store.calls.runner(AgentsOp.createSecret)
        let creating = Task { await model.create() }
        try await waitUntil { runner.isAwaitingConfirmation }
        #expect(runner.confirmation?.title.contains("“crm_api_key_2”") == true)
        #expect(!(runner.apiCall?.body?.jsonString().contains("crm-secret-fixture") ?? true))
        runner.confirm()
        await creating.value
        #expect(rig.body(AgentsOp.createSecret) == ["type": "new", "name": "crm_api_key_2", "value": "crm-secret-fixture"])
        #expect(model.newValue.isEmpty)
    }

    @Test func anEnvironmentVariableGoesAsOneOfItsKindsAfterTheOwnerSaysSo() async throws {
        let rig = AgentsFixtures.Rig()
        defer { rig.clean() }
        let model = rig.store.secrets
        model.newVariableLabel = "CRM_KEY"
        model.newVariableType = "secret"
        model.newVariableValues = [("production", AgentsFixtures.secretID), ("staging", "sec_staging")]
        let runner = rig.store.calls.runner(AgentsOp.createEnvironmentVariable)
        let creating = Task { await model.createVariable() }
        try await waitUntil { runner.isAwaitingConfirmation }
        #expect(runner.confirmation?.title.contains("“CRM_KEY”") == true)
        #expect(runner.confirmation?.consequence.contains("production and staging") == true)
        runner.confirm()
        await creating.value
        let body = try #require(rig.body(AgentsOp.createEnvironmentVariable))
        #expect(body == ["label": "CRM_KEY", "type": "secret",
                         "values": ["production": ["secret_id": .string(AgentsFixtures.secretID)], "staging": ["secret_id": "sec_staging"]]])
    }

    /// Review S-2: an environment emptied in the editor is removed on the server, not left as it was.
    @Test func anEmptiedEnvironmentIsSentAsRemoved() async throws {
        let rig = AgentsFixtures.Rig()
        defer { rig.clean() }
        let model = rig.store.secrets
        await model.variables.refresh()
        await model.selectVariable("env_1")
        #expect(model.originalEnvironments == ["production", "staging"])
        model.editedValues = [("production", "https://crm.example.com")]
        let variable = try #require(model.selectedVariable)
        #expect(model.editedValuesJSON(for: variable) == ["production": "https://crm.example.com", "staging": nil])
    }

    // MARK: - Conversations

    @Test func aSignedURLIsShownOnceKeptOutOfRecentsAndGoneWithTheAgent() async throws {
        let rig = AgentsFixtures.Rig()
        defer { rig.clean() }
        let model = rig.store.conversations
        model.startAgentID = AgentsFixtures.agentID
        await model.fetchSignedURL()
        let runner = rig.store.calls.runner(AgentsOp.signedURL, slot: AgentsFixtures.agentID)
        #expect(runner.credential?.fields.first?.value.contains("sig_fixture") == true)
        #expect(!(runner.result.flatMap(AgentsCalls.json(of:))?.jsonString().contains("sig_fixture") ?? true))
        #expect(rig.pane.recents.isEmpty)
        model.startAgentID = AgentsFixtures.salesAgentID
        #expect(runner.credential == nil, "choosing another agent takes the URL off screen")
    }

    @Test func aConversationShowsItsTranscriptAnalysisAndTags() async throws {
        let rig = AgentsFixtures.Rig()
        defer { rig.clean() }
        let model = rig.store.conversations
        await model.list.refresh()
        #expect(model.list.items.count == 3)
        #expect(model.list.hasMore)
        await model.select(AgentsFixtures.conversationID)
        let detail = try #require(model.detail)
        #expect(detail.turns.count == 4)
        #expect(detail.turns[2].toolCalls == ["lookup_order"])
        #expect(detail.evaluations.map(\.result) == ["success"])
        #expect(detail.collected.first?.value == "1042")
        #expect(detail.feedback == "like")

        await rig.store.directory.tags.refresh()
        let runner = rig.store.calls.runner(AgentsOp.unassignTag, slot: AgentsFixtures.conversationID)
        let removing = Task { await model.unassignTag("tag_refund") }
        try await waitUntil { runner.isAwaitingConfirmation }
        #expect(runner.confirmation?.title == "Delete the tag “Refund” from this conversation?")
        #expect(runner.confirmation?.consequence.contains("The tag itself is kept") == true)
        runner.confirm()
        await removing.value
        #expect(model.detail?.tagIDs.isEmpty == true)
    }

    @Test func theListFiltersGoOutAsTheSpecNamesThem() throws {
        let rig = AgentsFixtures.Rig()
        defer { rig.clean() }
        let model = rig.store.conversations
        model.filterAgentID = AgentsFixtures.agentID
        model.result = "failure"
        model.since = .week
        model.searchText = "refund"
        model.now = { Date(timeIntervalSince1970: 1_000_000) }
        let arguments = model.listArguments()
        #expect(arguments["agent_id"] == .string(AgentsFixtures.agentID))
        #expect(arguments["call_successful"] == "failure")
        #expect(arguments["call_start_after_unix"] == .number(1_000_000 - 7 * 86_400))
        #expect(arguments["search"] == "refund")
    }

    // MARK: - Knowledge, tools, MCP, testing, analytics

    @Test func addingAWebPageSendsItsAddressAndSyncInTheFolderOnScreen() async throws {
        let rig = AgentsFixtures.Rig()
        defer { rig.clean() }
        let model = rig.store.knowledge
        await model.list.refresh()
        let folder = try #require(model.list.items.first { $0.isFolder })
        await model.open(folder: folder)
        model.addKind = .url
        model.addURL = "https://example.com/faq"
        model.autoSync = true
        model.syncDays = 14
        await model.add()
        #expect(rig.body(AgentsOp.createURLDocument) == [
            "url": "https://example.com/faq", "parent_folder_id": "folder_help",
            "enable_auto_sync": true, "minimum_frequency_days": 14,
        ])
        #expect(model.selectedID == "doc_new04")
    }

    /// Review K-1: cancelling a crawl (destructive now) asks once, in the pane, naming the site.
    @Test func cancellingACrawlAsksOnceNamingTheSite() async throws {
        let rig = AgentsFixtures.Rig()
        defer { rig.clean() }
        let model = rig.store.knowledge
        await model.crawls.refresh()
        let job = try #require(model.crawls.items.first)
        let runner = rig.store.calls.runner(AgentsOp.cancelCrawl, slot: job.id)
        let cancelling = Task { await model.cancelCrawl(job) }
        try await waitUntil { runner.isAwaitingConfirmation }
        #expect(runner.confirmation?.title.contains("https://example.com/help") == true)
        #expect(runner.confirmation?.consequence.contains("deletes every document") == true)
        runner.confirm()
        await cancelling.value
        #expect(rig.requests(AgentsOp.cancelCrawl).count == 1)
        #expect(rig.pane.confirming == nil, "one question, answered")
    }

    /// Review NC-1: saving a tool is real-world now; the question names the tool, where it
    /// sends and which headers (never their values) go with it.
    @Test func savingAToolAsksNamingItsHostAndHeaderNames() async throws {
        let rig = AgentsFixtures.Rig()
        defer { rig.clean() }
        let model = rig.store.tools
        await model.select(AgentsFixtures.toolID)
        #expect(model.editor.url == "https://api.example.com/orders/{order_id}")
        model.editsJSON = true
        model.configJSON = """
        {"type": "webhook", "name": "lookup_order", "description": "Finds an order by its number",
         "response_timeout_secs": 45, "api_schema": {"url": "https://api.example.com/orders/{order_id}", "method": "GET",
         "request_headers": {"Authorization": "Bearer tool-fixture-token", "X-Shop": "7"}}}
        """
        let runner = rig.store.calls.runner(AgentsOp.updateTool, slot: AgentsFixtures.toolID)
        let saving = Task { await model.save() }
        try await waitUntil { runner.isAwaitingConfirmation }
        let question = try #require(runner.confirmation)
        #expect(question.title.contains("“lookup_order” calling api.example.com"))
        #expect(question.consequence.contains("Authorization and X-Shop"))
        #expect(!question.consequence.contains("tool-fixture-token"))
        #expect(!(runner.apiCall?.body?.jsonString().contains("tool-fixture-token") ?? true))
        runner.confirm()
        await saving.value
        let body = try #require(rig.body(AgentsOp.updateTool))
        #expect(body["tool_config"]["response_timeout_secs"] == 45)
        #expect(body["tool_config"]["description"] == "Finds an order by its number")
        // Executions from an agent the list has not reached are named by a lookup.
        await model.loadExecutions()
        #expect(rig.store.directory.agentName("agent_unknown9") == "Old returns agent")
    }

    @Test func aWebhookToolNeedsARealAddress() {
        var editor = AgentsToolEditor()
        editor.name = "hook"
        editor.description = "Calls a hook"
        for bad in ["httpfoo://x", "https://user:pass@example.com/x", "ftp://example.com", "https://"] {
            editor.url = bad
            #expect(!editor.problems.isEmpty, "\(bad)")
        }
        editor.url = "https://example.com/hook"
        #expect(editor.problems.isEmpty)
    }

    /// Review M-2: an MCP address with a password is refused; plain http, this Mac, private and
    /// link-local addresses are allowed only with a warning that the question repeats.
    @Test func anMCPAddressIsCheckedBeforeAgentsSendAnythingThere() {
        #expect(AgentsOutsideAddress("https://user:pass@mcp.example.com/sse").refusal != nil)
        #expect(AgentsOutsideAddress("https:///sse").refusal != nil)
        #expect(AgentsOutsideAddress("file:///etc/passwd").refusal != nil)
        #expect(AgentsOutsideAddress("https://mcp.example.com/sse").warnings.isEmpty)
        for (address, word) in [("http://mcp.example.com/sse", "plain http"), ("https://localhost:8080/sse", "loopback"),
                                ("https://127.0.0.1/sse", "loopback"), ("https://192.168.1.20/sse", "private"),
                                ("https://10.0.0.5/sse", "private"), ("https://172.20.1.1/sse", "private"),
                                ("https://169.254.169.254/latest", "link-local"), ("https://printer.local/sse", "private"),
                                ("https://[::1]/sse", "loopback")] {
            let found = AgentsOutsideAddress(address)
            #expect(found.isAllowed, "\(address)")
            #expect(found.warnings.contains { $0.contains(word) }, "\(address): \(found.warnings)")
        }
    }

    /// Round 2 (c): the same machines written other ways, over https too.
    @Test func loopbackAndPrivateHostsAreRecognisedHoweverWritten() {
        let cases: [(String, String)] = [
            ("https://[::ffff:127.0.0.1]/sse", "loopback"), ("https://[::ffff:7f00:1]/sse", "loopback"),
            ("https://localhost./sse", "loopback"), ("https://2130706433/sse", "loopback"),
            ("https://0x7f000001/sse", "loopback"), ("https://0177.0.0.1/sse", "loopback"), ("https://127.1/sse", "loopback"),
            ("https://[fe80::1]/sse", "link-local"), ("https://2852039166/latest", "link-local"),
            ("https://[fd12:3456::1]/sse", "private"), ("https://[::ffff:10.0.0.5]/sse", "private"),
            ("https://10.1/sse", "private"), ("https://0xc0a80001/sse", "private"),
        ]
        for (address, word) in cases {
            let found = AgentsOutsideAddress(address)
            #expect(found.isAllowed, "\(address)")
            #expect(found.warnings.contains { $0.contains(word) }, "\(address): \(found.warnings)")
            #expect(!found.warnings.contains { $0.contains("plain http") }, "\(address) is https")
        }
        for address in ["https://8.8.8.8/sse", "https://mcp.example.com/sse", "https://[2001:db8::1]/sse", "https://1000.example.com/x"] {
            #expect(AgentsOutsideAddress(address).warnings.isEmpty, "\(address)")
        }
    }

    @Test func connectingAnMCPServerSaysWhereAgentsWillSendThings() async throws {
        let rig = AgentsFixtures.Rig()
        defer { rig.clean() }
        let model = rig.store.mcpServers
        model.newName = "Order system"
        model.newURL = "http://192.168.1.20/sse"
        model.newApprovalPolicy = "require_approval_all"
        let runner = rig.store.calls.runner(AgentsOp.createMCPServer)
        let creating = Task { await model.create() }
        try await waitUntil { runner.isAwaitingConfirmation }
        let question = try #require(runner.confirmation)
        #expect(question.title.contains("http://192.168.1.20/sse"))
        #expect(question.consequence.hasPrefix("Careful: It is plain http"))
        #expect(question.consequence.contains("private-network"))
        #expect(question.consequence.contains("ask the caller before they run"))
        runner.confirm()
        await creating.value
        let body = try #require(rig.body(AgentsOp.createMCPServer))
        #expect(body["config"]["url"] == "http://192.168.1.20/sse")
        #expect(try AgentsSpec.shared().unresolved(body: body, operationID: AgentsOp.createMCPServer).isEmpty)
    }

    /// Review M-1: statuses are matched by the spec's `mcp:<server>:<tool>` ids, and a changed
    /// definition says so.
    @Test func eachMCPToolShowsItsApprovalAndAChangedDefinition() async throws {
        let rig = AgentsFixtures.Rig()
        defer { rig.clean() }
        let model = rig.store.mcpServers
        await model.select(AgentsFixtures.serverID)
        await model.loadTools()
        #expect(model.tools.map(\.approval) == ["auto_approved", "requires_approval"])
        #expect(model.tools.map { $0.badge?.text } == ["Runs without asking", "Changed since approval"])
    }

    /// Review M-3: switching a server to run every tool without asking says exactly that.
    @Test func turningOnAutoApproveAllSaysToolsRunWithoutAsking() async throws {
        let rig = AgentsFixtures.Rig()
        defer { rig.clean() }
        let model = rig.store.mcpServers
        await model.select(AgentsFixtures.serverID)
        model.settings.approvalPolicy = "auto_approve_all"
        let runner = rig.store.calls.runner(AgentsOp.updateMCPServer, slot: AgentsFixtures.serverID)
        let saving = Task { await model.saveSettings() }
        try await waitUntil { runner.isAwaitingConfirmation }
        #expect(runner.confirmation?.title.contains("run without asking") == true)
        #expect(runner.confirmation?.consequence.hasPrefix(
            "Every tool on https://mcp.example.com/sse will run without asking the caller first") == true)
        runner.decline()
        await saving.value
        #expect(rig.requests(AgentsOp.updateMCPServer).isEmpty)
    }

    @Test func aResponseTestIsSentWithOnlyTheFieldsItsKindAccepts() async throws {
        let rig = AgentsFixtures.Rig()
        defer { rig.clean() }
        let model = rig.store.testing
        await model.select(AgentsFixtures.testID)
        #expect(model.draft.successExamples == "Let me get a colleague who can help with the refund.")
        model.draft.successCondition = "Offers a person."
        await model.save()
        let recorded = try #require(rig.requests(AgentsOp.updateTest).last)
        #expect(recorded.request.method == "PUT")
        let body = try JSONValue(data: recorded.body)
        #expect(body["success_condition"] == "Offers a person.")
        #expect(body["id"] == .null, "read-only fields are not sent back")
        #expect(body["created_at_unix_secs"] == .null)
        #expect(try AgentsSpec.shared().unresolved(body: body, operationID: AgentsOp.updateTest).isEmpty)

        await model.openInvocation("inv_1")
        #expect(model.invocationRuns.count == 2)
        #expect(model.summaries["test_sim02"] == "Impatient caller reschedules")
    }

    @Test func analyticsCountsLiveConversationsAndPricesTheLLMs() async throws {
        let rig = AgentsFixtures.Rig()
        defer { rig.clean() }
        let model = rig.store.analytics
        await model.loadLiveCount()
        #expect(model.liveCount == 3)
        model.promptLength = 4000
        await model.estimateCost()
        #expect(model.prices.first?.llm == "gemini-2.5-flash")
        #expect(rig.body(AgentsOp.llmCost) == ["prompt_length": 4000, "number_of_pages": 0, "rag_enabled": false])
        model.agentID = AgentsFixtures.agentID
        await model.estimateCost()
        #expect(rig.requests(AgentsOp.agentLLMCost).count == 1)
        await model.tickets.refresh()
        await model.openTicket("tkt_1")
        #expect(model.ticket?.comments.count == 1)
        #expect(model.assignableUsers.map(\.name) == ["Alex"])
    }

    @Test func nothingLeavesForAHostOutsideTheRegionAllowlist() async throws {
        let rig = AgentsFixtures.Rig()
        defer { rig.clean() }
        await rig.store.agents.list.refresh()
        await rig.store.conversations.list.refresh()
        await rig.store.knowledge.list.refresh()
        await rig.store.batchCalls.list.refresh()
        #expect(rig.transport.requests.count == 4)
        #expect(rig.transport.hostViolations.isEmpty)
        #expect(rig.transport.requests.allSatisfy { $0.url.host == ElevenLabsRegion.global.host })
    }

    /// Review LIST-1: a filter changed while the list loads is fetched too, not dropped.
    @Test func aFilterChangedDuringALoadIsFetchedAgain() async throws {
        var slow = FakeElevenLabsTransport.Reply.json(AgentsFixtures.answer(for: AgentsOp.listBatches))
        slow.delay = .milliseconds(200)
        let rig = AgentsFixtures.Rig(overriding: [AgentsOp.listBatches: slow])
        defer { rig.clean() }
        let model = rig.store.batchCalls
        let first = Task { await model.list.refresh() }
        try await waitUntil { rig.requests(AgentsOp.listBatches).count == 1 }
        model.filterAgentID = AgentsFixtures.agentID
        await model.list.refresh()
        await first.value
        #expect(rig.requests(AgentsOp.listBatches).count == 2)
        #expect(rig.requests(AgentsOp.listBatches).last?.request.url.query?.contains("agent_id=agent_support01") == true)
    }

    // MARK: - Store

    /// Review item 3: a region change, a new key or a disconnect never hands back the previous
    /// account's store — even when the new client lands at the old one's address.
    @Test func aRegionChangeStartsAFreshStore() {
        var settings = Settings()
        settings.elevenLabsLinked = true
        let app = AppModel(settings: settings)
        var reused = 0
        for index in 0..<40 {
            let before = AgentsPlatformStore.shared(for: app)
            before.batchCalls.name = "workspace \(index)"
            #expect(AgentsPlatformStore.shared(for: app) === before, "the same account keeps its store")
            app.elevenLabsRegion = index.isMultiple(of: 2) ? .eu : .global
            let after = AgentsPlatformStore.shared(for: app)
            if after === before || after.batchCalls.name == "workspace \(index)" { reused += 1 }
        }
        #expect(reused == 0, "\(reused) of 40 region changes kept the previous workspace's store")
    }

    // MARK: - Helpers

    func fillBatch(_ model: AgentBatchCallsModel) {
        model.name = "October renewals"
        model.agentID = AgentsFixtures.agentID
        model.phoneNumberID = AgentsFixtures.phoneID
        model.recipientsText = "phone_number,FirstName\n+15550111,Ana\n+15550112,Ben\n+15550113,Cy"
    }


    func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("timed out waiting")
    }
}

/// The pinned OpenAPI snapshot, read the way the spec means it: `$ref`s followed, unions
/// searched, open maps (dynamic variables, free-form configs) accepted below their name.
final class AgentsSpec: @unchecked Sendable {
    private let schemas: [String: Any]
    private let operations: [String: [String: Any]]

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: AgentsSpec?

    static func shared() throws -> AgentsSpec {
        try lock.withLock {
            if let cached { return cached }
            let url = CoreCatalogTests.repository.appendingPathComponent("Scripts/elevenlabs/openapi.json")
            let spec = try AgentsSpec(data: Data(contentsOf: url))
            cached = spec
            return spec
        }
    }

    init(data: Data) throws {
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        schemas = (root["components"] as? [String: Any])?["schemas"] as? [String: Any] ?? [:]
        var operations: [String: [String: Any]] = [:]
        for (_, item) in root["paths"] as? [String: Any] ?? [:] {
            for (_, value) in item as? [String: Any] ?? [:] {
                if let operation = value as? [String: Any], let id = operation["operationId"] as? String {
                    operations[id] = operation
                }
            }
        }
        self.operations = operations
    }

    func resolves(_ argument: AgentsArgument) -> Bool {
        guard let operation = operations[argument.operationID] else { return false }
        let segments = argument.path.split(separator: ".").map(String.init)
        let first = segments[0].replacingOccurrences(of: "[]", with: "")
        if segments.count == 1, parameterNames(operation).contains(first) { return true }
        guard let body = bodySchema(operation) else { return false }
        return walk(body, segments[...])
    }

    /// The leaf paths of a request body that the operation's body schema does not have.
    func unresolved(body: JSONValue, operationID: String) -> [String] {
        AgentsJSON.leafPaths(body).filter { !resolves(AgentsArgument(operationID, $0)) }
    }

    private func parameterNames(_ operation: [String: Any]) -> Set<String> {
        Set((operation["parameters"] as? [Any] ?? []).compactMap { (resolve($0) as? [String: Any])?["name"] as? String })
    }

    private func bodySchema(_ operation: [String: Any]) -> Any? {
        let content = (operation["requestBody"] as? [String: Any])?["content"] as? [String: Any] ?? [:]
        return (content["application/json"] as? [String: Any])?["schema"]
            ?? (content["multipart/form-data"] as? [String: Any])?["schema"]
    }

    private func resolve(_ node: Any) -> Any {
        var node = node
        var seen = 0
        while let object = node as? [String: Any], let reference = object["$ref"] as? String, seen < 32 {
            node = schemas[String(reference.split(separator: "/").last ?? "")] ?? [:]
            seen += 1
        }
        return node
    }

    private func walk(_ node: Any, _ segments: ArraySlice<String>) -> Bool {
        let schema = resolve(node) as? [String: Any] ?? [:]
        guard var segment = segments.first else { return true }
        if isOpen(schema) { return true }
        var intoItems = false
        if segment.hasSuffix("[]") {
            segment.removeLast(2)
            intoItems = true
        }
        for candidate in [schema] + variants(schema) {
            let candidate = resolve(candidate) as? [String: Any] ?? [:]
            if isOpen(candidate) { return true }
            guard let property = (candidate["properties"] as? [String: Any])?[segment] else { continue }
            let next = intoItems ? items(property) : property
            if walk(next, segments.dropFirst()) { return true }
        }
        return false
    }

    private func variants(_ schema: [String: Any]) -> [Any] {
        ["anyOf", "oneOf", "allOf"].flatMap { schema[$0] as? [Any] ?? [] }
    }

    private func items(_ node: Any) -> Any {
        let schema = resolve(node) as? [String: Any] ?? [:]
        if let items = schema["items"] { return items }
        for variant in variants(schema) {
            if let items = (resolve(variant) as? [String: Any])?["items"] { return items }
        }
        return [:] as [String: Any]
    }

    /// A map or a free-form object: anything below it is the owner's to name.
    private func isOpen(_ schema: [String: Any]) -> Bool {
        if schema["additionalProperties"] is [String: Any] || schema["additionalProperties"] as? Bool == true { return true }
        return schema["type"] as? String == "object" && schema["properties"] == nil
    }
}
