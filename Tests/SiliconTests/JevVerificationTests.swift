import Foundation
import Testing
@testable import SiliconControl
@testable import SiliconRuntime
@testable import SiliconUI

// MARK: - Fixtures

/// The numbers a clean answer produces: it answers the question, invents nothing,
/// contradicts nothing, is in the right format, is finished, is not a refusal, and is good.
///
/// Every policy test below starts here and moves exactly one number. That is what makes
/// them mutation-proof: a rule deleted from `VerificationPolicy` makes its own test fail
/// and nobody else's, so a green suite means every rule is still doing something.
extension VerificationAnswers {
    static let clean = VerificationAnswers(
        answersTheQuestion: 0.96,
        claimsUnavailableInformation: 0.03,
        contradictsContext: 0.02,
        followsRequestedFormat: 0.94,
        isCutOff: 0.04,
        refusesOrDeflects: 0.02,
        answerQuality: 1.9,
        answerQualityConfidence: 0.88
    )

    func with(_ change: (inout VerificationAnswers) -> Void) -> VerificationAnswers {
        var copy = self
        change(&copy)
        return copy
    }
}

/// A Jev response body carrying all seven answers, as TypeSafe would send it.
func jevVerificationBody(
    _ answers: VerificationAnswers = .clean, inputTokens: Int = 900
) -> String {
    func noul(_ value: Double) -> String { #"{"type":"noul","noul":\#(value)}"# }
    let quality = answers.answerQuality
    // A three-level distribution whose expectation is the score, near enough for a test.
    let score = """
        {"type":"score","score":\(quality),"confidence":\(answers.answerQualityConfidence),
         "legend":{"0":"unusable","1":"acceptable","2":"good"},
         "probabilities":{"0":0.1,"1":0.2,"2":0.7}}
        """
    return """
        {"model":"jev-1.13.0",
         "usage":{"input_tokens":\(inputTokens),"output_tokens":21},
         "answers":{
           "answers_the_question":\(noul(answers.answersTheQuestion)),
           "claims_unavailable_information":\(noul(answers.claimsUnavailableInformation)),
           "contradicts_context":\(noul(answers.contradictsContext)),
           "follows_requested_format":\(noul(answers.followsRequestedFormat)),
           "is_cut_off":\(noul(answers.isCutOff)),
           "refuses_or_deflects":\(noul(answers.refusesOrDeflects)),
           "answer_quality":\(score)
         }}
        """
}

/// An OpenAI-shaped completion, as the loopback gateway hands one back.
func gatewayCompletion(_ content: String) -> String {
    let escaped = String(
        decoding: (try? JSONEncoder().encode(content)) ?? Data("\"\"".utf8), as: UTF8.self
    )
    return #"{"choices":[{"index":0,"message":{"role":"assistant","content":\#(escaped)},"#
        + #""finish_reason":"stop"}]}"#
}

/// A verifier wired to a `JevService` under test, with the gateway and the target injected.
///
/// The production one is `AppModel.jevVerifier()`; this is the same type with the same four
/// closures, which is the point of it being a value: no shared service, no Keychain, no
/// real key, no real money.
@MainActor
func testVerifier(
    service: JevService, target: String?, gateway: GatewayEscalation?,
    escalations: EscalationCount? = nil
) -> JevVerifier {
    JevVerifier(
        isAvailable: { await service.isAvailable(.verification) },
        ask: { state in try await VerificationQuestions.ask(state: state, using: service) },
        escalationTarget: { answeredBy in
            // The production resolver's identity guard, in miniature: a fake target that
            // is the model under test is no target at all.
            target == answeredBy ? nil : target
        },
        escalate: { modelID, messages, maxTokens in
            await escalations?.note()
            guard let gateway else {
                throw JevVerificationError.escalationEmpty(model: modelID)
            }
            return try await gateway.run(
                modelID: modelID, messages: messages, maxTokens: maxTokens
            )
        }
    )
}

/// Whether a piece of background work actually ran, and whether it was cancelled first.
actor Landing {
    private(set) var landed = false
    private(set) var wasCancelled = true
    func note(cancelled: Bool) { landed = true; wasCancelled = cancelled }
}

actor EscalationCount {
    private(set) var calls = 0
    func note() { calls += 1 }
}

func chatPrompt(
    _ text: String, system: String? = nil, history: [(String, String)] = [],
    images: [String] = []
) -> VerificationPrompt {
    var messages: [ControlAPI.ChatRequest.Message] = []
    if let system { messages.append(.init(role: "system", content: system)) }
    for (role, content) in history { messages.append(.init(role: role, content: content)) }
    messages.append(.init(role: "user", content: text, images: images))
    return VerificationPrompt(messages: messages)
}

/// Jev on, verification on, pointed at a loopback double.
extension JevHarness {
    func enableVerification() async throws {
        try await service.update { settings in
            settings.enabled = true
            settings.features[.verification] = true
        }
    }
}

// MARK: - The policy

/// One test per rule, each moving one number away from `.clean`.
@Suite("Verification policy")
struct VerificationPolicyTests {

    @Test func aCleanAnswerIsAccepted() {
        #expect(VerificationPolicy.verdict(.clean, wasTruncated: false) == .accept)
        // And truncation alone changes nothing: an answer that reads as finished is
        // finished, whatever the token budget did.
        #expect(VerificationPolicy.verdict(.clean, wasTruncated: true) == .accept)
    }

    @Test func notAnsweringTheQuestionEscalatesAndDoubtAnnotates() {
        let no = VerificationAnswers.clean.with { $0.answersTheQuestion = 0.2 }
        let verdict = VerificationPolicy.verdict(no, wasTruncated: false)
        #expect(verdict.name == "escalate")
        #expect(verdict.reasons == ["The reply does not answer what was asked."])

        // Exactly on the bar escalates; the rule is "at or below".
        let onTheBar = VerificationAnswers.clean.with {
            $0.answersTheQuestion = VerificationPolicy.answersEscalatesAtOrBelow
        }
        #expect(VerificationPolicy.verdict(onTheBar, wasTruncated: false).name == "escalate")

        // The middle band is the model saying it cannot tell, which is worth a note and
        // not worth paying a stronger model to redo.
        let unsure = VerificationAnswers.clean.with { $0.answersTheQuestion = 0.5 }
        let middle = VerificationPolicy.verdict(unsure, wasTruncated: false)
        #expect(middle.name == "annotate")
        #expect(middle.reasons == ["It is not clear the reply answers what was asked."])

        // And just above the clearing bar, nothing at all.
        let fine = VerificationAnswers.clean.with {
            $0.answersTheQuestion = VerificationPolicy.answersClearsAtOrAbove
        }
        #expect(VerificationPolicy.verdict(fine, wasTruncated: false) == .accept)
    }

    @Test func describingSomethingItWasNeverGivenEscalates() {
        let invented = VerificationAnswers.clean.with { $0.claimsUnavailableInformation = 0.81 }
        let verdict = VerificationPolicy.verdict(invented, wasTruncated: false)
        #expect(verdict.name == "escalate")
        #expect(verdict.reasons.first?.contains("never provided") == true)

        let maybe = VerificationAnswers.clean.with { $0.claimsUnavailableInformation = 0.65 }
        #expect(VerificationPolicy.verdict(maybe, wasTruncated: false).name == "annotate")

        // A confident no is as certain as a confident yes — the other end of the noul, and
        // the reason this is two bars rather than one.
        let certainlyNot = VerificationAnswers.clean.with {
            $0.claimsUnavailableInformation = VerificationPolicy.unavailableClearsAtOrBelow
        }
        #expect(VerificationPolicy.verdict(certainlyNot, wasTruncated: false) == .accept)
    }

    @Test func contradictingTheContextEscalates() {
        let clash = VerificationAnswers.clean.with { $0.contradictsContext = 0.85 }
        let verdict = VerificationPolicy.verdict(clash, wasTruncated: false)
        #expect(verdict.name == "escalate")
        #expect(verdict.reasons == ["The reply contradicts the context it was given."])

        let maybe = VerificationAnswers.clean.with { $0.contradictsContext = 0.65 }
        #expect(VerificationPolicy.verdict(maybe, wasTruncated: false).name == "annotate")
    }

    /// The rule the whole feature turns on: the *code* decides truncation.
    @Test func cutOffOnlyEscalatesWhenTheRuntimeSaysTheBudgetRanOut() {
        let trailsOff = VerificationAnswers.clean.with { $0.isCutOff = 0.9 }

        let budgetSpent = VerificationPolicy.verdict(trailsOff, wasTruncated: true)
        #expect(budgetSpent.name == "escalate")
        #expect(budgetSpent.reasons == [
            "The reply stops mid-thought and the token budget ran out.",
        ])

        // Same answer from Jev, different fact from the runtime, different verdict. A
        // rerun would produce the same shape and cost money to do it.
        let budgetLeft = VerificationPolicy.verdict(trailsOff, wasTruncated: false)
        #expect(budgetLeft.name == "annotate")
        #expect(budgetLeft.reasons == [
            "The reply reads as unfinished, though the token budget was not spent.",
        ])

        // Middle band plus a spent budget is a note, not a rerun.
        let unsure = VerificationAnswers.clean.with { $0.isCutOff = 0.45 }
        #expect(VerificationPolicy.verdict(unsure, wasTruncated: true).name == "annotate")
        #expect(VerificationPolicy.verdict(unsure, wasTruncated: false) == .accept)
    }

    @Test func aRefusalIsNotedAndNeverEscalated() {
        let refused = VerificationAnswers.clean.with { $0.refusesOrDeflects = 0.95 }
        let verdict = VerificationPolicy.verdict(refused, wasTruncated: false)
        // A refusal is often the right answer, and a stronger model is not the cure for
        // one — so this rule can only ever annotate, at any value.
        #expect(verdict.name == "annotate")
        #expect(verdict.reasons == ["The reply declines or deflects the request."])
        #expect(VerificationPolicy.verdict(
            VerificationAnswers.clean.with { $0.refusesOrDeflects = 1 }, wasTruncated: true
        ).name == "annotate")
    }

    @Test func aMissedFormatIsNotedAndNeverEscalated() {
        let wrongShape = VerificationAnswers.clean.with { $0.followsRequestedFormat = 0.1 }
        let verdict = VerificationPolicy.verdict(wrongShape, wasTruncated: false)
        #expect(verdict.name == "annotate")
        #expect(verdict.reasons == ["The reply is not in the format the message asked for."])
        // Re-running rarely fixes formatting, so it never buys a second answer.
        #expect(VerificationPolicy.verdict(
            VerificationAnswers.clean.with { $0.followsRequestedFormat = 0 }, wasTruncated: true
        ).name == "annotate")
    }

    /// The holistic head reports and never gates — the cascade cookbook's arrangement.
    @Test func theQualityRatingIsReportedAndNeverEscalates() {
        let bad = VerificationAnswers.clean.with {
            $0.answerQuality = 0.3
            $0.answerQualityConfidence = 0.8
        }
        let verdict = VerificationPolicy.verdict(bad, wasTruncated: false)
        #expect(verdict.name == "annotate")
        #expect(verdict.reasons == ["The reply is rated unusable."])
        // Not at the floor either, however sure it is: one question that hides six
        // judgments cannot say which of them went wrong, so it cannot buy a second answer.
        #expect(VerificationPolicy.verdict(
            VerificationAnswers.clean.with {
                $0.answerQuality = 0
                $0.answerQualityConfidence = 1
            }, wasTruncated: true
        ).name == "annotate")

        // Same rating, flat distribution: the model is telling us it cannot tell, and the
        // sentence says so rather than reading as a finding.
        let unsure = bad.with { $0.answerQualityConfidence = 0.2 }
        let soft = VerificationPolicy.verdict(unsure, wasTruncated: false)
        #expect(soft.name == "annotate")
        #expect(soft.reasons.first?.contains("not a confident one") == true)

        // Thin but usable is a note.
        let thin = VerificationAnswers.clean.with { $0.answerQuality = 1.0 }
        let note = VerificationPolicy.verdict(thin, wasTruncated: false)
        #expect(note.name == "annotate")
        #expect(note.reasons == ["The reply is rated thin."])
    }

    /// The fabrication head cannot fire on evidence this state never carried.
    @Test func aWithheldSystemPromptDowngradesTheFabricationHead() {
        let invented = VerificationAnswers.clean.with { $0.claimsUnavailableInformation = 0.95 }

        // Everything the model saw is in the state: a confident yes is a finding.
        #expect(VerificationPolicy.verdict(
            invented, wasTruncated: false, evidenceIncomplete: false
        ).name == "escalate")

        // The system prompt was too long to send, or the context was elided. The same
        // number now means "not in what you showed me", which is not the same claim.
        let guarded = VerificationPolicy.verdict(
            invented, wasTruncated: false, evidenceIncomplete: true
        )
        #expect(guarded.name == "annotate")
        #expect(guarded.reasons.first?.contains("too long to check against") == true)

        // The other heads are untouched by it — only this one reads absence as evidence.
        #expect(VerificationPolicy.verdict(
            VerificationAnswers.clean.with { $0.answersTheQuestion = 0.1 },
            wasTruncated: false, evidenceIncomplete: true
        ).name == "escalate")
    }

    @Test func oneEscalationOutweighsAnyNumberOfNotesAndReasonsAreInQuestionOrder() {
        let mess = VerificationAnswers.clean.with {
            $0.answersTheQuestion = 0.1           // escalates
            $0.claimsUnavailableInformation = 0.9 // escalates
            $0.refusesOrDeflects = 0.9            // notes only
            $0.followsRequestedFormat = 0.1       // notes only
            $0.answerQuality = 0                  // notes only
        }
        let verdict = VerificationPolicy.verdict(mess, wasTruncated: false)
        #expect(verdict.name == "escalate")
        // Only the escalating reasons, and in the order the questions are declared in —
        // so the same verdict reads the same way twice.
        #expect(verdict.reasons == [
            "The reply does not answer what was asked.",
            "The reply states things about a document, tool result or image that was never "
            + "provided.",
        ])
    }

    @Test func everyThresholdIsAPairThatDoesNotCross() {
        // A low bar above its high bar would make the middle band empty and the policy a
        // lie about itself.
        #expect(VerificationPolicy.answersEscalatesAtOrBelow
            < VerificationPolicy.answersClearsAtOrAbove)
        #expect(VerificationPolicy.unavailableClearsAtOrBelow
            < VerificationPolicy.unavailableEscalatesAtOrAbove)
        #expect(VerificationPolicy.contradictsClearsAtOrBelow
            < VerificationPolicy.contradictsEscalatesAtOrAbove)
        #expect(VerificationPolicy.cutOffClearsAtOrBelow
            < VerificationPolicy.cutOffFiresAtOrAbove)
        #expect(VerificationPolicy.qualityEscalatesAtOrBelow
            < VerificationPolicy.qualityClearsAtOrAbove)
        // And the three escalating heads share one bar, which is the cookbook's.
        #expect(VerificationPolicy.fireThreshold == 0.7)
        #expect(VerificationPolicy.unavailableEscalatesAtOrAbove
            == VerificationPolicy.fireThreshold)
        #expect(VerificationPolicy.contradictsEscalatesAtOrAbove
            == VerificationPolicy.fireThreshold)
        #expect(VerificationPolicy.cutOffFiresAtOrAbove == VerificationPolicy.fireThreshold)
        // A lean is not a finding: at 0.65 every one of them only annotates.
        for answers in [
            VerificationAnswers.clean.with { $0.claimsUnavailableInformation = 0.65 },
            VerificationAnswers.clean.with { $0.contradictsContext = 0.65 },
            VerificationAnswers.clean.with { $0.isCutOff = 0.65 },
        ] {
            #expect(VerificationPolicy.verdict(answers, wasTruncated: true).name == "annotate")
        }
    }
}

// MARK: - The questions and the state

@Suite("Verification questions")
struct VerificationQuestionTests {

    @Test func everyQuestionIsWellFormedAndNamedInTheOrderList() throws {
        for (name, question) in VerificationQuestions.questions {
            try question.validate(name: name)
            #expect(VerificationQuestions.order.contains(name), "\(name) is not in `order`")
        }
        #expect(VerificationQuestions.order.count == VerificationQuestions.questions.count)
        try JevService.checkLimits(VerificationQuestions.questions)
        #expect(VerificationQuestions.feature == .verification)
        // Six nouls and one score, which is what `VerificationAnswers` reads.
        #expect(VerificationQuestions.questions.values.filter { $0.type == "noul" }.count == 6)
        #expect(VerificationQuestions.questions.values.filter { $0.type == "score" }.count == 1)
    }

    @Test func aLongReplyIsSentHeadAndTail() throws {
        let long = String(repeating: "A", count: 400) + "MIDDLE"
            + String(repeating: "Z", count: 400)
        let trimmed = VerificationQuestions.trimmed(long, toBytes: 100)
        #expect(trimmed.utf8.count < long.utf8.count)
        #expect(trimmed.hasPrefix("A"))
        // The tail survives, which is what `is_cut_off` reads.
        #expect(trimmed.hasSuffix("Z"))
        #expect(trimmed.contains("[…]"))
        #expect(!trimmed.contains("MIDDLE"))

        // Short text is untouched, gap marker and all.
        #expect(VerificationQuestions.trimmed("short", toBytes: 100) == "short")

        // Cutting on character boundaries, not byte ones: a multi-byte character must not
        // come back as a broken one.
        let emoji = String(repeating: "🙂", count: 50)
        let cut = VerificationQuestions.trimmed(emoji, toBytes: 40)
        #expect(cut.unicodeScalars.allSatisfy { $0.properties.isEmoji || $0 == " " || $0 == "\n" || $0 == "[" || $0 == "]" || $0 == "…" })
    }

    @Test func imagesAreNamedNeverSent() throws {
        let prompt = chatPrompt(
            "What is in this picture?",
            images: ["data:image/png;base64,iVBORw0KGgoAAAANSUhEUg=="]
        )
        let state = VerificationQuestions.state(
            message: prompt.lastUserMessage, systemPrompt: prompt.systemPrompt,
            reply: "A kettle on a blue counter.", context: prompt.derivedContext
        )
        let text = state.content.promptText
        // Not one byte of it. Jev reads text, and a base64 PNG in the state is kilobytes
        // of noise that answers none of the seven questions.
        #expect(!text.contains("iVBORw0KGgo"))
        #expect(!text.contains("base64"))

        // And the note has to say the *contents* are missing, not merely that a picture
        // existed. "An image was attached" alone reads as evidence the model was given
        // something, which is the opposite of what this state can vouch for.
        #expect(text.contains("An image was attached"))
        #expect(text.contains("contents are not included"))
        let many = try #require(VerificationQuestions.context(
            priorTurns: [], imageCount: 3
        ))
        #expect(many.contains("3 images were attached"))
        #expect(many.contains("contents are not included"))

        // The fabrication question says the same thing in its own criteria, because that
        // is where `jev-1.13` reads it: without the clause, a reply describing the picture
        // looks like a reply describing something it was given.
        let fabrication = try #require(
            VerificationQuestions.questions["claims_unavailable_information"]
        )
        let criteria = fabrication.criteria?.promptText ?? ""
        #expect(criteria.contains("an image was attached"))
        #expect(criteria.contains("does not make the image's contents available"))
        // The other half of the same idea, and the question's end of the `withheld`
        // contract: what this state left out is not proof the model invented it.
        #expect(criteria.contains("`withheld`"))
        #expect(criteria.contains("could see it even though you cannot"))
    }

    @Test func theStateHoldsOnlyWhatTheQuestionsNeed() throws {
        let prompt = chatPrompt(
            "Summarise it in three bullets.",
            system: "You are terse.",
            history: [("user", "Here is the report."), ("assistant", "Noted.")]
        )
        let state = VerificationQuestions.state(
            message: prompt.lastUserMessage, systemPrompt: prompt.systemPrompt,
            reply: "• one\n• two\n• three", context: prompt.derivedContext
        )
        let fields = try #require(state.content.objectValue)
        #expect(Set(fields.keys) == ["message", "reply", "system_prompt", "context"])
        #expect(fields["message"]?.stringValue == "Summarise it in three bullets.")
        // The last user turn is the question, not part of the context around it.
        #expect(fields["context"]?.stringValue?.contains("Summarise it in three") == false)
        #expect(fields["context"]?.stringValue?.contains("Here is the report.") == true)

        // A long persona document is omitted rather than sent: past a few hundred words it
        // is not context for "does this answer the question", it is a distraction.
        let wordy = String(repeating: "You are a helpful assistant. ", count: 200)
        let trimmedState = VerificationQuestions.state(
            message: "hi", systemPrompt: wordy, reply: "hello", context: nil
        )
        #expect(trimmedState.content.objectValue?["system_prompt"] == nil)
        // And an absent context is an absent key, not an empty string the model has to
        // decide means nothing.
        #expect(trimmedState.content.objectValue?["context"] == nil)
        // …but the state says the prompt was withheld, so the fabrication head cannot be
        // escalated on evidence this state never had.
        #expect(trimmedState.evidenceIncomplete)
        #expect(Set(trimmedState.content.objectValue?.keys ?? [:].keys)
            == ["message", "reply", "withheld"])
    }

    @Test func aPastedDocumentIsSentHeadAndTailLikeEverythingElse() throws {
        // The question a pasted document ends with is at the end of it, so the message gets
        // the same treatment the reply does — anything else either drops the question or
        // sends a state big enough to lose it in.
        let pasted = String(repeating: "Paragraph of the report. ", count: 1_000)
            + "\n\nWhich quarter does this cover?"
        #expect(pasted.utf8.count > VerificationQuestions.maximumMessageBytes)

        let state = VerificationQuestions.state(
            message: pasted, systemPrompt: nil, reply: "The third quarter.", context: nil
        )
        let sent = try #require(state.content.objectValue?["message"]?.stringValue)
        #expect(sent.utf8.count < pasted.utf8.count)
        #expect(sent.hasSuffix("Which quarter does this cover?"))
        #expect(sent.hasPrefix("Paragraph of the report."))
        #expect(sent.contains("[…]"))
        // Trimming the message is not withholding evidence — the message is the question,
        // not a source the reply could be quoting.
        #expect(!state.evidenceIncomplete)

        // And the whole thing still fits what this app will send Jev at all.
        #expect(try JevService.stateBytes(state.content) < JevService.defaultMaxStateBytes)
    }

    @Test func anElidedContextSaysSoInTheState() throws {
        let long = String(repeating: "Minutes of the meeting. ", count: 1_000)
        let state = VerificationQuestions.state(
            message: "Summarise it.", systemPrompt: nil,
            reply: "They agreed to postpone.", context: long
        )
        let fields = try #require(state.content.objectValue)
        #expect(fields["context"]?.stringValue?.contains("[…]") == true)
        // Said in words, so the fabrication question can read it…
        #expect(fields["withheld"]?.stringValue?.contains("middle of `context`") == true)
        // …and flagged, so the policy refuses to escalate on that head.
        #expect(state.evidenceIncomplete)

        // A context that fits is sent whole and withholds nothing.
        let short = VerificationQuestions.state(
            message: "Summarise it.", systemPrompt: "Be terse.",
            reply: "They agreed to postpone.", context: "The meeting was postponed."
        )
        #expect(short.content.objectValue?["withheld"] == nil)
        #expect(!short.evidenceIncomplete)
    }

    @Test func truncationIsReadFromTheRuntimeNotTheModel() {
        // The runtime saying `length` is enough on its own.
        #expect(GenerationMetrics(generatedTokens: 5, finishReason: "length")
            .wasTruncated(budget: 4096))
        // …and so is spending the whole budget, whatever it called the ending. Some
        // `mlx_lm.server` builds stop exactly at `max_tokens` and still report `stop`;
        // believing the word alone would ship half a sentence as a finished answer.
        #expect(GenerationMetrics(generatedTokens: 4096, finishReason: "stop")
            .wasTruncated(budget: 4096))
        #expect(!GenerationMetrics(generatedTokens: 4095, finishReason: "stop")
            .wasTruncated(budget: 4096))
        // A runtime that reports nothing falls back to the same arithmetic.
        #expect(GenerationMetrics(generatedTokens: 512).wasTruncated(budget: 512))
        #expect(!GenerationMetrics(generatedTokens: 511).wasTruncated(budget: 512))
        // No budget and no finish reason is not evidence of anything.
        #expect(!GenerationMetrics(generatedTokens: 9_000).wasTruncated(budget: nil))
        #expect(!GenerationMetrics(generatedTokens: 9_000).wasTruncated(budget: 0))
    }
}

// MARK: - Verifying, end to end

@Suite("Verification, end to end")
@MainActor
struct JevVerificationTests {

    /// Off is off: nothing is sent, nothing is spent, and the caller behaves exactly as it
    /// did before this feature existed.
    @Test func nothingIsAskedWhenTheFeatureIsOff() async throws {
        let jev = try untouchedServer("verification is off")
        defer { jev.stop() }
        let gateway = try untouchedServer("verification is off, so nothing may escalate")
        defer { gateway.stop() }
        let harness = JevHarness()
        defer { harness.clean() }
        await harness.configure(baseURL: URL(string: "http://127.0.0.1:\(jev.port)")!)
        // Jev itself on, this feature off — the case a master switch alone would miss.
        try await harness.service.update { $0.enabled = true }

        let verifier = testVerifier(
            service: harness.service, target: "cloud/openai/gpt-5.5",
            gateway: GatewayEscalation(
                baseURL: URL(string: "http://127.0.0.1:\(gateway.port)")!, token: "t"
            )
        )
        let outcome = await verifier.verify(
            prompt: chatPrompt("What is 2 + 2?"), reply: "Four.",
            context: nil, truncated: true
        )
        #expect(outcome == .unavailable)
        #expect(outcome.verdictName == nil)
        #expect(jev.requests.isEmpty)
        #expect(gateway.requests.isEmpty)
        #expect(await harness.service.ledger().calls == 0)
    }

    @Test func acceptedAnswersComeBackUntouched() async throws {
        let jev = try CapturingServer { _, _ in .init(body: jevVerificationBody()) }
        defer { jev.stop() }
        let gateway = try untouchedServer("a clean answer must not be escalated")
        defer { gateway.stop() }
        let harness = JevHarness()
        defer { harness.clean() }
        await harness.configure(baseURL: URL(string: "http://127.0.0.1:\(jev.port)")!)
        try await harness.enableVerification()

        let verifier = testVerifier(
            service: harness.service, target: "cloud/openai/gpt-5.5",
            gateway: GatewayEscalation(
                baseURL: URL(string: "http://127.0.0.1:\(gateway.port)")!, token: "t"
            )
        )
        let outcome = await verifier.verify(
            prompt: chatPrompt("What is 2 + 2?"), reply: "Four.",
            context: nil, truncated: false
        )
        #expect(outcome == .accepted)
        #expect(jev.requests.count == 1)
        #expect(gateway.requests.isEmpty)

        // One verification, one line in the ledger, under this feature's own name.
        let ledger = await harness.service.ledger()
        #expect(ledger.month().features["verification"]?.calls == 1)
        #expect(ledger.calls == 1)

        // And the state Jev was sent carries no truncation flag: that is code's to know,
        // and a model asked to judge its own evidence is not a verifier.
        let body = String(
            decoding: try #require(jev.requests.first).body, as: UTF8.self
        ).lowercased()
        #expect(!body.contains("truncat"))
        #expect(!body.contains("finish_reason"))
        #expect(!body.contains("budget"))
    }

    @Test func aMiddleBandAnswerIsAnnotatedAndNothingIsEscalated() async throws {
        let jev = try CapturingServer { _, _ in
            .init(body: jevVerificationBody(.clean.with { $0.answersTheQuestion = 0.5 }))
        }
        defer { jev.stop() }
        let gateway = try untouchedServer("an annotate verdict must not spend money")
        defer { gateway.stop() }
        let harness = JevHarness()
        defer { harness.clean() }
        await harness.configure(baseURL: URL(string: "http://127.0.0.1:\(jev.port)")!)
        try await harness.enableVerification()

        let counted = EscalationCount()
        let verifier = testVerifier(
            service: harness.service, target: "cloud/openai/gpt-5.5",
            gateway: GatewayEscalation(
                baseURL: URL(string: "http://127.0.0.1:\(gateway.port)")!, token: "t"
            ),
            escalations: counted
        )
        let outcome = await verifier.verify(
            prompt: chatPrompt("Why is the sky blue?"),
            reply: "It is a question people ask a lot.", context: nil, truncated: false
        )
        #expect(outcome == .annotated(
            reasons: ["It is not clear the reply answers what was asked."]
        ))
        #expect(outcome.suggestion == nil)
        #expect(outcome.verdictName == "annotate")
        #expect(outcome.escalatedTo == nil)
        #expect(await counted.calls == 0)
        #expect(gateway.requests.isEmpty)
        // One question asked, one call billed. An annotate is a verdict, not a cascade.
        #expect(await harness.service.ledger().month().features["verification"]?.calls == 1)
    }

    /// The cascade, whole: flagged, re-run once, the second answer returned, and the second
    /// answer verified too — which is two verifications and exactly one escalation.
    @Test func aFlaggedAnswerIsReRunOnceAndTheSecondAnswerComesBack() async throws {
        let jev = try CapturingServer { _, served in
            // The local answer is flagged; the escalated one is clean.
            .init(body: served == 0
                ? jevVerificationBody(.clean.with { $0.claimsUnavailableInformation = 0.87 })
                : jevVerificationBody())
        }
        defer { jev.stop() }
        let gateway = try CapturingServer { _, _ in
            .init(body: gatewayCompletion("The report does not give a registration date."))
        }
        defer { gateway.stop() }
        let harness = JevHarness()
        defer { harness.clean() }
        await harness.configure(baseURL: URL(string: "http://127.0.0.1:\(jev.port)")!)
        try await harness.enableVerification()

        let counted = EscalationCount()
        let verifier = testVerifier(
            service: harness.service, target: "cloud/openai/gpt-5.5",
            gateway: GatewayEscalation(
                baseURL: URL(string: "http://127.0.0.1:\(gateway.port)")!,
                token: "gateway-token"
            ),
            escalations: counted
        )
        let outcome = await verifier.verify(
            prompt: chatPrompt("When does registration open?"),
            reply: "Registration opens on 09/05/2024, per the calendar page.",
            context: "The page lists no registration date.", truncated: false
        )

        guard case .escalated(let model, let reply, let reasons, let latency) = outcome else {
            Issue.record("expected an escalation, got \(outcome)"); return
        }
        #expect(model == "cloud/openai/gpt-5.5")
        #expect(reply == "The report does not give a registration date.")
        #expect(reasons == [
            "The reply states things about a document, tool result or image that was never "
            + "provided.",
        ])
        #expect(latency >= 0)
        #expect(outcome.escalatedTo == "cloud/openai/gpt-5.5")
        #expect(outcome.verdictName == "escalate")

        // Exactly one. A cascade that can re-enter itself is a loop with a card attached.
        #expect(await counted.calls == 1)
        #expect(gateway.requests.count == 1)

        // The escalated run went out as an ordinary OpenAI request, to the named model,
        // under this feature's own token cap and not the caller's.
        let sent = try #require(gateway.requests.first)
        #expect(sent.path == "/v1/chat/completions")
        #expect(sent.headers["authorization"] == "Bearer gateway-token")
        let body = try JSONSerialization.jsonObject(with: sent.body) as! [String: Any]
        #expect(body["model"] as? String == "cloud/openai/gpt-5.5")
        #expect(body["stream"] as? Bool == false)
        #expect(body["max_tokens"] as? Int == JevVerifier.escalatedTokenCap)
        let messages = body["messages"] as! [[String: Any]]
        #expect(messages.count == 1)
        #expect(messages.first?["role"] as? String == "user")
        #expect(messages.first?["content"] as? String == "When does registration open?")

        // Two verifications — the local answer and the escalated one — both billed to
        // `.verification`, because both were real questions really asked.
        #expect(jev.requests.count == 2)
        let ledger = await harness.service.ledger()
        #expect(ledger.month().features["verification"]?.calls == 2)
        #expect(ledger.month().features["decideTool"] == nil)
    }

    /// What actually goes on the wire when the prompt has a system turn, a history and an
    /// image: the same conversation, in OpenAI's shape, images and all.
    @Test func theEscalationSendsTheWholeConversationImagesIncluded() async throws {
        let jev = try CapturingServer { _, served in
            .init(body: served == 0
                ? jevVerificationBody(.clean.with { $0.answersTheQuestion = 0.05 })
                : jevVerificationBody())
        }
        defer { jev.stop() }
        let gateway = try CapturingServer { _, _ in
            .init(body: gatewayCompletion("A copper kettle on a blue counter."))
        }
        defer { gateway.stop() }
        let harness = JevHarness()
        defer { harness.clean() }
        await harness.configure(baseURL: URL(string: "http://127.0.0.1:\(jev.port)")!)
        try await harness.enableVerification()

        let image = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUg=="
        let prompt = chatPrompt(
            "What is in this picture?",
            system: "You are terse.",
            history: [("user", "Hello."), ("assistant", "Hi.")],
            images: [image]
        )
        let verifier = testVerifier(
            service: harness.service, target: "cloud/open-router/gpt-5.5",
            gateway: GatewayEscalation(
                baseURL: URL(string: "http://127.0.0.1:\(gateway.port)")!, token: "gw"
            )
        )
        let outcome = await verifier.verify(
            prompt: prompt, reply: "I cannot see it.", context: nil, truncated: false
        )
        #expect(outcome.escalatedTo == "cloud/open-router/gpt-5.5")

        let body = try JSONSerialization.jsonObject(
            with: try #require(gateway.requests.first).body
        ) as! [String: Any]
        let messages = body["messages"] as! [[String: Any]]
        // Every turn, in order, including the system one — the escalation model is
        // answering the same question under the same instructions, not a summary of it.
        #expect(messages.count == 4)
        #expect(messages.map { $0["role"] as! String } == ["system", "user", "assistant", "user"])
        #expect(messages[0]["content"] as? String == "You are terse.")
        #expect(messages[1]["content"] as? String == "Hello.")

        // The turn with the image becomes OpenAI content parts rather than a bare string.
        let parts = try #require(messages[3]["content"] as? [[String: Any]])
        #expect(parts.first?["type"] as? String == "text")
        #expect(parts.first?["text"] as? String == "What is in this picture?")
        #expect(parts.last?["type"] as? String == "image_url")
        #expect((parts.last?["image_url"] as? [String: Any])?["url"] as? String == image)

        // Jev, meanwhile, was told an image existed and given none of it — the two
        // destinations are deliberately not sent the same thing.
        let asked = String(decoding: try #require(jev.requests.first).body, as: UTF8.self)
        #expect(asked.contains("An image was attached"))
        #expect(!asked.contains("iVBORw0KGgo"))
    }

    /// The second look is reported, never acted on.
    @Test func aStillBadEscalatedAnswerIsReturnedWithItsOwnVerdictAttached() async throws {
        let jev = try CapturingServer { _, _ in
            .init(body: jevVerificationBody(.clean.with { $0.answersTheQuestion = 0.05 }))
        }
        defer { jev.stop() }
        let gateway = try CapturingServer { _, _ in
            .init(body: gatewayCompletion("Also not an answer."))
        }
        defer { gateway.stop() }
        let harness = JevHarness()
        defer { harness.clean() }
        await harness.configure(baseURL: URL(string: "http://127.0.0.1:\(jev.port)")!)
        try await harness.enableVerification()
        // Off, so the two identical-looking asks are each really sent and the count is real.
        try await harness.service.update { $0.cacheMinutes = 0 }

        let counted = EscalationCount()
        let verifier = testVerifier(
            service: harness.service, target: "node/studio/qwen3.8-27b",
            gateway: GatewayEscalation(
                baseURL: URL(string: "http://127.0.0.1:\(gateway.port)")!, token: "t"
            ),
            escalations: counted
        )
        let outcome = await verifier.verify(
            prompt: chatPrompt("Why is the sky blue?"), reply: "Ask someone else.",
            context: nil, truncated: false
        )

        guard case .escalated(_, let reply, let reasons, _) = outcome else {
            Issue.record("expected an escalation, got \(outcome)"); return
        }
        // Returned regardless of the second verdict — and the second verdict said so.
        #expect(reply == "Also not an answer.")
        #expect(reasons.count == 2)
        #expect(reasons.first == "The reply does not answer what was asked.")
        #expect(reasons.last?.hasPrefix("The stronger model's answer was flagged too:") == true)
        // Still exactly one escalation. No third rung, ever.
        #expect(await counted.calls == 1)
        #expect(gateway.requests.count == 1)
    }

    @Test func withNowhereToEscalateToTheAnswerIsOnlyAnnotated() async throws {
        let jev = try CapturingServer { _, _ in
            .init(body: jevVerificationBody(.clean.with { $0.contradictsContext = 0.9 }))
        }
        defer { jev.stop() }
        let harness = JevHarness()
        defer { harness.clean() }
        await harness.configure(baseURL: URL(string: "http://127.0.0.1:\(jev.port)")!)
        try await harness.enableVerification()

        let counted = EscalationCount()
        let verifier = testVerifier(
            service: harness.service, target: nil, gateway: nil, escalations: counted
        )
        let outcome = await verifier.verify(
            prompt: chatPrompt("Is the shop open on Sunday?"), reply: "Yes, all day.",
            context: "The shop is closed on Sundays.", truncated: false
        )
        #expect(outcome.verdictName == "annotate")
        // The reader still learns what was wrong — the difference between an answer that
        // is merely suspect and one that looks fine — plus what to do about it.
        // The reason says what is wrong with the answer; the note about there being
        // nowhere to send it is advice, so it travels in `suggestion` instead.
        #expect(outcome.reasons == ["The reply contradicts the context it was given."])
        #expect(outcome.suggestion == JevVerifier.noTargetNote)
        #expect(await counted.calls == 0)
        // One verification only: there was no second answer to verify.
        #expect(jev.requests.count == 1)
    }

    @Test func aGatewayThatRefusesLeavesTheLocalAnswerStanding() async throws {
        let jev = try CapturingServer { _, _ in
            .init(body: jevVerificationBody(.clean.with { $0.answersTheQuestion = 0.1 }))
        }
        defer { jev.stop() }
        let gateway = try CapturingServer { request, _ in
            .init(status: 502, body: #"{"error":"the node is asleep"}"#)
        }
        defer { gateway.stop() }
        let harness = JevHarness()
        defer { harness.clean() }
        await harness.configure(baseURL: URL(string: "http://127.0.0.1:\(jev.port)")!)
        try await harness.enableVerification()

        let verifier = testVerifier(
            service: harness.service, target: "node/studio/qwen3.8-27b",
            gateway: GatewayEscalation(
                baseURL: URL(string: "http://127.0.0.1:\(gateway.port)")!, token: "t"
            )
        )
        let outcome = await verifier.verify(
            prompt: chatPrompt("Why is the sky blue?"), reply: "Mm.",
            context: nil, truncated: false
        )
        // A gateway that refused is a fact about this Mac, not about the reply. Reported
        // beside the reasons, never thrown at whoever asked a chat question.
        #expect(outcome.verdictName == "annotate")
        #expect(outcome.reasons == ["The reply does not answer what was asked."])
        #expect(outcome.suggestion?.contains("node/studio/qwen3.8-27b") == true)
        #expect(outcome.suggestion?.contains("502") == true)
    }

    /// A TypeSafe outage must not turn a working chat into a failed one.
    @Test func aFailedQuestionIsNoVerdictRatherThanAFailedChat() async throws {
        let jev = try CapturingServer { _, _ in
            .init(status: 500, body: #"{"error":"upstream"}"#)
        }
        defer { jev.stop() }
        let harness = JevHarness()
        defer { harness.clean() }
        await harness.configure(baseURL: URL(string: "http://127.0.0.1:\(jev.port)")!)
        try await harness.enableVerification()

        let verifier = testVerifier(service: harness.service, target: nil, gateway: nil)
        let outcome = await verifier.verify(
            prompt: chatPrompt("hi"), reply: "hello", context: nil, truncated: false
        )
        #expect(outcome == .unavailable)
    }

    /// Streams judge but never escalate, and say what they would have done instead.
    @Test func aStreamingVerdictSuggestsRatherThanSubstitutes() async throws {
        let jev = try CapturingServer { _, _ in
            .init(body: jevVerificationBody(.clean.with { $0.isCutOff = 0.92 }))
        }
        defer { jev.stop() }
        let gateway = try untouchedServer("a stream must never escalate mid-answer")
        defer { gateway.stop() }
        let harness = JevHarness()
        defer { harness.clean() }
        await harness.configure(baseURL: URL(string: "http://127.0.0.1:\(jev.port)")!)
        try await harness.enableVerification()

        let verifier = testVerifier(
            service: harness.service, target: "cloud/openai/gpt-5.5",
            gateway: GatewayEscalation(
                baseURL: URL(string: "http://127.0.0.1:\(gateway.port)")!, token: "t"
            )
        )
        // The judgment a stream makes: the same policy, run without the escalation arm.
        let verdict = try #require(await verifier.judge(
            prompt: chatPrompt("Explain gradient descent."),
            reply: "Gradient descent works by repeatedly taking a step in the dire",
            context: nil, truncated: true
        ))
        #expect(verdict.name == "escalate")
        #expect(gateway.requests.isEmpty)

        let suggestion = JevVerifier.streamSuggestion(target: "cloud/openai/gpt-5.5")
        #expect(suggestion.contains("cloud/openai/gpt-5.5"))
        #expect(suggestion.contains("POST /chat"))
        #expect(JevVerifier.streamSuggestion(target: nil) == JevVerifier.noTargetNote)
    }

    /// The settings a control client may read, and the token it takes to change them.
    @Test func theEscalationTargetIsReadableButOnlyTheMacMaySetIt() async throws {
        let harness = JevHarness()
        defer { harness.clean() }
        await harness.configure()
        try await harness.service.update {
            $0.enabled = true
            $0.features[.verification] = true
            $0.verificationEscalationModel = "cloud/open-router/gpt-5.5"
        }

        let status = await AppModel.jevStatus(from: harness.service)
        #expect(status.verificationEscalationModel == "cloud/open-router/gpt-5.5")
        // Named, never hidden: a phone is entitled to see that its answers are being
        // re-run on somebody else's hardware. `POST /jev` is what it may not call, and
        // that gate is the route's own (asserted in the contract export).
        let json = String(
            decoding: try JSONEncoder().encode(status), as: UTF8.self
        )
        #expect(json.contains("verificationEscalationModel"))
        #expect(!json.lowercased().contains("apikey"))

        // The patch sets it, and has a separate way of saying "go back to working it out"
        // — an absent field means "leave alone", so nil could not say it.
        let set = ControlAPI.JevUpdate(verificationEscalationModel: "node/studio/qwen3.8-27b")
        let cleared = ControlAPI.JevUpdate(clearVerificationEscalation: true)
        #expect(set.verificationEscalationModel == "node/studio/qwen3.8-27b")
        #expect(set.clearVerificationEscalation == nil)
        #expect(cleared.verificationEscalationModel == nil)
        // Both survive the wire, which is the only way a control client can send them.
        let roundTripped = try JSONDecoder().decode(
            ControlAPI.JevUpdate.self, from: try JSONEncoder().encode(set)
        )
        #expect(roundTripped == set)
    }

    @Test func theEscalationTargetSurvivesTheSettingsFile() async throws {
        let harness = JevHarness()
        defer { harness.clean() }
        await harness.configure()
        try await harness.service.update {
            $0.enabled = true
            $0.features[.verification] = true
            $0.verificationEscalationModel = "cloud/openai/gpt-5.5"
        }
        let reloaded = JevSettings.load(from: harness.configURL)
        #expect(reloaded.verificationEscalationModel == "cloud/openai/gpt-5.5")
        #expect(reloaded.isOn(.verification))

        // The picker's "work it out" row arrives as an empty string; storing that would be
        // a model id no gateway can parse.
        try await harness.service.update { $0.verificationEscalationModel = "  " }
        #expect(await harness.service.settings().verificationEscalationModel == nil)
        #expect(JevSettings.load(from: harness.configURL).verificationEscalationModel == nil)

        // And the file still carries no credential.
        let onDisk = String(decoding: try Data(contentsOf: harness.configURL), as: UTF8.self)
        #expect(!onDisk.lowercased().contains("apikey"))
    }
}

// MARK: - Live

/// Against the real TypeSafe API, with a real key, when both are explicitly asked for.
///
/// Never part of an ordinary run: it costs money and needs a credential. The key is read
/// from the environment at the moment it is used and is never printed — not the value, not
/// its length, not a prefix.
@Suite("Verification, live")
@MainActor
struct JevVerificationLiveTests {

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SILICON_JEV_LIVE"] == "1"))
    func jevTellsAGoodAnswerFromACutOffOne() async throws {
        let harness = JevHarness()
        defer { harness.clean() }
        await harness.service.configure(
            keyProvider: { ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"] },
            keyIsSet: { ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"] != nil },
            configURL: harness.configURL
        )
        try await harness.enableVerification()
        guard await harness.service.isAvailable(.verification) else {
            Issue.record("SILICON_JEV_LIVE=1 but TYPESAFE_API_KEY is not set.")
            return
        }

        // Nowhere to escalate to: this test is about the judgment, and it must not put a
        // cloud bill on top of the Jev one.
        let verifier = testVerifier(service: harness.service, target: nil, gateway: nil)
        let question = chatPrompt("Why does bread rise?")

        let good = await verifier.verify(
            prompt: question,
            reply: "Yeast eats the sugars in the dough and gives off carbon dioxide. The "
                + "gluten network traps those bubbles, so the dough expands; the oven's heat "
                + "then sets the structure before the gas escapes.",
            context: nil, truncated: false
        )
        #expect(good == .accepted, "a good answer should not be flagged; got \(good)")

        // The same question, answered until the token budget ran out. The runtime's word
        // is what makes this an escalation rather than a note — so it is passed as a fact.
        let cut = await verifier.verify(
            prompt: question,
            reply: "Yeast eats the sugars in the dough and gives off carbon dioxide, which "
                + "is trapped by the glu",
            context: nil, truncated: true
        )
        #expect(cut.verdictName == "annotate", "with no target, an escalation annotates")
        #expect(cut.reasons.contains { $0.contains("mid-thought") },
                "the cut-off reply should be recognised as one; got \(cut.reasons)")

        // Two questions asked, two calls billed, and the ledger knows whose they were.
        let ledger = await harness.service.ledger()
        #expect(ledger.month().features["verification"]?.calls == 2)
        #expect(ledger.inputTokens > 0)
    }
}

// MARK: - Choosing a target

/// The rule on its own, with no gateway, no swarm and no settings file behind it.
@Suite("Verification escalation target")
struct VerificationTargetTests {

    private func model(_ id: String, serving: Bool = false) -> GatewayAPI.Model {
        GatewayAPI.Model(
            id: id, displayName: id, where_: "somewhere", contextWindow: nil, serving: serving
        )
    }

    /// The one model an escalation must never be: the machine is busy being the thing
    /// under test, and re-running here would unload it mid-request.
    @Test func itIsNeverAModelOnThisMac() {
        let library = [
            model("local/qwen3-30b", serving: true),
            model("local/llama-70b"),
        ]
        #expect(AppModel.escalationTarget(
            chosen: nil, from: library, excluding: "local/qwen3-30b"
        ) == nil)
        // Not even when the settings file names one — a hand-edited file, or a pick left
        // behind by a model since reinstalled, is ignored rather than carried out.
        #expect(AppModel.escalationTarget(
            chosen: "local/llama-70b", from: library, excluding: "local/qwen3-30b"
        ) == nil)
        // And the identity guard stands on its own, for a reply that came from elsewhere.
        #expect(AppModel.escalationTarget(
            chosen: "node/studio/qwen3.8-27b", from: [], excluding: "node/studio/qwen3.8-27b"
        ) == nil)
    }

    /// Automatically: a node that is already serving, and nothing else.
    @Test func theAutomaticChoiceIsAServingNodeAndNeverTheCloud() {
        let world = [
            model("local/qwen3-30b", serving: true),
            model("cloud/open-router/gpt-5.5"),
            model("node/studio/qwen3.8-27b", serving: true),
        ]
        #expect(AppModel.escalationTarget(chosen: nil, from: world, excluding: "local/qwen3-30b")
            == "node/studio/qwen3.8-27b")

        // A node that is installed but not serving is not a free second opinion — starting
        // one is a load, and the automatic path does not go that far.
        let idle = [
            model("cloud/open-router/gpt-5.5"),
            model("node/studio/qwen3.8-27b", serving: false),
        ]
        #expect(AppModel.escalationTarget(chosen: nil, from: idle, excluding: nil) == nil)

        // With only a cloud model reachable, the automatic answer is still nothing:
        // sending a whole conversation to someone else's hardware is the owner's call.
        #expect(AppModel.escalationTarget(
            chosen: nil, from: [model("cloud/open-router/gpt-5.5", serving: true)], excluding: nil
        ) == nil)
    }

    /// Explicitly: whatever the owner named, seen or not.
    @Test func anExplicitPickIsHonouredEvenWhenTheGatewayCannotSeeIt() {
        #expect(AppModel.escalationTarget(
            chosen: "cloud/open-router/gpt-5.5", from: [], excluding: nil
        ) == "cloud/open-router/gpt-5.5")
        // A pick wins over what the automatic rule would have found — including over a
        // serving node, which is the point of picking.
        #expect(AppModel.escalationTarget(
            chosen: "cloud/open-router/gpt-5.5",
            from: [model("node/studio/qwen3.8-27b", serving: true)], excluding: nil
        ) == "cloud/open-router/gpt-5.5")
        // Empty is not a pick; it is the "work it out" row.
        #expect(AppModel.escalationTarget(
            chosen: "", from: [model("node/studio/qwen3.8-27b", serving: true)], excluding: nil
        ) == "node/studio/qwen3.8-27b")
        // And nonsense is nothing, rather than a model id the gateway would 400 on.
        #expect(AppModel.escalationTarget(chosen: "gpt-5.5", from: [], excluding: nil) == nil)
    }
}

// MARK: - The streaming paths

@Suite("Verification on the streaming paths", .redirectedConversationStore)
@MainActor
struct VerificationStreamTests {

    private func isolatedModel() -> AppModel {
        BuddyTestStore.redirect()
        return AppModel(settings: .init())
    }

    /// `verifyWithoutEscalating` judges and resolves, and runs nothing.
    @Test func judgingAStreamNamesATargetWithoutUsingIt() async throws {
        let jev = try CapturingServer { _, _ in
            .init(body: jevVerificationBody(.clean.with { $0.answersTheQuestion = 0.05 }))
        }
        defer { jev.stop() }
        let gateway = try untouchedServer("a stream must never escalate")
        defer { gateway.stop() }
        let harness = JevHarness()
        defer { harness.clean() }
        await harness.configure(baseURL: URL(string: "http://127.0.0.1:\(jev.port)")!)
        try await harness.enableVerification()

        let app = isolatedModel()
        let counted = EscalationCount()
        let verifier = testVerifier(
            service: harness.service, target: "node/studio/qwen3.8-27b",
            gateway: GatewayEscalation(
                baseURL: URL(string: "http://127.0.0.1:\(gateway.port)")!, token: "t"
            ),
            escalations: counted
        )

        let judged = try #require(await app.verifyWithoutEscalating(
            prompt: chatPrompt("Why is the sky blue?"), reply: "Ask someone else.",
            truncated: false, using: verifier
        ))
        #expect(judged.verdict.name == "escalate")
        // Resolved so the suggestion can name it — and not called.
        #expect(judged.target == "node/studio/qwen3.8-27b")
        #expect(await counted.calls == 0)
        #expect(gateway.requests.isEmpty)

        // An accept resolves nothing at all: there is nothing to suggest.
        let clean = try CapturingServer { _, _ in .init(body: jevVerificationBody()) }
        defer { clean.stop() }
        let secondHarness = JevHarness()
        defer { secondHarness.clean() }
        await secondHarness.configure(baseURL: URL(string: "http://127.0.0.1:\(clean.port)")!)
        try await secondHarness.enableVerification()
        let fine = try #require(await app.verifyWithoutEscalating(
            prompt: chatPrompt("What is 2 + 2?"), reply: "Four.", truncated: false,
            using: testVerifier(
                service: secondHarness.service, target: "node/studio/qwen3.8-27b", gateway: nil
            )
        ))
        #expect(fine.verdict == .accept)
        #expect(fine.target == nil)
    }

    /// The frame itself: keyed, never escalated, and silent on an accept.
    @Test func theStreamFrameIsKeyedAndCarriesASuggestionNotAModel() async throws {
        let jev = try CapturingServer { _, _ in
            .init(body: jevVerificationBody(.clean.with { $0.isCutOff = 0.95 }))
        }
        defer { jev.stop() }
        let harness = JevHarness()
        defer { harness.clean() }
        await harness.configure(baseURL: URL(string: "http://127.0.0.1:\(jev.port)")!)
        try await harness.enableVerification()

        let app = isolatedModel()
        let verifier = testVerifier(
            service: harness.service, target: "node/studio/qwen3.8-27b", gateway: nil
        )
        let conversation = UUID().uuidString
        let message = UUID().uuidString
        let frame = try #require(await app.streamVerdict(
            prompt: chatPrompt("Explain gradient descent."),
            reply: "Gradient descent works by repeatedly taking a step in the dire",
            // `finish_reason` from the runtime, not a guess by the model.
            metrics: GenerationMetrics(generatedTokens: 64, finishReason: "length"),
            budget: 64, conversationID: conversation, messageID: message,
            using: verifier
        ))
        #expect(frame.verdict == "escalate")
        #expect(frame.reasons == [
            "The reply stops mid-thought and the token budget ran out.",
        ])
        // Never on a stream — the tokens are already on screen.
        #expect(frame.escalatedTo == nil)
        #expect(frame.suggestion?.contains("node/studio/qwen3.8-27b") == true)
        // Keyed, so a verdict that arrives after the stream has closed knows its bubble.
        #expect(frame.conversationID == conversation)
        #expect(frame.messageID == message)

        // An empty reply is not an answer to judge, and costs nothing.
        let before = jev.requests.count
        #expect(await app.streamVerdict(
            prompt: chatPrompt("hi"), reply: "", metrics: GenerationMetrics(), budget: nil,
            using: verifier
        ) == nil)
        #expect(jev.requests.count == before)
    }

    @Test func aCleanStreamSaysNothingAtAll() async throws {
        let jev = try CapturingServer { _, _ in .init(body: jevVerificationBody()) }
        defer { jev.stop() }
        let harness = JevHarness()
        defer { harness.clean() }
        await harness.configure(baseURL: URL(string: "http://127.0.0.1:\(jev.port)")!)
        try await harness.enableVerification()

        let app = isolatedModel()
        // Silence is the accept: a frame saying "nothing is wrong" is noise on a phone.
        #expect(await app.streamVerdict(
            prompt: chatPrompt("What is 2 + 2?"), reply: "Four.",
            metrics: GenerationMetrics(generatedTokens: 3, finishReason: "stop"), budget: 512,
            using: testVerifier(service: harness.service, target: nil, gateway: nil)
        ) == nil)
    }

    /// A verdict is written onto the message, so it outlives the stream that missed it.
    @Test func aVerdictOnAMessageComesBackFromTheTranscript() async throws {
        let app = isolatedModel()
        let summary = await app.createConversation(title: "Lisbon")
        let index = try #require(app.conversations.firstIndex { $0.id.uuidString == summary.id })
        let reply = ChatMessage(role: .assistant, content: "Start in Alfama.")
        app.conversations[index].messages = [
            ChatMessage(role: .user, content: "Three days in Lisbon?"), reply,
        ]
        app.conversations[index].messages[1].verification = ControlAPI.ChatVerdict(
            verdict: "annotate",
            reasons: ["The reply is rated thin."],
            conversationID: summary.id, messageID: reply.id.uuidString
        )

        let detail = try await app.conversation(id: summary.id)
        let assistant = try #require(detail.messages.last)
        #expect(assistant.id == reply.id.uuidString)
        #expect(assistant.verification?.verdict == "annotate")
        #expect(assistant.verification?.reasons == ["The reply is rated thin."])
        // The user's own turn was never judged, so it carries nothing.
        #expect(detail.messages.first?.verification == nil)
    }

    /// The bound on how long a stream waits, in both directions.
    @Test func theStreamTakesAQuickVerdictAndGivesUpOnASlowOne() async throws {
        let quick = Task<Int?, Never> { 7 }
        #expect(await VerdictRelay.result(of: quick, within: .seconds(3)) == 7)

        // Slower than the grace: the stream closes without it…
        let finished = Landing()
        let slow = Task<Int?, Never> {
            try? await Task.sleep(for: .milliseconds(400))
            // Recorded rather than returned, because a cancelled task can still return a
            // value — only the flag can tell the two apart.
            await finished.note(cancelled: Task.isCancelled)
            return 9
        }
        #expect(await VerdictRelay.result(of: slow, within: .milliseconds(50)) == nil)
        // …and the work still finishes, uncancelled, which is what puts the verdict on the
        // message and on /events. Giving up on the wait must never mean giving up on the
        // verdict — that is the half that always matters.
        #expect(await slow.value == 9)
        #expect(await finished.landed == true)
        #expect(await finished.wasCancelled == false)

        // Nothing to report is not the same as being late, and both read as nil here.
        let empty = Task<Int?, Never> { nil }
        #expect(await VerdictRelay.result(of: empty, within: .seconds(3)) == nil)
    }
}
