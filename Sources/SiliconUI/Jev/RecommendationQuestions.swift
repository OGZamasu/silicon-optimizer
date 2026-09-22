import Foundation
import SiliconCatalog
import SiliconControl
import SiliconCore
import SiliconPlanner
import SiliconRuntime

// MARK: - The candidate

/// One model on the shortlist, described in the words a judgment can be made from.
///
/// Every field here is derived from the catalog entry and this Mac's own memory plan by
/// code, never by the model: what the model is asked is which of these suits the job, not
/// how big the file is. Raw values are kept raw — `maxContext` is a token count and
/// `tokensPerSecond` is a rate — and the prompt turns them into named buckets on the way
/// out, because `jev-1.13` reads `262144` far less reliably than it reads "very long".
public struct RecommendationCandidate: Sendable, Equatable, Hashable {

    /// Catalog id. Also the option name in the Choice, so the answer maps back to an entry
    /// without a lookup table that could drift.
    public var id: String
    /// What the browser calls it.
    public var name: String
    /// The name with its size and runtime tokens removed — "Qwen3-Coder 30B A3B" is the
    /// `Qwen3-Coder` family. Two entries of the same family differ by size and packing, and
    /// saying so keeps the Choice from reading like eight unrelated products.
    public var family: String
    /// "30B", or "30B (3.3B active)" for a mixture of experts.
    public var parameters: String
    /// The traits below, in the order `RecommendationTrait.allCases` lists them.
    public var capabilities: [RecommendationTrait]
    /// The context this Mac will actually load the model at, from its own memory plan.
    ///
    /// This, not `maxContext`, is what a long-context job has to clear. A 262K ceiling on
    /// an entry that plans to 16K here is a fact about the model and a fiction about this
    /// computer, and recommending it for "read the whole repository" on the strength of the
    /// ceiling would be a promise the machine cannot keep.
    public var contextLength: Int
    /// The catalogue ceiling. Kept only to say that a bigger Mac would go further.
    public var maxContext: Int
    /// The best quantization that fits on this Mac, and what it is predicted to generate at.
    public var quantization: String
    public var tokensPerSecond: Double
    /// Editorial rating, 1–5.
    public var rating: Int
    public var isInstalled: Bool
    public var isFeatured: Bool

    public init(
        id: String, name: String, family: String, parameters: String,
        capabilities: [RecommendationTrait], contextLength: Int, maxContext: Int,
        quantization: String, tokensPerSecond: Double, rating: Int, isInstalled: Bool,
        isFeatured: Bool
    ) {
        self.id = id
        self.name = name
        self.family = family
        self.parameters = parameters
        self.capabilities = capabilities
        self.contextLength = contextLength
        self.maxContext = maxContext
        self.quantization = quantization
        self.tokensPerSecond = tokensPerSecond
        self.rating = rating
        self.isInstalled = isInstalled
        self.isFeatured = isFeatured
    }

    public func has(_ trait: RecommendationTrait) -> Bool { capabilities.contains(trait) }
}

/// What a model can do, as this feature needs to talk about it.
///
/// Not `ModelCapabilities` itself: that option set has no member for "will answer an adult
/// request", which is a real axis of this decision and is carried in the catalog by a LoRA
/// and a name rather than by a flag. One enum, so the Choice's descriptions, the nouls and
/// the vetoes all use the same vocabulary.
public enum RecommendationTrait: String, Sendable, CaseIterable, Hashable {
    case coding, vision, reasoning, toolCalling, multilingual, uncensored, embedding

    /// What the model is told this trait means. Written as a capability of the model, so it
    /// reads as the other half of the matching noul about the job.
    public var phrase: String {
        switch self {
        case .coding: "writes, reviews and debugs source code"
        case .vision: "reads images, screenshots and scanned pages"
        case .reasoning: "works through a problem step by step before answering"
        case .toolCalling: "calls tools and functions, and emits structured JSON a program runs"
        case .multilingual: "works in languages other than English"
        case .uncensored: "answers adult and edgy requests that most models refuse"
        case .embedding: "turns text into vectors for search; it does not hold a conversation"
        }
    }

    /// The same trait in the one-line reason the owner reads.
    public var shortPhrase: String {
        switch self {
        case .coding: "code"
        case .vision: "vision"
        case .reasoning: "deep reasoning"
        case .toolCalling: "tool calling"
        case .multilingual: "non-English text"
        case .uncensored: "uncensored answers"
        case .embedding: "embeddings"
        }
    }
}

// MARK: - The question set

/// Task-aware model recommendation: the owner says what the job is, Jev judges what the job
/// needs, and `RecommendationPolicy` combines that with what this Mac can actually run.
///
/// Questions, thresholds and policy in one file, which is the convention `JevQuestionSet`
/// documents and the reason for it: a question's wording *is* the behaviour, and a threshold
/// decides what is done with the answer. A reviewer should be able to read the whole policy
/// here without opening anything else.
///
/// **On the protocol's `questions`.** One of the questions — the Choice — is built from the
/// shortlist, which is not known until a request is being prepared, so the static property
/// carries the eight nouls and the score, which never change, and `questions(over:)` adds
/// the Choice. `ask(task:candidates:using:)` below sends the merged set through the same
/// door `JevQuestionSet.ask` uses, so the master switch, the feature toggle, the budget, the
/// size limit, the cache and the ledger all still apply.
public enum RecommendationQuestions: JevQuestionSet {

    public static let feature = JevFeature.recommendation

    /// The shortlist's ceiling. A Choice takes up to 255 options and the state limit is far
    /// above what sixteen candidates cost — this is a accuracy bound, not a size one.
    /// `jev-1.13` loses accuracy to irrelevant detail, and the seventeenth-best fit for this
    /// machine is not going to win.
    public static let maximumCandidates = 16

    /// How much of the owner's description of the job is sent. A few kilobytes is a long
    /// paragraph; past that it is a document, and a document is exactly the "large state
    /// full of irrelevant detail" the jaggedness note warns about.
    public static let maximumTaskBytes = 4_096

    // MARK: Thresholds

    /// The Choice's gate. Above `act` the ranking is Jev's; between the two it is Jev's with
    /// the answer marked as close; below `confirm` the whole ordering falls back to hardware
    /// fit, because a flat distribution over sixteen models is the model saying it cannot
    /// separate them, and guessing from it would be worse than the fit order we already had.
    ///
    /// Low rather than a classifier's 0.8: confidence measures how concentrated the
    /// distribution is, and with sixteen options several of which are genuinely
    /// interchangeable, a clear winner rarely takes most of the mass. Nothing is spent or
    /// deleted on the strength of this — it orders a list the owner then reads.
    public static let choiceThresholds = JevThresholds(act: 0.55, confirm: 0.30)

    /// A noul's gate for a **hard requirement** — vision, tool calling, uncensored answers,
    /// a long context. High and it vetoes every candidate that cannot do it, so the bar is
    /// set where a confident yes is meant, and the middle does nothing.
    public static let requirement = (yes: 0.80, no: 0.20)

    /// A noul's gate for a **preference**: it moves a weight rather than removing a model,
    /// so it does not need the same evidence.
    public static let preference = (yes: 0.60, no: 0.40)

    /// Where a `task_difficulty` score stops counting as everyday work. The score runs 0…2,
    /// so this is "closer to demanding than to moderate".
    public static let demandingFloor = 1.5

    /// Below this confidence the difficulty score is not read at all.
    ///
    /// A Score's confidence is how concentrated the distribution over the levels is, and a
    /// flat one means the levels overlapped for this job or the description did not say
    /// enough to place it. An expected value computed from a flat distribution lands near
    /// the middle whatever the job was, and this one only ever does one thing — decide
    /// whether speed still counts — so an unplaceable job is treated as ordinary rather
    /// than read as a number that means nothing.
    public static let scoreConfidenceFloor = 0.50

    /// What `needs_long_context` asks for, in tokens: a model below this cannot hold a book
    /// or a codebase in one go, whatever else it is good at.
    public static let longContextTokens = 131_072

    // MARK: Questions

    /// The candidate-independent half: eight nouls about what the job needs, and one score
    /// for how hard it is. Every one is written about the job, never about a model, so the
    /// answers stay reusable when the shortlist changes.
    ///
    /// Each is deliberately literal. `jev-1.13` answers the question that was written, so a
    /// scoping word that a person would read past is written out, and the `false` side of
    /// each noul names the case that would otherwise be read into the `true` side.
    public static let questions: [String: ControlAPI.SystemOneQuestion] = [
        "needs_vision": noul(
            "The job described in `task` requires looking at pictures: photographs, "
            + "screenshots, diagrams, scanned pages or video frames.",
            yes: "The work cannot be done without seeing an image.",
            no: "The work is entirely text, including code, even if it mentions images, "
                + "image files or image generation in words."
        ),
        "needs_code": noul(
            "The job described in `task` involves reading, writing, reviewing, translating "
            + "or debugging source code.",
            yes: "Source code is part of the input or part of the output.",
            no: "The work is prose, data or conversation, with no source code in it."
        ),
        "needs_tool_calling": noul(
            "The job described in `task` requires the model to call tools or functions, or "
            + "to emit structured JSON that a program then acts on.",
            yes: "It is an agent, an assistant wired to tools, or a step in an automated "
                + "pipeline that consumes the model's output as data.",
            no: "A person reads the model's answer and decides what to do next."
        ),
        "needs_multilingual": noul(
            "The job described in `task` involves text in a language other than English — "
            + "either the text going in, or the text coming out.",
            yes: "Another language is named, or the text quoted in the task is in one.",
            no: "Everything in the job is in English."
        ),
        "needs_long_context": noul(
            "The job described in `task` requires the model to read a very large amount of "
            + "text at once — a whole book, a full transcript, or an entire codebase in a "
            + "single request — rather than a few pages at a time.",
            yes: "The whole body of material has to be in front of the model together.",
            no: "The work is done a document, a file or a message at a time, however many "
                + "of them there are."
        ),
        "needs_uncensored": noul(
            "The job described in `task` asks for adult, explicit, graphically violent or "
            + "otherwise transgressive content that a typical instruction-tuned assistant "
            + "would refuse to produce.",
            yes: "Producing what was asked for means writing the material most models "
                + "decline to write.",
            no: "The subject may be dark, clinical, legal or uncomfortable, but a typical "
                + "assistant would answer it."
        ),
        "needs_fast_responses": noul(
            "In the job described in `task`, a person is waiting for each answer and wants "
            + "it quickly.",
            yes: "It is interactive — a chat, an editor completion, a shell helper — and "
                + "latency is felt.",
            no: "It runs in the background, in a batch, or overnight, and nobody is "
                + "watching it produce each token."
        ),
        "needs_deep_reasoning": noul(
            "The job described in `task` requires working a problem through in several "
            + "steps — planning, proving, deriving, or diagnosing from symptoms — before an "
            + "answer can be given.",
            yes: "Getting it right takes reasoning the model has to do itself.",
            no: "It is recall, summary, extraction, translation or rewriting, where the "
                + "answer follows from the material directly."
        ),
        "task_difficulty": .init(
            type: "score",
            instructions: .string(
                "How demanding is the job described in `task` for the language model that "
                + "will do it?"
            ),
            criteria: .array([
                .string(
                    "Simple: short, well-defined turns a small model handles — rewriting, "
                    + "tagging, extraction, everyday chat, quick questions."
                ),
                .string(
                    "Moderate: real work with judgment in it — drafting and editing "
                    + "documents, ordinary programming, answering questions about material "
                    + "supplied with the request."
                ),
                .string(
                    "Demanding: work where a weaker model produces plausible and wrong "
                    + "answers — unfamiliar algorithms, architecture and design, subtle "
                    + "debugging, specialist or professional subject matter."
                ),
            ])
        ),
    ]

    /// The full set for one request: the nouls and the score above, plus the Choice over
    /// this shortlist.
    ///
    /// The Choice is the relative question — *which of these*, given everything — and the
    /// nouls are the absolute ones. The jaggedness note is explicit that the two are not
    /// interchangeable and that neither's threshold carries over to the other, which is why
    /// the policy below uses the Choice for ordering and the nouls for vetoes, and never the
    /// other way round.
    public static func questions(
        over candidates: [RecommendationCandidate]
    ) -> [String: ControlAPI.SystemOneQuestion] {
        guard !candidates.isEmpty else { return questions }
        var all = questions
        all["best_for_task"] = .init(
            type: "choice",
            instructions: .object([
                "question": .string(
                    "Which of these models should do the job described in `task`?"
                ),
                "focus": .string(
                    "Judge how well each model's abilities match what the job needs. Every "
                    + "option listed already runs on this computer, so do not weigh how "
                    + "large or how fast it is except where the job itself calls for speed."
                ),
            ]),
            criteria: .object(
                Dictionary(uniqueKeysWithValues: candidates.map {
                    ($0.id, describe($0, against: candidates))
                })
            )
        )
        return all
    }

    /// One option's description, written against its rivals.
    ///
    /// `cannot` is the contrastive half and is computed, not authored: it lists the traits
    /// some *other* candidate on this shortlist has and this one does not. Two entries from
    /// the same family at different sizes otherwise read as near-duplicates, and the
    /// structured-criteria guidance is explicit that similar options need to say what they
    /// are not for.
    static func describe(
        _ candidate: RecommendationCandidate, against all: [RecommendationCandidate]
    ) -> JSONContent {
        let elsewhere = Set(all.flatMap(\.capabilities)).subtracting(candidate.capabilities)
        var fields: [String: JSONContent] = [
            "model": .string(candidate.name),
            "family": .string(candidate.family),
            "size": .string(candidate.parameters),
            "good_at": .array(
                candidate.capabilities.map { .string($0.phrase) }
            ),
            "context": .string(contextLabel(candidate.contextLength)),
            "speed_here": .string(speedLabel(candidate.tokensPerSecond)),
            "reputation": .string(ratingLabel(candidate.rating)),
        ]
        // The ceiling, only when it is higher than what this computer will load — so the
        // model is judged on what it will actually do here, with the headroom mentioned
        // rather than offered.
        if candidate.maxContext > candidate.contextLength {
            fields["context_ceiling"] = .string(
                "Trained to go further; a computer with more memory would load more of it."
            )
        }
        if !elsewhere.isEmpty {
            fields["cannot"] = .array(
                RecommendationTrait.allCases
                    .filter(elsewhere.contains)
                    .map { .string($0.phrase) }
            )
        }
        if candidate.isInstalled {
            fields["already_here"] = .string("Already downloaded on this computer.")
        }
        if candidate.isFeatured {
            fields["editors_pick"] = .string("The catalogue's current spotlight entry.")
        }
        return .object(fields)
    }

    /// Token counts as words. `jev-1.13` is unreliable on numeric magnitude and reliable on
    /// named buckets, so the number never reaches the model.
    static func contextLabel(_ tokens: Int) -> String {
        switch tokens {
        case ..<16_385: "short — a few long documents at most"
        case ..<65_537: "standard — a large document or a long conversation"
        case ..<262_144: "long — a small codebase or a short book in one request"
        default: "very long — a book or a whole repository in one request"
        }
    }

    /// Likewise for the rate. The figure is in the parenthesis for a reader who wants it;
    /// the judgment hangs on the word in front of it.
    static func speedLabel(_ tokensPerSecond: Double) -> String {
        let bucket: String
        switch tokensPerSecond {
        case ..<15: bucket = "slow — noticeable waiting on every reply"
        case ..<30: bucket = "workable — reads about as fast as a person"
        case ..<60: bucket = "fast"
        default: bucket = "very fast — answers appear almost at once"
        }
        return bucket + String(format: " (about %.0f words a second)", tokensPerSecond)
    }

    static func ratingLabel(_ rating: Int) -> String {
        switch rating {
        case ...2: "weak for its size"
        case 3: "sound"
        case 4: "strong"
        default: "one of the best available"
        }
    }

    /// A noul with both sides written out. The `false` description is not decoration: the
    /// jaggedness note's first failure mode is literal reading, and the case a reader would
    /// wrongly fold into `true` belongs in `false` where the model can see it.
    static func noul(_ instructions: String, yes: String, no: String) -> ControlAPI.SystemOneQuestion {
        .init(
            type: "noul",
            instructions: .string(instructions),
            criteria: .object(["true": .string(yes), "false": .string(no)])
        )
    }

    // MARK: The shortlist

    /// Which traits keep a slot on the shortlist however far down the fit order they are.
    ///
    /// The plain top sixteen is a list ordered by one axis, and a Mac with a deep catalogue
    /// can fill all sixteen with general text models — at which point a job that needs to
    /// look at a photograph is asked about a shortlist with nothing on it that can, and the
    /// veto empties the list and falls back. The model cannot choose an option that was not
    /// offered, so the best-fitting example of each thing a job can *require* is offered.
    public static let reservedTraits: [RecommendationTrait] = [
        .vision, .toolCalling, .uncensored,
    ]

    /// The top `limit` by hardware fit, with a slot kept for the best-fitting candidate
    /// that can see, that can call tools, that will answer an adult request, that loads a
    /// long context here, and for the fastest one on the machine.
    ///
    /// Reservations displace from the bottom — the lowest-fitting unreserved entry goes —
    /// and never the best fit, which is the answer this route gives when Jev is off. The
    /// result stays in fit order, because that is the order the fallback uses.
    public static func shortlist(
        from ranked: [RecommendationCandidate], limit: Int = maximumCandidates
    ) -> [RecommendationCandidate] {
        guard limit > 0 else { return [] }
        guard ranked.count > limit else { return ranked }

        var chosen = Set(0..<limit)
        var reserved: Set<Int> = []

        var wanted: [Int] = reservedTraits.compactMap { trait in
            ranked.firstIndex { $0.has(trait) }
        }
        if let long = ranked.firstIndex(where: { $0.contextLength >= longContextTokens }) {
            wanted.append(long)
        }
        if let fastest = ranked.indices.max(by: {
            ranked[$0].tokensPerSecond < ranked[$1].tokensPerSecond
        }) {
            wanted.append(fastest)
        }

        for index in wanted {
            if chosen.contains(index) {
                reserved.insert(index)
                continue
            }
            // The highest index among the unreserved is the worst fit of the ones kept.
            // Index 0 is never given up: it is what this route answers without Jev, and a
            // reservation should widen the choice rather than remove the default from it.
            guard let worst = chosen.filter({ $0 != 0 && !reserved.contains($0) }).max()
            else { break }
            chosen.remove(worst)
            chosen.insert(index)
            reserved.insert(index)
        }
        return chosen.sorted().map { ranked[$0] }
    }

    // MARK: State

    /// The `state` half of the request: the job, and the shortlist by id, name and size.
    ///
    /// **What leaves this Mac is this plus the questions**, and the questions are the
    /// larger half — `describe(_:against:)` above writes each option's abilities, the
    /// context bucket and the speed bucket *this computer* plans for it, whether it is
    /// already downloaded, and whether it is the catalogue's spotlight entry. So the honest
    /// summary is: the owner's description of the job, and a rough performance sketch of
    /// sixteen catalogue models on this machine. Not a file, not a conversation, not a
    /// path, not a machine name, not what else is installed beyond `already_here`, and
    /// nothing at all about a swarm peer.
    ///
    /// Two consequences worth knowing. `already_here` says something about this library, so
    /// the same job asked on two Macs is not the same request. And `speed_here` is a
    /// prediction that moves with memory pressure, so an identical retry while something
    /// large is running produces a different body, misses the cache and is paid for again —
    /// which is the price of judging models on what they will do here rather than on a
    /// spec sheet.
    ///
    /// The task text is somebody's prose and is not trusted to be inert — `jev-1.13` does
    /// not treat state as hostile, and a description that argues for its own answer can
    /// move one. What limits the damage is the shape rather than the wording: every answer
    /// is typed, the Choice's options are catalogue ids this code put there, and the
    /// ranking that comes out is a reordering of a list code already built. A task cannot
    /// name a model that is not on the shortlist, cannot lift one this Mac was not going to
    /// run, and cannot reach anything but the order of three suggestions.
    public static func state(
        task: String, candidates: [RecommendationCandidate]
    ) -> JSONContent {
        .object([
            "task": .string(task),
            "models_available": .array(candidates.map {
                .object([
                    "id": .string($0.id),
                    "model": .string($0.name),
                    "size": .string($0.parameters),
                ])
            }),
        ])
    }

    /// The owner's description of the job, or nil when there is nothing to judge — and
    /// whether anything was cut off getting there.
    ///
    /// `truncated` is returned rather than swallowed because the caller can be told. A job
    /// described in six pages was judged on the first four kilobytes of it, and somebody
    /// wondering why the answer ignored the part about Japanese deserves to know that the
    /// part about Japanese was never sent.
    ///
    /// Cut on a character boundary rather than a byte one, so a multi-byte scalar is never
    /// halved — a lone continuation byte would be a decoding failure on the wire rather
    /// than a shorter question.
    public static func trimmedTask(_ task: String?) -> (text: String, truncated: Bool)? {
        guard let task else { return nil }
        let trimmed = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.utf8.count > maximumTaskBytes else { return (trimmed, false) }
        var kept = ""
        var bytes = 0
        for character in trimmed {
            let width = String(character).utf8.count
            if bytes + width > maximumTaskBytes { break }
            kept.append(character)
            bytes += width
        }
        return (kept, true)
    }

    // MARK: Asking

    /// One request, through `JevService`, with every question this feature has.
    ///
    /// No `cacheKey`: the service's own is a digest of the whole request body, and the body
    /// here is a function of the job and the shortlist and nothing else, so two calls a
    /// minute apart about the same job already collapse into one. Passing a key made of the
    /// task text would buy nothing and would put somebody's prose into a cache key, which
    /// is the thing the derived key exists to avoid.
    public static func ask(
        task: String, candidates: [RecommendationCandidate],
        using service: JevService = .shared
    ) async throws -> ControlAPI.DecideResponse {
        try await DecisionRouter.router(for: service).decide(
            feature,
            state: state(task: task, candidates: candidates),
            questions: questions(over: candidates)
        )
    }
}

// MARK: - The policy

/// What the app does with the answers. A pure function, so it can be exercised against
/// hand-written responses without a network, a key or a machine of a particular size.
public enum RecommendationPolicy {

    // MARK: Weights

    /// How much Jev's own pick counts. The largest of the three: the whole point of asking
    /// is that matching a job to a model is a judgment, and the two terms below are the
    /// things code already knew.
    public static let jevWeight = 0.55
    /// How much this Mac's memory-and-speed fit counts, normalised so the best-fitting
    /// candidate scores 1. It is a real constraint and not only a tie-break: a model that
    /// barely fits is a worse recommendation than one that fits comfortably.
    public static let fitWeight = 0.30
    /// How much raw generation speed counts — and only when the job says a person is
    /// waiting. Zero otherwise, so a batch job is never handed a weaker model for being
    /// quick.
    public static let speedWeight = 0.15

    /// Where the speed term stops climbing, in tokens a second. Past this, faster is not
    /// better in any way a person notices, and rewarding it would tilt every interactive
    /// job towards the smallest model on the list. The same ceiling `AutoConfigurator`
    /// uses for its own speed term.
    public static let speedCeiling = 40.0

    /// How many are returned.
    public static let places = 3

    // MARK: Result

    public struct Ranked: Sendable, Equatable {
        public var id: String
        /// One line, for the owner: what the job needs, and what this model costs to run.
        public var reason: String
        public var score: Double

        public init(id: String, reason: String, score: Double) {
            self.id = id
            self.reason = reason
            self.score = score
        }
    }

    public struct Outcome: Sendable, Equatable {
        /// Best first, at most `places` of them.
        public var ranked: [Ranked]
        /// Everything the owner should know about *why this list is this list*: an ordering
        /// that is not Jev's, a Choice too close to call, a pick the weights demoted, a
        /// requirement nothing could meet. A list rather than one string because more than
        /// one can be true at once, and the caller joins them.
        public var notes: [String]
        /// False when hardware fit did the ordering — because the Choice was too flat to
        /// separate the shortlist, or because every candidate failed a requirement and the
        /// vetoes had to be set aside.
        public var followedJev: Bool

        public init(ranked: [Ranked], notes: [String], followedJev: Bool) {
            self.ranked = ranked
            self.notes = notes
            self.followedJev = followedJev
        }

        /// The notes as one sentence-run, or nil when there is nothing to say.
        public var note: String? { notes.isEmpty ? nil : notes.joined(separator: " ") }
    }

    // MARK: Ranking

    /// Veto, then weigh.
    ///
    /// - Parameters:
    ///   - answers: one `DecideResponse` carrying every question in the set. Read through
    ///     the typed accessors, so a renamed id or a changed question kind throws by name
    ///     instead of silently ranking on a default.
    ///   - candidates: the shortlist, in hardware-fit order.
    ///   - fitScores: each candidate's hardware fit, normalised to 0…1. A candidate with no
    ///     entry counts as 0 rather than being dropped — a missing fit is a code error, and
    ///     losing a model silently is the worse failure.
    public static func rank(
        answers: ControlAPI.DecideResponse,
        candidates: [RecommendationCandidate],
        fitScores: [String: Double]
    ) throws -> Outcome {
        guard !candidates.isEmpty else {
            return Outcome(ranked: [], notes: [], followedJev: false)
        }

        let needs = try Needs(answers)
        let choice = try answers.choice("best_for_task")
        let band = RecommendationQuestions.choiceThresholds.band(choice.confidence)
        var notes: [String] = []

        // Vetoes first, and they survive a low-confidence Choice: a noul is its own absolute
        // judgment with its own gate, and "this job needs to look at pictures" does not stop
        // being true because the model could not separate sixteen models on everything else.
        var eligible = candidates.filter { needs.vetoReason(for: $0) == nil }
        var ranByFit = band == .escalate
        // Set when nothing met the requirements and the vetoes had to be dropped. It
        // changes what is worth saying afterwards: "Jev preferred this one, but it cannot
        // see" is useful when something else could, and noise when nothing could.
        let vetoesSetAside = eligible.isEmpty
        if eligible.isEmpty {
            // Everything was ruled out. Better to answer with the hardware-fit order and say
            // why than to 404 a machine that can run something.
            eligible = candidates
            ranByFit = true
            notes.append(
                "No model here can do everything this job needs — "
                + (needs.unmetPhrase(candidates) ?? "some requirement is unmet")
                + ". Ranked on how well they run here instead."
            )
        } else if ranByFit {
            notes.append(String(
                format: "Jev could not separate these for this job (confidence %.2f), "
                    + "so they are ranked by how well they run here.", choice.confidence
            ))
        } else if band == .confirm {
            notes.append(String(
                format: "Jev's pick is not clear-cut (confidence %.2f); the next two are close.",
                choice.confidence
            ))
        }

        let ordered: [(RecommendationCandidate, Double)]
        if ranByFit {
            ordered = eligible
                .map { ($0, fitScores[$0.id] ?? 0) }
                .sorted {
                    if $0.1 != $1.1 { return $0.1 > $1.1 }
                    return $0.0.id < $1.0.id
                }
        } else {
            ordered = eligible
                .map { ($0, composite($0, needs: needs, choice: choice, fitScores: fitScores)) }
                // Fit breaks a tie, and the id breaks that, so the same inputs always give
                // the same list — `sorted` is not stable and a shuffling recommendation is
                // an alarming thing to watch.
                .sorted {
                    if $0.1 != $1.1 { return $0.1 > $1.1 }
                    let left = fitScores[$0.0.id] ?? 0, right = fitScores[$1.0.id] ?? 0
                    if left != right { return left > right }
                    return $0.0.id < $1.0.id
                }
        }

        // The composite can and does overrule the Choice — that is what the fit and speed
        // terms are for — and when it has, the owner is told rather than left to wonder why
        // the model Jev named is second. Two ways it happens, and they read differently: a
        // veto took Jev's pick off the list, or the weights moved it down.
        if let top = ordered.first?.0, top.id != choice.choice,
           let preferred = candidates.first(where: { $0.id == choice.choice }) {
            if let veto = needs.vetoReason(for: preferred) {
                if !vetoesSetAside {
                    notes.append(
                        "Jev preferred \(preferred.name), but it has \(veto) for this job."
                    )
                }
            } else if !ranByFit {
                notes.append(
                    "Jev preferred \(preferred.name); it is ranked lower because it runs "
                    + "less well on this Mac."
                )
            }
        }

        return Outcome(
            ranked: ordered.prefix(places).map {
                Ranked(id: $0.0.id, reason: reason(for: $0.0, needs: needs), score: $0.1)
            },
            notes: notes,
            followedJev: !ranByFit
        )
    }

    /// `w_jev·P(this model) + w_fit·fit + w_speed·speed`, and the third term only when the
    /// job says someone is waiting *and* the job is not demanding. A person who asked for a
    /// proof will wait for it; a person typing in an editor will not, and that is the whole
    /// of what `task_difficulty` decides here.
    static func composite(
        _ candidate: RecommendationCandidate,
        needs: Needs,
        choice: (choice: String, confidence: Double, probabilities: [String: Double]),
        fitScores: [String: Double]
    ) -> Double {
        let jev = choice.probabilities[candidate.id] ?? 0
        let fit = fitScores[candidate.id] ?? 0
        let speed = needs.rewardsSpeed
            ? min(candidate.tokensPerSecond / speedCeiling, 1)
            : 0
        return jevWeight * jev + fitWeight * fit + speedWeight * speed
    }

    /// Raw `AutoConfigurator` scores onto 0…1, best at 1.
    ///
    /// Relative rather than absolute because the raw score has no ceiling and means nothing
    /// on its own: it is a sum of terms tuned to order a list, and what this needs from it
    /// is where each candidate stands against the best one on *this* machine.
    public static func normalizedFit(_ scores: [String: Double]) -> [String: Double] {
        guard let best = scores.values.max(), best > 0 else {
            return scores.mapValues { _ in 0 }
        }
        return scores.mapValues { max(0, min($0 / best, 1)) }
    }

    /// "needs vision and tool calling; fits at Q4_K_M at ~28 tok/s".
    static func reason(for candidate: RecommendationCandidate, needs: Needs) -> String {
        var line: String
        let met = needs.required.filter(candidate.has)
        if met.isEmpty {
            line = needs.rewardsSpeed ? "quick general work" : "general work"
        } else {
            line = "needs " + list(met.map(\.shortPhrase))
        }
        line += String(
            format: "; fits at %@ at ~%.0f tok/s", candidate.quantization,
            candidate.tokensPerSecond
        )
        if candidate.isInstalled { line += "; already installed" }
        return line
    }

    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: ""
        case 1: items[0]
        case 2: "\(items[0]) and \(items[1])"
        default: items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }

    // MARK: What the job needs

    /// The nouls and the score, read once through the typed accessors and turned into the
    /// handful of booleans the rest of the policy uses. Separated so every threshold
    /// comparison is in one place a reviewer can check against the thresholds above.
    struct Needs: Sendable, Equatable {
        var vision = false
        var coding = false
        var toolCalling = false
        var multilingual = false
        var longContext = false
        var uncensored = false
        var deepReasoning = false
        var fastResponses = false
        var difficulty = 0.0
        /// Whether `difficulty` came back concentrated enough to act on.
        var difficultyIsReadable = false

        init(_ answers: ControlAPI.DecideResponse) throws {
            let hard = RecommendationQuestions.requirement
            let soft = RecommendationQuestions.preference
            vision = Self.confidentYes(try answers.noul("needs_vision"), hard)
            coding = Self.confidentYes(try answers.noul("needs_code"), soft)
            toolCalling = Self.confidentYes(try answers.noul("needs_tool_calling"), hard)
            multilingual = Self.confidentYes(try answers.noul("needs_multilingual"), soft)
            longContext = Self.confidentYes(try answers.noul("needs_long_context"), hard)
            uncensored = Self.confidentYes(try answers.noul("needs_uncensored"), hard)
            deepReasoning = Self.confidentYes(try answers.noul("needs_deep_reasoning"), soft)
            fastResponses = Self.confidentYes(try answers.noul("needs_fast_responses"), soft)
            let scored = try answers.score("task_difficulty")
            // A flat distribution over the levels is the model saying it cannot place this
            // job, and the expectation of a flat distribution is the middle of the scale
            // whatever the job was. Read as "ordinary" instead of as a number that means
            // nothing — which, since difficulty only ever decides whether speed still
            // counts, is the same as not reading it.
            // The score is kept whatever its confidence, and `isDemanding` is the one
            // place that decides whether to believe it. Zeroing it here as well would be a
            // second guard saying the same thing, and two mechanisms for one rule is how a
            // rule quietly survives having one of them deleted.
            difficultyIsReadable = scored.confidence >= RecommendationQuestions.scoreConfidenceFloor
            difficulty = scored.score
        }

        /// A noul's own gate, which is not a Choice's. The number a noul returns *is* the
        /// answer, so the certain readings are at both ends and only a confident yes counts
        /// as a requirement — `noulBand` is what says which end this landed at.
        static func confidentYes(_ p: Double, _ gate: (yes: Double, no: Double)) -> Bool {
            JevThresholds.noulBand(p, yes: gate.yes, no: gate.no) == .act && p >= gate.yes
        }

        var isDemanding: Bool {
            difficultyIsReadable && difficulty >= RecommendationQuestions.demandingFloor
        }

        /// Speed earns its weight only on interactive work that is not demanding.
        var rewardsSpeed: Bool { fastResponses && !isDemanding }

        /// The traits a candidate is vetoed for lacking. Long context is not a trait, so it
        /// is checked separately in `vetoReason`.
        var hardTraits: [RecommendationTrait] {
            var traits: [RecommendationTrait] = []
            if vision { traits.append(.vision) }
            if toolCalling { traits.append(.toolCalling) }
            if uncensored { traits.append(.uncensored) }
            return traits
        }

        /// Everything the job asked for, hard or soft, for the reason line.
        var required: [RecommendationTrait] {
            var traits = hardTraits
            if coding { traits.append(.coding) }
            if multilingual { traits.append(.multilingual) }
            if deepReasoning { traits.append(.reasoning) }
            return RecommendationTrait.allCases.filter(traits.contains)
        }

        /// Why this candidate cannot do the job, or nil if it can. The string is for a
        /// person reading a log or a failing test; the policy only asks whether it is nil.
        func vetoReason(for candidate: RecommendationCandidate) -> String? {
            if let missing = hardTraits.first(where: { !candidate.has($0) }) {
                return "no \(missing.shortPhrase)"
            }
            // What this Mac will load, not what the entry is trained to. A 262K ceiling
            // planned down to 16K here cannot hold a repository, and saying it can is the
            // one promise this feature must not make.
            if longContext,
               candidate.contextLength < RecommendationQuestions.longContextTokens {
                return "too short a context on this Mac"
            }
            return nil
        }

        /// Which requirement nothing on the shortlist could meet, for the note.
        func unmetPhrase(_ candidates: [RecommendationCandidate]) -> String? {
            if let missing = hardTraits.first(where: { trait in
                !candidates.contains { $0.has(trait) }
            }) {
                return "none of them \(missing.phrase)"
            }
            if longContext, !candidates.contains(where: {
                $0.contextLength >= RecommendationQuestions.longContextTokens
            }) {
                return "none of them holds a whole codebase in one request"
            }
            return nil
        }
    }
}

// MARK: - Deriving a candidate

extension RecommendationCandidate {

    /// The traits a catalog entry has.
    ///
    /// Six come from `ModelCapabilities`. The seventh does not exist there: whether an entry
    /// will answer an adult or edgy request is carried in this catalog by its name and by
    /// the refusal-ablation LoRA its variants apply at load, so it is read from those. Both
    /// signals rather than either, because a rename should not silently drop the trait and a
    /// future adapter that is not an ablation should not silently add it.
    public static func traits(of entry: ModelEntry) -> [RecommendationTrait] {
        var traits: [RecommendationTrait] = []
        if entry.capabilities.contains(.coding) { traits.append(.coding) }
        if entry.capabilities.contains(.vision) { traits.append(.vision) }
        if entry.capabilities.contains(.reasoning) { traits.append(.reasoning) }
        if entry.capabilities.contains(.toolCalling) { traits.append(.toolCalling) }
        if entry.capabilities.contains(.multilingual) { traits.append(.multilingual) }
        if isUncensored(entry) { traits.append(.uncensored) }
        if entry.capabilities.contains(.embedding) { traits.append(.embedding) }
        return RecommendationTrait.allCases.filter(traits.contains)
    }

    /// What the catalogue declares, or — belt and braces — an entry carrying an adapter
    /// that projects out the refusal direction.
    ///
    /// The declaration is the answer; the adapter check is the safety net, so an entry
    /// added with the flag forgotten is still described honestly rather than offered to
    /// somebody who asked for a model that refuses things. `RecommendationTraitTests` turns
    /// the net into a failing test, so a forgotten flag is a red build and not a silent
    /// second source of truth.
    ///
    /// Matched case-insensitively but *not* by locale: `localizedCaseInsensitiveContains`
    /// folds case according to whoever is running the app, and the Turkish dotless i is a
    /// real example of that changing what "REFUSAL" matches. A catalogue string is data,
    /// not the owner's language.
    public static func isUncensored(_ entry: ModelEntry) -> Bool {
        if entry.isUncensored { return true }
        return entry.variants.contains { variant in
            guard let summary = variant.lora?.summary else { return false }
            return summary.range(of: "refusal", options: .caseInsensitive) != nil
                || summary.range(of: "ablat", options: .caseInsensitive) != nil
        }
    }

    /// The name with the parts that say how big it is, and in what runtime, taken out.
    ///
    /// Purely lexical and deliberately so: a hand-kept family field would be one more thing
    /// to forget when an entry is added, and the naming convention in this catalog — name,
    /// size, packing — is consistent enough to read.
    public static func family(of entry: ModelEntry) -> String {
        let dropped: Set<String> = ["mlx", "gguf", "instruct"]
        let kept = entry.name.split(separator: " ").filter { token in
            // Bracketed in some names — "Qwen3.8 27B (MLX)" — so the brackets come off
            // before the word is recognised rather than after it is not.
            let word = String(token).trimmingCharacters(in: CharacterSet(charactersIn: "()[]"))
            if dropped.contains(word.lowercased()) { return false }
            return !isSizeToken(word)
        }
        let family = kept.joined(separator: " ")
        return family.isEmpty ? entry.name : family
    }

    /// "30B", "A3B", "1.7B", "120B" — a parameter count, not a word.
    static func isSizeToken(_ token: String) -> Bool {
        var body = Substring(token)
        if body.first == "A" || body.first == "a" { body = body.dropFirst() }
        guard let last = body.last, last == "B" || last == "b" || last == "M" || last == "m"
        else { return false }
        let digits = body.dropLast()
        guard !digits.isEmpty, digits.allSatisfy({ $0.isNumber || $0 == "." }),
              digits.first?.isNumber == true
        else { return false }
        return true
    }

    /// Everything above, plus this Mac's own plan for the entry.
    public init(
        entry: ModelEntry, recommendation: AutoConfigurator.Recommendation, isInstalled: Bool
    ) {
        self.init(
            id: entry.id,
            name: entry.name,
            family: Self.family(of: entry),
            parameters: entry.parameterLabel
                + (entry.activeParameterLabel.map { " (\($0))" } ?? ""),
            capabilities: Self.traits(of: entry),
            contextLength: recommendation.configuration.contextLength,
            maxContext: entry.maxContext,
            quantization: recommendation.quantization.rawValue,
            tokensPerSecond: recommendation.speed.generationTokensPerSecond,
            rating: entry.rating,
            isInstalled: isInstalled,
            isFeatured: entry.isFeatured
        )
    }
}
