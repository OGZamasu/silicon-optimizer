import Foundation

// MARK: - ElevenLabs over the control API

/// `/elevenlabs/*`: the owner's ElevenLabs account, reached through the app that holds its key.
///
/// This module does not link the ElevenLabs client, and neither does the MCP bridge that links
/// this module. The routes carry JSON between HTTP and the host; only the app talks to
/// ElevenLabs, so the key never leaves it.
///
/// - `GET /elevenlabs/status` — linked or not, the region, the owner's switch, the last
///   balance the app checked.
/// - `GET /elevenlabs/operations?q=&group=&risk=&limit=` — search every operation.
/// - `GET /elevenlabs/operations/{id}` — one operation: parameters, body schema, response,
///   risk, cost and credential notes, and ElevenLabs's own description, quoted as data.
/// - `POST /elevenlabs/call` — `{operation, arguments, files: [{field, path}], confirm}`.
public enum ElevenLabsControl {

    /// Whether a request path is one of the ElevenLabs routes, for the caller policy.
    ///
    /// By its first segment, case-insensitively, the way the router splits a path. `//elevenlabs/call`
    /// is routed as `/elevenlabs/call`, and `/ElevenLabs/call` is refused rather than
    /// answered 404, so there is no spelling of the path that slips past the rule.
    public static func isElevenLabsPath(_ path: String) -> Bool {
        guard let first = path.split(separator: "/").first else { return false }
        return first.lowercased() == "elevenlabs"
    }

    /// What every caller but this Mac's own control token is told, on either listener.
    ///
    /// Paired phones at full scope included: ElevenLabs calls spend the owner's credits and
    /// some place real phone calls, and that is the owner's decision to make at the Mac, not
    /// a phone's, the same rule as the TypeSafe budget.
    public static let onlyThisMac =
        "ElevenLabs spends the owner's credits, so only this Mac's own control token can use it."

    /// What a loopback request with a browser's `Host` or `Origin` is told. The token already
    /// keeps a web page out; this is the second lock, the one the agent routes have too.
    public static let loopbackOnly =
        "Only loopback clients may use the ElevenLabs routes on this listener."

    /// What a host that is not the Mac app answers: the MCP bridge's doubles, the fixtures.
    public static let notOnThisHost =
        "This host does not have ElevenLabs. It lives in the Silicon Optimizer app on the Mac."

    /// `POST /elevenlabs/call` while no key is linked.
    public static let notConnected =
        "ElevenLabs is not connected. The owner connects it in Settings → ElevenLabs on the Mac."

    /// The owner's Settings switch, by the name the Settings window shows. Off by default;
    /// while it is off, destructive and real-world operations are refused to agents and
    /// credentials in answers are masked.
    public static let riskySwitch = "Let agents run destructive and real-world ElevenLabs actions"

    /// Where that switch lives.
    public static let riskySwitchLocation = "Settings → ElevenLabs"

    /// The fields of a `POST /elevenlabs/call` body. Anything else is refused by name, so a
    /// misspelt `argumnets` is an error rather than a call sent without its arguments.
    public static let callFields: Set<String> = ["operation", "arguments", "files", "confirm"]

    /// How much JSON (or text, or events) a call answers inline. Past it the answer is
    /// shortened, and the whole of it is saved in the output folder.
    public static let inlineResultBytes = 256 * 1024

    /// `GET /elevenlabs/operations` answers this many unless asked for fewer or more, and
    /// never more than `maximumListLimit` — which is more than there are operations, so one
    /// request can list them all.
    public static let defaultListLimit = 50
    public static let maximumListLimit = 500

    /// The most a call may upload, all its files together — the client's own ceiling.
    /// ElevenLabs's are lower for most operations; this is the one that stops the app reading
    /// anything bigger.
    public static let maximumUploadBytes: Int64 = 3 << 30

    /// The most files one call may name.
    public static let maximumUploadFiles = 100
}

/// One request for the host, already past the caller policy.
public struct ElevenLabsControlRequest: Sendable, Equatable {
    public enum Route: Sendable, Equatable {
        /// `GET /elevenlabs/status`
        case status
        /// `GET /elevenlabs/operations`
        case operations(ElevenLabsOperationQuery)
        /// `GET /elevenlabs/operations/{id}`
        case operation(id: String)
        /// `POST /elevenlabs/call`, its body exactly as it arrived.
        case call(body: Data)
        /// `POST /elevenlabs/agents/converse` (`ElevenLabsRealtimeAPI.swift`), its body as it arrived.
        case agentConverse(body: Data)
    }

    public var route: Route

    public init(route: Route) { self.route = route }
}

/// The query string of `GET /elevenlabs/operations`, as sent. The host validates it: only it
/// knows the groups and risk classes.
public struct ElevenLabsOperationQuery: Sendable, Equatable {
    /// `q`: every word must appear in the operation's id, path, method, summary or group.
    public var text: String?
    public var group: String?
    /// `read`, `generate`, `modify`, `destructive` or `realWorld`.
    public var risk: String?
    /// A whole number, 1 through `ElevenLabsControl.maximumListLimit`.
    public var limit: String?

    public init(text: String? = nil, group: String? = nil, risk: String? = nil, limit: String? = nil) {
        self.text = text
        self.group = group
        self.risk = risk
        self.limit = limit
    }
}

/// The host's answer: a status and a JSON body. An error body is `{"error": "…"}` plus whatever
/// `ElevenLabsWire.Refusal` adds, so every client that reads `ControlAPI.ErrorResponse` reads it.
public struct ElevenLabsControlResponse: Sendable, Equatable {
    public var status: Int
    public var body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }

    public static func encode(_ value: some Encodable, status: Int = 200) -> Self {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let body = try? encoder.encode(value) else {
            return .error(500, "Could not encode the ElevenLabs answer.")
        }
        return .init(status: status, body: body)
    }

    public static func error(_ status: Int, _ message: String) -> Self {
        refusal(status, ElevenLabsWire.Refusal(error: message))
    }

    public static func refusal(_ status: Int, _ refusal: ElevenLabsWire.Refusal) -> Self {
        encode(refusal, status: status)
    }
}

/// The fixed-shape parts of the answers. An operation's detail and a call's result carry the
/// vendor's schemas and answers, which are any JSON at all; those are built by the host and
/// read by the MCP bridge as JSON trees, and their keys are documented in `docs/ELEVENLABS.md`.
public enum ElevenLabsWire {

    /// `GET /elevenlabs/status`.
    public struct Status: Codable, Sendable, Equatable {
        public var linked: Bool
        /// The API host the key is sent to, e.g. `api.elevenlabs.io`.
        public var region: String
        public var regionName: String
        /// Whether the owner's `ElevenLabsControl.riskySwitch` is on.
        public var agentsMayRunRiskyActions: Bool
        public var riskySwitch: String
        /// How many operations `GET /elevenlabs/operations` can find.
        public var operations: Int
        /// The last balance the app checked this launch, if it has checked one. Reading the
        /// status never asks ElevenLabs anything.
        public var account: Account?
        /// What to do next, when there is something to do.
        public var note: String?

        public init(
            linked: Bool, region: String, regionName: String, agentsMayRunRiskyActions: Bool,
            operations: Int, account: Account? = nil, note: String? = nil
        ) {
            self.linked = linked
            self.region = region
            self.regionName = regionName
            self.agentsMayRunRiskyActions = agentsMayRunRiskyActions
            self.riskySwitch = ElevenLabsControl.riskySwitch
            self.operations = operations
            self.account = account
            self.note = note
        }
    }

    /// The plan and balance, as the app last saw them.
    public struct Account: Codable, Sendable, Equatable {
        public var tier: String
        public var characterCount: Int
        public var characterLimit: Int
        public var remainingCharacters: Int
        /// ISO 8601.
        public var nextResetAt: String?
        /// ISO 8601: when the app asked.
        public var checkedAt: String

        public init(
            tier: String, characterCount: Int, characterLimit: Int, remainingCharacters: Int,
            nextResetAt: String?, checkedAt: String
        ) {
            self.tier = tier
            self.characterCount = characterCount
            self.characterLimit = characterLimit
            self.remainingCharacters = remainingCharacters
            self.nextResetAt = nextResetAt
            self.checkedAt = checkedAt
        }
    }

    /// One operation in a list.
    public struct OperationSummary: Codable, Sendable, Equatable {
        public var id: String
        public var method: String
        public var path: String
        public var group: String
        public var summary: String
        /// `read`, `generate`, `modify`, `destructive` or `realWorld`.
        public var risk: String
        public var billable: Bool
        public var returnsCredential: Bool
        /// `destructive` and `realWorld`: `confirm: true` and the owner's switch.
        public var requiresConfirmation: Bool
        public var deprecated: Bool
        public var supportsStreaming: Bool
        /// Multipart fields that take a file, for `files: [{field, path}]`.
        public var fileFields: [String]

        public init(
            id: String, method: String, path: String, group: String, summary: String,
            risk: String, billable: Bool, returnsCredential: Bool, requiresConfirmation: Bool,
            deprecated: Bool, supportsStreaming: Bool, fileFields: [String]
        ) {
            self.id = id
            self.method = method
            self.path = path
            self.group = group
            self.summary = summary
            self.risk = risk
            self.billable = billable
            self.returnsCredential = returnsCredential
            self.requiresConfirmation = requiresConfirmation
            self.deprecated = deprecated
            self.supportsStreaming = supportsStreaming
            self.fileFields = fileFields
        }
    }

    /// `GET /elevenlabs/operations`.
    public struct OperationList: Codable, Sendable, Equatable {
        /// How many operations matched.
        public var total: Int
        /// How many are in `operations`: at most the limit.
        public var returned: Int
        public var operations: [OperationSummary]
        /// Every group and how many operations it holds, whatever the filters.
        public var groups: [Group]

        public init(total: Int, operations: [OperationSummary], groups: [Group]) {
            self.total = total
            self.returned = operations.count
            self.operations = operations
            self.groups = groups
        }
    }

    public struct Group: Codable, Sendable, Equatable {
        public var name: String
        public var count: Int

        public init(name: String, count: Int) {
            self.name = name
            self.count = count
        }
    }

    /// One upload in a `POST /elevenlabs/call` body: the multipart field, and a path on this
    /// Mac. The path is read on the Mac and never appears in an answer.
    public struct CallFile: Codable, Sendable, Equatable {
        public var field: String
        public var path: String

        public init(field: String, path: String) {
            self.field = field
            self.path = path
        }
    }

    /// Every refusal. `error` is the whole sentence; the rest says parts of it again as data,
    /// for a script that would rather not parse prose.
    public struct Refusal: Codable, Sendable, Equatable {
        public var error: String
        public var operation: String?
        public var risk: String?
        /// What the operation does, in the spec's words.
        public var summary: String?
        /// The switch that would allow it, when one would.
        public var setting: String?
        public var closeMatches: [String]?
        /// Every problem with the request, when there were several.
        public var problems: [String]?
        /// ElevenLabs's own status, when it was ElevenLabs that refused.
        public var upstreamStatus: Int?
        public var requestID: String?
        public var retryAfterSeconds: Double?

        public init(
            error: String, operation: String? = nil, risk: String? = nil, summary: String? = nil,
            setting: String? = nil, closeMatches: [String]? = nil, problems: [String]? = nil,
            upstreamStatus: Int? = nil, requestID: String? = nil, retryAfterSeconds: Double? = nil
        ) {
            self.error = error
            self.operation = operation
            self.risk = risk
            self.summary = summary
            self.setting = setting
            self.closeMatches = closeMatches
            self.problems = problems
            self.upstreamStatus = upstreamStatus
            self.requestID = requestID
            self.retryAfterSeconds = retryAfterSeconds
        }
    }
}

// MARK: - The host's default

extension ControlHost {
    /// A host that is not the Mac app has no ElevenLabs: a 501 with a sentence, like the
    /// decision routes' default.
    public func elevenLabs(_ request: ElevenLabsControlRequest) async -> ElevenLabsControlResponse {
        .error(501, ElevenLabsControl.notOnThisHost)
    }
}

// MARK: - Routing

extension ControlServer {

    /// `/elevenlabs/*`, once `mayReach` and the body gate have let the request through.
    static func routeElevenLabs(
        _ request: HTTPRequest, segments: [String], as caller: Caller, on origin: Origin,
        host: any ControlHost
    ) async -> HTTPResponse {
        // The third lock. The body gate and `mayReach` have already refused everyone else;
        // this is the one that still holds if either of them is ever loosened.
        guard caller == .control, origin == .primary else {
            return .error(403, ElevenLabsControl.onlyThisMac)
        }
        guard GatewayServer.isValidLoopbackHost(request.headers["host"]),
              GatewayServer.isTrustedLoopbackOrigin(request.headers["origin"])
        else { return .error(403, ElevenLabsControl.loopbackOnly) }
        guard let route = elevenLabsRoute(
            method: request.method, segments: segments, query: request.query, body: request.body
        ) else {
            return .error(404, "Unknown endpoint \(request.method) \(request.path)")
        }
        let answer = await host.elevenLabs(ElevenLabsControlRequest(route: route))
        return HTTPResponse(status: answer.status, body: answer.body)
    }

    /// The route a request names, or nil for a path or method there is no route for.
    static func elevenLabsRoute(
        method: String, segments: [String], query: [String: String], body: Data
    ) -> ElevenLabsControlRequest.Route? {
        guard segments.first == "elevenlabs" else { return nil }
        if method == "GET", segments == ["elevenlabs", "status"] { return .status }
        if method == "GET", segments == ["elevenlabs", "operations"] {
            return .operations(ElevenLabsOperationQuery(
                text: query["q"], group: query["group"], risk: query["risk"], limit: query["limit"]
            ))
        }
        if method == "GET",
           let id = parameter(segments, matching: ["elevenlabs", "operations", "*"]) {
            return .operation(id: id)
        }
        if method == "POST", segments == ["elevenlabs", "call"] { return .call(body: body) }
        return elevenLabsRealtimeRoute(method: method, segments: segments, body: body)
    }
}
