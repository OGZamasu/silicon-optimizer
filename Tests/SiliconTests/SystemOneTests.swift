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
                "urgent": .init(type: "noul", instructions: .string("Is this urgent?")),
                "anger": .init(type: "score", instructions: .string("How angry?"),
                               criteria: .array([.string("Calm"), .string("Angry")])),
            ],
            provider: "typesafe"
        )
        let body = try JSONSerialization.jsonObject(with: SystemOneClient.body(for: request)) as! [String: Any]
        #expect(Set(body.keys) == ["state", "model", "questions"])
        #expect(body["model"] as? String == "jev-latest")
        let questions = body["questions"] as! [String: [String: Any]]
        #expect(questions["urgent"]?["type"] as? String == "noul")
        #expect(questions["urgent"]?["instructions"] as? String == "Is this urgent?")
        #expect(questions["urgent"]?["criteria"] == nil)
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
            questions: ["mood": .init(type: "choice", instructions: .string("Which mood?"))]
        )
        #expect(throws: ControlAPI.SystemOneValidationError.self) { try bad.validate() }
        let empty = ControlAPI.DecideRequest(state: .string("x"), questions: [:])
        #expect(throws: ControlAPI.SystemOneValidationError.self) { try empty.validate() }
        let score = ControlAPI.DecideRequest(
            state: .string("x"),
            questions: ["s": .init(type: "score", instructions: .string("How bad?"),
                                   criteria: .array([]))]
        )
        #expect(throws: ControlAPI.SystemOneValidationError.self) { try score.validate() }

        // And the instruction itself is required, on all three kinds. A rubric with no
        // question attached is not a question: `jev-1.13` answers what was written.
        for kind in [
            ControlAPI.SystemOneQuestion(type: "noul"),
            .init(type: "choice", criteria: .object(["a": .null])),
            .init(type: "score", criteria: .array([.string("low"), .string("high")])),
            .init(type: "noul", instructions: .string("   ")),
            .init(type: "noul", instructions: .null),
        ] {
            #expect(throws: ControlAPI.SystemOneValidationError.self) {
                try kind.validate(name: "q")
            }
        }
    }

    /// The accessors a feature reads answers with, including what they do when the id is
    /// wrong — which is the whole reason they exist.
    @Test func typedAccessorsReadAnswersOrSayWhyNot() throws {
        let response = ControlAPI.DecideResponse(
            model: "jev-1.13.0", usage: .init(inputTokens: 10, outputTokens: 1),
            answers: [
                "refund": .noul(0.93),
                "team": .choice(choice: "billing", confidence: 0.82,
                                probabilities: ["billing": 0.82, "tech": 0.18]),
                "urgency": .score(score: 1.7, confidence: 0.78,
                                  legend: ["0": .string("Can wait"), "1": .string("Today")],
                                  probabilities: ["0": 0.3, "1": 0.7]),
            ]
        )
        #expect(try response.noul("refund") == 0.93)
        let team = try response.choice("team")
        #expect(team.choice == "billing" && team.confidence == 0.82)
        #expect(team.probabilities["tech"] == 0.18)
        let urgency = try response.score("urgency")
        #expect(urgency.score == 1.7 && urgency.legend["1"] == .string("Today"))
        #expect(urgency.probabilities["1"] == 0.7)

        // A misspelled id is an error, not a silently skipped branch.
        #expect(throws: ControlAPI.SystemOneAnswerError.missing("refunds", "noul")) {
            try response.noul("refunds")
        }
        #expect(throws: ControlAPI.SystemOneAnswerError.wrongKind(
            "refund", expected: "choice", found: "noul"
        )) { try response.choice("refund") }
        #expect(throws: ControlAPI.SystemOneAnswerError.self) { try response.score("team") }
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
            question: .init(type: "score", instructions: .string("How urgent?"),
                            criteria: .array([.string("Can wait"), .string("Today")])),
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
                name: "big",
                question: .init(type: "choice", instructions: .string("Which label?"),
                                criteria: .object(labels)),
                state: state
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
            name: "c",
            question: .init(type: "choice", instructions: .string("Yes or no?"),
                            criteria: .object(["no": .null, "yes": .null])),
            state: state
        )
        #expect(LocalDecider.answer(for: choice, probabilities: [0.3, 0.7])
            == .choice(choice: "yes", confidence: 0.7, probabilities: ["no": 0.3, "yes": 0.7]))

        let score = try LocalDecider.plan(
            name: "s",
            question: .init(type: "score", instructions: .string("How much?"),
                            criteria: .array([.string("0"), .string("1"), .string("2")])),
            state: state
        )
        guard case .score(let expected, let confidence, _, _) = LocalDecider.answer(for: score, probabilities: [0.1, 0.1, 0.8]) else {
            Issue.record("expected a score"); return
        }
        #expect(abs(expected - 1.7) < 1e-9 && confidence == 0.8)

        let noul = try LocalDecider.plan(
            name: "n", question: .init(type: "noul", instructions: .string("Is it so?")),
            state: state
        )
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
                "refund": .init(type: "noul", instructions: .string("Asks for a refund?")),
                "team": .init(type: "choice", instructions: .string("Which team?"),
                              criteria: .object(["billing": .null, "tech": .null])),
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
        let response = try await client.decide(.init(
            state: .string("s"),
            questions: ["ok": .init(type: "noul", instructions: .string("Is it ok?"))]
        ))
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
            try await client.decide(.init(
                state: .string("s"),
                questions: ["x": .init(type: "noul", instructions: .string("Is it x?"))]
            ))
        }
    }

    @Test func refusesWithoutAKey() async {
        let client = SystemOneClient(apiKey: "  ")
        await #expect(throws: SystemOneError.noAPIKey) {
            try await client.decide(.init(
                state: .string("s"),
                questions: ["x": .init(type: "noul", instructions: .string("Is it x?"))]
            ))
        }
    }

    /// Services echo the offending request into a 401, `Authorization` header and all. That
    /// body used to travel straight into the error, out of `POST /decide` as a 400 a paired
    /// phone could read, and onto the Settings screen as selectable text.
    @Test func aServerThatEchoesTheKeyBackDoesNotGetToPublishIt() async throws {
        let key = "sk-live-0123456789abcdefghijklmnop"
        for status in [401, 403] {
            let server = try CapturingServer { request, _ in
                .init(
                    status: status,
                    body: #"{"detail":"Bad credentials on \#(request.headers["authorization"] ?? "")"}"#
                )
            }
            defer { server.stop() }
            let client = SystemOneClient(
                baseURL: URL(string: "http://127.0.0.1:\(server.port)")!, apiKey: key
            )
            for attempt in [
                { try await client.decide(.init(
                    state: .string("s"),
                    questions: ["x": .init(type: "noul", instructions: .string("Is it x?"))]
                )) as Any },
                { try await client.models() as Any },
            ] {
                await #expect(throws: (any Error).self) { try await attempt() }
                do {
                    _ = try await attempt()
                } catch {
                    let text = "\(error) \(error.localizedDescription)"
                    #expect(!text.contains(key), "HTTP \(status) leaked the key")
                    #expect(!text.contains("Bearer"), "HTTP \(status) leaked the header")
                    #expect(text.contains(SystemOneClient.rejectedKey))
                }
            }
        }
    }

    /// Any other status keeps its detail, because it is useful — but scrubbed, because the
    /// body is the server's and the key is ours.
    @Test func otherStatusesKeepTheirDetailWithTheKeyScrubbedOut() async throws {
        let key = "sk-live-0123456789abcdefghijklmnop"
        let server = try CapturingServer { request, _ in
            .init(
                status: 422,
                body: #"{"detail":"rejected \#(request.headers["authorization"] ?? "") for questions.x"}"#
            )
        }
        defer { server.stop() }
        let client = SystemOneClient(
            baseURL: URL(string: "http://127.0.0.1:\(server.port)")!, apiKey: key
        )
        do {
            _ = try await client.decide(.init(
                state: .string("s"),
                questions: ["x": .init(type: "noul", instructions: .string("Is it x?"))]
            ))
            Issue.record("a 422 should have thrown")
        } catch {
            let text = "\(error) \(error.localizedDescription)"
            #expect(!text.contains(key) && !text.contains("Bearer"))
            #expect(text.contains("[redacted]"))
            #expect(text.contains("for questions.x"))
        }
        // A short string is not redacted — otherwise an ordinary word in a body would be.
        #expect(SystemOneClient.redacting("ab", in: "a body about ab") == "a body about ab")
    }

    /// Three ways to say "come back later", in order of precision.
    @Test func retryAfterReadsMillisecondsThenSecondsThenADate() {
        func response(_ headers: [String: String]) -> HTTPURLResponse? {
            HTTPURLResponse(
                url: URL(string: "https://api.typesafe.ai/v1/systemone")!, statusCode: 429,
                httpVersion: nil, headerFields: headers
            )
        }
        #expect(SystemOneClient.retryAfter(in: response(["retry-after-ms": "250"])) == 0.25)
        // Milliseconds win when both are sent: they are the more precise answer.
        #expect(SystemOneClient.retryAfter(
            in: response(["retry-after-ms": "250", "Retry-After": "9"])
        ) == 0.25)
        #expect(SystemOneClient.retryAfter(in: response(["Retry-After": "9"])) == 9)
        let soon = SystemOneClient.retryAfter(
            in: response(["Retry-After": "Fri, 18 Sep 2099 09:41:00 GMT"])
        )
        #expect((soon ?? 0) > 0)
        #expect(SystemOneClient.retryAfter(in: response(["Retry-After": "whenever"])) == nil)
        #expect(SystemOneClient.retryAfter(in: response([:])) == nil)
        #expect(SystemOneClient.retryAfter(in: nil) == nil)
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
