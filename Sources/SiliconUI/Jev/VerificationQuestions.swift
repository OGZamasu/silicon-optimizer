import Foundation
import SiliconControl
import SiliconRuntime

/// What Jev is asked about a finished local answer, and what this app does with the answer.
///
/// One file, by the convention in `JevQuestionSet`: the wording of a question *is* the
/// behaviour — `jev-1.13` answers what you wrote, not what you meant — and the thresholds
/// decide what happens next. Split across three files they drift; here a reviewer reads the
/// whole policy in a minute.
///
/// The shape is TypeSafe's SDE cascade (`cookbooks/sde_cascade`): a cheap rung produces an
/// answer, a battery of narrow nouls looks for the specific ways it goes wrong, and a
/// stronger rung is paid for only when one of them fires. The rungs here are "the model
/// loaded on this Mac" and "a stronger model on the gateway" rather than two OpenAI tiers,
/// but the algorithm and the reason for it are the same.
enum VerificationQuestions: JevQuestionSet {

    static let feature = JevFeature.verification

    /// The order reasons are reported in, so two runs of the same verdict read the same.
    static let order = [
        "answers_the_question", "claims_unavailable_information", "contradicts_context",
        "follows_requested_format", "is_cut_off", "refuses_or_deflects", "answer_quality",
    ]

    static let questions: [String: ControlAPI.SystemOneQuestion] = [

        // Phrased so a high number is a good answer, per the noul page's advice, and named
        // for the statement rather than for the failure — `answers_the_question` at 0.02 is
        // a confident "no it does not", which is exactly the reading the policy wants.
        "answers_the_question": .init(
            type: "noul",
            instructions: .string(
                "The text in `reply` addresses what `message` asks for."
            ),
            criteria: .object([
                "true": .string(
                    "`reply` responds to the request in `message` — it answers the question "
                    + "asked, or does the task asked for."
                ),
                "false": .string(
                    "`reply` is about something else, restates the question without "
                    + "answering it, or answers a different question."
                ),
            ])
        ),

        // The fabrication head. Deliberately literal about where the facts would have to
        // come from: the cascade cookbook's per-field "is this absent from the source?"
        // question, asked once over the whole reply because a chat answer has no fields.
        "claims_unavailable_information": .init(
            type: "noul",
            instructions: .string(
                "`reply` states specific facts about a document, a file, a tool result, a "
                + "search result or an image, and those facts do not appear anywhere in "
                + "`message`, `context` or `system_prompt`."
            ),
            criteria: .object([
                "true": .string(
                    "`reply` reports what some document, tool or image says, quotes it, or "
                    + "gives figures from it, and that material is not in the state above. "
                    + "`context` saying only that an image was attached does not make the "
                    + "image's contents available."
                ),
                "false": .string(
                    "Everything `reply` attributes to a document, tool or image is present "
                    + "in the state above, or `reply` makes no such claim at all — general "
                    + "knowledge, opinion and reasoning are not claims about a source. Also "
                    + "false when `withheld` says the material was left out of this state: "
                    + "the model that wrote `reply` could see it even though you cannot."
                ),
            ])
        ),

        "contradicts_context": .init(
            type: "noul",
            instructions: .string(
                "`reply` states something that contradicts `context`."
            ),
            criteria: .object([
                "true": .string(
                    "At least one statement in `reply` cannot be true if `context` is true."
                ),
                "false": .string(
                    "Nothing in `reply` conflicts with `context`, or there is no `context`. "
                    + "Going beyond `context` is not the same as contradicting it."
                ),
            ])
        ),

        // Two judgments would hide in "does it follow the format?" — was one asked for, and
        // was it used. `jev-1.13` reads instructions literally, so the "none asked for" case
        // is written into both halves rather than left to interpretation, and both halves
        // point the same way (the jaggedness note on contradictory criteria).
        "follows_requested_format": .init(
            type: "noul",
            instructions: .string(
                "`reply` is in the output format `message` asks for. This is also true when "
                + "`message` asks for no particular format."
            ),
            criteria: .object([
                "true": .string(
                    "`message` names a format — JSON, a table, bullet points, a word or line "
                    + "limit, a language — and `reply` is in it; or `message` names no format."
                ),
                "false": .string(
                    "`message` names a format and `reply` is not in it."
                ),
            ])
        ),

        // Whether it *reads* as unfinished. Whether the token budget ran out is a fact the
        // runtime reported, and `VerificationPolicy` supplies it; asking the model for it
        // would be asking it to guess at something code already knows.
        "is_cut_off": .init(
            type: "noul",
            instructions: .string(
                "`reply` ends mid-thought: its last sentence is unfinished, or it breaks off "
                + "before finishing what it had started saying."
            ),
            criteria: .object([
                "true": .string(
                    "The text stops in the middle of a word, a sentence, a list item, a code "
                    + "block or an argument it was in the middle of making."
                ),
                "false": .string(
                    "The text reaches an ending — a finished sentence, a closing remark, a "
                    + "complete list. A short answer is not a cut-off one."
                ),
            ])
        ),

        "refuses_or_deflects": .init(
            type: "noul",
            instructions: .string(
                "`reply` declines to do what `message` asks, or deflects it, instead of "
                + "attempting it."
            ),
            criteria: .object([
                "true": .string(
                    "`reply` says it will not or cannot do the thing, redirects the reader "
                    + "elsewhere, or answers with a disclaimer in place of an answer."
                ),
                "false": .string(
                    "`reply` attempts the request. Attempting it and noting a caveat, or "
                    + "asking one clarifying question before answering, is not a refusal."
                ),
            ])
        ),

        // A score rather than a seventh noul because "good enough to send" is a position on
        // a spectrum, and because a score carries a confidence — which is what lets the
        // policy tell "this is bad" from "I cannot tell".
        "answer_quality": .init(
            type: "score",
            instructions: .string(
                "Rate `reply` as an answer to `message`."
            ),
            criteria: .array([
                .string(
                    "Unusable: wrong, empty, incoherent, or about something else entirely. "
                    + "Whoever asked is no better off than before."
                ),
                .string(
                    "Acceptable: answers the question, but thinly — vague, partial, or "
                    + "missing something `message` explicitly asked for."
                ),
                .string(
                    "Good: answers what was asked, completely enough to act on, with nothing "
                    + "obviously wrong in it."
                ),
            ])
        ),
    ]

    // MARK: - State

    /// The longest message this app sends, in UTF-8 bytes.
    ///
    /// A pasted document arrives as the message, and the question a pasted document ends
    /// with is at the end of it — so the same head-and-tail treatment the reply gets, for
    /// the same reason: the state must not grow past the point where `jev-1.13` starts
    /// losing the question in the bulk around it.
    static let maximumMessageBytes = 4 * 1024
    /// The longest reply this app sends to be judged, in UTF-8 bytes.
    ///
    /// A chat answer can be tens of kilobytes and `jev-1.13` loses accuracy to irrelevant
    /// bulk (the jaggedness note on large states), so a long reply is sent head and tail
    /// with the middle elided. The two ends are where the failures this asks about live: a
    /// reply opens by addressing the question or not, and ends mid-thought or not.
    static let maximumReplyBytes = 6 * 1024
    /// A system prompt longer than this is omitted rather than sent. Past a few hundred
    /// words it is a persona document, not context for "does this answer the question",
    /// and it would crowd out the parts that are.
    static let maximumSystemPromptBytes = 2 * 1024
    static let maximumContextBytes = 8 * 1024

    /// The state, and whether anything the questions ask about was left out of it.
    ///
    /// The flag is the important half. `claims_unavailable_information` asks whether the
    /// reply describes a source that is not in this state — and if this state is a filtered
    /// copy of what the model actually saw, "not here" and "never existed" look identical
    /// from inside it. So the state says in words what was withheld, and the policy refuses
    /// to escalate on that head when anything was.
    struct BuiltState: Sendable {
        var content: JSONContent
        /// True when the system prompt was dropped, or the context was elided — the two
        /// places evidence for the reply could have been and now is not.
        var evidenceIncomplete: Bool
    }

    /// Nothing else about the Mac goes in: not the model's name, not its settings, not what
    /// else is loaded. None of the questions ask about any of it, and unrelated material in
    /// the state costs accuracy.
    static func state(
        message: String, systemPrompt: String?, reply: String, context: String?
    ) -> BuiltState {
        var fields: [String: JSONContent] = [
            "message": .string(trimmed(message, toBytes: maximumMessageBytes)),
            "reply": .string(trimmed(reply, toBytes: maximumReplyBytes)),
        ]
        var withheld: [String] = []

        let prompt = systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !prompt.isEmpty {
            if systemPrompt!.utf8.count <= maximumSystemPromptBytes {
                // Omitted rather than sent empty: an empty string is still a key the model
                // reads and has to decide means nothing.
                fields["system_prompt"] = .string(systemPrompt!)
            } else {
                withheld.append(
                    "The system prompt was too long to include here. The model that wrote "
                    + "`reply` could see it."
                )
            }
        }

        if let context, !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let cut = trimmed(context, toBytes: maximumContextBytes)
            fields["context"] = .string(cut)
            if cut != context {
                withheld.append(
                    "The middle of `context` was removed to keep this short. The model that "
                    + "wrote `reply` could see all of it."
                )
            }
        }

        if !withheld.isEmpty { fields["withheld"] = .string(withheld.joined(separator: " ")) }
        return BuiltState(content: .object(fields), evidenceIncomplete: !withheld.isEmpty)
    }

    /// Head and tail, with a marked gap. Cutting at character boundaries rather than bytes
    /// so the result is still valid text; the byte budget is the ceiling, not the target.
    static func trimmed(_ text: String, toBytes limit: Int) -> String {
        guard text.utf8.count > limit else { return text }
        let half = max(limit / 2, 1)
        let head = prefix(of: text, bytes: half)
        let tail = suffix(of: text, bytes: limit - half)
        return head + "\n\n […] \n\n" + tail
    }

    private static func prefix(of text: String, bytes: Int) -> String {
        var out = ""
        var used = 0
        for character in text {
            let size = String(character).utf8.count
            if used + size > bytes { break }
            out.append(character)
            used += size
        }
        return out
    }

    private static func suffix(of text: String, bytes: Int) -> String {
        var out = ""
        var used = 0
        for character in text.reversed() {
            let size = String(character).utf8.count
            if used + size > bytes { break }
            out.insert(character, at: out.startIndex)
            used += size
        }
        return out
    }

    /// What a request's other messages and attachments look like to these questions.
    ///
    /// Images are named, never sent: `POST /decide` carries text and JSON, Jev reads text
    /// and JSON, and a base64 PNG in the state would be tens of kilobytes of noise that
    /// answers nothing. Saying "an image was attached" is the honest version — and the
    /// `claims_unavailable_information` criteria say in so many words that it does not make
    /// the image's contents available, so a reply describing the picture is flagged rather
    /// than waved through.
    static func context(
        priorTurns: [(role: String, content: String)], imageCount: Int, attachments: [String] = []
    ) -> String? {
        var parts: [String] = []
        for turn in priorTurns {
            let text = turn.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            parts.append("\(turn.role): \(text)")
        }
        parts.append(contentsOf: attachments.filter { !$0.isEmpty })
        if imageCount == 1 {
            parts.append("An image was attached. Its contents are not included here.")
        } else if imageCount > 1 {
            parts.append(
                "\(imageCount) images were attached. Their contents are not included here."
            )
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }
}

// MARK: - The answers, as numbers

/// Jev's seven answers, read once through the typed accessors so a misspelled id or a
/// changed question kind fails by name here rather than silently skipping a rule.
///
/// A struct rather than the raw `DecideResponse` so the policy below is a pure function of
/// numbers: every rule in it can be exercised without a server, a key or a response body.
struct VerificationAnswers: Sendable, Equatable {
    var answersTheQuestion: Double
    var claimsUnavailableInformation: Double
    var contradictsContext: Double
    var followsRequestedFormat: Double
    var isCutOff: Double
    var refusesOrDeflects: Double
    var answerQuality: Double
    var answerQualityConfidence: Double

    init(
        answersTheQuestion: Double, claimsUnavailableInformation: Double,
        contradictsContext: Double, followsRequestedFormat: Double, isCutOff: Double,
        refusesOrDeflects: Double, answerQuality: Double, answerQualityConfidence: Double
    ) {
        self.answersTheQuestion = answersTheQuestion
        self.claimsUnavailableInformation = claimsUnavailableInformation
        self.contradictsContext = contradictsContext
        self.followsRequestedFormat = followsRequestedFormat
        self.isCutOff = isCutOff
        self.refusesOrDeflects = refusesOrDeflects
        self.answerQuality = answerQuality
        self.answerQualityConfidence = answerQualityConfidence
    }

    init(_ response: ControlAPI.DecideResponse) throws {
        let quality = try response.score("answer_quality")
        self.init(
            answersTheQuestion: try response.noul("answers_the_question"),
            claimsUnavailableInformation: try response.noul("claims_unavailable_information"),
            contradictsContext: try response.noul("contradicts_context"),
            followsRequestedFormat: try response.noul("follows_requested_format"),
            isCutOff: try response.noul("is_cut_off"),
            refusesOrDeflects: try response.noul("refuses_or_deflects"),
            answerQuality: quality.score,
            answerQualityConfidence: quality.confidence
        )
    }
}

// MARK: - The policy

/// What the app does about an answer: send it as it stands, pay for a better one, or send it
/// with a note attached.
enum VerificationVerdict: Sendable, Equatable {
    /// Nothing fired. The local answer goes back untouched.
    case accept
    /// Something fired hard enough to be worth another model's time.
    case escalate(reasons: [String])
    /// Something is in the middle band: worth telling the reader about, not worth paying
    /// to redo. A noul at 0.5 is the model saying it cannot tell, and spending money on
    /// "cannot tell" is how a verification feature becomes a bill.
    case annotate(reasons: [String])

    var name: String {
        switch self {
        case .accept: "accept"
        case .escalate: "escalate"
        case .annotate: "annotate"
        }
    }

    var reasons: [String] {
        switch self {
        case .accept: []
        case .escalate(let reasons), .annotate(let reasons): reasons
        }
    }
}

/// The numbers, in one place, with the rule each one gates.
///
/// Two bars per question rather than one, because a noul's certain answers are at *both*
/// ends and its useless ones are in the middle (`JevThresholds.noulBand`, and TypeSafe's
/// Confidence page). Below the low bar and above the high bar the model is telling us
/// something; between them it is telling us it cannot tell, and that band annotates.
enum VerificationPolicy {

    /// `answers_the_question`: at or below this, the reply is not an answer. Escalates.
    static let answersEscalatesAtOrBelow = 0.35
    /// …and below this it is merely doubtful. Annotates.
    static let answersClearsAtOrAbove = 0.7

    /// `claims_unavailable_information`: at or above this, it is describing something it
    /// was never given. Escalates — this is the failure the cascade exists for.
    ///
    /// 0.7 rather than a bare majority, which is the cascade cookbook's own `FIRE_T`. A
    /// noul at 0.55 is the model leaning, not the model finding; escalating on a lean buys
    /// a second answer for every borderline reply and turns the annotate band — which is
    /// where a lean belongs — into decoration. The three escalating heads share the number
    /// deliberately, so there is one bar to argue about rather than three.
    static let unavailableEscalatesAtOrAbove = fireThreshold
    /// …and above this it is worth mentioning. Annotates.
    static let unavailableClearsAtOrBelow = 0.3

    /// `contradicts_context`, on the same two bars and for the same reason.
    static let contradictsEscalatesAtOrAbove = fireThreshold
    static let contradictsClearsAtOrBelow = 0.3

    /// `is_cut_off`: at or above this the text reads as unfinished. Whether that escalates
    /// depends on `wasTruncated`, which is the runtime's word and not the model's.
    static let cutOffFiresAtOrAbove = fireThreshold
    static let cutOffClearsAtOrBelow = 0.3

    /// The bar a per-head "something is wrong" noul has to clear to be worth paying a
    /// stronger model: TypeSafe's SDE cascade uses 0.7 for exactly this decision.
    static let fireThreshold = 0.7

    /// `refuses_or_deflects`: at or above this, say so. Never escalates on its own — a
    /// refusal is often the right answer, and a stronger model is not the cure for one.
    static let refusalFiresAtOrAbove = 0.6

    /// `follows_requested_format`: at or below this, the format asked for was not used.
    /// Annotates: the content may be fine, and re-running rarely fixes formatting.
    static let formatFiresAtOrBelow = 0.35

    /// `answer_quality`: at or below this expected level — nearer "unusable" than
    /// "acceptable" — say so.
    ///
    /// **Annotate only, at every level.** This is the holistic head, and the cascade
    /// cookbook does not gate on its equivalent either: it computes the whole-record judge
    /// and then drives escalation from the per-field battery, because one question that
    /// hides six judgments cannot say *which* of them went wrong. It is worth reporting and
    /// worth reading; it is not worth buying a second answer on its own, and every failure
    /// that is worth buying one for has its own head above.
    static let qualityEscalatesAtOrBelow = 0.5
    static let qualityConfidenceFloor = 0.5
    /// …and below this level it is thin. Annotates.
    static let qualityClearsAtOrAbove = 1.2

    /// The whole policy, as a pure function.
    ///
    /// - Parameters:
    ///   - wasTruncated: whether the token budget, not the model, ended the answer. Read
    ///     from the runtime's `finish_reason` by `GenerationMetrics.wasTruncated(budget:)`
    ///     and passed in. Jev is never asked it: it is a fact this process already has, and
    ///     the one thing a verifier must not do is guess at its own evidence.
    ///   - evidenceIncomplete: whether the state Jev saw was missing something the model
    ///     that wrote the reply could see — a system prompt too long to send, a context
    ///     elided in the middle. When it is, `claims_unavailable_information` cannot
    ///     escalate: from inside a filtered state, "this is not here" and "this was never
    ///     given to anyone" look the same, and paying for a second answer on that
    ///     confusion is the cascade punishing a reply for our own trimming.
    static func verdict(
        _ answers: VerificationAnswers, wasTruncated: Bool, evidenceIncomplete: Bool = false
    ) -> VerificationVerdict {
        var escalations: [(String, String)] = []
        var notes: [(String, String)] = []

        if answers.answersTheQuestion <= answersEscalatesAtOrBelow {
            escalations.append((
                "answers_the_question",
                "The reply does not answer what was asked."
            ))
        } else if answers.answersTheQuestion < answersClearsAtOrAbove {
            notes.append((
                "answers_the_question",
                "It is not clear the reply answers what was asked."
            ))
        }

        if answers.claimsUnavailableInformation >= unavailableEscalatesAtOrAbove,
           !evidenceIncomplete {
            escalations.append((
                "claims_unavailable_information",
                "The reply states things about a document, tool result or image that was "
                + "never provided."
            ))
        } else if answers.claimsUnavailableInformation >= unavailableEscalatesAtOrAbove {
            notes.append((
                "claims_unavailable_information",
                "The reply may be describing a source that was never provided — though part "
                + "of what the model was given was too long to check against."
            ))
        } else if answers.claimsUnavailableInformation > unavailableClearsAtOrBelow {
            notes.append((
                "claims_unavailable_information",
                "The reply may be describing a source that was never provided."
            ))
        }

        if answers.contradictsContext >= contradictsEscalatesAtOrAbove {
            escalations.append((
                "contradicts_context", "The reply contradicts the context it was given."
            ))
        } else if answers.contradictsContext > contradictsClearsAtOrBelow {
            notes.append((
                "contradicts_context",
                "The reply may contradict the context it was given."
            ))
        }

        if answers.followsRequestedFormat <= formatFiresAtOrBelow {
            notes.append((
                "follows_requested_format",
                "The reply is not in the format the message asked for."
            ))
        }

        if answers.isCutOff >= cutOffFiresAtOrAbove {
            if wasTruncated {
                escalations.append((
                    "is_cut_off",
                    "The reply stops mid-thought and the token budget ran out."
                ))
            } else {
                // Reads as unfinished, but every token it wanted was available — so a
                // rerun would produce the same shape and cost money to do it.
                notes.append((
                    "is_cut_off",
                    "The reply reads as unfinished, though the token budget was not spent."
                ))
            }
        } else if answers.isCutOff > cutOffClearsAtOrBelow, wasTruncated {
            notes.append((
                "is_cut_off", "The token budget ran out; the reply may be incomplete."
            ))
        }

        if answers.refusesOrDeflects >= refusalFiresAtOrAbove {
            notes.append((
                "refuses_or_deflects", "The reply declines or deflects the request."
            ))
        }

        if answers.answerQuality <= qualityEscalatesAtOrBelow {
            if answers.answerQualityConfidence >= qualityConfidenceFloor {
                notes.append(("answer_quality", "The reply is rated unusable."))
            } else {
                // Rated badly, but the distribution is flat: the model is unsure, and an
                // unsure bad rating is worth even less than a confident one.
                notes.append((
                    "answer_quality",
                    "The reply may be unusable, though the rating is not a confident one."
                ))
            }
        } else if answers.answerQuality < qualityClearsAtOrAbove {
            notes.append(("answer_quality", "The reply is rated thin."))
        }

        if !escalations.isEmpty { return .escalate(reasons: ordered(escalations)) }
        if !notes.isEmpty { return .annotate(reasons: ordered(notes)) }
        return .accept
    }

    /// Reasons in question order, so the same verdict reads the same way twice.
    private static func ordered(_ reasons: [(String, String)]) -> [String] {
        reasons
            .sorted { VerificationQuestions.order.firstIndex(of: $0.0) ?? .max
                < VerificationQuestions.order.firstIndex(of: $1.0) ?? .max }
            .map(\.1)
    }
}
