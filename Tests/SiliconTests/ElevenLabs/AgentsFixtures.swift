import Foundation
import SiliconElevenLabs
@testable import SiliconUI

/// A pretend ElevenLabs for the agents sections' tests: realistic answers by operation, all in
/// memory. Numbers are from the fictional 555-01xx range, addresses from the documentation
/// ranges, people from example.com. Nothing here reaches a network, a Keychain or a real file.
enum AgentsFixtures {

    /// A store whose calls go to `transport` through a real client with a fake key and a
    /// scratch sink.
    @MainActor
    struct Rig {
        let transport: FakeElevenLabsTransport
        let credentials = FakeCredentialSource(key: "fixture-not-a-real-key")
        let sink = TemporaryFileSink()
        let client: ElevenLabsClient
        let store: AgentsPlatformStore
        let pane = ElevenLabsPaneState(defaults: nil, client: { nil })

        /// A rig whose answers for some operations are replaced (a delay, a failure, another body).
        init(overriding overrides: [String: FakeElevenLabsTransport.Reply]) {
            self.init { request in
                if let reply = overrides[request.operationID] { return reply }
                return try await AgentsFixtures.reply(request)
            }
        }

        init(handler: @escaping @Sendable (ElevenLabsRequest) async throws -> FakeElevenLabsTransport.Reply = AgentsFixtures.reply) {
            transport = FakeElevenLabsTransport(handler: handler)
            client = ElevenLabsClient(credentials: credentials, region: .global, transport: transport, sink: sink)
            let client = client
            let sink = sink
            store = AgentsPlatformStore(context: .init(client: { client }, sink: { sink }, pane: pane))
        }

        /// Every request's operation id, in order.
        var sent: [String] { transport.requests.map(\.operationID) }

        func requests(_ operationID: String) -> [FakeElevenLabsTransport.Recorded] {
            transport.recorded.filter { $0.request.operationID == operationID }
        }

        /// The JSON body of the last request for `operationID`.
        func body(_ operationID: String) -> JSONValue? {
            requests(operationID).last.flatMap { try? JSONValue(data: $0.body) }
        }

        func clean() {
            transport.removeTemporaryFiles()
            sink.removeAll()
        }
    }

    // MARK: - Answers

    static let agentID = "agent_support01"
    static let salesAgentID = "agent_sales02"
    static let phoneID = "phnum_main01"
    static let secondPhoneID = "phnum_sip02"
    static let batchID = "btcal_oct01"
    static let conversationID = "conv_0001"
    static let documentID = "doc_hours01"
    static let toolID = "tool_orders01"
    static let serverID = "mcp_orders01"
    static let secretID = "sec_crm01"
    static let testID = "test_refund01"

    @Sendable
    static func reply(_ request: ElevenLabsRequest) async throws -> FakeElevenLabsTransport.Reply {
        switch request.operationID {
        case AgentsOp.documentContent:
            return .init(status: 200, headers: ["content-type": "text/plain"],
                         body: Data("Monday to Friday, 9:00 to 18:00. Saturday 10:00 to 14:00.".utf8))
        case AgentsOp.conversationAudio:
            return .audio(Data(repeating: 0xFF, count: 2_048))
        case AgentsOp.exportBatch:
            return .init(status: 200, headers: ["content-type": "text/csv"], body: Data("phone_number,status\n+15550111,completed\n".utf8))
        case AgentsOp.getMergeProposal:
            // The proposal asked for, by the last path component.
            return .json(mergeProposal(request.url.lastPathComponent))
        default:
            return .json(answer(for: request.operationID))
        }
    }

    static func answer(for operationID: String) -> JSONValue {
        switch operationID {
        case AgentsOp.listAgents:
            return ["agents": [agentSummary(agentID, "Support", tags: ["support", "english"], lastCall: 1_790_000_000),
                               agentSummary(salesAgentID, "Sales follow-up", tags: ["sales"], lastCall: nil)],
                    "has_more": false]
        case AgentsOp.getAgent, AgentsOp.updateAgent:
            return agent
        case AgentsOp.createAgent, AgentsOp.duplicateAgent:
            return ["agent_id": "agent_new03"]
        case AgentsOp.listLLMs:
            return ["llms": [["llm": "gemini-2.5-flash", "max_context_limit": 1_000_000, "supports_image_input": true],
                             ["llm": "gpt-4o-mini", "max_context_limit": 128_000]],
                    "default_deprecation_config": [:]]
        case AgentsOp.agentWidget:
            return ["agent_id": .string(agentID), "widget_config": ["variant": "compact", "placement": "bottom-right",
                                                                     "avatar": ["type": "orb"], "text_input_enabled": true]]
        case AgentsOp.agentLink:
            return ["agent_id": .string(agentID), "token": ["agent_id": .string(agentID), "conversation_token": "tok_fixture_share",
                                                            "purpose": "shareable_link"]]
        case AgentsOp.listBranches:
            return ["results": [
                ["id": "agtbrch_main", "name": "Main", "agent_id": .string(agentID), "description": "What callers hear",
                 "created_at": 1_780_000_000, "last_committed_at": 1_789_000_000, "is_archived": false,
                 "current_live_percentage": 100, "calls_7d": 412, "draft_exists": false],
                ["id": "agtbrch_tone", "name": "Warmer tone", "agent_id": .string(agentID),
                 "description": "Softer greeting and shorter answers", "created_at": 1_789_500_000,
                 "last_committed_at": 1_789_900_000, "is_archived": false, "current_live_percentage": 0,
                 "calls_7d": 0, "draft_exists": true, "commits_ahead": 2, "commits_behind": 1,
                 "parent_branch_id": "agtbrch_main"],
            ]]
        case AgentsOp.versionMetadata:
            return ["id": "agtvrsn_7", "agent_id": .string(agentID), "branch_id": "agtbrch_main",
                    "version_description": "Shorter first message", "seq_no_in_branch": 7,
                    "time_committed_secs": 1_789_000_000, "parents": [:]]
        case AgentsOp.listMergeProposals:
            return ["results": [mergeProposal("mp_1"), mergeProposal("mp_2")], "next_cursor": nil, "has_more": false]
        case AgentsOp.listProcedures:
            return ["procedures": [["procedure_id": "proc_refund", "name": "Refunds", "type": "free_form",
                                    "trigger": "The caller wants money back", "has_draft": true]]]
        case AgentsOp.getProcedure, AgentsOp.getProcedureDraft:
            return ["procedure_id": "proc_refund", "name": "Refunds", "type": "free_form",
                    "trigger": "The caller wants money back", "content": "1. Ask for the order number.\n2. Check it."]
        case AgentsOp.getSettings:
            return ["can_use_mcp_servers": true, "rag_retention_period_days": 10, "default_livekit_stack": "standard",
                    "webhooks": ["events": ["transcript"], "post_call_webhook_id": nil]]
        case AgentsOp.getDashboardSettings:
            return ["charts": [["name": "Success rate", "type": "call_success"]]]
        case AgentsOp.listConversations:
            return ["conversations": [
                conversationSummary(conversationID, "Order 1042 delivery moved", result: "success", start: 1_790_000_000, duration: 184),
                conversationSummary("conv_0002", "Refund request escalated", result: "failure", start: 1_789_990_000, duration: 421),
                conversationSummary("conv_0003", "Opening hours", result: "success", start: 1_789_980_000, duration: 41),
            ], "has_more": true, "next_cursor": "c2"]
        case AgentsOp.getConversation, AgentsOp.runAnalysis:
            return conversation
        case AgentsOp.textSearch, AgentsOp.smartSearch:
            return ["results": [["conversation_id": .string(conversationID), "agent_id": .string(agentID), "agent_name": "Support",
                                 "transcript_index": 2, "chunk_text": "Could we move the delivery to Friday?", "score": 0.91,
                                 "conversation_start_time_unix_secs": 1_790_000_000]],
                    "has_more": false]
        case AgentsOp.signedURL:
            return ["signed_url": "wss://api.elevenlabs.io/v1/convai/conversation?agent_id=agent_support01&conversation_signature=sig_fixture"]
        case AgentsOp.webRTCToken:
            return ["token": "tok_fixture_webrtc", "conversation_id": "conv_live01"]
        case AgentsOp.conversationUsers:
            return ["users": [["user_id": "caller-17", "last_contact_unix_secs": 1_790_000_000, "first_contact_unix_secs": 1_780_000_000,
                               "conversation_count": 3, "last_contact_conversation_id": .string(conversationID),
                               "last_contact_agent_name": "Support", "sentiment": [:], "most_frustrated_conversations": []]],
                    "has_more": false]
        case AgentsOp.listTags:
            return ["conversation_tags": [["tag_id": "tag_refund", "workspace_id": "ws", "owner_user_id": "u", "title": "Refund",
                                           "description": "Money back requests", "created_at_unix_secs": 1_780_000_000],
                                          ["tag_id": "tag_vip", "workspace_id": "ws", "owner_user_id": "u", "title": "VIP",
                                           "description": nil, "created_at_unix_secs": 1_780_000_000]],
                    "has_more": false]
        case AgentsOp.listDocuments:
            return ["documents": [
                document("folder_help", "Help centre", type: "folder", size: 0),
                document(documentID, "Opening hours", type: "text", size: 2_048),
                document("doc_returns02", "Returns policy", type: "url", size: 18_400, url: "https://example.com/returns"),
                document("doc_catalog03", "Catalogue 2026.pdf", type: "file", size: 4_200_000),
            ], "has_more": false]
        case AgentsOp.getDocument:
            return document(documentID, "Opening hours", type: "text", size: 2_048)
        case AgentsOp.documentContent:
            return "Monday to Friday, 9:00 to 18:00. Saturday 10:00 to 14:00."
        case AgentsOp.ragOverview:
            return ["total_used_bytes": 3_400_000, "total_max_bytes": 20_000_000,
                    "models": [["model": "e5_mistral_7b_instruct", "used_bytes": 3_400_000]]]
        case AgentsOp.ragIndexes:
            return ["indexes": [["id": "rag_1", "model": "e5_mistral_7b_instruct", "status": "succeeded",
                                 "progress_percentage": 100, "document_model_index_usage": ["used_bytes": 51_200]]]]
        case AgentsOp.listCrawls:
            return ["crawl_jobs": [["id": "crawl_1", "seed_url": "https://example.com/help", "max_pages": 100,
                                    "status": "processing", "pages_identified": 40, "pages_scraped": 22, "pages_failed": 1,
                                    "root_folder_id": "folder_help", "updated_at": 1_790_000_000, "created_at": 1_789_990_000]]]
        case AgentsOp.createURLDocument, AgentsOp.createTextDocument, AgentsOp.createFolder, AgentsOp.createFileDocument:
            return ["id": "doc_new04", "name": "New document"]
        case AgentsOp.ragQuery:
            return ["retrieval_query": "hours", "chunks": [["document_id": .string(documentID), "document_name": "Opening hours",
                                                           "chunk_id": "ch_1", "text": "Monday to Friday, 9:00 to 18:00.",
                                                           "vector_distance": 0.12, "content_format": "markdown",
                                                           "document_type": "text", "source_url": nil]]]
        case AgentsOp.agentKnowledgeSize:
            return ["number_of_pages": 12]
        case AgentsOp.listTools, AgentsOp.getTool, AgentsOp.createTool, AgentsOp.updateTool:
            if operationID == AgentsOp.listTools { return ["tools": [tool], "has_more": false] }
            return tool
        case AgentsOp.toolExecutions:
            return ["executions": [["id": "exec_1", "tool_id": .string(toolID), "tool_request_id": "r1",
                                    "conversation_id": .string(conversationID), "agent_id": .string(agentID),
                                    "timestamp": 1_790_000_000, "latency_secs": 0.42, "is_error": false],
                                   ["id": "exec_2", "tool_id": .string(toolID), "tool_request_id": "r2",
                                    "conversation_id": "conv_0002", "agent_id": "agent_unknown9", "timestamp": 1_789_990_000,
                                    "latency_secs": 20.0, "is_error": true, "error_message": "Timed out after 20 s"]],
                    "has_more": false]
        case AgentsOp.agentSummaries:
            return ["agent_unknown9": ["status": "success", "data": agentSummary("agent_unknown9", "Old returns agent", tags: [], lastCall: nil)]]
        case AgentsOp.listPhoneNumbers:
            return ["phone_numbers": [
                phoneNumber(phoneID, "+15550100", "Support line", provider: "twilio", agent: (agentID, "Support")),
                phoneNumber(secondPhoneID, "+15550101", "Outbound", provider: "sip_trunk", agent: nil),
            ], "has_more": false]
        case AgentsOp.getPhoneNumber:
            return phoneNumber(phoneID, "+15550100", "Support line", provider: "twilio", agent: (agentID, "Support"))
        case AgentsOp.importPhoneNumber:
            return ["phone_number_id": "phnum_new03"]
        case AgentsOp.twilioCall, AgentsOp.sipTrunkCall, AgentsOp.exotelCall, AgentsOp.whatsAppCall:
            return ["success": true, "message": "Call started", "conversation_id": "conv_call01", "callSid": "CA0001"]
        case AgentsOp.listWhatsAppAccounts:
            return ["items": [["business_account_id": "wa_b1", "phone_number_id": "wa_num1", "business_account_name": "Example Shop",
                               "phone_number_name": "Shop", "phone_number": "+15550102", "assigned_agent_id": .string(agentID),
                               "assigned_agent_name": "Support", "enable_messaging": true, "enable_audio_message_response": false,
                               "enable_typing_indicator": true, "is_token_expired": false]]]
        case AgentsOp.listBatches:
            return ["batch_calls": [batch(batchID, "October renewals", status: "in_progress"),
                                    batch("btcal_sep02", "September survey", status: "completed")],
                    "has_more": false]
        case AgentsOp.getBatch, AgentsOp.submitBatch:
            var value = batch(batchID, "October renewals", status: "in_progress").objectValue ?? [:]
            value["recipients"] = [
                recipient("r1", "+15550111", "completed", conversation: "conv_b1"),
                recipient("r2", "+15550112", "failed", conversation: nil),
                recipient("r3", "+15550113", "voicemail", conversation: "conv_b3"),
                recipient("r4", "+15550114", "pending", conversation: nil),
                recipient("r5", "+15550115", "in_progress", conversation: "conv_b5"),
            ]
            return .object(value)
        case AgentsOp.listMCPServers:
            return ["mcp_servers": [mcpServer]]
        case AgentsOp.getMCPServer, AgentsOp.createMCPServer, AgentsOp.updateMCPServer:
            return mcpServer
        case AgentsOp.listMCPTools:
            return ["success": true, "tools": [
                ["name": "lookup_order", "description": "Finds an order by number", "inputSchema": ["type": "object"]],
                ["name": "issue_refund", "description": "Refunds an order", "inputSchema": ["type": "object"]],
            ], "tool_approval_statuses": [
                // As the spec names them: `mcp:<server id>:<tool name>`.
                ["tool_id": "mcp:mcp_orders01:lookup_order", "state": "up_to_date", "approval_policy": "auto_approved"],
                ["tool_id": "mcp:mcp_orders01:issue_refund", "state": "needs_review", "approval_policy": "requires_approval"],
            ]]
        case AgentsOp.listSecrets:
            return ["secrets": [secret(secretID, "crm_api_key", tools: 2, agents: 1), secret("sec_unused02", "old_token", tools: 0, agents: 0)]]
        case AgentsOp.getSecret:
            return secret(secretID, "crm_api_key", tools: 2, agents: 1)
        case AgentsOp.createSecret:
            return ["type": "stored", "secret_id": "sec_new03", "name": "crm_api_key_2"]
        case AgentsOp.listEnvironmentVariables:
            return ["environment_variables": [["label": "CRM_BASE_URL", "created_at_unix_secs": 1_780_000_000,
                                               "updated_at_unix_secs": 1_789_000_000, "type": "string", "id": "env_1",
                                               "workspace_id": "ws", "values": ["production": "https://crm.example.com",
                                                                                "staging": "https://staging.crm.example.com"]]],
                    "has_more": false]
        case AgentsOp.getEnvironmentVariable:
            return ["label": "CRM_BASE_URL", "created_at_unix_secs": 1_780_000_000, "updated_at_unix_secs": 1_789_000_000,
                    "type": "string", "id": "env_1", "workspace_id": "ws",
                    "values": ["production": "https://crm.example.com", "staging": "https://staging.crm.example.com"]]
        case AgentsOp.createEnvironmentVariable:
            return ["label": "NEW_VAR", "created_at_unix_secs": 1_790_000_000, "updated_at_unix_secs": 1_790_000_000,
                    "type": "string", "id": "env_new", "workspace_id": "ws", "values": ["production": "x"]]
        case AgentsOp.listTests:
            return ["tests": [
                ["id": "folder_regress", "name": "Regression", "created_at_unix_secs": 1_780_000_000,
                 "last_updated_at_unix_secs": 1_780_000_000, "type": "folder", "entity_type": "folder", "children_count": 4],
                ["id": .string(testID), "name": "Refund request is escalated", "created_at_unix_secs": 1_780_000_000,
                 "last_updated_at_unix_secs": 1_789_000_000, "type": "llm", "entity_type": "test"],
                ["id": "test_sim02", "name": "Impatient caller reschedules", "created_at_unix_secs": 1_780_000_000,
                 "last_updated_at_unix_secs": 1_789_000_000, "type": "simulation", "entity_type": "test"],
            ], "has_more": false]
        case AgentsOp.getTest:
            return ["id": .string(testID), "name": "Refund request is escalated", "type": "llm",
                    "chat_history": [["role": "user", "message": "I want my money back for order 1042.", "time_in_call_secs": 0]],
                    "success_condition": "The agent offers to hand over to a person.",
                    "success_examples": [["response": "Let me get a colleague who can help with the refund.", "type": "success"]],
                    "failure_examples": [["response": "Refunds are not possible.", "type": "failure"]],
                    "dynamic_variables": [:], "created_at_unix_secs": 1_780_000_000]
        case AgentsOp.createTest:
            return ["id": "test_new03"]
        case AgentsOp.listInvocations:
            return ["results": [["id": "inv_1", "agent_id": .string(agentID), "created_at_unix_secs": 1_790_000_000,
                                 "test_run_count": 3, "passed_count": 2, "failed_count": 1, "pending_count": 0,
                                 "title": "Nightly regression", "repeat_count": 1]],
                    "has_more": false]
        case AgentsOp.getInvocation, AgentsOp.runTests:
            return ["id": "inv_1", "agent_id": .string(agentID), "created_at": 1_790_000_000, "repeat_count": 1,
                    "test_runs": [
                        ["test_run_id": "run_1", "test_invocation_id": "inv_1", "agent_id": .string(agentID),
                         "status": "passed", "test_id": .string(testID), "test_name": "Refund request is escalated",
                         "condition_result": ["result": "success", "rationale": ["summary": "Handed over politely."]]],
                        ["test_run_id": "run_2", "test_invocation_id": "inv_1", "agent_id": .string(agentID),
                         "status": "failed", "test_id": "test_sim02", "test_name": "test_sim02",
                         "condition_result": ["result": "failure", "rationale": ["summary": "Never confirmed the new day."]]],
                    ]]
        case AgentsOp.testSummaries:
            return ["tests": ["test_sim02": ["id": "test_sim02", "name": "Impatient caller reschedules"]]]
        case AgentsOp.simulate:
            return ["simulated_conversation": [["role": "agent", "message": "Hello! How can I help?", "time_in_call_secs": 0],
                                               ["role": "user", "message": "Move my delivery to Friday.", "time_in_call_secs": 3]],
                    "analysis": ["transcript_summary": "The caller moved a delivery.", "call_successful": "success"]]
        case AgentsOp.liveCount:
            return ["count": 3]
        case AgentsOp.agentTopics:
            return ["topics": [["topic_id": "t1", "label": "Delivery changes", "description": "Moving or cancelling deliveries",
                                "conversation_count": 120, "success_rate": 0.82],
                               ["topic_id": "t2", "label": "Refunds", "description": "Money back", "conversation_count": 44,
                                "success_rate": 0.41]],
                    "window_start_unix_secs": 1_789_000_000, "window_end_unix_secs": 1_790_000_000]
        case AgentsOp.llmCost, AgentsOp.agentLLMCost:
            return ["llm_prices": [["llm": "gemini-2.5-flash", "price_per_minute": 0.0021, "price_per_message": 0.0004],
                                   ["llm": "gpt-4o-mini", "price_per_minute": 0.0032, "price_per_message": 0.0006]]]
        case AgentsOp.listTickets, AgentsOp.listAgentTickets:
            return ["agent_conversation_tickets": [ticket], "has_more": false]
        case AgentsOp.getTicket:
            return ticket
        case AgentsOp.assignableUsers:
            return [["user_id": "user_a", "email": "alex@example.com", "first_name": "Alex", "is_service_account": false,
                     "has_access": true]]
        case "get_user_voices_v2":
            return ["voices": [["voice_id": "voice_calm", "name": "Calm narrator", "category": "premade",
                                "labels": ["accent": "british"]]], "has_more": false]
        default:
            return [:]
        }
    }

    // MARK: - Pieces

    static func agentSummary(_ id: String, _ name: String, tags: [String], lastCall: Int?) -> JSONValue {
        ["agent_id": .string(id), "name": .string(name), "voice_id": "voice_calm", "tags": .array(tags.map(JSONValue.string)),
         "created_at_unix_secs": 1_780_000_000, "access_info": access,
         "last_call_time_unix_secs": lastCall.map { .number(Double($0)) } ?? .null, "archived": false]
    }

    static let access: JSONValue = ["is_creator": true, "creator_name": "Alex", "creator_email": "alex@example.com", "role": "admin"]

    static let agent: JSONValue = [
        "agent_id": .string(agentID), "name": "Support", "tags": ["support", "english"],
        "version_id": "agtvrsn_7", "branch_id": "agtbrch_main", "main_branch_id": "agtbrch_main",
        "conversation_config": [
            "agent": [
                "first_message": "Hello! How can I help you today?", "language": "en",
                "prompt": ["prompt": "You are the support agent of Example Shop. Be brief and friendly.",
                           "llm": "gemini-2.5-flash", "temperature": 0.2, "max_tokens": -1,
                           "tool_ids": .array([.string(toolID)]), "mcp_server_ids": [],
                           "knowledge_base": [["id": .string(documentID), "name": "Opening hours", "type": "text", "usage_mode": "auto"]]],
            ],
            "tts": ["voice_id": "voice_calm", "model_id": "eleven_flash_v2_5", "stability": 0.5, "similarity_boost": 0.8, "speed": 1.0],
            "conversation": ["max_duration_seconds": 600],
        ],
        "platform_settings": [
            "call_limits": ["daily_limit": 100_000, "agent_concurrency_limit": -1],
            "auth": ["enable_auth": false, "shareable_token": "tok_fixture_shareable"],
        ],
        "workflow": ["edges": [:], "nodes": [:]],
        "metadata": ["created_at_unix_secs": 1_780_000_000],
    ]

    /// The agent with an inline webhook tool whose header value ElevenLabs masks for the app.
    static var agentWithInlineToolHeader: JSONValue {
        var value = agent
        value = AgentsJSON.setting(
            [["type": "webhook", "name": "crm_lookup", "description": "Looks up the caller",
              "api_schema": ["url": "https://crm.example.com/lookup", "method": "GET",
                             "request_headers": ["Authorization": "Bearer crm-fixture-token"]]]],
            at: "conversation_config.agent.prompt.tools", in: value
        )
        return value
    }

    static func conversationSummary(_ id: String, _ title: String, result: String, start: Int, duration: Int) -> JSONValue {
        ["agent_id": .string(agentID), "agent_name": "Support", "conversation_id": .string(id),
         "start_time_unix_secs": .number(Double(start)), "call_duration_secs": .number(Double(duration)), "message_count": 8,
         "status": "done", "call_successful": .string(result), "call_summary_title": .string(title), "tag_ids": []]
    }

    static let conversation: JSONValue = [
        "agent_id": .string(agentID), "agent_name": "Support", "status": "done", "conversation_id": .string(conversationID),
        "has_audio": true, "has_user_audio": true, "has_response_audio": true, "has_auxiliary_audio": false,
        "tag_ids": ["tag_refund"],
        "metadata": ["start_time_unix_secs": 1_790_000_000, "call_duration_secs": 184, "cost": 612,
                     "termination_reason": "The caller ended the call.", "main_language": "en",
                     "phone_call": ["direction": "inbound", "external_number": "+15550177", "type": "twilio"],
                     "feedback": ["likes": 1, "dislikes": 0]],
        "analysis": ["call_successful": "success", "transcript_summary": "The caller moved the delivery of order 1042 to Friday.",
                     "call_summary_title": "Order 1042 delivery moved",
                     "evaluation_criteria_results": ["resolved": ["criteria_id": "resolved", "result": "success",
                                                                  "rationale": "The new date was confirmed."]],
                     "data_collection_results": ["order_number": ["data_collection_id": "order_number", "value": "1042",
                                                                  "rationale": "Said at 0:12."]]],
        "transcript": [
            ["role": "agent", "message": "Hello! How can I help you today?", "time_in_call_secs": 0],
            ["role": "user", "message": "Could we move the delivery of order 1042 to Friday?", "time_in_call_secs": 4],
            ["role": "agent", "message": "Of course — Friday between 9 and 12 works. Shall I book it?", "time_in_call_secs": 9,
             "tool_calls": [["tool_name": "lookup_order"]]],
            ["role": "user", "message": "Yes please.", "time_in_call_secs": 14],
        ],
    ]

    static func document(_ id: String, _ name: String, type: String, size: Int, url: String? = nil) -> JSONValue {
        var value: [String: JSONValue] = [
            "id": .string(id), "name": .string(name), "type": .string(type),
            "metadata": ["created_at_unix_secs": 1_780_000_000, "last_updated_at_unix_secs": 1_789_000_000,
                         "size_bytes": .number(Double(size))],
            "supported_usages": ["auto", "prompt"], "access_info": access, "folder_path": [], "dependent_agents": type == "folder" ? [] : [["id": .string(agentID), "name": "Support"]],
        ]
        if let url { value["url"] = .string(url) }
        return .object(value)
    }

    static let tool: JSONValue = [
        "id": .string(toolID),
        "tool_config": ["type": "webhook", "name": "lookup_order", "description": "Finds an order by its number",
                        "response_timeout_secs": 20,
                        "api_schema": ["url": "https://api.example.com/orders/{order_id}", "method": "GET"]],
        "access_info": access, "usage_stats": ["total_calls": 1_204, "avg_latency_secs": 0.38],
    ]

    static func phoneNumber(_ id: String, _ number: String, _ label: String, provider: String, agent: (String, String)?) -> JSONValue {
        ["phone_number_id": .string(id), "phone_number": .string(number), "label": .string(label), "provider": .string(provider),
         "supports_inbound": true, "supports_outbound": true,
         "assigned_agent": agent.map { ["agent_id": .string($0.0), "agent_name": .string($0.1)] } ?? .null]
    }

    /// Two open proposals: mp_1 takes "Warmer tone" into Main, mp_2 takes Main into "Warmer tone".
    static func mergeProposal(_ id: String) -> JSONValue {
        let second = id == "mp_2"
        return ["id": .string(id), "agent_id": .string(agentID),
                "source_branch_id": second ? "agtbrch_main" : "agtbrch_tone",
                "target_branch_id": second ? "agtbrch_tone" : "agtbrch_main",
                "source_tip_version_id_at_creation": "agtvrsn_9",
                "title": second ? "Bring back the old greeting" : "Warmer greeting",
                "outcome": ["type": "open"], "created_at": 1_789_950_000, "updated_at": 1_789_950_000]
    }

    static func batch(_ id: String, _ name: String, status: String) -> JSONValue {
        ["id": .string(id), "phone_number_id": .string(phoneID), "phone_provider": "twilio", "whatsapp_params": nil,
         "name": .string(name), "agent_id": .string(agentID), "agent_name": "Support", "branch_id": nil, "environment": nil,
         "created_at_unix": 1_789_990_000, "scheduled_time_unix": 1_790_000_000, "timezone": nil,
         "total_calls_dispatched": 3, "total_calls_scheduled": 5, "total_calls_finished": 2, "last_updated_at_unix": 1_790_000_100,
         "status": .string(status), "retry_count": 0,
         "telephony_call_config": ["ringing_timeout_secs": 60, "twilio_call_recording_enabled": false],
         "target_concurrency_limit": nil]
    }

    static func recipient(_ id: String, _ number: String, _ status: String, conversation: String?) -> JSONValue {
        ["id": .string(id), "phone_number": .string(number), "status": .string(status), "created_at_unix": 1_790_000_000,
         "updated_at_unix": 1_790_000_100, "conversation_id": conversation.map(JSONValue.string) ?? .null]
    }

    static let mcpServer: JSONValue = [
        "id": .string(serverID),
        "config": ["name": "Order system", "url": "https://mcp.example.com/sse", "transport": "SSE",
                   "approval_policy": "require_approval_per_tool", "description": "Orders and refunds",
                   "response_timeout_secs": 30, "execution_mode": "immediate", "pre_tool_speech": "auto",
                   "interruption_mode": "allow", "secret_token": ["secret_id": .string(secretID)]],
        "dependent_agents": [["id": .string(agentID), "name": "Support"]],
        "metadata": ["created_at": 1_780_000_000],
    ]

    static func secret(_ id: String, _ name: String, tools: Int, agents: Int) -> JSONValue {
        ["type": "stored", "secret_id": .string(id), "name": .string(name),
         "used_by": ["tools": .array((0..<tools).map { ["id": .string("tool_\($0)"), "name": .string("Tool \($0 + 1)"),
                                                          "created_at_unix_secs": 1_780_000_000, "access_level": "admin"] }),
                     "agents": .array((0..<agents).map { _ in ["id": .string(agentID), "name": "Support"] }),
                     "phone_numbers": [], "mcp_servers": [], "others": []]]
    }

    static let ticket: JSONValue = [
        "agentqa_ticket_id": "tkt_1", "workspace_id": "ws", "owner_user_id": "user_a", "agent_id": .string(agentID),
        "needs_clustering": false, "issue_type": "knowledge_gap", "labels": [], "conversation_ids": ["conv_0002"],
        "qa_comment": "The agent did not know the refund window.", "ticket_comments": [["comment": "Adding the policy to the knowledge base.", "created_at_unix_secs": 1_790_000_000]],
        "turn_comments": [], "status": "in_progress", "source": "qa", "assignee_user_id": "user_a",
        "created_at_unix_secs": 1_789_990_000, "updated_at_unix_secs": 1_790_000_000,
    ]
}
