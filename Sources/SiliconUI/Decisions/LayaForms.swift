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
/// A tool call about to run — with the request, the goal and the results it is judged
/// against — a reply being checked and a prompt whose safety is being read go whole or not
/// at all, because an answer about part of one can wave through the part that was cut.
/// Whatever still does not fit is refused by the sidecar, and the router asks the next lane.
///
/// Jev and the loaded model are not affected: they get every request as the feature wrote it.
enum LayaForms {

    typealias Questions = [String: ControlAPI.SystemOneQuestion]

    static func form(
        _ feature: JevFeature, state: JSONContent, questions: Questions,
        keeping: Set<String> = []
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
            let questions = LayaBudget.compact(
                ranked(feature, state: state, questions: questions, keeping: keeping)
            )
            let (structure, subject) = trimmed(feature, state: state, questions: questions)
            return (
                LayaBudget.shortened(structure, toFit: questions, protecting: subject),
                questions
            )
        }
    }

    /// Where the choice is over a list the checkpoint cannot name in full, which part of it
    /// is asked about rather than the question being dropped for the tail.
    ///
    /// `keeping` goes in first — the owner's default model, which a routing question must be
    /// able to answer with. Then a recommendation takes its list in rank order, best first.
    /// Routing's list is ordered by where a model runs — this Mac, the swarm, providers — so
    /// taking it from the top would fill the budget with this Mac's models on any Mac with
    /// about eight, and Laya could never send a request to the swarm or a provider however
    /// hard it was. So it is taken a model from each place in turn, each place in list order.
    static func ranked(
        _ feature: JevFeature, state: JSONContent, questions: Questions,
        keeping: Set<String> = []
    ) -> Questions {
        let (choice, list, key): (String, String, String)
        switch feature {
        case .routing: (choice, list, key) = ("best_model", "candidates", "option")
        case .recommendation: (choice, list, key) = ("best_for_task", "models_available", "id")
        default: return questions
        }
        guard let question = questions[choice],
              let items = state.objectValue?[list]?.arrayValue
        else { return questions }
        let names = items.compactMap { $0.objectValue?[key]?.stringValue }
        var order = names
        if feature == .routing {
            var places: [String] = []
            var byPlace: [String: [String]] = [:]
            for item in items {
                guard let name = item.objectValue?[key]?.stringValue else { continue }
                let place = self.place(item.objectValue?["runs_on"]?.stringValue)
                if byPlace[place] == nil { places.append(place) }
                byPlace[place, default: []].append(name)
            }
            order = []
            for turn in 0..<(byPlace.values.map(\.count).max() ?? 0) {
                for place in places where turn < byPlace[place]!.count {
                    order.append(byPlace[place]![turn])
                }
            }
        }
        order = names.filter(keeping.contains) + order.filter { !keeping.contains($0) }
        var narrowed = questions
        narrowed[choice] = LayaBudget.keepingFirst(question, in: order)
        return narrowed
    }

    /// This Mac, the swarm, or a provider, from a routing candidate's `runs_on`.
    private static func place(_ runsOn: String?) -> String {
        switch runsOn {
        case RoutingCandidate.Placement.thisMac.describedAs: "this Mac"
        case RoutingCandidate.Placement.node("").describedAs: "swarm"
        default: "provider"
        }
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
            // Nothing here is only supporting text. The call is judged against the request
            // and the goal — a cut can take "…but don't push" out of either — and against
            // the recent results, where an injected instruction is exactly what one question
            // looks for, in whichever result carried it. So the state goes whole: if it does
            // not fit, the sidecar refuses and the person is asked, as before any of this.
            return (.object(fields), Set(fields.keys))
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
