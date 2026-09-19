import Foundation
import Network
import Testing
@testable import SiliconControl
@testable import SiliconRuntime

@Suite("System One wire shape")
struct SystemOneWireTests {

    /// TypeSafe's SDK sends exactly `state`, `model`, `questions`, with a question's unset
    /// fields left off. Anything else is a 422 from their side.
    @Test func requestBodyIsTypeSafesOwn() throws {
        let request = ControlAPI.DecideRequest(
            state: .object(["ticket": .string("Charged twice")]),
            questions: [
                "department": .init(
                    type: "choice", instructions: .string("Which team"),
                    criteria: .object(["billing": .string("Payment issues"), "technical": .null])
                ),
                "urgent": .init(type: "noul"),
                "anger": .init(type: "score", criteria: .array([.string("Calm"), .string("Angry")])),
            ],
            provider: "typesafe"
        )
        let body = try JSONSerialization.jsonObject(with: SystemOneClient.body(for: request)) as! [String: Any]
        #expect(Set(body.keys) == ["state", "model", "questions"])
        #expect(body["model"] as? String == "jev-latest")
        let questions = body["questions"] as! [String: [String: Any]]
        #expect(questions["urgent"]! as NSDictionary == ["type": "noul"] as NSDictionary)
        let department = questions["department"]!
        #expect(department["type"] as? String == "choice")
        #expect((department["criteria"] as! [String: Any])["technical"] is NSNull)
        #expect(questions["anger"]!["criteria"] as? [String] == ["Calm", "Angry"])
    }

    /// The examples in TypeSafe's OpenAPI document decode as-is.
    @Test func typeSafeResponseDecodes() throws {
        let json = """
            {"model":"jev-1.13.0","usage":{"input_tokens":120,"output_tokens":12},
             "answers":{
               "tone":{"type":"choice","choice":"angry","confidence":0.9,"probabilities":{"angry":0.8,"calm":0.1,"excited":0.1}},
               "spam":{"type":"noul","noul":0.98},
               "urgency":{"type":"score","score":1.7,"confidence":0.9,
                          "legend":{"0":"Can wait","1":"This week","2":"Today"},
                          "probabilities":{"0":0.1,"1":0.1,"2":0.8}}}}
            """
        let response = try JSONDecoder().decode(ControlAPI.DecideResponse.self, from: Data(json.utf8))
        #expect(response.model == "jev-1.13.0")
        #expect(response.usage.inputTokens == 120)
        #expect(response.answers["spam"] == .noul(0.98))
        guard case .choice(let choice, let confidence, let probabilities) = response.answers["tone"] else {
            Issue.record("tone should be a choice"); return
        }
        #expect(choice == "angry" && confidence == 0.9 && probabilities["calm"] == 0.1)
        guard case .score(let score, _, let legend, let probabilities2) = response.answers["urgency"] else {
            Issue.record("urgency should be a score"); return
        }
        #expect(score == 1.7 && legend["2"] == .string("Today") && probabilities2["2"] == 0.8)

        // And it round-trips: what we encode is what they sent, plus our two fields.
        let again = try JSONDecoder().decode(ControlAPI.DecideResponse.self, from: JSONEncoder().encode(response))
        #expect(again == response)
    }

    @Test func malformedQuestionsAreNamed() {
        let bad = ControlAPI.DecideRequest(
            state: .string("x"),
            questions: ["mood": .init(type: "choice")]
        )
        #expect(throws: ControlAPI.SystemOneValidationError.self) { try bad.validate() }
        let empty = ControlAPI.DecideRequest(state: .string("x"), questions: [:])
        #expect(throws: ControlAPI.SystemOneValidationError.self) { try empty.validate() }
        let score = ControlAPI.DecideRequest(
            state: .string("x"), questions: ["s": .init(type: "score", criteria: .array([]))]
        )
        #expect(throws: ControlAPI.SystemOneValidationError.self) { try score.validate() }
    }

    @Test func promptTextIsStableForObjects() {
        let a = JSONContent.object(["b": .number(2), "a": .array([.string("x"), .bool(true)])])
        #expect(a.promptText == #"{"a":["x",true],"b":2}"#)
        #expect(JSONContent.string("plain").promptText == "plain")
    }
}

@Suite("Local decision lane")
struct LocalDeciderTests {
    private let state = JSONContent.string("Customer: charged twice for order A-104, wants it fixed now.")

    @Test func choiceBecomesLetteredOptionsInSortedOrder() throws {
        let plan = try LocalDecider.plan(
            name: "department",
            question: .init(
                type: "choice", instructions: .string("Which team?"),
                criteria: .object(["technical": .string("Bugs"), "billing": .string("Payments")])
            ),
            state: state
        )
        #expect(plan.keys == ["billing", "technical"])
        #expect(plan.letters == ["A", "B"])
        let user = plan.messages[1]["content"]!
        #expect(user.hasPrefix("STATE:\nCustomer: charged twice"))
        #expect(user.contains("QUESTION: Which team?"))
        #expect(user.contains("A. billing: Payments\nB. technical: Bugs"))
    }

    @Test func scoreAndNoulPlans() throws {
        let score = try LocalDecider.plan(
            name: "urgency",
            question: .init(type: "score", criteria: .array([.string("Can wait"), .string("Today")])),
            state: state
        )
        #expect(score.keys == ["0", "1"])
        #expect(score.legend["1"] == .string("Today"))
        #expect(score.messages[1]["content"]!.contains("A. score 0: Can wait\nB. score 1: Today"))

        let noul = try LocalDecider.plan(
            name: "refund",
            question: .init(type: "noul", instructions: .string("Asks for a refund"),
                            criteria: .object(["true": .string("Explicitly wants money back")])),
            state: state
        )
        #expect(noul.keys == ["yes", "no"])
        #expect(noul.messages[1]["content"]!.contains("A. Yes: Explicitly wants money back\nB. No\n"))
    }

    @Test func moreThan26OptionsIsRefused() {
        let labels = Dictionary(uniqueKeysWithValues: (0..<27).map { ("label\($0)", JSONContent.null) })
        #expect(throws: SystemOneError.self) {
            try LocalDecider.plan(
                name: "big", question: .init(type: "choice", criteria: .object(labels)), state: state
            )
        }
    }

    /// Candidates that are not letters are dropped; the letters renormalise; a letter the
    /// model never considered is zero, not missing.
    @Test func distributionComesFromTheLetterCandidatesOnly() throws {
        let candidates: [(token: String, logprob: Double)] = [
            ("A", log(0.6)), (" B", log(0.2)), ("Answer", log(0.15)), ("<think>", log(0.05)),
        ]
        let probabilities = try #require(LocalDecider.distribution(topLogprobs: candidates, letters: ["A", "B", "C"]))
        #expect(abs(probabilities[0] - 0.75) < 1e-9)
        #expect(abs(probabilities[1] - 0.25) < 1e-9)
        #expect(probabilities[2] == 0)
        #expect(LocalDecider.distribution(topLogprobs: [("x", 0)], letters: ["A"]) == nil)
    }

    @Test func answersFollowTheDistribution() throws {
        let choice = try LocalDecider.plan(
            name: "c", question: .init(type: "choice", criteria: .object(["no": .null, "yes": .null])), state: state
        )
        #expect(LocalDecider.answer(for: choice, probabilities: [0.3, 0.7])
            == .choice(choice: "yes", confidence: 0.7, probabilities: ["no": 0.3, "yes": 0.7]))

        let score = try LocalDecider.plan(
            name: "s", question: .init(type: "score", criteria: .array([.string("0"), .string("1"), .string("2")])), state: state
        )
        guard case .score(let expected, let confidence, _, _) = LocalDecider.answer(for: score, probabilities: [0.1, 0.1, 0.8]) else {
            Issue.record("expected a score"); return
        }
        #expect(abs(expected - 1.7) < 1e-9 && confidence == 0.8)

        let noul = try LocalDecider.plan(name: "n", question: .init(type: "noul"), state: state)
        #expect(LocalDecider.answer(for: noul, probabilities: [0.9, 0.1]) == .noul(0.9))
    }

    /// Against a fake llama-server: one request per question with max_tokens 1 and logprobs
    /// on, answers assembled from the top candidates, usage summed.
    @Test func asksTheServerOncePerQuestion() async throws {
        let server = try CapturingServer { _ in
            """
            {"choices":[{"message":{"content":"A"},"logprobs":{"content":[{"token":"A","logprob":-0.05,
              "top_logprobs":[{"token":"A","logprob":-0.05},{"token":"B","logprob":-3.0}]}]}}],
             "usage":{"prompt_tokens":40,"completion_tokens":1}}
            """
        }
        defer { server.stop() }
        let decider = LocalDecider(
            endpoint: URL(string: "http://127.0.0.1:\(server.port)")!, modelName: "Test 1B"
        )
        let response = try await decider.decide(.init(
            state: state,
            questions: [
                "refund": .init(type: "noul"),
                "team": .init(type: "choice", criteria: .object(["billing": .null, "tech": .null])),
            ]
        ))
        #expect(response.provider == "local" && response.model == "Test 1B")
        #expect(response.usage.inputTokens == 80)
        #expect(server.requests.count == 2)
        let body = try JSONSerialization.jsonObject(with: server.requests[0].body) as! [String: Any]
        #expect(body["max_tokens"] as? Int == 1 && body["logprobs"] as? Bool == true)
        #expect((body["chat_template_kwargs"] as? [String: Bool])?["enable_thinking"] == false)
        guard case .noul(let p) = response.answers["refund"] else { Issue.record("noul"); return }
        #expect(p > 0.9)
        guard case .choice(let label, _, _) = response.answers["team"] else { Issue.record("choice"); return }
        #expect(label == "billing")
    }
}

@Suite("TypeSafe client")
struct SystemOneClientTests {
    @Test func postsToSystemOneWithBearer() async throws {
        let server = try CapturingServer { _ in
            #"{"model":"jev-1.13.0","usage":{"input_tokens":9,"output_tokens":1},"answers":{"ok":{"type":"noul","noul":0.42}}}"#
        }
        defer { server.stop() }
        let client = SystemOneClient(
            baseURL: URL(string: "http://127.0.0.1:\(server.port)")!, apiKey: "sk-test"
        )
        let response = try await client.decide(.init(state: .string("s"), questions: ["ok": .init(type: "noul")]))
        #expect(response.answers["ok"] == .noul(0.42))
        #expect(response.provider == "127.0.0.1")
        #expect(response.latencyMS ?? 0 > 0)
        let request = try #require(server.requests.first)
        #expect(request.path == "/v1/systemone")
        #expect(request.headers["authorization"] == "Bearer sk-test")
        let body = try JSONSerialization.jsonObject(with: request.body) as! [String: Any]
        #expect(body["model"] as? String == "jev-latest")
    }

    @Test func errorsCarryTypeSafesDetail() async throws {
        let server = try CapturingServer(status: 422) { _ in
            #"{"detail":[{"loc":["body","questions","x","criteria"],"msg":"Field required","type":"missing"}]}"#
        }
        defer { server.stop() }
        let client = SystemOneClient(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!, apiKey: "k")
        await #expect(throws: SystemOneError.http(422, "body.questions.x.criteria: Field required")) {
            try await client.decide(.init(state: .string("s"), questions: ["x": .init(type: "noul")]))
        }
    }

    @Test func refusesWithoutAKey() async {
        let client = SystemOneClient(apiKey: "  ")
        await #expect(throws: SystemOneError.noAPIKey) {
            try await client.decide(.init(state: .string("s"), questions: ["x": .init(type: "noul")]))
        }
    }
}

// MARK: - Fixture

/// A loopback HTTP server that records each request (path, headers, body) and answers with a
/// canned JSON body.
final class CapturingServer: @unchecked Sendable {
    struct Recorded { var path: String; var headers: [String: String]; var body: Data }

    /// One canned answer. Statuses and headers are per-call, not per-server, because a
    /// backoff test needs "429 with a retry-after, then 429, then 200" from one socket.
    struct Answer {
        var status = 200
        var headers: [String: String] = [:]
        var body: String

        init(status: Int = 200, headers: [String: String] = [:], body: String) {
            self.status = status
            self.headers = headers
            self.body = body
        }
    }

    private let listener: NWListener
    private let lock = NSLock()
    /// Given the request and how many have already been served, what to answer.
    private let answer: @Sendable (Recorded, Int) -> Answer
    private(set) var port: UInt16 = 0
    private var recorded: [Recorded] = []

    var requests: [Recorded] { lock.lock(); defer { lock.unlock() }; return recorded }

    convenience init(status: Int = 200, respond: @escaping @Sendable (Recorded) -> String) throws {
        try self.init { request, _ in Answer(status: status, body: respond(request)) }
    }

    init(answer: @escaping @Sendable (Recorded, Int) -> Answer) throws {
        self.answer = answer
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        listener = try NWListener(using: parameters, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in if case .ready = state { ready.signal() } }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: DispatchQueue(label: "capturing-server"))
        ready.wait()
        port = listener.port?.rawValue ?? 0
    }

    func stop() { listener.cancel() }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: DispatchQueue(label: "capturing-conn"))
        var buffer = Data()
        func readMore() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) {
                [weak self] data, _, _, error in
                guard let self, error == nil, let data else { connection.cancel(); return }
                buffer.append(data)
                guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { readMore(); return }
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                var headers: [String: String] = [:]
                for line in head.split(separator: "\r\n").dropFirst() {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
                let length = Int(headers["content-length"] ?? "0") ?? 0
                let bodyStart = end.upperBound
                guard buffer.count - bodyStart >= length else { readMore(); return }
                let path = head.split(separator: "\r\n").first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                let record = Recorded(path: path, headers: headers, body: buffer[bodyStart..<(bodyStart + length)])
                self.lock.lock()
                let served = self.recorded.count
                self.recorded.append(record)
                self.lock.unlock()
                let canned = self.answer(record, served)
                let body = Data(canned.body.utf8)
                var responseHead = "HTTP/1.1 \(canned.status) X\r\nContent-Type: application/json\r\n"
                    + "Content-Length: \(body.count)\r\nConnection: close\r\n"
                for (name, value) in canned.headers.sorted(by: { $0.key < $1.key }) {
                    responseHead += "\(name): \(value)\r\n"
                }
                var response = Data((responseHead + "\r\n").utf8)
                response.append(body)
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        readMore()
    }
}
