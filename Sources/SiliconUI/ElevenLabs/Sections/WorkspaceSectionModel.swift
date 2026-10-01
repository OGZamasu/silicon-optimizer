import Foundation
import Observation
import SiliconElevenLabs

// MARK: - Data

struct WorkspaceMember: Identifiable, Hashable, Sendable {
    var id: String
    var email: String
    var firstName: String
    var seatType: String
    var isOwner: Bool
    var isLocked: Bool

    init?(json: JSONValue) {
        guard let email = json["email"].stringValue else { return nil }
        id = json["user_id"].stringValue ?? email
        self.email = email
        firstName = json["first_name"].stringValue ?? ""
        seatType = json["seat_type"].stringValue ?? ""
        isOwner = json["is_owner"].boolValue ?? false
        isLocked = json["is_locked"].boolValue ?? false
    }
}

struct WorkspaceGroup: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var members: [String]

    init?(json: JSONValue) {
        guard let id = json["id"].stringValue ?? json["group_id"].stringValue else { return nil }
        self.id = id
        name = json["name"].stringValue ?? id
        members = (json["members_emails"].arrayValue ?? json["members"].arrayValue ?? [])
            .compactMap { $0.stringValue ?? $0["email"].stringValue }
    }
}

/// A sign-in connection agents and tools use to reach another service.
struct WorkspaceAuthConnection: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var authType: String
    var provider: String?
    var status: String?
    var statusDetail: String?
    var usedBy: Int

    init?(json: JSONValue) {
        guard let id = json["id"].stringValue else { return nil }
        self.id = id
        name = json["name"].stringValue ?? id
        authType = json["auth_type"].stringValue ?? "?"
        provider = json["provider"].stringValue
        status = json["status"].stringValue
        statusDetail = json["status_detail"].stringValue
        usedBy = json["used_by"].arrayValue?.count ?? 0
    }
}

/// Who a resource is shared with.
struct WorkspaceResource: Hashable, Sendable {
    struct Target: Identifiable, Hashable, Sendable {
        var id: String
        var name: String
        var type: String
    }

    var id: String
    var name: String
    var type: String
    /// Role → group ids holding it.
    var roles: [String: [String]]
    var shareOptions: [Target]

    init?(json: JSONValue) {
        guard let id = json["resource_id"].stringValue else { return nil }
        self.id = id
        name = json["resource_name"].stringValue ?? id
        type = json["resource_type"].stringValue ?? ""
        roles = (json["role_to_group_ids"].objectValue ?? [:]).mapValues { $0.arrayValue?.compactMap(\.stringValue) ?? [] }
        shareOptions = (json["share_options"].arrayValue ?? []).compactMap { option in
            guard let id = option["id"].stringValue else { return nil }
            return Target(id: id, name: option["name"].stringValue ?? id, type: option["type"].stringValue ?? "")
        }
    }
}

struct WorkspaceAuditEntry: Identifiable, Hashable, Sendable {
    var id: String
    var time: String
    var activity: String
    var className: String?
    var actor: String?
    var message: String
    var failed: Bool

    init?(json: JSONValue) {
        guard let id = json["id"].stringValue else { return nil }
        self.id = id
        time = json["time_dt"].stringValue ?? ""
        activity = json["activity_name"].stringValue ?? ""
        className = json["class_name"].stringValue
        let user = json["actor"]["user"]
        actor = user["email_addr"].stringValue ?? user["name"].stringValue ?? json["actor"]["app_name"].stringValue
        message = json["message"].stringValue ?? ""
        failed = json["status_id"].intValue == 2
    }
}

/// One kind of sign-in connection: a shape of the create (or update) body's union, told apart
/// by its `auth_type` constant.
struct WorkspaceAuthKind: Identifiable, Hashable, Sendable {
    var authType: String
    var schema: JSONValue
    var id: String { authType }

    static func kinds(of operationID: String) -> [WorkspaceAuthKind] {
        guard let body = ElevenLabsCatalog.operation(operationID)?.body else { return [] }
        let shape = JSONSchema.unwrapNullable(body.schema)
        return (shape["anyOf"].arrayValue ?? shape["oneOf"].arrayValue ?? []).compactMap { variant in
            guard let type = variant["properties"]["auth_type"]["const"].stringValue else { return nil }
            return WorkspaceAuthKind(authType: type, schema: variant)
        }
    }

    func operation(from base: ElevenLabsOperation) -> ElevenLabsOperation {
        var narrowed = base
        narrowed.body = ElevenLabsBody(contentType: .json, required: true, schema: schema, fileFields: [])
        return narrowed
    }
}

// MARK: - Model

/// Members & sharing: who is in the workspace and with which seat, invitations, groups, who a
/// resource is shared with, the sign-in connections agents use, and the audit log. Everything
/// that changes membership or access reaches people outside this screen, so it asks first.
@MainActor
@Observable
final class WorkspaceSectionModel {

    enum Tab: String, CaseIterable, Identifiable {
        case members, invites, groups, sharing, connections, audit
        var id: String { rawValue }
        var title: String {
            switch self {
            case .members: "Members"
            case .invites: "Invites"
            case .groups: "Groups"
            case .sharing: "Sharing"
            case .connections: "Sign-in connections"
            case .audit: "Audit log"
            }
        }
    }

    let actions: VoicesStudioActions
    var tab: Tab = .members

    // Members
    private(set) var members: [WorkspaceMember] = []
    private(set) var loadedMembers = false
    var seatEdits: [String: String] = [:]

    // Invites
    var inviteEmails = ""
    var inviteSeat = ""
    var inviteGroups: Set<String> = []
    var inviteUsageLimit = ""
    var withdrawEmail = ""
    private(set) var inviteProblems: [String] = []

    // Groups
    private(set) var groups: [WorkspaceGroup] = []
    private(set) var groupsAnswer: JSONValue?
    var groupSearch = ""
    var memberEmail: [String: String] = [:]

    // Sharing
    var resourceID = ""
    var resourceType = ""
    /// The resource last looked up, with the id and kind it was asked by.
    private var loadedResource: (id: String, type: String, resource: WorkspaceResource)?
    /// The resource named by the id and kind in the fields now — never another one's, shown
    /// under these while they are still being looked up.
    var resource: WorkspaceResource? {
        guard let loadedResource, loadedResource.id == resourceID.trimmingCharacters(in: .whitespaces),
              loadedResource.type == resourceType else { return nil }
        return loadedResource.resource
    }
    var shareRole = ""
    var shareTarget = ""
    var shareEmail = ""
    var shareKeyID = ""

    // Connections
    private(set) var connections: [WorkspaceAuthConnection] = []
    var newConnectionType = ""
    @ObservationIgnored private var forms: [String: ElevenLabsFormModel] = [:]
    private(set) var editingConnection: WorkspaceAuthConnection?

    // Audit
    private(set) var audit: [WorkspaceAuditEntry] = []
    @ObservationIgnored private var auditCursor: String?
    private(set) var auditHasMore = false
    var auditActivity = ""
    var auditClass = ""

    init(environment: VoicesStudioEnvironment) {
        actions = VoicesStudioActions(context: environment.context)
        actions.readsShownInPlace = ["get_workspace_members", "get_groups_endpoint", "search_groups", "list_auth_connections", "get_workspace_audit_logs"]
    }

    // MARK: Spec

    static let controls: [VoicesStudioControl] = [
        .init("update_workspace_member", "email"),
        .init("update_workspace_member", "workspace_seat_type", enumerated: true),
        .init("update_workspace_member", "is_locked"),
        .init("invite_user", "email"),
        .init("invite_user", "seat_type", enumerated: true),
        .init("invite_user", "group_ids"),
        .init("invite_user", "usage_limit"),
        .init("invite_users_bulk", "emails"),
        .init("invite_users_bulk", "seat_type", enumerated: true),
        .init("invite_users_bulk", "group_ids"),
        .init("invite_users_bulk", "usage_limit"),
        .init("delete_invite", "email"),
        .init("search_groups", "name"),
        .init("add_member", "group_id"),
        .init("add_member", "email"),
        .init("remove_member", "group_id"),
        .init("remove_member", "email"),
        .init("get_resource_metadata", "resource_id"),
        .init("get_resource_metadata", "resource_type", enumerated: true),
        .init("share_resource_endpoint", "resource_type", enumerated: true),
        .init("share_resource_endpoint", "role", enumerated: true),
        .init("share_resource_endpoint", "group_id", describedValues: ["default"]),
        .init("share_resource_endpoint", "user_email"),
        .init("share_resource_endpoint", "workspace_api_key_id"),
        .init("unshare_resource_endpoint", "group_id"),
        .init("unshare_resource_endpoint", "user_email"),
        .init("unshare_resource_endpoint", "workspace_api_key_id"),
        .init("create_auth_connection", "auth_type"),
        .init("create_auth_connection", "name"),
        .init("update_auth_connection", "auth_connection_id"),
        .init("delete_auth_connection", "auth_connection_id"),
        .init("get_workspace_audit_logs", "limit"),
        .init("get_workspace_audit_logs", "cursor"),
        .init("get_workspace_audit_logs", "activity_name"),
        .init("get_workspace_audit_logs", "class_name"),
    ]

    static let callsWithoutControls: Set<String> = ["get_workspace_members", "get_groups_endpoint", "list_auth_connections"]
    static let explorerOnly: [String: String] = [:]

    var seatTypes: [String] { VoicesStudioSchema.choices("invite_user", "seat_type") }
    var resourceTypes: [String] { VoicesStudioSchema.choices("get_resource_metadata", "resource_type") }
    var roles: [String] { VoicesStudioSchema.choices("share_resource_endpoint", "role") }

    // MARK: Members

    func refreshMembers() async {
        guard let json = await actions.perform("get_workspace_members", quietly: true)?.voicesStudioJSON else { return }
        members = (json.arrayValue ?? json["members"].arrayValue ?? []).compactMap(WorkspaceMember.init(json:))
        loadedMembers = true
    }

    func memberArguments(_ member: WorkspaceMember, seat: String? = nil, locked: Bool? = nil) -> [String: JSONValue] {
        var arguments: [String: JSONValue] = ["email": .string(member.email)]
        if let seat { arguments["workspace_seat_type"] = .string(seat) }
        if let locked { arguments["is_locked"] = .bool(locked) }
        return arguments
    }

    func changeSeat(_ member: WorkspaceMember) async {
        guard let seat = seatEdits[member.id], seat != member.seatType else { return }
        guard await actions.perform(
            "update_workspace_member", memberArguments(member, seat: seat),
            subject: "\(member.email)'s seat to \(VoicesStudioFormat.words(seat))",
            question: VoicesStudioQuestion(
                "Give \(member.email) a \(VoicesStudioFormat.words(seat).lowercased()) seat?", button: "Change seat",
                consequence: "\(member.email) gets what a \(VoicesStudioFormat.words(seat).lowercased()) seat allows, "
                    + "from now on."
            )
        ) != nil else { return }
        seatEdits[member.id] = nil
        // The member holds the seat sent from now on: the row says so at once, so its picker does
        // not start from the seat before (picking that one to go back would look like no change).
        if let index = members.firstIndex(where: { $0.id == member.id }) { members[index].seatType = seat }
        await refreshMembers()
    }

    func setLocked(_ member: WorkspaceMember, _ locked: Bool) async {
        guard await actions.perform(
            "update_workspace_member", memberArguments(member, locked: locked),
            subject: locked ? "\(member.email) out of the workspace" : "\(member.email) back into the workspace",
            question: locked
                ? VoicesStudioQuestion("Lock \(member.email) out of the workspace?", button: "Lock out",
                                       consequence: "\(member.email) can no longer use this workspace until unlocked.")
                : VoicesStudioQuestion("Let \(member.email) back into the workspace?", button: "Unlock",
                                       consequence: "\(member.email) can use this workspace again.")
        ) != nil else { return }
        if let index = members.firstIndex(where: { $0.id == member.id }) { members[index].isLocked = locked }
        await refreshMembers()
    }

    // MARK: Invites

    /// One address goes through the single invite; several through the bulk one.
    func inviteCall() -> (operationID: String, arguments: [String: JSONValue], problems: [String]) {
        let emails = VoicesStudioFormat.list(inviteEmails)
        var problems: [String] = []
        if emails.isEmpty { problems.append("Give at least one email address.") }
        for email in emails where !email.contains("@") { problems.append("“\(email)” is not an email address.") }
        var arguments: [String: JSONValue] = [:]
        arguments.voicesStudioSet("seat_type", VoicesStudioFormat.text(inviteSeat))
        if !inviteGroups.isEmpty { arguments["group_ids"] = .array(inviteGroups.sorted().map(JSONValue.string)) }
        let limit = inviteUsageLimit.trimmingCharacters(in: .whitespaces)
        if !limit.isEmpty {
            if let value = Int(limit), value >= 0 { arguments["usage_limit"] = .number(Double(value)) } else {
                problems.append("The monthly credit limit must be a whole number, 0 or more.")
            }
        }
        if emails.count == 1 {
            arguments["email"] = .string(emails[0])
            return ("invite_user", arguments, problems)
        }
        arguments["emails"] = .array(emails.map(JSONValue.string))
        return ("invite_users_bulk", arguments, problems)
    }

    func invite() async {
        let call = inviteCall()
        inviteProblems = call.problems
        guard call.problems.isEmpty else { return }
        let emails = VoicesStudioFormat.list(inviteEmails)
        let subject = emails.count == 1 ? "an invitation to \(emails[0])"
            : "invitations to \(emails.count) people (\(emails.joined(separator: ", ")))"
        guard await actions.perform(
            call.operationID, call.arguments, subject: subject,
            consequence: "An email goes to \(emails.count == 1 ? emails[0] : "each of them") inviting them to join this "
                + "workspace\(inviteSeat.isEmpty ? "" : " with a \(VoicesStudioFormat.words(inviteSeat).lowercased()) seat")"
                + ", using one of your seats."
                + (emails.count > 1 ? " Every address must be in a verified domain of the workspace." : "")
        ) != nil else { return }
        inviteEmails = ""
        inviteUsageLimit = ""
        inviteGroups = []
    }

    func withdrawInvite() async {
        let email = withdrawEmail.trimmingCharacters(in: .whitespaces)
        guard !email.isEmpty,
              await actions.perform(
                "delete_invite", ["email": .string(email)], subject: "the invitation to \(email)",
                consequence: "The invitation sent to \(email) stops working."
              ) != nil else { return }
        withdrawEmail = ""
    }

    // MARK: Groups

    func refreshGroups() async {
        guard let json = await actions.perform("get_groups_endpoint", quietly: true)?.voicesStudioJSON else { return }
        take(groups: json)
    }

    /// The groups answer has no fixed shape in the spec: a list, a `groups` list, or a map by id.
    func take(groups json: JSONValue) {
        let list = json.arrayValue ?? json["groups"].arrayValue
            ?? json.objectValue.map { $0.compactMap { key, value -> JSONValue? in
                guard var entry = value.objectValue else { return nil }
                if entry["id"] == nil { entry["id"] = .string(key) }
                return .object(entry)
            } } ?? []
        groups = list.compactMap(WorkspaceGroup.init(json:)).sorted { $0.name < $1.name }
        groupsAnswer = groups.isEmpty && json != .null ? json : nil
    }

    func searchGroups() async {
        let name = groupSearch.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty,
              let json = await actions.perform("search_groups", ["name": .string(name)], quietly: true)?.voicesStudioJSON
        else { return }
        groups = (json.arrayValue ?? []).compactMap(WorkspaceGroup.init(json:))
        groupsAnswer = nil
    }

    func addMember(to group: WorkspaceGroup) async {
        let email = (memberEmail[group.id] ?? "").trimmingCharacters(in: .whitespaces)
        guard !email.isEmpty,
              await actions.perform(
                "add_member", ["group_id": .string(group.id), "email": .string(email)],
                subject: "\(email) to the group “\(group.name)”",
                question: VoicesStudioQuestion(
                    "Add \(email) to the group “\(group.name)”?", button: "Add to group",
                    consequence: "\(email) gets everything shared with “\(group.name)”."
                )
              ) != nil else { return }
        memberEmail[group.id] = ""
        await refreshGroups()
    }

    func removeMember(_ email: String, from group: WorkspaceGroup) async {
        guard await actions.perform(
            "remove_member", ["group_id": .string(group.id), "email": .string(email)],
            subject: "\(email) from the group “\(group.name)”",
            question: VoicesStudioQuestion(
                "Take \(email) out of the group “\(group.name)”?", button: "Remove from group",
                consequence: "\(email) loses what they could reach only through “\(group.name)”."
            )
        ) != nil else { return }
        await refreshGroups()
    }

    // MARK: Sharing

    func loadResource() async {
        let id = resourceID.trimmingCharacters(in: .whitespaces)
        let type = resourceType
        guard !id.isEmpty, !resourceType.isEmpty,
              let json = await actions.perform(
                "get_resource_metadata", ["resource_id": .string(id), "resource_type": .string(type)], quietly: true
              )?.voicesStudioJSON else { return }
        loadedResource = WorkspaceResource(json: json).map { (id, type, $0) }
    }

    /// Who a share names: a user or service account by email, a group (or `default`, every
    /// member), or a workspace API key by id — whichever the owner picked or typed.
    ///
    /// A share option's `name` is "The name of the principal", not an address, so users and
    /// service accounts are named by the email typed for them and keys by the key id typed;
    /// the list offers only groups (and `default`), whose ids it does carry.
    func targetArguments() -> [String: JSONValue] {
        let email = shareEmail.trimmingCharacters(in: .whitespaces)
        let key = shareKeyID.trimmingCharacters(in: .whitespaces)
        if !email.isEmpty, !key.isEmpty { return [:] }  // two targets: `shareProblem` says so
        if !email.isEmpty { return ["user_email": .string(email)] }
        if !key.isEmpty { return ["workspace_api_key_id": .string(key)] }
        if shareTarget == "default" { return ["group_id": "default"] }
        guard let target = groupOptions.first(where: { $0.id == shareTarget }) else { return [:] }
        return ["group_id": .string(target.id)]
    }

    /// Why nothing can be shared or unshared as the fields stand, when that is so.
    var shareProblem: String? {
        let email = shareEmail.trimmingCharacters(in: .whitespaces)
        let key = shareKeyID.trimmingCharacters(in: .whitespaces)
        if !email.isEmpty, !key.isEmpty {
            return "Share with an email or with a key id, not both — clear one of them."
        }
        return nil
    }

    /// The groups a resource can be shared with, from its share options.
    var groupOptions: [WorkspaceResource.Target] { resource?.shareOptions.filter { $0.type == "group" } ?? [] }

    var targetName: String {
        let email = shareEmail.trimmingCharacters(in: .whitespaces)
        if !email.isEmpty { return email }
        let key = shareKeyID.trimmingCharacters(in: .whitespaces)
        if !key.isEmpty { return "the API key \(key)" }
        if shareTarget == "default" { return "every member of the workspace" }
        return groupOptions.first { $0.id == shareTarget }.map { "the group “\($0.name)”" } ?? "?"
    }

    func share() async {
        guard let resource, !shareRole.isEmpty else { return }
        var arguments = targetArguments()
        guard !arguments.isEmpty else { return }
        arguments["resource_id"] = .string(resource.id)
        arguments["resource_type"] = .string(resource.type)
        arguments["role"] = .string(shareRole)
        guard await actions.perform(
            "share_resource_endpoint", arguments, subject: "“\(resource.name)” with \(targetName)",
            question: VoicesStudioQuestion(
                "Share “\(resource.name)” with \(targetName) as \(shareRole)?", button: "Share",
                consequence: "\(targetName.prefix(1).uppercased() + targetName.dropFirst()) gets the \(shareRole) role on “\(resource.name)”."
            )
        ) != nil, self.resource?.id == resource.id else { return }
        await loadResource()
    }

    func unshare() async {
        guard let resource else { return }
        var arguments = targetArguments()
        guard !arguments.isEmpty else { return }
        arguments["resource_id"] = .string(resource.id)
        arguments["resource_type"] = .string(resource.type)
        guard await actions.perform(
            "unshare_resource_endpoint", arguments, subject: "“\(resource.name)” from \(targetName)",
            question: VoicesStudioQuestion(
                "Stop sharing “\(resource.name)” with \(targetName)?", button: "Stop sharing",
                consequence: "\(targetName.prefix(1).uppercased() + targetName.dropFirst()) loses the access to “\(resource.name)” this share gave."
            )
        ) != nil, self.resource?.id == resource.id else { return }
        await loadResource()
    }

    // MARK: Sign-in connections

    func refreshConnections() async {
        guard let json = await actions.perform("list_auth_connections", quietly: true)?.voicesStudioJSON else { return }
        connections = (json["auth_connections"].arrayValue ?? []).compactMap(WorkspaceAuthConnection.init(json:))
    }

    var createKinds: [WorkspaceAuthKind] { WorkspaceAuthKind.kinds(of: "create_auth_connection") }

    /// The form for a kind of connection — create, or update when editing one of that kind.
    func connectionForm(_ operationID: String, authType: String) -> ElevenLabsFormModel? {
        let key = "\(operationID)/\(authType)"
        if let existing = forms[key] { return existing }
        guard let base = ElevenLabsCatalog.operation(operationID),
              let kind = WorkspaceAuthKind.kinds(of: operationID).first(where: { $0.authType == authType }) else { return nil }
        let operation = kind.operation(from: base)
        let names = Set(ElevenLabsFormField.fields(for: operation).map(\.name)).subtracting(["auth_connection_id"])
        let made = ElevenLabsFormModel(operation: operation, only: names)
        forms[key] = made
        return made
    }

    /// The new connection's arguments: the form's fields and the kind it was chosen as — the
    /// `auth_type` constant is not required in every shape, so the form alone would leave it out.
    func createConnectionArguments() -> (arguments: [String: JSONValue], problems: [String])? {
        let type = newConnectionType.isEmpty ? (createKinds.first?.authType ?? "") : newConnectionType
        guard let form = connectionForm("create_auth_connection", authType: type) else { return nil }
        var built = form.arguments()
        built.arguments["auth_type"] = .string(type)
        return (built.arguments, built.problems)
    }

    func createConnection() async {
        let type = newConnectionType.isEmpty ? (createKinds.first?.authType ?? "") : newConnectionType
        guard let form = connectionForm("create_auth_connection", authType: type),
              let built = createConnectionArguments() else { return }
        form.setProblems(built.problems)
        guard built.problems.isEmpty else { return }
        let name = built.arguments["name"]?.stringValue ?? type
        guard await actions.perform(
            "create_auth_connection", built.arguments, subject: "a sign-in connection “\(name)”",
            question: VoicesStudioQuestion(
                "Create the sign-in connection “\(name)”?", button: "Create connection",
                consequence: "Agents and tools in this workspace can sign in to another service with these credentials."
            )
        ) != nil else { return }
        form.reset()
        await refreshConnections()
    }

    func edit(_ connection: WorkspaceAuthConnection?) {
        // Whatever was typed into an edit form — a secret included — does not outlive it.
        if let previous = editingConnection {
            forms["update_auth_connection/\(previous.authType)"]?.reset()
        }
        editingConnection = connection
    }

    var canEdit: (WorkspaceAuthConnection) -> Bool {
        { connection in WorkspaceAuthKind.kinds(of: "update_auth_connection").contains { $0.authType == connection.authType } }
    }

    func updateConnection() async {
        guard let connection = editingConnection,
              let form = connectionForm("update_auth_connection", authType: connection.authType) else { return }
        var built = form.arguments()
        form.setProblems(built.problems)
        guard built.problems.isEmpty else { return }
        built.arguments["auth_connection_id"] = .string(connection.id)
        built.arguments["auth_type"] = .string(connection.authType)
        guard await actions.perform(
            "update_auth_connection", built.arguments, subject: "the sign-in connection “\(connection.name)”",
            question: VoicesStudioQuestion(
                "Change the sign-in connection “\(connection.name)”?", button: "Save connection",
                consequence: connection.usedBy > 0
                    ? "The \(connection.usedBy) agents or tools that use it sign in with the new settings from now on."
                    : "Agents and tools that use it later sign in with the new settings."
            )
        ) != nil else { return }
        // Close the editor only if it is still this connection's: another one's (whose form may
        // be the same kind's) keeps what the owner typed there.
        if editingConnection?.id == connection.id { edit(nil) }
        await refreshConnections()
    }

    func deleteConnection(_ connection: WorkspaceAuthConnection) async {
        guard await actions.perform(
            "delete_auth_connection", ["auth_connection_id": .string(connection.id)],
            subject: "the sign-in connection “\(connection.name)”",
            consequence: connection.usedBy > 0
                ? "\(connection.usedBy) agents or tools use it and will no longer be able to sign in."
                : "Nothing in the workspace uses it."
        ) != nil else { return }
        if editingConnection?.id == connection.id { edit(nil) }
        await refreshConnections()
    }

    // MARK: Audit log

    func auditArguments(cursor: String?) -> [String: JSONValue] {
        var arguments: [String: JSONValue] = ["limit": 50]
        arguments.voicesStudioSet("activity_name", VoicesStudioFormat.text(auditActivity))
        arguments.voicesStudioSet("class_name", VoicesStudioFormat.text(auditClass))
        arguments.voicesStudioSet("cursor", cursor.map(JSONValue.string))
        return arguments
    }

    func refreshAudit() async {
        guard let json = await actions.perform("get_workspace_audit_logs", auditArguments(cursor: nil), quietly: true)?
            .voicesStudioJSON else { return }
        audit = (json["entries"].arrayValue ?? []).compactMap(WorkspaceAuditEntry.init(json:))
        auditCursor = json["next_cursor"].stringValue
        auditHasMore = json["has_more"].boolValue == true && auditCursor?.isEmpty == false
    }

    func moreAudit() async {
        guard auditHasMore, let cursor = auditCursor,
              let json = await actions.perform("get_workspace_audit_logs", auditArguments(cursor: cursor), quietly: true)?
                .voicesStudioJSON else { return }
        audit += (json["entries"].arrayValue ?? []).compactMap(WorkspaceAuditEntry.init(json:))
        auditCursor = json["next_cursor"].stringValue
        auditHasMore = json["has_more"].boolValue == true && auditCursor?.isEmpty == false
    }

    /// Loads what the tab on screen shows, the first time it is shown.
    func loadTab() async {
        switch tab {
        case .members where !loadedMembers: await refreshMembers()
        case .invites, .groups: if groups.isEmpty { await refreshGroups() }
        case .connections where connections.isEmpty: await refreshConnections()
        case .audit where audit.isEmpty: await refreshAudit()
        default: break
        }
    }

    // MARK: Test support

    func load(members: [WorkspaceMember] = [], groups: [WorkspaceGroup] = [], resource: WorkspaceResource? = nil,
              connections: [WorkspaceAuthConnection] = [], audit: [WorkspaceAuditEntry] = []) {
        self.members = members
        loadedMembers = true
        self.groups = groups
        if let resource {
            resourceID = resource.id
            resourceType = resource.type
            loadedResource = (resource.id, resource.type, resource)
        } else {
            loadedResource = nil
        }
        self.connections = connections
        self.audit = audit
    }
}
