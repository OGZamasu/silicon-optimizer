import Foundation
import Testing
@testable import SiliconControl
@testable import SiliconElevenLabs
@testable import SiliconMCP
@testable import SiliconUI

private typealias ELJSON = SiliconElevenLabs.JSONValue
private typealias MCPJSON = SiliconMCP.JSONValue

/// The whole path an agent's call takes: an MCP tool, over HTTP to the real control server and
/// its caller policy, into the app's handler and its gate, through the real `ElevenLabsClient`
/// — and out to an in-memory transport. No network, no Keychain, no key but a planted one.
@Suite("ElevenLabs control: MCP to the client, end to end")
struct ElevenLabsControlMCPTests {

    static let plantedKey = "sk_" + String(repeating: "e2e0", count: 12)

    /// Every one of the catalog's operations, called through `elevenlabs_call` with arguments
    /// derived from its own schemas (and a file for every upload field), reaches the transport
    /// as its own method and path — with the owner's switch on and `confirm: true`, which is
    /// what the risky ones need.
    @MainActor
    @Test func everyOperationIsReachableThroughElevenLabsCall() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("elevenlabs-control-e2e-\(UUID().uuidString)", isDirectory: true)
        try requireTemporaryDirectory(scratch)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { removeTemporaryDirectory(scratch) }
        do {
            let rig = Rig(allowRisky: true)
            defer { rig.clean() }
            try await withServer(host: ElevenLabsHandlerHost(rig.handler)) { fixture in
                let channel = FixtureChannel(client: fixture.local)
                var reached = 0
                for operation in ElevenLabsCatalog.all {
                    var files: [MCPJSON] = []
                    for field in operation.body?.fileFields ?? [] {
                        let file = scratch.appendingPathComponent("\(operation.id)-\(field).bin")
                        try Data("file for \(field)".utf8).write(to: file)
                        files.append(["field": .string(field), "path": .string(file.path)])
                    }
                    let before = rig.transport.recorded.count
                    let answer: String
                    do {
                        answer = try await ElevenLabsTools.invoke("elevenlabs_call", arguments: [
                            "operation": .string(operation.id),
                            "arguments": try Self.mcp(.object(Self.sampleArguments(operation))),
                            "files": .array(files), "confirm": true,
                        ], channel: channel)
                    } catch {
                        Issue.record("\(operation.id): \(error.localizedDescription)")
                        continue
                    }
                    let recorded = rig.transport.recorded
                    #expect(recorded.count == before + 1, "\(operation.id)")
                    guard let sent = recorded.last?.request, recorded.count == before + 1 else { continue }
                    #expect(sent.operationID == operation.id)
                    #expect(sent.method == operation.method, "\(operation.id)")
                    #expect(Self.matches(sent.url.path(percentEncoded: false), operation.path), "\(operation.id): \(sent.url.path)")
                    #expect(answer.hasPrefix("\(operation.id) (\(operation.method) \(operation.path))"), "\(operation.id)")
                    #expect(!answer.contains(Self.plantedKey))
                    reached += 1
                }
                #expect(reached == ElevenLabsCatalog.all.count)
                #expect(rig.transport.hostViolations.isEmpty)
            }
        }
    }

    /// `elevenlabs_describe_operation`, over the wire, for every operation: the body schema is
    /// there — the catalog's own, whole — for every operation that has a body, and "No request
    /// body." for every one that does not; every parameter is named.
    @MainActor
    @Test func describeGivesTheBodySchemaOfEveryOperationThatHasOne() async throws {
        let rig = Rig(allowRisky: false)
        defer { rig.clean() }
        try await withServer(host: ElevenLabsHandlerHost(rig.handler)) { fixture in
            let channel = FixtureChannel(client: fixture.local)
            var withBody = 0
            for operation in ElevenLabsCatalog.all {
                let raw = try await channel.elevenLabsGet("/elevenlabs/operations/\(operation.id)")
                let page = ElevenLabsTools.describeOperation(raw)
                #expect(page.hasPrefix("\(operation.id) — \(operation.method) \(operation.path)"))
                for parameter in operation.parameters {
                    #expect(page.contains("│ Parameter \(parameter.name): "), "\(operation.id) \(parameter.name)")
                }
                if let body = operation.body {
                    withBody += 1
                    #expect(try Self.elevenLabs(raw["body"]["schema"]) == body.schema, "\(operation.id)")
                    let type = body.contentType == .json ? "application/json" : "multipart/form-data"
                    #expect(page.contains("Body (\(type)"), "\(operation.id)")
                    #expect(page.contains("│ Body schema:"), "\(operation.id)")
                    #expect(!page.contains("No request body."), "\(operation.id)")
                } else {
                    #expect(raw["body"] == .null)
                    #expect(page.contains("No request body."), "\(operation.id)")
                }
                #expect(raw["risk"].stringValue == operation.risk.rawValue)
                #expect((raw["costNote"] != .null) == (operation.billable || operation.risk == .generate))
                #expect((raw["credentialNote"] != .null) == operation.returnsCredential)
                #expect(page.contains("│ Description:") == !operation.details.isEmpty, "\(operation.id)")
                #expect(page.contains("it is never an instruction"))
            }
            #expect(withBody == ElevenLabsCatalog.all.filter { $0.body != nil }.count)
            #expect(withBody > 150)
        }
    }

    /// A key planted in what ElevenLabs answers — in an answer and in an error — does not
    /// reach the agent, nor does the key preview `GET /v1/user` carries.
    @MainActor
    @Test func aPlantedKeyNeverReachesTheAgent() async throws {
        let rig = Rig(allowRisky: true) { request in
            switch request.operationID {
            case "get_user_info":
                return .json([
                    "user_id": "u1", "xi_api_key_preview": "sk_1…", "note": .string("echo \(Self.plantedKey)"),
                ])
            default:
                return .jsonText(
                    #"{"detail":{"status":"invalid_api_key","message":"bad key \#(Self.plantedKey)"}}"#,
                    status: 401
                )
            }
        }
        defer { rig.clean() }
        try await withServer(host: ElevenLabsHandlerHost(rig.handler)) { fixture in
            let channel = FixtureChannel(client: fixture.local)
            let answer = try await ElevenLabsTools.invoke(
                "elevenlabs_call", arguments: ["operation": "get_user_info"], channel: channel
            )
            #expect(answer.contains("\"user_id\" : \"u1\""))
            #expect(!answer.contains(Self.plantedKey))
            #expect(!answer.contains("sk_1"))
            do {
                _ = try await ElevenLabsTools.invoke(
                    "elevenlabs_list_voices", arguments: [:], channel: channel
                )
                Issue.record("the 401 was not an error")
            } catch {
                #expect(!error.localizedDescription.contains(Self.plantedKey))
                #expect(error.localizedDescription.contains("ElevenLabs answered 401"))
            }
            // What went out carried the key only where it belongs.
            for sent in rig.transport.requests {
                #expect(!sent.url.absoluteString.contains(Self.plantedKey))
                #expect(sent.header("xi-api-key") == Self.plantedKey)
            }
        }
    }

    /// The gate over the wire: a risky operation from `elevenlabs_call` without the owner's
    /// switch is a tool error naming the switch, and ElevenLabs never hears of it.
    @MainActor
    @Test func aRiskyCallIsRefusedOverTheWireAndNeverSent() async throws {
        let rig = Rig(allowRisky: false)
        defer { rig.clean() }
        let risky = try #require(ElevenLabsCatalog.all.first { $0.risk == .destructive })
        try await withServer(host: ElevenLabsHandlerHost(rig.handler)) { fixture in
            let channel = FixtureChannel(client: fixture.local)
            do {
                _ = try await ElevenLabsTools.invoke("elevenlabs_call", arguments: [
                    "operation": .string(risky.id),
                    "arguments": try Self.mcp(.object(Self.sampleArguments(risky))), "confirm": true,
                ], channel: channel)
                Issue.record("\(risky.id) ran")
            } catch {
                #expect(error.localizedDescription.contains(ElevenLabsControl.riskySwitch))
                #expect(error.localizedDescription.contains(risky.id))
            }
        }
        #expect(rig.transport.recorded.isEmpty)
    }

    /// The curated tools speak the spec's language: each one's operation is in the catalog,
    /// every argument is one of that operation's parameters, body fields or file fields, and
    /// every field the spec requires is required by the tool, defaulted, or one of a pair.
    @Test func curatedToolsUseTheCatalogsNamesAndCoverWhatItRequires() throws {
        for tool in ElevenLabsTools.curated {
            let operation = try #require(ElevenLabsCatalog.operation(tool.operation), "\(tool.name)")
            let schema = Sample.bodySchema(operation.body?.schema ?? .null)
            let properties = Set(schema["properties"].objectValue?.keys.map { $0 } ?? [])
            let known = Set(operation.parameters.map(\.name)).union(properties)
                .union(operation.body?.fileFields ?? [])
            for argument in tool.arguments {
                #expect(known.contains(argument.name), "\(tool.name).\(argument.name) is not in \(operation.id)")
                if operation.body?.fileFields.contains(argument.name) == true {
                    switch argument.kind {
                    case .path, .paths: break
                    default: Issue.record("\(tool.name).\(argument.name) is a file field but not a path")
                    }
                }
            }
            let required = Set(operation.parameters.filter(\.required).map(\.name))
                .union(operation.body?.requiredFields ?? [])
            let covered = Set(tool.arguments.filter(\.required).map(\.name))
                .union(tool.defaults.keys).union(tool.oneOf ?? [])
            #expect(required.isSubset(of: covered), "\(tool.name) leaves \(required.subtracting(covered).sorted()) to chance")
            // None of them is gated: a curated tool that needed confirm would have no way to give it.
            #expect(!operation.requiresConfirmation, "\(tool.name) maps to a gated operation")
        }
    }

    /// The app's own conformance, wired as it ships: its client, its dated output folder and
    /// media table, its switch. Audio lands in the folder and the pane's recent outputs; a big
    /// answer is saved whole beside it; the gate follows the switch as the owner flips it.
    @MainActor
    @Test func theAppRunsCallsIntoItsOwnOutputFolderAndFollowsItsSwitch() async throws {
        var settings = Settings()
        settings.elevenLabsLinked = true
        let model = AppModel(settings: settings)
        let transport = FakeElevenLabsTransport { request in
            switch request.operationID {
            case "text_to_speech_full":
                return .audio(Data([0x49, 0x44, 0x33, 1]), headers: ["character-cost": "5", "request-id": "r1"])
            case "get_speech_history":
                return .json(["history": .array((0..<3_000).map {
                    ["history_item_id": .string("h\($0)"), "text": .string(String(repeating: "x", count: 100))]
                })])
            default:
                return .json([:])
            }
        }
        model.elevenLabsLink.transport = transport
        model.elevenLabsLink.store = FakeCredentialSource(key: Self.plantedKey)
        model.elevenLabsLink.limits = CoreClientTests.fastLimits
        let folder = model.elevenLabsOutputDirectory
        try requireTemporaryDirectory(folder)
        defer {
            removeTemporaryDirectory(folder)
            transport.removeTemporaryFiles()
        }
        func call(_ operation: String, _ arguments: [String: ELJSON] = [:], confirm: Bool? = nil) async throws -> (Int, ELJSON) {
            var body: [String: ELJSON] = ["operation": .string(operation), "arguments": .object(arguments)]
            if let confirm { body["confirm"] = .bool(confirm) }
            let answer = await model.elevenLabs(.init(route: .call(body: ELJSON.object(body).encoded())))
            return (answer.status, try ELJSON(data: answer.body))
        }

        let status = try JSONDecoder().decode(
            ElevenLabsWire.Status.self, from: await model.elevenLabs(.init(route: .status)).body
        )
        #expect(status.linked && !status.agentsMayRunRiskyActions)

        let (spokeStatus, spoken) = try await call("text_to_speech_full", ["voice_id": "v", "text": "Hi"])
        #expect(spokeStatus == 200)
        let file = try #require(spoken["file"].stringValue)
        #expect(file.hasPrefix(folder.path))
        #expect(spoken["characterCost"] == 5)
        #expect(spoken["costNote"].stringValue?.contains("5 characters") == true)
        #expect(model.elevenLabsRecentOutputs.contains { $0.url.path == file })

        let (historyStatus, history) = try await call("get_speech_history")
        #expect(historyStatus == 200)
        #expect(history["truncated"] == true)
        let whole = try #require(history["fullResult"]["file"].stringValue)
        #expect(whole.hasPrefix(folder.path))
        #expect(try ELJSON(data: Data(contentsOf: URL(fileURLWithPath: whole)))["history"].arrayValue?.count == 3_000)

        let risky = try #require(ElevenLabsCatalog.all.first {
            $0.risk == .destructive && $0.body == nil && $0.parameters.allSatisfy { $0.location == .path }
        })
        let arguments = Self.sampleArguments(risky)
        let before = transport.recorded.count
        #expect(try await call(risky.id, arguments, confirm: true).0 == 403)
        #expect(transport.recorded.count == before)
        model.elevenLabsAllowRiskyForAgents = true
        #expect(try await call(risky.id, arguments, confirm: false).0 == 403)
        #expect(try await call(risky.id, arguments, confirm: true).0 == 200)
        #expect(transport.recorded.count == before + 1)
        #expect(transport.recorded.last?.request.operationID == risky.id)
    }

    /// The gate over the real catalog and client: every destructive and real-world
    /// operation is held with confirm but no switch, and with the switch but no
    /// confirm, and ElevenLabs hears of none of them.
    @Test func everyGatedOperationInTheCatalogIsHeld() async throws {
        // Counted from the catalog: the risk table's own test holds the table to its numbers.
        let gated = ElevenLabsCatalog.all.filter(\.requiresConfirmation)
        #expect(gated.count == ElevenLabsCatalog.all.filter { $0.risk == .destructive || $0.risk == .realWorld }.count)
        #expect(!gated.isEmpty)
        for allowRisky in [false, true] {
            let rig = Rig(allowRisky: allowRisky)
            defer { rig.clean() }
            for operation in gated {
                let body: ELJSON = [
                    "operation": .string(operation.id),
                    "arguments": .object(Self.sampleArguments(operation)),
                    "confirm": .bool(!allowRisky),
                ]
                let answer = await rig.handler.handle(.init(route: .call(body: body.encoded())))
                #expect(answer.status == 403, "\(operation.id) with the switch \(allowRisky ? "on" : "off")")
            }
            #expect(rig.transport.recorded.isEmpty)
        }
    }

    /// Masking over the real catalog's credential fields and the real client: an agent's
    /// shareable token, a single-use token and a new service-account key are masked while
    /// the switch is off (the last two are gated then anyway) and handed over once it is on.
    /// The owner's own key in a webhook tool's headers and the key preview stay masked with the
    /// switch on; other literal header values follow the switch, as the core decides.
    @Test func realCredentialsAreMaskedUntilTheOwnerAllowsThem() async throws {
        let planted = "planted-" + UUID().uuidString
        let reply: @Sendable (ElevenLabsRequest) -> FakeElevenLabsTransport.Reply = { request in
            switch request.operationID {
            case "get_agent_route":
                return .json(["agent_id": "agent_1", "name": "Support",
                              "xi_api_key_preview": "sk_ab…",
                              "platform_settings": ["auth": ["shareable_token": .string(planted)]],
                              "tools": [["type": "webhook", "api_schema": ["request_headers": [
                                  "xi-api-key": .string(Self.plantedKey), "X-Team": "literal-header-value",
                              ]]]],
                              "notes": .string("the owner's key is \(Self.plantedKey)")])
            case "get_single_use_token": return .json(["token": .string(planted)])
            case "create_service_account_api_key": return .json(["xi-api-key": .string(planted), "key_id": "k"])
            default: return CoreConformanceTests.reply(for: request)
            }
        }
        for allowRisky in [false, true] {
            let rig = Rig(allowRisky: allowRisky, reply: reply)
            defer { rig.clean() }
            for id in ["get_agent_route", "get_single_use_token", "create_service_account_api_key"] {
                let operation = try #require(ElevenLabsCatalog.operation(id))
                #expect(operation.returnsCredential, "\(id)")
                let body: ELJSON = [
                    "operation": .string(id), "arguments": .object(Self.sampleArguments(operation)),
                    "confirm": true,
                ]
                let answer = await rig.handler.handle(.init(route: .call(body: body.encoded())))
                let text = String(decoding: answer.body, as: UTF8.self)
                if operation.requiresConfirmation && !allowRisky {
                    #expect(answer.status == 403, "\(id)")
                } else {
                    #expect(answer.status == 200, "\(id): \(text.prefix(200))")
                    #expect(text.contains(planted) == allowRisky, "\(id) with the switch \(allowRisky ? "on" : "off")")
                    if id == "get_agent_route" {
                        // Whatever the switch: never a key, never the preview.
                        #expect(!text.contains(Self.plantedKey), "\(id)")
                        #expect(!text.contains("sk_ab"), "\(id)")
                        #expect(text.contains("literal-header-value") == allowRisky, "\(id)")
                        #expect(text.contains("X-Team"), "\(id): the header's name stays")
                    } else {
                        #expect(text.contains(ElevenLabsRedaction.placeholder) == !allowRisky, "\(id)")
                    }
                }
            }
        }
    }

    /// An upload through the real client: its bytes reach ElevenLabs in the multipart body
    /// under the file's own name, and nothing about where it lives on this Mac does.
    @Test func anUploadReachesElevenLabsAsItsBytesUnderItsOwnName() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("elevenlabs-control-upload-e2e-\(UUID().uuidString)", isDirectory: true)
        try requireTemporaryDirectory(scratch)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { removeTemporaryDirectory(scratch) }
        let audio = scratch.appendingPathComponent("voice memo.wav")
        let bytes = Data("RIFF-\(UUID().uuidString)-WAVE".utf8)
        try bytes.write(to: audio)
        let rig = Rig(allowRisky: false)
        defer { rig.clean() }
        let body: ELJSON = [
            "operation": "audio_isolation", "arguments": [:],
            "files": [["field": "audio", "path": .string(audio.path)]],
        ]
        let answer = await rig.handler.handle(.init(route: .call(body: body.encoded())))
        #expect(answer.status == 200)
        let sent = try #require(rig.transport.recorded.last)
        #expect(sent.request.operationID == "audio_isolation")
        #expect(sent.body.range(of: bytes) != nil)
        let wire = String(decoding: sent.body, as: UTF8.self)
        #expect(wire.contains("name=\"audio\"; filename=\"voice memo.wav\""))
        #expect(!wire.contains(scratch.lastPathComponent))
        #expect(!wire.contains(ElevenLabsControlHandler.stagingPrefix))
        let text = String(decoding: answer.body, as: UTF8.self)
        #expect(!text.contains(scratch.lastPathComponent))
        #expect(try Data(contentsOf: audio) == bytes)
    }

    /// Every curated tool argument against the spec it stands for: its JSON type is one the
    /// spec's schema accepts for that field (a string field is never offered as an object), an
    /// enum it offers is inside the spec's, a range it offers is inside the spec's, and a file
    /// argument is a path — one, or several where the field takes several.
    @Test func curatedArgumentsHaveTheSpecsTypes() throws {
        for tool in ElevenLabsTools.curated {
            let operation = try #require(ElevenLabsCatalog.operation(tool.operation))
            let properties = Sample.bodySchema(operation.body?.schema ?? .null)["properties"].objectValue ?? [:]
            for argument in tool.arguments {
                let label = "\(tool.name).\(argument.name)"
                if let body = operation.body, body.fileFields.contains(argument.name) {
                    switch argument.kind {
                    case .path: #expect(!body.acceptsMultipleFiles(argument.name), "\(label) takes several")
                    case .paths: #expect(body.acceptsMultipleFiles(argument.name), "\(label) takes one")
                    default: Issue.record("\(label) is a file field but not a path")
                    }
                    continue
                }
                let spec = try #require(
                    operation.parameter(named: argument.name)?.schema ?? properties[argument.name], "\(label)"
                )
                let accepted = Self.jsonTypes(spec)
                let offered = try Self.elevenLabs(argument.schema)
                let type = try #require(offered["type"].stringValue, "\(label) offers no single type")
                if !accepted.isEmpty {
                    let fits = accepted.contains(type) || (type == "integer" && accepted.contains("number"))
                    #expect(fits, "\(label) is offered as \(type); the spec takes \(accepted.sorted())")
                }
                let plain = Self.plainVariant(spec)
                if let offeredEnum = offered["enum"].arrayValue, let specEnum = plain["enum"].arrayValue {
                    #expect(Set(offeredEnum).isSubset(of: Set(specEnum)), "\(label) offers values the spec does not")
                }
                if let low = offered["minimum"].doubleValue, let specLow = plain["minimum"].doubleValue {
                    #expect(low >= specLow, "\(label) minimum")
                }
                if let high = offered["maximum"].doubleValue, let specHigh = plain["maximum"].doubleValue {
                    #expect(high <= specHigh, "\(label) maximum")
                }
            }
        }
    }

    /// Every curated tool, every argument filled with a value the spec accepts (an object where
    /// the tool offers one), through the bridge's own body builder and the real client: each is
    /// sent, none refused — and `voice_settings` given as an object reaches ElevenLabs as the
    /// JSON string its multipart field is.
    @Test func everyCuratedToolRunsThroughTheRealClientWithEveryArgument() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("elevenlabs-control-curated-\(UUID().uuidString)", isDirectory: true)
        try requireTemporaryDirectory(scratch)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { removeTemporaryDirectory(scratch) }
        let sample = scratch.appendingPathComponent("sample.wav")
        try Data("RIFF sample WAVE".utf8).write(to: sample)
        let rig = Rig(allowRisky: false)
        defer { rig.clean() }
        for tool in ElevenLabsTools.curated {
            let operation = try #require(ElevenLabsCatalog.operation(tool.operation))
            let properties = Sample.bodySchema(operation.body?.schema ?? .null)["properties"].objectValue ?? [:]
            var arguments: [String: MCPJSON] = [:]
            for argument in tool.arguments {
                if let pair = tool.oneOf, pair.contains(argument.name), argument.name != pair[0] { continue }
                switch argument.kind {
                case .path: arguments[argument.name] = .string(sample.path)
                case .paths: arguments[argument.name] = [.string(sample.path)]
                default:
                    if let choice = argument.choices?.first {
                        arguments[argument.name] = .string(choice)
                    } else if case .jsonText = argument.kind {
                        arguments[argument.name] = ["stability": .number(0.5)]
                    } else {
                        let spec = operation.parameter(named: argument.name)?.schema ?? properties[argument.name] ?? .null
                        arguments[argument.name] = try Self.mcp(Sample.value(for: spec, name: argument.name))
                    }
                }
            }
            let body = try ElevenLabsTools.curatedBody(tool, arguments)
            let before = rig.transport.recorded.count
            let answer = await rig.handler.handle(.init(route: .call(body: try JSONEncoder().encode(body))))
            #expect(answer.status == 200, "\(tool.name): \(String(decoding: answer.body, as: UTF8.self).prefix(300))")
            #expect(rig.transport.recorded.count == before + 1, "\(tool.name)")
            if tool.name == "elevenlabs_change_voice", let sent = rig.transport.recorded.last {
                let wire = String(decoding: sent.body, as: UTF8.self)
                #expect(wire.contains("name=\"voice_settings\"\r\n\r\n{\"stability\":0.5}"), "\(wire.prefix(600))")
            }
        }
    }

    /// The JSON types a schema accepts, through `anyOf`/`oneOf`, leaving out null.
    fileprivate static func jsonTypes(_ schema: ELJSON) -> Set<String> {
        if let type = schema["type"].stringValue { return type == "null" ? [] : [type] }
        if let types = schema["type"].arrayValue { return Set(types.compactMap(\.stringValue)).subtracting(["null"]) }
        let variants = schema["anyOf"].arrayValue ?? schema["oneOf"].arrayValue ?? []
        return variants.reduce(into: Set<String>()) { $0.formUnion(jsonTypes($1)) }
    }

    /// The one non-null variant of an `anyOf`, or the schema itself.
    fileprivate static func plainVariant(_ schema: ELJSON) -> ELJSON {
        let variants = (schema["anyOf"].arrayValue ?? []).filter { $0["type"].stringValue != "null" }
        return variants.count == 1 ? variants[0] : schema
    }

    // MARK: - Samples

    /// Arguments from the operation's own schemas: every path and query parameter, required
    /// headers, and the body's required fields (or one optional one when none is required) —
    /// the core conformance test's recipe.
    fileprivate static func sampleArguments(_ operation: ElevenLabsOperation) -> [String: ELJSON] {
        var arguments: [String: ELJSON] = [:]
        for parameter in operation.parameters where parameter.location != .header || parameter.required {
            arguments[parameter.name] = Sample.value(for: parameter.schema, name: parameter.name)
        }
        if let body = operation.body {
            let schema = Sample.bodySchema(body.schema)
            let properties = schema["properties"].objectValue ?? [:]
            var names = schema["required"].arrayValue?.compactMap(\.stringValue) ?? []
            if names.isEmpty, let first = properties.keys.sorted().first(where: { !body.fileFields.contains($0) }) {
                names = [first]
            }
            for name in names where !body.fileFields.contains(name) {
                arguments[name] = Sample.value(for: properties[name] ?? .null, name: name)
            }
        }
        return arguments
    }

    /// Whether a sent path is the template with its `{parameters}` filled.
    static func matches(_ path: String, _ template: String) -> Bool {
        let sent = path.split(separator: "/", omittingEmptySubsequences: false)
        let shape = template.split(separator: "/", omittingEmptySubsequences: false)
        guard sent.count == shape.count else { return false }
        return zip(sent, shape).allSatisfy { $1.hasPrefix("{") || $0 == $1 }
    }

    fileprivate static func mcp(_ value: ELJSON) throws -> MCPJSON {
        try JSONDecoder().decode(MCPJSON.self, from: value.encoded())
    }

    fileprivate static func elevenLabs(_ value: MCPJSON) throws -> ELJSON {
        try ELJSON(data: JSONEncoder().encode(value))
    }

}

// MARK: - The rig

/// A real client over the in-memory transport, with a planted key, writing into a temporary
/// sink — and the app's handler over it.
private struct Rig {
    let transport: FakeElevenLabsTransport
    let sink = TemporaryFileSink()
    let handler: ElevenLabsControlHandler

    init(
        allowRisky: Bool,
        reply: @escaping @Sendable (ElevenLabsRequest) -> FakeElevenLabsTransport.Reply = {
            CoreConformanceTests.reply(for: $0)
        }
    ) {
        transport = FakeElevenLabsTransport { request in reply(request) }
        let client = ElevenLabsClient(
            credentials: FakeCredentialSource(key: ElevenLabsControlMCPTests.plantedKey),
            region: .global, transport: transport, sink: sink
        )
        handler = ElevenLabsControlHandler(
            state: .init(linked: true, region: .global, allowRiskyForAgents: allowRisky, account: nil),
            backend: client, sink: sink
        )
    }

    func clean() {
        sink.removeAll()
        transport.removeTemporaryFiles()
    }
}

/// The control API as the MCP tools see it, pointed at the fixture's loopback listener with
/// this Mac's own token — what `ControlClient` does against the running app, without the app.
private struct FixtureChannel: ElevenLabsChannel {
    let client: TestClient

    func elevenLabsGet(_ path: String) async throws -> MCPJSON {
        try await send("GET", path, nil)
    }

    func elevenLabsPost(_ path: String, _ body: MCPJSON) async throws -> MCPJSON {
        try await send("POST", path, String(decoding: try JSONEncoder().encode(body), as: UTF8.self))
    }

    private func send(_ method: String, _ path: String, _ body: String?) async throws -> MCPJSON {
        let (status, data) = try await client.call(method, path, token: client.token, body: body)
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode(ControlAPI.ErrorResponse.self, from: data))?.error
                ?? "HTTP \(status)"
            throw ControlClient.ClientError.server(status, message)
        }
        return try JSONDecoder().decode(MCPJSON.self, from: data)
    }
}

/// A control host whose `/elevenlabs/*` is the app's handler; everything else is the bare
/// host's answer, because nothing here asks for it.
actor ElevenLabsHandlerHost: ControlHost {
    let handler: ElevenLabsControlHandler

    init(_ handler: ElevenLabsControlHandler) { self.handler = handler }

    func elevenLabs(_ request: ElevenLabsControlRequest) async -> ElevenLabsControlResponse {
        await handler.handle(request)
    }

    func jevStatus() async -> ControlAPI.JevStatus { .fixture() }
    func jevCalibration() async -> ControlAPI.JevCalibration? { nil }
    func calibrateJev() async throws -> ControlAPI.JevCalibration { .fixture(lane: nil) }
    func recommend(category: String?, task: String?) async -> ControlAPI.CatalogModel? { nil }
    func swarm() async -> ControlAPI.SwarmView { .init(peers: [], polledSecondsAgo: nil) }
    func profile() async -> ControlAPI.Profile { fatalError("unused") }
    func metrics() async -> ControlAPI.Metrics { fatalError("unused") }
    func status() async -> ControlAPI.Status {
        .init(state: "idle", loadedModelID: nil, loadedModelName: nil, contextLength: nil,
              expertStreaming: false, lastGenerationTokensPerSecond: nil)
    }
    func catalog(category: String?, onlyRunnable: Bool) async -> [ControlAPI.CatalogModel] { [] }
    func installed() async -> [ControlAPI.InstalledModel] { [] }
    func unload() async {}
    func imageModels() async -> [ControlAPI.ImageModel] { [] }
    func meshModels() async -> [ControlAPI.MeshModel] { [] }
    func videoModels() async -> [ControlAPI.VideoModel] { [] }
    func conversationList() async -> [ControlAPI.ConversationSummary] { [] }
    func createConversation(title: String?) async -> ControlAPI.ConversationSummary {
        .init(id: "1", title: title ?? "New", updatedAt: ControlAPI.timestamp(Date()), messageCount: 0)
    }
    func recentGuardrailScreenings() async -> ControlAPI.GuardrailScreenings {
        .init(available: false, questions: [], screenings: [])
    }
    func updateJev(_ update: ControlAPI.JevUpdate) async throws -> ControlAPI.JevStatus { .fixture() }
    func nodeAdvertisement() async -> ControlAPI.NodeAdvertisement {
        .init(
            name: "Fixture", platform: "macos-apple-silicon",
            profile: .init(chip: "Apple M3 Max", memoryGB: 38.7, bandwidthGBps: 300, gpuCores: 40),
            capabilities: [],
            metrics: .init(queueDepth: 0, headroomGB: 8.9, gpuUtilPct: 0, memoryUsedPct: 0)
        )
    }
    func beginEventUpdates(postingTo hub: BuddyEventHub) async {}
    func plan(_ request: ControlAPI.PlanRequest) async throws -> ControlAPI.Plan { throw DecisionsHostError.unused }
    func install(_ request: ControlAPI.LoadRequest) async throws -> String { throw DecisionsHostError.unused }
    func load(_ request: ControlAPI.LoadRequest) async throws -> ControlAPI.Status { throw DecisionsHostError.unused }
    func chat(_ request: ControlAPI.ChatRequest) async throws -> ControlAPI.ChatResponse { throw DecisionsHostError.unused }
    func decide(_ request: ControlAPI.DecideRequest) async throws -> ControlAPI.DecideResponse { throw DecisionsHostError.unused }
    func benchmark() async throws -> ControlAPI.BenchmarkResult { throw DecisionsHostError.unused }
    func planImage(_ request: ControlAPI.ImageRequest) async throws -> ControlAPI.ImagePlan { throw DecisionsHostError.unused }
    func generateImage(_ request: ControlAPI.ImageRequest) async throws -> ControlAPI.ImageResponse { throw DecisionsHostError.unused }
    func planMesh(_ request: ControlAPI.MeshRequest) async throws -> ControlAPI.MeshPlan { throw DecisionsHostError.unused }
    func generateMesh(_ request: ControlAPI.MeshRequest) async throws -> ControlAPI.MeshResponse { throw DecisionsHostError.unused }
    func generateVideo(_ request: ControlAPI.VideoGenerateRequest) async throws -> ControlAPI.VideoResponse {
        throw DecisionsHostError.unused
    }
    func chatStream(
        _ request: ControlAPI.ChatRequest
    ) async throws -> AsyncThrowingStream<ControlAPI.ChatStreamEvent, any Error> {
        throw DecisionsHostError.unused
    }
    func conversation(id: String) async throws -> ControlAPI.ConversationDetail { throw DecisionsHostError.unused }
    func replyInConversation(
        id: String, to message: ControlAPI.NewMessageRequest
    ) async throws -> AsyncThrowingStream<ControlAPI.ChatStreamEvent, any Error> {
        throw DecisionsHostError.unused
    }
}
