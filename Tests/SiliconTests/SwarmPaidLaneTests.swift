import Foundation
import Testing
@testable import SiliconControl
@testable import SiliconRuntime
@testable import SiliconUI

/// A swarm node's request runs with `PaidLanes.allowed` false, and nothing it sets off may
/// spend the owner's money.
///
/// Every test here counts requests at a loopback TypeSafe, never the real one, and each ends
/// by showing the same call *does* reach that double when the lanes are open — so a door
/// that was simply broken could not pass for one that was shut.
@Suite("Swarm requests and the paid lanes")
struct SwarmPaidLaneTests {

    private static let asked = ControlAPI.DecideRequest(
        state: .string("A customer was charged twice."),
        questions: jevQuestions, provider: "typesafe"
    )

    /// The one door. Unavailable to every feature, refused before the cache, the budget or
    /// the key is looked at, and nothing reaches the server or the ledger.
    @Test func theJevDoorIsShutToASwarmRequest() async throws {
        let typeSafe = try CapturingServer { _ in jevAnswer }
        defer { typeSafe.stop() }
        let harness = JevHarness()
        defer { harness.clean() }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        await harness.configure(
            baseURL: URL(string: "http://127.0.0.1:\(typeSafe.port)")!, session: session
        )
        try await harness.service.update { settings in
            settings.enabled = true
            for feature in JevFeature.allCases { settings.features[feature] = true }
        }
        let service = harness.service

        try await PaidLanes.$allowed.withValue(false) {
            for feature in JevFeature.allCases {
                #expect(await service.isAvailable(feature) == false, "\(feature.rawValue)")
            }
            await #expect(throws: JevError.notForPeers) {
                try await service.ask(.decideTool, state: .string("s"), questions: jevQuestions)
            }
            await #expect(throws: JevError.notForPeers) {
                _ = try await AppModel.decideViaTypeSafe(Self.asked, using: service)
            }
            #expect(await AppModel.cascadeMayEscalate(service) == false)
        }
        #expect(typeSafe.requests.isEmpty)
        #expect(await service.ledger().month().total.calls == 0)

        // The same calls, from anyone else.
        #expect(await AppModel.cascadeMayEscalate(service))
        _ = try await AppModel.decideViaTypeSafe(Self.asked, using: service)
        #expect(typeSafe.requests.count == 1)
    }

    /// `auto` for a swarm node is the free lane and nothing more: the question the local
    /// model was unsure of is answered locally rather than put to Jev.
    @Test func theCascadeAnswersASwarmNodeFromTheFreeLaneOnly() async throws {
        let llama = try CapturingServer { recorded in
            // Near-even letters on the refund question put it in the middle of the band,
            // which is exactly the answer the cascade would send to Jev.
            let even = String(decoding: recorded.body, as: UTF8.self).contains("Asks for money back")
            return """
                {"choices":[{"message":{"content":"A"},"logprobs":{"content":[{"token":"A","logprob":\(even ? -0.69 : -0.05),
                  "top_logprobs":[{"token":"A","logprob":\(even ? -0.69 : -0.05)},{"token":"B","logprob":\(even ? -0.70 : -3.0)}]}]}}],
                 "usage":{"prompt_tokens":40,"completion_tokens":1}}
                """
        }
        defer { llama.stop() }
        let typeSafe = try CapturingServer { recorded in
            CalibrationRunTests.jevAnswer(to: recorded.body)
        }
        defer { typeSafe.stop() }
        let harness = JevHarness()
        defer { harness.clean() }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        await harness.configure(
            baseURL: URL(string: "http://127.0.0.1:\(typeSafe.port)")!, session: session
        )
        try await harness.service.update { settings in
            settings.enabled = true
            settings.features[.decideTool] = true
            settings.features[.calibration] = true
        }

        let decider = LocalDecider(
            endpoint: URL(string: "http://127.0.0.1:\(llama.port)")!, modelName: "Test 1B"
        )
        let service = harness.service
        let request = ControlAPI.DecideRequest(
            state: .string("A customer was charged twice."),
            questions: [
                "refund": .init(type: "noul", instructions: .string("Asks for money back")),
                "team": .init(
                    type: "choice", instructions: .string("Which team?"),
                    criteria: .object(["billing": .null, "technical": .null])
                ),
            ]
        )
        func cascade() async throws -> ControlAPI.DecideResponse {
            try await DecisionCascade.run(
                request,
                floors: ControlAPI.JevCalibration.Floors(confidence: 0.6, noulLow: 0.25, noulHigh: 0.75),
                jevAvailable: { await AppModel.cascadeMayEscalate(service) },
                local: { try await decider.decide($0) },
                jev: { try await AppModel.escalate($0, using: service) }
            )
        }

        let peer = try await PaidLanes.$allowed.withValue(false) { try await cascade() }
        #expect(peer.provider == "local")
        #expect(typeSafe.requests.isEmpty)

        let owner = try await cascade()
        #expect(owner.provider == "local+typesafe")
        #expect(typeSafe.requests.count == 1)
    }

    /// A render the swarm names a cloud provider's model for would be billed to the owner's
    /// account. It is refused before the host is asked — on every render route the swarm
    /// can reach, on both listeners, in any spelling of the namespace — while a model the
    /// swarm does render, and `auto`, still reach it, and the owner's own token and a paired
    /// phone send the same body through untouched.
    @Test func theSwarmSecretCannotNameACloudModelForARender() async throws {
        let swarm = "test-shared-swarm-secret"
        try await BuddyMediaFixture.withServer(swarmToken: swarm) { fixture in
            let picture = try fixture.writeOutput(
                named: "kettle.png", bytes: BuddyMediaRoutesTests.pngBytes(count: 64)
            )
            let mediaID = try #require(
                await fixture.registry.register(path: picture.path, within: [fixture.outputs.path])
            )
            let routes = [
                "/image/plan", "/image/generate", "/mesh/plan", "/mesh/generate", "/video/generate",
            ]
            func body(_ model: String) -> String {
                #"{"prompt":"a kettle","mediaID":"\#(mediaID)","modelID":"\#(model)"}"#
            }

            for client in [fixture.phone, fixture.local] {
                for route in routes {
                    for model in ["cloud/gmi/flux-pro", "Cloud/OpenRouter/a-video-model", " cloud/x"] {
                        let (status, answer) = try await client.call(
                            "POST", route, token: swarm, body: body(model)
                        )
                        #expect(status == 403, "\(route) \(model)")
                        #expect(
                            (try? JSONDecoder().decode(ControlAPI.ErrorResponse.self, from: answer))?
                                .error == ControlServer.paidMediaIsNotForPeers
                        )
                    }
                }
            }
            #expect(await fixture.host.modelsAsked.isEmpty)

            for route in routes {
                for model in ["flux1-schnell", "auto"] {
                    #expect(try await fixture.phone.status(
                        "POST", route, token: swarm, body: body(model)
                    ) == 200, "\(route) \(model)")
                }
            }
            #expect(await fixture.host.modelsAsked.count == routes.count * 2)
            #expect(await fixture.host.modelsAsked.allSatisfy { !$0.hasPrefix("cloud/") })

            // Whoever else asks is not the swarm, and the rule is not theirs.
            let phone = try await fixture.pair()
            for route in routes {
                #expect(try await fixture.phone.status(
                    "POST", route, token: phone.token, body: body("cloud/gmi/flux-pro")
                ) == 200)
                #expect(try await fixture.local.status(
                    "POST", route, token: fixture.local.token, body: body("cloud/gmi/flux-pro")
                ) == 200)
            }
            #expect(await fixture.host.modelsAsked.count == routes.count * 4)
        }
    }

    /// A flagged answer to a swarm node's chat may be re-run on the owner's hardware, never
    /// on a cloud model billed to the owner — whether the owner picked one or the gateway
    /// merely lists one.
    @Test func aSwarmChatIsNeverReRunOnACloudModel() {
        func model(_ id: String, serving: Bool) -> GatewayAPI.Model {
            GatewayAPI.Model(
                id: id, displayName: id, where_: "somewhere", contextWindow: nil, serving: serving
            )
        }
        let world = [
            model("cloud/open-router/gpt-5.5", serving: true),
            model("node/studio/qwen3.8-27b", serving: true),
        ]
        #expect(AppModel.escalationTarget(
            chosen: "cloud/open-router/gpt-5.5", from: [], excluding: nil, paidAllowed: false
        ) == nil)
        #expect(AppModel.escalationTarget(
            chosen: nil, from: world, excluding: nil, paidAllowed: false
        ) == "node/studio/qwen3.8-27b")
        #expect(AppModel.escalationTarget(
            chosen: "node/studio/qwen3.8-27b", from: [], excluding: nil, paidAllowed: false
        ) == "node/studio/qwen3.8-27b")
        // The owner's own pick still stands for the owner.
        #expect(AppModel.escalationTarget(
            chosen: "cloud/open-router/gpt-5.5", from: [], excluding: nil
        ) == "cloud/open-router/gpt-5.5")
    }
}
