import Foundation
import SiliconControl

/// What a Laya checkpoint can read, estimated on this side of the pipe, and the form a request
/// takes to fit it.
///
/// laya-mlx 0.1.0 builds every question the same way (`common.build_prefix`): the question's
/// own text, then each option as a mask token and at most 48 tokens of "label: description",
/// the whole prefix held to `head_max_len` — 192 — by cutting the question's text first and
/// then every option alike. The state gets what is left of the context. It cuts all three
/// silently, and answers about what is left as confidently as ever. The sidecar measures with
/// the checkpoint's own tokenizer and refuses what would be cut; this estimates the same
/// arithmetic so the app can send a Laya lane a form that fits in the first place.
///
/// The estimate counts GPT-2-style pre-tokens — runs of letters, runs of digits, runs of
/// punctuation — which a BPE tokenizer can only split further, and adds headroom on top. It
/// decides nothing on its own: a form that still does not fit is refused by the sidecar, which
/// counts for real.
public enum LayaBudget {

    /// `head_max_len`: the most a question and its options may take.
    public static let headTokens = 192
    /// The most one option may take, its mask token aside.
    public static let optionTokens = 48
    /// The context every form is made to fit: the smallest of the three checkpoints', so a
    /// form fits whichever the owner has chosen.
    public static var contextTokens: Int {
        LayaCheckpoint.allCases.map(\.contextTokens).min() ?? 512
    }
    /// Headroom on every count. The stand-in came within about 6% of the English
    /// checkpoint's tokenizer on routing states; a quarter covers JSON punctuation, which a
    /// real vocabulary splits more finely than one pre-token.
    static let headroom = 1.25
    /// What a question's own text is always left, however many options it has.
    static let minimumQuestionTokens = 32

    // MARK: Counting

    private static let pretoken = try! NSRegularExpression(
        pattern: #" ?\p{L}+|\p{N}+| ?[^\s\p{L}\p{N}]+|\s+"#
    )

    /// Estimated tokens in `text`, headroom included.
    public static func tokens(_ text: String) -> Int {
        let count = pretoken.numberOfMatches(
            in: text, range: NSRange(text.startIndex..., in: text)
        )
        return Int((Double(count) * headroom).rounded(.up))
    }

    /// The text the checkpoint reads for a state: laya-mlx passes a string through and
    /// serialises anything else with Python's `json.dumps`, keys in the order they arrive —
    /// sorted, as `LayaSidecar` sends them.
    public static func text(of state: JSONContent) -> String {
        if case .string(let text) = state { return text }
        return python(state)
    }

    /// Python's `json.dumps` with its default separators and `ensure_ascii=False`.
    static func python(_ value: JSONContent) -> String {
        switch value {
        case .null: return "null"
        case .bool(let flag): return flag ? "true" : "false"
        case .number(let number):
            if number.rounded() == number, abs(number) < 1e15 { return String(Int64(number)) }
            return String(number)
        case .string(let text): return quoted(text)
        case .array(let values): return "[" + values.map(python).joined(separator: ", ") + "]"
        case .object(let fields):
            return "{" + fields.keys.sorted().map {
                quoted($0) + ": " + python(fields[$0]!)
            }.joined(separator: ", ") + "}"
        }
    }

    private static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    // MARK: A question, as laya-mlx builds it

    /// The question's own text: a string as it is, anything else as `json.dumps` of it.
    static func instructionText(_ question: ControlAPI.SystemOneQuestion) -> String {
        guard let instructions = question.instructions else { return "" }
        if case .string(let text) = instructions { return text }
        return python(instructions)
    }

    /// `render_options`: what each option reads as, in the order laya-mlx lists them.
    static func options(_ question: ControlAPI.SystemOneQuestion) -> [String] {
        func render(_ value: JSONContent) -> String {
            if case .string(let text) = value { return text }
            return python(value)
        }
        switch question.type {
        case "choice":
            let labels = question.criteria?.objectValue ?? [:]
            return labels.keys.sorted().map { label in
                switch labels[label]! {
                case .null, .string(""): label
                case let value: "\(label): \(render(value))"
                }
            }
        case "score":
            return (question.criteria?.arrayValue ?? []).enumerated().map {
                "level \($0.offset): \(render($0.element))"
            }
        default:
            let criteria = question.criteria?.objectValue ?? [:]
            func side(_ key: String, _ fallback: String) -> String {
                guard let value = criteria[key], !value.isNull, value != .string("") else {
                    return fallback
                }
                return render(value)
            }
            return [
                "false: " + side("false", "no, the statement does not hold"),
                "true: " + side("true", "yes, the statement holds"),
            ]
        }
    }

    /// Tokens the question takes ahead of the state, and whether laya-mlx would cut any of
    /// it to get there.
    public static func prefix(
        _ question: ControlAPI.SystemOneQuestion
    ) -> (tokens: Int, cut: Bool) {
        let head = tokens("\(question.type) question: \(instructionText(question))")
        let wanted = options(question).map { 1 + tokens(" " + $0) }
        var taken = wanted.map { min($0, 1 + optionTokens) }
        var cut = zip(wanted, taken).contains { $0 != $1 }
        if headTokens - taken.reduce(0, +) < 16 {
            let each = max(4, (headTokens - 16) / max(1, taken.count))
            if taken.contains(where: { $0 > each }) { cut = true }
            taken = taken.map { min($0, each) }
        }
        let headRoom = max(8, headTokens - taken.reduce(0, +))
        if head > headRoom { cut = true }
        return (1 + min(head, headRoom) + 1 + taken.reduce(0, +) + 1, cut)
    }

    /// What the state may take beside the longest of these questions.
    public static func room(for questions: [String: ControlAPI.SystemOneQuestion]) -> Int {
        let longest = questions.values.map { prefix($0).tokens }.max() ?? 0
        return max(0, contextTokens - longest - 1)
    }

    /// Whether this request reaches the checkpoint whole: every question uncut, and the
    /// state inside what they leave.
    public static func fits(
        state: JSONContent, questions: [String: ControlAPI.SystemOneQuestion]
    ) -> Bool {
        !questions.values.contains { prefix($0).cut }
            && tokens(text(of: state)) <= room(for: questions)
    }

    // MARK: The form that fits

    /// The questions, rewritten to fit laya-mlx's budget rather than be cut by it.
    ///
    /// Each option keeps its label and as much of its description as its share allows —
    /// the part that says what it is for first, what it is not for last. A question's own
    /// text is put in words, its main question first, and kept to what the options leave.
    /// A choice with more options than the budget can even name is dropped: an option cut
    /// to three tokens is not an option the model can tell apart from its neighbours, and
    /// every feature reads a missing answer as no opinion.
    public static func compact(
        _ questions: [String: ControlAPI.SystemOneQuestion]
    ) -> [String: ControlAPI.SystemOneQuestion] {
        questions.compactMapValues(compact)
    }

    /// A choice over as many of its options as the checkpoint can name, taken in `order` —
    /// for a choice whose options are a ranked list, where the head of it is worth asking
    /// about and the tail is not worth losing the question for.
    public static func keepingFirst(
        _ choice: ControlAPI.SystemOneQuestion, in order: [String]
    ) -> ControlAPI.SystemOneQuestion {
        guard choice.type == "choice", let labels = choice.criteria?.objectValue else {
            return choice
        }
        var kept: [String: JSONContent] = [:]
        var spent = 0
        for label in order {
            guard let value = labels[label] else { continue }
            let cost = 1 + tokens(" " + label)
            guard spent + cost <= headTokens - minimumQuestionTokens else { break }
            kept[label] = value
            spent += cost
        }
        guard !kept.isEmpty else { return choice }
        var narrowed = choice
        narrowed.criteria = .object(kept)
        return narrowed
    }

    static func compact(
        _ question: ControlAPI.SystemOneQuestion
    ) -> ControlAPI.SystemOneQuestion? {
        guard !prefix(question).cut else { return reshaped(question) }
        return question
    }

    /// The most a yes/no or a score's own text is given before its options are shared out.
    static let maximumQuestionTokens = 136

    private static func reshaped(
        _ question: ControlAPI.SystemOneQuestion
    ) -> ControlAPI.SystemOneQuestion? {
        let lead = "\(question.type) question: "
        let words = inWords(question.instructions)
        // A choice's labels come first — an option the model cannot tell apart is no option.
        // A yes/no's question comes first — its two sides only elaborate it, and its text is
        // where a warning like "the call's own claims are not evidence" lives.
        let optionBudget = question.type == "choice"
            ? headTokens - minimumQuestionTokens
            : headTokens - 1 - min(maximumQuestionTokens, max(minimumQuestionTokens, tokens(lead + words)))
        var compacted = question
        switch question.type {
        case "choice":
            guard let labels = question.criteria?.objectValue, !labels.isEmpty else {
                return question
            }
            let names = labels.keys.sorted()
            let bare = names.map { 1 + tokens(" " + $0) }
            guard bare.reduce(0, +) <= optionBudget else { return nil }
            // Every label first; what is left is shared out for the descriptions.
            let extra = (optionBudget - bare.reduce(0, +)) / names.count
            var fitted: [String: JSONContent] = [:]
            for (name, cost) in zip(names, bare) {
                let share = min(1 + optionTokens, cost + extra)
                fitted[name] = description(labels[name]!).flatMap {
                    capped($0, toFit: share - 1, after: " \(name): ")
                }.map(JSONContent.string) ?? .null
            }
            compacted.criteria = .object(fitted)
        case "score":
            guard let levels = question.criteria?.arrayValue, !levels.isEmpty else {
                return question
            }
            let share = min(1 + optionTokens, optionBudget / levels.count)
            compacted.criteria = .array(levels.enumerated().map { index, level in
                let text = description(level) ?? ""
                return .string(capped(text, toFit: share - 1, after: " level \(index): ") ?? "")
            })
        default:
            let criteria = question.criteria?.objectValue ?? [:]
            let share = min(1 + optionTokens, optionBudget / 2)
            var fitted: [String: JSONContent] = [:]
            for side in ["false", "true"] {
                guard let text = criteria[side].flatMap(description) else { continue }
                if let kept = capped(text, toFit: share - 1, after: " \(side): ") {
                    fitted[side] = .string(kept)
                }
            }
            compacted.criteria = fitted.isEmpty ? question.criteria : .object(fitted)
        }
        let taken = options(compacted).map { min(1 + tokens(" " + $0), 1 + optionTokens) }
        let headRoom = headTokens - taken.reduce(0, +) - 1
        compacted.instructions = .string(capped(words, toFit: headRoom, after: lead) ?? words)
        return prefix(compacted).cut ? nil : compacted
    }

    /// A description as one line of text, the part that says what the option is for first.
    static func description(_ value: JSONContent) -> String? {
        switch value {
        case .null: return nil
        case .string(let text): return text.isEmpty ? nil : text
        case .array(let values):
            let parts = values.compactMap(description)
            return parts.isEmpty ? nil : parts.joined(separator: "; ")
        case .object(let fields):
            let first = [
                "what", "what_it_does", "use_when", "good_for", "good_at", "model", "name",
                "size", "kind",
            ]
            let last = ["avoid_when", "not_for", "cannot"]
            let rest = fields.keys.sorted().filter { !first.contains($0) && !last.contains($0) }
            let parts = (first + rest + last).compactMap { key -> String? in
                guard let text = fields[key].flatMap(description) else { return nil }
                return last.contains(key) ? "not \(text)" : text
            }
            return parts.isEmpty ? nil : parts.joined(separator: "; ")
        case .bool, .number: return python(value)
        }
    }

    /// A question's instructions in words: its main question first, then what to focus on,
    /// then the rest — so what a cut to fit takes is the list of fields to look at, not the
    /// warning about what to disbelieve.
    static func inWords(_ instructions: JSONContent?) -> String {
        guard let instructions else { return "" }
        guard case .object(let fields) = instructions else {
            return description(instructions) ?? ""
        }
        var parts: [String] = []
        if let question = fields["question"].flatMap(description) { parts.append(question) }
        let order = ["focus"] + fields.keys.sorted().filter { $0 != "focus" }
        for key in order where key != "question" && fields[key] != nil {
            guard let text = fields[key].flatMap(description) else { continue }
            parts.append("\(key.replacingOccurrences(of: "_", with: " ")): \(text)")
        }
        return parts.joined(separator: "; ")
    }

    /// The longest start of `text`, cut at a word, that fits `budget` tokens after `lead` —
    /// with an ellipsis when anything was cut. Nil when not even a word fits.
    static func capped(_ text: String, toFit budget: Int, after lead: String) -> String? {
        if tokens(lead + text) <= budget { return text }
        let words = text.split(separator: " ", omittingEmptySubsequences: true)
        var low = 0, high = words.count
        while low < high {
            let middle = (low + high + 1) / 2
            let trial = words.prefix(middle).joined(separator: " ") + "…"
            if tokens(lead + trial) <= budget { low = middle } else { high = middle - 1 }
        }
        return low == 0 ? nil : words.prefix(low).joined(separator: " ") + "…"
    }

    // MARK: The state that fits

    /// The state, its free text shortened until it fits beside these questions.
    ///
    /// The longest string goes first, cut to its head and its tail with the gap marked,
    /// until the whole fits or nothing long is left. Top-level keys in `protecting` are
    /// never cut: they are what the questions judge — a tool call about to run, a reply
    /// being checked, a prompt whose safety is being read — and an answer about part of one
    /// is worse than none. A state that still does not fit goes as it is, and the sidecar
    /// refuses it.
    public static func shortened(
        _ state: JSONContent, toFit questions: [String: ControlAPI.SystemOneQuestion],
        protecting protected: Set<String> = []
    ) -> JSONContent {
        let room = room(for: questions)
        var state = state
        for _ in 0..<64 {
            let excess = tokens(text(of: state)) - room
            guard excess > 0,
                  let (path, value) = longestString(in: state, protecting: protected)
            else { return state }
            let length = tokens(value)
            guard length > 16 else { return state }
            let target = max(12, min(length * 3 / 4, length - excess))
            state = replacing(path, in: state, with: headAndTail(value, toFit: target))
        }
        return state
    }

    private enum Step: Hashable { case key(String), index(Int) }

    private static func longestString(
        in value: JSONContent, protecting protected: Set<String>, path: [Step] = []
    ) -> ([Step], String)? {
        switch value {
        case .string(let text): return (path, text)
        case .array(let values):
            return values.enumerated().compactMap {
                longestString(in: $0.element, protecting: protected, path: path + [.index($0.offset)])
            }.max { $0.1.count < $1.1.count }
        case .object(let fields):
            return fields.compactMap { key, field in
                path.isEmpty && protected.contains(key)
                    ? nil
                    : longestString(in: field, protecting: protected, path: path + [.key(key)])
            }.max { $0.1.count < $1.1.count }
        default: return nil
        }
    }

    private static func replacing(
        _ path: [Step], in value: JSONContent, with text: String
    ) -> JSONContent {
        guard let step = path.first else { return .string(text) }
        let rest = Array(path.dropFirst())
        switch (step, value) {
        case (.key(let key), .object(var fields)):
            fields[key] = replacing(rest, in: fields[key] ?? .null, with: text)
            return .object(fields)
        case (.index(let index), .array(var values)):
            values[index] = replacing(rest, in: values[index], with: text)
            return .array(values)
        default: return value
        }
    }

    /// Two thirds head, one third tail, the gap marked: a long paste carries the material
    /// first and the actual ask last. Cut by characters rather than words, so a log line or
    /// a JSON argument with no spaces in it shortens like prose does.
    static func headAndTail(_ text: String, toFit budget: Int) -> String {
        let characters = Array(text)
        func joined(_ count: Int) -> String {
            let head = count * 2 / 3
            return String(characters.prefix(head)) + " … "
                + String(characters.suffix(count - head))
        }
        var low = 0, high = characters.count
        while low < high {
            let middle = (low + high + 1) / 2
            if tokens(joined(middle)) <= budget { low = middle } else { high = middle - 1 }
        }
        return joined(low)
    }
}
