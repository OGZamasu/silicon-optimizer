import Foundation
import Testing
@testable import SiliconElevenLabs
@testable import SiliconUI

/// Usage, service accounts and webhooks: the plan read from the free account routes, usage
/// charted from the analytics table, keys made with the spec's permissions and shown once,
/// limits cleared with the spec's word, webhooks created as HMAC with their secret shown once,
/// and every change that reaches outside the account asked first.
@Suite("ElevenLabs usage, service accounts and webhooks sections")
@MainActor
struct VoicesStudioAccountsTests {

    static let subscription: JSONValue = [
        "tier": "creator", "character_count": 61_200, "character_limit": 100_000, "status": "active",
        "next_character_count_reset_unix": 1_790_000_000, "voice_slots_used": 7, "voice_limit": 30,
        "professional_voice_slots_used": 1, "professional_voice_limit": 1, "billing_period": "monthly_period",
        "currency": "usd", "current_overage": ["amount": "0", "currency": "usd"],
        "next_invoice": ["amount_due_cents": 2200, "next_payment_attempt_unix": 1_790_000_000, "discounts": [],
                         "payment_intent_status": "processing", "payment_intent_statusses": []],
        "open_invoices": [], "has_open_invoices": false,
    ]

    static let usageTable: JSONValue = [
        "columns": ["time", "product_type", "credits"], "column_types": ["DateTime", "String", "Float"],
        "column_units": ["", "", "credits"],
        "rows": [["2026-09-27 00:00:00", "tts", 1200], ["2026-09-27 00:00:00", "dubbing", 300],
                 ["2026-09-28 00:00:00", "tts", 800.5]],
    ]

    // MARK: Usage

    @Test func thePlanIsReadFromTheFreeAccountRoutesAndTheKeyPreviewIsNeverShown() async throws {
        let fixture = VoicesStudioFixture([
            "get_user_subscription_info": [.json(Self.subscription)],
            "get_user_info": [.json(["user_id": "u1", "first_name": "Alex", "seat_type": "workspace_admin",
                                     "xi_api_key_preview": "sk_1234…", "subscription": Self.subscription])],
        ])
        defer { fixture.clean() }
        let model = UsageSectionModel(environment: fixture.environment)
        await model.refreshAccount()
        let account = try #require(model.account)
        #expect(account.remaining == 38_800)
        #expect(account.voiceSlots?.used == 7)
        #expect(account.nextInvoiceCents == 2200)
        #expect(account.overage == nil)
        #expect(account.seatType == "workspace_admin")
        for id in ["get_user_subscription_info", "get_user_info"] {
            #expect(try #require(model.actions.runner(id)).operation.risk == .read)
        }
    }

    @Test func usageIsQueriedForTheSpanAndChartedByGroup() async throws {
        let fixture = VoicesStudioFixture(["usage_by_product_over_time": [.json(Self.usageTable)]])
        defer { fixture.clean() }
        let model = UsageSectionModel(environment: fixture.environment)
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        model.now = { now }
        model.span = .week
        model.bucket = .day
        model.groupBy = "product_type"
        let arguments = model.usageArguments()
        #expect(arguments["end_time"] == .number(1_790_000_000_000))
        #expect(arguments["start_time"] == .number(Double(1_790_000_000 - 7 * 86_400) * 1000))
        #expect(arguments["interval_seconds"] == 86_400)
        #expect(arguments["group_by"] == ["product_type"])
        #expect(fixture.client.validate("usage_by_product_over_time", arguments: arguments).isEmpty)
        #expect(fixture.client.validate("requests_list", arguments: model.requestArguments()).isEmpty)

        await model.refreshUsage()
        let usage = try #require(model.usage)
        #expect(usage.points.count == 3)
        #expect(usage.points.map(\.group) == ["tts", "dubbing", "tts"])
        #expect(usage.total == 2300.5)
        #expect(usage.valueName == "Credits")
    }

    // MARK: Service accounts

    static let account: JSONValue = [
        "service_account_user_id": "sa1", "name": "Render farm", "created_at_unix": 1_780_000_000,
        "api-keys": [["name": "CI", "hint": "a1b2", "key_id": "k1", "service_account_user_id": "sa1",
                      "is_disabled": false, "permissions": ["text_to_speech", "voices_read"],
                      "character_limit": 50_000, "character_count": 1_200, "hashed_xi_api_key": "h",
                      "allowed_ips": ["10.0.0.0/24"]]],
    ]

    @Test func aNewKeyIsShownOnceAndNeverRecorded() async throws {
        let secret = "sk_" + String(repeating: "q", count: 30)
        let fixture = VoicesStudioFixture([
            "create_service_account_api_key": [.json(["xi-api-key": .string(secret), "key_id": "k2"])],
            "get_service_account_api_keys_route": [.json(["api-keys": []])],
        ])
        defer { fixture.clean() }
        let model = ServiceAccountsSectionModel(environment: fixture.environment)
        model.load(accounts: [try #require(ServiceAccount(json: Self.account))], selected: try #require(ServiceAccount(json: Self.account)))
        model.keyDraft.name = "Nightly"
        model.keyDraft.allPermissions = false
        #expect(model.createKeyArguments().1 == ["Choose what the key may do, or allow everything."])
        model.keyDraft.permissions = ["text_to_speech"]
        model.keyDraft.characterLimit = "10000"
        model.keyDraft.allowedIPs = "10.0.0.0/24\n192.0.2.7"
        let (arguments, problems) = model.createKeyArguments()
        #expect(problems.isEmpty)
        #expect(arguments["permissions"] == ["text_to_speech"])
        #expect(arguments["allowed_ips"] == ["10.0.0.0/24", "192.0.2.7"])
        #expect(fixture.client.validate("create_service_account_api_key", arguments: arguments).isEmpty)

        let asked = try await voicesStudioAsk(model.actions, answer: true) { await model.createKey() }
        #expect(asked?.risk == .realWorld)
        #expect(asked?.consequence.contains("It is shown once") == true)
        let runner = try #require(model.actions.runner("create_service_account_api_key"))
        #expect(runner.credential?.fields.first?.value == secret)
        guard case .json(let shown, _)? = runner.result else { Issue.record("expected JSON"); return }
        #expect(shown["xi-api-key"] == .string(ElevenLabsRedaction.placeholder))
        runner.dismissCredential()
        #expect(runner.credential == nil)
    }

    @Test func editingAKeySendsOnlyWhatChangedAndClearsALimitWithTheSpecsWord() throws {
        let fixture = VoicesStudioFixture()
        defer { fixture.clean() }
        let model = ServiceAccountsSectionModel(environment: fixture.environment)
        let account = try #require(ServiceAccount(json: Self.account))
        model.load(accounts: [account], selected: account)
        model.edit(account.keys[0])
        #expect(model.editKeyArguments() == ["service_account_user_id": "sa1", "api_key_id": "k1"])
        model.keyDraft.characterLimit = ""
        model.keyDraft.allPermissions = true
        let arguments = try #require(model.editKeyArguments())
        #expect(arguments["character_limit"] == "clear")
        #expect(arguments["permissions"] == "all")
        #expect(arguments["name"] == nil)
        #expect(fixture.client.validate("edit_service_account_api_key", arguments: arguments).isEmpty)
    }

    @Test func disablingThisAppsOwnKeySaysEverythingStops() async throws {
        let fixture = VoicesStudioFixture()
        defer { fixture.clean() }
        let model = ServiceAccountsSectionModel(environment: fixture.environment)
        let asked = try await voicesStudioAsk(model.actions, answer: false) { await model.disableOwnKey() }
        #expect(asked?.title == "Disable the key this Mac uses?")
        #expect(asked?.consequence.contains("stops working") == true)
        #expect(fixture.transport.recorded.isEmpty)
        for policy in ["allow", "forbid", "clear"] {
            model.policy = policy
            #expect(fixture.client.validate("set_third_party_disabling_policy", arguments: model.policyArguments()).isEmpty,
                    "\(policy)")
        }
    }

    // MARK: Webhooks

    @Test func aWebhookIsHMACSignedOverHTTPSAndItsSecretIsShownOnce() async throws {
        let fixture = VoicesStudioFixture([
            "create_workspace_webhook_route": [.json(["webhook_id": "w1", "webhook_secret": "whsec_fixture_value"])],
            "get_workspace_webhooks_route": [.json(["webhooks": []])],
        ])
        defer { fixture.clean() }
        let model = WebhooksSectionModel(environment: fixture.environment)
        model.draft.name = "Ops"
        model.draft.url = "http://example.com/hook"
        #expect(model.createArguments().1 == ["The address must be an https:// URL, as the spec asks."])
        model.draft.url = "https://example.com/hook"
        model.draft.headers = "X-Team: voice"
        let (arguments, problems) = model.createArguments()
        #expect(problems.isEmpty)
        #expect(arguments["settings"] == ["auth_type": "hmac", "name": "Ops", "webhook_url": "https://example.com/hook",
                                          "request_headers": ["X-Team": "voice"]])
        #expect(fixture.client.validate("create_workspace_webhook_route", arguments: arguments).isEmpty)

        _ = try await voicesStudioConfirm(model.actions.runner("create_workspace_webhook_route"), answer: true) {
            await model.create()
        }
        let runner = try #require(model.actions.runner("create_workspace_webhook_route"))
        #expect(runner.credential?.fields.map(\.path) == ["webhook_secret"])
    }

    @Test func savingAWebhookNamesTheEventsItStartsReceiving() async throws {
        let fixture = VoicesStudioFixture()
        defer { fixture.clean() }
        let model = WebhooksSectionModel(environment: fixture.environment)
        let webhook = try #require(WorkspaceWebhook(json: [
            "name": "Ops", "webhook_id": "w1", "webhook_url": "https://example.com/hook", "is_disabled": false,
            "is_auto_disabled": false, "created_at_unix": 1, "auth_type": "hmac", "events": ["flows"],
        ]))
        model.load(webhooks: [webhook])
        model.edit(webhook, eventsKnown: true)
        model.draft.events.insert("speech_to_text")
        let arguments = try #require(model.editArguments())
        #expect(arguments["events"] == ["flows", "speech_to_text"])
        #expect(fixture.client.validate("edit_workspace_webhook_route", arguments: arguments).isEmpty)
        let asked = try await voicesStudioConfirm(model.actions.runner("edit_workspace_webhook_route"), answer: false) {
            await model.save()
        }
        #expect(asked?.consequence.contains("starts receiving Speech to text events") == true)
        let deleting = try await voicesStudioConfirm(model.actions.runner("delete_workspace_webhook_route"), answer: false) {
            await model.delete(webhook)
        }
        #expect(deleting?.title == "Delete the webhook “Ops”?")
        #expect(fixture.transport.recorded.isEmpty)
    }
}
