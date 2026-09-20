import CryptoKit
import Foundation
import SiliconCatalog
import SiliconControl
import SiliconCore
import SiliconRuntime

// MARK: - Candidates

/// One model `silicon/auto` could send a request to, described by traits code derives rather
/// than by anything a model was asked to infer.
///
/// Two names on purpose. `id` is the gateway model id — `local/qwen3-coder-30b@Q4_K_M`, or
/// `local/external:/Users/…/model.gguf` for a file someone imported — and it never leaves the
/// Mac. `label` is what Jev sees: a slug of the model's own name, unique within one request.
/// The app promises that only what a question needs is sent to TypeSafe, and a filesystem
/// path is not something a routing question needs.
public struct RoutingCandidate: Sendable, Equatable, Identifiable {

    /// Which machine answers, which is also what it costs and how long it waits.
    public enum Placement: Sendable, Equatable {
        case thisMac
        case node(String)
        case cloud(String)

        public var isLocal: Bool {
            if case .thisMac = self { return true }
            return false
        }

        public var isCloud: Bool {
            if case .cloud = self { return true }
            return false
        }

        /// What the state says. A node's *name* is the owner's name for a machine in their
        /// house — it is not something a routing question needs, and what matters to the
        /// judgment is that the work leaves this Mac for a peer rather than for a provider.
        public var describedAs: String {
            switch self {
            case .thisMac: "this Mac"
            case .node: "a machine on your own network"
            case .cloud(let provider): "\(provider), over the internet"
            }
        }

        /// What the log line says, which stays on this Mac and may as well be specific.
        public var loggedAs: String {
            switch self {
            case .thisMac: "this Mac"
            case .node(let name): "the node \(name)"
            case .cloud(let provider): provider
            }
        }

        /// How far the work travels: none, the local network, the internet.
        var rank: Int {
            switch self {
            case .thisMac: 0
            case .node: 1
            case .cloud: 2
            }
        }
    }

    public var id: String
    public var label: String
    public var name: String
    public var placement: Placement
    /// Total parameters in billions, and the active count for a mixture-of-experts model —
    /// the number that actually decides how fast it answers.
    public var parameterBillions: Double?
    public var activeParameterBillions: Double?
    public var quantization: String?
    public var contextWindow: Int?
    public var vision: Bool
    public var codeTuned: Bool
    public var reasoning: Bool
    public var uncensored: Bool
    /// Measured on this machine's own recent gateway traffic, not a claim from a spec sheet.
    public var tokensPerSecond: Double?
    /// Nil means nobody published a price. Zero means it genuinely costs nothing per token:
    /// anything on hardware you own, and a provider's free tier.
    public var usdPerMillionTokens: Double?
    /// Answers without a load: the model serving here right now, a node's running model, or
    /// a remote one, which has nothing to load by definition.
    public var readyNow: Bool

    public init(
        id: String, label: String, name: String, placement: Placement,
        parameterBillions: Double? = nil, activeParameterBillions: Double? = nil,
        quantization: String? = nil, contextWindow: Int? = nil,
        vision: Bool = false, codeTuned: Bool = false, reasoning: Bool = false,
        uncensored: Bool = false, tokensPerSecond: Double? = nil,
        usdPerMillionTokens: Double? = nil, readyNow: Bool = false
    ) {
        self.id = id
        self.label = label
        self.name = name
        self.placement = placement
        self.parameterBillions = parameterBillions
        self.activeParameterBillions = activeParameterBillions
        self.quantization = quantization
        self.contextWindow = contextWindow
        self.vision = vision
        self.codeTuned = codeTuned
        self.reasoning = reasoning
        self.uncensored = uncensored
        self.tokensPerSecond = tokensPerSecond
        self.usdPerMillionTokens = usdPerMillionTokens
        self.readyNow = readyNow
    }

    /// Free at the point of use: your own hardware, or a provider's free tier.
    public var isFree: Bool { (usdPerMillionTokens ?? .infinity) == 0 }

    /// What the speed of an answer turns on: the active parameters for an MoE model, the
    /// whole count for a dense one.
    public var workingBillions: Double? { activeParameterBillions ?? parameterBillions }
}

// MARK: Deriving traits

extension RoutingCandidate {

    /// A model installed here. Everything but the name comes from facts on disk — the GGUF
    /// header's shape, the capability flags recorded at install, the quantization — with the
    /// catalog entry filling in what the file cannot say.
    public static func local(
        _ model: GatewayAPI.Model, installed: InstalledModel, catalog: ModelEntry?,
        label: String
    ) -> RoutingCandidate {
        let capabilities = installed.capabilities.union(catalog?.capabilities ?? [])
        let guessed = NameTraits(installed.name)
        let total = (installed.shape ?? catalog?.shape).map { Double($0.totalParameters) / 1e9 }
        let active = (installed.shape ?? catalog?.shape)?.moe.map {
            Double($0.activeParameters) / 1e9
        }
        return RoutingCandidate(
            id: model.id,
            label: label,
            name: installed.name,
            placement: .thisMac,
            parameterBillions: total ?? guessed.totalBillions,
            activeParameterBillions: active ?? guessed.activeBillions,
            quantization: installed.quantization.rawValue,
            contextWindow: model.contextWindow,
            // A vision model without its projector file cannot look at anything, which is
            // why the installed model answers this and not the catalog.
            vision: installed.supportsVision,
            codeTuned: capabilities.contains(.coding) || guessed.codeTuned,
            reasoning: capabilities.contains(.reasoning) || guessed.reasoning,
            uncensored: guessed.uncensored,
            tokensPerSecond: model.tokensPerSecond,
            // Electricity is not a per-token price, and a routing decision that pretended
            // otherwise would send everything to the cloud the moment it looked cheap.
            usdPerMillionTokens: 0,
            readyNow: model.serving
        )
    }

    /// A model a swarm node offers. A node reports a name and, while it is serving, a context
    /// length — so every other trait is read out of the name, which is all there is.
    public static func node(
        _ model: GatewayAPI.Model, peer: String, label: String
    ) -> RoutingCandidate {
        let name = Self.modelName(fromNodeID: model.id) ?? model.displayName
        let guessed = NameTraits(name)
        return RoutingCandidate(
            id: model.id,
            label: label,
            name: name,
            placement: .node(peer),
            parameterBillions: guessed.totalBillions,
            activeParameterBillions: guessed.activeBillions,
            quantization: model.quantization,
            contextWindow: model.contextWindow,
            vision: guessed.vision,
            codeTuned: guessed.codeTuned,
            reasoning: guessed.reasoning,
            uncensored: guessed.uncensored,
            tokensPerSecond: model.tokensPerSecond,
            usdPerMillionTokens: 0,
            readyNow: model.serving
        )
    }

    /// A model on a provider. The listing gives a name and usually a context window; a price
    /// only when the provider publishes one, which today means OpenRouter and the free tiers.
    public static func cloud(
        _ model: GatewayAPI.Model, cloud: CloudModel?, provider: String, label: String
    ) -> RoutingCandidate {
        let name = cloud?.displayName ?? model.displayName
        let guessed = NameTraits([name, cloud?.id ?? ""].joined(separator: " "))
        return RoutingCandidate(
            id: model.id,
            label: label,
            name: name,
            placement: .cloud(provider),
            parameterBillions: guessed.totalBillions,
            activeParameterBillions: guessed.activeBillions,
            quantization: nil,
            contextWindow: cloud?.contextWindow ?? model.contextWindow,
            vision: guessed.vision,
            codeTuned: guessed.codeTuned,
            reasoning: guessed.reasoning,
            uncensored: guessed.uncensored,
            tokensPerSecond: model.tokensPerSecond,
            // A free tier is a real zero. Everything else is nil rather than a guess: an
            // invented price is worse than an honest "nobody said".
            usdPerMillionTokens: cloud.map { $0.isFree ? 0 : $0.pricePerMillionInputUSD }
                ?? nil,
            readyNow: true
        )
    }

    /// The model half of a `node/<peer>/<model>` id.
    static func modelName(fromNodeID id: String) -> String? {
        guard case .node(_, let model)? = GatewayAPI.parseModelID(id) else { return nil }
        return model
    }

    /// What a model's name gives away when nothing else will say.
    ///
    /// Only ever a fallback. An installed model has a GGUF header and capability flags; a
    /// node model and a remote one have a string, and "Qwen3-Coder-30B-A3B" plainly says
    /// three things about itself. Read as whole words, so "codex" does not read as code and
    /// "reasonable" does not read as reasoning.
    public struct NameTraits: Sendable, Equatable {
        public var vision = false
        public var codeTuned = false
        public var reasoning = false
        public var uncensored = false
        public var totalBillions: Double?
        public var activeBillions: Double?

        public init(_ name: String) {
            let lower = name.lowercased()
            let words = Set(
                lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            )
            func says(_ any: [String]) -> Bool {
                any.contains { words.contains($0) || lower.contains($0) }
            }
            vision = says(["vl", "vision", "llava", "pixtral", "moondream", "internvl"])
            codeTuned = says(["coder", "codestral", "devstral", "starcoder", "codellama"])
                || words.contains("code")
            reasoning = says(["qwq", "thinking", "reasoner", "magistral"])
                || words.contains("think") || words.contains("r1") || words.contains("reasoning")
            uncensored = says(["uncensored", "abliterated", "unfiltered", "dolphin"])

            // "30b" and "a3b" in one name: the larger is the model, the smaller is what it
            // activates per token. Counting is code's job, never the model's.
            let sizes = Self.parameterSizes(in: lower)
            totalBillions = sizes.max()
            if sizes.count > 1 { activeBillions = sizes.min() }
        }

        /// Every "<number>b" in a name, in billions. "minimax-m2.7" has none: the b is what
        /// makes it a parameter count.
        static func parameterSizes(in lower: String) -> [Double] {
            guard let regex = try? NSRegularExpression(
                pattern: #"(?<![\d.])(\d+(?:\.\d+)?)\s?b(?![a-z0-9])"#
            ) else { return [] }
            let range = NSRange(lower.startIndex..., in: lower)
            return regex.matches(in: lower, range: range).compactMap { match in
                guard let digits = Range(match.range(at: 1), in: lower) else { return nil }
                return Double(lower[digits])
            }
        }
    }

    /// Short, unique, and derived from the model's own name — what Jev picks between.
    ///
    /// Uniqueness matters more than beauty: two quantizations of one model differ only by a
    /// suffix, and a choice cannot have two options with the same name.
    public static func labels(for names: [String]) -> [String] {
        var used: Set<String> = []
        return names.map { name in
            var slug = String(
                name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
            )
            while slug.contains("--") { slug = slug.replacingOccurrences(of: "--", with: "-") }
            slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            if slug.count > 48 { slug = String(slug.prefix(48)) }
            if slug.isEmpty { slug = "model" }
            var candidate = slug
            var suffix = 2
            while used.contains(candidate) {
                candidate = "\(slug)-\(suffix)"
                suffix += 1
            }
            used.insert(candidate)
            return candidate
        }
    }
}

// MARK: - The request being routed

/// What one inbound gateway request looks like to the routing questions: the message being
/// answered and a few facts about the conversation around it.
///
/// Read out of the body the client sent, in either dialect — chat completions (the harness)
/// or responses (Codex) — because the gateway routes both and the question is the same.
public struct RoutingRequest: Sendable, Equatable {

    /// The latest user message, trimmed. Head and tail both kept: a long paste usually
    /// carries the material first and the actual ask last, and a request truncated to its
    /// first lines routes on the document instead of on the question about it.
    public var message: String
    public var turns: Int
    public var imagesAttached: Bool
    public var systemMentionsCodeOrTools: Bool
    /// Counted here, because `jev-1.13` does not count.
    public var messageWords: Int

    public static let maximumMessageCharacters = 3_600
    private static let headCharacters = 2_400

    public init(
        message: String, turns: Int, imagesAttached: Bool,
        systemMentionsCodeOrTools: Bool, messageWords: Int
    ) {
        self.message = message
        self.turns = turns
        self.imagesAttached = imagesAttached
        self.systemMentionsCodeOrTools = systemMentionsCodeOrTools
        self.messageWords = messageWords
    }

    public static func read(body: Data) -> RoutingRequest {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        var texts: [(role: String, text: String, hasImage: Bool)] = []

        if let instructions = json["instructions"] as? String, !instructions.isEmpty {
            texts.append((role: "system", text: instructions, hasImage: false))
        }
        for message in json["messages"] as? [[String: Any]] ?? [] {
            let content = flatten(message["content"])
            texts.append((
                role: message["role"] as? String ?? "user",
                text: content.text, hasImage: content.hasImage
            ))
        }
        for item in json["input"] as? [[String: Any]] ?? [] {
            guard (item["type"] as? String) == "message" || item["type"] == nil else { continue }
            let content = flatten(item["content"])
            texts.append((
                role: item["role"] as? String ?? "user",
                text: content.text, hasImage: content.hasImage
            ))
        }

        let conversation = texts.filter { $0.role == "user" || $0.role == "assistant" }
        // No user message means no message. The tempting fallback — the last thing in the
        // list — is the system prompt on every turn that is only a tool result, and a
        // harness's preamble is both private and identical every time: a paid question
        // about the wrong text with a foregone answer. The router routes on nothing
        // instead, which it knows how to do.
        let latest = texts.last { $0.role == "user" }?.text ?? ""
        let system = texts.filter { $0.role == "system" || $0.role == "developer" }
            .map(\.text).joined(separator: "\n")
        let toolsOffered = !((json["tools"] as? [Any])?.isEmpty ?? true)

        return RoutingRequest(
            message: trimmed(latest),
            turns: conversation.count,
            imagesAttached: texts.contains(where: \.hasImage),
            systemMentionsCodeOrTools: toolsOffered || mentionsCodeOrTools(system),
            messageWords: latest.split(whereSeparator: \.isWhitespace).count
        )
    }

    /// Chat content is a string or an array of typed parts; an image part is how both
    /// dialects attach a picture.
    static func flatten(_ content: Any?) -> (text: String, hasImage: Bool) {
        if let text = content as? String { return (text, false) }
        guard let parts = content as? [[String: Any]] else { return ("", false) }
        var text = ""
        var hasImage = false
        for part in parts {
            let type = part["type"] as? String ?? ""
            if type.contains("image") { hasImage = true }
            if let piece = part["text"] as? String { text += piece }
        }
        return (text, hasImage)
    }

    /// A literal keyword check, kept in code: the question Jev is asked is about the user's
    /// message, and this is a fact about the harness's own preamble that code can just read.
    static func mentionsCodeOrTools(_ system: String) -> Bool {
        guard !system.isEmpty else { return false }
        let lower = system.lowercased()
        return [
            "tool", "function call", "code", "repository", "repo", "file",
            "terminal", "shell", "patch", "diff", "compile",
        ].contains { lower.contains($0) }
    }

    static func trimmed(_ text: String) -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > maximumMessageCharacters else { return clean }
        let head = clean.prefix(headCharacters)
        let tail = clean.suffix(maximumMessageCharacters - headCharacters)
        return "\(head)\n…\n\(tail)"
    }

    /// The request half of the cache key: this conversation's shape and this message's
    /// content. Two identical asks inside the cache window are one decision and must cost
    /// one call — a harness retrying a dropped stream should not pay TypeSafe twice for the
    /// same routing.
    ///
    /// Hashed rather than kept whole, so nothing that logs a cache key logs a message.
    public var cacheKey: String {
        let digest = SHA256.hash(data: Data(message.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return "\(turns)|\(imagesAttached)|\(systemMentionsCodeOrTools)|\(digest)"
    }

    /// The conversation half of the state: three facts, each of which code observed rather
    /// than inferred.
    var digestJSON: JSONContent {
        .object([
            "turns_so_far": .number(Double(turns)),
            "images_attached": .bool(imagesAttached),
            "system_prompt_mentions_code_or_tools": .bool(systemMentionsCodeOrTools),
            "message_word_count": .number(Double(messageWords)),
        ])
    }
}

// MARK: - The questions

/// What Jev is asked before a request is routed, and the numbers the answers are read
/// against — together, in one file, because the wording *is* the behaviour and a threshold
/// decides what the app does with it.
///
/// Seven judgments and one choice, asked in a single request: Jev reads the state once and
/// answers every question against it in parallel, so asking eight costs about what asking
/// one costs. Each is written literally — `jev-1.13` answers the question on the page, not
/// the one behind it — and each is about the *message*, never about arithmetic: how long the
/// message is, how many turns there have been and whether an image is attached are all facts
/// code already has, so code passes them in and keeps the judgment for what is genuinely a
/// judgment.
public enum RoutingQuestions: JevQuestionSet {

    public static let feature = JevFeature.routing

    /// The band the `best_model` choice is read against.
    ///
    /// Low on purpose, and lower than a destructive feature would ever use. Several models
    /// are usually acceptable answers to "who should take this", and a spread distribution
    /// there means "any of these three", not "I don't know" — while the cost of a wrong pick
    /// is one answer from a slightly worse model, which the person can retry by naming one.
    /// Below `confirm` the distribution is flat enough that the owner's own default model is
    /// the better guess, so that is what it falls back to.
    public static let thresholds = JevThresholds(act: 0.60, confirm: 0.35)

    /// A yes/no gate on one noul.
    ///
    /// Two numbers rather than one because a noul has no confidence of its own: a
    /// probability near either end is an answer, and one in the middle is Jev saying it does
    /// not know. Every rule below treats "does not know" as "no" — a veto or a preference
    /// that fires on a shrug is worse than one that never fires — but the middle is written
    /// down rather than implied, so a reader can see where it is.
    public struct Gate: Sendable, Equatable {
        public var yes: Double
        public var no: Double

        public init(yes: Double, no: Double) {
            self.yes = yes
            self.no = no
        }

        public func says(_ probability: Double) -> Bool {
            JevThresholds.noulBand(probability, yes: yes, no: no) == .act && probability >= yes
        }

        public func isUnsure(_ probability: Double) -> Bool {
            JevThresholds.noulBand(probability, yes: yes, no: no) != .act
        }
    }

    /// Every number the policy reads, in one place.
    public enum Cutoff {
        /// Asks for a model that can see. High, because vetoing every text model on a
        /// maybe would route half the traffic through a vision model for nothing.
        public static let needsVision = Gate(yes: 0.6, no: 0.2)
        /// Asks for a window big enough to hold what it is about.
        public static let needsLongContext = Gate(yes: 0.6, no: 0.2)
        public static let isCodeTask = Gate(yes: 0.6, no: 0.25)
        public static let isCreativeWriting = Gate(yes: 0.6, no: 0.25)
        /// Higher than the rest: this one sends work to whatever is already warm, so it
        /// should only fire when the message really is a one-liner.
        public static let isQuickLookup = Gate(yes: 0.7, no: 0.3)
        public static let needsFrontierReasoning = Gate(yes: 0.7, no: 0.3)

        /// `complexity` at or below this is trivial; at or above `hardComplexity` it is hard
        /// multi-step work. The gap between them is the ordinary middle, where the choice
        /// answer stands on its own.
        public static let trivialComplexity = 0.5
        public static let hardComplexity = 1.5
        /// A score does carry a confidence, and this one is worth checking: sending work to
        /// another machine can cost money, so it needs a complexity read Jev is actually
        /// sure of. Preferring something already warm cannot cost anything, so it does not.
        public static let hardComplexityConfidence = 0.4

        /// What "long context" has to mean in tokens for the veto to be checkable.
        public static let longContextTokens = 32_768
        /// A message this long needs the room whatever Jev thinks of it — counted in code,
        /// because `jev-1.13` does not count.
        public static let longMessageWords = 2_000
    }

    /// The candidate-independent half: the judgments about the request itself, which are the
    /// same questions whatever models happen to be installed. `questions(for:)` adds the
    /// choice over the models that exist right now.
    public static let questions: [String: ControlAPI.SystemOneQuestion] = [
        "needs_vision": .init(
            type: "noul",
            instructions: .string(
                "The user's latest message, `message`, asks about a picture, screenshot, "
                + "photo, diagram, chart, scanned page or video frame — something the "
                + "assistant has to look at rather than read."
            ),
            criteria: .object([
                "true": .string(
                    "The message refers to an image the user has attached, is attaching, or "
                    + "is pointing at: \"what does this screenshot show\", \"read the chart\"."
                ),
                "false": .string(
                    "The message can be answered from its own text. Mentioning the word "
                    + "image, or asking for an image to be generated, is not the same as "
                    + "needing to look at one."
                ),
            ])
        ),
        "needs_long_context": .init(
            type: "noul",
            instructions: .string(
                "Answering `message` means working through a long document, transcript, log, "
                + "book chapter or codebase — material the assistant has to hold all of at "
                + "once, rather than answering from the message alone."
            ),
            criteria: .object([
                "true": .string(
                    "The message contains or points at long material and asks for something "
                    + "over the whole of it: summarise this transcript, find the bug in this "
                    + "file, compare these two contracts."
                ),
                "false": .string(
                    "The message is self-contained, or it refers to something long but asks "
                    + "only about one small part of it."
                ),
            ])
        ),
        "is_code_task": .init(
            type: "noul",
            instructions: .string(
                "`message` asks for code to be written, explained, reviewed, debugged, "
                + "translated between languages or changed, or asks about a programming "
                + "language, a library, an API, a shell command or an error message."
            ),
            criteria: .object([
                "true": .string(
                    "Writing a function, fixing a stack trace, explaining what a snippet "
                    + "does, choosing between two libraries, writing a shell one-liner."
                ),
                "false": .string(
                    "Everything else, including questions about software that do not "
                    + "involve reading or writing any: \"which laptop should I buy\"."
                ),
            ])
        ),
        "is_quick_lookup": .init(
            type: "noul",
            instructions: .string(
                "`message` asks for one short fact, a definition, a translation, a unit "
                + "conversion, a name or a one-line answer — something a person would expect "
                + "back in a sentence."
            ),
            criteria: .object([
                "true": .string(
                    "\"What year did X happen\", \"how do you say this in German\", "
                    + "\"what does this flag do\", \"rewrite this line more politely\"."
                ),
                "false": .string(
                    "Anything that wants an explanation, a piece of writing, a plan, a "
                    + "comparison or code."
                ),
            ])
        ),
        "needs_frontier_reasoning": .init(
            type: "noul",
            instructions: .string(
                "Answering `message` well needs careful step-by-step reasoning: a proof, a "
                + "plan with several dependent steps, a subtle bug, or weighing several "
                + "constraints against each other at once."
            ),
            criteria: .object([
                "true": .string(
                    "Design this schema given these five requirements; why does this "
                    + "concurrency bug only appear under load; work out the best order for "
                    + "these tasks given the deadlines."
                ),
                "false": .string(
                    "The answer is mostly recall, restatement, formatting, or a single "
                    + "well-known step — even when the subject is technical."
                ),
            ])
        ),
        "is_creative_writing": .init(
            type: "noul",
            instructions: .string(
                "`message` asks for imaginative writing: fiction, a story, poetry, lyrics, a "
                + "script, a roleplay turn, or prose written in a deliberate voice."
            ),
            criteria: .object([
                "true": .string(
                    "Write a short story about…; continue this scene; write a limerick; "
                    + "stay in character as…."
                ),
                "false": .string(
                    "Factual, technical or professional writing — an email, a summary, "
                    + "documentation, a report — however well written it needs to be."
                ),
            ])
        ),
        "complexity": .init(
            type: "score",
            instructions: .string(
                "How much work answering `message` is, for whichever model takes it."
            ),
            criteria: .array([
                .string(
                    "Trivial. One fact, one definition, one translation, one small edit. A "
                    + "correct answer is a sentence or two and there is nothing to work out."
                ),
                .string(
                    "Moderate. A few steps or some judgment: an explanation, a short "
                    + "function, a summary of material that is in the message, a comparison "
                    + "of two things the answer already knows about."
                ),
                .string(
                    "Hard, multi-step. Designing or debugging something substantial, "
                    + "holding several constraints at once, or producing a long piece of "
                    + "writing or code where the parts have to agree with each other."
                ),
            ])
        ),
    ]

    /// The full set for one request: the judgments above plus a choice over the models this
    /// Mac can actually reach right now.
    ///
    /// The choice is built per request rather than declared once because its options *are*
    /// the installed models, the reachable nodes and the ticked remote models — a list that
    /// changes when someone downloads a model or a node goes offline.
    public static func questions(
        for candidates: [RoutingCandidate]
    ) -> [String: ControlAPI.SystemOneQuestion] {
        var all = questions
        if let choice = bestModelQuestion(for: candidates) { all["best_model"] = choice }
        return all
    }

    /// At most this many options. The wire allows 255; accuracy and the state limit do not.
    /// A long tail of near-identical quantizations is exactly the irrelevant detail
    /// `jev-1.13` loses accuracy to, and sixteen options with their traits is already several
    /// kilobytes of state before the message is added.
    public static let maximumCandidates = 16

    /// Which candidates survive the cap.
    ///
    /// Bucketed by where they run — this Mac first, then the swarm, then providers — and
    /// only then by whether they are warm and by label. Without the buckets, ticking thirty
    /// remote models would push this Mac's own library out of its own routing question,
    /// which is both wrong for an app about the hardware in front of you and the exact
    /// shape of an accident: the list that decides is not the list you were looking at.
    ///
    /// The consequence is deliberate and worth saying: a library of more than sixteen
    /// installed models crowds the swarm out of the question. That is the same order
    /// `gatewayModelSnapshot` already lists them in.
    ///
    /// `keeping` is the owner's fallback. It is pinned in whatever the cap would have done,
    /// because a question that cannot answer "the one you chose" is worse than a short one.
    public static func shortlist(
        _ candidates: [RoutingCandidate], keeping pinned: String? = nil
    ) -> [RoutingCandidate] {
        let ordered = candidates.sorted { first, second in
            if first.placement.rank != second.placement.rank {
                return first.placement.rank < second.placement.rank
            }
            if first.readyNow != second.readyNow { return first.readyNow }
            return first.label < second.label
        }
        guard ordered.count > maximumCandidates else { return ordered }
        guard let pinned, let keep = ordered.first(where: { $0.id == pinned }) else {
            return Array(ordered.prefix(maximumCandidates))
        }
        var kept = ordered.prefix(maximumCandidates)
        guard !kept.contains(where: { $0.id == pinned }) else { return Array(kept) }
        // The pinned model displaces the last of the cap, and the order still holds.
        kept = kept.dropLast()
        return (kept + [keep]).sorted { first, second in
            if first.placement.rank != second.placement.rank {
                return first.placement.rank < second.placement.rank
            }
            if first.readyNow != second.readyNow { return first.readyNow }
            return first.label < second.label
        }
    }

    static func bestModelQuestion(
        for candidates: [RoutingCandidate]
    ) -> ControlAPI.SystemOneQuestion? {
        guard !candidates.isEmpty else { return nil }
        var criteria: [String: JSONContent] = [:]
        for candidate in candidates {
            criteria[candidate.label] = .object([
                "what": .string(describe(candidate)),
                "good_for": .string(goodFor(candidate).joined(separator: "; ")),
                "not_for": .string(notFor(candidate).joined(separator: "; ")),
            ])
        }
        return .init(
            type: "choice",
            instructions: .object([
                "question": .string(
                    "Which one of these models should answer the user's latest message?"
                ),
                "the_message_is": .string("`message`"),
                "also_read": .string(
                    "`conversation`, and the traits of each option in `candidates`"
                ),
                "pick": .string(
                    "the option whose strengths match what the message actually asks for, "
                    + "and which can answer it at the length and quality the message deserves"
                ),
            ]),
            criteria: .object(criteria)
        )
    }

    /// One sentence of fact per option, assembled from the traits — never a judgment, so
    /// that what Jev is weighing is the same thing the policy vetoes on.
    static func describe(_ candidate: RoutingCandidate) -> String {
        var parts = [candidate.name]
        if let billions = candidate.parameterBillions {
            var size = "\(number(billions))B parameters"
            if let active = candidate.activeParameterBillions, active < billions {
                size += " of which \(number(active))B are active per token"
            }
            parts.append(size)
        }
        if let quantization = candidate.quantization { parts.append("quantized \(quantization)") }
        parts.append("runs on \(candidate.placement.describedAs)")
        if let context = candidate.contextWindow {
            parts.append("a context window of about \(context / 1024)K tokens")
        }
        if let rate = candidate.tokensPerSecond {
            parts.append("measured here at about \(number(rate)) tokens a second")
        }
        parts.append(candidate.readyNow
            ? "ready now, with nothing to load"
            : "not loaded, so the first answer waits a minute or two while it starts")
        switch candidate.usdPerMillionTokens {
        case .some(0): parts.append("costs nothing per token")
        case .some(let price): parts.append("costs about $\(number(price)) per million tokens")
        case nil: parts.append("billed by the provider at a price it does not publish here")
        }
        return parts.joined(separator: ", ") + "."
    }

    static func goodFor(_ candidate: RoutingCandidate) -> [String] {
        var reasons: [String] = []
        if candidate.vision { reasons.append("questions about an attached image or screenshot") }
        if candidate.codeTuned { reasons.append("writing, changing and explaining code") }
        if candidate.reasoning { reasons.append("problems that need several steps of working") }
        if candidate.uncensored {
            reasons.append("blunt or adult material other models decline to write")
        }
        switch candidate.workingBillions ?? 0 {
        case 25...: reasons.append("hard questions and long, careful answers")
        case 7..<25: reasons.append("everyday questions, summaries and short pieces of code")
        case 0.1..<7: reasons.append("short factual answers and simple rewrites")
        default: break
        }
        if candidate.readyNow, candidate.isFree {
            reasons.append("an answer that starts immediately and costs nothing")
        }
        return reasons.isEmpty ? ["general questions"] : reasons
    }

    static func notFor(_ candidate: RoutingCandidate) -> [String] {
        var reasons: [String] = []
        if !candidate.vision { reasons.append("anything that means looking at an image") }
        if let context = candidate.contextWindow, context < Cutoff.longContextTokens {
            reasons.append("documents longer than about \(context / 1024)K tokens")
        }
        if !candidate.readyNow {
            reasons.append("a one-line answer someone is waiting on, since it has to load first")
        }
        if !candidate.isFree, candidate.placement.isCloud {
            reasons.append("routine questions you would rather not be billed for")
        }
        if (candidate.workingBillions ?? 0) > 0, (candidate.workingBillions ?? 0) < 7 {
            reasons.append("long multi-step work")
        }
        if candidate.codeTuned, !candidate.reasoning {
            reasons.append("imaginative writing")
        }
        return reasons.isEmpty ? ["nothing in particular"] : reasons
    }

    static func number(_ value: Double) -> String {
        value == value.rounded()
            ? String(format: "%.0f", value)
            : String(format: "%.1f", value)
    }

    // MARK: Asking

    /// The state: the message, the conversation facts, and the candidates.
    ///
    /// Nothing else. Not the rest of the conversation, not the model library, not what is
    /// running — the app's promise is that a feature sends only what its question needs, and
    /// a bigger state would cost accuracy as well as trust.
    public static func state(
        request: RoutingRequest, candidates: [RoutingCandidate]
    ) -> JSONContent {
        .object([
            "message": .string(request.message),
            "conversation": request.digestJSON,
            "candidates": .array(candidates.map { candidate in
                var traits: [String: JSONContent] = [
                    "option": .string(candidate.label),
                    "runs_on": .string(candidate.placement.describedAs),
                    "vision": .bool(candidate.vision),
                    "code_tuned": .bool(candidate.codeTuned),
                    "reasoning": .bool(candidate.reasoning),
                    "uncensored": .bool(candidate.uncensored),
                    "ready_now": .bool(candidate.readyNow),
                ]
                if let billions = candidate.parameterBillions {
                    traits["parameters_billions"] = .number(billions)
                }
                if let active = candidate.activeParameterBillions {
                    traits["active_parameters_billions"] = .number(active)
                }
                if let quantization = candidate.quantization {
                    traits["quantization"] = .string(quantization)
                }
                if let context = candidate.contextWindow {
                    traits["context_window_tokens"] = .number(Double(context))
                }
                if let rate = candidate.tokensPerSecond {
                    traits["tokens_per_second"] = .number((rate * 10).rounded() / 10)
                }
                if let price = candidate.usdPerMillionTokens {
                    traits["usd_per_million_tokens"] = .number(price)
                }
                return .object(traits)
            }),
        ])
    }

    /// What a cached answer is an answer *to*: this message, in this conversation, against
    /// this set of models.
    ///
    /// The last part matters more than it looks. Labels are positional — two quantizations
    /// of one model are `x` and `x-2` — so the same label can mean a different physical
    /// model once something is installed, hidden or unplugged. Without the set in the key, a
    /// cached choice of `x-2` could be resolved against a list where `x-2` is someone else.
    public static func cacheKey(
        request: RoutingRequest, candidates: [RoutingCandidate]
    ) -> String {
        let shape = candidates
            .map { "\($0.id)\u{1F}\($0.label)\u{1F}\($0.readyNow)" }
            .joined(separator: "\u{1E}")
        let digest = SHA256.hash(data: Data(shape.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return "\(request.cacheKey)|\(digest)"
    }

    /// One request, through the one door — so the feature switch, the budget, the size
    /// limit, the cache and the ledger all apply without this file remembering them.
    ///
    /// Not `JevQuestionSet.ask(state:)`: that one asks `questions`, which is the fixed half.
    /// Routing without its choice over the models would be seven judgments and no decision.
    ///
    /// `using` is the seam a test points at a loopback server instead of TypeSafe.
    public static func ask(
        request: RoutingRequest, candidates: [RoutingCandidate],
        using service: JevService = .shared
    ) async throws -> ControlAPI.DecideResponse {
        try await DecisionRouter.router(for: service).decide(
            feature,
            state: state(request: request, candidates: candidates),
            questions: questions(for: candidates),
            cacheKey: cacheKey(request: request, candidates: candidates)
        )
    }
}

// MARK: - The answers, as the policy reads them

/// Jev's eight answers, read once through the typed accessors and handed to the policy as
/// plain numbers.
///
/// One place converts wire answers into policy inputs, and it is here. An answer that did not
/// come back, or came back as the wrong kind, takes its neutral value rather than throwing:
/// routing must never be the reason a chat request fails, and "no opinion" is a perfectly
/// good input to a policy whose first rule is that the owner's default model is fine.
public struct RoutingAnswers: Sendable, Equatable {
    public var needsVision: Double
    public var needsLongContext: Double
    public var isCodeTask: Double
    public var isQuickLookup: Double
    public var needsFrontierReasoning: Double
    public var isCreativeWriting: Double
    /// Nil when no score came back — which is not the same as a score of zero.
    public var complexity: Double?
    public var complexityConfidence: Double
    /// The option label Jev chose, which is a `RoutingCandidate.label`, never a model id.
    public var bestModel: String?
    public var bestModelConfidence: Double

    public init(
        needsVision: Double = 0, needsLongContext: Double = 0, isCodeTask: Double = 0,
        isQuickLookup: Double = 0, needsFrontierReasoning: Double = 0,
        isCreativeWriting: Double = 0, complexity: Double? = nil,
        complexityConfidence: Double = 0, bestModel: String? = nil,
        bestModelConfidence: Double = 0
    ) {
        self.needsVision = needsVision
        self.needsLongContext = needsLongContext
        self.isCodeTask = isCodeTask
        self.isQuickLookup = isQuickLookup
        self.needsFrontierReasoning = needsFrontierReasoning
        self.isCreativeWriting = isCreativeWriting
        self.complexity = complexity
        self.complexityConfidence = complexityConfidence
        self.bestModel = bestModel
        self.bestModelConfidence = bestModelConfidence
    }

    public static func read(from response: ControlAPI.DecideResponse) -> RoutingAnswers {
        var answers = RoutingAnswers()
        answers.needsVision = (try? response.noul("needs_vision")) ?? 0
        answers.needsLongContext = (try? response.noul("needs_long_context")) ?? 0
        answers.isCodeTask = (try? response.noul("is_code_task")) ?? 0
        answers.isQuickLookup = (try? response.noul("is_quick_lookup")) ?? 0
        answers.needsFrontierReasoning = (try? response.noul("needs_frontier_reasoning")) ?? 0
        answers.isCreativeWriting = (try? response.noul("is_creative_writing")) ?? 0
        if let complexity = try? response.score("complexity") {
            answers.complexity = complexity.score
            answers.complexityConfidence = complexity.confidence
        }
        if let best = try? response.choice("best_model") {
            answers.bestModel = best.choice
            answers.bestModelConfidence = best.confidence
        }
        return answers
    }

    /// What code saw for itself, folded in over what Jev judged.
    ///
    /// Two of the eight questions have a half that is not a judgment at all: whether an image
    /// is attached, and how long the message is. Code can see both exactly, `jev-1.13` cannot
    /// count, and a model's opinion must not be able to talk the app out of a fact — so the
    /// question asks only the semantic half and this raises the answer when the observed half
    /// settles it.
    public func observing(_ request: RoutingRequest) -> RoutingAnswers {
        var updated = self
        if request.imagesAttached { updated.needsVision = 1 }
        if request.messageWords >= RoutingQuestions.Cutoff.longMessageWords {
            updated.needsLongContext = 1
        }
        return updated
    }
}

// MARK: - The policy

/// Which model answers, decided by code from Jev's answers.
///
/// Every rule here is ordinary Swift, and that is deliberate: the model supplies judgments
/// about the request, and the policy — what is a hard requirement, what is merely preferred,
/// how sure is sure enough — is the app's, where it can be read, tested and changed without
/// asking anything.
public enum RoutingPolicy {

    public struct Decision: Sendable, Equatable {
        /// The gateway model id that will answer.
        public var modelID: String
        /// One line, for the log and the stream's comment.
        public var reason: String

        public init(modelID: String, reason: String) {
            self.modelID = modelID
            self.reason = reason
        }
    }

    /// The rules, in order:
    ///
    /// 1. **Vision veto.** A request that needs eyes may only go to a model that has them.
    /// 2. **Long-context veto.** A request that needs the room may only go to a model whose
    ///    window is known to be big enough.
    /// 3. **The choice, or the default.** Jev's pick is the starting point when it survived
    ///    the vetoes and its confidence is inside the band; otherwise the owner's default.
    /// 4. **Trivial and quick → something already warm and free.**
    /// 5. **Hard, or frontier reasoning → another machine**, which is where the big models
    ///    are; only when the complexity read is one Jev is sure of, because this one can
    ///    cost money.
    /// 6. **A code task → a code-tuned model**, unless it is creative writing, where a
    ///    coding fine-tune is the wrong instrument.
    ///
    /// At most one of 4, 5 and 6 fires. They can disagree — a message can read as both a
    /// quick lookup and as frontier reasoning — and when they do, the cheap recoverable
    /// mistake wins over the expensive one.
    ///
    /// A veto that would empty the list is dropped instead, and says so in the reason. There
    /// is no model here that can read an image; the request still has to go somewhere, and
    /// failing a chat completion because routing was fussy is not an option this has.
    public static func choose(
        answers: RoutingAnswers,
        candidates: [RoutingCandidate],
        defaultModel: String
    ) -> Decision {
        guard !candidates.isEmpty else {
            return Decision(
                modelID: defaultModel, reason: "nothing to route between; used the default"
            )
        }

        var notes: [String] = []
        var eligible = candidates

        // 1 — vision.
        if RoutingQuestions.Cutoff.needsVision.says(answers.needsVision) {
            let seeing = eligible.filter(\.vision)
            if seeing.isEmpty {
                notes.append("wanted vision, nothing here has it")
            } else {
                eligible = seeing
                notes.append("vision required")
            }
        }

        // 2 — context. An unknown window is not a known shortfall: a node model that is not
        // running yet reports none, and vetoing it would quietly empty the swarm out of
        // every long request.
        if RoutingQuestions.Cutoff.needsLongContext.says(answers.needsLongContext) {
            let roomy = eligible.filter {
                ($0.contextWindow ?? Int.max) >= RoutingQuestions.Cutoff.longContextTokens
            }
            if roomy.isEmpty {
                notes.append("wanted a long window, nothing here has one")
            } else {
                eligible = roomy
                notes.append("long context required")
            }
        }

        // 3 — the starting point.
        var chosen: RoutingCandidate
        var why: String
        /// Whether the starting point is a choice Jev made at full confidence — `act`, not
        /// merely inside the band. Rule 5 leaves those alone.
        var isConfidentChoice = false
        let band = answers.bestModel.map {
            _ in RoutingQuestions.thresholds.band(answers.bestModelConfidence)
        }
        if let best = answers.bestModel, band != .escalate,
           let pick = eligible.first(where: { $0.label == best }) {
            chosen = pick
            why = "Jev picked it (confidence \(rounded(answers.bestModelConfidence)))"
            isConfidentChoice = band == .act
        } else if let fallback = eligible.first(where: { $0.id == defaultModel }) {
            chosen = fallback
            why = answers.bestModel == nil
                ? "no model choice came back; used the default"
                : band == .escalate
                    ? "choice confidence \(rounded(answers.bestModelConfidence)) is below "
                        + "\(rounded(RoutingQuestions.thresholds.confirm)); used the default"
                    : "Jev's pick cannot take this one; used the default"
        } else {
            // The default is itself vetoed — a 4K model asked to read a book. Rank what is
            // left rather than failing: the request still has to go somewhere.
            chosen = rank(eligible, answers: answers).first ?? eligible[0]
            why = "the default model cannot take this one; ranked the rest"
        }

        // 4, 5, 6 — at most one.
        if (answers.complexity ?? .infinity) <= RoutingQuestions.Cutoff.trivialComplexity,
           RoutingQuestions.Cutoff.isQuickLookup.says(answers.isQuickLookup),
           !(chosen.readyNow && chosen.isFree),
           let warm = rank(
               eligible.filter { $0.readyNow && $0.isFree }, answers: answers
           ).first {
            chosen = warm
            why = "a trivial lookup, and \(warm.name) is already warm and free"
        } else if isHardWork(answers), chosen.placement.isLocal, !isConfidentChoice,
                  let elsewhere = biggerElsewhere(than: chosen, among: eligible, answers: answers) {
            why = "hard multi-step work, and \(elsewhere.name) on "
                + "\(elsewhere.placement.loggedAs) is bigger "
                + "(\(sizeLabel(elsewhere)) against \(sizeLabel(chosen)))"
            chosen = elsewhere
        } else if RoutingQuestions.Cutoff.isCodeTask.says(answers.isCodeTask),
                  !RoutingQuestions.Cutoff.isCreativeWriting.says(answers.isCreativeWriting),
                  !chosen.codeTuned,
                  let coder = rank(eligible.filter(\.codeTuned), answers: answers).first {
            chosen = coder
            why = "a code task, and \(coder.name) is tuned for code"
        }

        let reason = ([why] + notes).joined(separator: "; ")
        return Decision(modelID: chosen.id, reason: "\(chosen.name) — \(reason)")
    }

    /// The best model elsewhere that is actually *bigger* than the one already chosen.
    ///
    /// "Send hard work to another machine" is only true when the other machine is running
    /// something with more to it. Moving a hard question off a 30B model here onto an 8B one
    /// on a node is a downgrade wearing the words of an upgrade — and a model whose size
    /// nobody published cannot be shown to be an upgrade, so it does not qualify. Both sides
    /// are compared on what actually does the work: active parameters for a
    /// mixture-of-experts model, the whole count for a dense one.
    static func biggerElsewhere(
        than chosen: RoutingCandidate, among candidates: [RoutingCandidate],
        answers: RoutingAnswers
    ) -> RoutingCandidate? {
        let floor = chosen.workingBillions ?? 0
        return rank(
            candidates.filter { !$0.placement.isLocal && ($0.workingBillions ?? 0) > floor },
            answers: answers
        ).first
    }

    static func sizeLabel(_ candidate: RoutingCandidate) -> String {
        guard let billions = candidate.workingBillions else { return "an unpublished size" }
        return "\(RoutingQuestions.number(billions))B working"
    }

    /// Hard enough to be worth another machine. The complexity read has to be one Jev is
    /// sure of; a confident frontier-reasoning noul stands on its own.
    static func isHardWork(_ answers: RoutingAnswers) -> Bool {
        if RoutingQuestions.Cutoff.needsFrontierReasoning.says(answers.needsFrontierReasoning) {
            return true
        }
        guard let complexity = answers.complexity else { return false }
        return complexity >= RoutingQuestions.Cutoff.hardComplexity
            && answers.complexityConfidence >= RoutingQuestions.Cutoff.hardComplexityConfidence
    }

    /// Orders a set of candidates by how well they suit *this* request. Used only to break
    /// ties and to fill in when the choice cannot be used — the choice is the judgment, and
    /// this is arithmetic over traits, which is code's half of the job.
    static func rank(
        _ candidates: [RoutingCandidate], answers: RoutingAnswers
    ) -> [RoutingCandidate] {
        let wantsCode = RoutingQuestions.Cutoff.isCodeTask.says(answers.isCodeTask)
        let wantsProse = RoutingQuestions.Cutoff.isCreativeWriting.says(answers.isCreativeWriting)
        let wantsReasoning = RoutingQuestions.Cutoff.needsFrontierReasoning
            .says(answers.needsFrontierReasoning)
        let wantsSpeed = RoutingQuestions.Cutoff.isQuickLookup.says(answers.isQuickLookup)
        let complexity = answers.complexity ?? 1
        let isHard = complexity >= RoutingQuestions.Cutoff.hardComplexity

        func merit(_ candidate: RoutingCandidate) -> Double {
            var value = 0.0
            if wantsCode, candidate.codeTuned { value += 2 }
            if wantsProse {
                // A coding fine-tune writes fiction like a manual, and a model that will not
                // write the scene at all is no use to someone who asked for it.
                if candidate.uncensored { value += 1 }
                if candidate.codeTuned { value -= 1 }
            }
            if wantsReasoning, candidate.reasoning { value += 1 }
            // Size earns its keep on hard work. On easy work it costs time, which is what
            // the speed term is for.
            if isHard { value += min(candidate.workingBillions ?? 7, 200) / 40 }
            if wantsSpeed { value += min(candidate.tokensPerSecond ?? 0, 120) / 60 }
            if candidate.readyNow { value += 1.5 }
            // Money is a bigger deterrent on an easy question than on a hard one, which is
            // the whole reason someone added a key.
            if !candidate.isFree { value -= isHard ? 0.5 : 1.5 }
            return value
        }

        return candidates.sorted { first, second in
            let left = merit(first)
            let right = merit(second)
            // A stable order matters: the same library and the same answers must produce the
            // same route every time, or a cache hit and a cache miss disagree.
            return left == right ? first.label < second.label : left > right
        }
    }

    static func rounded(_ value: Double) -> String { String(format: "%.2f", value) }
}
