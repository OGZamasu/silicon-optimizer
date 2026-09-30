import Foundation

/// The reviewed policy for every ElevenLabs operation: its risk class, whether it spends
/// credits, and whether its answer carries a credential.
///
/// One entry per operation in the pinned spec, by `operationId`, in five explicit lists. A
/// spec refresh that adds an operation lands it nowhere here, and `risk(for:)` then falls back
/// to `defaultRisk(method:path:)`: a read for GET, real-world for anything inside the families
/// below, and **destructive for every other unknown non-GET** — so a refresh fails safe
/// until someone reviews the new operation and lists it.
///
/// The families are the paths whose non-GET operations reach outside the account or change
/// who can get into it. Every non-GET inside one is `realWorld`, including its DELETEs and
/// cancellations; every other DELETE is `destructive`. `ElevenLabsRiskTableTests` holds the
/// table to those rules and to the exact list of real-world operations.
enum ElevenLabsRiskTable {

    /// Path patterns whose non-GET operations are all `realWorld`.
    static let realWorldFamilies: [String] = [
        #"^/v1/convai/(twilio|exotel|whatsapp|sip-trunk)/"#,   // outbound calls and messages
        #"^/v1/convai/batch-calling/"#,                         // submit/retry place real calls
        #"^/v1/convai/(v2/)?phone-numbers(/|$)"#,
        #"^/v1/convai/whatsapp-accounts(/|$)"#,
        #"^/v1/convai/secrets(/|$)"#,
        #"^/v1/convai/mcp-servers(/|$)"#,                      // connects agents to outside tools
        #"^/v1/convai/settings(/|$)"#,
        #"^/v1/workspace/(invites|members|groups|webhooks|auth-connections|resources)(/|$)"#,
        #"^/v1/service-accounts(/|$)"#,                        // including their API keys
        #"^/v1/workspaces/api-keys/"#,
    ]

    private static let familyExpressions = realWorldFamilies.map { try! NSRegularExpression(pattern: $0) }

    static func isInRealWorldFamily(_ path: String) -> Bool {
        familyExpressions.contains {
            $0.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil
        }
    }

    /// The class of an operation this table has never seen.
    static func defaultRisk(method: String, path: String) -> ElevenLabsRisk {
        if method.uppercased() == "GET" { return .read }
        if isInRealWorldFamily(path) { return .realWorld }
        return .destructive
    }

    static func risk(for id: String, method: String, path: String) -> ElevenLabsRisk {
        table[id] ?? defaultRisk(method: method, path: path)
    }

    /// Spends credits or money. Every `generate` operation, plus the real-world ones that
    /// bill by the minute or the order.
    static func isBillable(_ id: String, risk: ElevenLabsRisk) -> Bool {
        risk == .generate || billableBeyondGenerate.contains(id)
    }

    static func returnsCredential(_ id: String) -> Bool { credentialFields[id] != nil }

    /// Operations whose answer carries a credential, and the fields that hold it — found by
    /// walking every 2xx response schema in the spec for keys, secrets, tokens and signed
    /// conversation URLs. Signed *download* URLs for the owner's own files (Studio assets,
    /// knowledge-base sources, Productions deliverables) are not credentials to the account
    /// and are not listed.
    static let credentialFields: [String: [String]] = [
        "create_service_account_api_key": ["xi-api-key"],        // a new API key
        "create_workspace_webhook_route": ["webhook_secret"],     // the webhook signing secret
        "get_single_use_token": ["token"],                        // a 15-minute key for clients
        "get_conversation_signed_link": ["signed_url"],           // starts a billed conversation
        "get_signed_url_deprecated": ["signed_url"],
        "get_livekit_token": ["token"],
        "get_agent_link_route": ["conversation_token"],
        // An agent's `platform_settings.auth.shareable_token` lets anyone holding it start a
        // conversation with that agent.
        "get_agent_route": ["shareable_token"],
        "patch_agent_settings_route": ["shareable_token"],
        "merge_preview_route": ["shareable_token"],
        "rebase_preview_route": ["shareable_token"],
    ]

    /// Fields redacted from every answer, credential-bearing or not.
    static let alwaysRedactedFields: Set<String> = [
        "xi_api_key_preview",   // GET /v1/user: a preview of the key in use
    ]

    /// Real-world operations that bill: calls by the minute, and a submitted Productions order.
    static let billableBeyondGenerate: Set<String> = [
        "handle_twilio_outbound_call", "register_twilio_call", "handle_exotel_outbound_call",
        "whatsapp_outbound_call", "whatsapp_outbound_message", "handle_sip_trunk_outbound_call",
        "create_batch_call", "retry_batch_call", "public_submit_order",
    ]

    static let table: [String: ElevenLabsRisk] = {
        var table: [String: ElevenLabsRisk] = [:]
        for (risk, ids) in [(ElevenLabsRisk.read, read), (.generate, generate), (.modify, modify),
                            (.destructive, destructive), (.realWorld, realWorld)] {
            for id in ids { table[id] = risk }
        }
        return table
    }()

    /// Reads. Every GET, and the POSTs that only compute or download what already exists (usage
    /// queries, cost estimates, summaries, RAG retrieval, similar-voice search, history and Studio
    /// snapshot downloads).
    static let read: [String] = [
        "get_speech_history",  // GET /v1/history
        "get_speech_history_item_by_id",  // GET /v1/history/{history_item_id}
        "get_audio_full_from_speech_history_item",  // GET /v1/history/{history_item_id}/audio
        "download_speech_history_items",  // POST /v1/history/download
        "get_audio_isolation_history",  // GET /v1/audio-isolation/history
        "get_audio_from_sample",  // GET /v1/voices/{voice_id}/samples/{sample_id}/audio
        "text_to_voice_preview_stream",  // GET /v1/text-to-voice/{generated_voice_id}/stream
        "get_user_info",  // GET /v1/user
        "get_user_subscription_info",  // GET /v1/user/subscription
        "get_voice_settings_default",  // GET /v1/voices/settings/default
        "get_voice_settings",  // GET /v1/voices/{voice_id}/settings
        "get_voice_accents",  // GET /v1/voices/accents
        "get_voices",  // GET /v1/voices
        "get_voice_by_id",  // GET /v1/voices/{voice_id}
        "get_user_voices_v2",  // GET /v2/voices
        "get_projects",  // GET /v1/studio/projects
        "get_project_by_id",  // GET /v1/studio/projects/{project_id}
        "get_project_snapshots",  // GET /v1/studio/projects/{project_id}/snapshots
        "get_project_snapshot_endpoint",  // GET /v1/studio/projects/{project_id}/snapshots/{project_snapshot_id}
        "stream_project_snapshot_audio_endpoint",  // POST /v1/studio/projects/{project_id}/snapshots/{project_snapshot_id}/stream
        "stream_project_snapshot_archive_endpoint",  // POST /v1/studio/projects/{project_id}/snapshots/{project_snapshot_id}/archive
        "get_chapters",  // GET /v1/studio/projects/{project_id}/chapters
        "get_chapter_by_id_endpoint",  // GET /v1/studio/projects/{project_id}/chapters/{chapter_id}
        "get_chapter_snapshots",  // GET /v1/studio/projects/{project_id}/chapters/{chapter_id}/snapshots
        "get_chapter_snapshot_endpoint",  // GET /v1/studio/projects/{project_id}/chapters/{chapter_id}/snapshots/{chapter_snapshot_id}
        "stream_chapter_snapshot_audio",  // POST /v1/studio/projects/{project_id}/chapters/{chapter_id}/snapshots/{chapter_snapshot_id}/stream
        "get_project_muted_tracks_endpoint",  // GET /v1/studio/projects/{project_id}/muted-tracks
        "dubbing_project_list",  // GET /v1/dubbing/project
        "dubbing_project_get",  // GET /v1/dubbing/project/{project_id}
        "dubbing_language_list",  // GET /v1/dubbing/project/{project_id}/language
        "dubbing_language_get",  // GET /v1/dubbing/project/{project_id}/language/{language_id}
        "dubbing_transcript_get",  // GET /v1/dubbing/project/{project_id}/transcript
        "dubbing_target_transcript_get",  // GET /v1/dubbing/project/{project_id}/language/{language_id}/transcript
        "get_dubbing_resource",  // GET /v1/dubbing/resource/{dubbing_id}
        "get_similar_voices_for_speaker",  // GET /v1/dubbing/resource/{dubbing_id}/speaker/{speaker_id}/similar-voices
        "list_dubs",  // GET /v1/dubbing
        "get_dubbed_metadata",  // GET /v1/dubbing/{dubbing_id}
        "get_dubbed_file",  // GET /v1/dubbing/{dubbing_id}/audio/{language_code}
        "get_dubbed_transcript_file",  // GET /v1/dubbing/{dubbing_id}/transcript/{language_code}
        "get_dubbing_transcripts",  // GET /v1/dubbing/{dubbing_id}/transcripts/{language_code}/format/{format_type}
        "get_models",  // GET /v1/models
        "get_audio_native_project_settings_endpoint",  // GET /v1/audio-native/{project_id}/settings
        "get_similar_library_voices",  // POST /v1/similar-voices
        "get_library_voices",  // GET /v1/shared-voices
        "usage_characters",  // GET /v1/usage/character-stats
        "get_pronunciation_dictionary_metadata",  // GET /v1/pronunciation-dictionaries/{pronunciation_dictionary_id}
        "get_pronunciation_dictionary_version_pls",  // GET /v1/pronunciation-dictionaries/{dictionary_id}/{version_id}/download
        "get_pronunciation_dictionaries_metadata",  // GET /v1/pronunciation-dictionaries
        "get_service_account_api_keys_route",  // GET /v1/service-accounts/{service_account_user_id}/api-keys
        "get_workspace_audit_logs",  // GET /v1/workspace/audit-logs
        "list_auth_connections",  // GET /v1/workspace/auth-connections
        "get_workspace_service_accounts",  // GET /v1/service-accounts
        "get_groups_endpoint",  // GET /v1/workspace/groups
        "search_groups",  // GET /v1/workspace/groups/search
        "get_workspace_members",  // GET /v1/workspace/members
        "get_resource_metadata",  // GET /v1/workspace/resources/{resource_id}
        "get_workspace_webhooks_route",  // GET /v1/workspace/webhooks
        "get_transcript_by_id",  // GET /v1/speech-to-text/transcripts/{transcription_id}
        "get_conversation_signed_link",  // GET /v1/convai/conversation/get-signed-url
        "get_signed_url_deprecated",  // GET /v1/convai/conversation/get_signed_url
        "get_livekit_token",  // GET /v1/convai/conversation/token
        "get_agent_summaries_route",  // GET /v1/convai/agents/summaries
        "get_agent_route",  // GET /v1/convai/agents/{agent_id}
        "get_agent_widget_route",  // GET /v1/convai/agents/{agent_id}/widget
        "get_agent_link_route",  // GET /v1/convai/agents/{agent_id}/link
        "get_agents_route",  // GET /v1/convai/agents
        "get_agent_knowledge_base_size",  // GET /v1/convai/agent/{agent_id}/knowledge-base/size
        "get_agent_llm_expected_cost_calculation",  // POST /v1/convai/agent/{agent_id}/llm-usage/calculate
        "get_agent_test_folder_route",  // GET /v1/convai/agent-testing/folders/{folder_id}
        "get_agent_response_test_route",  // GET /v1/convai/agent-testing/{test_id}
        "get_agent_response_tests_summaries_route",  // POST /v1/convai/agent-testing/summaries
        "list_chat_response_tests_route",  // GET /v1/convai/agent-testing
        "list_test_invocations_route",  // GET /v1/convai/test-invocations
        "get_test_invocation_route",  // GET /v1/convai/test-invocations/{test_invocation_id}
        "get_conversation_histories_route",  // GET /v1/convai/conversations
        "get_conversation_users_route",  // GET /v1/convai/users
        "resolve_conversation_reference_route",  // GET /v1/convai/conversations/resolve
        "get_conversation_history_route",  // GET /v1/convai/conversations/{conversation_id}
        "get_conversation_summary_route",  // GET /v1/convai/conversations/{conversation_id}/summary
        "get_conversation_sip_messages",  // GET /v1/convai/conversations/{conversation_id}/sip-messages
        "get_conversation_audio_route",  // GET /v1/convai/conversations/{conversation_id}/audio
        "text_search_conversation_messages_route",  // GET /v1/convai/conversations/messages/text-search
        "smart_search_conversation_messages_route",  // GET /v1/convai/conversations/messages/smart-search
        "list_conversation_tags_route",  // GET /v1/convai/tags
        "get_conversation_tag_route",  // GET /v1/convai/tags/{tag_id}
        "list_agent_conversation_tickets_route",  // GET /v1/convai/agents/{agent_id}/triage-tickets
        "list_workspace_conversation_tickets_route",  // GET /v1/convai/triage-tickets
        "get_assignable_users_route",  // GET /v1/convai/agents/{agent_id}/triage-tickets/assignable-users
        "get_agent_conversation_ticket_route",  // GET /v1/convai/triage-tickets/{agentqa_ticket_id}
        "list_phone_numbers_route",  // GET /v1/convai/phone-numbers
        "get_phone_number_route",  // GET /v1/convai/phone-numbers/{phone_number_id}
        "list_phone_numbers_page_route",  // GET /v1/convai/v2/phone-numbers
        "list_sip_messages",  // GET /v1/convai/phone-numbers/{phone_number_id}/sip-messages
        "get_public_llm_expected_cost_calculation",  // POST /v1/convai/llm-usage/calculate
        "list_available_llms",  // GET /v1/convai/llm/list
        "get_live_count",  // GET /v1/convai/analytics/live-count
        "get_agent_knowledge_base_summaries_route",  // GET /v1/convai/knowledge-base/summaries
        "get_knowledge_base_list_route",  // GET /v1/convai/knowledge-base
        "list_crawl_jobs_route",  // GET /v1/convai/knowledge-base/crawl
        "get_crawl_job_route",  // GET /v1/convai/knowledge-base/crawl/{crawl_job_id}
        "get_documentation_from_knowledge_base",  // GET /v1/convai/knowledge-base/{documentation_id}
        "get_rag_index_overview",  // GET /v1/convai/knowledge-base/rag-index
        "get_rag_indexes",  // GET /v1/convai/knowledge-base/{documentation_id}/rag-index
        "search_knowledge_base_content_route",  // GET /v1/convai/knowledge-base/search
        "query_agent_knowledge_base_rag_route",  // POST /v1/convai/agents/{agent_id}/knowledge-base/rag-query
        "get_knowledge_base_dependent_agents",  // GET /v1/convai/knowledge-base/{documentation_id}/dependent-agents
        "get_knowledge_base_bulk_dependent_agents_route",  // POST /v1/convai/knowledge-base/dependent-agents
        "get_knowledge_base_content",  // GET /v1/convai/knowledge-base/{documentation_id}/content
        "get_knowledge_base_source_file_url",  // GET /v1/convai/knowledge-base/{documentation_id}/source-file-url
        "get_documentation_chunk_from_knowledge_base",  // GET /v1/convai/knowledge-base/{documentation_id}/chunk/{chunk_id}
        "get_documentation_chunks_from_knowledge_base",  // GET /v1/convai/knowledge-base/{documentation_id}/chunks
        "get_agent_topics_route",  // GET /v1/convai/agents/{agent_id}/topics
        "get_tools_route",  // GET /v1/convai/tools
        "get_tool_route",  // GET /v1/convai/tools/{tool_id}
        "get_tool_dependent_agents_route",  // GET /v1/convai/tools/{tool_id}/dependent-agents
        "get_tool_executions_route",  // GET /v1/convai/tools/{tool_id}/executions
        "get_settings_route",  // GET /v1/convai/settings
        "get_dashboard_settings_route",  // GET /v1/convai/settings/dashboard
        "get_secrets_route",  // GET /v1/convai/secrets
        "get_secret_route",  // GET /v1/convai/secrets/{secret_id}
        "get_secret_dependencies_route",  // GET /v1/convai/secrets/{secret_id}/dependencies/{resource_type}
        "get_workspace_batch_calls",  // GET /v1/convai/batch-calling/workspace
        "get_batch_call",  // GET /v1/convai/batch-calling/{batch_id}
        "export_batch_call",  // GET /v1/convai/batch-calling/{batch_id}/export
        "list_mcp_servers_route",  // GET /v1/convai/mcp-servers
        "get_mcp_route",  // GET /v1/convai/mcp-servers/{mcp_server_id}
        "list_mcp_server_tools_route",  // GET /v1/convai/mcp-servers/{mcp_server_id}/tools
        "get_mcp_tool_config_override_route",  // GET /v1/convai/mcp-servers/{mcp_server_id}/tool-configs/{tool_name}
        "get_whatsapp_account",  // GET /v1/convai/whatsapp-accounts/{phone_number_id}
        "list_whatsapp_accounts",  // GET /v1/convai/whatsapp-accounts
        "get_branches_route",  // GET /v1/convai/agents/{agent_id}/branches
        "get_branch_route",  // GET /v1/convai/agents/{agent_id}/branches/{branch_id}
        "get_version_metadata_route",  // GET /v1/convai/agents/{agent_id}/versions/{version_id}
        "merge_preview_route",  // GET /v1/convai/agents/{agent_id}/branches/{source_branch_id}/merge-preview
        "rebase_preview_route",  // GET /v1/convai/agents/{agent_id}/branches/{branch_id}/rebase-preview
        "list_merge_proposals_route",  // GET /v1/convai/agents/{agent_id}/merge-proposals
        "get_merge_proposal_route",  // GET /v1/convai/agents/{agent_id}/merge-proposals/{merge_proposal_id}
        "list_speech_engines",  // GET /v1/speech-engine
        "get_speech_engine",  // GET /v1/speech-engine/{speech_engine_id}
        "list_procedures_route",  // GET /v1/convai/agents/{agent_id}/branches/{branch_id}/procedures
        "get_procedure_route",  // GET /v1/convai/agents/{agent_id}/branches/{branch_id}/procedures/{procedure_id}
        "get_procedure_draft_route",  // GET /v1/convai/agents/{agent_id}/branches/{branch_id}/procedures/{procedure_id}/draft
        "list_environment_variables",  // GET /v1/convai/environment-variables
        "get_environment_variable",  // GET /v1/convai/environment-variables/{env_var_id}
        "get_finetunes",  // GET /v1/music/finetunes
        "get_finetune",  // GET /v1/music/finetunes/{finetune_id}
        "public_list_orders",  // GET /v1/productions/orders
        "public_get_order",  // GET /v1/productions/orders/{order_id}
        "public_get_media_info",  // GET /v1/productions/orders/{order_id}/media/{media_id}
        "public_get_order_deliverables",  // GET /v1/productions/orders/{order_id}/deliverables
        "public_get_available_languages",  // GET /v1/productions/orders/languages/{order_item_kind}
        "get_pvc_sample_audio",  // GET /v1/voices/pvc/{voice_id}/samples/{sample_id}/audio
        "get_pvc_sample_visual_waveform",  // GET /v1/voices/pvc/{voice_id}/samples/{sample_id}/waveform
        "get_pvc_sample_speakers",  // GET /v1/voices/pvc/{voice_id}/samples/{sample_id}/speakers
        "get_speaker_audio",  // GET /v1/voices/pvc/{voice_id}/samples/{sample_id}/speakers/{speaker_id}/audio
        "get_pvc_voice_captcha",  // GET /v1/voices/pvc/{voice_id}/captcha
        "list_video_generations",  // GET /v1/flows/video
        "get_video_generation",  // GET /v1/flows/video/{generation_id}
        "list_image_generations",  // GET /v1/flows/image
        "get_image_generation",  // GET /v1/flows/image/{generation_id}
        "list_text_to_speech_generations",  // GET /v1/flows/text-to-speech
        "get_text_to_speech_generation",  // GET /v1/flows/text-to-speech/{generation_id}
        "list_public_template_runs",  // GET /v1/flows/templates/{template_id}/runs
        "get_public_template_run",  // GET /v1/flows/templates/{template_id}/runs/{run_id}
        "list_public_templates",  // GET /v1/flows/templates
        "get_public_template",  // GET /v1/flows/templates/{template_id}
        "list_assets",  // GET /v1/assets
        "get_asset",  // GET /v1/assets/{asset_id}
        "usage_by_product_over_time",  // POST /v1/workspace/analytics/query/usage-by-product-over-time
        "requests_list",  // POST /v1/workspace/analytics/requests
        "redirect_to_mintlify",  // GET /docs
    ]

    /// Billable creation: speech, dialogue, voice changer, sound effects, music (plan, compose,
    /// stems, upload, finetunes), isolation, transcription, alignment, voice design and remix,
    /// dubbing, Studio and Audio Native conversion, Flows generations, agent simulations, test runs
    /// and conversation analysis.
    static let generate: [String] = [
        "sound_generation",  // POST /v1/sound-generation
        "audio_isolation",  // POST /v1/audio-isolation
        "audio_isolation_stream",  // POST /v1/audio-isolation/stream
        "text_to_speech_full",  // POST /v1/text-to-speech/{voice_id}
        "text_to_speech_full_with_timestamps",  // POST /v1/text-to-speech/{voice_id}/with-timestamps
        "text_to_speech_stream",  // POST /v1/text-to-speech/{voice_id}/stream
        "text_to_speech_stream_with_timestamps",  // POST /v1/text-to-speech/{voice_id}/stream/with-timestamps
        "text_to_dialogue",  // POST /v1/text-to-dialogue
        "text_to_dialogue_stream",  // POST /v1/text-to-dialogue/stream
        "text_to_dialogue_stream_with_timestamps",  // POST /v1/text-to-dialogue/stream/with-timestamps
        "text_to_dialogue_full_with_timestamps",  // POST /v1/text-to-dialogue/with-timestamps
        "speech_to_speech_full",  // POST /v1/speech-to-speech/{voice_id}
        "speech_to_speech_stream",  // POST /v1/speech-to-speech/{voice_id}/stream
        "text_to_voice",  // POST /v1/text-to-voice/create-previews
        "text_to_voice_design",  // POST /v1/text-to-voice/design
        "text_to_voice_remix",  // POST /v1/text-to-voice/{voice_id}/remix
        "create_podcast",  // POST /v1/studio/podcasts
        "convert_project_endpoint",  // POST /v1/studio/projects/{project_id}/convert
        "convert_chapter_endpoint",  // POST /v1/studio/projects/{project_id}/chapters/{chapter_id}/convert
        "dubbing_project_create",  // POST /v1/dubbing/project
        "dubbing_language_create",  // POST /v1/dubbing/project/{project_id}/language
        "dubbing_target_transcript_regenerate",  // POST /v1/dubbing/project/{project_id}/language/{language_id}/transcript/regenerate
        "add_language",  // POST /v1/dubbing/resource/{dubbing_id}/language
        "transcribe",  // POST /v1/dubbing/resource/{dubbing_id}/transcribe
        "translate",  // POST /v1/dubbing/resource/{dubbing_id}/translate
        "dub",  // POST /v1/dubbing/resource/{dubbing_id}/dub
        "render",  // POST /v1/dubbing/resource/{dubbing_id}/render/{language}
        "create_dubbing",  // POST /v1/dubbing
        "create_audio_native_project",  // POST /v1/audio-native
        "audio_native_project_update_content_endpoint",  // POST /v1/audio-native/{project_id}/content
        "audio_native_update_content_from_url",  // POST /v1/audio-native/content
        "video_to_music",  // POST /v1/music/video-to-music
        "speech_to_text",  // POST /v1/speech-to-text
        "forced_alignment",  // POST /v1/forced-alignment
        "run_conversation_simulation_route",  // POST /v1/convai/agents/{agent_id}/simulate-conversation
        "run_conversation_simulation_route_stream",  // POST /v1/convai/agents/{agent_id}/simulate-conversation/stream
        "run_agent_test_suite_route",  // POST /v1/convai/agents/{agent_id}/run-tests
        "resubmit_tests_route",  // POST /v1/convai/test-invocations/{test_invocation_id}/resubmit
        "run_conversation_analysis",  // POST /v1/convai/conversations/{conversation_id}/analysis/run
        "run_conversation_evaluations",  // POST /v1/convai/conversations/{conversation_id}/analysis/evaluations/run
        "compose_plan",  // POST /v1/music/plan
        "generate",  // POST /v1/music
        "compose_detailed",  // POST /v1/music/detailed
        "compose_detailed_stream",  // POST /v1/music/detailed/stream
        "stream_compose",  // POST /v1/music/stream
        "upload_song",  // POST /v1/music/upload
        "separate_song_stems",  // POST /v1/music/stem-separation
        "create_finetune",  // POST /v1/music/finetunes
        "create_video_generation",  // POST /v1/flows/video
        "create_image_generation",  // POST /v1/flows/image
        "create_text_to_speech_generation",  // POST /v1/flows/text-to-speech
        "create_public_template_run",  // POST /v1/flows/templates/{template_id}/runs
    ]

    /// Edits and creations within the owner's own resources that cost nothing by themselves: voices
    /// and their settings, Studio projects and chapters, dubbing transcripts, pronunciation
    /// dictionaries, agents, branches, drafts, deployments, procedures, tests, tags, tickets,
    /// knowledge base documents, tools, environment variables, speech engines, Productions orders
    /// before submission, PVC voices, samples and training, assets.
    static let modify: [String] = [
        "create_voice",  // POST /v1/text-to-voice
        "edit_voice_settings",  // POST /v1/voices/{voice_id}/settings/edit
        "edit_voice",  // POST /v1/voices/{voice_id}/edit
        "add_voice",  // POST /v1/voices/add
        "add_sharing_voice",  // POST /v1/voices/add/{public_user_id}/{voice_id}
        "update_pronunciation_dictionaries",  // POST /v1/studio/projects/{project_id}/pronunciation-dictionaries
        "add_project",  // POST /v1/studio/projects
        "edit_project",  // POST /v1/studio/projects/{project_id}
        "edit_project_content",  // POST /v1/studio/projects/{project_id}/content
        "add_chapter",  // POST /v1/studio/projects/{project_id}/chapters
        "edit_chapter",  // POST /v1/studio/projects/{project_id}/chapters/{chapter_id}
        "dubbing_transcript_segment_update",  // PATCH /v1/dubbing/project/{project_id}/transcript/segment/{segment_id}
        "dubbing_transcript_segments_update",  // PATCH /v1/dubbing/project/{project_id}/transcript/segments
        "dubbing_transcript_segment_add",  // POST /v1/dubbing/project/{project_id}/transcript/segment
        "dubbing_target_transcript_segment_update",  // PATCH /v1/dubbing/project/{project_id}/language/{language_id}/transcript/segment/{segment_id}
        "dubbing_target_transcript_segments_update",  // PATCH /v1/dubbing/project/{project_id}/language/{language_id}/transcript/segments
        "create_clip",  // POST /v1/dubbing/resource/{dubbing_id}/speaker/{speaker_id}/segment
        "update_segment_language",  // PATCH /v1/dubbing/resource/{dubbing_id}/segment/{segment_id}/{language}
        "migrate_segments",  // POST /v1/dubbing/resource/{dubbing_id}/migrate-segments
        "update_speaker",  // PATCH /v1/dubbing/resource/{dubbing_id}/speaker/{speaker_id}
        "create_speaker",  // POST /v1/dubbing/resource/{dubbing_id}/speaker
        "add_from_file",  // POST /v1/pronunciation-dictionaries/add-from-file
        "add_from_rules",  // POST /v1/pronunciation-dictionaries/add-from-rules
        "patch_pronunciation_dictionary",  // PATCH /v1/pronunciation-dictionaries/{pronunciation_dictionary_id}
        "set_rules",  // POST /v1/pronunciation-dictionaries/{pronunciation_dictionary_id}/set-rules
        "add_rules",  // POST /v1/pronunciation-dictionaries/{pronunciation_dictionary_id}/add-rules
        "remove_rules",  // POST /v1/pronunciation-dictionaries/{pronunciation_dictionary_id}/remove-rules
        "create_agent_route",  // POST /v1/convai/agents/create
        "patch_agent_settings_route",  // PATCH /v1/convai/agents/{agent_id}
        "post_agent_avatar_route",  // POST /v1/convai/agents/{agent_id}/avatar
        "post_agent_hold_audio_route",  // POST /v1/convai/agents/{agent_id}/hold-audio
        "duplicate_agent_route",  // POST /v1/convai/agents/{agent_id}/duplicate
        "create_agent_response_test_route",  // POST /v1/convai/agent-testing/create
        "create_agent_test_folder_route",  // POST /v1/convai/agent-testing/folders
        "update_agent_test_folder_route",  // PATCH /v1/convai/agent-testing/folders/{folder_id}
        "agent_testing_bulk_move_route",  // POST /v1/convai/agent-testing/bulk-move
        "update_agent_response_test_route",  // PUT /v1/convai/agent-testing/{test_id}
        "post_conversation_feedback_route",  // POST /v1/convai/conversations/{conversation_id}/feedback
        "assign_conversation_tags_route",  // POST /v1/convai/conversations/{conversation_id}/tags
        "create_conversation_tag_route",  // POST /v1/convai/tags
        "update_conversation_tag_route",  // PATCH /v1/convai/tags/{tag_id}
        "create_manual_agent_ticket_route",  // POST /v1/convai/agents/{agent_id}/triage-tickets
        "create_agent_conversation_ticket_route",  // POST /v1/convai/triage-tickets
        "update_agent_conversation_ticket_route",  // PATCH /v1/convai/triage-tickets/{agentqa_ticket_id}
        "add_ticket_comment_route",  // POST /v1/convai/triage-tickets/{agentqa_ticket_id}/comments
        "add_turn_comment_route",  // POST /v1/convai/triage-tickets/{agentqa_ticket_id}/turn-comments
        "upload_file_route",  // POST /v1/convai/conversations/{conversation_id}/files
        "add_documentation_to_knowledge_base",  // POST /v1/convai/knowledge-base
        "create_url_document_route",  // POST /v1/convai/knowledge-base/url
        "create_crawl_job_route",  // POST /v1/convai/knowledge-base/crawl
        "create_file_document_route",  // POST /v1/convai/knowledge-base/file
        "create_text_document_route",  // POST /v1/convai/knowledge-base/text
        "create_folder_route",  // POST /v1/convai/knowledge-base/folder
        "update_document_route",  // PATCH /v1/convai/knowledge-base/{documentation_id}
        "update_file_document_route",  // PATCH /v1/convai/knowledge-base/{documentation_id}/update-file
        "get_or_create_rag_indexes",  // POST /v1/convai/knowledge-base/rag-index
        "refresh_url_document_route",  // POST /v1/convai/knowledge-base/{documentation_id}/refresh
        "rag_index_status",  // POST /v1/convai/knowledge-base/{documentation_id}/rag-index
        "post_knowledge_base_move_route",  // POST /v1/convai/knowledge-base/{document_id}/move
        "post_knowledge_base_bulk_move_route",  // POST /v1/convai/knowledge-base/bulk-move
        "create_branch_route",  // POST /v1/convai/agents/{agent_id}/branches
        "update_branch_route",  // PATCH /v1/convai/agents/{agent_id}/branches/{branch_id}
        "merge_branch_into_target",  // POST /v1/convai/agents/{agent_id}/branches/{source_branch_id}/merge
        "rebase_branch_onto_main",  // POST /v1/convai/agents/{agent_id}/branches/{branch_id}/rebase
        "create_agent_deployment_route",  // POST /v1/convai/agents/{agent_id}/deployments
        "create_agent_draft_route",  // POST /v1/convai/agents/{agent_id}/drafts
        "create_merge_proposal_route",  // POST /v1/convai/agents/{agent_id}/merge-proposals
        "update_merge_proposal_route",  // PATCH /v1/convai/agents/{agent_id}/merge-proposals/{merge_proposal_id}
        "submit_merge_proposal_review_route",  // POST /v1/convai/agents/{agent_id}/merge-proposals/{merge_proposal_id}/reviews
        "add_merge_proposal_comment_route",  // POST /v1/convai/agents/{agent_id}/merge-proposals/{merge_proposal_id}/comments
        "accept_merge_proposal_route",  // POST /v1/convai/agents/{agent_id}/merge-proposals/{merge_proposal_id}/merge
        "create_procedure_route",  // POST /v1/convai/agents/{agent_id}/branches/{branch_id}/procedures
        "compile_procedures_route",  // POST /v1/convai/agents/{agent_id}/branches/{branch_id}/procedures/compile
        "update_procedure_draft_route",  // PATCH /v1/convai/agents/{agent_id}/branches/{branch_id}/procedures/{procedure_id}/draft
        "update_finetune",  // PATCH /v1/music/finetunes/{finetune_id}
        "public_create_order",  // POST /v1/productions/orders
        "public_update_order",  // PATCH /v1/productions/orders/{order_id}
        "public_register_media",  // POST /v1/productions/orders/{order_id}/media
        "public_upsert_order_item",  // POST /v1/productions/orders/{order_id}/items
        "create_pvc_voice",  // POST /v1/voices/pvc
        "edit_pvc_voice",  // POST /v1/voices/pvc/{voice_id}
        "add_pvc_voice_samples",  // POST /v1/voices/pvc/{voice_id}/samples
        "edit_pvc_voice_sample",  // POST /v1/voices/pvc/{voice_id}/samples/{sample_id}
        "start_speaker_separation",  // POST /v1/voices/pvc/{voice_id}/samples/{sample_id}/separate-speakers
        "verify_pvc_voice_captcha",  // POST /v1/voices/pvc/{voice_id}/captcha
        "run_pvc_voice_training",  // POST /v1/voices/pvc/{voice_id}/train
        "request_pvc_manual_verification",  // POST /v1/voices/pvc/{voice_id}/verification
        "upload_asset",  // POST /v1/assets
    ]

    /// Deletes (every DELETE outside the real-world families), the one bulk delete sent as a
    /// POST, and cancelling a knowledge-base crawl, which removes every document the crawl made.
    static let destructive: [String] = [
        "delete_speech_history_item",  // DELETE /v1/history/{history_item_id}
        "delete_audio_isolation_history_item",  // DELETE /v1/audio-isolation/history/{history_item_id}
        "delete_sample",  // DELETE /v1/voices/{voice_id}/samples/{sample_id}
        "delete_voice",  // DELETE /v1/voices/{voice_id}
        "delete_project",  // DELETE /v1/studio/projects/{project_id}
        "delete_chapter_endpoint",  // DELETE /v1/studio/projects/{project_id}/chapters/{chapter_id}
        "dubbing_project_delete",  // DELETE /v1/dubbing/project/{project_id}
        "dubbing_language_delete",  // DELETE /v1/dubbing/project/{project_id}/language/{language_id}
        "dubbing_transcript_segment_delete",  // DELETE /v1/dubbing/project/{project_id}/transcript/segment/{segment_id}
        "delete_segment",  // DELETE /v1/dubbing/resource/{dubbing_id}/segment/{segment_id}
        "delete_dubbing",  // DELETE /v1/dubbing/{dubbing_id}
        "delete_transcript_by_id",  // DELETE /v1/speech-to-text/transcripts/{transcription_id}
        "delete_agent_route",  // DELETE /v1/convai/agents/{agent_id}
        "delete_agent_hold_audio_route",  // DELETE /v1/convai/agents/{agent_id}/hold-audio
        "delete_agent_test_folder_route",  // DELETE /v1/convai/agent-testing/folders/{folder_id}
        "delete_chat_response_test_route",  // DELETE /v1/convai/agent-testing/{test_id}
        "delete_conversation_route",  // DELETE /v1/convai/conversations/{conversation_id}
        "unassign_conversation_tag_route",  // DELETE /v1/convai/conversations/{conversation_id}/tags/{tag_id}
        "delete_conversation_tag_route",  // DELETE /v1/convai/tags/{tag_id}
        "delete_agent_conversation_ticket_route",  // DELETE /v1/convai/triage-tickets/{agentqa_ticket_id}
        "cancel_file_upload_route",  // DELETE /v1/convai/conversations/{conversation_id}/files/{file_id}
        "delete_knowledge_base_document",  // DELETE /v1/convai/knowledge-base/{documentation_id}
        "delete_rag_index",  // DELETE /v1/convai/knowledge-base/{documentation_id}/rag-index/{rag_index_id}
        "post_knowledge_base_bulk_delete_route",  // POST /v1/convai/knowledge-base/bulk-delete
        "delete_tool_route",  // DELETE /v1/convai/tools/{tool_id}
        "delete_agent_draft_route",  // DELETE /v1/convai/agents/{agent_id}/drafts
        "delete_speech_engine",  // DELETE /v1/speech-engine/{speech_engine_id}
        "remove_procedure_route",  // DELETE /v1/convai/agents/{agent_id}/branches/{branch_id}/procedures/{procedure_id}
        "delete_procedure_draft_route",  // DELETE /v1/convai/agents/{agent_id}/branches/{branch_id}/procedures/{procedure_id}/draft
        "delete_finetune",  // DELETE /v1/music/finetunes/{finetune_id}
        "public_remove_order_item",  // DELETE /v1/productions/orders/{order_id}/items/{item_id}
        "delete_pvc_voice_sample",  // DELETE /v1/voices/pvc/{voice_id}/samples/{sample_id}
        "delete_asset_endpoint",  // DELETE /v1/assets/{asset_id}
        "cancel_crawl_job_route",  // POST /v1/convai/knowledge-base/crawl/{crawl_job_id}/cancel
    ]

    /// Reaches outside the account, or hands out or changes access to it: outbound calls and
    /// messages (Twilio, Exotel, WhatsApp, SIP trunk), batch calling, phone numbers and WhatsApp
    /// accounts, secrets, MCP servers, Agents Platform workspace settings, workspace invites,
    /// members, groups, webhooks, auth connections and resource sharing, service accounts and API
    /// keys (including disabling the key in use), agent tools and environment variables (a webhook
    /// tool points an agent at an outside URL with headers, exactly as an MCP server does), speech
    /// engines (they send ElevenLabs to an outside WebSocket URL with the owner's headers),
    /// single-use tokens, replicating a voice to another
    /// data-residency workspace, and submitting a Productions order (which charges the workspace).
    static let realWorld: [String] = [
        "replicate_voice_to_isolated_environment",  // POST /v1/voices/{voice_id}/replicate-to-isolated-environment
        "disable",  // POST /v1/workspaces/api-keys/disable
        "set_third_party_disabling_policy",  // POST /v1/workspaces/api-keys/third-party-disabling
        "create_service_account_api_key",  // POST /v1/service-accounts/{service_account_user_id}/api-keys
        "edit_service_account_api_key",  // PATCH /v1/service-accounts/{service_account_user_id}/api-keys/{api_key_id}
        "delete_service_account_api_key",  // DELETE /v1/service-accounts/{service_account_user_id}/api-keys/{api_key_id}
        "create_auth_connection",  // POST /v1/workspace/auth-connections
        "update_auth_connection",  // PATCH /v1/workspace/auth-connections/{auth_connection_id}
        "delete_auth_connection",  // DELETE /v1/workspace/auth-connections/{auth_connection_id}
        "create_service_account",  // POST /v1/service-accounts
        "remove_member",  // POST /v1/workspace/groups/{group_id}/members/remove
        "add_member",  // POST /v1/workspace/groups/{group_id}/members
        "invite_user",  // POST /v1/workspace/invites/add
        "invite_users_bulk",  // POST /v1/workspace/invites/add-bulk
        "delete_invite",  // DELETE /v1/workspace/invites
        "update_workspace_member",  // POST /v1/workspace/members
        "share_resource_endpoint",  // POST /v1/workspace/resources/{resource_id}/share
        "unshare_resource_endpoint",  // POST /v1/workspace/resources/{resource_id}/unshare
        "create_workspace_webhook_route",  // POST /v1/workspace/webhooks
        "edit_workspace_webhook_route",  // PATCH /v1/workspace/webhooks/{webhook_id}
        "delete_workspace_webhook_route",  // DELETE /v1/workspace/webhooks/{webhook_id}
        "get_single_use_token",  // POST /v1/single-use-token/{token_type}
        "handle_twilio_outbound_call",  // POST /v1/convai/twilio/outbound-call
        "register_twilio_call",  // POST /v1/convai/twilio/register-call
        "handle_exotel_outbound_call",  // POST /v1/convai/exotel/outbound-call
        "whatsapp_outbound_call",  // POST /v1/convai/whatsapp/outbound-call
        "whatsapp_outbound_message",  // POST /v1/convai/whatsapp/outbound-message
        "create_phone_number_route",  // POST /v1/convai/phone-numbers
        "delete_phone_number_route",  // DELETE /v1/convai/phone-numbers/{phone_number_id}
        "update_phone_number_route",  // PATCH /v1/convai/phone-numbers/{phone_number_id}
        "update_settings_route",  // PATCH /v1/convai/settings
        "update_dashboard_settings_route",  // PATCH /v1/convai/settings/dashboard
        "create_secret_route",  // POST /v1/convai/secrets
        "delete_secret_route",  // DELETE /v1/convai/secrets/{secret_id}
        "update_secret_route",  // PATCH /v1/convai/secrets/{secret_id}
        "create_batch_call",  // POST /v1/convai/batch-calling/submit
        "delete_batch_call",  // DELETE /v1/convai/batch-calling/{batch_id}
        "cancel_batch_call",  // POST /v1/convai/batch-calling/{batch_id}/cancel
        "retry_batch_call",  // POST /v1/convai/batch-calling/{batch_id}/retry
        "handle_sip_trunk_outbound_call",  // POST /v1/convai/sip-trunk/outbound-call
        "create_mcp_server_route",  // POST /v1/convai/mcp-servers
        "delete_mcp_server_route",  // DELETE /v1/convai/mcp-servers/{mcp_server_id}
        "update_mcp_server_config_route",  // PATCH /v1/convai/mcp-servers/{mcp_server_id}
        "update_mcp_server_approval_policy_route",  // PATCH /v1/convai/mcp-servers/{mcp_server_id}/approval-policy
        "add_mcp_server_tool_approval_route",  // POST /v1/convai/mcp-servers/{mcp_server_id}/tool-approvals
        "remove_mcp_server_tool_approval_route",  // DELETE /v1/convai/mcp-servers/{mcp_server_id}/tool-approvals/{tool_name}
        "add_mcp_tool_config_override_route",  // POST /v1/convai/mcp-servers/{mcp_server_id}/tool-configs
        "update_mcp_tool_config_override_route",  // PATCH /v1/convai/mcp-servers/{mcp_server_id}/tool-configs/{tool_name}
        "remove_mcp_tool_config_override_route",  // DELETE /v1/convai/mcp-servers/{mcp_server_id}/tool-configs/{tool_name}
        "update_whatsapp_account",  // PATCH /v1/convai/whatsapp-accounts/{phone_number_id}
        "delete_whatsapp_account",  // DELETE /v1/convai/whatsapp-accounts/{phone_number_id}
        "public_submit_order",  // POST /v1/productions/orders/{order_id}/submit
        "create_speech_engine",  // POST /v1/speech-engine
        "update_speech_engine",  // PATCH /v1/speech-engine/{speech_engine_id}
        "add_tool_route",  // POST /v1/convai/tools
        "update_tool_route",  // PATCH /v1/convai/tools/{tool_id}
        "create_environment_variable",  // POST /v1/convai/environment-variables
        "update_environment_variable",  // PATCH /v1/convai/environment-variables/{env_var_id}
    ]
}
