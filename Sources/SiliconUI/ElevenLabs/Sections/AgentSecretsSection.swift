import Foundation
import Observation
import SiliconElevenLabs
import SwiftUI

/// Workspace secrets tools and MCP servers authenticate with, and environment variables (per
/// environment values, plain or pointing at a secret).
///
/// A secret's value goes one way: typed here, sent to ElevenLabs, never shown again —
/// ElevenLabs does not return it, this app does not keep it, and "Show API call" masks it.
struct AgentSecretsSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        AgentSecretsScreen(model: AgentsPlatformStore.shared(for: app).secrets)
    }
}

struct AgentSecretsScreen: View {
    @Bindable var model: AgentSecretsModel

    var body: some View {
        ElevenLabsSectionPage(.agentSecrets, accessory: {
            AgentsRefreshButton(list: model.list, help: "Fetch the secrets again")
        }) {
            AgentsMasterDetail {
                AgentsCard("Secrets") {
                    AgentsSearchField(prompt: "Names starting with…", text: $model.search) {
                        Task { await model.list.refresh() }
                    }
                    AgentsListBody(model.list, runner: model.calls.runner(AgentsOp.listSecrets),
                                   empty: "No secrets yet.") { secret in
                        AgentsRow(selected: model.selectedID == secret.id) {
                            Task { await model.select(secret.id) }
                        } content: {
                            VStack(alignment: .leading, spacing: 2) {
                                Label(secret.name, systemImage: "key").lineLimit(1)
                                Text(secret.usageSummary).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } detail: {
                VStack(alignment: .leading, spacing: 14) {
                    if let secret = model.selected {
                        AgentSecretDetail(model: model, secret: secret)
                    }
                    AgentSecretComposer(model: model)
                }
            }
            AgentEnvironmentVariablesCard(model: model)
        }
        .task { await model.list.loadIfNeeded() }
    }
}

// MARK: - View-model

@MainActor
@Observable
final class AgentSecretsModel {
    @ObservationIgnored unowned let store: AgentsPlatformStore
    var calls: AgentsCalls { store.calls }

    /// Request fields that carry a secret's value.
    static let secretFields: Set<String> = ["value"]

    var search = ""
    let list: AgentsPagedList<AgentsSecret>
    private(set) var selectedID: String?
    private(set) var detail: AgentsSecret?
    /// Names of the resources using the secret, by kind.
    private(set) var dependencies: [String: [String]] = [:]

    // New secret, or a new value for the selected one
    var newName = ""
    var newValue = ""
    var replaceName = ""
    var replaceValue = ""

    // Environment variables
    let variables: AgentsPagedList<AgentsEnvironmentVariable>
    var variableType = ""
    var newVariableLabel = ""
    var newVariableType = "string"
    /// environment → value (or secret id), production first.
    var newVariableValues: [(environment: String, value: String)] = [("production", "")]
    private(set) var selectedVariableID: String?
    var editedValues: [(environment: String, value: String)] = []
    /// The environments the selected variable had when fetched.
    private(set) var originalEnvironments: Set<String> = []
    /// The variable whose values `editedValues` holds; nil while the selected one's are on their way.
    private(set) var loadedVariableID: String?

    /// Whether the values on screen are the selected variable's: saving waits for them.
    var variableIsLoaded: Bool { selectedVariableID != nil && loadedVariableID == selectedVariableID }

    /// The selected variable's values: in, on their way, or not coming (the error, and how to retry).
    var variableLoad: AgentsDetailLoad {
        .of(loaded: variableIsLoaded,
            runner: selectedVariableID.map { calls.runner(AgentsOp.getEnvironmentVariable, slot: $0) })
    }

    init(store: AgentsPlatformStore) {
        self.store = store
        let box = AgentsWeakBox<AgentSecretsModel>()
        list = AgentsPagedList { cursor in await box.value?.fetchPage(cursor) }
        variables = AgentsPagedList { cursor in await box.value?.fetchVariables(cursor) }
        box.value = self
    }

    private func fetchPage(_ cursor: String?) async -> AgentsPage<AgentsSecret>? {
        var arguments: [String: JSONValue] = ["page_size": 100]
        let search = search.trimmingCharacters(in: .whitespaces)
        if !search.isEmpty { arguments["search"] = .string(search) }
        if let cursor { arguments["cursor"] = .string(cursor) }
        guard let json = await calls.json(AgentsOp.listSecrets, arguments, quiet: true) else { return nil }
        return AgentsPage(
            items: (json["secrets"].arrayValue ?? []).compactMap(AgentsSecret.init(json:)),
            cursor: json["next_cursor"].stringValue
        )
    }

    var selected: AgentsSecret? {
        guard let selectedID else { return nil }
        return detail ?? list.item(selectedID)
    }

    func select(_ id: String) async {
        selectedID = id
        detail = nil
        dependencies = [:]
        replaceName = list.item(id)?.name ?? ""
        replaceValue = ""
        guard let json = await calls.json(AgentsOp.getSecret, ["secret_id": .string(id)], slot: id, quiet: true),
              selectedID == id else { return }
        detail = AgentsSecret(json: json)
        replaceName = detail?.name ?? replaceName
        var found: [String: [String]] = [:]
        for kind in ["tools", "agents", "mcp_servers"] {
            let names = (json["used_by"][kind].arrayValue ?? []).map { $0["name"].stringValue ?? $0["id"].stringValue ?? "?" }
            if !names.isEmpty { found[kind] = names }
        }
        let numbers = (json["used_by"]["phone_numbers"].arrayValue ?? []).map { $0["phone_number"].stringValue ?? "?" }
        if !numbers.isEmpty { found["phone_numbers"] = numbers }
        dependencies = found
    }

    /// More of what uses the secret, one kind at a time.
    func loadDependencies(_ kind: String) async {
        guard let selectedID else { return }
        guard let json = await calls.json(AgentsOp.secretDependencies, [
            "secret_id": .string(selectedID), "resource_type": .string(kind), "page_size": 100,
        ], slot: "\(selectedID)/\(kind)", quiet: true) else { return }
        let items = json["dependencies"].arrayValue ?? json["results"].arrayValue ?? json[kind].arrayValue ?? []
        dependencies[kind] = items.map { $0["name"].stringValue ?? $0["phone_number"].stringValue ?? $0["id"].stringValue ?? "?" }
    }

    func create() async {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !newValue.isEmpty else { return }
        let value = newValue
        guard let json = await calls.json(
            AgentsOp.createSecret, ["type": "new", "name": .string(name), "value": .string(value)],
            title: "New secret “\(name)”", subject: "“\(name)”",
            consequence: "ElevenLabs stores the value in your workspace, where tools and MCP servers you point at it can use it. "
                + "It cannot be read back, here or in ElevenLabs.",
            question: "Store the secret “\(name)” in your workspace?", confirmLabel: "Store secret"
        ) else { return }
        newValue = ""
        newName = ""
        if let secret = AgentsSecret(json: json) {
            list.upsert(secret)
            store.directory.secrets.upsert(secret)
            await select(secret.id)
        } else {
            await list.refresh()
        }
    }

    /// Replaces the selected secret's value (and name).
    func replace() async {
        guard let secret = selected, !replaceValue.isEmpty else { return }
        let name = replaceName.trimmingCharacters(in: .whitespaces).isEmpty ? secret.name : replaceName
        guard await calls.json(
            AgentsOp.updateSecret,
            ["secret_id": .string(secret.id), "type": "update", "name": .string(name), "value": .string(replaceValue)],
            slot: secret.id, subject: "“\(secret.name)” with a new value",
            consequence: "Everything using it — \(secret.usageSummary.lowercased()) — uses the new value from now on. "
                + "The old value is gone.",
            question: "Replace the value of “\(secret.name)”?", confirmLabel: "Replace value"
        ) != nil else { return }
        replaceValue = ""
        await list.refresh()
        await select(secret.id)
    }

    func delete() async {
        guard let secret = selected else { return }
        guard await calls.json(
            AgentsOp.deleteSecret, ["secret_id": .string(secret.id)], slot: secret.id,
            subject: "the secret “\(secret.name)”",
            consequence: secret.usageCount > 0
                ? "\(secret.usageSummary). ElevenLabs refuses to delete a secret that is in use."
                : "ElevenLabs deletes it for good. Nothing uses it."
        ) != nil else { return }
        list.remove(secret.id)
        store.directory.secrets.remove(secret.id)
        guard selectedID == secret.id else { return }
        selectedID = nil
        detail = nil
    }

    // MARK: Environment variables

    private func fetchVariables(_ cursor: String?) async -> AgentsPage<AgentsEnvironmentVariable>? {
        var arguments: [String: JSONValue] = ["page_size": 100]
        if !variableType.isEmpty { arguments["type"] = .string(variableType) }
        if let cursor { arguments["cursor"] = .string(cursor) }
        guard let json = await calls.json(AgentsOp.listEnvironmentVariables, arguments, quiet: true) else { return nil }
        return AgentsPage(
            items: (json["environment_variables"].arrayValue ?? []).compactMap(AgentsEnvironmentVariable.init(json:)),
            cursor: json["next_cursor"].stringValue, hasMore: json["has_more"].boolValue
        )
    }

    func selectVariable(_ id: String) async {
        selectedVariableID = id
        // The previous variable's values never stand in for this one's.
        loadedVariableID = nil
        editedValues = []
        originalEnvironments = []
        guard let json = await calls.json(AgentsOp.getEnvironmentVariable, ["env_var_id": .string(id)], slot: id, quiet: true),
              selectedVariableID == id, let variable = AgentsEnvironmentVariable(json: json) else { return }
        variables.upsert(variable)
        editedValues = Self.editable(json["values"], type: variable.type)
        originalEnvironments = Set(editedValues.map(\.environment))
        loadedVariableID = id
    }

    var selectedVariable: AgentsEnvironmentVariable? {
        selectedVariableID.flatMap { variables.item($0) }
    }

    /// Values as the form edits them: a string, or the secret's / connection's id.
    static func editable(_ values: JSONValue, type: String) -> [(environment: String, value: String)] {
        (values.objectValue ?? [:]).keys.sorted { lhs, rhs in
            lhs == "production" ? true : rhs == "production" ? false : lhs < rhs
        }.map { environment in
            let value = values[environment]
            return (environment, value.stringValue ?? value["secret_id"].stringValue ?? value["auth_connection_id"].stringValue ?? "")
        }
    }

    /// The `values` object for a variable of `type`.
    static func valuesJSON(_ values: [(environment: String, value: String)], type: String) -> JSONValue {
        var object: [String: JSONValue] = [:]
        for (environment, value) in values {
            let environment = environment.trimmingCharacters(in: .whitespaces)
            guard !environment.isEmpty, !value.isEmpty else { continue }
            switch type {
            case "secret": object[environment] = ["secret_id": .string(value)]
            case "auth_connection": object[environment] = ["auth_connection_id": .string(value)]
            default: object[environment] = .string(value)
            }
        }
        return .object(object)
    }

    var newVariableProblems: [String] {
        var problems: [String] = []
        if newVariableLabel.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("Give the variable a label.") }
        if newVariableValues.first(where: { $0.environment == "production" })?.value.isEmpty ?? true {
            problems.append("A variable needs a production value.")
        }
        return problems
    }

    func createVariable() async {
        guard newVariableProblems.isEmpty else { return }
        let body: JSONValue = [
            "label": .string(newVariableLabel.trimmingCharacters(in: .whitespaces)), "type": .string(newVariableType),
            "values": Self.valuesJSON(newVariableValues, type: newVariableType),
        ]
        let label = newVariableLabel.trimmingCharacters(in: .whitespaces)
        guard let json = await calls.json(
            AgentsOp.createEnvironmentVariable, ["body": body], title: "Variable “\(label)”",
            subject: "“\(label)” (\(AgentsFormat.words(newVariableType).lowercased()))",
            consequence: "Tools, MCP servers and agents that refer to {{\(label)}} use these values in "
                + ListFormatter.localizedString(byJoining: newVariableValues.map(\.environment).filter { !$0.isEmpty })
                + " from their next conversation. The values themselves are not shown here again.",
            confirmLabel: "Create variable"
        ) else { return }
        newVariableLabel = ""
        newVariableValues = [("production", "")]
        if let variable = AgentsEnvironmentVariable(json: json) { variables.upsert(variable) } else { await variables.refresh() }
    }

    /// The update's `values`: the edited ones, and null for an environment that was removed or
    /// emptied (the API keeps what a replace leaves out otherwise). Production cannot be removed.
    func editedValuesJSON(for variable: AgentsEnvironmentVariable) -> JSONValue {
        var values = Self.valuesJSON(editedValues, type: variable.type).objectValue ?? [:]
        for environment in originalEnvironments where environment != "production" && values[environment] == nil {
            values[environment] = .null
        }
        return .object(values)
    }

    func saveVariable() async {
        guard variableLoad.isLoaded, let variable = selectedVariable else { return }
        let removed = originalEnvironments.filter { environment in
            environment != "production" && !editedValues.contains { $0.environment == environment && !$0.value.isEmpty }
        }.sorted()
        guard await calls.json(AgentsOp.updateEnvironmentVariable, [
            "env_var_id": .string(variable.id), "values": editedValuesJSON(for: variable),
        ], slot: variable.id, title: "Variable “\(variable.label)”",
           subject: "“\(variable.label)”",
           consequence: "What refers to {{\(variable.label)}} uses the new values from its next conversation."
            + (removed.isEmpty ? "" : " Removed: " + ListFormatter.localizedString(byJoining: removed) + "."),
           confirmLabel: "Save values"
        ) != nil else { return }
        if selectedVariableID == variable.id { await selectVariable(variable.id) }
    }

    static let arguments: [AgentsArgument] = [
        AgentsArgument(AgentsOp.listSecrets, "page_size"), AgentsArgument(AgentsOp.listSecrets, "search"),
        AgentsArgument(AgentsOp.listSecrets, "cursor"), AgentsArgument(AgentsOp.getSecret, "secret_id"),
        AgentsArgument(AgentsOp.secretDependencies, "secret_id"), AgentsArgument(AgentsOp.secretDependencies, "resource_type"),
        AgentsArgument(AgentsOp.secretDependencies, "page_size"),
        AgentsArgument(AgentsOp.createSecret, "type"), AgentsArgument(AgentsOp.createSecret, "name"),
        AgentsArgument(AgentsOp.createSecret, "value"),
        AgentsArgument(AgentsOp.updateSecret, "secret_id"), AgentsArgument(AgentsOp.updateSecret, "type"),
        AgentsArgument(AgentsOp.updateSecret, "name"), AgentsArgument(AgentsOp.updateSecret, "value"),
        AgentsArgument(AgentsOp.deleteSecret, "secret_id"),
        AgentsArgument(AgentsOp.listEnvironmentVariables, "page_size"), AgentsArgument(AgentsOp.listEnvironmentVariables, "type"),
        AgentsArgument(AgentsOp.listEnvironmentVariables, "cursor"),
        AgentsArgument(AgentsOp.getEnvironmentVariable, "env_var_id"),
        AgentsArgument(AgentsOp.createEnvironmentVariable, "label"), AgentsArgument(AgentsOp.createEnvironmentVariable, "type"),
        AgentsArgument(AgentsOp.createEnvironmentVariable, "values"),
        AgentsArgument(AgentsOp.updateEnvironmentVariable, "env_var_id"), AgentsArgument(AgentsOp.updateEnvironmentVariable, "values"),
    ]
}

// MARK: - Views

private struct AgentSecretDetail: View {
    @Bindable var model: AgentSecretsModel
    let secret: AgentsSecret

    var body: some View {
        let calls = model.calls
        AgentsCard(secret.name, subtitle: secret.usageSummary) {
            AgentsFact(label: "Kind", value: AgentsFormat.words(secret.type))
            AgentsFact(label: "ID", value: secret.id, monospaced: true)
            AgentsRunnerError(runner: calls.runner(AgentsOp.getSecret, slot: secret.id))
            ForEach(model.dependencies.keys.sorted(), id: \.self) { kind in
                AgentsFact(label: AgentsFormat.words(kind), value: ListFormatter.localizedString(byJoining: model.dependencies[kind] ?? []))
            }
            if secret.usageCount > 0 {
                Menu("Everything that uses it") {
                    ForEach(AgentsSchema.choices(AgentsOp.secretDependencies, "resource_type"), id: \.self) { kind in
                        Button(AgentsFormat.words(kind)) { Task { await model.loadDependencies(kind) } }
                    }
                }
                .fixedSize()
            }
            Divider()
            Text("Replace the value").font(.subheadline.weight(.medium))
            Form {
                TextField("Name", text: $model.replaceName)
                SecureField("New value", text: $model.replaceValue)
            }
            .formStyle(.columns)
            AgentsRunButton(runner: calls.runner(AgentsOp.updateSecret, slot: secret.id), title: "Replace…",
                            disabled: model.replaceValue.isEmpty) {
                Task { await model.replace() }
            }
            AgentsRunnerOutput(runner: calls.runner(AgentsOp.updateSecret, slot: secret.id))
            Divider()
            AgentsRunButton(runner: calls.runner(AgentsOp.deleteSecret, slot: secret.id), title: "Delete the secret…") {
                Task { await model.delete() }
            }
            AgentsRunnerOutput(runner: calls.runner(AgentsOp.deleteSecret, slot: secret.id))
        }
    }
}

private struct AgentSecretComposer: View {
    @Bindable var model: AgentSecretsModel

    var body: some View {
        let runner = model.calls.runner(AgentsOp.createSecret)
        AgentsCard("New secret", subtitle: "An API key or password a tool or MCP server sends. Once stored it cannot be read back.") {
            Form {
                TextField("Name", text: $model.newName, prompt: Text("crm_api_key"))
                SecureField("Value", text: $model.newValue)
            }
            .formStyle(.columns)
            AgentsRunButton(runner: runner, title: "Store…",
                                disabled: model.newName.trimmingCharacters(in: .whitespaces).isEmpty || model.newValue.isEmpty) {
                Task { await model.create() }
            }
            AgentsRunnerOutput(runner: runner, showsResult: false)
        }
    }
}

private struct AgentEnvironmentVariablesCard: View {
    @Bindable var model: AgentSecretsModel
    @State private var expanded = false

    var body: some View {
        let calls = model.calls
        AgentsCard("Environment variables", subtitle: "Values that differ between environments (production, staging…): plain text, or a pointer to a secret or a sign-in connection.") {
            DisclosureGroup("Show variables", isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Kind", selection: $model.variableType) {
                        Text("All kinds").tag("")
                        ForEach(AgentsSchema.choices(AgentsOp.listEnvironmentVariables, "type"), id: \.self) {
                            Text(AgentsFormat.words($0)).tag($0)
                        }
                    }
                    .fixedSize()
                    .onChange(of: model.variableType) { Task { await model.variables.refresh() } }
                    AgentsListBody(model.variables, runner: calls.runner(AgentsOp.listEnvironmentVariables),
                                   empty: "No environment variables.") { variable in
                        AgentsRow(selected: model.selectedVariableID == variable.id) {
                            Task { await model.selectVariable(variable.id) }
                        } content: {
                            HStack {
                                Text(variable.label).font(.callout.monospaced())
                                AgentsBadge(text: AgentsFormat.words(variable.type))
                                Spacer()
                                Text(variable.values.keys.sorted().joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let variable = model.selectedVariable {
                        Divider()
                        Text("“\(variable.label)” by environment").font(.subheadline.weight(.medium))
                        let load = model.variableLoad
                        AgentsDetailLoadProblem(load: load)
                        valuesEditor($model.editedValues, type: variable.type)
                        AgentsRunButton(runner: calls.runner(AgentsOp.updateEnvironmentVariable, slot: variable.id), title: "Save values…",
                                        disabled: !load.isLoaded, disabledReason: load.reason(waiting: "Waiting for the variable's values.")) {
                            Task { await model.saveVariable() }
                        }
                        AgentsRunnerOutput(runner: calls.runner(AgentsOp.updateEnvironmentVariable, slot: variable.id))
                    }
                    Divider()
                    Text("New variable").font(.subheadline.weight(.medium))
                    HStack {
                        TextField("Label", text: $model.newVariableLabel, prompt: Text("CRM_BASE_URL")).textFieldStyle(.roundedBorder)
                        Picker("Kind", selection: $model.newVariableType) {
                            ForEach(["string", "secret", "auth_connection"], id: \.self) { Text(AgentsFormat.words($0)).tag($0) }
                        }
                        .fixedSize()
                    }
                    valuesEditor($model.newVariableValues, type: model.newVariableType)
                    ElevenLabsProblemList(problems: model.newVariableProblems)
                    AgentsRunButton(runner: calls.runner(AgentsOp.createEnvironmentVariable), title: "Create…",
                                        disabled: !model.newVariableProblems.isEmpty) {
                        Task { await model.createVariable() }
                    }
                    AgentsRunnerOutput(runner: calls.runner(AgentsOp.createEnvironmentVariable), showsResult: false)
                }
                .padding(.top, 6)
            }
        }
        .onChange(of: expanded) {
            if expanded {
                Task {
                    await model.variables.loadIfNeeded()
                    await model.store.directory.secrets.loadIfNeeded()
                }
            }
        }
    }

    private func valuesEditor(_ values: Binding<[(environment: String, value: String)]>, type: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(values.wrappedValue.indices, id: \.self) { index in
                HStack {
                    TextField("Environment", text: Binding(
                        get: { values.wrappedValue[index].environment },
                        set: { values.wrappedValue[index].environment = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 130)
                    .disabled(values.wrappedValue[index].environment == "production")
                    if type == "secret" {
                        Picker("Secret", selection: Binding(
                            get: { values.wrappedValue[index].value },
                            set: { values.wrappedValue[index].value = $0 }
                        )) {
                            Text("Choose a secret").tag("")
                            ForEach(model.store.directory.secrets.items) { Text($0.name).tag($0.id) }
                        }
                        .labelsHidden()
                    } else {
                        TextField(type == "auth_connection" ? "Connection ID" : "Value", text: Binding(
                            get: { values.wrappedValue[index].value },
                            set: { values.wrappedValue[index].value = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                    }
                    if values.wrappedValue[index].environment != "production" {
                        Button {
                            values.wrappedValue.remove(at: index)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove this environment")
                    }
                }
            }
            Button("Add an environment") { values.wrappedValue.append(("", "")) }
                .buttonStyle(.link)
                .font(.caption)
        }
    }
}
