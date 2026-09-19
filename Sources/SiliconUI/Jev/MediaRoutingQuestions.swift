import Foundation
import SiliconCatalog
import SiliconControl
import SiliconCore
import SiliconRuntime

// MARK: - What is being asked for

/// The three media lanes a request can land in.
///
/// `mesh` is here because the policy is written once for all three, not because anything
/// routes a mesh today: `ControlAPI.MeshRequest` carries an image path and no prompt, and a
/// router whose whole job is to read a prompt has nothing to read. See the note on
/// `AppModel.generateMesh` in `AppModel+MediaRouting.swift`.
public enum MediaKind: String, Sendable, Equatable, CaseIterable {
    case video, image, mesh

    /// Written for the model, not for a developer: it goes into the state verbatim.
    var promptNoun: String {
        switch self {
        case .video: "a short video clip"
        case .image: "a still image"
        case .mesh: "a 3D model"
        }
    }

    /// Whether a clip length is part of the answer at all. Only video has one.
    var hasDuration: Bool { self == .video }
}

/// How much work the render should be given.
public enum MediaDetailLevel: Int, Sendable, Equatable, CaseIterable {
    case draft = 0
    case standard = 1
    case maximum = 2
}

// MARK: - Candidates

/// One model the router may choose, with its traits already worked out in code.
///
/// Nothing here is inferred by Jev. The catalog, the swarm poll and the installer answer
/// every one of these, and they are handed over as facts so the model is left with the one
/// judgment it is actually good at: which of these suits what the prompt describes.
public struct MediaCandidate: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    /// What the catalog says this model is for, verbatim.
    public var goodAt: String
    /// Clip lengths the lane can serve. Empty for kinds that have no duration.
    public var supportedSeconds: [Int]
    /// The largest size the lane advertises, as the catalog writes it ("720p").
    public var maxResolution: String?
    /// Whether this lane allows nudity and sexual content.
    public var isUncensored: Bool
    /// Where the job would run, as a category rather than a machine: "this Mac" or "a
    /// paired machine". Never a node's name — the question tells the model to ignore how
    /// fast and how available a lane is, so a name it could recognise is a distractor, and
    /// a machine name is the owner's, not something to hand to a third party.
    public var runsOn: String
    /// Whether something can run it right now — a reachable node advertising it, or the
    /// weights installed here.
    public var isReady: Bool
    /// The honest wall-clock expectation, when one is known.
    public var typicalRenderTime: String?
    /// Whether the lane takes a per-clip turbo/full sampling choice (H3 on a node that
    /// advertises `h3_turbo`).
    public var supportsSamplingChoice: Bool
    /// Whether the lane takes an explicit denoising-step count (`h3_steps`).
    public var supportsStepCount: Bool
    /// The step count a normal render uses, for the kinds whose detail control is steps.
    public var defaultSteps: Int?

    public init(
        id: String, name: String, goodAt: String, supportedSeconds: [Int] = [],
        maxResolution: String? = nil, isUncensored: Bool = false, runsOn: String,
        isReady: Bool, typicalRenderTime: String? = nil,
        supportsSamplingChoice: Bool = false, supportsStepCount: Bool = false,
        defaultSteps: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.goodAt = goodAt
        self.supportedSeconds = supportedSeconds
        self.maxResolution = maxResolution
        self.isUncensored = isUncensored
        self.runsOn = runsOn
        self.isReady = isReady
        self.typicalRenderTime = typicalRenderTime
        self.supportsSamplingChoice = supportsSamplingChoice
        self.supportsStepCount = supportsStepCount
        self.defaultSteps = defaultSteps
    }

    /// The nearest length this lane can actually render.
    public func nearestSeconds(to target: Int) -> Int? {
        supportedSeconds.min { abs($0 - target) < abs($1 - target) }
    }

    /// Whether this lane can serve the asked-for length closely enough to count.
    ///
    /// Every lane has *some* nearest length, so "supports it" has to mean "close enough":
    /// asking for fifteen seconds and being handed five is not a near miss, it is a
    /// different shot. Two seconds of slack lets 8 stand in for 9 and stops 5 standing in
    /// for 15.
    public func supports(seconds target: Int) -> Bool {
        guard let nearest = nearestSeconds(to: target) else { return false }
        return abs(nearest - target) <= MediaRoutingThresholds.secondsTolerance
    }
}

extension MediaCandidate {

    /// A video model, with what the swarm poll knows about it folded in.
    public static func video(
        _ entry: VideoEntry, node: String?, capabilityParameters: [String] = []
    ) -> MediaCandidate {
        MediaCandidate(
            id: entry.id,
            name: entry.name,
            goodAt: entry.summary,
            supportedSeconds: entry.supportedSeconds,
            maxResolution: Self.largestResolution(in: entry.outputs),
            isUncensored: Self.isUncensoredVideo(entry),
            runsOn: MediaCandidate.pairedMachine,
            isReady: node != nil,
            typicalRenderTime: entry.typicalDuration,
            supportsSamplingChoice: capabilityParameters.contains("h3_turbo"),
            supportsStepCount: capabilityParameters.contains("h3_steps")
        )
    }

    /// A diffusion model. `runsOn` is the app's own routing answer — a node when one is
    /// offering images, this Mac when MFLUX is doing it — because that is what decides how
    /// long the render takes and the router should see the same machine the job will.
    public static func image(
        _ entry: DiffusionEntry, installed: Bool, runsOn: String
    ) -> MediaCandidate {
        MediaCandidate(
            id: entry.id,
            name: entry.name,
            goodAt: entry.summary.replacingOccurrences(of: "\n", with: " "),
            maxResolution: "\(entry.shape.nativeResolution)px native",
            // No diffusion entry in this catalog is an uncensored lane; the field stays
            // false rather than being guessed from a licence.
            isUncensored: false,
            runsOn: runsOn,
            isReady: installed,
            supportsStepCount: true,
            defaultSteps: entry.shape.defaultSteps
        )
    }

    /// The two places a media job can run, said the same way every time.
    public static let thisMac = "this Mac"
    public static let pairedMachine = "a paired machine"

    /// Video entries do not carry an "uncensored" flag, so it is derived — from the id the
    /// catalog gives the merge, and from the phrase its summary uses. Both, rather than
    /// either, so a future entry that only says it in prose is still caught and one that
    /// only says it in its id is too.
    static func isUncensoredVideo(_ entry: VideoEntry) -> Bool {
        if entry.id.localizedCaseInsensitiveContains("uncensored") { return true }
        return entry.summary.localizedCaseInsensitiveContains("adult content allowed")
    }

    /// The largest `NNNp` in a catalog `outputs` line — "MP4, 480p–1080p" is 1080p.
    static func largestResolution(in outputs: String) -> String? {
        var best: Int?
        var digits = ""
        for character in outputs {
            if character.isNumber {
                digits.append(character)
                continue
            }
            if character == "p", let value = Int(digits), (100...8640).contains(value) {
                best = max(best ?? 0, value)
            }
            digits = ""
        }
        return best.map { "\($0)p" }
    }
}

// MARK: - Thresholds

/// Every number the policy reads, in one place, each with the reason it is that number.
///
/// TypeSafe's advice is that a threshold is not one number: it depends on what happens when
/// the answer is wrong. Nothing here deletes anything — the worst case is a clip rendered by
/// the wrong model, which costs GPU minutes — so the bars are moderate. The one exception is
/// `adultContent`, which gates a lane, and is stated in the feature brief rather than tuned.
public enum MediaRoutingThresholds {

    /// The `model` choice's two-way gate. At or above `act`, take Jev's pick. Between the
    /// two, take its pick but prefer one that can actually run right now. Below `confirm`,
    /// keep the user's own default and say Jev was unsure.
    ///
    /// This is a *choice* confidence, which is how concentrated the distribution over the
    /// lanes is. It is never applied to a noul: a noul carries no confidence, and 0.5 on one
    /// means "as likely as not", not "medium".
    public static let model = JevThresholds(act: 0.55, confirm: 0.3)

    /// At or above this, a prompt counts as asking for adult content: the uncensored lane is
    /// the only one allowed to take it. The figure is the feature's, not a tuned one.
    public static let adultContentYes = 0.6

    /// At or below this, a prompt counts as plainly not asking for adult content, and the
    /// uncensored lanes are vetoed. Between the two the answer is "as likely as not", which
    /// is a reason to ask rather than to pick a lane that may reject the job.
    public static let adultContentNo = 0.25

    /// Which side of the adult-content gate a prompt falls on, or neither.
    ///
    /// Through `JevThresholds.noulBand` rather than a confidence band, because this is a
    /// noul: the number it returns *is* the answer, so the certain readings are at both ends
    /// and the useless ones are in the middle. A choice-style gate would read 0.05 — a
    /// confident "no, nothing adult here" — as no confidence at all and refuse to route
    /// perfectly ordinary prompts.
    public static func adultLane(_ probability: Double) -> AdultVerdict {
        guard JevThresholds.noulBand(probability, yes: adultContentYes, no: adultContentNo)
            == .act
        else { return .unclear }
        return probability >= adultContentYes ? .adult : .ordinary
    }

    public enum AdultVerdict: Sendable, Equatable { case adult, ordinary, unclear }

    /// At or above this, the request names a real person as someone to depict. Combined
    /// with adult content it is a hard stop, so the bar is "more likely than not" rather
    /// than high: the cost of refusing an ordinary prompt is an error message, and the cost
    /// of not refusing is rendering sexual imagery of a named real person.
    public static let namesRealPerson = 0.5

    /// Below this many steps a model is a distilled one — FLUX.1 schnell finishes in four —
    /// and its step count is part of how it was trained, not a quality dial. Halving it
    /// produces mush and doubling it produces the same picture more slowly, so `detail_level`
    /// leaves it alone.
    public static let smallestScalableSteps = 8

    /// A score answer below this confidence is not used; the app's own default stands.
    /// A flat distribution over "a moment / a short clip / a scene / a long take" means the
    /// prompt did not say, and inventing a length from it is worse than keeping the one the
    /// user already chose.
    public static let scoreConfidence = 0.3

    /// How far the nearest supported length may be from the asked-for one.
    public static let secondsTolerance = 2

    // The nouls below only shape the one-line reason and the style presets, never which
    // lane runs. 0.5 is "more likely than not", 0.6 where a phrase would be embarrassing
    // if wrong.
    public static let motionHeavy = 0.5
    public static let stillSubject = 0.25
    public static let depictsPeople = 0.5
    public static let noPeople = 0.25
    public static let violentOrGore = 0.6
    public static let needsLegibleText = 0.6
    public static let photorealistic = 0.6
    public static let stylized = 0.6
    public static let specificSubjectReference = 0.6
}

// MARK: - Questions

/// One prompt read once, and every judgment the media lanes need, asked together.
///
/// The whole policy is in this file on purpose. A question's wording *is* the behaviour —
/// `jev-1.13` answers what you wrote rather than what you meant — and the thresholds above
/// decide what the app does with the answer, so a reviewer can read both in a minute and say
/// whether they are right.
///
/// Every question is asked on every media request, including the ones that cannot matter:
/// `clip_length` means nothing for a still image, and `needs_legible_text` means nothing for
/// most clips. That is TypeSafe's speculative fan-out — questions are answered in parallel,
/// so asking ten costs one request and barely more time than asking three — and the code
/// below simply ignores the answers its lane has no use for.
public enum MediaRoutingQuestions: JevQuestionSet {

    public static let feature: JevFeature = .mediaRouting

    /// The id a caller passes instead of a model when it wants this router to decide.
    public static let autoModelID = "auto"

    /// The escape hatch in the `model` choice. Without one, a request no installed lane
    /// suits comes back as a confident pick of the least-bad option, and the confidence
    /// says nothing is wrong — TypeSafe's own advice is to offer a no-match outcome when
    /// the list might not cover the input. Code maps it to the owner's default and says so.
    public static let noMatchOption = "none_of_these"

    /// Whether a model field is asking to be routed. Nil is the historical "use whatever
    /// the app has selected", and it is treated as auto so an agent that simply omits the
    /// model gets the same behaviour as one that says so.
    public static func isAuto(_ modelID: String?) -> Bool {
        guard let modelID = modelID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !modelID.isEmpty
        else { return true }
        return modelID.caseInsensitiveCompare(autoModelID) == .orderedSame
    }

    /// The questions that do not depend on which models are on offer.
    ///
    /// `JevQuestionSet` asks for a static set, and this is the honest half of it: the
    /// `model` choice is built from the candidates, so the router calls
    /// ``ask(prompt:negativePrompt:kind:candidates:)`` rather than the protocol's default
    /// `ask`, and ``questions(over:)`` is what actually goes on the wire.
    public static let questions: [String: ControlAPI.SystemOneQuestion] = [
        "depicts_people": .init(
            type: "noul",
            instructions: .string(
                "The requested result shows one or more people, or human-like characters."
            ),
            criteria: .object([
                "true": .string("A person, several people, or a human-like character appears."),
                "false": .string(
                    "Only places, objects, animals, text, or abstract imagery — no people."
                ),
            ])
        ),
        "adult_content": .init(
            type: "noul",
            instructions: .string(
                "The request asks for nudity or sexual content."
            ),
            criteria: .object([
                "true": .string(
                    "The request asks for bare breasts, buttocks or genitals, for a sex act, "
                    + "or for an explicitly erotic scene."
                ),
                "false": .string(
                    "Everything else, including swimwear, underwear, romance, kissing, "
                    + "violence, and medical or artistic nudity that the request does not ask to be explicit."
                ),
            ])
        ),
        "violent_or_gore": .init(
            type: "noul",
            instructions: .string(
                "The request asks for graphic violence, injury, blood or gore."
            ),
            criteria: .object([
                "true": .string("Wounds, blood, dismemberment, or an act of violence shown explicitly."),
                "false": .string(
                    "No violence, or violence that is implied, stylised or off-screen rather than shown."
                ),
            ])
        ),
        "needs_legible_text": .init(
            type: "noul",
            instructions: .string(
                "The request asks for specific words, letters or numbers to be readable in the result."
            ),
            criteria: .object([
                "true": .string(
                    "It gives the exact words to render — a sign, a title, a logo, a label, a caption."
                ),
                "false": .string(
                    "No particular text has to be readable, even if writing might appear in the scene."
                ),
            ])
        ),
        "motion_heavy": .init(
            type: "noul",
            instructions: .string(
                "The request describes fast or complicated movement, rather than a mostly still subject."
            ),
            criteria: .object([
                "true": .string(
                    "Running, fighting, dancing, vehicles, crowds, weather, or a moving camera."
                ),
                "false": .string(
                    "A portrait, a landscape, a slow drift, or a subject that mostly holds still."
                ),
            ])
        ),
        "photorealistic": .init(
            type: "noul",
            instructions: .string(
                "The request asks for a photographic or live-action look."
            ),
            criteria: .object([
                "true": .string("It asks for a photo, film, footage, or a real-looking scene."),
                "false": .string("It asks for some other look, or does not say."),
            ])
        ),
        "stylized_or_animated": .init(
            type: "noul",
            instructions: .string(
                "The request asks for an illustrated, animated, painted or otherwise non-photographic look."
            ),
            criteria: .object([
                "true": .string(
                    "It asks for anime, cartoon, 3D render, pixel art, watercolour, comic, or a named art style."
                ),
                "false": .string("It asks for some other look, or does not say."),
            ])
        ),
        "names_real_person": .init(
            type: "noul",
            instructions: .string(
                "The request names a specific real living or historical person as a subject to depict."
            ),
            criteria: .object([
                "true": .string(
                    "It gives the name of a real individual — a politician, an actor, a "
                    + "musician, an athlete, a public figure, or someone the requester knows "
                    + "— as someone who should appear in the result."
                ),
                "false": .string(
                    "Every person is described generically (\"a woman in a red coat\"), is "
                    + "the requester's own invention, or is a fictional character. A real "
                    + "name mentioned as a style reference rather than a subject to depict "
                    + "is also false."
                ),
            ])
        ),
        "names_brand_or_character": .init(
            type: "noul",
            instructions: .string(
                "The request names a real brand, company, product or trademarked character."
            ),
            criteria: .object([
                "true": .string(
                    "A company, a product line, a logo, or a character owned by one — "
                    + "\"a Coca-Cola bottle\", \"Mickey Mouse\", \"a Tesla\"."
                ),
                "false": .string(
                    "Objects and characters are generic: \"a fizzy drink bottle\", \"a cartoon "
                    + "mouse\", \"an electric car\"."
                ),
            ])
        ),
        "clip_length": .init(
            type: "score",
            instructions: .string(
                "How long should the finished clip be, judging only from what the request describes?"
            ),
            criteria: .array([
                .string("A moment: one beat, gesture or glance. About 2 to 3 seconds."),
                .string("A short clip: one continuous action from start to finish. About 5 seconds."),
                .string("A scene: two or three connected actions. About 8 to 10 seconds."),
                .string("A long take: an extended sequence or several shots' worth of action. 15 seconds or more."),
            ])
        ),
        "detail_level": .init(
            type: "score",
            instructions: .string(
                "How much render quality does this request call for?"
            ),
            criteria: .array([
                .string(
                    "A quick draft to check the idea: the request calls it a test, a rough, a "
                    + "sketch or a first look, or asks for it quickly."
                ),
                .string("A normal finished result. The request does not say either way."),
                .string(
                    "The best the model can do: the request calls it final, hero, print, "
                    + "high quality, or says it is going to be shown to someone."
                ),
            ])
        ),
    ]

    /// Derived from the questions rather than written twice, so a question added above is
    /// read back below without anyone remembering to list it.
    public static let noulNames = questions.filter { $0.value.type == "noul" }.keys.sorted()
    public static let scoreNames = questions.filter { $0.value.type == "score" }.keys.sorted()

    /// The fixed questions plus the one that depends on what is on offer.
    ///
    /// The option descriptions carry only what separates one lane from another *in meaning*
    /// — what it is for, and what it is not for. Everything operational (lengths, sizes,
    /// where it runs, whether it is ready) is in the state instead, said once, and acted on
    /// by the policy below. Repeating a fact in both places is how instructions and criteria
    /// come to disagree.
    public static func questions(
        over candidates: [MediaCandidate]
    ) -> [String: ControlAPI.SystemOneQuestion] {
        var all = questions
        guard !candidates.isEmpty else { return all }
        var criteria: [String: JSONContent] = [:]
        criteria[noMatchOption] = .object([
            "name": .string("None of these"),
            "use_when": .string(
                "None of the models above suits this request — it asks for something they "
                + "are all the wrong tool for."
            ),
            "avoid_when": .string("Any of the models above would do a reasonable job."),
        ])
        for candidate in candidates {
            var option: [String: JSONContent] = [
                "name": .string(candidate.name),
                "use_when": .string(
                    candidate.isUncensored
                        ? "The request asks for nudity or sexual content: this lane is the one that allows it."
                        : firstSentence(of: candidate.goodAt)
                ),
            ]
            option["avoid_when"] = .string(
                candidate.isUncensored
                    ? "The request does not ask for nudity or sexual content."
                    : "The request asks for nudity or sexual content."
            )
            criteria[candidate.id] = .object(option)
        }
        all["model"] = .init(
            type: "choice",
            instructions: .object([
                "question": .string("Which of these models should render this request?"),
                "focus": .string(
                    "Judge only how well each model suits what the request describes. Do not "
                    + "consider how long a model takes or whether it is ready; the application "
                    + "decides those itself."
                ),
            ]),
            criteria: .object(criteria)
        )
        return all
    }

    /// The most prompt text this router will send.
    ///
    /// A video prompt may be twelve thousand characters and a batch is many of them, while
    /// the state a Jev call may carry is tens of kilobytes and shrinking. It is also the
    /// wrong trade even when it fits: accuracy falls as a state fills with detail the
    /// question does not need, and the tenth paragraph of a shot list does not change which
    /// lane renders it. The opening is what describes the subject, so the opening is what
    /// goes.
    public static let maximumPromptCharacters = 4_000

    static func trimmed(_ text: String) -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > maximumPromptCharacters else { return clean }
        return String(clean.prefix(maximumPromptCharacters)) + "…"
    }

    /// The state: the request, and the facts about each lane.
    ///
    /// Deliberately small. Accuracy falls as a state fills with detail the question does not
    /// need, so this carries the prompt, the kind, and the candidate traits — not the queue,
    /// not the machine, not what else is loaded.
    /// No negative prompt travels with it, because none exists to send: neither
    /// `ControlAPI.ImageRequest` nor `VideoQueueRequest` carries one, and the composers have
    /// no field for it. A parameter nothing ever fills is a claim the code does not keep.
    public static func state(
        prompt: String, kind: MediaKind, candidates: [MediaCandidate]
    ) -> JSONContent {
        let request: [String: JSONContent] = [
            "wants": .string(kind.promptNoun),
            "prompt": .string(trimmed(prompt)),
        ]
        let listed: [JSONContent] = candidates.map { candidate in
            var fields: [String: JSONContent] = [
                "id": .string(candidate.id),
                "name": .string(candidate.name),
                "good_at": .string(candidate.goodAt),
                "runs_on": .string(candidate.runsOn),
                "allows_adult_content": .bool(candidate.isUncensored),
            ]
            if !candidate.supportedSeconds.isEmpty {
                fields["clip_lengths_seconds"] = .array(
                    candidate.supportedSeconds.map { .number(Double($0)) }
                )
            }
            if let resolution = candidate.maxResolution {
                fields["max_resolution"] = .string(resolution)
            }
            if let time = candidate.typicalRenderTime {
                fields["typical_render_time"] = .string(time)
            }
            return .object(fields)
        }
        return .object(["request": .object(request), "candidates": .array(listed)])
    }

    /// One request to Jev, through the one governed door, with every question at once.
    ///
    /// `using` is the seam a test injects a service pointed at a loopback server through,
    /// so nothing in this feature's tests has to reach for the shared singleton.
    public static func ask(
        prompt: String, kind: MediaKind, candidates: [MediaCandidate],
        using service: JevService = .shared
    ) async throws -> ControlAPI.DecideResponse {
        try await service.ask(
            feature,
            state: state(prompt: prompt, kind: kind, candidates: candidates),
            questions: questions(over: candidates)
        )
    }

    /// The lead sentence of a catalog summary, which is where the catalog puts what the
    /// model is for. Trimmed so one long entry cannot crowd out the others.
    static func firstSentence(of summary: String) -> String {
        let flattened = summary
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let stop = flattened.firstIndex(of: ".") else {
            return String(flattened.prefix(220))
        }
        return String(flattened[...stop].prefix(220))
    }
}

// MARK: - Reading the answers

/// Plain values out of a `DecideResponse`, so the policy is a function of numbers rather
/// than of a wire type — which is what makes it testable without a server.
public struct MediaRoutingAnswers: Sendable, Equatable {
    public var modelChoice: String?
    public var modelConfidence: Double
    public var modelProbabilities: [String: Double]
    public var nouls: [String: Double]
    /// Question id → (expected score, confidence).
    public var scores: [String: (score: Double, confidence: Double)]

    public init(
        modelChoice: String? = nil, modelConfidence: Double = 0,
        modelProbabilities: [String: Double] = [:], nouls: [String: Double] = [:],
        scores: [String: (score: Double, confidence: Double)] = [:]
    ) {
        self.modelChoice = modelChoice
        self.modelConfidence = modelConfidence
        self.modelProbabilities = modelProbabilities
        self.nouls = nouls
        self.scores = scores
    }

    public static func == (lhs: MediaRoutingAnswers, rhs: MediaRoutingAnswers) -> Bool {
        lhs.modelChoice == rhs.modelChoice && lhs.modelConfidence == rhs.modelConfidence
            && lhs.modelProbabilities == rhs.modelProbabilities && lhs.nouls == rhs.nouls
            && lhs.scores.keys == rhs.scores.keys
            && lhs.scores.allSatisfy { rhs.scores[$0.key].map { $0 == $1 } ?? false }
    }

    /// Reads the response question by question, by name and by kind.
    ///
    /// Through the typed accessors rather than by walking `answers`: a question this app
    /// asked and Jev did not answer, or answered as another kind, is a fault worth failing
    /// on, and failing names the question rather than quietly reading as zero. The caller
    /// treats a throw as "Jev could not route this" and does exactly what the app does when
    /// Jev is switched off.
    public init(_ response: ControlAPI.DecideResponse, expectingModel: Bool) throws {
        self.init()
        for name in MediaRoutingQuestions.noulNames {
            nouls[name] = try response.noul(name)
        }
        for name in MediaRoutingQuestions.scoreNames {
            let answer = try response.score(name)
            scores[name] = (answer.score, answer.confidence)
        }
        guard expectingModel else { return }
        let choice = try response.choice("model")
        modelChoice = choice.choice
        modelConfidence = choice.confidence
        modelProbabilities = choice.probabilities
    }

    public func noul(_ name: String) -> Double { nouls[name] ?? 0 }

    /// A score as a level, or nil when the answer was too flat to use.
    ///
    /// Rounded to the nearest level rather than read as a number between two of them:
    /// `jev-1.13`'s score levels are not numerically calibrated, so an expectation is good
    /// for crossing a threshold and bad for interpolating. The level is what the rubric
    /// describes, and the rubric is what was asked.
    public func level(_ name: String, of count: Int) -> Int? {
        guard let answer = scores[name],
              answer.confidence >= MediaRoutingThresholds.scoreConfidence
        else { return nil }
        let rounded = Int(answer.score.rounded())
        return max(0, min(count - 1, rounded))
    }
}

// MARK: - The decision

/// What the router decided, and why, in a form the queue and the UI can both carry.
public struct MediaRoutingDecision: Sendable, Equatable {
    public var modelID: String
    public var modelName: String
    /// The clip length, for video. Nil for the kinds that have none.
    public var seconds: Int?
    /// Denoising steps, for the kinds whose detail control is a step count.
    public var steps: Int?
    /// H3's per-clip sampling choice, when the node advertises it.
    public var h3Turbo: Bool?
    /// H3's explicit step count, when the node advertises it.
    public var h3Steps: Int?
    public var detail: MediaDetailLevel
    /// True when Jev's own pick was too uncertain to use and the user's default stood.
    public var isUnsure: Bool
    /// The one line the queue item and the UI show.
    public var reason: String

    public init(
        modelID: String, modelName: String, seconds: Int? = nil, steps: Int? = nil,
        h3Turbo: Bool? = nil, h3Steps: Int? = nil, detail: MediaDetailLevel = .standard,
        isUnsure: Bool = false, reason: String
    ) {
        self.modelID = modelID
        self.modelName = modelName
        self.seconds = seconds
        self.steps = steps
        self.h3Turbo = h3Turbo
        self.h3Steps = h3Steps
        self.detail = detail
        self.isUnsure = isUnsure
        self.reason = reason
    }
}

/// Two answers, not one: routing something is not always the right outcome.
///
/// There is no `.confirm` case. Every caller here is one that cannot ask — a control route,
/// an MCP tool, a queue button whose whole point is that it returns at once — so a third
/// outcome would have had to collapse into one of these two at every call site anyway, and
/// the one it collapses into is this one. When there is a dialog to show, that is the time
/// to add it back.
public enum MediaRoutingOutcome: Sendable, Equatable {
    /// Send it, with these settings.
    case route(MediaRoutingDecision)
    /// Nothing was queued, and this says why in a sentence the caller can act on.
    case refuse(String)
}

/// What the app already knows before Jev is asked.
public struct MediaRoutingDefaults: Sendable, Equatable {
    /// A model the caller named. When this is set the router does not overrule it — an
    /// explicit choice is an instruction, not a suggestion.
    public var explicitModelID: String?
    /// The model the app would have used: the Video tab's selection, or the best-fitting
    /// diffusion entry. Where a low-confidence answer lands.
    public var fallbackModelID: String?
    /// A length the caller named. Honoured like a named model: the router may still pick
    /// the lane, but only from the lanes that can render this.
    public var explicitSeconds: Int?
    /// The length the app would have used when nobody said.
    public var seconds: Int
    /// Whether an adult prompt may be sent to the uncensored lane without asking.
    public var automaticUncensoredLane: Bool

    public init(
        explicitModelID: String? = nil, fallbackModelID: String? = nil,
        explicitSeconds: Int? = nil, seconds: Int = 5,
        automaticUncensoredLane: Bool = true
    ) {
        self.explicitModelID = explicitModelID
        self.fallbackModelID = fallbackModelID
        self.explicitSeconds = explicitSeconds
        self.seconds = seconds
        self.automaticUncensoredLane = automaticUncensoredLane
    }
}

// MARK: - The policy

/// Which lane, how long, and at what settings — decided by code from Jev's answers.
///
/// A pure function on purpose. Everything that can make this decision wrong is visible in
/// its arguments, it can be tested exhaustively without a network, and the rules that matter
/// — the adult-content gate, the duration veto, the low-confidence fallback — are `if`
/// statements a reviewer can read rather than probabilities a reviewer has to trust.
public enum MediaRoutingPolicy {

    public static func choose(
        answers: MediaRoutingAnswers,
        candidates: [MediaCandidate],
        kind: MediaKind,
        defaults: MediaRoutingDefaults
    ) -> MediaRoutingOutcome {

        let verdict = MediaRoutingThresholds.adultLane(answers.noul("adult_content"))

        // 1. The one thing no lane, no setting and no named model buys a way past. Sexual
        //    imagery of a real, named person is not something this app routes, and it is
        //    checked before anything else so that no later branch can reach around it.
        if verdict == .adult,
           answers.noul("names_real_person") >= MediaRoutingThresholds.namesRealPerson {
            return .refuse(
                "Sexual content depicting a named real person is not routed here; nothing "
                + "was queued."
            )
        }

        // 2. A named model is honoured. Jev's answers still shape the length and the
        //    settings, because those are what the caller left open.
        if let explicit = defaults.explicitModelID,
           let candidate = candidates.first(where: { $0.id == explicit }) {
            switch secondsFor(candidate, answers: answers, defaults: defaults, kind: kind) {
            case .refusal(let message):
                return .refuse(message)
            case .length(let seconds):
                return .route(decision(
                    for: candidate, seconds: seconds, answers: answers,
                    isUnsure: false, noMatch: false, prefix: "You chose"
                ))
            }
        }

        guard !candidates.isEmpty else {
            return .refuse("No \(kind.rawValue) model is available to route this to.")
        }

        // 3. The adult-content gate, both ways. An adult prompt goes to an uncensored lane
        //    that something can actually run, or nowhere; anything else never goes to one.
        //    "Installed" is part of the gate rather than a preference, because a lane no
        //    machine offers is not a destination — routing to it queues an adult prompt
        //    against a dead model and tells nobody.
        let uncensored = candidates.filter { $0.isUncensored && $0.isReady }
        let ordinary = candidates.filter { !$0.isUncensored }
        let adult = verdict == .adult
        let pool = adult ? uncensored : ordinary

        if pool.isEmpty {
            return .refuse(adult
                ? "This prompt asks for adult content and no uncensored lane is installed "
                    + "and ready. Set one up on a node, or name a model id explicitly if you "
                    + "believe the prompt was read wrongly."
                : "The only lanes available here are uncensored ones, and this prompt does "
                    + "not ask for adult content. Name a model id explicitly to use one anyway.")
        }

        if !adult, !defaults.automaticUncensoredLane, verdict == .unclear {
            // The owner has said adult prompts are their call, and this one might be. Fall
            // through rather than route it on a maybe.
            return .refuse(unclearMessage(allowUncensored: false))
        }

        // 4. The owner may have asked to be consulted before an adult prompt is routed, and
        //    there is nobody here to consult.
        if adult, !defaults.automaticUncensoredLane {
            return .refuse(
                "This prompt reads as adult content. Automatic routing to the uncensored "
                + "lane is switched off, so nothing was queued: allow it in Settings → "
                + "TypeSafe (Jev), or name a model id explicitly."
            )
        }

        // 5. Neither side of the gate. Ask, rather than pick a lane that may reject the job.
        if verdict == .unclear {
            return .refuse(unclearMessage(allowUncensored: true))
        }

        // 6. The duration veto. A lane that cannot serve the asked-for length is not a
        //    candidate for it, however well it suits the subject.
        var eligible = pool
        var clampedLength = false
        if kind.hasDuration {
            if let named = defaults.explicitSeconds {
                // A named length is honoured exactly or refused — never quietly rounded to
                // something else, which is how someone asking for fifteen seconds ends up
                // paying for five.
                let fits = pool.filter { $0.supportedSeconds.contains(named) }
                guard !fits.isEmpty else {
                    let lengths = Set(pool.flatMap(\.supportedSeconds)).sorted()
                        .map(String.init).joined(separator: ", ")
                    return .refuse(
                        "No available model renders a \(named) second clip. These lengths "
                        + "exist: \(lengths) seconds."
                    )
                }
                eligible = fits
            } else {
                let target = targetSeconds(answers: answers, defaults: defaults, kind: kind)
                let fits = pool.filter { $0.supports(seconds: target) }
                if fits.isEmpty {
                    // Nothing can do the length the prompt implied. Better a clip of the
                    // nearest length from a model that suits the subject than a refusal
                    // nobody asked for; the reason says the length moved.
                    clampedLength = true
                } else {
                    eligible = fits
                }
            }
        }

        // 7. Which of the survivors. Jev's pick when it is confident, the user's own default
        //    when it is not, and in every band a lane something can run is preferred over
        //    one nothing can — queueing against a model no machine offers is how a batch
        //    sits overnight doing nothing.
        let noMatch = answers.modelChoice == MediaRoutingQuestions.noMatchOption
        let band = MediaRoutingThresholds.model.band(answers.modelConfidence)
        let fallback = eligible.first { $0.id == defaults.fallbackModelID }
        let picked: MediaCandidate
        var isUnsure = false
        if noMatch, band != .escalate {
            // Jev says none of these is right. Its second choice is not an answer to that,
            // so the owner's own default is.
            picked = fallback ?? preferReady(eligible, answers: answers) ?? eligible[0]
        } else {
            switch band {
            case .act, .confirm:
                let ready = eligible.filter(\.isReady)
                picked = (ready.first { $0.id == answers.modelChoice })
                    ?? preferReady(eligible, answers: answers)
                    ?? (eligible.first { $0.id == answers.modelChoice })
                    ?? mostLikely(in: eligible, answers: answers)
                    ?? eligible[0]
            case .escalate:
                isUnsure = true
                picked = fallback
                    ?? preferReady(eligible, answers: answers)
                    ?? mostLikely(in: eligible, answers: answers)
                    ?? eligible[0]
            }
        }

        let seconds: Int?
        switch secondsFor(picked, answers: answers, defaults: defaults, kind: kind) {
        case .refusal(let message): return .refuse(message)
        case .length(let value): seconds = value
        }
        var chosen = decision(
            for: picked, seconds: seconds, answers: answers, isUnsure: isUnsure,
            noMatch: noMatch, prefix: "Auto →"
        )
        if clampedLength, let seconds {
            let target = targetSeconds(answers: answers, defaults: defaults, kind: kind)
            chosen.reason += " (no lane renders \(target) s; \(seconds) s is the closest)"
        }
        return .route(chosen)
    }

    /// Written once because three branches say it and a caller acts on the words.
    static func unclearMessage(allowUncensored: Bool) -> String {
        "Jev could not tell whether this prompt asks for adult content, so no model was "
        + "chosen and nothing was queued. Say explicitly in the prompt whether this is adult "
        + "content, or name a model id."
        + (allowUncensored ? "" : " Automatic routing to the uncensored lane is switched off.")
    }

    /// The most likely lane among the ones something can run right now, or nil when none of
    /// them can. Separate from `mostLikely` so "prefer ready" is one idea in one place
    /// rather than three copies of a `filter` that drift.
    static func preferReady(
        _ candidates: [MediaCandidate], answers: MediaRoutingAnswers
    ) -> MediaCandidate? {
        mostLikely(in: candidates.filter(\.isReady), answers: answers)
    }

    // MARK: Pieces

    /// Nil for an empty list rather than a crash or a silent first element: "none of these"
    /// is a real answer at this level and the caller has to decide what to do about it.
    static func mostLikely(
        in candidates: [MediaCandidate], answers: MediaRoutingAnswers
    ) -> MediaCandidate? {
        // Ties break on catalog order, which is the app's own preference order, so the same
        // answers always produce the same lane.
        candidates.max {
            (answers.modelProbabilities[$0.id] ?? 0) < (answers.modelProbabilities[$1.id] ?? 0)
        }
    }

    /// The length the request asks for, before any lane is consulted.
    ///
    /// A length the caller named wins outright — the same rule as a named model, for the
    /// same reason. Otherwise the rubric, and if the rubric's answer was too flat to use,
    /// whatever the app already had.
    static func targetSeconds(
        answers: MediaRoutingAnswers, defaults: MediaRoutingDefaults, kind: MediaKind
    ) -> Int {
        guard kind.hasDuration else { return defaults.seconds }
        if let named = defaults.explicitSeconds { return named }
        guard let level = answers.level("clip_length", of: clipLengthSeconds.count)
        else { return defaults.seconds }
        return clipLengthSeconds[level]
    }

    /// One length per level of the `clip_length` rubric, chosen to sit on — or between — the
    /// lengths the catalog actually serves, which across every video entry are 3, 5, 8, 10
    /// and 15 seconds. Level 2 is 9 because its rubric says "about 8 to 10": the nearest
    /// supported length then resolves to whichever of the two a lane offers.
    public static let clipLengthSeconds = [3, 5, 9, 15]

    /// The length this lane will actually render, or the refusal that says why it cannot.
    ///
    /// A length the caller named is exact or nothing. Everything else snaps to the nearest
    /// the lane serves, which is what the picker has always done with a stale selection.
    static func secondsFor(
        _ candidate: MediaCandidate, answers: MediaRoutingAnswers,
        defaults: MediaRoutingDefaults, kind: MediaKind
    ) -> ResolvedSeconds {
        guard kind.hasDuration else { return .length(nil) }
        if let named = defaults.explicitSeconds {
            guard candidate.supportedSeconds.contains(named) else {
                let lengths = candidate.supportedSeconds.map(String.init).joined(separator: ", ")
                return .refusal(
                    "\(candidate.id) does not render a \(named) second clip. It supports "
                    + "these lengths: \(lengths) seconds."
                )
            }
            return .length(named)
        }
        let target = targetSeconds(answers: answers, defaults: defaults, kind: kind)
        return .length(candidate.nearestSeconds(to: target) ?? defaults.seconds)
    }

    /// A length, or the sentence explaining why there is not one.
    enum ResolvedSeconds: Equatable {
        case length(Int?)
        case refusal(String)
    }

    static func detailLevel(_ answers: MediaRoutingAnswers) -> MediaDetailLevel {
        guard let level = answers.level("detail_level", of: MediaDetailLevel.allCases.count)
        else { return .standard }
        return MediaDetailLevel(rawValue: level) ?? .standard
    }

    /// The lane's own quality control, set from `detail_level`.
    ///
    /// Video has one knob and only on H3, and only when the node says it has it: turbo for a
    /// draft, the full schedule with more sigma points for a final. Every other video lane
    /// has no per-clip control at all, so the renderer default stands rather than an
    /// invented parameter being sent to a node that would refuse it. For images the control
    /// is denoising steps, around whatever the entry calls normal.
    static func settings(
        for candidate: MediaCandidate, detail: MediaDetailLevel
    ) -> (steps: Int?, h3Turbo: Bool?, h3Steps: Int?) {
        if let defaultSteps = candidate.defaultSteps, candidate.supportsStepCount,
           !candidate.supportsSamplingChoice {
            // A distilled model's step count is not a quality dial. FLUX.1 schnell finishes
            // in four steps because it was trained to; two produces mush and eight produces
            // the same picture twice as slowly. Scaling only applies where there is a real
            // range to move along.
            guard defaultSteps > MediaRoutingThresholds.smallestScalableSteps else {
                return (defaultSteps, nil, nil)
            }
            let steps: Int
            switch detail {
            case .draft: steps = max(1, Int((Double(defaultSteps) * 0.5).rounded()))
            case .standard: steps = defaultSteps
            case .maximum: steps = min(200, defaultSteps * 2)
            }
            return (steps, nil, nil)
        }
        guard candidate.supportsSamplingChoice else { return (nil, nil, nil) }
        switch detail {
        case .draft:
            return (nil, true, nil)
        case .standard:
            return (nil, nil, nil)
        case .maximum:
            // `h3_steps` is only legal alongside full sampling, and only from 4 to 30.
            return (nil, false, candidate.supportsStepCount ? 20 : nil)
        }
    }

    static func decision(
        for candidate: MediaCandidate, seconds: Int?, answers: MediaRoutingAnswers,
        isUnsure: Bool, noMatch: Bool, prefix: String
    ) -> MediaRoutingDecision {
        let detail = detailLevel(answers)
        let applied = settings(for: candidate, detail: detail)
        return MediaRoutingDecision(
            modelID: candidate.id,
            modelName: candidate.name,
            seconds: seconds,
            steps: applied.steps,
            h3Turbo: applied.h3Turbo,
            h3Steps: applied.h3Steps,
            detail: detail,
            isUnsure: isUnsure,
            reason: reason(
                prefix: prefix, candidate: candidate, seconds: seconds,
                answers: answers, detail: detail, isUnsure: isUnsure, noMatch: noMatch
            )
        )
    }

    /// "Auto → LTX 2.3 (5 s): motion-heavy, no people".
    ///
    /// Assembled in code from the same numbers the policy read, in a fixed order, so the
    /// line is a record of the decision rather than a second opinion about it.
    static func reason(
        prefix: String, candidate: MediaCandidate, seconds: Int?,
        answers: MediaRoutingAnswers, detail: MediaDetailLevel, isUnsure: Bool,
        noMatch: Bool
    ) -> String {
        var head = "\(prefix) \(candidate.name)"
        if let seconds { head += " (\(seconds) s)" }
        var clauses: [String] = []
        if noMatch { clauses.append("no installed model fits, kept your default") }
        if isUnsure { clauses.append("Jev unsure, kept your default") }
        if MediaRoutingThresholds.adultLane(answers.noul("adult_content")) == .adult {
            clauses.append("adult content")
        }
        if answers.noul("motion_heavy") >= MediaRoutingThresholds.motionHeavy {
            clauses.append("motion-heavy")
        } else if answers.noul("motion_heavy") < MediaRoutingThresholds.stillSubject {
            clauses.append("still subject")
        }
        if answers.noul("depicts_people") >= MediaRoutingThresholds.depictsPeople {
            clauses.append("people")
        } else if answers.noul("depicts_people") < MediaRoutingThresholds.noPeople {
            clauses.append("no people")
        }
        if answers.noul("violent_or_gore") >= MediaRoutingThresholds.violentOrGore {
            clauses.append("graphic violence")
        }
        if answers.noul("needs_legible_text") >= MediaRoutingThresholds.needsLegibleText {
            clauses.append("legible text")
        }
        if answers.noul("names_brand_or_character")
            >= MediaRoutingThresholds.specificSubjectReference {
            clauses.append("named brand")
        }
        if answers.noul("photorealistic") >= MediaRoutingThresholds.photorealistic {
            clauses.append("photoreal")
        } else if answers.noul("stylized_or_animated") >= MediaRoutingThresholds.stylized {
            clauses.append("stylised")
        }
        switch detail {
        case .draft: clauses.append("draft quality")
        case .standard: break
        case .maximum: clauses.append("maximum quality")
        }
        if clauses.isEmpty { clauses = ["best fit for this prompt"] }
        return "\(head): \(clauses.prefix(5).joined(separator: ", "))"
    }
}

// MARK: - Where the owner's choices live

// They used to live here, in `UserDefaults`. They live in `JevSettings` now — see
// `automaticUncensoredLane` and `composerAutoRoute` in `JevService.swift`.
//
// Two reasons. `GET /jev` and a paired phone can see and set them there, and could not see
// a `UserDefaults` key at all. And "default on when an uncensored lane is installed" has to
// be a question asked every time rather than a value written the first time a settings
// window is drawn: a Mac that installs a lane next week should get the sensible answer
// without anyone having opened Settings, and one that never had a lane should not be
// carrying a stale yes.
