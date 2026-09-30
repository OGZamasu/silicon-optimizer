import Foundation
import Testing
@testable import SiliconElevenLabs
@testable import SiliconUI

/// Members & sharing: every change to membership or access is a real-world question that
/// names who it affects and sends nothing when declined; invitations go singly or in bulk;
/// shares name their target the way the spec takes it; sign-in connections are built per
/// kind; the audit log pages.
@Suite("ElevenLabs workspace section")
@MainActor
struct VoicesStudioWorkspaceTests {

    static let member: JSONValue = ["user_id": "u2", "email": "sam@example.com", "first_name": "Sam",
                                    "seat_type": "workspace_member", "is_owner": false, "is_locked": false]

    @Test func invitationsGoOneByOneOrInBulkAndNameEveryone() async throws {
        let fixture = VoicesStudioFixture()
        defer { fixture.clean() }
        let model = WorkspaceSectionModel(environment: fixture.environment)
        model.inviteEmails = "sam@example.com"
        model.inviteSeat = "workspace_lite_member"
        model.inviteUsageLimit = "5000"
        let single = model.inviteCall()
        #expect(single.operationID == "invite_user")
        #expect(single.arguments == ["email": "sam@example.com", "seat_type": "workspace_lite_member", "usage_limit": 5000])
        #expect(fixture.client.validate(single.operationID, arguments: single.arguments).isEmpty)

        model.inviteEmails = "sam@example.com, kim@example.com"
        model.inviteGroups = ["g1"]
        let bulk = model.inviteCall()
        #expect(bulk.operationID == "invite_users_bulk")
        #expect(bulk.arguments["emails"] == ["sam@example.com", "kim@example.com"])
        #expect(bulk.arguments["group_ids"] == ["g1"])
        #expect(fixture.client.validate(bulk.operationID, arguments: bulk.arguments).isEmpty)

        let asked = try await voicesStudioConfirm(model.actions.runner("invite_users_bulk"), answer: false) {
            await model.invite()
        }
        #expect(asked?.risk == .realWorld)
        #expect(asked?.title == "Send invitations to 2 people (sam@example.com, kim@example.com)?")
        #expect(asked?.consequence.contains("verified domain") == true)
        #expect(asked?.consequence.contains("lite member seat") == true)
        #expect(fixture.transport.recorded.isEmpty)

        model.inviteEmails = "not-an-address"
        model.inviteUsageLimit = "-3"
        #expect(model.inviteCall().problems == ["“not-an-address” is not an email address.",
                                                "The monthly credit limit must be a whole number, 0 or more."])
    }

    @Test func changingASeatOrLockingSomeoneNamesThem() async throws {
        let fixture = VoicesStudioFixture([
            "update_workspace_member": [.json(["status": "ok"])],
            "get_workspace_members": [.json([Self.member])],
        ])
        defer { fixture.clean() }
        let model = WorkspaceSectionModel(environment: fixture.environment)
        let member = try #require(WorkspaceMember(json: Self.member))
        model.load(members: [member])
        model.seatEdits[member.id] = "workspace_admin"
        let asked = try await voicesStudioAsk(model.actions, answer: true) { await model.changeSeat(member) }
        #expect(asked?.title == "Give sam@example.com a workspace admin seat?")
        #expect(fixture.body("update_workspace_member") == ["email": "sam@example.com", "workspace_seat_type": "workspace_admin"])
        #expect(model.seatEdits[member.id] == nil)

        let lock = try await voicesStudioAsk(model.actions, answer: false) { await model.setLocked(member, true) }
        #expect(lock?.consequence.contains("can no longer use this workspace") == true)
        #expect(fixture.sent("update_workspace_member").count == 1)
    }

    @Test func aShareNamesAGroupAKeyAnEmailOrEveryone() throws {
        let fixture = VoicesStudioFixture()
        defer { fixture.clean() }
        let model = WorkspaceSectionModel(environment: fixture.environment)
        let resource = try #require(WorkspaceResource(json: [
            "resource_id": "voice1", "resource_name": "Narrator", "resource_type": "voice", "creator_user_id": "u1",
            "anonymous_access_level_override": "viewer", "role_to_group_ids": ["admin": ["g1"]],
            "share_options": [["name": "Editors", "id": "g2", "type": "group"], ["name": "CI key", "id": "k1", "type": "key"],
                              ["name": "Kim Lee", "id": "u3", "type": "user"]],
        ]))
        model.load(resource: resource)
        model.shareTarget = "g2"
        #expect(model.targetArguments() == ["group_id": "g2"])
        #expect(model.targetName == "the group “Editors”")
        model.shareTarget = "default"
        #expect(model.targetArguments() == ["group_id": "default"])
        #expect(model.targetName == "every member of the workspace")
        model.shareKeyID = "k1"
        #expect(model.targetArguments() == ["workspace_api_key_id": "k1"])
        model.shareEmail = "lee@example.com"
        #expect(model.targetArguments() == ["user_email": "lee@example.com"])
        var arguments = model.targetArguments()
        arguments["resource_id"] = "voice1"
        arguments["resource_type"] = "voice"
        arguments["role"] = "editor"
        #expect(fixture.client.validate("share_resource_endpoint", arguments: arguments).isEmpty)
    }

    @Test func groupsAreReadFromAnyShapeTheUntypedAnswerTakes() throws {
        let fixture = VoicesStudioFixture()
        defer { fixture.clean() }
        let model = WorkspaceSectionModel(environment: fixture.environment)
        model.take(groups: ["groups": [["id": "g1", "name": "Editors", "members_emails": ["kim@example.com"]]]])
        #expect(model.groups.map(\.name) == ["Editors"])
        model.take(groups: ["g2": ["name": "Voice team", "members": [["email": "sam@example.com"]]]])
        #expect(model.groups.first?.id == "g2")
        #expect(model.groups.first?.members == ["sam@example.com"])
        model.take(groups: ["unexpected": true])
        #expect(model.groups.isEmpty)
        #expect(model.groupsAnswer == ["unexpected": true])
    }

    @Test func aSignInConnectionIsBuiltForItsKindAndDeletingSaysWhatUsesIt() async throws {
        let fixture = VoicesStudioFixture()
        defer { fixture.clean() }
        let model = WorkspaceSectionModel(environment: fixture.environment)
        #expect(model.createKinds.map(\.authType).contains("bearer_auth"))
        let form = try #require(model.connectionForm("create_auth_connection", authType: "bearer_auth"))
        for node in form.nodes where node.field.required {
            if case .text = node.field.kind { node.text = node.field.name == "name" ? "Search API" : "value-for-test" }
        }
        model.newConnectionType = "bearer_auth"
        let built = try #require(model.createConnectionArguments())
        #expect(built.problems.isEmpty)
        #expect(built.arguments["auth_type"] == "bearer_auth")
        #expect(fixture.client.validate("create_auth_connection", arguments: built.arguments).isEmpty)

        let connection = try #require(WorkspaceAuthConnection(json: [
            "id": "ac1", "name": "Search API", "auth_type": "bearer_auth", "used_by": ["agent1", "tool2"], "status": "active",
        ]))
        #expect(model.canEdit(connection))
        let asked = try await voicesStudioConfirm(model.actions.runner("delete_auth_connection"), answer: false) {
            await model.deleteConnection(connection)
        }
        #expect(asked?.title == "Delete the sign-in connection “Search API”?")
        #expect(asked?.consequence.contains("2 agents or tools use it") == true)
        #expect(fixture.transport.recorded.isEmpty)
    }

    @Test func theAuditLogFiltersAndPages() async throws {
        let entry: (String) -> JSONValue = { id in
            ["id": .string(id), "time_dt": "2026-09-28T12:00:00Z", "activity_name": "Voice Created", "class_name": "Resource Change",
             "activity_id": 1, "status_id": 1, "actor": ["user": ["email_addr": "sam@example.com"]], "message": "Created a voice",
             "type_uid": 1, "type_name": "x"]
        }
        let fixture = VoicesStudioFixture(["get_workspace_audit_logs": [
            .json(["entries": [entry("e1")], "has_more": true, "next_cursor": "c2"]),
            .json(["entries": [entry("e2")], "has_more": false, "next_cursor": ""]),
        ]])
        defer { fixture.clean() }
        let model = WorkspaceSectionModel(environment: fixture.environment)
        model.auditActivity = "Voice Created"
        await model.refreshAudit()
        #expect(fixture.query("get_workspace_audit_logs").contains { $0 == ("activity_name", "Voice Created") })
        #expect(model.auditHasMore)
        await model.moreAudit()
        #expect(fixture.query("get_workspace_audit_logs").contains { $0 == ("cursor", "c2") })
        #expect(model.audit.map(\.id) == ["e1", "e2"])
        #expect(model.audit.first?.actor == "sam@example.com")
        #expect(!model.auditHasMore)
    }
}
