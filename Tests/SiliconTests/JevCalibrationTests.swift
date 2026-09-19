import Foundation
import Testing
@testable import SiliconControl
@testable import SiliconRuntime
@testable import SiliconUI

// MARK: - Shorthand

private typealias Answer = ControlAPI.SystemOneAnswer
private typealias Floors = ControlAPI.JevCalibration.Floors
private typealias Pair = CalibrationQuestions.Math.Pair

private let defaultFloors = Floors(confidence: 0.6, noulLow: 0.25, noulHigh: 0.75)

private func choice(_ label: String, _ confidence: Double) -> Answer {
    .choice(
        choice: label, confidence: confidence,
        probabilities: [label: confidence, "other": 1 - confidence]
    )
}

private func score(_ value: Double, _ confidence: Double) -> Answer {
    .score(score: value, confidence: confidence, legend: [:], probabilities: [:])
}

private func response(
    _ answers: [String: Answer], provider: String = "local",
    model: String = "Test 1B", inputTokens: Int = 100, latency: Double = 10
) -> ControlAPI.DecideResponse {
    .init(
        model: model, usage: .init(inputTokens: inputTokens, outputTokens: 1),
        answers: answers, provider: provider, latencyMS: latency
    )
}

private func request(_ names: [String]) -> ControlAPI.DecideRequest {
    .init(
        state: .string("A customer was charged twice."),
        questions: Dictionary(uniqueKeysWithValues: names.map { name in
            (name, ControlAPI.SystemOneQuestion(
                type: "noul", instructions: .string("Is \(name) true of the state?")
            ))
        })
    )
}

// MARK: - The policy

@Suite("Decision cascade")
@MainActor
struct DecisionCascadeTests {

    /// The two rules, at their edges. Both boundaries are deliberate and both are the
    /// opposite of what a careless reading would give: a confidence *equal* to the floor is
    /// confident enough, and a noul *equal* to either edge of the band is a confident answer
    /// rather than an uncertain one — the same convention `JevThresholds.noulBand` uses.
    @Test func theFloorIsInclusiveAndTheNoulBandIsNot() {
        // Choice and score: below the floor escalates, at it does not.
        #expect(!DecisionCascade.isUncertain(choice("a", 0.6), floors: defaultFloors))
        #expect(DecisionCascade.isUncertain(choice("a", 0.5999), floors: defaultFloors))
        #expect(!DecisionCascade.isUncertain(score(1.4, 0.6), floors: defaultFloors))
        #expect(DecisionCascade.isUncertain(score(1.4, 0.59), floors: defaultFloors))
        #expect(DecisionCascade.isUncertain(choice("a", 0), floors: defaultFloors))
        #expect(!DecisionCascade.isUncertain(choice("a", 1), floors: defaultFloors))

        // Nouls: uncertain strictly inside the band, confident at and outside both edges.
        for certain in [0.0, 0.1, 0.24, 0.25, 0.75, 0.76, 0.9, 1.0] {
            #expect(
                !DecisionCascade.isUncertain(.noul(certain), floors: defaultFloors),
                "a noul of \(certain) should not be escalated"
            )
        }
        for uncertain in [0.2501, 0.3, 0.5, 0.6, 0.7499] {
            #expect(
                DecisionCascade.isUncertain(.noul(uncertain), floors: defaultFloors),
                "a noul of \(uncertain) should be escalated"
            )
        }

        // And a confident *no* is not mistaken for no confidence, which is the whole reason
        // the noul rule is a band rather than a floor.
        #expect(!DecisionCascade.isUncertain(.noul(0.05), floors: defaultFloors))
        #expect(DecisionCascade.isUncertain(choice("a", 0.05), floors: defaultFloors))
    }

    /// The floors are read from wherever they came from, not baked in: a tighter band
    /// escalates more, a looser one less.
    @Test func theFloorsAreTheOnesHandedIn() {
        let strict = Floors(confidence: 0.95, noulLow: 0.1, noulHigh: 0.9)
        let loose = Floors(confidence: 0.2, noulLow: 0.45, noulHigh: 0.55)
        #expect(DecisionCascade.isUncertain(choice("a", 0.9), floors: strict))
        #expect(!DecisionCascade.isUncertain(choice("a", 0.9), floors: loose))
        #expect(DecisionCascade.isUncertain(.noul(0.2), floors: strict))
        #expect(!DecisionCascade.isUncertain(.noul(0.2), floors: loose))
    }

    @Test func uncertainPicksOutExactlyTheDoubtfulAnswers() {
        let escalate = DecisionCascade.uncertain(
            in: [
                "sure": .noul(0.95),
                "unsure": .noul(0.5),
                "confident-choice": choice("billing", 0.88),
                "shaky-choice": choice("billing", 0.41),
                "confident-score": score(2.0, 0.7),
                "shaky-score": score(1.5, 0.3),
            ],
            floors: defaultFloors
        )
        #expect(escalate == ["unsure", "shaky-choice", "shaky-score"])
    }

    /// The saving the cascade exists for: Jev is paid for the doubtful questions and for
    /// nothing else, and it sees the same state the local lane did.
    @Test func onlyTheUncertainQuestionsAreSent() async throws {
        let asked = request(["sure", "unsure", "alsoUnsure", "alsoSure"])
        var sent: [ControlAPI.DecideRequest] = []

        let result = try await DecisionCascade.run(
            asked,
            floors: defaultFloors,
            jevAvailable: { true },
            local: { _ in
                response([
                    "sure": .noul(0.95),
                    "unsure": .noul(0.5),
                    "alsoUnsure": choice("billing", 0.4),
                    "alsoSure": score(2.0, 0.8),
                ])
            },
            jev: { second in
                sent.append(second)
                return response(
                    ["unsure": .noul(0.12), "alsoUnsure": choice("technical", 0.93)],
                    provider: "typesafe", model: "jev-1.13.0", inputTokens: 900, latency: 240
                )
            }
        )

        #expect(sent.count == 1, "the escalation is one request, not one per question")
        #expect(Set(sent.first?.questions.keys ?? [:].keys) == ["unsure", "alsoUnsure"])
        #expect(sent.first?.state == asked.state)
        // The questions travel verbatim, so Jev is answering the question that was asked
        // rather than a paraphrase of it.
        #expect(sent.first?.questions["unsure"] == asked.questions["unsure"])

        // Jev's answers won where it answered; the local ones stayed where it did not.
        #expect(result.answers["unsure"] == .noul(0.12))
        #expect(result.answers["alsoUnsure"] == choice("technical", 0.93))
        #expect(result.answers["sure"] == .noul(0.95))
        #expect(result.answers["alsoSure"] == score(2.0, 0.8))
    }

    @Test func theResponseSaysWhichLaneAnsweredWhat() async throws {
        let result = try await DecisionCascade.run(
            request(["team", "refund"]),
            floors: defaultFloors,
            jevAvailable: { true },
            local: { _ in
                response(["team": choice("billing", 0.4), "refund": .noul(0.95)])
            },
            jev: { _ in
                response(
                    ["team": choice("technical", 0.93)],
                    provider: "typesafe", model: "jev-1.13.0", inputTokens: 900, latency: 240
                )
            }
        )

        #expect(result.provider == "local+typesafe")
        #expect(result.sources == ["team": "typesafe", "refund": "local"])
        #expect(result.model == "Test 1B + jev-1.13.0")
        // Both lanes were paid for, so both are in the usage.
        #expect(result.usage.inputTokens == 1000)
        #expect(result.latencyMS == 250)
    }

    /// With the feature off, or no key, or the budget spent, `auto` is the local lane it
    /// always was — and nothing is sent anywhere.
    @Test func jevUnavailableIsTheLocalLaneUnchanged() async throws {
        var jevWasAsked = false
        let local = response(["unsure": .noul(0.5)])
        let result = try await DecisionCascade.run(
            request(["unsure"]),
            floors: defaultFloors,
            jevAvailable: { false },
            local: { _ in local },
            jev: { _ in
                jevWasAsked = true
                return response([:], provider: "typesafe")
            }
        )
        #expect(!jevWasAsked)
        #expect(result == local)
        #expect(result.provider == "local")
        #expect(result.sources == nil)
    }

    /// A run where the machine was sure of everything must not even ask whether Jev is
    /// available: that reads the settings file, and on a hot path it should not.
    @Test func aConfidentRunNeverAsksAboutJev() async throws {
        var availabilityChecks = 0
        var jevWasAsked = false
        let result = try await DecisionCascade.run(
            request(["sure"]),
            floors: defaultFloors,
            jevAvailable: {
                availabilityChecks += 1
                return true
            },
            local: { _ in response(["sure": .noul(0.95)]) },
            jev: { _ in
                jevWasAsked = true
                return response([:], provider: "typesafe")
            }
        )
        #expect(availabilityChecks == 0)
        #expect(!jevWasAsked)
        #expect(result.provider == "local")
    }

    /// The local lane has already answered every question. A network blip on the optional
    /// second opinion must not turn a working decision into an error.
    @Test func aFailedEscalationKeepsTheLocalAnswers() async throws {
        struct Nope: Error {}
        let local = response(["unsure": .noul(0.5)])
        let result = try await DecisionCascade.run(
            request(["unsure"]),
            floors: defaultFloors,
            jevAvailable: { true },
            local: { _ in local },
            jev: { _ in throw Nope() }
        )
        #expect(result == local)
        #expect(result.provider == "local")
    }

    /// The local lane failing is a different matter: there is no answer at all, so the
    /// error is the answer.
    @Test func aFailedLocalLaneIsNotSwallowed() async {
        struct Nope: Error {}
        await #expect(throws: Nope.self) {
            _ = try await DecisionCascade.run(
                request(["unsure"]),
                floors: defaultFloors,
                jevAvailable: { true },
                local: { _ in throw Nope() },
                jev: { _ in response([:], provider: "typesafe") }
            )
        }
    }

    /// `local+typesafe` has to mean a Jev answer is actually in there. A reply that came
    /// back without the question in it leaves the response exactly as the local lane made it.
    @Test func anEmptyEscalationIsNotACascade() async throws {
        let local = response(["unsure": .noul(0.5)])
        let result = try await DecisionCascade.run(
            request(["unsure"]),
            floors: defaultFloors,
            jevAvailable: { true },
            local: { _ in local },
            jev: { _ in response([:], provider: "typesafe", model: "jev-1.13.0") }
        )
        #expect(result == local)
        #expect(result.sources == nil)
        #expect(result.model == "Test 1B")
    }

    /// Splicing on its own, including the part that is easy to get wrong: a question Jev
    /// was asked but did not answer keeps the local answer rather than vanishing.
    @Test func splicingKeepsWhatJevDidNotAnswer() {
        let spliced = DecisionCascade.splice(
            local: response(["a": .noul(0.5), "b": .noul(0.5), "c": .noul(0.99)]),
            jev: response(["a": .noul(0.1)], provider: "typesafe", model: "jev-1.13.0"),
            escalated: ["a", "b"]
        )
        #expect(spliced.answers.count == 3)
        #expect(spliced.answers["b"] == .noul(0.5))
        #expect(spliced.sources == ["a": "typesafe", "b": "local", "c": "local"])
    }
}

// MARK: - The arithmetic

@Suite("Calibration arithmetic")
struct CalibrationMathTests {

    private func pair(
        _ local: Answer, _ jev: Answer, expected: JSONContent? = nil, id: String = "case"
    ) -> Pair {
        .init(caseID: id, question: "q", local: local, jev: jev, expected: expected)
    }

    @Test func agreementIsDefinedPerKindAndAtItsEdges() {
        let math = CalibrationQuestions.Math.self

        // Nouls: which side of 0.5, not how close. An uncalibrated 0.93 and a calibrated
        // 0.58 are the same answer; 0.51 and 0.49 are not.
        #expect(math.agree(.noul(0.93), .noul(0.58)) == true)
        #expect(math.agree(.noul(0.51), .noul(0.49)) == false)
        #expect(math.agree(.noul(0.5), .noul(0.5)) == true)
        #expect(math.agree(.noul(0.5), .noul(0.49)) == false)

        // Choices: the label, whatever the confidence behind it.
        #expect(math.agree(choice("billing", 0.99), choice("billing", 0.31)) == true)
        #expect(math.agree(choice("billing", 0.99), choice("technical", 0.99)) == false)

        // Scores: half a level, inclusive.
        #expect(math.agree(score(1.0, 0.9), score(1.5, 0.9)) == true)
        #expect(math.agree(score(1.0, 0.9), score(1.51, 0.9)) == false)
        #expect(math.agree(score(2.0, 0.9), score(1.5, 0.9)) == true)

        // Kinds that cannot be compared are nil, not "disagree" — otherwise they would
        // quietly drag the floor upwards.
        #expect(math.agree(.noul(0.9), choice("a", 0.9)) == nil)
        #expect(math.agree(score(1, 0.9), choice("a", 0.9)) == nil)
    }

    @Test func agreementRowsCountPerKind() {
        let rows = CalibrationQuestions.Math.agreement([
            pair(.noul(0.9), .noul(0.8)),
            pair(.noul(0.9), .noul(0.2)),
            pair(choice("a", 0.9), choice("a", 0.9)),
            pair(choice("a", 0.9), choice("b", 0.9)),
            pair(choice("a", 0.9), choice("a", 0.4)),
            pair(score(1, 0.9), score(1.4, 0.9)),
        ])
        #expect(rows.map(\.kind) == ["noul", "choice", "score"])
        #expect(rows[0].compared == 2 && rows[0].agreed == 1 && rows[0].rate == 0.5)
        #expect(rows[1].compared == 3 && rows[1].agreed == 2)
        #expect(abs(rows[1].rate - 2.0 / 3.0) < 1e-12)
        #expect(rows[2].compared == 1 && rows[2].agreed == 1 && rows[2].rate == 1)
        // A kind nobody asked about is a zero row rather than a missing one, so the report
        // has the same shape every time.
        #expect(CalibrationQuestions.Math.agreement([]).allSatisfy {
            $0.compared == 0 && $0.rate == 0
        })
    }

    /// Ten answers, hand-checkable. Sorted by confidence with their verdicts:
    ///
    ///     0.95 ✓  0.93 ✓  0.90 ✓  0.88 ✓  0.85 ✓  0.80 ✗  0.70 ✓  0.65 ✓  0.55 ✗  0.40 ✗
    ///
    /// Reading down from the bottom: everything (7/10), then ≥0.41 (7/9), ≥0.56 (7/8 =
    /// 0.875), ≥0.66 (6/7), ≥0.71 (5/6), and finally ≥0.81, which drops the 0.80 mistake and
    /// leaves five answers that all agree. So the floor is 0.81 — the *lowest* threshold
    /// that clears 90%, because a higher one would only escalate more and cost more.
    @Test func theConfidenceFloorIsTheLowestThresholdThatClearsTheTarget() {
        let scored = CalibrationMathTests.tenScoredAnswers
        #expect(CalibrationQuestions.Math.confidenceFloor(scored) == 0.81)

        // A lower target stops earlier, at the first threshold that clears it.
        #expect(CalibrationQuestions.Math.confidenceFloor(scored, target: 0.8) == 0.56)
        // A target nothing reaches is nil, not a floor of 1.
        #expect(CalibrationQuestions.Math.confidenceFloor(scored, target: 1.01) == nil)
    }

    /// The sample guard, which is the difference between a threshold and a coincidence:
    /// at 0.81 only five answers are left, so asking for six finds nothing.
    @Test func aThresholdWithTooLittleBehindItIsNotAThreshold() {
        let scored = CalibrationMathTests.tenScoredAnswers
        #expect(CalibrationQuestions.Math.confidenceFloor(scored, minimumSamples: 5) == 0.81)
        #expect(CalibrationQuestions.Math.confidenceFloor(scored, minimumSamples: 6) == nil)
        // And a set smaller than the guard never gets as far as searching.
        #expect(CalibrationQuestions.Math.confidenceFloor(Array(scored.prefix(4))) == nil)
    }

    /// Nouls carry no confidence, so they cannot be thresholded on one. A set of nothing but
    /// nouls has no floor to find.
    @Test func noulsDoNotContributeToTheConfidenceFloor() {
        let nouls = (0..<20).map { index in
            pair(.noul(Double(index) / 20), .noul(Double(index) / 20))
        }
        #expect(CalibrationQuestions.Math.confidenceFloor(nouls) == nil)
        #expect(CalibrationQuestions.Math.bins(nouls).isEmpty)
    }

    /// Five disagreements at local 0.30, 0.45, 0.55, 0.62, 0.70.
    ///
    /// At 90% capture, `ceil(0.9 × 5) = 5` — all of them — so the band has to reach outside
    /// 0.30 and 0.70 on a hundredth grid, strictly: 0.29 to 0.71.
    ///
    /// At 60%, `ceil(0.9 × … )` is `ceil(0.6 × 5) = 3`, and the narrowest window of three is
    /// the middle one — 0.45, 0.55, 0.62 — which needs 0.44 to 0.63, a width of 0.19. The
    /// other two windows are wider: 0.29–0.56 is 0.27, and 0.50–0.71 is 0.21.
    @Test func theNoulBandIsTheNarrowestOneThatCatchesTheMistakes() {
        let pairs = CalibrationMathTests.fiveNoulDisagreements
        let wide = CalibrationQuestions.Math.noulBand(pairs)
        #expect(wide?.low == 0.29)
        #expect(wide?.high == 0.71)

        let narrow = CalibrationQuestions.Math.noulBand(pairs, capture: 0.6)
        #expect(narrow?.low == 0.44)
        #expect(narrow?.high == 0.63)
    }

    @Test func aBandNeedsEnoughDisagreementsToBeWorthPlacing() {
        let two = Array(CalibrationMathTests.fiveNoulDisagreements.prefix(2))
        #expect(CalibrationQuestions.Math.noulBand(two) == nil)
        #expect(CalibrationQuestions.Math.noulBand(two, minimumDisagreements: 2) != nil)
        // Agreement everywhere leaves nothing to catch.
        #expect(CalibrationQuestions.Math.noulBand([
            pair(.noul(0.9), .noul(0.9)), pair(.noul(0.1), .noul(0.2)),
            pair(.noul(0.8), .noul(0.6)), pair(.noul(0.3), .noul(0.4)),
        ]) == nil)
    }

    /// Bins are tenths of the local confidence, half-open except the last, and a noul is not
    /// in any of them.
    @Test func reliabilityBinsAreTenthsOfLocalConfidence() {
        let bins = CalibrationQuestions.Math.bins([
            pair(choice("a", 0.45), choice("a", 0.9)),
            pair(choice("a", 0.42), choice("b", 0.9)),
            pair(choice("a", 0.71), choice("a", 0.9)),
            pair(choice("a", 0.95), choice("a", 0.9)),
            pair(choice("a", 0.91), choice("a", 0.9)),
            pair(choice("a", 0.99), choice("b", 0.9)),
            pair(.noul(0.9), .noul(0.9)),
        ])
        #expect(bins.count == 3, "empty tenths are left out, not reported as zero")
        #expect(bins[0].lower == 0.4 && bins[0].upper == 0.5)
        #expect(bins[0].count == 2 && bins[0].agreed == 1 && bins[0].agreementRate == 0.5)
        #expect(abs(bins[0].meanConfidence - 0.435) < 1e-12)
        #expect(bins[1].lower == 0.7 && bins[1].count == 1 && bins[1].agreementRate == 1)
        #expect(bins[2].lower == 0.9 && bins[2].upper == 1.0)
        #expect(bins[2].count == 3 && bins[2].agreed == 2)
        #expect(abs(bins[2].agreementRate - 2.0 / 3.0) < 1e-12)

        // A perfect 1.0 belongs in the top bin, not in an eleventh one.
        let top = CalibrationQuestions.Math.bins([pair(choice("a", 1), choice("a", 1))])
        #expect(top.count == 1 && top[0].lower == 0.9 && top[0].upper == 1.0)
    }

    /// The column that keeps the reference honest: how each lane did against the hand
    /// labels, which is never allowed to move a floor.
    @Test func handLabelsAreComparedTheSameWayAndReportedSeparately() {
        let math = CalibrationQuestions.Math.self
        #expect(math.matchesExpected(.noul(0.7), .bool(true)) == true)
        #expect(math.matchesExpected(.noul(0.4), .bool(true)) == false)
        #expect(math.matchesExpected(choice("billing", 0.3), .string("billing")) == true)
        #expect(math.matchesExpected(score(1.5, 0.3), .number(1)) == true)
        #expect(math.matchesExpected(score(1.51, 0.3), .number(1)) == false)
        // A label of the wrong shape is skipped rather than counted as a miss.
        #expect(math.matchesExpected(.noul(0.7), .string("yes")) == nil)

        // Both lanes wrong together is exactly the case the caveat is about, and it shows
        // up here as a high agreement rate beside two poor label scores.
        let pairs = [
            pair(choice("a", 0.9), choice("a", 0.9), expected: .string("b")),
            pair(choice("a", 0.9), choice("a", 0.9), expected: .string("b")),
            pair(choice("b", 0.9), choice("b", 0.9), expected: .string("b")),
            pair(choice("c", 0.9), choice("c", 0.9)),
        ]
        #expect(math.overallRate(pairs) == 1)
        let local = math.accuracyAgainstLabels(pairs, lane: \.local)
        let reference = math.accuracyAgainstLabels(pairs, lane: \.jev)
        #expect(local?.compared == 3 && local?.matched == 1)
        #expect(reference?.compared == 3 && reference?.matched == 1)
        #expect(math.accuracyAgainstLabels([pair(.noul(0.9), .noul(0.9))], lane: \.local) == nil)
    }

    // MARK: Fixtures

    /// Ten choice answers, confidence and verdict as laid out in the test above.
    fileprivate static let tenScoredAnswers: [Pair] = [
        (0.95, true), (0.93, true), (0.90, true), (0.88, true), (0.85, true),
        (0.80, false), (0.70, true), (0.65, true), (0.55, false), (0.40, false),
    ].enumerated().map { index, row in
        Pair(
            caseID: "c\(index)", question: "q",
            local: choice("a", row.0),
            jev: choice(row.1 ? "a" : "b", 0.9)
        )
    }

    /// Five noul answers Jev disagreed with, plus two it agreed with — which must not widen
    /// the band, because the band is placed on the mistakes alone.
    fileprivate static let fiveNoulDisagreements: [Pair] = {
        let missed = [0.30, 0.45, 0.55, 0.62, 0.70].enumerated().map { index, local in
            Pair(
                caseID: "m\(index)", question: "q",
                local: .noul(local),
                // Opposite side of 0.5 from the local answer, so this is a disagreement.
                jev: .noul(local >= 0.5 ? 0.02 : 0.98)
            )
        }
        let agreed = [
            Pair(caseID: "a0", question: "q", local: .noul(0.02), jev: .noul(0.1)),
            Pair(caseID: "a1", question: "q", local: .noul(0.98), jev: .noul(0.9)),
        ]
        return missed + agreed
    }()
}

// MARK: - Settings

@Suite("Cascade settings")
struct CascadeSettingsTests {

    @Test func theFloorsShipAtTheDocumentedDefaults() {
        let settings = JevSettings()
        #expect(settings.cascadeFloor == 0.6)
        #expect(settings.cascadeNoulLow == 0.25)
        #expect(settings.cascadeNoulHigh == 0.75)
        #expect(settings.cascadeFloors == Floors(confidence: 0.6, noulLow: 0.25, noulHigh: 0.75))
    }

    @Test func theyRoundTripThroughTheFileAndAreClampedOnTheWayBack() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jev-cascade-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("jev.json")

        var settings = JevSettings()
        settings.cascadeFloor = 0.81
        settings.cascadeNoulLow = 0.29
        settings.cascadeNoulHigh = 0.71
        try settings.save(to: url)
        let reloaded = JevSettings.load(from: url)
        #expect(reloaded.cascadeFloor == 0.81)
        #expect(reloaded.cascadeNoulLow == 0.29)
        #expect(reloaded.cascadeNoulHigh == 0.71)

        // Hand-edited nonsense is clamped rather than trusted. An inverted band would
        // escalate nothing at all, which nobody means to ask for.
        var silly = JevSettings()
        silly.cascadeFloor = 9
        silly.cascadeNoulLow = 0.8
        silly.cascadeNoulHigh = 0.2
        let fixed = silly.normalized()
        #expect(fixed.cascadeFloor == 1)
        #expect(fixed.cascadeNoulLow == 0.2 && fixed.cascadeNoulHigh == 0.8)

        var broken = JevSettings()
        broken.cascadeFloor = .nan
        broken.cascadeNoulLow = -.infinity
        #expect(broken.normalized().cascadeFloor == JevSettings.defaultCascadeFloor)
        #expect(broken.normalized().cascadeNoulLow == JevSettings.defaultCascadeNoulLow)
    }

    /// An older `jev.json`, written before these three existed, reads as the defaults
    /// rather than as zeros — which would escalate nothing and quietly disable the cascade.
    @Test func aFileFromBeforeTheCascadeReadsAsTheDefaults() throws {
        let data = Data(#"{"enabled":true,"model":"jev-1.13.0","cacheMinutes":10}"#.utf8)
        let settings = try JSONDecoder().decode(JevSettings.self, from: data)
        #expect(settings.cascadeFloor == JevSettings.defaultCascadeFloor)
        #expect(settings.cascadeNoulLow == JevSettings.defaultCascadeNoulLow)
        #expect(settings.cascadeNoulHigh == JevSettings.defaultCascadeNoulHigh)
    }

    /// The price the "about N cents" warning is computed from is the price the ledger bills
    /// at — one constant, in the target the MCP bridge can reach.
    @Test func theQuotedPriceIsTheBilledPrice() {
        #expect(JevLedger.usdPerMillionInputTokens == ControlAPI.JevPricing.usdPerMillionInputTokens)
        #expect(JevLedger.cost(inputTokens: 1_000_000) == 0.042)
        #expect(ControlAPI.JevCalibration.estimatedCents() >= 1)
        // A hundred times the set costs more than one cent, so the estimate tracks the size
        // of the run rather than being a constant with a number in it.
        #expect(ControlAPI.JevCalibration.estimatedCents(cases: 4000)
            > ControlAPI.JevCalibration.estimatedCents())
    }
}

// MARK: - The set

@Suite("The calibration set")
struct CalibrationSetTests {

    @Test func everyBuiltInCaseIsWellFormedAndUniquelyNamed() throws {
        let cases = CalibrationQuestions.builtIn
        #expect(cases.count == ControlAPI.JevCalibration.builtInCaseCount)
        #expect(Set(cases.map(\.id)).count == cases.count)
        #expect(Set(cases.map(\.topic)) == ["routing", "triage", "safety", "sentiment"])
        for item in cases {
            try item.validate()
            #expect(!item.questions.isEmpty)
            // Every question carries a hand label, and of the right shape for its kind —
            // otherwise the column that keeps Jev honest has holes in it.
            for (name, question) in item.questions {
                let label = try #require(
                    item.expected?[name], "\(item.id).\(name) has no expected answer"
                )
                switch question.type {
                case "noul": #expect(label.boolValue != nil, "\(item.id).\(name)")
                case "choice":
                    let wanted = try #require(label.stringValue, "\(item.id).\(name)")
                    #expect(
                        question.criteria?.objectValue?[wanted] != nil,
                        "\(item.id).\(name) expects \"\(wanted)\", which is not an option"
                    )
                default:
                    let level = try #require(label.numberValue, "\(item.id).\(name)")
                    let levels = question.criteria?.arrayValue?.count ?? 0
                    #expect(level >= 0 && Int(level) < levels, "\(item.id).\(name)")
                }
            }
        }
        // All three kinds are exercised, and none of them only once — a floor measured on
        // two choices would be a floor measured on nothing.
        let kinds = cases.flatMap { $0.questions.values.map(\.type) }
        for kind in ["noul", "choice", "score"] {
            #expect(kinds.filter { $0 == kind }.count >= 15, "too few \(kind) questions")
        }
    }

    /// The set is what the "about N cents" warning is quoted from, so its real size has to
    /// stay near the constant the MCP bridge prints.
    @Test func theQuotedSizeMatchesTheRealOne() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try CalibrationQuestions.builtIn
            .map { try encoder.encode($0.request).count }
            .reduce(0, +) / CalibrationQuestions.builtIn.count
        // One token per byte is the pessimistic proxy the budget uses, so the quoted
        // per-case figure should be at or above what a case actually weighs.
        #expect(bytes <= ControlAPI.JevCalibration.estimatedInputTokensPerCase,
                "a case is \(bytes) bytes; the quote assumes \(ControlAPI.JevCalibration.estimatedInputTokensPerCase)")
    }

    @Test func casesOfYourOwnAreAddedAndBadOnesAreNoted() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jev-cases-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("jev-calibration.json")

        // A file that is not there is not an error.
        #expect(CalibrationQuestions.userCases(at: url).cases.isEmpty)
        #expect(CalibrationQuestions.userCases(at: url).notes.isEmpty)

        let mine = CalibrationQuestions.Case(
            id: "mine-1", topic: "routing",
            state: .string("Draw a map of the office."),
            questions: ["image": .init(type: "noul", instructions: .string("This asks for a picture."))],
            expected: ["image": .bool(true)]
        )
        try CalibrationQuestions.addUserCase(mine, at: url)
        #expect(CalibrationQuestions.userCases(at: url).cases == [mine])
        // Added twice is still once: the id is the identity.
        try CalibrationQuestions.addUserCase(mine, at: url)
        #expect(CalibrationQuestions.userCases(at: url).cases.count == 1)

        let both = CalibrationQuestions.allCases(userCasesAt: url)
        #expect(both.cases.count == CalibrationQuestions.builtIn.count + 1)
        #expect(both.cases.last == mine)

        // An id that shadows a built-in case is refused with a note rather than silently
        // replacing it, and a malformed one names itself.
        let clash = CalibrationQuestions.Case(
            id: CalibrationQuestions.builtIn[0].id, topic: "routing",
            state: .string("x"),
            questions: ["q": .init(type: "noul", instructions: .string("Is it x?"))]
        )
        let empty = CalibrationQuestions.Case(
            id: "empty", topic: "routing", state: .string("x"), questions: [:]
        )
        let encoder = JSONEncoder()
        try encoder.encode([mine, clash, empty]).write(to: url)
        let reread = CalibrationQuestions.userCases(at: url)
        #expect(reread.cases.map(\.id) == ["mine-1"])
        #expect(reread.notes.count == 2)
        #expect(reread.notes.contains { $0.contains(clash.id) })
        #expect(reread.notes.contains { $0.contains("empty") })

        // A file that is not calibration cases at all is a note, not a crash — the built-in
        // set is still worth measuring.
        try Data(#"{"something":"else"}"#.utf8).write(to: url)
        #expect(CalibrationQuestions.userCases(at: url).cases.isEmpty)
        #expect(CalibrationQuestions.userCases(at: url).notes.count == 1)
    }
}

// MARK: - Keeping the result

@Suite("Calibration persistence")
struct CalibrationPersistenceTests {

    private func result(modelID: String, confidence: Double = 0.81) -> ControlAPI.JevCalibration {
        .init(
            modelID: modelID, modelName: "Test 1B", jevModel: "jev-1.13.0",
            date: ControlAPI.timestamp(Date()),
            cases: 40, builtInCases: 40, userCases: 0, comparisons: 80,
            agreement: [], overallAgreementRate: 0.85,
            floors: .init(confidence: confidence, noulLow: 0.29, noulHigh: 0.71),
            confidenceFloorMeasured: true, noulBandMeasured: true, bins: [],
            inputTokens: 30_000, estimatedUSD: 0.00126
        )
    }

    @Test func aResultSurvivesTheFileAndIsOwnerOnly() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jev-calib-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store/local-calibration.json")

        #expect(CalibrationQuestions.lastResult(at: url) == nil)
        let written = result(modelID: "qwen-30b")
        try CalibrationQuestions.save(written, to: url)
        #expect(CalibrationQuestions.lastResult(at: url) == written)

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: url.deletingLastPathComponent().path
        )
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)

        // Rubbish in the file is "no calibration", not a crash.
        try Data("not json".utf8).write(to: url)
        #expect(CalibrationQuestions.lastResult(at: url) == nil)
    }

    /// The point of recording which model was measured: a threshold found on one model says
    /// nothing about another's confidence, so it is not carried over.
    @Test func floorsApplyOnlyToTheModelTheyWereMeasuredOn() {
        let settings = Floors(confidence: 0.6, noulLow: 0.25, noulHigh: 0.75)
        let measured = result(modelID: "qwen-30b")

        #expect(CalibrationQuestions.floors(
            forModel: "qwen-30b", calibration: measured, settings: settings
        ) == measured.floors)
        #expect(CalibrationQuestions.floors(
            forModel: "llama-4b", calibration: measured, settings: settings
        ) == settings)
        #expect(CalibrationQuestions.floors(
            forModel: nil, calibration: measured, settings: settings
        ) == settings)
        #expect(CalibrationQuestions.floors(
            forModel: "qwen-30b", calibration: nil, settings: settings
        ) == settings)
    }

    @Test func theStoreReadsOnceAndFollowsASave() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jev-calib-store-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("local-calibration.json")
        let store = LocalCalibrationStore()

        #expect(await store.result(at: url) == nil)
        // Written behind the store's back: the cached "none" is what it keeps, which is the
        // whole point of caching it.
        try CalibrationQuestions.save(result(modelID: "qwen-30b"), to: url)
        #expect(await store.result(at: url) == nil)
        await store.forget()
        #expect(await store.result(at: url)?.modelID == "qwen-30b")

        // A save through the store updates what it hands out without a re-read.
        try await store.save(result(modelID: "llama-4b", confidence: 0.5), to: url)
        #expect(await store.result(at: url)?.modelID == "llama-4b")
        #expect(CalibrationQuestions.lastResult(at: url)?.modelID == "llama-4b")
    }
}

// MARK: - End to end

@Suite("Calibration end to end")
struct CalibrationRunTests {

    /// Three cases, one of each question kind, so the report has a row for each.
    static let cases: [CalibrationQuestions.Case] = [
        .init(
            id: "e2e-noul", topic: "triage",
            state: .string("I was charged twice."),
            questions: ["refund": .init(
                type: "noul", instructions: .string("The customer wants money back.")
            )],
            expected: ["refund": .bool(true)]
        ),
        .init(
            id: "e2e-choice", topic: "triage",
            state: .string("The app closes as soon as I open it."),
            questions: ["team": .init(
                type: "choice", instructions: .string("Which team?"),
                criteria: .object(["billing": .null, "technical": .null])
            )],
            expected: ["team": .string("billing")]
        ),
        .init(
            id: "e2e-score", topic: "triage",
            state: .string("How do I change the language?"),
            questions: ["urgency": .init(
                type: "score", instructions: .string("How soon does this need a reply?"),
                criteria: .array([.string("Days"), .string("This week"), .string("Today")])
            )],
            expected: ["urgency": .number(0)]
        ),
    ]

    /// A whole run against two loopback servers: a fake llama-server that answers with
    /// canned `top_logprobs`, and a fake TypeSafe that answers whatever it is asked.
    @Test func runsBothLanesAgainstFakeServersAndReportsWhatItFound() async throws {
        let llama = try CapturingServer { _ in
            // Letter A at about 95%, B at about 5%: one confident answer, whatever the
            // question, which is enough to exercise the whole pipe.
            """
            {"choices":[{"message":{"content":"A"},"logprobs":{"content":[{"token":"A","logprob":-0.05,
              "top_logprobs":[{"token":"A","logprob":-0.05},{"token":"B","logprob":-3.0}]}]}}],
             "usage":{"prompt_tokens":40,"completion_tokens":1}}
            """
        }
        defer { llama.stop() }
        let typeSafe = try CapturingServer { recorded in Self.jevAnswer(to: recorded.body) }
        defer { typeSafe.stop() }

        let harness = JevHarness()
        defer { harness.clean() }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        await harness.configure(
            baseURL: URL(string: "http://127.0.0.1:\(typeSafe.port)")!, session: session
        )
        try await harness.service.update { settings in
            settings.enabled = true
            settings.features[.calibration] = true
            // Two identical questions in this set would otherwise be answered from the
            // cache, and a calibration run must actually ask.
            settings.cacheMinutes = 0
        }

        let decider = LocalDecider(
            endpoint: URL(string: "http://127.0.0.1:\(llama.port)")!, modelName: "Test 1B"
        )
        let service = harness.service
        let result = await CalibrationQuestions.calibrate(
            cases: Self.cases,
            context: .init(
                localModelID: "test-1b-q4", localModelName: "Test 1B",
                jevModel: "jev-1.13.0",
                fallbackFloors: .init(confidence: 0.6, noulLow: 0.25, noulHigh: 0.75),
                builtInCount: 0,
                now: Date(timeIntervalSince1970: 1_789_000_000)
            ),
            local: { try await decider.decide($0) },
            jev: { asked in
                try await service.ask(
                    .calibration, state: asked.state, questions: asked.questions
                )
            }
        )

        #expect(result.cases == 3)
        #expect(result.comparisons == 3)
        #expect(result.modelID == "test-1b-q4")
        #expect(result.date.hasPrefix("2026-"))
        // One request per case at Jev, carrying that case's questions — not one per
        // question, and not one for the lot.
        #expect(typeSafe.requests.count == 3)
        #expect(llama.requests.count == 3)

        // The fake local model always picks letter A, so it answers yes, billing and level
        // 0; the fake Jev answers no, technical and level 2. All three disagree.
        #expect(result.overallAgreementRate == 0)
        #expect(result.agreement.allSatisfy { $0.compared == 1 && $0.agreed == 0 })
        // Nothing agrees, so neither search can find anything and both floors fall back.
        #expect(!result.confidenceFloorMeasured)
        #expect(!result.noulBandMeasured)
        #expect(result.floors == .init(confidence: 0.6, noulLow: 0.25, noulHigh: 0.75))
        #expect(result.notes.contains { $0.contains("default floor") })
        #expect(result.notes.contains { $0.contains("Jev is the reference") })
        // Billed from the fake server's own usage figures.
        #expect(result.inputTokens == 3 * 120)
        #expect(abs(result.estimatedUSD - JevLedger.cost(inputTokens: 360)) < 1e-12)
        // Two confident local answers out of two that have a confidence, and the bins say so.
        #expect(result.bins.count == 1 && result.bins[0].lower == 0.9)
    }

    /// A case that falls over on one lane is dropped with a note. Thirty-nine good answers
    /// are worth more than a run that threw them away over the fortieth.
    @Test func aCaseThatFailsIsNotedRatherThanFatal() async {
        struct Nope: Error, LocalizedError {
            var errorDescription: String? { "the server said no" }
        }
        let result = await CalibrationQuestions.calibrate(
            cases: Self.cases,
            context: .init(
                localModelID: "m", localModelName: "M", jevModel: "jev-1.13.0",
                fallbackFloors: .init(confidence: 0.6, noulLow: 0.25, noulHigh: 0.75),
                builtInCount: 0
            ),
            local: { asked in
                guard asked.questions["team"] == nil else { throw Nope() }
                return .init(
                    model: "M", usage: .init(inputTokens: 10, outputTokens: 1),
                    answers: asked.questions.keys.reduce(into: [:]) { $0[$1] = .noul(0.9) }
                )
            },
            jev: { asked in
                .init(
                    model: "jev-1.13.0", usage: .init(inputTokens: 100, outputTokens: 1),
                    answers: asked.questions.keys.reduce(into: [:]) { $0[$1] = .noul(0.8) }
                )
            }
        )
        #expect(result.cases == 2)
        #expect(result.notes.contains { $0.contains("e2e-choice") && $0.contains("said no") })
        // The two that ran still produced a report.
        #expect(result.comparisons == 2)
        #expect(result.overallAgreementRate == 1)
    }

    /// Builds a TypeSafe answer for whatever was asked, so the fixture does not have to know
    /// the case set. Every answer is the opposite of the one the fake local model gives —
    /// which always picks letter A, and so the first option — so that every case disagrees:
    /// *no* for a noul, the last label for a choice, the top level for a score.
    static func jevAnswer(to body: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let questions = object["questions"] as? [String: [String: Any]]
        else { return #"{"model":"jev-1.13.0","usage":{"input_tokens":0,"output_tokens":0},"answers":{}}"# }

        var answers: [String: Any] = [:]
        for (name, question) in questions {
            switch question["type"] as? String {
            case "choice":
                let labels = (question["criteria"] as? [String: Any])?.keys.sorted() ?? []
                answers[name] = [
                    "type": "choice", "choice": labels.last ?? "",
                    "confidence": 0.88,
                    "probabilities": Dictionary(
                        uniqueKeysWithValues: labels.map { ($0, 1.0 / Double(labels.count)) }
                    ),
                ]
            case "score":
                let levels = (question["criteria"] as? [Any])?.count ?? 1
                answers[name] = [
                    "type": "score", "score": Double(levels - 1), "confidence": 0.77,
                    "legend": [:], "probabilities": [:],
                ]
            default:
                answers[name] = ["type": "noul", "noul": 0.09]
            }
        }
        let payload: [String: Any] = [
            "model": "jev-1.13.0",
            "usage": ["input_tokens": 120, "output_tokens": 1],
            "answers": answers,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Live

/// The only test here that spends money. Three cases, so it costs a fraction of a cent, and
/// it never prints the key.
@Suite("Calibration, live")
struct CalibrationLiveTests {

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SILICON_JEV_LIVE"] == "1"))
    func threeCasesAgainstTheRealJev() async throws {
        let key = try #require(
            ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"],
            "SILICON_JEV_LIVE=1 needs TYPESAFE_API_KEY."
        )
        let harness = JevHarness()
        defer { harness.clean() }
        await harness.configure(key: key, baseURL: SystemOneClient.typeSafeBaseURL)
        try await harness.service.update { settings in
            settings.enabled = true
            settings.features[.calibration] = true
            settings.cacheMinutes = 0
        }

        // Jev answers both lanes here: there is no llama-server in a test run, so the
        // "local" lane is Jev asked a second time. What this proves is the wire — that the
        // real service accepts these cases and that the arithmetic runs on real answers.
        let service = harness.service
        let ask: (ControlAPI.DecideRequest) async throws -> ControlAPI.DecideResponse = { asked in
            try await service.ask(
                .calibration, state: asked.state, questions: asked.questions
            )
        }
        let result = await CalibrationQuestions.calibrate(
            cases: Array(CalibrationQuestions.builtIn.prefix(3)),
            context: .init(
                localModelID: "live", localModelName: "Live",
                jevModel: JevService.pinnedModel,
                fallbackFloors: JevSettings().cascadeFloors,
                builtInCount: 3
            ),
            local: ask,
            jev: ask
        )

        #expect(result.cases == 3)
        #expect(result.comparisons == 6)
        #expect(result.inputTokens > 0)
        // Jev against itself on the same questions should agree with itself.
        #expect(result.overallAgreementRate > 0.9)
        let printable = "\(result.summary) \(result.notes.joined(separator: " "))"
        #expect(!printable.contains(key), "the key must never reach a test report")
    }
}
