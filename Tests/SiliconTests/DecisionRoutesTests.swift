import Foundation
import Testing
@testable import SiliconControl
@testable import SiliconRuntime

// MARK: - Translating laya-mlx's dictionaries

@Suite("Laya answers on the wire")
struct LayaWireTests {

    /// The exact dictionaries the library returns, transcribed from a real run on this Mac
    /// rather than from the README — which calls the expected score "expected score" while
    /// the key is `score`, and says nothing about `action.act_probability` being on every
    /// answer.
    private func decode(_ json: String) throws -> LayaSidecarResponse {
        try JSONDecoder().decode(LayaSidecarResponse.self, from: Data(json.utf8))
    }

    static let realAnswer = """
        {"model": "aac6fef/laya-mlx",
         "usage": {"input_tokens": 253, "output_tokens": 0},
         "latency_ms": 61.95, "per_question_ms": 20.65,
         "peak_memory_bytes": 1264000000,
         "answers": {
           "urgent": {"type": "noul", "confidence": 0.9025,
                      "action": {"act_probability": 1.0}, "noul": 0.0975},
           "department": {"type": "choice", "confidence": 0.9548,
                          "action": {"act_probability": 1.0}, "choice": "billing",
                          "probabilities": {"billing": 0.9907, "technical": 0.0026,
                                            "sales": 0.0039, "other": 0.0028}},
           "severity": {"type": "score", "confidence": 0.4059,
                        "action": {"act_probability": 1.0}, "score": 1.5185,
                        "legend": {"0": "not a problem", "1": "minor annoyance",
                                   "2": "real problem", "3": "blocking",
                                   "4": "urgent harm"},
                        "probabilities": {"0": 0.0208, "1": 0.4994, "2": 0.4353,
                                          "3": 0.0291, "4": 0.0152}}}}
        """

    @Test func allThreePrimitivesBecomeTheAnswersThisAppAlreadySpeaks() throws {
        let response = try decode(Self.realAnswer)
        let request = ControlAPI.DecideRequest(
            state: .string("an email"),
            questions: [
                "urgent": .init(type: "noul", instructions: .string("Reply today?")),
                "department": .init(
                    type: "choice", instructions: .string("Whose?"),
                    criteria: .object(["billing": .string("b"), "technical": .string("t"),
                                       "sales": .string("s"), "other": .string("o")])
                ),
                "severity": .init(
                    type: "score", instructions: .string("How bad?"),
                    criteria: .array([.string("a"), .string("b"), .string("c"),
                                      .string("d"), .string("e")])
                ),
            ]
        )
        let decided = try LayaWire.response(
            response, for: request, checkpoint: .english, wallClockMS: 64
        )

        // The typed accessors are what every feature reads through, so they are what the
        // translation has to satisfy — not the enum shape.
        #expect(try decided.noul("urgent") == 0.0975)
        let choice = try decided.choice("department")
        #expect(choice.choice == "billing")
        #expect(choice.confidence == 0.9548)
        #expect(choice.probabilities["billing"] == 0.9907)
        let score = try decided.score("severity")
        #expect(score.score == 1.5185)
        #expect(score.confidence == 0.4059)
        #expect(score.legend["1"]?.stringValue == "minor annoyance")
        #expect(score.probabilities["1"] == 0.4994)

        #expect(decided.provider == "laya", "the answer says which lane produced it")
        #expect(decided.model == "aac6fef/laya-mlx")
        #expect(decided.usage.inputTokens == 253)
        #expect(decided.latencyMS == 64)
    }

    /// The whole response re-encodes as the shape `/decide` has always returned, so a
    /// client written against the Jev lane reads a Laya answer without knowing.
    @Test func aLayaAnswerEncodesExactlyLikeAJevOne() throws {
        let response = try decode(Self.realAnswer)
        let request = ControlAPI.DecideRequest(
            state: .string("s"),
            questions: ["urgent": .init(type: "noul", instructions: .string("?"))]
        )
        let decided = try LayaWire.response(
            response, for: request, checkpoint: .english, wallClockMS: 5
        )
        let encoded = try JSONEncoder().encode(decided)
        let object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        let answers = object["answers"] as! [String: Any]
        let urgent = answers["urgent"] as! [String: Any]
        #expect(urgent["type"] as? String == "noul")
        #expect(urgent["noul"] as? Double == 0.0975)
        #expect(object["latency_ms"] as? Double == 5, "snake_case, as it always was")
        // And it decodes back through the type a client uses.
        let round = try JSONDecoder().decode(ControlAPI.DecideResponse.self, from: encoded)
        #expect(try round.noul("urgent") == 0.0975)
    }

    /// An answer of the wrong kind is caught here, with the question's name — not three
    /// frames away inside a feature's typed accessor.
    @Test func anAnswerOfTheWrongKindIsRefusedByName() throws {
        let response = try decode("""
            {"answers": {"urgent": {"type": "choice", "confidence": 0.5,
                                    "choice": "a", "probabilities": {"a": 1.0}}}}
            """)
        let request = ControlAPI.DecideRequest(
            state: .string("s"),
            questions: ["urgent": .init(type: "noul", instructions: .string("?"))]
        )
        #expect(throws: DecisionLaneError.wrongAnswerKind(
            question: "urgent", expected: "noul", got: "choice"
        )) {
            _ = try LayaWire.response(
                response, for: request, checkpoint: .english, wallClockMS: 1
            )
        }
    }

    @Test func aMissingAnswerIsRefusedRatherThanSilentlyDropped() throws {
        let response = try decode("""
            {"answers": {"other": {"type": "noul", "noul": 0.5, "confidence": 0.5}}}
            """)
        let request = ControlAPI.DecideRequest(
            state: .string("s"),
            questions: ["urgent": .init(type: "noul", instructions: .string("?"))]
        )
        #expect(throws: DecisionLaneError.missingAnswer(question: "urgent")) {
            _ = try LayaWire.response(
                response, for: request, checkpoint: .english, wallClockMS: 1
            )
        }
    }

    /// Probabilities come from another process, which means they are numbers somebody else
    /// computed. A NaN would compare false against every threshold and silently escalate
    /// nothing at all.
    @Test func numbersFromAnotherProcessAreClamped() throws {
        #expect(LayaWire.clamped(1.0001) == 1)
        #expect(LayaWire.clamped(-0.0001) == 0)
        #expect(LayaWire.clamped(.nan) == 0)
        #expect(LayaWire.clamped(.infinity) == 0)
        #expect(LayaWire.clamped(0.5) == 0.5)
    }

    /// The state and the questions go out in laya's own shape: a dict stays a dict, so the
    /// model sees the keys rather than a flattened string.
    @Test func theStateAndQuestionsKeepTheirShapeGoingOut() {
        let state = LayaWire.state(.object([
            "subject": .string("Refund"), "attempts": .number(2),
        ])) as? [String: Any]
        #expect(state?["subject"] as? String == "Refund")
        #expect((state?["attempts"] as? Double) == 2)

        let questions = LayaWire.questions([
            "pick": .init(
                type: "choice", instructions: .string("Which?"),
                criteria: .object(["a": .string("one")])
            ),
            "yes": .init(type: "noul", instructions: .string("True?")),
        ])
        let pick = questions["pick"] as? [String: Any]
        #expect(pick?["type"] as? String == "choice")
        #expect(pick?["instructions"] as? String == "Which?")
        #expect((pick?["criteria"] as? [String: Any])?["a"] as? String == "one")
        // A noul carries no criteria in laya's own examples, and none is invented.
        #expect((questions["yes"] as? [String: Any])?["criteria"] == nil)
    }
}

// MARK: - The routes

@Suite("Decision control routes")
struct DecisionRoutesTests {

    private func withServer(
        _ body: (DecisionsTestHost, ControlAPI.Handshake, Int) async throws -> Void
    ) async throws {
        let host = DecisionsTestHost()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("decisions-route-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let handshakeURL = directory.appendingPathComponent("control.json")
        let server = ControlServer(
            host: host, handshakeURL: handshakeURL,
            buddy: BuddyRegistry(url: directory.appendingPathComponent("buddy.json")),
            discoverTailnetAddress: { nil }
        )
        try await server.start()
        defer { Task { await server.stop() } }

        var handshake: ControlAPI.Handshake?
        for _ in 0..<200 where handshake == nil {
            handshake = try? JSONDecoder().decode(
                ControlAPI.Handshake.self, from: try Data(contentsOf: handshakeURL)
            )
            if handshake == nil { try await Task.sleep(for: .milliseconds(20)) }
        }
        let control = try #require(handshake)
        try await body(host, control, control.port)
        await server.stop()
    }

    private func call(
        _ method: String, _ path: String, port: Int, token: String, body: Data? = nil
    ) async throws -> (Int, Data) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    @Test func thePanelIsOneRequestAndCarriesNoKeyAndNoState() async throws {
        try await withServer { host, control, port in
            let (status, body) = try await call(
                "GET", "/decisions", port: port, token: control.token
            )
            #expect(status == 200)
            let decoded = try JSONDecoder().decode(
                ControlAPI.DecisionsStatus.self, from: body
            )
            #expect(decoded.lanes.map(\.id)
                    == ["typesafe", "laya", "node", "local"])
            #expect(decoded.abilities.count == JevFeature.allCases.count)
            // The two facts the owner is entitled to, on every lane.
            #expect(decoded.lanes.first { $0.id == "typesafe" }?.costsMoney == true)
            #expect(decoded.lanes.first { $0.id == "laya" }?.costsMoney == false)
            #expect(decoded.lanes.first { $0.id == "laya" }?.leavesTheMac == false)
            // A node is free and still leaves the machine: two questions, two answers.
            #expect(decoded.lanes.first { $0.id == "node" }?.costsMoney == false)
            #expect(decoded.lanes.first { $0.id == "node" }?.leavesTheMac == true)
            // The licence of the weights and of the port are both surfaced.
            let laya = try #require(decoded.lanes.first { $0.id == "laya" }?.laya)
            #expect(laya.licence == "Apache-2.0")
            #expect(laya.weightsAttribution.contains("Convai Innovations"))
            #expect(laya.portAttribution.contains("MLX port"))
            #expect(laya.package == "laya-mlx==0.1.0")
            #expect(laya.checkpoints.count == 3)
            #expect(laya.checkpoints.allSatisfy { $0.revision.count == 40 })

            let text = String(decoding: body, as: UTF8.self)
            #expect(!text.contains("sk-"), "no key ever appears on this route")
            #expect(!text.lowercased().contains("apikey"))
        }
    }

    /// The three write routes spend the owner's money, their disk, or change how the Mac
    /// decides. All three take the Mac's own token and nothing else.
    @Test func everyWriteRouteRefusesAnythingButTheControlToken() async throws {
        try await withServer { host, control, port in
            // The swarm secret is a credential on most routes here. Not these.
            let refusals: [(String, String, Data?, String)] = [
                ("POST", "/decisions/lanes",
                 try JSONEncoder().encode(ControlAPI.DecisionLanesUpdate(layaEnabled: false)),
                 ControlServer.decisionLanesRefusal),
                ("POST", "/decisions/install",
                 try JSONEncoder().encode(ControlAPI.DecisionInstallRequest()),
                 ControlServer.decisionInstallRefusal),
                ("POST", "/decisions/test",
                 try JSONEncoder().encode(ControlAPI.DecisionTestRequest(
                    lane: "laya", state: .string("s"),
                    questions: ["q": .init(type: "noul", instructions: .string("?"))]
                 )),
                 ControlServer.decisionTestRefusal),
                ("POST", "/decisions/calibrate", nil,
                 ControlServer.jevCalibrateRefusal),
            ]
            for (method, path, body, sentence) in refusals {
                let (status, answer) = try await call(
                    method, path, port: port, token: "a-guessed-token", body: body
                )
                // An unknown bearer never even identifies, so it is a 401 before scope.
                #expect(status == 401, "\(path) accepted a guessed token")
                _ = answer
                _ = sentence
            }
            // And with the right token they are reached.
            let (ok, _) = try await call(
                "POST", "/decisions/lanes", port: port, token: control.token,
                body: try JSONEncoder().encode(
                    ControlAPI.DecisionLanesUpdate(layaEnabled: true)
                )
            )
            #expect(ok == 200)
            #expect(await host.laneUpdates == 1)
        }
    }

    /// Every unknown word is refused with a sentence naming the legal ones, rather than
    /// being ignored — a lane word that silently did nothing would leave the owner
    /// believing an ability was pinned away from the cloud when it was not.
    @Test func unknownLanesCheckpointsAndOverridesAreRefusedBySentence() async throws {
        try await withServer { host, control, port in
            let cases: [(String, Data, String)] = [
                ("/decisions/lanes",
                 try JSONEncoder().encode(
                    ControlAPI.DecisionLanesUpdate(layaCheckpoint: "quantum")),
                 ControlAPI.DecisionLaneVocabulary.unknownCheckpoint("quantum")),
                ("/decisions/lanes",
                 try JSONEncoder().encode(
                    ControlAPI.DecisionLanesUpdate(overrides: ["routing": "alwaysNode"])),
                 ControlAPI.DecisionLaneVocabulary.unknownOverride("alwaysNode")),
                ("/decisions/test",
                 try JSONEncoder().encode(ControlAPI.DecisionTestRequest(
                    lane: "somewhere", state: .string("s"),
                    questions: ["q": .init(type: "noul", instructions: .string("?"))])),
                 ControlAPI.DecisionLaneVocabulary.unknownLane("somewhere")),
            ]
            for (path, body, sentence) in cases {
                let (status, answer) = try await call(
                    "POST", path, port: port, token: control.token, body: body
                )
                #expect(status == 400, "\(path) accepted a word it does not know")
                // Compared against the decoded `error`, not the raw body: the quotes the
                // sentence puts around the offending word are escaped on the wire.
                let reason = (try? JSONSerialization.jsonObject(with: answer)
                              as? [String: Any])?["error"] as? String
                #expect(reason == sentence)
            }
        }
    }

    /// `GET /jev/calibration` and `POST /jev/calibrate` keep working exactly as they did,
    /// and grow a lane. An empty body is still the old route.
    @Test func theCalibrationRoutesStayAdditive() async throws {
        try await withServer { host, control, port in
            let (missing, _) = try await call(
                "GET", "/jev/calibration", port: port, token: control.token
            )
            #expect(missing == 404, "no run yet is still a 404 with a sentence")

            await host.setCalibration(.fixture(lane: "local"), for: "local")
            let (found, body) = try await call(
                "GET", "/jev/calibration", port: port, token: control.token
            )
            #expect(found == 200)
            #expect(try JSONDecoder().decode(
                ControlAPI.JevCalibration.self, from: body
            ).lane == "local")

            // And with a lane, the lane's own.
            await host.setCalibration(.fixture(lane: "laya"), for: "laya")
            let (laneFound, laneBody) = try await call(
                "GET", "/jev/calibration?lane=laya", port: port, token: control.token
            )
            #expect(laneFound == 200)
            #expect(try JSONDecoder().decode(
                ControlAPI.JevCalibration.self, from: laneBody
            ).lane == "laya")

            // A word that is not a lane is a 400 with the same sentence POST gives it — not
            // a 404 saying that lane has never been calibrated. A known lane with no run yet
            // is still the 404.
            let (unknown, unknownBody) = try await call(
                "GET", "/jev/calibration?lane=quantum", port: port, token: control.token
            )
            #expect(unknown == 400)
            #expect((try? JSONSerialization.jsonObject(with: unknownBody)
                     as? [String: Any])?["error"] as? String
                    == ControlAPI.DecisionLaneVocabulary.unknownLane("quantum"))
            let (notYet, _) = try await call(
                "GET", "/jev/calibration?lane=node", port: port, token: control.token
            )
            #expect(notYet == 404)

            // An empty body is the route as it always was.
            let (old, _) = try await call(
                "POST", "/jev/calibrate", port: port, token: control.token
            )
            #expect(old == 200)
            #expect(await host.calibratedLanes == [nil])

            let (lane, _) = try await call(
                "POST", "/jev/calibrate", port: port, token: control.token,
                body: try JSONEncoder().encode(
                    ControlAPI.DecisionCalibrateRequest(lane: "laya"))
            )
            #expect(lane == 200)
            #expect(await host.calibratedLanes == [nil, "laya"])
        }
    }

    /// A host that is not the Mac app answers 501 rather than pretending it has lanes —
    /// and the route that existed before still forwards to the implementation it always
    /// had, which is what keeps the MCP bridge's doubles working.
    @Test func aHostWithoutLanesSaysSoAndKeepsTheOldRoute() async throws {
        let bare = BareDecisionHost()
        let status = await bare.decisionsStatus()
        #expect(status.lanes.isEmpty)
        await #expect(throws: ControlAPI.DecisionsUnsupported.self) {
            _ = try await bare.runDecisionTest(.init(
                lane: "laya", state: .string("s"),
                questions: ["q": .init(type: "noul", instructions: .string("?"))]
            ))
        }
        // No lane, or the lane that used to be the only one, still reaches `calibrateJev`.
        #expect(try await bare.calibrateDecisionLane(nil).lane == nil)
        #expect(try await bare.calibrateDecisionLane("local").lane == nil)
        await #expect(throws: ControlAPI.DecisionsUnsupported.self) {
            _ = try await bare.calibrateDecisionLane("laya")
        }
        #expect(ControlAPI.DecisionsUnsupported().status == 501)
    }
}

extension ControlAPI.JevCalibration {
    static func fixture(lane: String?) -> ControlAPI.JevCalibration {
        .init(
            lane: lane, modelID: "m", modelName: "M", jevModel: JevService.pinnedModel,
            date: ControlAPI.timestamp(Date()), cases: 40, builtInCases: 40, userCases: 0,
            comparisons: 120, agreement: [], overallAgreementRate: 0.9,
            floors: .init(confidence: 0.6, noulLow: 0.25, noulHigh: 0.75),
            escalationRate: 0.2, choiceFloorMeasured: true, scoreFloorMeasured: true,
            noulBandMeasured: true, bins: [], inputTokens: 100, estimatedUSD: 0.01
        )
    }
}
