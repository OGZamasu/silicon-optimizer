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
        let runner = rig.store.calls.runner(AgentsOp.deleteAgent)
        try await waitUntil { runner.isAwaitingConfirmation }
        #expect(runner.confirmation?.title == "Delete the agent “Support”?")
        #expect(runner.confirmation?.consequence.contains("Phone numbers") == true)
        runner.decline()
        await deleting.value
        #expect(rig.requests(AgentsOp.deleteAgent).isEmpty)
        #expect(model.selectedID == AgentsFixtures.agentID)
    }

    @Test func aDraftKeepsTheWholeConfigurationWithTheEditsMergedIn() async throws {
        let rig = AgentsFixtures.Rig()
        defer { rig.clean() }
        let model = rig.store.agents
        await model.select(AgentsFixtures.agentID)
        model.draft.firstMessage = "Hi there!"
        await model.saveAsDraft()
        let recorded = try #require(rig.requests(AgentsOp.createDraft).last)
        #expect(recorded.request.url.query?.contains("branch_id=agtbrch_main") == true)
        let body = try JSONValue(data: recorded.body)
        #expect(body["conversation_config"]["agent"]["first_message"] == "Hi there!")
        #expect(body["conversation_config"]["agent"]["prompt"]["llm"] == "gemini-2.5-flash")
        #expect(body["workflow"] != .null)
    }

    // MARK: - Batch calls

    @Test func recipientsAreReadFromCSVWithVariablesOrFromPlainLines() {
        let csv = """
        phone_number,first_name,order
        +1 (555) 010-0111,Ana,1042
        "+15550112","Ben, Jr.",1043
        +15550112,Dupe,1
        not-a-number,Cy,9
        """
        let parsed = AgentsBatchRecipients.parse(csv, whatsApp: false)
        #expect(parsed.recipients.map(\.phoneNumber) == ["+15550100111", "+15550112"])
        #expect(parsed.recipients[1].variables == ["first_name": "Ben, Jr.", "order": "1043"])
        #expect(parsed.duplicates == 1)
        #expect(parsed.problems == ["Line 5: “not-a-number” is not a phone number."])

        let plain = AgentsBatchRecipients.parse("+15550121\n\n+15550122\n", whatsApp: false)
        #expect(plain.recipients.count == 2)
        #expect(plain.recipients.allSatisfy { $0.variables.isEmpty })
        #expect(AgentsBatchRecipients.parse("name,email\nA,a@example.com", whatsApp: false).problems.first?.contains("phone_number") == true)
    }

    @Test func submittingABatchSaysHowManyPeopleWhichAgentAndFromWhereBeforeCalling() async throws {
        let rig = AgentsFixtures.Rig()
        defer { rig.clean() }
        await rig.store.directory.agents.refresh()
        await rig.store.directory.phoneNumbers.refresh()
        let model = rig.store.batchCalls
        model.name = "October renewals"
        model.agentID = AgentsFixtures.agentID
        model.phoneNumberID = AgentsFixtures.phoneID
        model.recipientsText = "phone_number,first_name\n+15550111,Ana\n+15550112,Ben\n+15550113,Cy"
        #expect(model.submitProblems.isEmpty)

        let wording = model.submitConfirmation()
        #expect(wording.title == "Place 3 real phone calls with “Support”?")
        #expect(wording.label == "Place 3 calls")
        #expect(wording.consequence.contains("3 recipients"))
        #expect(wording.consequence.contains("Support line (+15550100) through Twilio"))
        #expect(wording.consequence.contains("billed by the minute"))

        // Declined: nothing is sent.
        let runner = rig.store.calls.runner(AgentsOp.submitBatch)
        let declined = Task { await model.submit() }
        try await waitUntil { runner.isAwaitingConfirmation }
        #expect(AgentsConfirmationWording.title(for: runner) == wording.title)
        #expect(AgentsConfirmationWording.label(for: runner) == wording.label)
        #expect(runner.confirmation?.consequence == wording.consequence)
        #expect(runner.confirmation?.risk == .realWorld)
        runner.decline()
        await declined.value
        #expect(rig.requests(AgentsOp.submitBatch).isEmpty)

        // Confirmed: the recipients go with their variables.
        let confirmed = Task { await model.submit() }
        try await waitUntil { runner.isAwaitingConfirmation }
        runner.confirm()
        await confirmed.value
        let body = try #require(rig.body(AgentsOp.submitBatch))
        #expect(body["recipients"].arrayValue?.count == 3)
        #expect(body["recipients"][0] == ["phone_number": "+15550111",
                                          "conversation_initiation_client_data": ["dynamic_variables": ["first_name": "Ana"]]])
        #expect(body["agent_phone_number_id"] == .string(AgentsFixtures.phoneID))
        #expect(body["call_name"] == "October renewals")
        #expect(try AgentsSpec.shared().unresolved(body: body, operationID: AgentsOp.submitBatch).isEmpty)
        #expect(model.selectedID == AgentsFixtures.batchID)
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

    @Test func retryCountsTheFailedAndUnansweredAndCancelSaysItStops() async throws {
        let rig = AgentsFixtures.Rig()
        defer { rig.clean() }
        let model = rig.store.batchCalls
        await model.select(AgentsFixtures.batchID)
        #expect(model.recipients.count == 5)
        #expect(model.retryCount == 2)
        #expect(model.pendingCount == 2)
        let retry = try #require(model.retryConfirmation())
        #expect(retry.title == "Call 2 recipients of “October renewals” again with “Support”?")
        #expect(retry.label == "Place 2 calls")

        let runner = rig.store.calls.runner(AgentsOp.cancelBatch)
        let cancelling = Task { await model.cancel() }
        try await waitUntil { runner.isAwaitingConfirmation }
        #expect(AgentsConfirmationWording.label(for: runner) == "Stop the batch")
        #expect(AgentsConfirmationWording.title(for: runner) == "Stop the batch “October renewals”?")
        runner.confirm()
        await cancelling.value
        #expect(rig.requests(AgentsOp.cancelBatch).count == 1)
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
        #expect(AgentsConfirmationWording.title(for: runner) == "Call +15550199 now with “Sales follow-up”?")
        #expect(runner.confirmation?.consequence.contains("Outbound (+15550101) through SIP trunk") == true)
        runner.confirm()
        await calling.value
        let body = try #require(rig.body(AgentsOp.sipTrunkCall))
        #expect(body["to_number"] == "+15550199")
        #expect(body["conversation_initiation_client_data"]["dynamic_variables"] == ["first_name": "Ana", "order": "1042"])
        #expect(try AgentsSpec.shared().unresolved(body: body, operationID: AgentsOp.sipTrunkCall).isEmpty)
        #expect(rig.requests(AgentsOp.twilioCall).isEmpty)
    }

    @Test func importingANumberMasksTheProviderTokenInShowAPICall() async throws {
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
        let shown = try #require(runner.apiCall?.body)
        #expect(shown.jsonString().contains("twilio-token-fixture"), "the runner holds what it will send")
        let masked = AgentsSecretMask.masked(shown, fields: AgentPhoneNumbersModel.secretFields).jsonString()
        #expect(!masked.contains("twilio-token-fixture"))
        #expect(masked.contains("AC0000"))
        runner.confirm()
        await importing.value
        #expect(model.twilioToken.isEmpty, "the token leaves the form once sent")
        let body = try #require(rig.body(AgentsOp.importPhoneNumber))
        #expect(body["provider"] == "twilio")
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
        #expect(AgentsConfirmationWording.title(for: runner) == "Store the secret “crm_api_key_2” in the workspace?")
        runner.confirm()
        await creating.value
        #expect(rig.body(AgentsOp.createSecret) == ["type": "new", "name": "crm_api_key_2", "value": "crm-secret-fixture"])
        #expect(model.newValue.isEmpty)
        let call = try #require(runner.apiCall?.body)
        #expect(!AgentsSecretMask.masked(call, fields: AgentSecretsModel.secretFields).jsonString().contains("crm-secret-fixture"))
    }

    @Test func anEnvironmentVariableGoesAsOneOfItsKinds() async throws {
        let rig = AgentsFixtures.Rig()
        defer { rig.clean() }
        let model = rig.store.secrets
        model.newVariableLabel = "CRM_KEY"
        model.newVariableType = "secret"
        model.newVariableValues = [("production", AgentsFixtures.secretID), ("staging", "sec_staging")]
        await model.createVariable()
        let body = try #require(rig.body(AgentsOp.createEnvironmentVariable))
        #expect(body == ["label": "CRM_KEY", "type": "secret",
                         "values": ["production": ["secret_id": .string(AgentsFixtures.secretID)], "staging": ["secret_id": "sec_staging"]]])
    }

    // MARK: - Conversations

    @Test func aSignedURLIsShownOnceAndKeptOutOfTheRecentList() async throws {
        let rig = AgentsFixtures.Rig()
        defer { rig.clean() }
        let model = rig.store.conversations
        model.startAgentID = AgentsFixtures.agentID
        await model.fetchSignedURL()
        let runner = rig.store.calls.runner(AgentsOp.signedURL)
        #expect(runner.credential?.fields.first?.value.contains("sig_fixture") == true)
        #expect(!(runner.result.flatMap(AgentsCalls.json(of:))?.jsonString().contains("sig_fixture") ?? true))
        #expect(rig.pane.recents.isEmpty)
        runner.dismissCredential()
        #expect(runner.credential == nil)
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

        let runner = rig.store.calls.runner(AgentsOp.unassignTag)
        let removing = Task { await model.unassignTag("tag_refund") }
        try await waitUntil { runner.isAwaitingConfirmation }
        #expect(AgentsConfirmationWording.label(for: runner) == "Remove tag")
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

    @Test func aToolKeepsWhatTheFormDoesNotShowWhenSaved() async throws {
        let rig = AgentsFixtures.Rig()
        defer { rig.clean() }
        let model = rig.store.tools
        await model.select(AgentsFixtures.toolID)
        #expect(model.editor.url == "https://api.example.com/orders/{order_id}")
        model.editor.timeoutSeconds = 45
        await model.save()
        let body = try #require(rig.body(AgentsOp.updateTool))
        #expect(body["tool_config"]["response_timeout_secs"] == 45)
        #expect(body["tool_config"]["api_schema"]["method"] == "GET")
        #expect(body["tool_config"]["description"] == "Finds an order by its number")
        // Executions from an agent the list has not reached are named by a lookup.
        await model.loadExecutions()
        #expect(rig.store.directory.agentName("agent_unknown9") == "Old returns agent")
    }

    @Test func connectingAnMCPServerSaysWhereAgentsWillSendThings() async throws {
        let rig = AgentsFixtures.Rig()
        defer { rig.clean() }
        let model = rig.store.mcpServers
        model.newName = "Order system"
        model.newURL = "https://mcp.example.com/sse"
        model.newApprovalPolicy = "require_approval_all"
        let runner = rig.store.calls.runner(AgentsOp.createMCPServer)
        let creating = Task { await model.create() }
        try await waitUntil { runner.isAwaitingConfirmation }
        #expect(AgentsConfirmationWording.title(for: runner) == "Connect agents to https://mcp.example.com/sse?")
        #expect(runner.confirmation?.consequence.contains("ask for approval first") == true)
        runner.confirm()
        await creating.value
        let body = try #require(rig.body(AgentsOp.createMCPServer))
        #expect(body["config"]["url"] == "https://mcp.example.com/sse")
        #expect(try AgentsSpec.shared().unresolved(body: body, operationID: AgentsOp.createMCPServer).isEmpty)
        await model.loadTools()
        #expect(model.tools.map(\.approval) == ["auto_approved", "requires_approval"])
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

    // MARK: - Helpers

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
