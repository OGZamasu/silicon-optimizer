import Foundation
import SiliconControl

/// Errors from either decision lane.
public enum SystemOneError: Error, LocalizedError, Equatable {
    case noAPIKey
    case http(Int, String)
    /// 429 and 529 — "come back later", with the server's own `retry-after` in seconds
    /// when it sent one. Its own case because it is the only failure worth retrying: every
    /// other status means the request itself was wrong and will be wrong again.
    case overloaded(status: Int, retryAfter: TimeInterval?, detail: String)
    case tooManyOptions(question: String, count: Int)
    case noAnswer(question: String)
    case notLogprobCapable

    public var errorDescription: String? {
        switch self {
        case .noAPIKey:
            "No TypeSafe API key is set. Add one in Settings → TypeSafe (Jev), or use the local lane."
        case .http(let status, let detail):
            "TypeSafe answered HTTP \(status)\(detail.isEmpty ? "." : ": \(detail)")"
        case .overloaded(let status, _, let detail):
            status == 429
                ? "TypeSafe is rate limiting this key\(detail.isEmpty ? "." : ": \(detail)")"
                : "TypeSafe is overloaded\(detail.isEmpty ? "." : ": \(detail)")"
        case .tooManyOptions(let question, let count):
            "Question \"\(question)\" has \(count) options; the local lane answers with one letter, so 26 is the most it can offer."
        case .noAnswer(let question):
            "The loaded model did not answer question \"\(question)\" with one of its options."
        case .notLogprobCapable:
            "The loaded runtime does not report token probabilities, which the local decision lane needs. Load a GGUF model with llama.cpp."
        }
    }
}

// MARK: - TypeSafe

/// TypeSafe's hosted System One endpoint (`POST /v1/systemone`), and anything else that
/// speaks the same shape — a swarm node with the route, say. The body is exactly what the
/// official SDK sends: `state`, `model`, `questions`.
public struct SystemOneClient: Sendable {
    public static let typeSafeBaseURL = URL(string: "https://api.typesafe.ai")!
    public static let defaultModel = "jev-latest"

    public let baseURL: URL
    private let apiKey: String
    private let session: URLSession

    public init(baseURL: URL = typeSafeBaseURL, apiKey: String, session: URLSession? = nil) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session ?? {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 60
            return URLSession(configuration: configuration)
        }()
    }

    struct WireRequest: Encodable {
        var state: JSONContent
        var model: String
        var questions: [String: ControlAPI.SystemOneQuestion]
    }

    static func body(for request: ControlAPI.DecideRequest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(WireRequest(
            state: request.state,
            model: request.model ?? defaultModel,
            questions: request.questions
        ))
    }

    public func decide(_ request: ControlAPI.DecideRequest) async throws -> ControlAPI.DecideResponse {
        try request.validate()
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SystemOneError.noAPIKey
        }
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("v1/systemone"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("silicon-optimizer", forHTTPHeaderField: "User-Agent")
        urlRequest.httpBody = try Self.body(for: request)

        let started = Date()
        let (data, response) = try await session.data(for: urlRequest)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw Self.failure(status: status, headers: http, data: data)
        }
        var decoded = try JSONDecoder().decode(ControlAPI.DecideResponse.self, from: data)
        decoded.provider = baseURL == Self.typeSafeBaseURL ? "typesafe" : baseURL.host ?? "remote"
        decoded.latencyMS = Date().timeIntervalSince(started) * 1000
        return decoded
    }

    /// The model names this key may send, from `GET /v1/models`. Costs no tokens, which is
    /// what makes it the right way to check a key.
    public func models() async throws -> [String] {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SystemOneError.noAPIKey
        }
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("v1/models"))
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("silicon-optimizer", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: urlRequest)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw Self.failure(status: status, headers: http, data: data)
        }
        struct Listing: Decodable {
            struct Model: Decodable { var name: String }
            var models: [Model]
        }
        return try JSONDecoder().decode(Listing.self, from: data).models.map(\.name)
    }

    /// Splits "try again" from "you asked wrong", and carries the server's `retry-after`
    /// across so a caller's backoff can honour it rather than guess.
    static func failure(
        status: Int, headers: HTTPURLResponse?, data: Data
    ) -> SystemOneError {
        let detail = detail(in: data)
        guard status == 429 || status == 529 else { return .http(status, detail) }
        return .overloaded(
            status: status, retryAfter: retryAfter(in: headers), detail: detail
        )
    }

    /// `Retry-After` is either a count of seconds or an HTTP date; both are read, and
    /// anything else is nil so the caller falls back to its own backoff.
    static func retryAfter(in response: HTTPURLResponse?) -> TimeInterval? {
        guard let raw = (response?.value(forHTTPHeaderField: "Retry-After"))?
            .trimmingCharacters(in: .whitespaces), !raw.isEmpty
        else { return nil }
        if let seconds = TimeInterval(raw) { return max(0, seconds) }
        guard let date = httpDateFormatter.date(from: raw) else { return nil }
        return max(0, date.timeIntervalSinceNow)
    }

    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    /// TypeSafe's error bodies carry `detail` (a string, or FastAPI's list of validation
    /// errors). Whatever is there, shortened, beats "HTTP 422".
    static func detail(in data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(decoding: data.prefix(200), as: UTF8.self)
        }
        if let detail = object["detail"] as? String { return detail }
        if let errors = object["detail"] as? [[String: Any]] {
            return errors.prefix(3).compactMap { error in
                let location = (error["loc"] as? [Any])?.map { "\($0)" }.joined(separator: ".") ?? ""
                let message = error["msg"] as? String ?? ""
                return location.isEmpty ? message : "\(location): \(message)"
            }.joined(separator: "; ")
        }
        if let error = object["error"] as? String { return error }
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        return String(decoding: data.prefix(200), as: UTF8.self)
    }
}

// MARK: - Local

/// The same decision function on the model loaded here. Each question is one forward pass:
/// the state and the lettered options go in through the chat template, one token comes out,
/// and the distribution over the answer letters is read straight from the logits. No
/// generation loop, so a question costs prefill and nothing else; the state leads the prompt
/// so the server's prompt cache carries it from one question to the next.
///
/// What this lacks against Jev is calibration training: the probabilities are the model's
/// own, not tuned to mean what they say. They still rank the options and still expose
/// uncertainty, which is what a caller thresholds on.
public struct LocalDecider: Sendable {
    public let endpoint: URL
    public let modelName: String
    private let session: URLSession
    /// Questions in flight at once. Two keeps a second slot busy while the first is in
    /// prefill without thrashing the cache on a single-slot server.
    public var maxConcurrency = 2
    /// How many candidates to read back. Letters that fall outside get probability zero,
    /// which is the right answer for a candidate the model would never have chosen.
    public var topLogprobs = 20

    public init(endpoint: URL, modelName: String, session: URLSession? = nil) {
        self.endpoint = endpoint
        self.modelName = modelName
        self.session = session ?? {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 600
            return URLSession(configuration: configuration)
        }()
    }

    static let letters: [String] = (0..<26).map { String(UnicodeScalar(UInt8(65 + $0))) }

    enum Kind { case noul, choice, score }

    /// One question, resolved to lettered options and the messages that ask it.
    struct Plan: Equatable {
        var name: String
        var kind: Kind
        /// Wire keys in option order: labels for a choice, "0"… for a score, yes/no for a noul.
        var keys: [String]
        var legend: [String: JSONContent]
        var messages: [[String: String]]

        var letters: [String] { Array(LocalDecider.letters.prefix(keys.count)) }
    }

    static let systemPrompt = """
        You are a decision function, not a chat assistant. You will be shown a STATE and one \
        QUESTION with lettered options. Read the state, then reply with the single letter of \
        the best option and nothing else. Never explain.
        """

    static func plan(name: String, question: ControlAPI.SystemOneQuestion, state: JSONContent) throws -> Plan {
        try question.validate(name: name)
        var keys: [String] = []
        var lines: [String] = []
        var legend: [String: JSONContent] = [:]
        let kind: Kind
        let defaultInstructions: String

        switch question.type {
        case "choice":
            kind = .choice
            defaultInstructions = "Which option best describes the state?"
            // A JSON object has no order; sorted keys make the prompt, and so the cache,
            // deterministic for the same question.
            let criteria = question.criteria?.objectValue ?? [:]
            for label in criteria.keys.sorted() {
                keys.append(label)
                let description = criteria[label].map(\.promptText) ?? ""
                lines.append(description.isEmpty || description == "null" ? label : "\(label): \(description)")
            }
        case "score":
            kind = .score
            defaultInstructions = "Rate the state on the scale below, lowest first."
            for (level, description) in (question.criteria?.arrayValue ?? []).enumerated() {
                keys.append(String(level))
                legend[String(level)] = description
                lines.append("score \(level): \(description.promptText)")
            }
        default:
            kind = .noul
            defaultInstructions = "Is the following true of the state?"
            let criteria = question.criteria?.objectValue ?? [:]
            keys = ["yes", "no"]
            let yes = criteria["true"].map(\.promptText) ?? ""
            let no = criteria["false"].map(\.promptText) ?? ""
            lines = [
                yes.isEmpty || yes == "null" ? "Yes" : "Yes: \(yes)",
                no.isEmpty || no == "null" ? "No" : "No: \(no)",
            ]
        }
        guard keys.count <= letters.count else {
            throw SystemOneError.tooManyOptions(question: name, count: keys.count)
        }

        let instructions = question.instructions.map(\.promptText) ?? ""
        var user = "STATE:\n\(state.promptText)\n\n"
        user += "QUESTION: \(instructions.isEmpty ? defaultInstructions : instructions)\n"
        user += "OPTIONS:\n"
        for (index, line) in lines.enumerated() {
            user += "\(letters[index]). \(line)\n"
        }
        user += "\nReply with one letter."

        return Plan(
            name: name, kind: kind, keys: keys, legend: legend,
            messages: [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": user],
            ]
        )
    }

    /// The distribution over the option letters, from the model's top candidates for its
    /// first token. Candidates that are not a letter are dropped and the rest renormalised;
    /// a letter that never appeared gets zero.
    static func distribution(
        topLogprobs: [(token: String, logprob: Double)], letters: [String]
    ) -> [Double]? {
        var mass = [Double](repeating: 0, count: letters.count)
        var seen = false
        for candidate in topLogprobs {
            let token = candidate.token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let index = letters.firstIndex(of: token) else { continue }
            mass[index] = max(mass[index], exp(candidate.logprob))
            seen = true
        }
        guard seen else { return nil }
        let total = mass.reduce(0, +)
        return total > 0 ? mass.map { $0 / total } : nil
    }

    static func answer(for plan: Plan, probabilities: [Double]) -> ControlAPI.SystemOneAnswer {
        let best = probabilities.indices.max { probabilities[$0] < probabilities[$1] } ?? 0
        let confidence = probabilities[best]
        switch plan.kind {
        case .noul:
            return .noul(probabilities[0])
        case .choice:
            return .choice(
                choice: plan.keys[best], confidence: confidence,
                probabilities: Dictionary(uniqueKeysWithValues: zip(plan.keys, probabilities))
            )
        case .score:
            let expected = probabilities.enumerated().reduce(0.0) { $0 + Double($1.offset) * $1.element }
            return .score(
                score: expected, confidence: confidence, legend: plan.legend,
                probabilities: Dictionary(uniqueKeysWithValues: zip(plan.keys, probabilities))
            )
        }
    }

    // MARK: Wire

    struct WireRequest: Encodable {
        var messages: [[String: String]]
        var max_tokens = 1
        var temperature = 0.0
        var logprobs = true
        var top_logprobs: Int
        var cache_prompt = true
        /// Reasoning models would spend the one token opening a think block.
        var chat_template_kwargs = ["enable_thinking": false]
    }

    struct WireResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { var content: String? }
            struct Logprobs: Decodable {
                struct Entry: Decodable {
                    struct Candidate: Decodable { var token: String; var logprob: Double }
                    var token: String?
                    var logprob: Double?
                    var top_logprobs: [Candidate]?
                }
                var content: [Entry]?
            }
            var message: Message?
            var logprobs: Logprobs?
        }
        struct Usage: Decodable { var prompt_tokens: Int?; var completion_tokens: Int? }
        var choices: [Choice]
        var usage: Usage?
    }

    func ask(_ plan: Plan) async throws -> (ControlAPI.SystemOneAnswer, ControlAPI.SystemOneUsage) {
        var urlRequest = URLRequest(url: endpoint.appendingPathComponent("v1/chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(WireRequest(
            messages: plan.messages, top_logprobs: max(topLogprobs, plan.keys.count)
        ))
        let (data, response) = try await session.data(for: urlRequest)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw SystemOneError.http(status, String(decoding: data.prefix(200), as: UTF8.self))
        }
        let decoded = try JSONDecoder().decode(WireResponse.self, from: data)
        let letters = plan.letters
        let candidates = decoded.choices.first?.logprobs?.content?.first?.top_logprobs?
            .map { (token: $0.token, logprob: $0.logprob) } ?? []

        var probabilities = Self.distribution(topLogprobs: candidates, letters: letters)
        if probabilities == nil {
            // No probabilities came back (a runtime without logprobs) or none of the
            // candidates was a letter. The sampled token alone is still an answer, one-hot.
            let content = decoded.choices.first?.message?.content?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let index = letters.firstIndex(of: content) else {
                throw candidates.isEmpty && decoded.choices.first?.logprobs == nil
                    ? SystemOneError.notLogprobCapable
                    : SystemOneError.noAnswer(question: plan.name)
            }
            var oneHot = [Double](repeating: 0, count: letters.count)
            oneHot[index] = 1
            probabilities = oneHot
        }
        let usage = ControlAPI.SystemOneUsage(
            inputTokens: decoded.usage?.prompt_tokens ?? 0,
            outputTokens: decoded.usage?.completion_tokens ?? 0
        )
        return (Self.answer(for: plan, probabilities: probabilities!), usage)
    }

    public func decide(_ request: ControlAPI.DecideRequest) async throws -> ControlAPI.DecideResponse {
        try request.validate()
        let plans = try request.questions.keys.sorted().map { name in
            try Self.plan(name: name, question: request.questions[name]!, state: request.state)
        }
        let started = Date()
        var answers: [String: ControlAPI.SystemOneAnswer] = [:]
        var usage = ControlAPI.SystemOneUsage(inputTokens: 0, outputTokens: 0)

        // Bounded fan-out: chunks of `maxConcurrency`, each chunk in a task group.
        for chunk in stride(from: 0, to: plans.count, by: max(1, maxConcurrency)) {
            let slice = plans[chunk..<min(chunk + max(1, maxConcurrency), plans.count)]
            try await withThrowingTaskGroup(of: (String, ControlAPI.SystemOneAnswer, ControlAPI.SystemOneUsage).self) { group in
                for plan in slice {
                    group.addTask {
                        let (answer, used) = try await ask(plan)
                        return (plan.name, answer, used)
                    }
                }
                for try await (name, answer, used) in group {
                    answers[name] = answer
                    usage.inputTokens += used.inputTokens
                    usage.outputTokens += used.outputTokens
                }
            }
        }
        return ControlAPI.DecideResponse(
            model: modelName, usage: usage, answers: answers,
            provider: "local", latencyMS: Date().timeIntervalSince(started) * 1000
        )
    }
}
