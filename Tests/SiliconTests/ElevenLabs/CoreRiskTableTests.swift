import Foundation
import Testing
@testable import SiliconElevenLabs

/// Every operation has a reviewed risk class, the families that reach outside the account are
/// exactly the ones listed, and anything new fails safe.
@Suite("ElevenLabs risk table")
struct CoreRiskTableTests {

    @Test func everyOperationIsListedExactlyOnce() {
        let lists = [ElevenLabsRiskTable.read, ElevenLabsRiskTable.generate, ElevenLabsRiskTable.modify,
                     ElevenLabsRiskTable.destructive, ElevenLabsRiskTable.realWorld]
        let listed = lists.flatMap { $0 }
        #expect(listed.count == Set(listed).count, "an operation is in two lists")
        #expect(Set(listed) == Set(ElevenLabsCatalog.all.map(\.id)))
        #expect(lists.map(\.count) == [171, 52, 88, 34, 58])
    }

    @Test func theRulesHoldForEveryOperation() {
        for operation in ElevenLabsCatalog.all {
            switch operation.method {
            case "GET":
                #expect(operation.risk == .read, "\(operation.id)")
            case "DELETE":
                #expect([.destructive, .realWorld].contains(operation.risk), "\(operation.id)")
            default:
                break
            }
            if operation.method != "GET", ElevenLabsRiskTable.isInRealWorldFamily(operation.path) {
                #expect(operation.risk == .realWorld, "\(operation.id)")
            }
        }
    }

    /// The whole real-world list, written out: adding to it or taking from it is a decision,
    /// and this is where it shows.
    @Test func theRealWorldOperationsAreExactlyThese() {
        let realWorld = Set(ElevenLabsCatalog.all.filter { $0.risk == .realWorld }.map(\.id))
        #expect(realWorld == [
            // Outbound calls and messages
            "handle_twilio_outbound_call", "register_twilio_call", "handle_exotel_outbound_call",
            "whatsapp_outbound_call", "whatsapp_outbound_message", "handle_sip_trunk_outbound_call",
            // Batch calling
            "create_batch_call", "retry_batch_call", "cancel_batch_call", "delete_batch_call",
            // Phone numbers and WhatsApp accounts
            "create_phone_number_route", "update_phone_number_route", "delete_phone_number_route",
            "update_whatsapp_account", "delete_whatsapp_account",
            // Secrets
            "create_secret_route", "update_secret_route", "delete_secret_route",
            // MCP servers
            "create_mcp_server_route", "update_mcp_server_config_route", "delete_mcp_server_route",
            "update_mcp_server_approval_policy_route", "add_mcp_server_tool_approval_route",
            "remove_mcp_server_tool_approval_route", "add_mcp_tool_config_override_route",
            "update_mcp_tool_config_override_route", "remove_mcp_tool_config_override_route",
            // Agents Platform workspace settings
            "update_settings_route", "update_dashboard_settings_route",
            // Workspace membership, sharing, webhooks, auth connections
            "invite_user", "invite_users_bulk", "delete_invite", "update_workspace_member",
            "add_member", "remove_member", "share_resource_endpoint", "unshare_resource_endpoint",
            // Agent tools and environment variables: a webhook tool points an agent at an outside
            // URL with headers, as an MCP server does
            "add_tool_route", "update_tool_route", "create_environment_variable",
            "update_environment_variable",
            // Speech engines send ElevenLabs to an outside WebSocket URL with the owner's headers
            "create_speech_engine", "update_speech_engine",
            "create_workspace_webhook_route", "edit_workspace_webhook_route",
            "delete_workspace_webhook_route", "create_auth_connection", "update_auth_connection",
            "delete_auth_connection",
            // Service accounts and API keys
            "create_service_account", "create_service_account_api_key",
            "edit_service_account_api_key", "delete_service_account_api_key", "disable",
            "set_third_party_disabling_policy",
            // Outside the families, listed by hand
            "get_single_use_token", "replicate_voice_to_isolated_environment", "public_submit_order",
        ])
    }

    @Test func aNewOperationFailsSafeUntilSomeoneListsIt() throws {
        #expect(ElevenLabsRiskTable.defaultRisk(method: "POST", path: "/v1/brand-new") == .destructive)
        #expect(ElevenLabsRiskTable.defaultRisk(method: "PATCH", path: "/v1/voices/{voice_id}/new") == .destructive)
        #expect(ElevenLabsRiskTable.defaultRisk(method: "PUT", path: "/v1/anything") == .destructive)
        #expect(ElevenLabsRiskTable.defaultRisk(method: "POST", path: "/v1/convai/secrets/rotate") == .realWorld)
        #expect(ElevenLabsRiskTable.defaultRisk(method: "POST", path: "/v1/convai/twilio/new-call") == .realWorld)
        #expect(ElevenLabsRiskTable.defaultRisk(method: "GET", path: "/v1/convai/secrets/new") == .read)
        #expect(ElevenLabsRiskTable.defaultRisk(method: "GET", path: "/v1/brand-new") == .read)

        // The same through the loader, for an entry the table has never seen.
        let entry: JSONValue = [
            "id": "brand_new_operation", "method": "POST", "path": "/v1/brand-new",
            "group": "New", "parameters": [], "response": ["kind": "json"],
        ]
        let operation = try #require(ElevenLabsCatalog.operation(from: entry))
        #expect(operation.risk == .destructive)
        #expect(operation.requiresConfirmation)
        #expect(!operation.billable)
    }

    @Test func onlyDestructiveAndRealWorldAskFirst() {
        #expect(ElevenLabsRisk.allCases.filter(\.requiresConfirmation) == [.destructive, .realWorld])
    }

    @Test func everyGenerationIsBillableAndSoAreCallsAndSubmittedOrders() {
        for operation in ElevenLabsCatalog.all where operation.risk == .generate {
            #expect(operation.billable, "\(operation.id)")
        }
        let beyond = Set(ElevenLabsCatalog.all.filter { $0.billable && $0.risk != .generate }.map(\.id))
        #expect(beyond == [
            "handle_twilio_outbound_call", "register_twilio_call", "handle_exotel_outbound_call",
            "whatsapp_outbound_call", "whatsapp_outbound_message", "handle_sip_trunk_outbound_call",
            "create_batch_call", "retry_batch_call", "public_submit_order",
        ])
        #expect(ElevenLabsCatalog.operation("text_to_speech_full")?.billable == true)
        #expect(ElevenLabsCatalog.operation("get_voices")?.billable == false)
    }

    @Test func theCredentialReturningOperationsAreExactlyThese() {
        let flagged = Set(ElevenLabsCatalog.all.filter(\.returnsCredential).map(\.id))
        #expect(flagged == [
            "create_service_account_api_key", "create_workspace_webhook_route",
            "get_single_use_token", "get_conversation_signed_link", "get_signed_url_deprecated",
            "get_livekit_token", "get_agent_link_route", "get_agent_route",
            "patch_agent_settings_route", "merge_preview_route", "rebase_preview_route",
        ])
    }

    /// Each listed credential field really is in that operation's answer in the spec — the
    /// list was found by walking the schemas, and this walks them again.
    @Test func everyListedCredentialFieldIsInItsOperationsResponseSchema() throws {
        let snapshot = CoreCatalogTests.repository.appendingPathComponent("Scripts/elevenlabs/openapi.json")
        let spec = try JSONValue.parse(Data(contentsOf: snapshot))
        let schemas = spec["components"]["schemas"]
        for (id, fields) in ElevenLabsRiskTable.credentialFields {
            let operation = try #require(ElevenLabsCatalog.operation(id))
            let item = spec["paths"][operation.path][operation.method.lowercased()]
            var names = Set<String>()
            for (code, response) in item["responses"].objectValue ?? [:] where code.hasPrefix("2") {
                for (_, media) in response["content"].objectValue ?? [:] {
                    Self.collectFieldNames(media["schema"], schemas: schemas, seen: [], into: &names)
                }
            }
            for field in fields {
                #expect(names.contains(field), "\(id) has no \(field) in its response")
            }
        }
    }

    // MARK: - Redaction

    @Test func credentialFieldsAreRedactedAndNothingElseIs() throws {
        let token = try #require(ElevenLabsCatalog.operation("get_single_use_token"))
        #expect(ElevenLabsRedaction.redactCredentials(in: ["token": "sutkn_abc"], for: token)
                == ["token": .string(ElevenLabsRedaction.placeholder)])

        let agent = try #require(ElevenLabsCatalog.operation("get_agent_route"))
        let config: JSONValue = [
            "agent_id": "agent_1",
            "platform_settings": ["auth": ["enable_auth": true, "shareable_token": "share-abc"]],
            "conversation_config": ["tts": ["value": "kept"]],
        ]
        let redacted = ElevenLabsRedaction.redactCredentials(in: config, for: agent)
        #expect(redacted["platform_settings"]["auth"]["shareable_token"] == .string(ElevenLabsRedaction.placeholder))
        #expect(redacted["platform_settings"]["auth"]["enable_auth"] == true)
        #expect(redacted["conversation_config"]["tts"]["value"] == "kept")
        #expect(redacted["agent_id"] == "agent_1")

        // A public owner id is 64 hex digits; an answer must keep it.
        let voices = try #require(ElevenLabsCatalog.operation("get_library_voices"))
        let owner = String(repeating: "ab", count: 32)
        let list: JSONValue = ["voices": [["public_owner_id": .string(owner), "name": .string("sk_" + "notakeyjustaname")]]]
        let kept = ElevenLabsRedaction.redactCredentials(in: list, for: voices)
        #expect(kept["voices"][0]["public_owner_id"] == .string(owner))
        #expect(kept["voices"][0]["name"] == .string(ElevenLabsRedaction.placeholder))
    }

    @Test func theKeyPreviewIsRedactedFromTheUserAnswerToo() throws {
        let user = try #require(ElevenLabsCatalog.operation("get_user_info"))
        #expect(!user.returnsCredential)
        let redacted = ElevenLabsRedaction.redactCredentials(
            in: ["user_id": "u1", "xi_api_key_preview": "sk_…1234"], for: user
        )
        #expect(redacted["xi_api_key_preview"] == .string(ElevenLabsRedaction.placeholder))
        #expect(redacted["user_id"] == "u1")
    }

    @Test func errorTextLosesAnythingKeyShaped() {
        let key = "sk_" + String(repeating: "a1", count: 20)
        let legacy = String(repeating: "0f", count: 16)
        let text = ElevenLabsRedaction.redact("bad key \(key) and \(legacy) for task_abcdefghijk")
        #expect(!text.contains(key))
        #expect(!text.contains(legacy))
        #expect(text.contains("task_abcdefghijk"))
        #expect(ElevenLabsRedaction.redact("the key is hunter2hunter2", knownKey: "hunter2hunter2")
                == "the key is \(ElevenLabsRedaction.placeholder)")
    }

    // MARK: - Helpers

    static func collectFieldNames(
        _ schema: JSONValue, schemas: JSONValue, seen: Set<String>, into names: inout Set<String>
    ) {
        if let reference = schema["$ref"].stringValue {
            let name = String(reference.split(separator: "/").last ?? "")
            guard !seen.contains(name) else { return }
            collectFieldNames(schemas[name], schemas: schemas, seen: seen.union([name]), into: &names)
            return
        }
        for key in ["anyOf", "oneOf", "allOf"] {
            for variant in schema[key].arrayValue ?? [] {
                collectFieldNames(variant, schemas: schemas, seen: seen, into: &names)
            }
        }
        for key in ["items", "additionalProperties"] where schema[key].objectValue != nil {
            collectFieldNames(schema[key], schemas: schemas, seen: seen, into: &names)
        }
        for (name, property) in schema["properties"].objectValue ?? [:] {
            names.insert(name)
            collectFieldNames(property, schemas: schemas, seen: seen, into: &names)
        }
    }

    /// Cancelling a crawl deletes every document it created, so it asks first like a delete.
    @Test func cancellingACrawlIsDestructive() throws {
        let operation = try #require(ElevenLabsCatalog.operation("cancel_crawl_job_route"))
        #expect(operation.risk == .destructive)
        #expect(operation.risk.requiresConfirmation)
    }
}
