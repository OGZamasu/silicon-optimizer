import Foundation
import Observation
import SiliconElevenLabs
import SwiftUI

/// Batch calling: an agent phones (or WhatsApps) a list of people. Submitting a batch and
/// retrying one place real calls to real people, billed by the minute — so the confirmation
/// says how many recipients, which agent, from which number, and when, before anything is sent.
/// Also: the batches so far, each with its recipients and their outcomes, cancel, export and
/// delete.
struct AgentBatchCallsSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        AgentBatchCallsScreen(model: AgentsPlatformStore.shared(for: app).batchCalls)
    }
}

struct AgentBatchCallsScreen: View {
    @Bindable var model: AgentBatchCallsModel

    var body: some View {
        ElevenLabsSectionPage(.agentBatchCalls, accessory: {
            HStack(spacing: 8) {
                AgentsRefreshButton(list: model.list, help: "Fetch the batches again")
                Button {
                    model.composing = true
                } label: {
                    Label("New batch", systemImage: "plus")
                }
            }
        }) {
            if model.composing {
                AgentBatchComposer(model: model)
            }
            AgentsMasterDetail(masterWidth: 300) {
                AgentsCard("Batches") {
                    AgentsAgentPicker(directory: model.store.directory, selection: $model.filterAgentID, noneTitle: "All agents")
                        .font(.caption)
                        .fixedSize()
                        .onChange(of: model.filterAgentID) { Task { await model.list.refresh() } }
                    AgentsListBody(model.list, runner: model.calls.runner(AgentsOp.listBatches),
                                   empty: "No batches yet.") { batch in
                        AgentsRow(selected: model.selectedID == batch.id) {
                            Task { await model.select(batch.id) }
                        } content: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(batch.name).lineLimit(1)
                                    Spacer(minLength: 4)
                                    AgentsBadge(text: AgentsFormat.words(batch.status), color: AgentsBadge.color(forStatus: batch.status))
                                }
                                Text("\(batch.agentName) · \(batch.finished) of \(batch.scheduled) done · \(AgentsFormat.date(batch.scheduledAt ?? batch.createdAt))")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
            } detail: {
                if let batch = model.batch {
                    AgentBatchDetail(model: model, batch: batch)
                } else {
                    AgentsCard("No batch selected") {
                        AgentsEmptyState(title: "Choose a batch",
                                         message: "See each recipient's call, cancel what has not been placed, retry the calls that failed, or export the results.",
                                         systemImage: "phone.arrow.up.right")
                    }
                }
            }
        }
        .task { await model.list.loadIfNeeded() }
    }
}

// MARK: - Recipients

/// One person a batch will call, as read from the owner's list.
struct AgentsBatchRecipientDraft: Hashable, Sendable {
    var phoneNumber: String?
    var whatsAppUserID: String?
    /// The other columns, as the agent's dynamic variables.
    var variables: [String: String]

    var json: JSONValue {
        var object: [String: JSONValue] = [:]
        if let phoneNumber { object["phone_number"] = .string(phoneNumber) }
        if let whatsAppUserID { object["whatsapp_user_id"] = .string(whatsAppUserID) }
        if !variables.isEmpty {
            object["conversation_initiation_client_data"] = [
                "dynamic_variables": .object(variables.mapValues(JSONValue.string)),
            ]
        }
        return .object(object)
    }
}

/// Reads a recipient list: CSV with a header row (a `phone_number` or `whatsapp_user_id`
/// column, every other column a dynamic variable), or simply one number per line.
enum AgentsBatchRecipients {
    struct Parsed: Equatable, Sendable {
        var recipients: [AgentsBatchRecipientDraft]
        /// Lines that could not be used, with why — nothing is sent while there are any.
        var problems: [String]
        var duplicates: Int
    }

    /// The most problems listed one by one; past this the list says how many more.
    static let problemLimit = 20

    /// The spec's limit on recipients in one batch.
    static var recipientLimit: Int {
        AgentsSchema.schema(AgentsOp.submitBatch, "recipients").map(JSONSchema.unwrapNullable)?["maxItems"].intValue ?? 10_000
    }

    static func parse(_ text: String, whatsApp: Bool) -> Parsed {
        // Line numbers count every line, blank ones too, so a problem points where the owner looks.
        let numbered = text.components(separatedBy: .newlines).enumerated()
            .map { (number: $0.offset + 1, text: $0.element) }
            .filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let first = numbered.first else { return Parsed(recipients: [], problems: [], duplicates: 0) }
        // Column names are matched without regard to case but kept as written: an agent's
        // prompt says {{FirstName}}, not {{firstname}}.
        let header = fields(first.text)
        let key = whatsApp ? "whatsapp_user_id" : "phone_number"
        var recipients: [AgentsBatchRecipientDraft] = []
        var problems: [String] = []
        var seen = Set<String>()
        var duplicates = 0

        func add(_ address: String, variables: [String: String], line: Int) {
            guard let cleaned = whatsApp ? normalizedWhatsApp(address) : normalizedPhone(address),
                  isValid(cleaned, whatsApp: whatsApp) else {
                problems.append("Line \(line): “\(address)” is not a \(whatsApp ? "WhatsApp number" : "phone number").")
                return
            }
            guard seen.insert(cleaned).inserted else {
                duplicates += 1
                return
            }
            recipients.append(AgentsBatchRecipientDraft(
                phoneNumber: whatsApp ? nil : cleaned, whatsAppUserID: whatsApp ? cleaned : nil, variables: variables
            ))
        }

        if let column = header.firstIndex(where: { $0.caseInsensitiveCompare(key) == .orderedSame }) {
            for line in numbered.dropFirst() {
                let values = fields(line.text)
                guard values.indices.contains(column) else {
                    problems.append("Line \(line.number): no \(key) value.")
                    continue
                }
                var variables: [String: String] = [:]
                for (index, name) in header.enumerated() where index != column && values.indices.contains(index) {
                    let value = values[index]
                    if !name.isEmpty, !value.isEmpty { variables[name] = value }
                }
                add(values[column], variables: variables, line: line.number)
            }
        } else if header.count > 1 {
            problems.append("The first line looks like a header but has no “\(key)” column.")
        } else {
            for line in numbered {
                add(line.text.trimmingCharacters(in: .whitespaces), variables: [:], line: line.number)
            }
        }
        if recipients.count > recipientLimit {
            problems.insert("A batch takes at most \(recipientLimit.formatted()) recipients; this list has \(recipients.count.formatted()).", at: 0)
        }
        return Parsed(recipients: recipients, problems: problems, duplicates: duplicates)
    }

    /// The problems as the screen lists them: the first ones, then how many more.
    static func shown(_ problems: [String]) -> [String] {
        guard problems.count > problemLimit else { return problems }
        return Array(problems.prefix(problemLimit)) + ["… and \(problems.count - problemLimit) more lines to fix."]
    }

    /// Characters a written phone number may hold besides its digits.
    private static let phoneFormatting = Set(" -().\u{00A0}")

    /// `+1 (555) 010-0199` → `+15550100199`. Nil for anything but ASCII digits, a leading `+`,
    /// spaces, dashes, dots and brackets — so `²`, full-width digits or `5550100;5550101` are
    /// refused rather than sent.
    static func normalizedPhone(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        var digits = ""
        for (index, character) in trimmed.enumerated() {
            if character.isASCII, character.isNumber {
                digits.append(character)
            } else if character == "+", index == 0 {
                continue
            } else if !phoneFormatting.contains(character) {
                return nil
            }
        }
        return trimmed.hasPrefix("+") ? "+" + digits : digits
    }

    /// A WhatsApp user id: ASCII digits only, formatting allowed as for phone numbers.
    static func normalizedWhatsApp(_ text: String) -> String? {
        normalizedPhone(text).map { $0.filter { $0 != "+" } }
    }

    /// E.164 in shape: an optional `+` and 7 to 15 ASCII digits.
    static func isValid(_ address: String, whatsApp: Bool) -> Bool {
        let body = address.hasPrefix("+") ? address.dropFirst() : Substring(address)
        return (7...15).contains(body.count) && body.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// One CSV line's fields: commas separate, double quotes group, `""` inside quotes is a quote.
    static func fields(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        let characters = Array(line)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if inQuotes {
                if character == "\"" {
                    if index + 1 < characters.count, characters[index + 1] == "\"" {
                        current.append("\"")
                        index += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    current.append(character)
                }
            } else if character == "\"" {
                inQuotes = true
            } else if character == "," {
                fields.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
            index += 1
        }
        fields.append(current.trimmingCharacters(in: .whitespaces))
        return fields
    }
}

// MARK: - View-model

@MainActor
@Observable
final class AgentBatchCallsModel {
    enum Channel: String, CaseIterable, Identifiable {
        case phone = "Phone calls"
        case whatsApp = "WhatsApp calls"
        var id: String { rawValue }
    }

    @ObservationIgnored unowned let store: AgentsPlatformStore
    var calls: AgentsCalls { store.calls }

    var filterAgentID = ""
    let list: AgentsPagedList<AgentsBatchCall>
    private(set) var selectedID: String?
    private(set) var batch: AgentsBatchCall?
    private(set) var recipients: [AgentsBatchRecipient] = []

    // Composer
    var composing = false
    var name = ""
    var agentID = ""
    var channel: Channel = .phone {
        didSet { if channel != oldValue { reparse() } }
    }
    var phoneNumberID = ""
    var whatsAppAccountID = ""
    var whatsAppTemplate = ""
    var whatsAppLanguage = "en"
    /// The pasted or imported list; read into `parsed` as it changes.
    var recipientsText = "" {
        didSet { reparse() }
    }
    var startLater = false
    var startAt = Date().addingTimeInterval(3600)
    var concurrency = 0
    var ringSeconds = 60
    var recordCalls = false
    /// What went wrong reading an imported file.
    private(set) var importProblem: String?
    private(set) var parsed = AgentsBatchRecipients.Parsed(recipients: [], problems: [], duplicates: 0)

    /// Submit's guard: after an unknown outcome no second batch goes out until the owner has
    /// looked at the list.
    let submitGuard = AgentsSendGuard()
    /// Retry's, per batch.
    @ObservationIgnored private var retryGuards: [String: AgentsSendGuard] = [:]

    init(store: AgentsPlatformStore) {
        self.store = store
        let box = AgentsWeakBox<AgentBatchCallsModel>()
        list = AgentsPagedList { cursor in await box.value?.fetchPage(cursor) }
        box.value = self
    }

    private func fetchPage(_ cursor: String?) async -> AgentsPage<AgentsBatchCall>? {
        var arguments: [String: JSONValue] = ["limit": 50]
        if !filterAgentID.isEmpty { arguments["agent_id"] = .string(filterAgentID) }
        if let cursor { arguments["last_doc"] = .string(cursor) }
        guard let json = await calls.json(AgentsOp.listBatches, arguments, quiet: true) else { return nil }
        return AgentsPage(
            items: (json["batch_calls"].arrayValue ?? []).compactMap(AgentsBatchCall.init(json:)),
            cursor: json["next_doc"].stringValue, hasMore: json["has_more"].boolValue
        )
    }

    // MARK: Composing

    private func reparse() {
        parsed = AgentsBatchRecipients.parse(recipientsText, whatsApp: channel == .whatsApp)
    }

    var fromNumber: AgentsPhoneNumber? { store.directory.phoneNumber(phoneNumberID) }

    /// Why Submit is not available yet, in the owner's words; empty when it is.
    var submitProblems: [String] {
        var problems: [String] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("Give the batch a name.") }
        if agentID.isEmpty { problems.append("Choose the agent that will talk.") }
        switch channel {
        case .phone:
            if phoneNumberID.isEmpty { problems.append("Choose the number to call from.") }
        case .whatsApp:
            if whatsAppAccountID.isEmpty { problems.append("Choose the WhatsApp number to call from.") }
            if whatsAppTemplate.trimmingCharacters(in: .whitespaces).isEmpty {
                problems.append("Name the template that asks each recipient for permission to call.")
            }
        }
        if parsed.recipients.isEmpty { problems.append("Add at least one recipient.") }
        problems += parsed.problems
        if startLater, startAt <= now() { problems.append("The start time is in the past.") }
        return problems
    }

    /// Now, for the schedule check; a test pins it.
    @ObservationIgnored var now: () -> Date = Date.init

    func submitArguments() -> [String: JSONValue]? {
        guard submitProblems.isEmpty, submitGuard.canSend else { return nil }
        var arguments: [String: JSONValue] = [
            "call_name": .string(name.trimmingCharacters(in: .whitespaces)),
            "agent_id": .string(agentID),
            "recipients": .array(parsed.recipients.map(\.json)),
        ]
        switch channel {
        case .phone:
            arguments["agent_phone_number_id"] = .string(phoneNumberID)
            var telephony: [String: JSONValue] = ["ringing_timeout_secs": .number(Double(ringSeconds))]
            if recordCalls, fromNumber?.provider == "twilio" { telephony["twilio_call_recording_enabled"] = true }
            arguments["telephony_call_config"] = .object(telephony)
        case .whatsApp:
            arguments["whatsapp_params"] = [
                "whatsapp_phone_number_id": .string(whatsAppAccountID),
                "whatsapp_call_permission_request_template_name": .string(whatsAppTemplate.trimmingCharacters(in: .whitespaces)),
                "whatsapp_call_permission_request_template_language_code": .string(whatsAppLanguage),
            ]
        }
        if startLater { arguments["scheduled_time_unix"] = .number(startAt.timeIntervalSince1970.rounded(.down)) }
        if concurrency > 0 { arguments["target_concurrency_limit"] = .number(Double(concurrency)) }
        return arguments
    }

    /// What the confirmation says: the number of people called, the agent, the number called
    /// from, and when. The pane's question reads "Place <subject>?" with "Call now".
    func submitConfirmation() -> (subject: String, consequence: String) {
        let count = parsed.recipients.count
        let agent = store.directory.agentName(agentID)
        let people = AgentsFormat.count(count, "recipient")
        let kind = channel == .phone ? "real phone call" : "real WhatsApp call"
        let from: String = switch channel {
        case .phone: fromNumber.map { "\($0.displayName) through \($0.providerName)" } ?? "the chosen number"
        case .whatsApp: store.phoneNumbers.whatsApp.item(whatsAppAccountID)?.number ?? "the chosen WhatsApp number"
        }
        let when = startLater
            ? "starting \(startAt.formatted(date: .abbreviated, time: .shortened))"
            : "starting as soon as you confirm"
        let pace = concurrency > 0 ? ", up to \(concurrency) at a time" : ""
        return (
            subject: "\(AgentsFormat.count(count, kind)) with “\(agent)”",
            consequence: "ElevenLabs will call \(people) from \(from), \(when)\(pace). The agent “\(agent)” talks to "
                + "everyone who answers. Every call is a real call to a real person, billed by the minute. "
                + "Once confirmed it cannot be stopped from here; stop the batch from its page."
        )
    }

    /// Submits the batch once. If the outcome is unknown — no answer, a timeout, ElevenLabs
    /// failing — the form is cleared, the list fetched again, and nothing more can be submitted
    /// until the owner says they have looked for the batch there.
    func submit() async {
        guard let arguments = submitArguments() else { return }
        let wording = submitConfirmation()
        let batchName = name.trimmingCharacters(in: .whitespaces)
        let runner = calls.runner(AgentsOp.submitBatch)
        let json = await submitGuard.send(runner: runner, what: "The batch “\(batchName)”",
                                          check: "the batches below for “\(batchName)”") {
            await calls.json(AgentsOp.submitBatch, arguments, title: "Batch “\(batchName)”",
                             subject: wording.subject, consequence: wording.consequence)
        }
        guard let json else {
            if submitGuard.warning != nil {
                clearComposer()
                await list.refresh()
            }
            return
        }
        clearComposer()
        composing = false
        if let batch = AgentsBatchCall(json: json) {
            list.upsert(batch)
            await select(batch.id)
        } else {
            await list.refresh()
        }
    }

    private func clearComposer() {
        recipientsText = ""
        name = ""
    }

    /// Reads a CSV file into the list. UTF-8 first, then Windows-1252 (what Excel often writes);
    /// a file too big or unreadable says so instead of doing nothing.
    func importCSV(_ url: URL) {
        importProblem = nil
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= Self.importLimit else {
            importProblem = "\(url.lastPathComponent) is \(AgentsFormat.bytes(size)); lists up to \(AgentsFormat.bytes(Self.importLimit)) can be imported."
            return
        }
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            recipientsText = text
        } else if let text = try? String(contentsOf: url, encoding: .windowsCP1252) {
            recipientsText = text
            importProblem = "\(url.lastPathComponent) is not UTF-8; it was read as Windows Latin 1. Check names with accents."
        } else {
            importProblem = "\(url.lastPathComponent) could not be read as text."
        }
    }

    static let importLimit = 5 << 20

    // MARK: A batch

    func select(_ id: String) async {
        selectedID = id
        if let known = list.item(id) { batch = known }
        recipients = []
        await reload()
    }

    func reload() async {
        guard let selectedID else { return }
        guard let json = await calls.json(AgentsOp.getBatch, ["batch_id": .string(selectedID)], slot: selectedID, quiet: true),
              self.selectedID == selectedID else { return }
        batch = AgentsBatchCall(json: json)
        recipients = (json["recipients"].arrayValue ?? []).compactMap(AgentsBatchRecipient.init(json:))
        if let batch { list.upsert(batch) }
    }

    /// The recipients a retry would call again, by the last statuses fetched.
    var retryCount: Int { recipients.filter(\.isRetryable).count }

    /// Calls placed yet to finish or not yet placed: what Cancel stops.
    var pendingCount: Int {
        recipients.filter { ["pending", "dispatched", "initiated", "in_progress"].contains($0.status) }.count
    }

    /// Retry's guard for one batch.
    func retryGuard(for id: String) -> AgentsSendGuard {
        if let existing = retryGuards[id] { return existing }
        let made = AgentsSendGuard()
        retryGuards[id] = made
        return made
    }

    func retryConfirmation() -> (subject: String, consequence: String)? {
        guard let batch else { return nil }
        let count = retryCount
        let from = store.directory.phoneNumber(batch.phoneNumberID)?.displayName ?? "the batch's number"
        return (
            subject: "\(AgentsFormat.count(count, "call")) again to recipients of “\(batch.name)” with “\(batch.agentName)”",
            consequence: "ElevenLabs will call again the \(AgentsFormat.count(count, "recipient")) whose calls failed or went "
                + "unanswered (by the statuses on screen), from \(from). The agent “\(batch.agentName)” talks to everyone who "
                + "answers. These are real calls to real people, billed by the minute."
        )
    }

    func retry() async {
        guard let batch, let wording = retryConfirmation() else { return }
        let guardian = retryGuard(for: batch.id)
        let runner = calls.runner(AgentsOp.retryBatch, slot: batch.id)
        let answer = await guardian.send(runner: runner, what: "The retry of “\(batch.name)”",
                                         check: "this batch's recipients") {
            await calls.json(AgentsOp.retryBatch, ["batch_id": .string(batch.id)], slot: batch.id,
                             title: "Retried “\(batch.name)”", subject: wording.subject, consequence: wording.consequence)
        }
        if answer != nil || guardian.warning != nil { await reload() }
    }

    func cancel() async {
        guard let batch else { return }
        let pending = pendingCount
        guard await calls.json(
            AgentsOp.cancelBatch, ["batch_id": .string(batch.id)], slot: batch.id,
            subject: "“\(batch.name)” — stop placing its calls",
            consequence: "ElevenLabs stops the batch: calls not yet placed (\(pending) by the statuses on screen) are not "
                + "placed, and every recipient is marked cancelled. Calls already in progress may finish."
        ) != nil else { return }
        await reload()
    }

    func export() async {
        guard let batch else { return }
        await calls.run(AgentsOp.exportBatch, ["batch_id": .string(batch.id)], slot: batch.id,
                        title: "Results of “\(batch.name)”")
    }

    func delete() async {
        guard let batch else { return }
        guard await calls.json(
            AgentsOp.deleteBatch, ["batch_id": .string(batch.id)], slot: batch.id,
            subject: "the batch “\(batch.name)”",
            consequence: "ElevenLabs deletes the batch and its \(AgentsFormat.count(recipients.count, "recipient record")) for good. "
                + "The conversations stay in history." + (batch.isActive ? " Calls still to be placed will not be." : "")
        ) != nil else { return }
        list.remove(batch.id)
        selectedID = nil
        self.batch = nil
        recipients = []
    }

    static let arguments: [AgentsArgument] = [
        AgentsArgument(AgentsOp.listBatches, "limit"), AgentsArgument(AgentsOp.listBatches, "agent_id"),
        AgentsArgument(AgentsOp.listBatches, "last_doc"),
        AgentsArgument(AgentsOp.submitBatch, "call_name"), AgentsArgument(AgentsOp.submitBatch, "agent_id"),
        AgentsArgument(AgentsOp.submitBatch, "recipients[].phone_number"),
        AgentsArgument(AgentsOp.submitBatch, "recipients[].whatsapp_user_id"),
        AgentsArgument(AgentsOp.submitBatch, "recipients[].conversation_initiation_client_data.dynamic_variables"),
        AgentsArgument(AgentsOp.submitBatch, "agent_phone_number_id"),
        AgentsArgument(AgentsOp.submitBatch, "telephony_call_config.ringing_timeout_secs"),
        AgentsArgument(AgentsOp.submitBatch, "telephony_call_config.twilio_call_recording_enabled"),
        AgentsArgument(AgentsOp.submitBatch, "whatsapp_params.whatsapp_phone_number_id"),
        AgentsArgument(AgentsOp.submitBatch, "whatsapp_params.whatsapp_call_permission_request_template_name"),
        AgentsArgument(AgentsOp.submitBatch, "whatsapp_params.whatsapp_call_permission_request_template_language_code"),
        AgentsArgument(AgentsOp.submitBatch, "scheduled_time_unix"),
        AgentsArgument(AgentsOp.submitBatch, "target_concurrency_limit"),
        AgentsArgument(AgentsOp.getBatch, "batch_id"), AgentsArgument(AgentsOp.retryBatch, "batch_id"),
        AgentsArgument(AgentsOp.cancelBatch, "batch_id"), AgentsArgument(AgentsOp.exportBatch, "batch_id"),
        AgentsArgument(AgentsOp.deleteBatch, "batch_id"),
    ]
}

// MARK: - Views

private struct AgentBatchComposer: View {
    @Bindable var model: AgentBatchCallsModel

    var body: some View {
        let runner = model.calls.runner(AgentsOp.submitBatch)
        let parsed = model.parsed
        AgentsCard("New batch", subtitle: "Every recipient gets a real call from the agent. Nothing is placed until you confirm the count.") {
            Button("Close") { model.composing = false }.buttonStyle(.link)
        } content: {
            Form {
                TextField("Name", text: $model.name, prompt: Text("October renewals"))
                AgentsAgentPicker(directory: model.store.directory, selection: $model.agentID)
                Picker("Channel", selection: $model.channel) {
                    ForEach(AgentBatchCallsModel.Channel.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                switch model.channel {
                case .phone:
                    AgentsPhoneNumberPicker(directory: model.store.directory, selection: $model.phoneNumberID)
                    Stepper("Ring for \(model.ringSeconds) s", value: $model.ringSeconds, in: {
                        let range = AgentsSchema.range(AgentsOp.submitBatch, "telephony_call_config.ringing_timeout_secs", fallback: 1...999)
                        return Int(range.lowerBound)...Int(range.upperBound)
                    }(), step: 5)
                    if model.fromNumber?.provider == "twilio" {
                        Toggle("Record the calls", isOn: $model.recordCalls)
                    }
                case .whatsApp:
                    Picker("From", selection: $model.whatsAppAccountID) {
                        Text("Choose a WhatsApp number").tag("")
                        ForEach(model.store.phoneNumbers.whatsApp.items) { Text($0.number).tag($0.id) }
                    }
                    .task { await model.store.phoneNumbers.whatsApp.loadIfNeeded() }
                    TextField("Permission template", text: $model.whatsAppTemplate, prompt: Text("call_permission"))
                    TextField("Template language", text: $model.whatsAppLanguage, prompt: Text("en"))
                }
                Toggle("Start later", isOn: $model.startLater)
                if model.startLater {
                    DatePicker("Start at", selection: $model.startAt, in: Date()...)
                }
                Stepper(model.concurrency > 0 ? "At most \(model.concurrency) calls at once" : "As many at once as the plan allows",
                        value: $model.concurrency, in: 0...100)
            }
            .formStyle(.columns)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Recipients").font(.subheadline.weight(.medium))
                    Spacer()
                    Button("Import CSV…") {
                        if let url = AgentsFilePicker.choose(types: ["csv", "txt"]).first { model.importCSV(url) }
                    }
                }
                Text(model.channel == .phone
                     ? "One number per line, or CSV with a phone_number column; every other column becomes a dynamic variable for the agent."
                     : "One WhatsApp number per line, or CSV with a whatsapp_user_id column; other columns become dynamic variables.")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $model.recipientsText)
                    .font(.callout.monospaced())
                    .frame(minHeight: 110)
                    .overlay { RoundedRectangle(cornerRadius: 5).stroke(.separator) }
                HStack(spacing: 10) {
                    Label(AgentsFormat.count(parsed.recipients.count, "recipient"), systemImage: "person.2")
                        .font(.callout.weight(.medium))
                    if parsed.duplicates > 0 {
                        Text("\(parsed.duplicates) duplicate\(parsed.duplicates == 1 ? "" : "s") left out").font(.caption).foregroundStyle(.secondary)
                    }
                    if let first = parsed.recipients.first, !first.variables.isEmpty {
                        Text("Variables: \(first.variables.keys.sorted().joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let problem = model.importProblem {
                Label(problem, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
            }
            ElevenLabsProblemList(problems: AgentsBatchRecipients.shown(model.submitProblems))
            AgentsSendButton(runner: runner, guardian: model.submitGuard,
                             title: "Place \(AgentsFormat.count(parsed.recipients.count, "call"))…",
                             disabled: !model.submitProblems.isEmpty) {
                Task { await model.submit() }
            }
            AgentsRunnerOutput(runner: runner, showsResult: false)
        }
    }
}

private struct AgentBatchDetail: View {
    let model: AgentBatchCallsModel
    let batch: AgentsBatchCall

    var body: some View {
        let calls = model.calls
        VStack(alignment: .leading, spacing: 14) {
            AgentsCard(batch.name) {
                Button {
                    Task { await model.reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Fetch the batch again")
                .accessibilityLabel("Fetch the batch again")
            } content: {
                HStack(spacing: 6) {
                    AgentsBadge(text: AgentsFormat.words(batch.status), color: AgentsBadge.color(forStatus: batch.status))
                    if batch.isWhatsApp { AgentsBadge(text: "WhatsApp", color: .green) }
                    if batch.retryCount > 0 { AgentsBadge(text: "Retried \(batch.retryCount)×") }
                }
                AgentsFact(label: "Agent", value: batch.agentName.isEmpty ? model.store.directory.agentName(batch.agentID) : batch.agentName)
                if let number = model.store.directory.phoneNumber(batch.phoneNumberID) {
                    AgentsFact(label: "Calling from", value: number.displayName)
                } else if let provider = batch.provider {
                    AgentsFact(label: "Provider", value: AgentsFormat.words(provider))
                }
                AgentsFact(label: "Starts", value: AgentsFormat.date(batch.scheduledAt))
                AgentsFact(label: "Progress", value: "\(batch.dispatched) placed, \(batch.finished) finished, of \(batch.scheduled)")
                ProgressView(value: Double(batch.finished), total: Double(max(batch.scheduled, 1)))
                AgentsRunnerError(runner: calls.runner(AgentsOp.getBatch, slot: batch.id))
            }
            AgentsCard("Actions") {
                VStack(alignment: .leading, spacing: 10) {
                    if batch.isActive {
                        AgentsRunButton(runner: calls.runner(AgentsOp.cancelBatch, slot: batch.id), title: "Stop the batch…") {
                            Task { await model.cancel() }
                        }
                        AgentsRunnerOutput(runner: calls.runner(AgentsOp.cancelBatch, slot: batch.id))
                    }
                    AgentsSendButton(runner: calls.runner(AgentsOp.retryBatch, slot: batch.id),
                                     guardian: model.retryGuard(for: batch.id),
                                     title: "Call \(AgentsFormat.count(model.retryCount, "recipient")) again…",
                                     disabled: model.retryCount == 0 || batch.isActive,
                                     disabledReason: batch.isActive ? "The batch is still running." : nil) {
                        Task { await model.retry() }
                    }
                    Text("Retry calls the recipients whose calls failed or went unanswered.")
                        .font(.caption).foregroundStyle(.secondary)
                    AgentsRunnerOutput(runner: calls.runner(AgentsOp.retryBatch, slot: batch.id))
                    AgentsRunButton(runner: calls.runner(AgentsOp.exportBatch, slot: batch.id), title: "Export CSV",
                                    disabled: batch.isActive, disabledReason: "Export needs a finished batch.") {
                        Task { await model.export() }
                    }
                    AgentsRunnerOutput(runner: calls.runner(AgentsOp.exportBatch, slot: batch.id), showsResult: true)
                }
            }
            AgentsCard("Recipients", subtitle: AgentsFormat.count(model.recipients.count, "recipient")) {
                let counts = Dictionary(grouping: model.recipients, by: \.status).mapValues(\.count)
                HStack(spacing: 6) {
                    ForEach(counts.keys.sorted(), id: \.self) { status in
                        AgentsBadge(text: "\(AgentsFormat.words(status)) \(counts[status] ?? 0)", color: AgentsBadge.color(forStatus: status))
                    }
                }
                ForEach(model.recipients.prefix(200)) { recipient in
                    HStack {
                        Text(recipient.phoneNumber ?? recipient.whatsAppUserID ?? recipient.id)
                            .font(.callout.monospacedDigit())
                        Spacer()
                        AgentsBadge(text: AgentsFormat.words(recipient.status), color: AgentsBadge.color(forStatus: recipient.status))
                        if let conversation = recipient.conversationID {
                            Button("Conversation") {
                                Task { await model.store.conversations.select(conversation) }
                                model.store.open(.agentConversations)
                            }
                            .buttonStyle(.link)
                            .font(.caption)
                        }
                    }
                }
                if model.recipients.count > 200 {
                    Text("… and \(model.recipients.count - 200) more — export the CSV for all of them.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            AgentsCard("Delete") {
                AgentsRunButton(runner: calls.runner(AgentsOp.deleteBatch, slot: batch.id), title: "Delete the batch…") {
                    Task { await model.delete() }
                }
                AgentsRunnerOutput(runner: calls.runner(AgentsOp.deleteBatch, slot: batch.id))
            }
        }
    }
}
