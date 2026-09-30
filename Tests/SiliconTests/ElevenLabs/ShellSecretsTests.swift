import AppKit
import Foundation
import SwiftUI
import Testing
import SiliconElevenLabs
@testable import SiliconUI

/// Secrets in forms: secret fields are typed hidden, header maps get hidden values, and nothing
/// typed is echoed in Show API call. And the client's refusals — a path value with a slash, a
/// masked value sent back — land beside the field they name.
@Suite("ElevenLabs secrets and refusals")
@MainActor
struct ShellSecretsTests {

    // MARK: - Forms

    /// Every secret-looking request field in the spec is either treated as a secret or
    /// reviewed as not one — so a spec refresh that adds a `*_token` field fails here.
    @Test func everySecretLookingRequestFieldIsReviewed() {
        let notSecrets: Set<String> = [
            "api_key_id", "api_key_name", "workspace_api_key_id", "auth", "auth_connection",
            "auth_connection_id", "auth_resolved_params", "auth_type", "author", "basic_auth_in_header",
            "credentials", "enable_auth", "max_tokens", "next_page_token", "secret_id",
            "token_response_field", "token_type", "token_url",
        ]
        let pattern = try! NSRegularExpression(pattern: "secret|password|passphrase|token|private_key|api_key|authorization|client_key|auth|credential|hmac")
        var unreviewed: Set<String> = []
        for operation in ElevenLabsCatalog.all {
            for field in Self.allFields(ElevenLabsFormField.fields(for: operation)) {
                let name = field.name.lowercased()
                guard pattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil else { continue }
                if ElevenLabsFormField.secretFieldNames.contains(name) || notSecrets.contains(name) { continue }
                unreviewed.insert(name)
            }
        }
        #expect(unreviewed.isEmpty, "not reviewed as secret or not: \(unreviewed.sorted())")
    }

    @Test func secretTextFieldsAreMarkedAndHeaderMapsGetTheirOwnEditor() throws {
        var secretNames: Set<String> = []
        var headerMaps = 0
        for operation in ElevenLabsCatalog.all {
            for field in Self.allFields(ElevenLabsFormField.fields(for: operation)) {
                if case .text = field.kind, ElevenLabsFormField.secretFieldNames.contains(field.name.lowercased()) {
                    #expect(field.isSecret, "\(operation.id): \(field.id)")
                    secretNames.insert(field.name)
                }
                if case .headerMap = field.kind {
                    headerMaps += 1
                    #expect(ElevenLabsFormField.headerMapFieldNames.contains(field.name))
                }
            }
        }
        #expect(secretNames.isSuperset(of: ["client_secret", "password"]))
        #expect(headerMaps > 0)

        let secret = try #require(ElevenLabsCatalog.operation("create_secret_route"))
        let value = try #require(ElevenLabsFormField.fields(for: secret).first { $0.name == "value" })
        #expect(value.isSecret)
        let tts = try #require(ElevenLabsCatalog.operation("text_to_speech_full"))
        #expect(!ElevenLabsFormField.fields(for: tts).contains { $0.isSecret })
    }

    @Test func aHeaderMapIsRowsOfNamesAndHiddenValues() {
        let field = ElevenLabsFormField(
            id: "body.request_headers", name: "request_headers", location: .body, title: "Request headers",
            description: "", required: false, nullable: false, deprecated: false, defaultValue: nil, examples: [],
            kind: .headerMap, constraints: .init(), isSecret: true
        )
        let node = ElevenLabsFormNode(field: field)
        var problems: [String] = []
        #expect(node.value(path: "request_headers", problems: &problems) == nil)
        node.addHeader()
        node.headerEntries[0].name = "Authorization"
        node.headerEntries[0].value = "Bearer typed-value"
        node.addHeader()
        #expect(node.value(path: "request_headers", problems: &problems) == ["Authorization": "Bearer typed-value"])
        #expect(problems.isEmpty)
        #expect(node.holdsTypedSecret)

        node.load(["X-One": "1", "X-Two": "2"])
        #expect(node.headerEntries.map(\.name) == ["X-One", "X-Two"])
        node.load(["X-Ref": ["secret_id": "s1"]])
        #expect(node.editsAsJSON)
    }

    /// What was typed into a secret is not in "Show API call": the client masks it in its
    /// description, and curl is built from that.
    @Test func aTypedSecretIsNotEchoedInShowAPICall() async throws {
        let fixture = ShellExplorerTests.Fixture()
        defer { fixture.clean() }
        let runner = try #require(ElevenLabsRunner(operationID: "create_secret_route", context: fixture.context))
        let running = Task { await runner.perform(arguments: ["type": "new", "name": "db", "value": "hunter2-typed"]) }
        try await ShellExplorerTests.waitUntil { runner.phase == .awaitingConfirmation || runner.phase == .failed }
        let call = try #require(runner.apiCall)
        let shownBody = call.body?.jsonString() ?? ""
        #expect(!shownBody.contains("hunter2-typed"))
        #expect(shownBody.contains(ElevenLabsRedaction.placeholder))
        #expect(!ElevenLabsCurl.command(for: call).contains("hunter2-typed"))
        runner.decline()
        _ = await running.value
        #expect(fixture.transport.requests.isEmpty)
    }

    // MARK: - Refusals beside their field

    @Test func aSlashInAPathValueIsNamedBesideItsField() async throws {
        let fixture = ShellExplorerTests.Fixture()
        defer { fixture.clean() }
        let explorer = ElevenLabsExplorerModel(context: fixture.context)
        let session = try #require(explorer.session(for: "text_to_speech_full"))
        let voice = try #require(session.form.nodes.first { $0.field.name == "voice_id" })
        voice.text = "../other"
        session.form.nodes.first { $0.field.name == "text" }?.text = "Hi"
        #expect(!session.form.check())
        #expect(session.form.problems(for: voice).first?.contains("may not contain “/”") == true)

        // The client's own refusal, for arguments that skipped the form, lands there too.
        await session.runner.perform(arguments: ["voice_id": "a/b", "text": "Hi"])
        #expect(session.runner.phase == .failed)
        session.form.setProblems(session.runner.problems)
        #expect(!session.form.problems(for: voice).isEmpty, "\(session.runner.problems)")
        #expect(fixture.transport.requests.isEmpty)
    }

    @Test func aMaskedValueSentBackIsNamedBesideItsField() async throws {
        let fixture = ShellExplorerTests.Fixture()
        defer { fixture.clean() }
        let explorer = ElevenLabsExplorerModel(context: fixture.context)
        let session = try #require(explorer.session(for: "text_to_speech_full"))
        let text = try #require(session.form.nodes.first { $0.field.name == "text" })
        session.form.nodes.first { $0.field.name == "voice_id" }?.text = "v1"
        text.text = "Say \(ElevenLabsRedaction.placeholder)"
        #expect(!session.form.check())
        #expect(session.form.problems(for: text).first?.contains("still holds") == true)

        await session.runner.perform(arguments: ["voice_id": "v1", "text": .string("Say \(ElevenLabsRedaction.placeholder)")])
        session.form.setProblems(session.runner.problems)
        #expect(!session.form.problems(for: text).isEmpty, "\(session.runner.problems)")
        #expect(fixture.transport.requests.isEmpty)
    }

    @Test func nestedProblemsFindTheirTopLevelField() {
        let form = ElevenLabsFormModel(operation: ShellInterfaceTests.speechLike)
        let settings = form.nodes.first { $0.field.name == "voice_settings" }!
        form.setProblems([#""voice_settings.stability" must be at most 1"#, "voice_settings.style must be a number."])
        #expect(form.problems(for: settings).count == 2)
        #expect(form.problems(for: form.nodes.first { $0.field.name == "text" }!).isEmpty)
    }

    // MARK: - Helpers

    static func allFields(_ fields: [ElevenLabsFormField]) -> [ElevenLabsFormField] {
        fields.flatMap { field -> [ElevenLabsFormField] in
            switch field.kind {
            case .object(let children): [field] + allFields(children)
            case .list(let item): [field] + allFields([item])
            case .variants(let variants): [field] + allFields(variants.map(\.field))
            default: [field]
            }
        }
    }
}
