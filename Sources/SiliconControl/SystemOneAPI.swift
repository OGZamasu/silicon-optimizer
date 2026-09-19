import Foundation

/// A JSON value as it travels on the wire. A decision's state and every description inside a
/// question can each be text, an object, or an array; TypeSafe accepts all three and so does
/// the local lane, so the type is kept whole rather than flattened to a string on arrival.
public indirect enum JSONContent: Codable, Equatable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONContent])
    case object([String: JSONContent])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONContent].self) { self = .array(value) }
        else if let value = try? container.decode([String: JSONContent].self) { self = .object(value) }
        else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not JSON.")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            // 3 stays 3 on the wire, not 3.0 — TypeSafe's examples use integers for score
            // levels and a reader comparing bodies should not see a spurious fraction.
            if value == value.rounded(), abs(value) < 1e15 { try container.encode(Int64(value)) }
            else { try container.encode(value) }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONContent]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONContent]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// The value as a prompt can carry it: text verbatim, anything else as compact JSON with
    /// stable key order, so the same state produces the same prompt and the server's prompt
    /// cache gets to do its job.
    public var promptText: String {
        if case .string(let value) = self { return value }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

extension ControlAPI {

    /// One typed question, in TypeSafe's own wire form, so a request written for Jev is
    /// accepted here without translation. Three kinds exist:
    ///
    /// - `noul`: a yes/no; `criteria` may describe the `true` and `false` outcomes.
    /// - `choice`: one label from `criteria`, an object of label → description (or null).
    /// - `score`: one level of an ordered rubric; `criteria` is a non-empty array whose
    ///   position is the score, counting from zero.
    public struct SystemOneQuestion: Codable, Equatable, Sendable {
        public var type: String
        public var instructions: JSONContent?
        public var criteria: JSONContent?

        public init(type: String, instructions: JSONContent? = nil, criteria: JSONContent? = nil) {
            self.type = type
            self.instructions = instructions
            self.criteria = criteria
        }

        public static let kinds: Set<String> = ["noul", "choice", "score"]

        /// Everything the wire allows and nothing else, checked before any provider is
        /// asked: a malformed question should fail here with the question's name, not as a
        /// 422 from TypeSafe or a confusing prompt to the local model.
        public func validate(name: String) throws {
            guard Self.kinds.contains(type) else {
                throw SystemOneValidationError(name: name, reason: "type must be noul, choice or score, not \"\(type)\".")
            }
            // Required on all three kinds. A question with nothing in `instructions` is a
            // rubric with no question attached: Jev answers what was written, so there has
            // to be something written, and the local lane would otherwise fall back to a
            // generic sentence that means whatever the reader hopes it means.
            guard let instructions, !instructions.isNull else {
                throw SystemOneValidationError(
                    name: name, reason: "instructions are required: say what is being judged."
                )
            }
            if let text = instructions.stringValue,
               text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw SystemOneValidationError(
                    name: name, reason: "instructions are empty: say what is being judged."
                )
            }
            switch type {
            case "choice":
                guard let labels = criteria?.objectValue, !labels.isEmpty else {
                    throw SystemOneValidationError(name: name, reason: "a choice needs criteria: an object of label → description.")
                }
            case "score":
                guard let levels = criteria?.arrayValue, !levels.isEmpty else {
                    throw SystemOneValidationError(name: name, reason: "a score needs criteria: a non-empty array of level descriptions, lowest first.")
                }
            default:
                if let criteria, !criteria.isNull, criteria.objectValue == nil {
                    throw SystemOneValidationError(name: name, reason: "noul criteria, when given, is an object with optional \"true\" and \"false\" descriptions.")
                }
            }
        }
    }

    public struct SystemOneValidationError: Error, LocalizedError, Equatable {
        public var name: String
        public var reason: String
        public init(name: String, reason: String) { self.name = name; self.reason = reason }
        public var errorDescription: String? { "Question \"\(name)\": \(reason)" }
    }

    /// An answer, tagged by the kind of question it answers. Encodes exactly as TypeSafe
    /// does, so a response from either lane reads the same to a client.
    public enum SystemOneAnswer: Codable, Equatable, Sendable {
        /// Probability that the statement holds, 0 to 1.
        case noul(Double)
        /// The most likely label, how sure, and the whole distribution.
        case choice(choice: String, confidence: Double, probabilities: [String: Double])
        /// Expected score across the levels, how sure, the rubric keyed by level, and the
        /// distribution over levels.
        case score(score: Double, confidence: Double, legend: [String: JSONContent], probabilities: [String: Double])

        private enum CodingKeys: String, CodingKey {
            case type, noul, choice, confidence, probabilities, score, legend
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(String.self, forKey: .type) {
            case "noul":
                self = .noul(try container.decode(Double.self, forKey: .noul))
            case "choice":
                self = .choice(
                    choice: try container.decode(String.self, forKey: .choice),
                    confidence: try container.decode(Double.self, forKey: .confidence),
                    probabilities: try container.decode([String: Double].self, forKey: .probabilities)
                )
            case "score":
                self = .score(
                    score: try container.decode(Double.self, forKey: .score),
                    confidence: try container.decode(Double.self, forKey: .confidence),
                    legend: try container.decode([String: JSONContent].self, forKey: .legend),
                    probabilities: try container.decode([String: Double].self, forKey: .probabilities)
                )
            case let other:
                throw DecodingError.dataCorruptedError(
                    forKey: .type, in: container, debugDescription: "Unknown answer type \(other)."
                )
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .noul(let value):
                try container.encode("noul", forKey: .type)
                try container.encode(value, forKey: .noul)
            case .choice(let choice, let confidence, let probabilities):
                try container.encode("choice", forKey: .type)
                try container.encode(choice, forKey: .choice)
                try container.encode(confidence, forKey: .confidence)
                try container.encode(probabilities, forKey: .probabilities)
            case .score(let score, let confidence, let legend, let probabilities):
                try container.encode("score", forKey: .type)
                try container.encode(score, forKey: .score)
                try container.encode(confidence, forKey: .confidence)
                try container.encode(legend, forKey: .legend)
                try container.encode(probabilities, forKey: .probabilities)
            }
        }

        public var type: String {
            switch self {
            case .noul: "noul"
            case .choice: "choice"
            case .score: "score"
            }
        }
    }

    public struct SystemOneUsage: Codable, Equatable, Sendable {
        public var inputTokens: Int
        public var outputTokens: Int

        public init(inputTokens: Int, outputTokens: Int) {
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
        }

        private enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
        }
    }

    /// `POST /decide` (also served at `/v1/systemone`): a state and typed questions in, typed
    /// probabilistic answers out. The body is TypeSafe's, plus `provider` to pick who answers.
    public struct DecideRequest: Codable, Sendable {
        public var state: JSONContent
        public var questions: [String: SystemOneQuestion]
        /// Which TypeSafe model answers. Set by this app on the way out, not read on the
        /// way in: the local lane has no aliases, and the Jev lane uses the version pinned
        /// in Settings → TypeSafe (Jev) so a tool call cannot move this Mac onto an alias
        /// the thresholds were never tuned against. Absent means `jev-latest` on the wire.
        public var model: String?
        /// `auto` (the model loaded here, else TypeSafe when a key is set), `local`, or
        /// `typesafe`.
        public var provider: String?

        public init(
            state: JSONContent, questions: [String: SystemOneQuestion],
            model: String? = nil, provider: String? = nil
        ) {
            self.state = state
            self.questions = questions
            self.model = model
            self.provider = provider
        }

        public func validate() throws {
            guard !questions.isEmpty else {
                throw SystemOneValidationError(name: "-", reason: "at least one question is required.")
            }
            for (name, question) in questions { try question.validate(name: name) }
        }
    }

    /// TypeSafe's response shape — `model`, `usage`, `answers` — with two additions a caller
    /// here cares about: which lane answered, and how long it took.
    public struct DecideResponse: Codable, Equatable, Sendable {
        public var model: String
        public var usage: SystemOneUsage
        public var answers: [String: SystemOneAnswer]
        public var provider: String?
        public var latencyMS: Double?

        public init(
            model: String, usage: SystemOneUsage, answers: [String: SystemOneAnswer],
            provider: String? = nil, latencyMS: Double? = nil
        ) {
            self.model = model
            self.usage = usage
            self.answers = answers
            self.provider = provider
            self.latencyMS = latencyMS
        }

        private enum CodingKeys: String, CodingKey {
            case model, usage, answers, provider
            case latencyMS = "latency_ms"
        }

        // MARK: Reading answers

        /// The probability that a noul question's statement holds, 0 to 1.
        ///
        /// These three exist so a feature is not written against
        /// `if case .noul(let p) = response.answers["x"]`, which silently does nothing when
        /// the id is misspelled or the question kind changed. A mismatch throws, by name.
        public func noul(_ id: String) throws -> Double {
            guard let answer = answers[id] else { throw SystemOneAnswerError.missing(id, "noul") }
            guard case .noul(let value) = answer else {
                throw SystemOneAnswerError.wrongKind(id, expected: "noul", found: answer.type)
            }
            return value
        }

        public func choice(
            _ id: String
        ) throws -> (choice: String, confidence: Double, probabilities: [String: Double]) {
            guard let answer = answers[id] else { throw SystemOneAnswerError.missing(id, "choice") }
            guard case .choice(let choice, let confidence, let probabilities) = answer else {
                throw SystemOneAnswerError.wrongKind(id, expected: "choice", found: answer.type)
            }
            return (choice, confidence, probabilities)
        }

        public func score(
            _ id: String
        ) throws -> (
            score: Double, confidence: Double,
            probabilities: [String: Double], legend: [String: JSONContent]
        ) {
            guard let answer = answers[id] else { throw SystemOneAnswerError.missing(id, "score") }
            guard case .score(let score, let confidence, let legend, let probabilities) = answer
            else {
                throw SystemOneAnswerError.wrongKind(id, expected: "score", found: answer.type)
            }
            return (score, confidence, probabilities, legend)
        }
    }

    /// What the typed accessors throw: the answer was not there, or was not that kind.
    public struct SystemOneAnswerError: Error, LocalizedError, Equatable {
        public var name: String
        public var expected: String
        /// The kind that was actually returned, or nil when there was no answer at all.
        public var found: String?

        public static func missing(_ name: String, _ expected: String) -> Self {
            Self(name: name, expected: expected, found: nil)
        }

        public static func wrongKind(_ name: String, expected: String, found: String) -> Self {
            Self(name: name, expected: expected, found: found)
        }

        public var errorDescription: String? {
            guard let found else {
                return "No answer came back for question \"\(name)\"; a \(expected) was expected."
            }
            return "Question \"\(name)\" answered with a \(found), not a \(expected)."
        }
    }
}
