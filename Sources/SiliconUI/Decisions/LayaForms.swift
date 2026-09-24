import Foundation
import SiliconControl
import SiliconRuntime

/// Each ability's request, in the form a Laya checkpoint can read whole.
///
/// The English checkpoint reads 512 tokens: 192 of question and what is left of state. The
/// abilities' requests were written for Jev, which reads tens of thousands, and most of them
/// run to several times that — a routing state with eight candidates is about 900 tokens.
/// laya-mlx used to cut them silently; the sidecar now refuses instead, so without these
/// forms Laya would answer almost nothing the app asks it.
///
/// Every form follows one rule: what the questions *judge* is sent whole, and what merely
/// supports the judgment is shortened. A state that repeats what the questions' options
/// already say — every candidate's traits, every tool's description — loses the repeat;
/// free text around the subject is cut to its head and tail; the subject itself never is.
/// A tool call about to run, a reply being checked and a prompt whose safety is being read
/// go whole or not at all, because an answer about part of one can wave through the part
/// that was cut. Whatever still does not fit is refused by the sidecar, and the router asks
/// the next lane.
///
/// Jev and the loaded model are not affected: they get every request as the feature wrote it.
enum LayaForms {

    typealias Questions = [String: ControlAPI.SystemOneQuestion]

    static func form(
        _ feature: JevFeature, state: JSONContent, questions: Questions
    ) -> (state: JSONContent, questions: Questions) {
        switch feature {
        case .decideTool:
            // The caller's own state and questions, as asked: shortening them would answer
            // something the caller did not ask. One too long is refused with the reason.
            return (state, questions)
        case .calibration:
            // The labelled cases are measured as they are written; only the questions are
            // held to the checkpoint's budget, the same as every ability's.
            return (state, LayaBudget.compact(questions))
        default:
            let questions = LayaBudget.compact(ranked(feature, state: state, questions: questions))
            let (structure, subject) = trimmed(feature, state: state, questions: questions)
            return (
                LayaBudget.shortened(structure, toFit: questions, protecting: subject),
                questions
            )
        }
    }

    /// Where the choice is over a ranked list — routing's shortlist, this Mac first; the
    /// recommendation's, best first — the checkpoint is asked about as much of the head of
    /// it as it can name, rather than the question being dropped for the tail.
    static func ranked(
        _ feature: JevFeature, state: JSONContent, questions: Questions
    ) -> Questions {
        let (choice, list, key): (String, String, String)
        switch feature {
        case .routing: (choice, list, key) = ("best_model", "candidates", "option")
        case .recommendation: (choice, list, key) = ("best_for_task", "models_available", "id")
        default: return questions
        }
        guard let question = questions[choice],
              let order = labels(state.objectValue?[list], key: key)?.arrayValue
        else { return questions }
        var narrowed = questions
        narrowed[choice] = LayaBudget.keepingFirst(question, in: order.compactMap(\.stringValue))
        return narrowed
    }

    /// The state with what repeats the questions taken out, and the keys that are the
    /// subject of the questions — never shortened.
    static func trimmed(
        _ feature: JevFeature, state: JSONContent, questions: Questions
    ) -> (JSONContent, Set<String>) {
        guard case .object(var fields) = state else { return (state, []) }
        switch feature {
        case .routing:
            // Every candidate's traits are in `best_model`'s options already, so the list
            // is only the names of the ones being asked about.
            fields["candidates"] = asked(fields["candidates"], key: "option", by: questions["best_model"])
            return (.object(fields), [])
        case .mediaRouting:
            // The prompt is what the adult-content and named-person gates read: whole.
            fields["candidates"] = asked(fields["candidates"], key: "id", by: questions["model"])
            return (.object(fields), ["request"])
        case .skillSelection:
            // `available` repeats the choice's options, and the second call's entries are
            // described in their own questions. The pruning call has neither.
            fields["available"] = nil
            return (.object(fields), ["turn", "latest_turn"])
        case .recommendation:
            fields["models_available"] = asked(
                fields["models_available"], key: "id", by: questions["best_for_task"]
            )
            return (.object(fields), [])
        case .guardrails:
            // The newest result is the one a call is most likely to follow from.
            if let results = fields["recent_tool_results"]?.arrayValue, let last = results.last {
                fields["recent_tool_results"] = .array([last])
            }
            return (.object(fields), [
                "tool_call", "working_directory", "paths_outside_working_directory",
                "known_paid_endpoints_named",
            ])
        case .verification:
            // A reply cut to its head and tail reads as cut off and as not answering — two of
            // the failures being checked for — and a flagged reply is re-run, perhaps paid.
            return (.object(fields), ["reply", "message"])
        case .decideTool, .calibration:
            return (state, [])
        }
    }

    /// A list of objects, as the one field of each that names it.
    private static func labels(_ list: JSONContent?, key: String) -> JSONContent? {
        guard let items = list?.arrayValue else { return list }
        return .array(items.compactMap { $0.objectValue?[key] })
    }

    /// The names from a list that `choice` still asks about, in the list's order — nothing
    /// when the choice is not asked at all.
    private static func asked(
        _ list: JSONContent?, key: String, by choice: ControlAPI.SystemOneQuestion?
    ) -> JSONContent? {
        guard let options = choice?.criteria?.objectValue,
              let names = labels(list, key: key)?.arrayValue
        else { return nil }
        return .array(names.filter { $0.stringValue.map { options[$0] != nil } ?? false })
    }
}
