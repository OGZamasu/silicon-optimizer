import Foundation
import SiliconControl
import SiliconRuntime

// MARK: - Temporary

/// Stand-ins for the accessors the Jev foundation is adding under review.
///
/// This whole file is scaffolding. The foundation branch is gaining typed accessors on
/// `DecideResponse` and a noul band on `JevThresholds`; this feature is written against those
/// signatures, and until they land it needs *something* to compile. When they arrive, delete
/// this file — the compiler will insist, because the names will be ambiguous, which is the
/// point: a shim that can be forgotten is a shim that gets shipped.
///
/// Nothing here is a design decision. Each one is the smallest thing that behaves the way the
/// real accessor is specified to behave.

/// An answer that is missing, or is not the kind of answer the caller asked for.
public struct JevAnswerError: Error, LocalizedError, Equatable {
    public var name: String
    public var reason: String

    public var errorDescription: String? { "Answer \"\(name)\": \(reason)" }
}

extension ControlAPI.DecideResponse {

    public func noul(_ name: String) throws -> Double {
        guard let answer = answers[name] else {
            throw JevAnswerError(name: name, reason: "no answer came back.")
        }
        guard case .noul(let probability) = answer else {
            throw JevAnswerError(name: name, reason: "answered as a \(answer.type), not a noul.")
        }
        return probability
    }

    public func choice(
        _ name: String
    ) throws -> (choice: String, confidence: Double, probabilities: [String: Double]) {
        guard let answer = answers[name] else {
            throw JevAnswerError(name: name, reason: "no answer came back.")
        }
        guard case .choice(let choice, let confidence, let probabilities) = answer else {
            throw JevAnswerError(name: name, reason: "answered as a \(answer.type), not a choice.")
        }
        return (choice, confidence, probabilities)
    }

    public func score(
        _ name: String
    ) throws -> (
        score: Double, confidence: Double, probabilities: [String: Double],
        legend: [String: JSONContent]
    ) {
        guard let answer = answers[name] else {
            throw JevAnswerError(name: name, reason: "no answer came back.")
        }
        guard case .score(let score, let confidence, let legend, let probabilities) = answer else {
            throw JevAnswerError(name: name, reason: "answered as a \(answer.type), not a score.")
        }
        return (score, confidence, probabilities, legend)
    }
}

extension JevThresholds {
    /// Where a noul's probability lands on a three-way gate. A noul carries no confidence of
    /// its own, so the band comes from the probability itself: near one end it is an answer,
    /// in the middle it is "I don't know" wearing a number.
    public static func noulBand(_ probability: Double, yes: Double, no: Double) -> JevBand {
        if probability >= yes || probability <= no { return .act }
        return .escalate
    }
}
