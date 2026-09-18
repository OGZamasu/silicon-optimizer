import Foundation
import Testing
@testable import SiliconControl

/// The machine-readable contract the Silicon Buddy apps are generated from.
///
/// Every example here is built from the real `ControlAPI` type, never from a hand-written
/// dictionary — which is the whole point. A field renamed on this side changes the fixtures,
/// and the generated iOS and Android clients change with them, instead of the phone quietly
/// dropping a key three weeks later.
///
/// Run with `SILICON_EXPORT_CONTRACT=<dir> swift test --filter ContractExportTests` to write
/// the fixtures into the silicon-buddy repository. Without that variable this is a plain
/// round-trip test and touches no files at all.
@Suite("Silicon Buddy contract export")
struct ContractExportTests {

    @Test func everyWireTypeSurvivesARoundTrip() throws {
        for route in Self.routes {
            for (label, example) in route.examples {
                let encoded = try example.encode()
                let again = try example.roundTrip(encoded)
                #expect(
                    encoded == again,
                    "\(route.method) \(route.path) — \(label) does not survive a round trip"
                )
            }
        }
    }

    /// Pinned exactly, not spot-checked. A route added to `ControlServer` without a fixture
    /// is a mobile client somebody has to write by hand, so it fails here first.
    @Test func theRouteTableIsExactlyWhatTheServerAnswers() {
        let names = Self.routes.map { "\($0.method) \($0.path)" }
        #expect(Set(names).count == names.count)
        #expect(Set(names) == [
            "POST /buddy/pair", "GET /buddy/devices", "DELETE /buddy/devices/{id}",
            "POST /chat/stream", "GET /events",
            "GET /conversations", "POST /conversations", "GET /conversations/{id}",
            "POST /conversations/{id}/messages",
            "GET /health", "GET /profile", "GET /metrics", "GET /status", "GET /installed",
            "GET /catalog", "GET /recommend", "POST /plan", "POST /install", "POST /load",
            "POST /unload", "POST /chat", "POST /decide", "POST /v1/systemone",
            "POST /benchmark", "GET /swarm", "GET /v1/node",
            "GET /image/models", "POST /image/plan", "POST /image/generate",
            "GET /mesh/models", "POST /mesh/plan", "POST /mesh/generate",
            "GET /video/models", "GET /video/queue", "POST /video/queue",
            "POST /video/queue/control", "POST /video/generate",
        ])
        #expect(Self.routes.filter(\.isStream).count == 3)
        #expect(Self.routes.allSatisfy { !$0.summary.isEmpty })
        // Every route says what it answers when it says no, so a generated client has the
        // failure shapes as well as the happy one.
        // Every route says how it refuses — except the one that cannot. /health exists to
        // separate "the app is not running" from "bad token", so it has no failure mode.
        #expect(Self.routes.allSatisfy { $0.path == "/health" || !$0.errors.isEmpty })
        #expect(Self.routes.first { $0.path == "/health" }?.errors.isEmpty == true)
        // A route a chat-only device may call must not advertise the refusal it would get
        // if it could not, and one it may not must.
        let chatRoutes = Set(
            Self.routes.filter { $0.scopes.contains("chat") }.map { "\($0.method) \($0.path)" }
        )
        #expect(chatRoutes.contains("GET /recommend"))
        #expect(chatRoutes.contains("GET /v1/node"))
        #expect(chatRoutes.contains("POST /plan"))
        #expect(!chatRoutes.contains("POST /load"))
        #expect(!chatRoutes.contains("POST /benchmark"))
        #expect(Self.routes.allSatisfy { route in
            route.auth != "device" || route.scopes.contains("chat") == (route.errors[403] == nil)
        })
        // File names carry no spaces and no braces, so a generator can use them as symbols.
        #expect(Self.routes.allSatisfy {
            !$0.fileName.contains(" ") && !$0.fileName.contains("{")
        })
    }

    @Test func exportsWhenAskedTo() throws {
        guard let directory = ProcessInfo.processInfo.environment["SILICON_EXPORT_CONTRACT"],
              !directory.trimmingCharacters(in: .whitespaces).isEmpty
        else { return }

        let root = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        var expected = Set(Self.routes.map(\.fileName))
        expected.insert("routes.md")
        // A renamed or deleted route leaves a fixture behind, and a stale fixture is worse
        // than a missing one — a generator would build a client for a route that is gone.
        for stale in try FileManager.default.contentsOfDirectory(atPath: root.path)
        where !expected.contains(stale) && (stale.hasSuffix(".json") || stale == "routes.md") {
            try FileManager.default.removeItem(at: root.appendingPathComponent(stale))
        }

        for route in Self.routes {
            try route.fixture().write(
                to: root.appendingPathComponent(route.fileName), options: .atomic
            )
        }
        try Data(Self.routesMarkdown().utf8).write(
            to: root.appendingPathComponent("routes.md"), options: .atomic
        )

        let written = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
        #expect(written.isSuperset(of: expected))
    }

    // MARK: - Shapes

    /// One example value, kept with the two things a fixture needs from it: its bytes, and
    /// proof that those bytes decode back into the same thing.
    struct Example: Sendable {
        var encode: @Sendable () throws -> Data
        var roundTrip: @Sendable (Data) throws -> Data

        static func of<T: Codable & Sendable>(_ value: T) -> Example {
            Example(
                encode: { try ContractExportTests.encoder.encode(value) },
                roundTrip: { data in
                    try ContractExportTests.encoder.encode(
                        try JSONDecoder().decode(T.self, from: data)
                    )
                }
            )
        }
    }

    struct Route: Sendable {
        var method: String
        var path: String
        /// control — this Mac's own token. device — a paired phone's token, which the
        /// control token also satisfies. none — open, and there are only two of those.
        var auth: String
        var summary: String
        var request: Example?
        var response: Example?
        /// SSE event name to payload example, for the routes that answer a stream.
        var events: [(String, Example)] = []
        /// What this route says when it says no, keyed by status. Every entry is an
        /// `ErrorResponse`, which is the only failure envelope this server has.
        var errors: [Int: String] = [:]
        /// The device scopes that may call it. Filled in from the server's own gate.
        var scopes: [String] = ["full"]

        var isStream: Bool { !events.isEmpty }

        var examples: [(String, Example)] {
            var all: [(String, Example)] = []
            if let request { all.append(("request", request)) }
            if let response { all.append(("response", response)) }
            all.append(contentsOf: events.map { ("event \($0.0)", $0.1) })
            all.append(contentsOf: errors.sorted { $0.key < $1.key }.map {
                ("error \($0.key)", .of(ControlAPI.ErrorResponse(error: $0.value)))
            })
            return all
        }

        /// The refusals every authenticated route shares, so each entry below only has to
        /// name what is particular to it.
        static func commonErrors(auth: String, openToChatOnly: Bool) -> [Int: String] {
            // An unauthenticated route can only fail in ways particular to it, so it says
            // so itself rather than inheriting refusals it has no token to refuse.
            guard auth != "none" else { return [:] }
            var shared = [
                401: "Invalid or missing control token.",
                411: "This server needs a Content-Length. Chunked bodies are not read.",
                413: "That request body is larger than this device may send (4194304 bytes).",
            ]
            if auth == "control" {
                shared[403] = "Only this Mac can list paired devices."
            } else if !openToChatOnly {
                shared[403] = "This device is paired for chat only. Pair it again with full "
                    + "control from Settings → Silicon Buddy on the Mac."
            }
            return shared
        }

        /// A path cannot be a file name, so its slashes become underscores. The mapping is
        /// exact in both directions, which is what lets a generator read the route back out
        /// of the file name.
        /// A path is not a file name, so `/`, `{` and `}` all become `_`. The mapping is
        /// documented in `routes.md` and the result has no spaces or braces in it, which is
        /// what lets a generator turn a file name into a symbol.
        var fileName: String {
            let flattened = path
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "{", with: "_")
                .replacingOccurrences(of: "}", with: "_")
            return "\(method)_\(flattened).json"
        }

        func fixture() throws -> Data {
            var body: [String: Any] = [
                "method": method, "path": path, "auth": auth, "summary": summary,
                "scopes": scopes,
            ]
            body["request"] = try request.map { try json($0) } ?? NSNull()
            body["response"] = try response.map { try json($0) } ?? NSNull()
            if !events.isEmpty {
                var frames: [String: Any] = [:]
                for (name, example) in events { frames[name] = try json(example) }
                body["events"] = frames
                body["contentType"] = "text/event-stream"
            }
            var refusals: [String: Any] = [:]
            for (status, message) in errors {
                refusals[String(status)] = try json(
                    .of(ControlAPI.ErrorResponse(error: message))
                )
            }
            body["errors"] = refusals
            return try JSONSerialization.data(
                withJSONObject: body, options: [.prettyPrinted, .sortedKeys]
            )
        }

        private func json(_ example: Example) throws -> Any {
            try JSONSerialization.jsonObject(with: try example.encode())
        }
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func routesMarkdown() -> String {
        var lines = [
            "# Silicon Optimizer control API",
            "",
            "Generated by `ContractExportTests` in the silicon-optimizer repository.",
            "Do not edit by hand: re-run the export instead.",
            "",
            "Every route takes `Authorization: Bearer <token>` unless its auth column says",
            "`none`. A `control` token is the Mac's own, rotated every launch and readable",
            "only by processes running as the owner. A `device` token is minted by",
            "`POST /buddy/pair` and is what a phone holds; the control token satisfies those",
            "routes too, but not the other way round.",
            "",
            "Every body must carry a `Content-Length`; chunked requests are answered 411.",
            "A device may send at most 4 MiB, 8 images per message and about 1.5 MB per",
            "image; over that is a 413. Failures are always `{\"error\": \"...\"}`, and each",
            "fixture lists the ones its route can produce.",
            "",
            "Fixture file names replace `/`, `{` and `}` with `_`, so",
            "`POST /conversations/{id}/messages` is `POST__conversations__id__messages.json`.",
            "",
            "Each fixture lists the device `scopes` that may call it; an empty list means the",
            "route needs no token at all.",
            "",
            "`full` and `chat` are the two device scopes. A `chat` device may use the routes",
            "that only read or advise — `/health`, `/status`, `/profile`, `/metrics`,",
            "`/catalog`, `/installed`, `/recommend`, `/plan`, `/swarm`, `/v1/node`,",
            "`/image/models`, `/mesh/models`, `/video/models`, `/video/queue`, `/events` —",
            "plus `/chat`, `/chat/stream`, `/decide`, `/v1/systemone` and every",
            "`/conversations` route. Everything else answers 403: installing, loading,",
            "unloading, benchmarking, rendering, queue control and the device list.",
            "",
            "| Method | Path | Auth | What it does |",
            "|---|---|---|---|",
        ]
        for route in routes {
            let streaming = route.isStream ? " _(SSE)_" : ""
            lines.append("| `\(route.method)` | `\(route.path)` | \(route.auth) | \(route.summary)\(streaming) |")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - The table

    /// Each entry below names only the refusals particular to it; the ones every route of
    /// its auth class shares are folded in here, so they cannot drift apart.
    ///
    /// Which scope may call a route is asked of the server's own gate rather than restated,
    /// so the fixtures cannot claim a 403 that cannot happen — or miss one that can.
    static let routes: [Route] = (buddyRoutes + coreRoutes + mediaRoutes).map { route in
        var decorated = route
        let openToChat = ControlServer.Caller.device(id: "fixture", scope: .chat)
            .mayReach(method: route.method, path: route.path)
        // Empty means no token at all, which is a different thing from "full only" and
        // would be a lie to tell about /health.
        decorated.scopes = route.auth == "none"
            ? [] : (route.auth == "device" && openToChat ? ["full", "chat"] : ["full"])
        decorated.errors = Route.commonErrors(auth: route.auth, openToChatOnly: openToChat)
            .merging(route.errors) { _, particular in particular }
        return decorated
    }

    // MARK: Silicon Buddy's own

    static let buddyRoutes: [Route] = [
        Route(
            method: "POST", path: "/buddy/pair", auth: "none",
            summary: "Spend the six-digit code on screen for a device token of your own.",
            request: .of(ControlAPI.BuddyPairRequest(
                code: "417082", deviceName: "Galaxy S24 Ultra", platform: "android"
            )),
            response: .of(ControlAPI.BuddyPairResponse(
                deviceID: "7A1E0C6E-2C6A-4F4E-9F1E-0B2D3C4A5B6C",
                token: "V0hBVC1BLVRPS0VOLVdPVUxELUxPT0stTElLRS1IRVJF",
                macName: "Mac Studio", port: 8788, scope: "full"
            )),
            errors: [
                400: "The request does not name a device.",
                403: BuddyRegistry.wrongCode,
                429: "Too many pairing attempts. Wait a minute.",
            ]
        ),
        Route(
            method: "GET", path: "/buddy/devices", auth: "control",
            summary: "The paired devices, without their token hashes.",
            response: .of([exampleDevice])
        ),
        Route(
            method: "DELETE", path: "/buddy/devices/{id}", auth: "control",
            summary: "Revoke one device. Its token stops working at once, streams included.",
            response: .of(["status": "revoked"]),
            errors: [404: "No paired device with id 7A1E0C6E-2C6A-4F4E-9F1E-0B2D3C4A5B6C."]
        ),
        Route(
            method: "POST", path: "/chat/stream", auth: "device",
            summary: "The same body as /chat, answered token by token.",
            request: .of(exampleChatRequest),
            events: [
                ("token", .of(ControlAPI.StreamToken(text: "Because "))),
                ("reasoning", .of(ControlAPI.StreamToken(text: "The user asked about "))),
                ("finished", .of(exampleMetrics)),
                ("error", .of(ControlAPI.ErrorResponse(error: "The device stopped reading."))),
            ],
            errors: [400: "No model is loaded."]
        ),
        Route(
            method: "GET", path: "/events", auth: "device",
            summary: "What the Mac is doing: loaded model, downloads, render jobs.",
            events: [
                ("status", .of(exampleStatus)),
                ("download", .of(ControlAPI.DownloadEvent(
                    id: "qwen3-coder-30b", name: "Qwen3-Coder 30B A3B", fraction: 0.42,
                    bytesReceived: 8_589_934_592, bytesExpected: 20_401_094_656,
                    bytesPerSecond: 41_943_040
                ))),
                ("job", .of(ControlAPI.JobEvent(
                    id: "9C2F-0001", kind: "video", status: "running",
                    title: "Opening shot", fraction: 0.33
                ))),
                ("heartbeat", .of(ControlAPI.HeartbeatEvent(at: "2026-09-18T09:41:00Z"))),
            ],
            errors: [429: "Too many open streams. Close one before opening another."]
        ),
        Route(
            method: "GET", path: "/conversations", auth: "device",
            summary: "Every conversation on the Mac, newest first.",
            response: .of([exampleConversationSummary])
        ),
        Route(
            method: "POST", path: "/conversations", auth: "device",
            summary: "Start a conversation. It appears in the Mac's own sidebar at once.",
            request: .of(ControlAPI.NewConversationRequest(title: "Weekend in Lisbon")),
            response: .of(exampleConversationSummary)
        ),
        Route(
            method: "GET", path: "/conversations/{id}", auth: "device",
            summary: "One transcript. Images are omitted.",
            response: .of(ControlAPI.ConversationDetail(
                id: "3F5C1A88-9C1D-4E2B-8A70-1D2E3F405162",
                title: "Weekend in Lisbon",
                updatedAt: "2026-09-18T09:41:12Z",
                isGenerating: false,
                messages: [
                    .init(role: "user", content: "Three days in Lisbon — what would you do?",
                          createdAt: "2026-09-18T09:40:58Z"),
                    .init(role: "assistant", content: "Start in Alfama, early.",
                          createdAt: "2026-09-18T09:41:12Z"),
                ]
            )),
            errors: [404: "No conversation with id 3F5C1A88-9C1D-4E2B-8A70-1D2E3F405162."]
        ),
        Route(
            method: "POST", path: "/conversations/{id}/messages", auth: "device",
            summary: "Send a message and stream the answer. Both are saved on the Mac.",
            request: .of(ControlAPI.NewMessageRequest(
                content: "Three days in Lisbon — what would you do?"
            )),
            events: [
                ("token", .of(ControlAPI.StreamToken(text: "Start "))),
                ("reasoning", .of(ControlAPI.StreamToken(text: "Three days is "))),
                ("finished", .of(exampleMetrics)),
                ("error", .of(ControlAPI.ErrorResponse(error: "The device stopped reading."))),
            ],
            errors: [
                400: "No model is loaded.",
                404: "No conversation with id 3F5C1A88-9C1D-4E2B-8A70-1D2E3F405162.",
                409: "That conversation is still being answered. Wait for it to finish, or "
                    + "start another one.",
            ]
        ),
    ]

    // MARK: Everything that was already there

    static let coreRoutes: [Route] = [
        Route(
            method: "GET", path: "/health", auth: "none",
            summary: "Unauthenticated, so a client can tell a dead app from a bad token.",
            response: .of(["status": "ok", "version": "0.1.0"])
        ),
        Route(
            method: "GET", path: "/profile", auth: "device",
            summary: "What this Mac is, and how much of it a model may have.",
            response: .of(ControlAPI.Profile(
                chip: "Apple M3 Max", generation: "M3", totalMemoryBytes: 41_553_527_603,
                modelBudgetBytes: 29_200_000_000, performanceCores: 12, efficiencyCores: 4,
                gpuCores: 40, neuralEngineCores: 16, memoryBandwidthGBps: 300,
                diskFreeBytes: 890_000_000_000
            ))
        ),
        Route(
            method: "GET", path: "/metrics", auth: "device",
            summary: "Memory, swap, GPU and CPU right now.",
            response: .of(ControlAPI.Metrics(
                memoryUsedBytes: 21_474_836_480, memoryWiredBytes: 6_442_450_944,
                memoryTotalBytes: 41_553_527_603, swapUsedBytes: 0,
                gpuUtilization: 0.12, cpuUtilization: 0.24, memoryPressure: "normal"
            ))
        ),
        Route(
            method: "GET", path: "/status", auth: "device",
            summary: "What is loaded, at what settings, how fast it last ran.",
            response: .of(exampleStatus)
        ),
        Route(
            method: "GET", path: "/installed", auth: "device",
            summary: "The models on this Mac's disk.",
            response: .of([ControlAPI.InstalledModel(
                id: "qwen3-coder-30b", name: "Qwen3-Coder 30B A3B", quantization: "Q4_K_M",
                sizeOnDiskBytes: 20_401_094_656, isLoaded: true, supportsVision: false
            )])
        ),
        Route(
            method: "GET", path: "/catalog", auth: "device",
            summary: "The catalogue, each entry judged against this Mac.",
            response: .of([exampleCatalogModel])
        ),
        Route(
            method: "GET", path: "/recommend", auth: "device",
            summary: "The strongest model this machine can actually run.",
            response: .of(exampleCatalogModel)
        ),
        Route(
            method: "POST", path: "/plan", auth: "device",
            summary: "Will this fit at this context, and what would you change?",
            request: .of(ControlAPI.PlanRequest(
                modelID: "qwen3-coder-30b", quantization: "Q4_K_M", contextLength: 16_384
            )),
            response: .of(examplePlan)
        ),
        Route(
            method: "POST", path: "/install", auth: "device",
            summary: "Download a model. Progress arrives on /events.",
            request: .of(ControlAPI.LoadRequest(modelID: "qwen3-coder-30b", quantization: "Q4_K_M")),
            response: .of(["status": "Downloading Qwen3-Coder 30B A3B (Q4_K_M)."])
        ),
        Route(
            method: "POST", path: "/load", auth: "device",
            summary: "Load a model into memory.",
            request: .of(ControlAPI.LoadRequest(
                modelID: "qwen3-coder-30b", quantization: "Q4_K_M", contextLength: 16_384
            )),
            response: .of(exampleStatus)
        ),
        Route(
            method: "POST", path: "/unload", auth: "device",
            summary: "Free the loaded model.",
            response: .of(["status": "unloaded"])
        ),
        Route(
            method: "POST", path: "/chat", auth: "device",
            summary: "Ask the loaded model and wait for the whole answer.",
            request: .of(exampleChatRequest),
            response: .of(ControlAPI.ChatResponse(
                content: "Start in Alfama, early.", reasoning: nil, promptTokens: 412,
                generatedTokens: 96, tokensPerSecond: 89.4
            ))
        ),
        Route(
            method: "POST", path: "/decide", auth: "device",
            summary: "Typed probabilistic decisions, in the TypeSafe/Jev shape.",
            request: .of(ControlAPI.DecideRequest(
                state: .string("Customer was charged twice and wants it fixed."),
                questions: [
                    "refund": .init(type: "noul", instructions: .string("Asks for money back")),
                ]
            )),
            response: .of(ControlAPI.DecideResponse(
                model: "Qwen3-Coder 30B A3B",
                usage: .init(inputTokens: 120, outputTokens: 1),
                answers: ["refund": .noul(0.94)],
                provider: "local"
            ))
        ),
        Route(
            method: "POST", path: "/v1/systemone", auth: "device",
            summary: "The same route as /decide, at the path TypeSafe's own clients use.",
            request: .of(ControlAPI.DecideRequest(
                state: .string("Customer was charged twice and wants it fixed."),
                questions: [
                    "refund": .init(type: "noul", instructions: .string("Asks for money back")),
                ]
            )),
            response: .of(ControlAPI.DecideResponse(
                model: "Qwen3-Coder 30B A3B",
                usage: .init(inputTokens: 120, outputTokens: 1),
                answers: ["refund": .noul(0.94)],
                provider: "local"
            ))
        ),
        Route(
            method: "POST", path: "/benchmark", auth: "device",
            summary: "Measure the loaded model here, and recalibrate its estimates.",
            response: .of(ControlAPI.BenchmarkResult(
                modelName: "Qwen3-Coder 30B A3B", score: 82, grade: "Fast",
                generationTokensPerSecond: 89.4, promptTokensPerSecond: 1120,
                timeToFirstToken: 0.31, longContextFalloff: 0.86,
                predictedGenerationTokensPerSecond: 91, calibration: 0.98,
                findings: [.init(
                    title: "Within 2% of prediction",
                    detail: "The planner's estimate needed no correction.",
                    severity: "info"
                )]
            ))
        ),
        Route(
            method: "GET", path: "/swarm", auth: "device",
            summary: "The other machines this Mac can delegate to.",
            response: .of(ControlAPI.SwarmView(
                peers: [.init(
                    name: "silicon-node", baseURL: "http://silicon-node:8790",
                    reachable: true, error: nil,
                    capabilities: [.init(id: "image-to-mesh", kind: "mesh", ready: true)]
                )],
                polledSecondsAgo: 4
            ))
        ),
        Route(
            method: "GET", path: "/v1/node", auth: "device",
            summary: "What this Mac advertises to its peers.",
            response: .of(ControlAPI.NodeAdvertisement(
                name: "Mac Studio", platform: "macos-apple-silicon",
                profile: .init(
                    chip: "Apple M3 Max", memoryGB: 38.7, bandwidthGBps: 300, gpuCores: 40
                ),
                capabilities: [.init(
                    id: "llm-qwen3-coder-30b", kind: "llm", ready: true, peakGB: 20.3,
                    typicalSeconds: nil, detail: "Loaded at 16K context"
                )],
                metrics: .init(
                    queueDepth: 0, headroomGB: 8.9, gpuUtilPct: 12, memoryUsedPct: 52
                )
            ))
        ),
    ]

    // MARK: Images, meshes and video

    static let mediaRoutes: [Route] = [
        Route(
            method: "GET", path: "/image/models", auth: "device",
            summary: "The image models here, and what each would peak at.",
            response: .of([ControlAPI.ImageModel(
                id: "flux2-klein", name: "FLUX.2 klein", author: "Black Forest Labs",
                license: "Apache-2.0", summary: "Fast local text-to-image.",
                parameters: "4B", blocks: 19, defaultSteps: 8, isGated: false,
                recommendation: exampleImagePlan
            )])
        ),
        Route(
            method: "POST", path: "/image/plan", auth: "device",
            summary: "Phase-by-phase memory for a given size, steps and precision.",
            request: .of(exampleImageRequest), response: .of(exampleImagePlan)
        ),
        Route(
            method: "POST", path: "/image/generate", auth: "device",
            summary: "Render an image, locally or on a paired node.",
            request: .of(exampleImageRequest),
            response: .of(ControlAPI.ImageResponse(
                path: "/Users/you/Pictures/Silicon/lisbon-0001.png", elapsedSeconds: 11.4,
                peakMemoryBytes: 13_958_643_712, predictedPeakBytes: 14_200_000_000,
                model: "FLUX.2 klein"
            ))
        ),
        Route(
            method: "GET", path: "/mesh/models", auth: "device",
            summary: "The 3D models here, and what they cost to run.",
            response: .of([ControlAPI.MeshModel(
                id: "hunyuan3d-2", name: "Hunyuan3D 2", author: "Tencent",
                summary: "Image to textured mesh.", outputs: "GLB, OBJ",
                typicalDuration: "5 minutes", peakBytes: 13_958_643_712,
                weightsBytes: 6_442_450_944, isInstalled: true, installDetail: "Installed"
            )])
        ),
        Route(
            method: "POST", path: "/mesh/plan", auth: "device",
            summary: "Will this mesh job fit, here or on the node?",
            request: .of(exampleMeshRequest),
            response: .of(ControlAPI.MeshPlan(
                model: "Hunyuan3D 2", peakBytes: 13_958_643_712, peakPhase: "Texture bake",
                budgetBytes: 29_200_000_000, verdict: "fits", isRemote: false,
                phases: [.init(name: "Texture bake", detail: "2048px", residentBytes: 13_958_643_712)],
                suggestions: [], notes: []
            ))
        ),
        Route(
            method: "POST", path: "/mesh/generate", auth: "device",
            summary: "Turn an image into a mesh.",
            request: .of(exampleMeshRequest),
            response: .of(ControlAPI.MeshResponse(
                glbPath: "/Users/you/Models/kettle.glb", objPath: nil,
                elapsedSeconds: 323.7, model: "Hunyuan3D 2"
            ))
        ),
        Route(
            method: "GET", path: "/video/models", auth: "device",
            summary: "The video models, and which machine can run each.",
            response: .of([ControlAPI.VideoModel(
                id: "hailuo-h3", name: "Hailuo H3", summary: "Text and image to video.",
                typicalDuration: "4 minutes", supportsImageInput: true,
                supportedSeconds: [5, 10], available: true, node: "silicon-node"
            )])
        ),
        Route(
            method: "GET", path: "/video/queue", auth: "device",
            summary: "The render queue and what is running.",
            response: .of(exampleVideoQueue)
        ),
        Route(
            method: "POST", path: "/video/queue", auth: "device",
            summary: "Add prompts to the queue without holding a connection.",
            request: .of(ControlAPI.VideoQueueRequest(
                prompts: ["A tram climbing Alfama at dawn"], title: "Lisbon", variations: 2
            )),
            response: .of(exampleVideoQueue)
        ),
        Route(
            method: "POST", path: "/video/queue/control", auth: "device",
            summary: "Pause, resume, skip or cancel queued work.",
            request: .of(ControlAPI.VideoQueueControl(action: "pause")),
            response: .of(exampleVideoQueue)
        ),
        Route(
            method: "POST", path: "/video/generate", auth: "device",
            summary: "Render one clip and wait for it. At most eight of these at once.",
            request: .of(ControlAPI.VideoGenerateRequest(
                prompt: "A tram climbing Alfama at dawn", modelID: "hailuo-h3", seconds: 5
            )),
            response: .of(ControlAPI.VideoResponse(
                file: "/Users/you/Movies/Silicon/lisbon-0001.mp4", node: "silicon-node",
                model: "hailuo-h3", elapsedSeconds: 244.1
            ))
        ),
    ]

    // MARK: - Shared examples

    static let exampleDevice = ControlAPI.BuddyDeviceSummary(
        id: "7A1E0C6E-2C6A-4F4E-9F1E-0B2D3C4A5B6C", name: "Galaxy S24 Ultra",
        platform: "android", scope: "full", pairedAt: "2026-09-18T09:12:44Z",
        lastSeen: "2026-09-18T09:40:02Z"
    )

    static let exampleStatus = ControlAPI.Status(
        state: "running", loadedModelID: "qwen3-coder-30b",
        loadedModelName: "Qwen3-Coder 30B A3B", contextLength: 16_384,
        expertStreaming: false, lastGenerationTokensPerSecond: 89.4
    )

    static let exampleMetrics = ControlAPI.ChatMetrics(
        promptTokens: 412, generatedTokens: 96, tokensPerSecond: 89.4, timeToFirstToken: 0.31
    )

    static let exampleChatRequest = ControlAPI.ChatRequest(
        messages: [.init(role: "user", content: "Three days in Lisbon — what would you do?")],
        temperature: 0.7, maxTokens: 1024
    )

    static let exampleConversationSummary = ControlAPI.ConversationSummary(
        id: "3F5C1A88-9C1D-4E2B-8A70-1D2E3F405162", title: "Weekend in Lisbon",
        updatedAt: "2026-09-18T09:41:12Z", messageCount: 2
    )

    static let examplePlan = ControlAPI.Plan(
        verdict: "fits", residentBytes: 21_800_000_000, budgetBytes: 29_200_000_000,
        weightsBytes: 20_401_094_656, expertsBytes: 0, kvCacheBytes: 1_073_741_824,
        computeBytes: 325_000_000, streamedFromDiskBytes: 0,
        suggestions: [.init(
            title: "Halve the context",
            detail: "8K instead of 16K frees half a gigabyte.",
            savingBytes: 536_870_912, cost: "Shorter memory in long chats"
        )],
        notes: ["Measured on this Mac's own disk speed."]
    )

    static let exampleCatalogModel = ControlAPI.CatalogModel(
        id: "qwen3-coder-30b", name: "Qwen3-Coder 30B A3B", author: "Qwen",
        license: "Apache-2.0", summary: "A coding model that fits a 36 GB Mac.",
        category: "code", parameters: "30B", activeParameters: "3B", isMoE: true,
        capabilities: ["code", "tools"], rating: 5, maxContext: 262_144,
        quantizations: ["Q4_K_M", "Q5_K_M", "Q8_0"],
        recommendation: .init(
            quantization: "Q4_K_M", contextLength: 16_384, expertSlots: nil,
            estimatedGenerationTokensPerSecond: 89, estimatedPromptTokensPerSecond: 1120,
            downloadBytes: 20_401_094_656, plan: examplePlan,
            rationale: "The strongest coding model inside this Mac's budget."
        )
    )

    static let exampleImageRequest = ControlAPI.ImageRequest(
        prompt: "A tram climbing Alfama at dawn", modelID: "flux2-klein",
        width: 1024, height: 1024, steps: 8
    )

    static let exampleImagePlan = ControlAPI.ImagePlan(
        width: 1024, height: 1024, steps: 8, quantization: "8-bit",
        peakBytes: 13_958_643_712, peakPhase: "Decode", budgetBytes: 29_200_000_000,
        verdict: "fits",
        phases: [.init(name: "Decode", detail: "VAE", residentBytes: 13_958_643_712)],
        suggestions: [], notes: ["The last phase is the one that decides."]
    )

    static let exampleMeshRequest = ControlAPI.MeshRequest(
        imagePath: "/Users/you/Pictures/kettle.png", modelID: "hunyuan3d-2", textureSize: 2048
    )

    static let exampleVideoQueue = ControlAPI.VideoQueueView(
        paused: false, activeID: "9C2F-0001", message: nil,
        items: [.init(
            id: "9C2F-0001", batchID: "9C2F", title: "Lisbon",
            prompt: "A tram climbing Alfama at dawn", scene: 1, variation: 1,
            seed: 424_242, modelID: "hailuo-h3", seconds: 5, resolution: "768P",
            h3Turbo: false, status: "running", nodeJobID: "job-1187", file: nil,
            outputDirectory: "/Users/you/Movies/Silicon/Lisbon", error: nil,
            uncertainSubmission: false, h3Steps: 30
        )]
    )
}
