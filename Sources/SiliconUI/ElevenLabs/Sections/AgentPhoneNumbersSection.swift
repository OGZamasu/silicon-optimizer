import Foundation
import Observation
import SiliconElevenLabs
import SwiftUI

/// Phone numbers and WhatsApp accounts agents answer on, and calls and messages they place.
///
/// Everything here reaches the real world: importing a number, pointing it at an agent,
/// removing it, placing a call, sending a WhatsApp message. Each asks first, naming the number,
/// the recipient and the agent, and saying what will happen and that it is billed.
struct AgentPhoneNumbersSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        AgentPhoneNumbersScreen(model: AgentsPlatformStore.shared(for: app).phoneNumbers)
    }
}

struct AgentPhoneNumbersScreen: View {
    @Bindable var model: AgentPhoneNumbersModel

    var body: some View {
        ElevenLabsSectionPage(.agentPhoneNumbers, accessory: {
            AgentsRefreshButton(list: model.list, help: "Fetch the phone numbers again")
        }) {
            AgentsMasterDetail {
                AgentsCard("Phone numbers") {
                    AgentsSearchField(prompt: "Number, label or ID", text: $model.search) {
                        Task { await model.list.refresh() }
                    }
                    Picker("Provider", selection: $model.provider) {
                        Text("All providers").tag("")
                        ForEach(AgentsSchema.choices(AgentsOp.listPhoneNumbers, "provider"), id: \.self) {
                            Text(AgentsFormat.words($0)).tag($0)
                        }
                    }
                    .font(.caption)
                    .fixedSize()
                    .onChange(of: model.provider) { Task { await model.list.refresh() } }
                    AgentsListBody(model.list, runner: model.calls.runner(AgentsOp.listPhoneNumbers),
                                   empty: "No numbers yet. Import one from Twilio, a SIP trunk or Exotel below.") { number in
                        AgentsRow(selected: model.selectedID == number.id) {
                            Task { await model.select(number.id) }
                        } content: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(number.number).font(.callout.monospacedDigit())
                                Text("\(number.label.isEmpty ? number.providerName : "\(number.label) · \(number.providerName)")\(number.agentName.map { " → \($0)" } ?? "")")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
            } detail: {
                if let number = model.selected {
                    AgentPhoneNumberDetail(model: model, number: number)
                } else {
                    AgentsCard("No number selected") {
                        AgentsEmptyState(title: "Choose a number",
                                         message: "Point it at an agent, rename it, see its SIP log, or remove it.",
                                         systemImage: "phone")
                    }
                }
            }
            AgentOutboundCallCard(model: model)
            AgentPhoneImportCard(model: model)
            AgentWhatsAppCard(model: model)
        }
        .task { await model.list.loadIfNeeded() }
    }
}

// MARK: - View-model

@MainActor
@Observable
final class AgentPhoneNumbersModel {
    enum ImportProvider: String, CaseIterable, Identifiable {
        case twilio = "Twilio"
        case sipTrunk = "SIP trunk"
        case exotel = "Exotel"
        var id: String { rawValue }
    }

    @ObservationIgnored unowned let store: AgentsPlatformStore
    var calls: AgentsCalls { store.calls }

    var search = ""
    var provider = ""
    let list: AgentsPagedList<AgentsPhoneNumber>

    private(set) var selectedID: String?
    private(set) var detail: JSONValue = .null
    var assignAgentID = ""
    var labelText = ""
    private(set) var sipMessages: [JSONValue] = []

    // Outbound call
    var callFromID = ""
    var callAgentID = ""
    var callTo = ""
    var callVariables = ""
    var callRecording = false
    var callRingSeconds = 60

    // Import
    /// Whether the import form and the WhatsApp card are open.
    var showsImport = false
    var showsWhatsApp = false
    var importProvider: ImportProvider = .twilio
    var importLabel = ""
    var importNumber = ""
    var twilioSID = ""
    var twilioToken = ""
    var sipAddress = ""
    var sipTransport = ""
    var sipEncryption = ""
    var sipUsername = ""
    var sipPassword = ""
    var exotelAccountSID = ""
    var exotelAPIKey = ""
    var exotelAPIToken = ""
    var exotelSubdomain = ""
    var exotelAppID = ""
    var importInbound = true
    var importOutbound = true

    // WhatsApp
    let whatsApp: AgentsPagedList<AgentsWhatsAppAccount>
    var whatsAppAccountID = ""
    var whatsAppAgentID = ""
    var whatsAppRecipient = ""
    var whatsAppTemplate = ""
    var whatsAppLanguage = "en"
    var whatsAppBodyParameters = ""
    var whatsAppPermissionTemplate = ""

    /// Request fields that carry the owner's provider secrets: masked in "Show API call".
    static let secretFields: Set<String> = ["token", "account_auth_token", "api_key", "api_token", "password"]

    init(store: AgentsPlatformStore) {
        self.store = store
        let box = AgentsWeakBox<AgentPhoneNumbersModel>()
        list = AgentsPagedList { cursor in await box.value?.fetchPage(cursor) }
        whatsApp = AgentsPagedList { _ in await box.value?.fetchWhatsApp() }
        box.value = self
    }

    var selected: AgentsPhoneNumber? {
        guard let selectedID else { return nil }
        return AgentsPhoneNumber(json: detail) ?? list.item(selectedID)
    }

    private func fetchPage(_ cursor: String?) async -> AgentsPage<AgentsPhoneNumber>? {
        var arguments: [String: JSONValue] = ["page_size": 100]
        let search = search.trimmingCharacters(in: .whitespaces)
        if !search.isEmpty { arguments["search"] = .string(search) }
        if !provider.isEmpty { arguments["provider"] = .string(provider) }
        if let cursor { arguments["cursor"] = .string(cursor) }
        guard let json = await calls.json(AgentsOp.listPhoneNumbers, arguments, quiet: true) else { return nil }
        return AgentsPage(
            items: (json["phone_numbers"].arrayValue ?? []).compactMap(AgentsPhoneNumber.init(json:)),
            cursor: json["next_cursor"].stringValue, hasMore: json["has_more"].boolValue
        )
    }

    func select(_ id: String) async {
        selectedID = id
        detail = .null
        sipMessages = []
        // The previous number's agent and name never stand in for this one's.
        let known = list.item(id)
        assignAgentID = known?.agentID ?? ""
        labelText = known?.label ?? ""
        guard let json = await calls.json(AgentsOp.getPhoneNumber, ["phone_number_id": .string(id)], slot: id, quiet: true),
              selectedID == id else { return }
        detail = json
        if let number = AgentsPhoneNumber(json: json) {
            assignAgentID = number.agentID ?? ""
            labelText = number.label
            list.upsert(number)
        }
    }

    // MARK: Changing a number

    func assignAgent() async {
        guard let number = selected else { return }
        let agent = assignAgentID.isEmpty ? nil : store.directory.agentName(assignAgentID)
        let value: JSONValue = assignAgentID.isEmpty ? .null : .string(assignAgentID)
        guard await calls.json(
            AgentsOp.updatePhoneNumber, ["phone_number_id": .string(number.id), "agent_id": value],
            slot: "\(number.id)#agent",
            subject: agent.map { "\(number.number) answered by “\($0)”" } ?? "\(number.number) answered by no agent",
            consequence: agent.map { "From now on, calls to \(number.number) are answered by “\($0)”." }
                ?? "Calls to \(number.number) will no longer be answered by an agent.",
            question: agent.map { "Answer calls to \(number.number) with “\($0)”?" }
                ?? "Stop answering calls to \(number.number) with an agent?",
            confirmLabel: agent == nil ? "Unassign" : "Assign"
        ) != nil else { return }
        await select(number.id)
    }

    func rename() async {
        guard let number = selected else { return }
        let label = labelText.trimmingCharacters(in: .whitespaces)
        guard await calls.json(
            AgentsOp.updatePhoneNumber, ["phone_number_id": .string(number.id), "label": .string(label)],
            slot: "\(number.id)#label",
            subject: "\(number.number) renamed “\(label)”", consequence: "Only its name in ElevenLabs changes.",
            question: "Rename \(number.number) “\(label)”?", confirmLabel: "Rename"
        ) != nil else { return }
        await select(number.id)
    }

    func loadSIPMessages() async {
        guard let selectedID else { return }
        guard let json = await calls.json(AgentsOp.phoneSIPMessages, ["phone_number_id": .string(selectedID), "page_size": 20],
                                          slot: selectedID, quiet: true)
        else { return }
        sipMessages = json["sip_messages"].arrayValue ?? []
    }

    func delete() async {
        guard let number = selected else { return }
        guard await calls.json(
            AgentsOp.deletePhoneNumber, ["phone_number_id": .string(number.id)], slot: number.id,
            subject: "\(number.number) from ElevenLabs",
            consequence: "Calls to \(number.number) stop reaching your agents, and agents can no longer call from it. "
                + "The number itself stays with \(number.providerName)."
        ) != nil else { return }
        list.remove(number.id)
        store.directory.phoneNumbers.remove(number.id)
        guard selectedID == number.id else { return }
        selectedID = nil
        detail = .null
    }

    // MARK: Outbound call

    /// `name=value` lines, as the agent's dynamic variables.
    static func variables(_ text: String) -> [String: JSONValue] {
        var variables: [String: JSONValue] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty else { continue }
            variables[parts[0]] = .string(parts[1])
        }
        return variables
    }

    var callFrom: AgentsPhoneNumber? {
        store.directory.phoneNumber(callFromID) ?? list.item(callFromID)
    }

    func callArguments() -> [String: JSONValue]? {
        let to = callTo.trimmingCharacters(in: .whitespaces)
        guard let from = callFrom, from.outboundCallOperation != nil, !callAgentID.isEmpty, !to.isEmpty else { return nil }
        var arguments: [String: JSONValue] = [
            "agent_id": .string(callAgentID), "agent_phone_number_id": .string(from.id), "to_number": .string(to),
            "telephony_call_config": ["ringing_timeout_secs": .number(Double(callRingSeconds))],
        ]
        let variables = Self.variables(callVariables)
        if !variables.isEmpty {
            arguments["conversation_initiation_client_data"] = ["dynamic_variables": .object(variables)]
        }
        if from.provider == "twilio", callRecording { arguments["call_recording_enabled"] = true }
        return arguments
    }

    /// The outbound call's guard: one for the screen, whichever provider places the call, so
    /// switching the From number during a call cannot start a second one.
    let callGuard = AgentsSendGuard()
    let whatsAppMessageGuard = AgentsSendGuard()
    let whatsAppCallGuard = AgentsSendGuard()

    /// Places one real phone call, after the owner confirms who is called, from where and by whom.
    /// If the outcome is unknown, the number is cleared and nothing more can be dialled until the
    /// owner has looked in Conversations.
    func placeCall() async {
        guard callGuard.canSend, let from = callFrom, let operation = from.outboundCallOperation,
              let arguments = callArguments() else { return }
        let to = callTo.trimmingCharacters(in: .whitespaces)
        let agent = store.directory.agentName(callAgentID)
        let runner = calls.runner(operation)
        let answer = await callGuard.send(runner: runner, what: "The call to \(to)", check: "Conversations") {
            await calls.json(
                operation, arguments, title: "Call to \(to)",
                subject: "a call to \(to) with “\(agent)”",
                consequence: "ElevenLabs will dial \(to) now from \(from.displayName) through \(from.providerName), and the agent "
                    + "“\(agent)” will talk to whoever answers. The call is billed by the minute and cannot be stopped from here."
            )
        }
        if answer != nil || callGuard.warning != nil {
            callTo = ""
            await store.conversations.list.refresh()
        }
    }

    // MARK: Import

    /// The import body for the chosen provider.
    func importBody() -> JSONValue? {
        let label = importLabel.trimmingCharacters(in: .whitespaces)
        let number = importNumber.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty, !number.isEmpty else { return nil }
        var body: [String: JSONValue] = [
            "label": .string(label), "phone_number": .string(number),
            "supports_inbound": .bool(importInbound), "supports_outbound": .bool(importOutbound),
        ]
        switch importProvider {
        case .twilio:
            guard !twilioSID.isEmpty, !twilioToken.isEmpty else { return nil }
            body["provider"] = "twilio"
            body["sid"] = .string(twilioSID.trimmingCharacters(in: .whitespaces))
            body["token"] = .string(twilioToken)
        case .sipTrunk:
            body["provider"] = "sip_trunk"
            if !sipAddress.isEmpty {
                var outbound: [String: JSONValue] = ["address": .string(sipAddress.trimmingCharacters(in: .whitespaces))]
                if !sipTransport.isEmpty { outbound["transport"] = .string(sipTransport) }
                if !sipEncryption.isEmpty { outbound["media_encryption"] = .string(sipEncryption) }
                if !sipUsername.isEmpty {
                    var credentials: [String: JSONValue] = ["username": .string(sipUsername)]
                    if !sipPassword.isEmpty { credentials["password"] = .string(sipPassword) }
                    outbound["credentials"] = .object(credentials)
                }
                body["outbound_trunk_config"] = .object(outbound)
            }
        case .exotel:
            guard !exotelAccountSID.isEmpty, !exotelAPIKey.isEmpty, !exotelAPIToken.isEmpty, !exotelSubdomain.isEmpty,
                  !exotelAppID.isEmpty else { return nil }
            body["provider"] = "exotel"
            body["account_sid"] = .string(exotelAccountSID)
            body["api_key"] = .string(exotelAPIKey)
            body["api_token"] = .string(exotelAPIToken)
            body["api_subdomain"] = .string(exotelSubdomain)
            body["app_id"] = .string(exotelAppID)
        }
        return .object(body)
    }

    func importNumberNow() async {
        guard let body = importBody() else { return }
        let number = importNumber.trimmingCharacters(in: .whitespaces)
        guard let json = await calls.json(
            AgentsOp.importPhoneNumber, ["body": body], title: "Imported \(number)",
            subject: "\(number) from \(importProvider.rawValue)",
            consequence: "ElevenLabs will connect \(number) to your account using the \(importProvider.rawValue) credentials "
                + "you entered, so agents can answer\(importOutbound ? " and place" : "") calls on it. "
                + "The credentials are sent to ElevenLabs and not written to disk by this app.",
            question: "Import \(number) from \(importProvider.rawValue)?", confirmLabel: "Import number",
            holdIfUnknown: AgentsCreateHolds.lost("\(number) from \(importProvider.rawValue)", check: "the phone numbers list")
                .replacingOccurrences(of: "The answer to creating", with: "The answer to importing")
        ) else {
            // It may have been connected, with the credentials typed: the list shows whether.
            if calls.outcomeWasUnknown(AgentsOp.importPhoneNumber) {
                calls.holds.onReadAgain(AgentsOp.importPhoneNumber) { [weak self] in await self?.list.refresh() }
                store.directory.phoneNumbers.reset()
                await list.refresh()
            }
            return
        }
        twilioToken = ""
        sipPassword = ""
        exotelAPIKey = ""
        exotelAPIToken = ""
        importLabel = ""
        importNumber = ""
        store.directory.phoneNumbers.reset()
        await list.refresh()
        if let id = json["phone_number_id"].stringValue { await select(id) }
    }

    // MARK: WhatsApp

    private func fetchWhatsApp() async -> AgentsPage<AgentsWhatsAppAccount>? {
        guard let json = await calls.json(AgentsOp.listWhatsAppAccounts, quiet: true) else { return nil }
        return AgentsPage(items: (json["items"].arrayValue ?? []).compactMap(AgentsWhatsAppAccount.init(json:)))
    }

    var whatsAppAccount: AgentsWhatsAppAccount? { whatsApp.item(whatsAppAccountID) }

    func refreshWhatsAppAccount(_ id: String) async {
        guard let json = await calls.json(AgentsOp.getWhatsAppAccount, ["phone_number_id": .string(id)], slot: id, quiet: true),
              let account = AgentsWhatsAppAccount(json: json) else { return }
        whatsApp.upsert(account)
    }

    func updateWhatsApp(_ account: AgentsWhatsAppAccount, changes: [String: JSONValue], what: String) async {
        var arguments = changes
        arguments["phone_number_id"] = .string(account.id)
        guard await calls.json(
            AgentsOp.updateWhatsAppAccount, arguments, slot: account.id,
            subject: "\(account.number)", consequence: what,
            question: "Save the WhatsApp settings of \(account.number)?", confirmLabel: "Save"
        ) != nil else { return }
        await refreshWhatsAppAccount(account.id)
    }

    func deleteWhatsApp(_ account: AgentsWhatsAppAccount) async {
        guard await calls.json(
            AgentsOp.deleteWhatsAppAccount, ["phone_number_id": .string(account.id)], slot: account.id,
            subject: "the WhatsApp account \(account.number) from ElevenLabs",
            consequence: "Messages and calls to \(account.number) on WhatsApp stop reaching your agents."
        ) != nil else { return }
        whatsApp.remove(account.id)
    }

    func whatsAppMessageArguments() -> [String: JSONValue]? {
        guard let account = whatsAppAccount, !whatsAppAgentID.isEmpty else { return nil }
        let recipient = whatsAppRecipient.trimmingCharacters(in: .whitespaces)
        let template = whatsAppTemplate.trimmingCharacters(in: .whitespaces)
        guard !recipient.isEmpty, !template.isEmpty else { return nil }
        let parameters: [JSONValue] = whatsAppBodyParameters.split(whereSeparator: \.isNewline)
            .map { ["type": "text", "text": .string(String($0))] }
        return [
            "agent_id": .string(whatsAppAgentID), "whatsapp_phone_number_id": .string(account.id),
            "whatsapp_user_id": .string(recipient), "template_name": .string(template),
            "template_language_code": .string(whatsAppLanguage),
            "template_params": parameters.isEmpty ? [] : [["type": "body", "parameters": .array(parameters)]],
        ]
    }

    func sendWhatsAppMessage() async {
        guard whatsAppMessageGuard.canSend, let account = whatsAppAccount, let arguments = whatsAppMessageArguments()
        else { return }
        let recipient = whatsAppRecipient.trimmingCharacters(in: .whitespaces)
        let agent = store.directory.agentName(whatsAppAgentID)
        let runner = calls.runner(AgentsOp.whatsAppMessage)
        let answer = await whatsAppMessageGuard.send(runner: runner, what: "The WhatsApp message to \(recipient)",
                                                     check: "Conversations") {
            await calls.json(
                AgentsOp.whatsAppMessage, arguments, title: "WhatsApp message to \(recipient)",
                subject: "a WhatsApp message to \(recipient)",
                consequence: "ElevenLabs will send the template “\(whatsAppTemplate)” from \(account.number) to \(recipient) "
                    + "on WhatsApp, and the agent “\(agent)” will carry on the conversation if they reply. It is billed."
            )
        }
        if answer != nil || whatsAppMessageGuard.warning != nil {
            whatsAppRecipient = ""
            await store.conversations.list.refresh()
        }
    }

    func whatsAppCallArguments() -> [String: JSONValue]? {
        guard let account = whatsAppAccount, !whatsAppAgentID.isEmpty else { return nil }
        let recipient = whatsAppRecipient.trimmingCharacters(in: .whitespaces)
        let template = whatsAppPermissionTemplate.trimmingCharacters(in: .whitespaces)
        guard !recipient.isEmpty, !template.isEmpty else { return nil }
        return [
            "agent_id": .string(whatsAppAgentID), "whatsapp_phone_number_id": .string(account.id),
            "whatsapp_user_id": .string(recipient),
            "whatsapp_call_permission_request_template_name": .string(template),
            "whatsapp_call_permission_request_template_language_code": .string(whatsAppLanguage),
        ]
    }

    func placeWhatsAppCall() async {
        guard whatsAppCallGuard.canSend, let account = whatsAppAccount, let arguments = whatsAppCallArguments() else { return }
        let recipient = whatsAppRecipient.trimmingCharacters(in: .whitespaces)
        let template = whatsAppPermissionTemplate.trimmingCharacters(in: .whitespaces)
        let agent = store.directory.agentName(whatsAppAgentID)
        let runner = calls.runner(AgentsOp.whatsAppCall)
        let answer = await whatsAppCallGuard.send(runner: runner, what: "The WhatsApp call to \(recipient)",
                                                  check: "Conversations") {
            await calls.json(
                AgentsOp.whatsAppCall, arguments, title: "WhatsApp call to \(recipient)",
                subject: "a WhatsApp call to \(recipient) with “\(agent)”",
                consequence: "ElevenLabs will call \(recipient) on WhatsApp from \(account.number) (asking their permission first with "
                    + "the template “\(template)”), and the agent “\(agent)” will talk to them. The call is billed by the minute."
            )
        }
        if answer != nil || whatsAppCallGuard.warning != nil {
            whatsAppRecipient = ""
            await store.conversations.list.refresh()
        }
    }

    static let arguments: [AgentsArgument] = [
        AgentsArgument(AgentsOp.listPhoneNumbers, "page_size"), AgentsArgument(AgentsOp.listPhoneNumbers, "search"),
        AgentsArgument(AgentsOp.listPhoneNumbers, "provider"), AgentsArgument(AgentsOp.listPhoneNumbers, "cursor"),
        AgentsArgument(AgentsOp.getPhoneNumber, "phone_number_id"),
        AgentsArgument(AgentsOp.updatePhoneNumber, "phone_number_id"), AgentsArgument(AgentsOp.updatePhoneNumber, "agent_id"),
        AgentsArgument(AgentsOp.updatePhoneNumber, "label"),
        AgentsArgument(AgentsOp.phoneSIPMessages, "phone_number_id"), AgentsArgument(AgentsOp.phoneSIPMessages, "page_size"),
        AgentsArgument(AgentsOp.deletePhoneNumber, "phone_number_id"),
    ] + [AgentsOp.twilioCall, AgentsOp.sipTrunkCall, AgentsOp.exotelCall].flatMap { op in
        [
            AgentsArgument(op, "agent_id"), AgentsArgument(op, "agent_phone_number_id"), AgentsArgument(op, "to_number"),
            AgentsArgument(op, "telephony_call_config.ringing_timeout_secs"),
            AgentsArgument(op, "conversation_initiation_client_data.dynamic_variables"),
        ]
    } + [
        AgentsArgument(AgentsOp.twilioCall, "call_recording_enabled"),
        AgentsArgument(AgentsOp.importPhoneNumber, "label"), AgentsArgument(AgentsOp.importPhoneNumber, "phone_number"),
        AgentsArgument(AgentsOp.importPhoneNumber, "supports_inbound"), AgentsArgument(AgentsOp.importPhoneNumber, "supports_outbound"),
        AgentsArgument(AgentsOp.importPhoneNumber, "provider"), AgentsArgument(AgentsOp.importPhoneNumber, "sid"),
        AgentsArgument(AgentsOp.importPhoneNumber, "token"),
        AgentsArgument(AgentsOp.importPhoneNumber, "outbound_trunk_config.address"),
        AgentsArgument(AgentsOp.importPhoneNumber, "outbound_trunk_config.transport"),
        AgentsArgument(AgentsOp.importPhoneNumber, "outbound_trunk_config.media_encryption"),
        AgentsArgument(AgentsOp.importPhoneNumber, "outbound_trunk_config.credentials.username"),
        AgentsArgument(AgentsOp.importPhoneNumber, "outbound_trunk_config.credentials.password"),
        AgentsArgument(AgentsOp.importPhoneNumber, "account_sid"), AgentsArgument(AgentsOp.importPhoneNumber, "api_key"),
        AgentsArgument(AgentsOp.importPhoneNumber, "api_token"), AgentsArgument(AgentsOp.importPhoneNumber, "api_subdomain"),
        AgentsArgument(AgentsOp.importPhoneNumber, "app_id"),
        AgentsArgument(AgentsOp.getWhatsAppAccount, "phone_number_id"),
        AgentsArgument(AgentsOp.updateWhatsAppAccount, "phone_number_id"),
        AgentsArgument(AgentsOp.updateWhatsAppAccount, "assigned_agent_id"),
        AgentsArgument(AgentsOp.updateWhatsAppAccount, "enable_messaging"),
        AgentsArgument(AgentsOp.updateWhatsAppAccount, "enable_audio_message_response"),
        AgentsArgument(AgentsOp.updateWhatsAppAccount, "enable_typing_indicator"),
        AgentsArgument(AgentsOp.deleteWhatsAppAccount, "phone_number_id"),
        AgentsArgument(AgentsOp.whatsAppMessage, "agent_id"), AgentsArgument(AgentsOp.whatsAppMessage, "whatsapp_phone_number_id"),
        AgentsArgument(AgentsOp.whatsAppMessage, "whatsapp_user_id"), AgentsArgument(AgentsOp.whatsAppMessage, "template_name"),
        AgentsArgument(AgentsOp.whatsAppMessage, "template_language_code"),
        AgentsArgument(AgentsOp.whatsAppMessage, "template_params[].type"),
        AgentsArgument(AgentsOp.whatsAppMessage, "template_params[].parameters[].type"),
        AgentsArgument(AgentsOp.whatsAppMessage, "template_params[].parameters[].text"),
        AgentsArgument(AgentsOp.whatsAppCall, "agent_id"), AgentsArgument(AgentsOp.whatsAppCall, "whatsapp_phone_number_id"),
        AgentsArgument(AgentsOp.whatsAppCall, "whatsapp_user_id"),
        AgentsArgument(AgentsOp.whatsAppCall, "whatsapp_call_permission_request_template_name"),
        AgentsArgument(AgentsOp.whatsAppCall, "whatsapp_call_permission_request_template_language_code"),
    ]
}

// MARK: - Views

private struct AgentPhoneNumberDetail: View {
    @Bindable var model: AgentPhoneNumbersModel
    let number: AgentsPhoneNumber

    var body: some View {
        let calls = model.calls
        VStack(alignment: .leading, spacing: 14) {
            AgentsCard(number.number, subtitle: number.label) {
                AgentsFact(label: "Provider", value: number.providerName)
                AgentsFact(label: "Calls", value: AgentsFormat.words(
                    [number.supportsInbound ? "incoming" : nil, number.supportsOutbound ? "outgoing" : nil]
                        .compactMap { $0 }.joined(separator: " and ")
                ))
                AgentsFact(label: "Answered by", value: number.agentName ?? "No agent")
                AgentsFact(label: "ID", value: number.id, monospaced: true)
                AgentsRunnerError(runner: calls.runner(AgentsOp.getPhoneNumber, slot: number.id))
            }
            AgentsCard("Agent", subtitle: "Which agent answers calls to this number.") {
                HStack {
                    AgentsAgentPicker(directory: model.store.directory, selection: $model.assignAgentID, noneTitle: "No agent")
                        .fixedSize()
                    AgentsRunButton(runner: calls.runner(AgentsOp.updatePhoneNumber, slot: "\(number.id)#agent"), title: "Assign…",
                                    disabled: model.assignAgentID == (number.agentID ?? "")) {
                        Task { await model.assignAgent() }
                    }
                }
                AgentsRunnerOutput(runner: calls.runner(AgentsOp.updatePhoneNumber, slot: "\(number.id)#agent"))
            }
            AgentsCard("Label") {
                HStack {
                    TextField("Label", text: $model.labelText).textFieldStyle(.roundedBorder)
                    AgentsRunButton(runner: calls.runner(AgentsOp.updatePhoneNumber, slot: "\(number.id)#label"), title: "Rename…",
                                    disabled: model.labelText == number.label || model.labelText.isEmpty) {
                        Task { await model.rename() }
                    }
                }
                AgentsRunnerOutput(runner: calls.runner(AgentsOp.updatePhoneNumber, slot: "\(number.id)#label"))
            }
            AgentsCard("SIP log", subtitle: "The signalling of recent calls on this number, for troubleshooting.") {
                Button("Fetch SIP messages") { Task { await model.loadSIPMessages() } }
                AgentsRunnerError(runner: calls.runner(AgentsOp.phoneSIPMessages, slot: number.id))
                ForEach(Array(model.sipMessages.enumerated()), id: \.offset) { _, message in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(AgentsFormat.words(message["direction"].stringValue)) · \(message["transport"].stringValue ?? "")")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(message["raw_message"].stringValue ?? "").font(.caption.monospaced()).lineLimit(6).textSelection(.enabled)
                    }
                }
            }
            AgentsCard("Remove") {
                AgentsRunButton(runner: calls.runner(AgentsOp.deletePhoneNumber, slot: number.id), title: "Remove from ElevenLabs…") {
                    Task { await model.delete() }
                }
                AgentsRunnerOutput(runner: calls.runner(AgentsOp.deletePhoneNumber, slot: number.id))
            }
        }
    }
}

private struct AgentOutboundCallCard: View {
    @Bindable var model: AgentPhoneNumbersModel

    var body: some View {
        let runner = model.calls.runner(model.callFrom?.outboundCallOperation ?? AgentsOp.twilioCall)
        AgentsCard("Place a call", subtitle: "An agent calls one person now. For many at once, use Batch calls.") {
            Form {
                AgentsPhoneNumberPicker(directory: model.store.directory, selection: $model.callFromID)
                AgentsAgentPicker(directory: model.store.directory, selection: $model.callAgentID)
                TextField("Number to call", text: $model.callTo, prompt: Text("+15550100"))
                Stepper("Ring for \(model.callRingSeconds) s", value: $model.callRingSeconds, in: {
                    let range = AgentsSchema.range(AgentsOp.twilioCall, "telephony_call_config.ringing_timeout_secs", fallback: 1...999)
                    return Int(range.lowerBound)...Int(range.upperBound)
                }(), step: 5)
                if model.callFrom?.provider == "twilio" {
                    Toggle("Record the call", isOn: $model.callRecording)
                }
            }
            .formStyle(.columns)
            VStack(alignment: .leading, spacing: 4) {
                Text("Dynamic variables").font(.callout)
                TextEditor(text: $model.callVariables)
                    .font(.callout.monospaced())
                    .frame(minHeight: 44)
                    .overlay { RoundedRectangle(cornerRadius: 5).stroke(.separator) }
                Text("One name=value per line, filled into the agent's prompt.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            AgentsSendButton(runner: runner, guardian: model.callGuard, title: "Call…",
                             disabled: model.callArguments() == nil,
                             disabledReason: model.callFrom != nil && model.callFrom?.outboundCallOperation == nil
                                 ? "This app cannot place calls through \(model.callFrom?.providerName ?? "that provider")." : nil) {
                Task { await model.placeCall() }
            }
            ForEach([AgentsOp.twilioCall, AgentsOp.sipTrunkCall, AgentsOp.exotelCall], id: \.self) {
                AgentsRunnerOutput(runner: model.calls.runner($0), showsResult: true)
            }
        }
    }
}

private struct AgentPhoneImportCard: View {
    @Bindable var model: AgentPhoneNumbersModel

    var body: some View {
        let runner = model.calls.runner(AgentsOp.importPhoneNumber)
        AgentsCard("Import a number", subtitle: "Connect a number you have with Twilio, a SIP trunk or Exotel. Its credentials go to ElevenLabs and are not kept by this app.") {
            DisclosureGroup("Show the form", isExpanded: $model.showsImport) {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Provider", selection: $model.importProvider) {
                        ForEach(AgentPhoneNumbersModel.ImportProvider.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Form {
                        TextField("Label", text: $model.importLabel, prompt: Text("Support line"))
                        TextField("Number", text: $model.importNumber, prompt: Text("+15550100"))
                        switch model.importProvider {
                        case .twilio:
                            TextField("Account SID", text: $model.twilioSID)
                            SecureField("Auth token", text: $model.twilioToken)
                        case .sipTrunk:
                            TextField("Outbound address", text: $model.sipAddress, prompt: Text("sip.example.com"))
                            Picker("Transport", selection: $model.sipTransport) {
                                Text("Default").tag("")
                                ForEach(AgentsSchema.choices(AgentsOp.importPhoneNumber, "outbound_trunk_config.transport"), id: \.self) {
                                    Text($0.uppercased()).tag($0)
                                }
                            }
                            Picker("Media encryption", selection: $model.sipEncryption) {
                                Text("Default").tag("")
                                ForEach(AgentsSchema.choices(AgentsOp.importPhoneNumber, "outbound_trunk_config.media_encryption"), id: \.self) {
                                    Text(AgentsFormat.words($0)).tag($0)
                                }
                            }
                            TextField("Username", text: $model.sipUsername, prompt: Text("Optional"))
                            SecureField("Password", text: $model.sipPassword)
                        case .exotel:
                            TextField("Account SID", text: $model.exotelAccountSID)
                            SecureField("API key", text: $model.exotelAPIKey)
                            SecureField("API token", text: $model.exotelAPIToken)
                            Picker("API host", selection: $model.exotelSubdomain) {
                                Text("Choose").tag("")
                                ForEach(AgentsSchema.choices(AgentsOp.importPhoneNumber, "api_subdomain"), id: \.self) { Text($0).tag($0) }
                            }
                            TextField("App ID", text: $model.exotelAppID)
                        }
                        Toggle("Answer incoming calls", isOn: $model.importInbound)
                        Toggle("Place outgoing calls", isOn: $model.importOutbound)
                    }
                    .formStyle(.columns)
                    AgentsHeldCreateNotice(holds: model.calls.holds, operationID: AgentsOp.importPhoneNumber)
                    AgentsRunButton(runner: runner, title: "Import…", disabled: model.importBody() == nil
                                        || model.calls.holds.notice(AgentsOp.importPhoneNumber) != nil) {
                        Task { await model.importNumberNow() }
                    }
                    AgentsRunnerOutput(runner: runner, showsResult: false)
                }
                .padding(.top, 6)
            }
        }
    }
}

private struct AgentWhatsAppCard: View {
    @Bindable var model: AgentPhoneNumbersModel

    var body: some View {
        let calls = model.calls
        AgentsCard("WhatsApp", subtitle: "WhatsApp Business numbers connected to ElevenLabs: which agent answers, and messages or calls an agent starts.") {
            DisclosureGroup("Show WhatsApp", isExpanded: $model.showsWhatsApp) {
                VStack(alignment: .leading, spacing: 10) {
                    AgentsListBody(model.whatsApp, runner: calls.runner(AgentsOp.listWhatsAppAccounts),
                                   empty: "No WhatsApp accounts. Connect one in the ElevenLabs dashboard first.") { account in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("\(account.number) · \(account.name)").font(.callout)
                                if account.tokenExpired { AgentsBadge(text: "Token expired", color: .red) }
                                Spacer()
                                Button("Remove…") { Task { await model.deleteWhatsApp(account) } }.buttonStyle(.link)
                            }
                            HStack(spacing: 10) {
                                Picker("Agent", selection: Binding(
                                    get: { account.agentID ?? "" },
                                    set: { id in
                                        let name = id.isEmpty ? "no agent" : "“\(model.store.directory.agentName(id))”"
                                        Task { await model.updateWhatsApp(account, changes: ["assigned_agent_id": id.isEmpty ? .null : .string(id)],
                                                                          what: "WhatsApp messages and calls to \(account.number) will be handled by \(name).") }
                                    }
                                )) {
                                    Text("No agent").tag("")
                                    ForEach(model.store.directory.agents.items) { Text($0.name).tag($0.id) }
                                }
                                .fixedSize()
                                toggle("Messages", account.messaging, account, key: "enable_messaging")
                                toggle("Voice replies", account.audioReplies, account, key: "enable_audio_message_response")
                                toggle("Typing", account.typingIndicator, account, key: "enable_typing_indicator")
                            }
                            .font(.caption)
                            AgentsRunnerOutput(runner: calls.runner(AgentsOp.updateWhatsAppAccount, slot: account.id), showsResult: false)
                        }
                    }
                    AgentsRunnerOutput(runner: calls.runner(AgentsOp.deleteWhatsAppAccount), showsResult: false)
                    Divider()
                    Text("Message or call someone").font(.subheadline.weight(.medium))
                    Form {
                        Picker("From", selection: $model.whatsAppAccountID) {
                            Text("Choose an account").tag("")
                            ForEach(model.whatsApp.items) { Text($0.number).tag($0.id) }
                        }
                        AgentsAgentPicker(directory: model.store.directory, selection: $model.whatsAppAgentID)
                        TextField("WhatsApp user", text: $model.whatsAppRecipient, prompt: Text("15550100"))
                        TextField("Language", text: $model.whatsAppLanguage, prompt: Text("en"))
                        TextField("Message template", text: $model.whatsAppTemplate, prompt: Text("order_update"))
                        LabeledContent("Template text values") {
                            TextEditor(text: $model.whatsAppBodyParameters)
                                .font(.callout)
                                .frame(minHeight: 40)
                                .overlay { RoundedRectangle(cornerRadius: 5).stroke(.separator) }
                        }
                        TextField("Call permission template", text: $model.whatsAppPermissionTemplate, prompt: Text("For calls"))
                    }
                    .formStyle(.columns)
                    AgentsSendButton(runner: calls.runner(AgentsOp.whatsAppMessage), guardian: model.whatsAppMessageGuard,
                                     title: "Send message…", disabled: model.whatsAppMessageArguments() == nil,
                                     note: "Billed per message.") {
                        Task { await model.sendWhatsAppMessage() }
                    }
                    AgentsSendButton(runner: calls.runner(AgentsOp.whatsAppCall), guardian: model.whatsAppCallGuard,
                                     title: "Call…", disabled: model.whatsAppCallArguments() == nil) {
                        Task { await model.placeWhatsAppCall() }
                    }
                    AgentsRunnerOutput(runner: calls.runner(AgentsOp.whatsAppMessage), showsResult: true)
                    AgentsRunnerOutput(runner: calls.runner(AgentsOp.whatsAppCall), showsResult: true)
                }
                .padding(.top, 6)
            }
        }
        .task(id: model.showsWhatsApp) {
            if model.showsWhatsApp {
                await model.whatsApp.loadIfNeeded()
                await model.store.directory.agents.loadIfNeeded()
            }
        }
    }

    private func toggle(_ title: String, _ value: Bool, _ account: AgentsWhatsAppAccount, key: String) -> some View {
        Toggle(title, isOn: Binding(
            get: { value },
            set: { on in
                Task { await model.updateWhatsApp(account, changes: [key: .bool(on)],
                                                  what: "\(title) will be turned \(on ? "on" : "off") for \(account.number).") }
            }
        ))
        .toggleStyle(.checkbox)
    }
}
