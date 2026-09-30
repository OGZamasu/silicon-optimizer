import Foundation
import SiliconElevenLabs

/// The operation ids the agents sections call, by name. Every one is checked against the
/// catalog by a test, so a spec refresh that renames one fails there.
enum AgentsOp {
    // Agents
    static let listAgents = "get_agents_route"
    static let agentSummaries = "get_agent_summaries_route"
    static let createAgent = "create_agent_route"
    static let getAgent = "get_agent_route"
    static let updateAgent = "patch_agent_settings_route"
    static let deleteAgent = "delete_agent_route"
    static let duplicateAgent = "duplicate_agent_route"
    static let agentWidget = "get_agent_widget_route"
    static let agentLink = "get_agent_link_route"
    static let agentAvatar = "post_agent_avatar_route"
    static let setHoldAudio = "post_agent_hold_audio_route"
    static let deleteHoldAudio = "delete_agent_hold_audio_route"
    static let listBranches = "get_branches_route"
    static let createBranch = "create_branch_route"
    static let getBranch = "get_branch_route"
    static let updateBranch = "update_branch_route"
    static let mergePreview = "merge_preview_route"
    static let mergeBranch = "merge_branch_into_target"
    static let rebasePreview = "rebase_preview_route"
    static let rebaseBranch = "rebase_branch_onto_main"
    static let versionMetadata = "get_version_metadata_route"
    static let createDraft = "create_agent_draft_route"
    static let deleteDraft = "delete_agent_draft_route"
    static let createDeployment = "create_agent_deployment_route"
    static let listMergeProposals = "list_merge_proposals_route"
    static let createMergeProposal = "create_merge_proposal_route"
    static let getMergeProposal = "get_merge_proposal_route"
    static let updateMergeProposal = "update_merge_proposal_route"
    static let commentMergeProposal = "add_merge_proposal_comment_route"
    static let reviewMergeProposal = "submit_merge_proposal_review_route"
    static let acceptMergeProposal = "accept_merge_proposal_route"
    static let listProcedures = "list_procedures_route"
    static let getProcedure = "get_procedure_route"
    static let createProcedure = "create_procedure_route"
    static let compileProcedures = "compile_procedures_route"
    static let getProcedureDraft = "get_procedure_draft_route"
    static let updateProcedureDraft = "update_procedure_draft_route"
    static let deleteProcedureDraft = "delete_procedure_draft_route"
    static let removeProcedure = "remove_procedure_route"
    static let listLLMs = "list_available_llms"
    static let getSettings = "get_settings_route"
    static let updateSettings = "update_settings_route"
    static let getDashboardSettings = "get_dashboard_settings_route"
    static let updateDashboardSettings = "update_dashboard_settings_route"

    // Conversations
    static let listConversations = "get_conversation_histories_route"
    static let getConversation = "get_conversation_history_route"
    static let conversationAudio = "get_conversation_audio_route"
    static let conversationFeedback = "post_conversation_feedback_route"
    static let deleteConversation = "delete_conversation_route"
    static let conversationSIPMessages = "get_conversation_sip_messages"
    static let runAnalysis = "run_conversation_analysis"
    static let runEvaluation = "run_conversation_evaluations"
    static let assignTags = "assign_conversation_tags_route"
    static let unassignTag = "unassign_conversation_tag_route"
    static let textSearch = "text_search_conversation_messages_route"
    static let smartSearch = "smart_search_conversation_messages_route"
    static let resolveReference = "resolve_conversation_reference_route"
    static let conversationUsers = "get_conversation_users_route"
    static let signedURL = "get_conversation_signed_link"
    static let webRTCToken = "get_livekit_token"

    // Knowledge base
    static let listDocuments = "get_knowledge_base_list_route"
    static let getDocument = "get_documentation_from_knowledge_base"
    static let documentContent = "get_knowledge_base_content"
    static let createURLDocument = "create_url_document_route"
    static let createTextDocument = "create_text_document_route"
    static let createFileDocument = "create_file_document_route"
    static let createFolder = "create_folder_route"
    static let updateDocument = "update_document_route"
    static let replaceDocumentFile = "update_file_document_route"
    static let refreshURLDocument = "refresh_url_document_route"
    static let deleteDocument = "delete_knowledge_base_document"
    static let moveDocument = "post_knowledge_base_move_route"
    static let bulkMoveDocuments = "post_knowledge_base_bulk_move_route"
    static let bulkDeleteDocuments = "post_knowledge_base_bulk_delete_route"
    static let documentDependents = "get_knowledge_base_dependent_agents"
    static let bulkDependents = "get_knowledge_base_bulk_dependent_agents_route"
    static let documentSummaries = "get_agent_knowledge_base_summaries_route"
    static let documentSourceURL = "get_knowledge_base_source_file_url"
    static let ragIndexes = "get_rag_indexes"
    static let computeRAGIndex = "rag_index_status"
    static let deleteRAGIndex = "delete_rag_index"
    static let ragOverview = "get_rag_index_overview"
    static let batchRAGIndexes = "get_or_create_rag_indexes"
    static let documentChunks = "get_documentation_chunks_from_knowledge_base"
    static let documentChunk = "get_documentation_chunk_from_knowledge_base"
    static let searchDocuments = "search_knowledge_base_content_route"
    static let createCrawl = "create_crawl_job_route"
    static let listCrawls = "list_crawl_jobs_route"
    static let getCrawl = "get_crawl_job_route"
    static let cancelCrawl = "cancel_crawl_job_route"
    static let agentKnowledgeSize = "get_agent_knowledge_base_size"
    static let ragQuery = "query_agent_knowledge_base_rag_route"

    // Tools
    static let listTools = "get_tools_route"
    static let getTool = "get_tool_route"
    static let createTool = "add_tool_route"
    static let updateTool = "update_tool_route"
    static let deleteTool = "delete_tool_route"
    static let toolDependents = "get_tool_dependent_agents_route"
    static let toolExecutions = "get_tool_executions_route"

    // Phone numbers, calls and messages
    static let listPhoneNumbers = "list_phone_numbers_page_route"
    static let getPhoneNumber = "get_phone_number_route"
    static let importPhoneNumber = "create_phone_number_route"
    static let updatePhoneNumber = "update_phone_number_route"
    static let deletePhoneNumber = "delete_phone_number_route"
    static let phoneSIPMessages = "list_sip_messages"
    static let twilioCall = "handle_twilio_outbound_call"
    static let exotelCall = "handle_exotel_outbound_call"
    static let sipTrunkCall = "handle_sip_trunk_outbound_call"
    static let whatsAppCall = "whatsapp_outbound_call"
    static let whatsAppMessage = "whatsapp_outbound_message"
    static let listWhatsAppAccounts = "list_whatsapp_accounts"
    static let getWhatsAppAccount = "get_whatsapp_account"
    static let updateWhatsAppAccount = "update_whatsapp_account"
    static let deleteWhatsAppAccount = "delete_whatsapp_account"

    // Batch calling
    static let submitBatch = "create_batch_call"
    static let listBatches = "get_workspace_batch_calls"
    static let getBatch = "get_batch_call"
    static let cancelBatch = "cancel_batch_call"
    static let retryBatch = "retry_batch_call"
    static let exportBatch = "export_batch_call"
    static let deleteBatch = "delete_batch_call"

    // MCP servers
    static let listMCPServers = "list_mcp_servers_route"
    static let getMCPServer = "get_mcp_route"
    static let createMCPServer = "create_mcp_server_route"
    static let updateMCPServer = "update_mcp_server_config_route"
    static let deleteMCPServer = "delete_mcp_server_route"
    static let listMCPTools = "list_mcp_server_tools_route"
    static let approveMCPTool = "add_mcp_server_tool_approval_route"
    static let removeMCPToolApproval = "remove_mcp_server_tool_approval_route"
    static let addMCPToolOverride = "add_mcp_tool_config_override_route"
    static let getMCPToolOverride = "get_mcp_tool_config_override_route"
    static let updateMCPToolOverride = "update_mcp_tool_config_override_route"
    static let removeMCPToolOverride = "remove_mcp_tool_config_override_route"

    // Secrets and environment variables
    static let listSecrets = "get_secrets_route"
    static let getSecret = "get_secret_route"
    static let createSecret = "create_secret_route"
    static let updateSecret = "update_secret_route"
    static let deleteSecret = "delete_secret_route"
    static let secretDependencies = "get_secret_dependencies_route"
    static let listEnvironmentVariables = "list_environment_variables"
    static let getEnvironmentVariable = "get_environment_variable"
    static let createEnvironmentVariable = "create_environment_variable"
    static let updateEnvironmentVariable = "update_environment_variable"

    // Testing
    static let listTests = "list_chat_response_tests_route"
    static let getTest = "get_agent_response_test_route"
    static let createTest = "create_agent_response_test_route"
    static let updateTest = "update_agent_response_test_route"
    static let deleteTest = "delete_chat_response_test_route"
    static let testSummaries = "get_agent_response_tests_summaries_route"
    static let createTestFolder = "create_agent_test_folder_route"
    static let getTestFolder = "get_agent_test_folder_route"
    static let renameTestFolder = "update_agent_test_folder_route"
    static let deleteTestFolder = "delete_agent_test_folder_route"
    static let moveTests = "agent_testing_bulk_move_route"
    static let runTests = "run_agent_test_suite_route"
    static let listInvocations = "list_test_invocations_route"
    static let getInvocation = "get_test_invocation_route"
    static let resubmitTests = "resubmit_tests_route"
    static let simulate = "run_conversation_simulation_route"
    static let simulateStream = "run_conversation_simulation_route_stream"

    // Analytics, tags and triage
    static let liveCount = "get_live_count"
    static let llmCost = "get_public_llm_expected_cost_calculation"
    static let agentLLMCost = "get_agent_llm_expected_cost_calculation"
    static let agentTopics = "get_agent_topics_route"
    static let listTags = "list_conversation_tags_route"
    static let getTag = "get_conversation_tag_route"
    static let createTag = "create_conversation_tag_route"
    static let updateTag = "update_conversation_tag_route"
    static let deleteTag = "delete_conversation_tag_route"
    static let listTickets = "list_workspace_conversation_tickets_route"
    static let listAgentTickets = "list_agent_conversation_tickets_route"
    static let getTicket = "get_agent_conversation_ticket_route"
    static let createTicket = "create_agent_conversation_ticket_route"
    static let createManualTicket = "create_manual_agent_ticket_route"
    static let updateTicket = "update_agent_conversation_ticket_route"
    static let deleteTicket = "delete_agent_conversation_ticket_route"
    static let commentTicket = "add_ticket_comment_route"
    static let commentTicketTurn = "add_turn_comment_route"
    static let assignableUsers = "get_assignable_users_route"

    /// Every operation the agents sections run natively, by name.
    static let native: [String] = [
        listAgents, agentSummaries, createAgent, getAgent, updateAgent, deleteAgent, duplicateAgent, agentWidget,
        agentLink, agentAvatar, setHoldAudio, deleteHoldAudio, listBranches, createBranch, getBranch, updateBranch,
        mergePreview, mergeBranch, rebasePreview, rebaseBranch, versionMetadata, createDraft, deleteDraft,
        createDeployment, listMergeProposals, createMergeProposal, getMergeProposal, updateMergeProposal,
        commentMergeProposal, reviewMergeProposal, acceptMergeProposal, listProcedures, getProcedure,
        createProcedure, compileProcedures, getProcedureDraft, updateProcedureDraft, deleteProcedureDraft,
        removeProcedure, listLLMs, getSettings, updateSettings, getDashboardSettings, updateDashboardSettings,
        listConversations, getConversation, conversationAudio, conversationFeedback,
        deleteConversation, conversationSIPMessages, runAnalysis, runEvaluation, assignTags, unassignTag,
        textSearch, smartSearch, resolveReference, conversationUsers, signedURL, webRTCToken, listDocuments,
        getDocument, documentContent, createURLDocument, createTextDocument, createFileDocument, createFolder,
        updateDocument, replaceDocumentFile, refreshURLDocument, deleteDocument, moveDocument, bulkMoveDocuments,
        bulkDeleteDocuments, documentDependents, bulkDependents, documentSummaries, documentSourceURL, ragIndexes,
        computeRAGIndex, deleteRAGIndex, ragOverview, batchRAGIndexes, documentChunks, documentChunk,
        searchDocuments, createCrawl, listCrawls, getCrawl, cancelCrawl, agentKnowledgeSize, ragQuery, listTools,
        getTool, createTool, updateTool, deleteTool, toolDependents, toolExecutions, listPhoneNumbers,
        getPhoneNumber, importPhoneNumber, updatePhoneNumber, deletePhoneNumber, phoneSIPMessages, twilioCall,
        exotelCall, sipTrunkCall, whatsAppCall, whatsAppMessage, listWhatsAppAccounts, getWhatsAppAccount,
        updateWhatsAppAccount, deleteWhatsAppAccount, submitBatch, listBatches, getBatch, cancelBatch, retryBatch,
        exportBatch, deleteBatch, listMCPServers, getMCPServer, createMCPServer, updateMCPServer, deleteMCPServer,
        listMCPTools, approveMCPTool, removeMCPToolApproval, addMCPToolOverride, getMCPToolOverride,
        updateMCPToolOverride, removeMCPToolOverride, listSecrets, getSecret, createSecret, updateSecret,
        deleteSecret, secretDependencies, listEnvironmentVariables, getEnvironmentVariable,
        createEnvironmentVariable, updateEnvironmentVariable, listTests, getTest, createTest, updateTest,
        deleteTest, testSummaries, createTestFolder, getTestFolder, renameTestFolder, deleteTestFolder, moveTests,
        runTests, listInvocations, getInvocation, resubmitTests, simulate, simulateStream, liveCount, llmCost,
        agentLLMCost, agentTopics, listTags, getTag, createTag, updateTag, deleteTag, listTickets,
        listAgentTickets, getTicket, createTicket, createManualTicket, updateTicket, deleteTicket, commentTicket,
        commentTicketTurn, assignableUsers
    ]

    /// The agents operations left to the Explorer, each with why: the Explorer runs every
    /// catalog operation with a generated form, so these still work, just without a screen.
    static let explorerOnly: [String: String] = [
        "get_signed_url_deprecated": "Deprecated duplicate of get_conversation_signed_link, which Conversations uses.",
        "add_documentation_to_knowledge_base": "Deprecated; the knowledge base adds pages, text and files through the newer create operations.",
        "update_mcp_server_approval_policy_route": "Deprecated; MCP servers change the approval policy through update_mcp_server_config_route.",
        "list_phone_numbers_route": "Superseded by the paged list_phone_numbers_page_route, which Phone numbers uses (same numbers, with search).",
        "get_conversation_summary_route": "A lighter copy of what the conversation detail already shows (title, summary, result, messages).",
        "upload_file_route": "Attaches a file to a conversation in progress; that belongs to the live conversation of the realtime wave.",
        "cancel_file_upload_route": "Removes a file attached to a conversation in progress; realtime wave, like upload_file_route.",
        "register_twilio_call": "Returns TwiML for the owner's own Twilio webhook server to connect a call it received; not a desktop action.",
    ]
}

// MARK: - Agents

struct AgentsAgent: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var voiceID: String?
    var tags: [String]
    var createdAt: Date?
    var lastCallAt: Date?
    var archived: Bool

    init(id: String, name: String, voiceID: String? = nil, tags: [String] = [], createdAt: Date? = nil,
         lastCallAt: Date? = nil, archived: Bool = false) {
        self.id = id
        self.name = name
        self.voiceID = voiceID
        self.tags = tags
        self.createdAt = createdAt
        self.lastCallAt = lastCallAt
        self.archived = archived
    }

    init?(json: JSONValue) {
        guard let id = json["agent_id"].stringValue else { return nil }
        self.init(
            id: id, name: json["name"].stringValue ?? id, voiceID: json["voice_id"].stringValue,
            tags: AgentsJSON.strings(json["tags"]), createdAt: AgentsJSON.date(json["created_at_unix_secs"]),
            lastCallAt: AgentsJSON.date(json["last_call_time_unix_secs"]),
            archived: json["archived"].boolValue ?? false
        )
    }
}

struct AgentsBranch: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var description: String
    var isArchived: Bool
    var isMain: Bool
    var protection: String?
    var lastCommittedAt: Date?
    var draftExists: Bool
    var commitsAhead: Int?
    var commitsBehind: Int?
    var calls7d: Int?
    var livePercentage: Double?

    init?(json: JSONValue, mainBranchID: String? = nil) {
        guard let id = json["id"].stringValue else { return nil }
        self.id = id
        name = json["name"].stringValue ?? id
        description = json["description"].stringValue ?? ""
        isArchived = json["is_archived"].boolValue ?? false
        isMain = id == mainBranchID || json["parent_branch_id"] == .null && name.lowercased() == "main"
        protection = json["protection_status"].stringValue
        lastCommittedAt = AgentsJSON.date(json["last_committed_at"])
        draftExists = json["draft_exists"].boolValue ?? false
        commitsAhead = json["commits_ahead"].intValue
        commitsBehind = json["commits_behind"].intValue
        calls7d = json["calls_7d"].intValue
        livePercentage = json["current_live_percentage"].doubleValue
    }
}

struct AgentsMergeProposal: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var description: String
    var sourceBranchID: String
    var targetBranchID: String
    var outcome: String
    var reviewCount: Int
    var commentCount: Int
    var createdAt: Date?

    init?(json: JSONValue) {
        guard let id = json["id"].stringValue else { return nil }
        self.id = id
        title = json["title"].stringValue ?? id
        description = json["description"].stringValue ?? ""
        sourceBranchID = json["source_branch_id"].stringValue ?? ""
        targetBranchID = json["target_branch_id"].stringValue ?? ""
        outcome = json["outcome"]["type"].stringValue ?? json["outcome"]["status"].stringValue ?? "open"
        reviewCount = json["reviews"].arrayValue?.count ?? 0
        commentCount = json["comments"].arrayValue?.count ?? 0
        createdAt = AgentsJSON.date(json["created_at"])
    }
}

/// A step-by-step procedure an agent follows, on one branch.
struct AgentsProcedure: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    /// free_form, deterministic or folder.
    var type: String
    var trigger: String
    var hasDraft: Bool

    init?(json: JSONValue) {
        guard let id = json["procedure_id"].stringValue else { return nil }
        self.id = id
        name = json["name"].stringValue ?? id
        type = json["type"].stringValue ?? "free_form"
        trigger = json["trigger"].stringValue ?? ""
        hasDraft = json["has_draft"].boolValue ?? false
    }
}

struct AgentsLLMInfo: Identifiable, Hashable, Sendable {
    var id: String { llm }
    var llm: String
    var maxContext: Int?
    var deprecated: Bool
    var supportsImages: Bool

    init?(json: JSONValue) {
        guard let llm = json["llm"].stringValue else { return nil }
        self.llm = llm
        maxContext = json["max_context_limit"].intValue
        deprecated = json["deprecation_info"] != .null
        supportsImages = json["supports_image_input"].boolValue ?? false
    }
}

// MARK: - Conversations

struct AgentsConversation: Identifiable, Hashable, Sendable {
    var id: String
    var agentID: String
    var agentName: String?
    var startedAt: Date?
    var durationSeconds: Int?
    var messageCount: Int?
    var status: String
    var callSuccessful: String?
    var title: String?
    var summary: String?
    var direction: String?
    var rating: Double?
    var tagIDs: [String]

    init(id: String, agentID: String, agentName: String? = nil, startedAt: Date? = nil,
         durationSeconds: Int? = nil, messageCount: Int? = nil, status: String = "done",
         callSuccessful: String? = nil, title: String? = nil, summary: String? = nil,
         direction: String? = nil, rating: Double? = nil, tagIDs: [String] = []) {
        self.id = id
        self.agentID = agentID
        self.agentName = agentName
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
        self.messageCount = messageCount
        self.status = status
        self.callSuccessful = callSuccessful
        self.title = title
        self.summary = summary
        self.direction = direction
        self.rating = rating
        self.tagIDs = tagIDs
    }

    init?(json: JSONValue) {
        guard let id = json["conversation_id"].stringValue else { return nil }
        self.init(
            id: id, agentID: json["agent_id"].stringValue ?? "", agentName: json["agent_name"].stringValue,
            startedAt: AgentsJSON.date(json["start_time_unix_secs"]),
            durationSeconds: json["call_duration_secs"].intValue, messageCount: json["message_count"].intValue,
            status: json["status"].stringValue ?? "unknown", callSuccessful: json["call_successful"].stringValue,
            title: json["call_summary_title"].stringValue, summary: json["transcript_summary"].stringValue,
            direction: json["direction"].stringValue, rating: json["rating"].doubleValue,
            tagIDs: AgentsJSON.strings(json["tag_ids"])
        )
    }
}

struct AgentsTranscriptTurn: Identifiable, Hashable, Sendable {
    var id: Int
    var role: String
    var message: String?
    var timeInCall: Int?
    var toolCalls: [String]
    var interrupted: Bool

    init(id: Int, role: String, message: String?, timeInCall: Int? = nil, toolCalls: [String] = [],
         interrupted: Bool = false) {
        self.id = id
        self.role = role
        self.message = message
        self.timeInCall = timeInCall
        self.toolCalls = toolCalls
        self.interrupted = interrupted
    }

    static func turns(_ value: JSONValue) -> [AgentsTranscriptTurn] {
        (value.arrayValue ?? []).enumerated().map { index, turn in
            AgentsTranscriptTurn(
                id: index, role: turn["role"].stringValue ?? "agent",
                message: turn["message"].stringValue ?? turn["original_message"].stringValue,
                timeInCall: turn["time_in_call_secs"].intValue,
                toolCalls: (turn["tool_calls"].arrayValue ?? []).compactMap { $0["tool_name"].stringValue },
                interrupted: turn["interrupted"].boolValue ?? false
            )
        }
    }
}

struct AgentsConversationDetail: Hashable, Sendable {
    struct Evaluation: Identifiable, Hashable, Sendable {
        var id: String
        var result: String
        var rationale: String
    }

    struct Collected: Identifiable, Hashable, Sendable {
        var id: String
        var value: String
        var rationale: String
    }

    var id: String
    var agentID: String
    var agentName: String?
    var status: String
    var startedAt: Date?
    var durationSeconds: Int?
    var cost: Int?
    var terminationReason: String?
    var title: String?
    var summary: String?
    var callSuccessful: String?
    var turns: [AgentsTranscriptTurn]
    var hasAudio: Bool
    var evaluations: [Evaluation]
    var collected: [Collected]
    var tagIDs: [String]
    var phoneCall: String?
    var batchCallID: String?
    var mainLanguage: String?
    var feedback: String?

    init?(json: JSONValue) {
        guard let id = json["conversation_id"].stringValue else { return nil }
        self.id = id
        agentID = json["agent_id"].stringValue ?? ""
        agentName = json["agent_name"].stringValue
        status = json["status"].stringValue ?? "unknown"
        let metadata = json["metadata"]
        startedAt = AgentsJSON.date(metadata["start_time_unix_secs"])
        durationSeconds = metadata["call_duration_secs"].intValue
        cost = metadata["cost"].intValue
        terminationReason = metadata["termination_reason"].stringValue
        mainLanguage = metadata["main_language"].stringValue
        let analysis = json["analysis"]
        title = analysis["call_summary_title"].stringValue
        summary = analysis["transcript_summary"].stringValue
        callSuccessful = analysis["call_successful"].stringValue
        turns = AgentsTranscriptTurn.turns(json["transcript"])
        hasAudio = json["has_audio"].boolValue ?? false
        evaluations = (analysis["evaluation_criteria_results"].objectValue ?? [:]).keys.sorted().map { key in
            let item = analysis["evaluation_criteria_results"][key]
            return Evaluation(
                id: item["criteria_id"].stringValue ?? key, result: item["result"].stringValue ?? "unknown",
                rationale: item["rationale"].stringValue ?? ""
            )
        }
        collected = (analysis["data_collection_results"].objectValue ?? [:]).keys.sorted().map { key in
            let item = analysis["data_collection_results"][key]
            let value = item["value"]
            return Collected(
                id: item["data_collection_id"].stringValue ?? key,
                value: value.stringValue ?? (value == .null ? "—" : value.jsonString()),
                rationale: item["rationale"].stringValue ?? ""
            )
        }
        tagIDs = AgentsJSON.strings(json["tag_ids"])
        let call = metadata["phone_call"]
        if call != .null {
            phoneCall = [call["direction"].stringValue, call["external_number"].stringValue, call["type"].stringValue]
                .compactMap { $0 }.joined(separator: " · ")
        }
        batchCallID = metadata["batch_call"]["batch_call_id"].stringValue
        let likes = metadata["feedback"]["likes"].intValue ?? 0
        let dislikes = metadata["feedback"]["dislikes"].intValue ?? 0
        feedback = likes > 0 ? "like" : dislikes > 0 ? "dislike" : nil
    }
}

// MARK: - Knowledge base

struct AgentsKnowledgeDocument: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    /// url, file, text or folder.
    var type: String
    var url: String?
    var sizeBytes: Int?
    var updatedAt: Date?
    var parentFolderID: String?
    var folderPath: [(id: String, name: String)]
    var dependentAgents: Int
    var autoSync: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.type == rhs.type && lhs.sizeBytes == rhs.sizeBytes
            && lhs.updatedAt == rhs.updatedAt && lhs.parentFolderID == rhs.parentFolderID
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    init(id: String, name: String, type: String, url: String? = nil, sizeBytes: Int? = nil,
         updatedAt: Date? = nil, parentFolderID: String? = nil, folderPath: [(id: String, name: String)] = [],
         dependentAgents: Int = 0, autoSync: Bool = false) {
        self.id = id
        self.name = name
        self.type = type
        self.url = url
        self.sizeBytes = sizeBytes
        self.updatedAt = updatedAt
        self.parentFolderID = parentFolderID
        self.folderPath = folderPath
        self.dependentAgents = dependentAgents
        self.autoSync = autoSync
    }

    init?(json: JSONValue) {
        guard let id = json["id"].stringValue else { return nil }
        self.init(
            id: id, name: json["name"].stringValue ?? id, type: json["type"].stringValue ?? "text",
            url: json["url"].stringValue, sizeBytes: json["metadata"]["size_bytes"].intValue,
            updatedAt: AgentsJSON.date(json["metadata"]["last_updated_at_unix_secs"]),
            parentFolderID: json["folder_parent_id"].stringValue,
            folderPath: (json["folder_path"].arrayValue ?? []).compactMap { segment in
                segment["id"].stringValue.map { ($0, segment["name"].stringValue ?? $0) }
            },
            dependentAgents: json["dependent_agents"].arrayValue?.count ?? 0,
            autoSync: json["auto_sync_info"] != .null
        )
    }

    var isFolder: Bool { type == "folder" }

    var typeName: String {
        switch type {
        case "url": "Web page"
        case "file": "File"
        case "text": "Text"
        case "folder": "Folder"
        default: AgentsFormat.words(type)
        }
    }

    var systemImage: String {
        switch type {
        case "folder": "folder"
        case "url": "link"
        case "file": "doc"
        default: "text.alignleft"
        }
    }
}

struct AgentsCrawlJob: Identifiable, Hashable, Sendable {
    var id: String
    var url: String
    var status: String
    var identified: Int
    var scraped: Int
    var failed: Int
    var createdAt: Date?

    init?(json: JSONValue) {
        guard let id = json["id"].stringValue else { return nil }
        self.id = id
        url = json["seed_url"].stringValue ?? ""
        status = json["status"].stringValue ?? "unknown"
        identified = json["pages_identified"].intValue ?? 0
        scraped = json["pages_scraped"].intValue ?? 0
        failed = json["pages_failed"].intValue ?? 0
        createdAt = AgentsJSON.date(json["created_at"])
    }
}

struct AgentsRAGIndex: Identifiable, Hashable, Sendable {
    var id: String
    var model: String
    var status: String
    var progress: Double
    var usedBytes: Int?

    init?(json: JSONValue) {
        guard let id = json["id"].stringValue else { return nil }
        self.id = id
        model = json["model"].stringValue ?? ""
        status = json["status"].stringValue ?? "unknown"
        progress = json["progress_percentage"].doubleValue ?? 0
        usedBytes = json["document_model_index_usage"]["used_bytes"].intValue
    }
}

struct AgentsChunk: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var content: String
    var score: Double?
}

// MARK: - Tools

struct AgentsTool: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    /// webhook, client, system, mcp, api_integration_webhook…
    var type: String
    var description: String
    var totalCalls: Int?
    var averageLatency: Double?
    var config: JSONValue

    init(id: String, name: String, type: String, description: String = "", totalCalls: Int? = nil,
         averageLatency: Double? = nil, config: JSONValue = .null) {
        self.id = id
        self.name = name
        self.type = type
        self.description = description
        self.totalCalls = totalCalls
        self.averageLatency = averageLatency
        self.config = config
    }

    init?(json: JSONValue) {
        guard let id = json["id"].stringValue else { return nil }
        let config = json["tool_config"]
        self.init(
            id: id, name: config["name"].stringValue ?? id, type: config["type"].stringValue ?? "webhook",
            description: config["description"].stringValue ?? "",
            totalCalls: json["usage_stats"]["total_calls"].intValue,
            averageLatency: json["usage_stats"]["avg_latency_secs"].doubleValue, config: config
        )
    }
}

struct AgentsToolExecution: Identifiable, Hashable, Sendable {
    var id: String
    var conversationID: String
    var agentID: String
    var at: Date?
    var latency: Double?
    var isError: Bool
    var error: String?

    init?(json: JSONValue) {
        guard let id = json["id"].stringValue ?? json["tool_request_id"].stringValue else { return nil }
        self.id = id
        conversationID = json["conversation_id"].stringValue ?? ""
        agentID = json["agent_id"].stringValue ?? ""
        at = AgentsJSON.date(json["timestamp"])
        latency = json["latency_secs"].doubleValue
        isError = json["is_error"].boolValue ?? false
        error = json["error_message"].stringValue
    }
}

// MARK: - Phone numbers

struct AgentsPhoneNumber: Identifiable, Hashable, Sendable {
    var id: String
    var number: String
    var label: String
    /// twilio, sip_trunk or exotel.
    var provider: String
    var supportsInbound: Bool
    var supportsOutbound: Bool
    var agentID: String?
    var agentName: String?

    init(id: String, number: String, label: String, provider: String, supportsInbound: Bool = true,
         supportsOutbound: Bool = true, agentID: String? = nil, agentName: String? = nil) {
        self.id = id
        self.number = number
        self.label = label
        self.provider = provider
        self.supportsInbound = supportsInbound
        self.supportsOutbound = supportsOutbound
        self.agentID = agentID
        self.agentName = agentName
    }

    init?(json: JSONValue) {
        guard let id = json["phone_number_id"].stringValue else { return nil }
        self.init(
            id: id, number: json["phone_number"].stringValue ?? "", label: json["label"].stringValue ?? "",
            provider: json["provider"].stringValue ?? "twilio",
            supportsInbound: json["supports_inbound"].boolValue ?? true,
            supportsOutbound: json["supports_outbound"].boolValue ?? true,
            agentID: json["assigned_agent"]["agent_id"].stringValue,
            agentName: json["assigned_agent"]["agent_name"].stringValue
        )
    }

    /// "Support line (+1 555 0100)".
    var displayName: String {
        label.isEmpty ? number : "\(label) (\(number))"
    }

    var providerName: String {
        switch provider {
        case "twilio": "Twilio"
        case "sip_trunk": "SIP trunk"
        case "exotel": "Exotel"
        default: AgentsFormat.words(provider)
        }
    }

    /// The operation that places an outbound call from this number.
    var outboundCallOperation: String {
        switch provider {
        case "sip_trunk": AgentsOp.sipTrunkCall
        case "exotel": AgentsOp.exotelCall
        default: AgentsOp.twilioCall
        }
    }
}

struct AgentsWhatsAppAccount: Identifiable, Hashable, Sendable {
    var id: String
    var number: String
    var name: String
    var businessName: String
    var agentID: String?
    var agentName: String?
    var messaging: Bool
    var audioReplies: Bool
    var typingIndicator: Bool
    var tokenExpired: Bool

    init?(json: JSONValue) {
        guard let id = json["phone_number_id"].stringValue else { return nil }
        self.id = id
        number = json["phone_number"].stringValue ?? ""
        name = json["phone_number_name"].stringValue ?? ""
        businessName = json["business_account_name"].stringValue ?? ""
        agentID = json["assigned_agent_id"].stringValue
        agentName = json["assigned_agent_name"].stringValue
        messaging = json["enable_messaging"].boolValue ?? false
        audioReplies = json["enable_audio_message_response"].boolValue ?? false
        typingIndicator = json["enable_typing_indicator"].boolValue ?? false
        tokenExpired = json["is_token_expired"].boolValue ?? false
    }
}

// MARK: - Batch calls

struct AgentsBatchCall: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var agentID: String
    var agentName: String
    var phoneNumberID: String?
    var provider: String?
    var status: String
    var createdAt: Date?
    var scheduledAt: Date?
    var dispatched: Int
    var scheduled: Int
    var finished: Int
    var retryCount: Int
    var isWhatsApp: Bool

    init(id: String, name: String, agentID: String, agentName: String, phoneNumberID: String? = nil,
         provider: String? = nil, status: String, createdAt: Date? = nil, scheduledAt: Date? = nil,
         dispatched: Int = 0, scheduled: Int = 0, finished: Int = 0, retryCount: Int = 0, isWhatsApp: Bool = false) {
        self.id = id
        self.name = name
        self.agentID = agentID
        self.agentName = agentName
        self.phoneNumberID = phoneNumberID
        self.provider = provider
        self.status = status
        self.createdAt = createdAt
        self.scheduledAt = scheduledAt
        self.dispatched = dispatched
        self.scheduled = scheduled
        self.finished = finished
        self.retryCount = retryCount
        self.isWhatsApp = isWhatsApp
    }

    init?(json: JSONValue) {
        guard let id = json["id"].stringValue else { return nil }
        self.init(
            id: id, name: json["name"].stringValue ?? id, agentID: json["agent_id"].stringValue ?? "",
            agentName: json["agent_name"].stringValue ?? "", phoneNumberID: json["phone_number_id"].stringValue,
            provider: json["phone_provider"].stringValue, status: json["status"].stringValue ?? "pending",
            createdAt: AgentsJSON.date(json["created_at_unix"]), scheduledAt: AgentsJSON.date(json["scheduled_time_unix"]),
            dispatched: json["total_calls_dispatched"].intValue ?? 0,
            scheduled: json["total_calls_scheduled"].intValue ?? 0,
            finished: json["total_calls_finished"].intValue ?? 0, retryCount: json["retry_count"].intValue ?? 0,
            isWhatsApp: json["whatsapp_params"] != .null
        )
    }

    /// Whether the batch is still placing calls: what Cancel is for.
    var isActive: Bool { status == "pending" || status == "in_progress" }
}

struct AgentsBatchRecipient: Identifiable, Hashable, Sendable {
    var id: String
    var phoneNumber: String?
    var whatsAppUserID: String?
    var status: String
    var conversationID: String?
    var updatedAt: Date?

    init?(json: JSONValue) {
        guard let id = json["id"].stringValue else { return nil }
        self.id = id
        phoneNumber = json["phone_number"].stringValue
        whatsAppUserID = json["whatsapp_user_id"].stringValue
        status = json["status"].stringValue ?? "pending"
        conversationID = json["conversation_id"].stringValue
        updatedAt = AgentsJSON.date(json["updated_at_unix"])
    }

    /// The statuses Retry calls again: "failed and no-response recipients".
    var isRetryable: Bool { status == "failed" || status == "voicemail" }
}

// MARK: - MCP servers

struct AgentsMCPServer: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var url: String
    var transport: String
    var approvalPolicy: String
    var description: String
    var dependentAgents: Int
    var config: JSONValue

    init(id: String, name: String, url: String, transport: String = "SSE",
         approvalPolicy: String = "require_approval_all", description: String = "", dependentAgents: Int = 0,
         config: JSONValue = .null) {
        self.id = id
        self.name = name
        self.url = url
        self.transport = transport
        self.approvalPolicy = approvalPolicy
        self.description = description
        self.dependentAgents = dependentAgents
        self.config = config
    }

    init?(json: JSONValue) {
        guard let id = json["id"].stringValue else { return nil }
        let config = json["config"]
        let url = config["url"].stringValue ?? config["url"]["secret_id"].stringValue.map { "secret \($0)" } ?? ""
        self.init(
            id: id, name: config["name"].stringValue ?? id, url: url,
            transport: config["transport"].stringValue ?? "SSE",
            approvalPolicy: config["approval_policy"].stringValue ?? "require_approval_all",
            description: config["description"].stringValue ?? "",
            dependentAgents: json["dependent_agents"].arrayValue?.count ?? 0, config: config
        )
    }
}

struct AgentsMCPTool: Identifiable, Hashable, Sendable {
    var id: String { name }
    var name: String
    var description: String
    var inputSchema: JSONValue
    /// The approval state ElevenLabs reports for it, when per-tool approval applies.
    var approval: String?
}

// MARK: - Secrets and environment variables

struct AgentsSecret: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var type: String
    var usedByTools: Int
    var usedByAgents: Int
    var usedByPhoneNumbers: Int
    var usedByMCPServers: Int

    init(id: String, name: String, type: String = "stored", usedByTools: Int = 0, usedByAgents: Int = 0,
         usedByPhoneNumbers: Int = 0, usedByMCPServers: Int = 0) {
        self.id = id
        self.name = name
        self.type = type
        self.usedByTools = usedByTools
        self.usedByAgents = usedByAgents
        self.usedByPhoneNumbers = usedByPhoneNumbers
        self.usedByMCPServers = usedByMCPServers
    }

    init?(json: JSONValue) {
        guard let id = json["secret_id"].stringValue else { return nil }
        let used = json["used_by"]
        self.init(
            id: id, name: json["name"].stringValue ?? id, type: json["type"].stringValue ?? "stored",
            usedByTools: used["tools"].arrayValue?.count ?? 0, usedByAgents: used["agents"].arrayValue?.count ?? 0,
            usedByPhoneNumbers: used["phone_numbers"].arrayValue?.count ?? 0,
            usedByMCPServers: used["mcp_servers"].arrayValue?.count ?? 0
        )
    }

    var usageCount: Int { usedByTools + usedByAgents + usedByPhoneNumbers + usedByMCPServers }

    /// "Used by 2 tools and 1 agent", or "Not used".
    var usageSummary: String {
        let parts = [
            usedByTools > 0 ? AgentsFormat.count(usedByTools, "tool") : nil,
            usedByAgents > 0 ? AgentsFormat.count(usedByAgents, "agent") : nil,
            usedByPhoneNumbers > 0 ? AgentsFormat.count(usedByPhoneNumbers, "phone number") : nil,
            usedByMCPServers > 0 ? AgentsFormat.count(usedByMCPServers, "MCP server") : nil,
        ].compactMap { $0 }
        return parts.isEmpty ? "Not used" : "Used by " + ListFormatter.localizedString(byJoining: parts)
    }
}

struct AgentsEnvironmentVariable: Identifiable, Hashable, Sendable {
    var id: String
    var label: String
    /// string, secret or auth_connection.
    var type: String
    /// Environment name → what it holds, as shown (a secret's id, never a value).
    var values: [String: String]
    var updatedAt: Date?

    init?(json: JSONValue) {
        guard let id = json["id"].stringValue else { return nil }
        self.id = id
        label = json["label"].stringValue ?? id
        type = json["type"].stringValue ?? "string"
        var values: [String: String] = [:]
        for (environment, value) in json["values"].objectValue ?? [:] {
            values[environment] = value.stringValue ?? value["secret_id"].stringValue.map { "secret \($0)" }
                ?? value["auth_connection_id"].stringValue.map { "connection \($0)" } ?? value.jsonString()
        }
        self.values = values
        updatedAt = AgentsJSON.date(json["updated_at_unix_secs"])
    }
}

// MARK: - Testing

struct AgentsTest: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    /// llm, tool, simulation — or folder.
    var type: String
    var isFolder: Bool
    var parentFolderID: String?
    var childrenCount: Int?
    var updatedAt: Date?

    init(id: String, name: String, type: String, isFolder: Bool = false, parentFolderID: String? = nil,
         childrenCount: Int? = nil, updatedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.type = type
        self.isFolder = isFolder
        self.parentFolderID = parentFolderID
        self.childrenCount = childrenCount
        self.updatedAt = updatedAt
    }

    init?(json: JSONValue) {
        guard let id = json["id"].stringValue else { return nil }
        let type = json["type"].stringValue ?? "llm"
        self.init(
            id: id, name: json["name"].stringValue ?? id, type: type,
            isFolder: json["entity_type"].stringValue == "folder" || type == "folder",
            parentFolderID: json["folder_parent_id"].stringValue, childrenCount: json["children_count"].intValue,
            updatedAt: AgentsJSON.date(json["last_updated_at_unix_secs"])
        )
    }

    var typeName: String {
        switch type {
        case "llm": "Response"
        case "tool": "Tool call"
        case "simulation": "Simulation"
        case "folder": "Folder"
        default: AgentsFormat.words(type)
        }
    }
}

struct AgentsTestInvocation: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var agentID: String?
    var createdAt: Date?
    var runCount: Int
    var passed: Int
    var failed: Int
    var pending: Int

    init?(json: JSONValue) {
        guard let id = json["id"].stringValue else { return nil }
        self.id = id
        title = json["title"].stringValue ?? id
        agentID = json["agent_id"].stringValue
        createdAt = AgentsJSON.date(json["created_at_unix_secs"] != .null ? json["created_at_unix_secs"] : json["created_at"])
        runCount = json["test_run_count"].intValue ?? (json["test_runs"].arrayValue?.count ?? 0)
        passed = json["passed_count"].intValue ?? 0
        failed = json["failed_count"].intValue ?? 0
        pending = json["pending_count"].intValue ?? 0
    }
}

struct AgentsTestRun: Identifiable, Hashable, Sendable {
    var id: String
    var testID: String
    var testName: String
    var status: String
    var result: String?
    var rationale: String?

    init?(json: JSONValue) {
        guard let id = json["test_run_id"].stringValue else { return nil }
        self.id = id
        testID = json["test_id"].stringValue ?? ""
        testName = json["test_name"].stringValue ?? testID
        status = json["status"].stringValue ?? "pending"
        result = json["condition_result"]["result"].stringValue
        rationale = json["condition_result"]["rationale"]["summary"].stringValue
            ?? json["condition_result"]["rationale"].stringValue
    }
}

// MARK: - Analytics

struct AgentsTag: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var description: String

    init(id: String, title: String, description: String = "") {
        self.id = id
        self.title = title
        self.description = description
    }

    init?(json: JSONValue) {
        guard let id = json["tag_id"].stringValue else { return nil }
        self.init(id: id, title: json["title"].stringValue ?? id, description: json["description"].stringValue ?? "")
    }
}

struct AgentsTicket: Identifiable, Hashable, Sendable {
    var id: String
    var agentID: String
    var status: String
    var source: String
    var issueType: String?
    var comment: String
    var conversationIDs: [String]
    var assigneeID: String?
    var createdAt: Date?
    var comments: [(comment: String, at: Date?)]
    var turnComments: [(turn: Int, comment: String)]

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.status == rhs.status && lhs.assigneeID == rhs.assigneeID
            && lhs.comments.count == rhs.comments.count && lhs.turnComments.count == rhs.turnComments.count
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    init?(json: JSONValue) {
        guard let id = json["agentqa_ticket_id"].stringValue else { return nil }
        self.id = id
        agentID = json["agent_id"].stringValue ?? ""
        status = json["status"].stringValue ?? "open"
        source = json["source"].stringValue ?? "manual"
        issueType = json["issue_type"].stringValue
        comment = json["qa_comment"].stringValue ?? ""
        conversationIDs = AgentsJSON.strings(json["conversation_ids"])
        assigneeID = json["assignee_user_id"].stringValue
        createdAt = AgentsJSON.date(json["created_at_unix_secs"])
        comments = (json["ticket_comments"].arrayValue ?? []).map {
            ($0["comment"].stringValue ?? "", AgentsJSON.date($0["created_at_unix_secs"]))
        }
        turnComments = (json["turn_comments"].arrayValue ?? []).map {
            ($0["turn_index"].intValue ?? 0, $0["comment"].stringValue ?? "")
        }
    }
}

struct AgentsTopic: Identifiable, Hashable, Sendable {
    var id: String
    var label: String
    var description: String
    var conversations: Int
    var successRate: Double?
    var parentID: String?

    init?(json: JSONValue) {
        guard let id = json["topic_id"].stringValue else { return nil }
        self.id = id
        label = json["label"].stringValue ?? id
        description = json["description"].stringValue ?? ""
        conversations = json["conversation_count"].intValue ?? 0
        successRate = json["success_rate"].doubleValue
        parentID = json["parent_topic_id"].stringValue
    }
}

struct AgentsLLMPrice: Identifiable, Hashable, Sendable {
    var id: String { llm }
    var llm: String
    var perMinute: Double
    var perMessage: Double

    init?(json: JSONValue) {
        guard let llm = json["llm"].stringValue else { return nil }
        self.llm = llm
        perMinute = json["price_per_minute"].doubleValue ?? 0
        perMessage = json["price_per_message"].doubleValue ?? 0
    }
}

struct AgentsWorkspaceUser: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var hasAccess: Bool

    init?(json: JSONValue) {
        guard let id = json["user_id"].stringValue else { return nil }
        self.id = id
        name = json["first_name"].stringValue ?? json["email"].stringValue ?? id
        hasAccess = json["has_access"].boolValue ?? false
    }
}
