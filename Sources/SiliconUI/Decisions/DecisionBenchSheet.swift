import SiliconControl
import SiliconRuntime
import SwiftUI

/// The test bench: one question set, one lane you name, and the probabilities it came back
/// with.
///
/// It asks the *named* lane rather than the one the policy would choose, which is the whole
/// point — running the same set against two lanes and looking at the two distributions side
/// by side is the only way to find out that they disagree, and where.
///
/// The set is editable, and it starts as one question of each kind against a small state,
/// so somebody who has just installed Laya can press one button and see it work.
struct DecisionBenchSheet: View {
    let lanes: [ControlAPI.DecisionLaneView]
    var done: () -> Void

    @Environment(AppModel.self) private var model
    @State private var lane = DecisionLaneID.laya.wireName
    @State private var stateText = Self.sampleState
    @State private var questionsText = Self.sampleQuestions
    @State private var result: ControlAPI.DecisionTestResult?
    @State private var problem: String?
    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Decision test bench").font(.title3.weight(.semibold))
            Text(
                "Asks the lane you pick, not the one the policy would. Run the same set on "
                + "two lanes to see where they disagree."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Picker("Lane", selection: $lane) {
                ForEach(lanes, id: \.id) { entry in
                    Text(
                        entry.displayName
                        + (entry.available ? "" : " — not available")
                        + (entry.costsMoney ? " (costs money)" : "")
                    ).tag(entry.id)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("State").font(.caption.weight(.medium))
                TextEditor(text: $stateText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 80)
                    .border(.quaternary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Questions").font(.caption.weight(.medium))
                TextEditor(text: $questionsText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 150)
                    .border(.quaternary)
            }

            HStack {
                Button(running ? "Asking…" : "Ask") { run() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(running)
                Button("Close") { done() }
                Spacer()
                if let result {
                    Text(headline(result))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            if let result {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(result.answers.keys.sorted(), id: \.self) { id in
                            answerRow(id, result.answers[id]!)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func headline(_ result: ControlAPI.DecisionTestResult) -> String {
        var parts = [result.model]
        if let per = result.perQuestionMS {
            parts.append(String(format: "%.0f ms a question", per))
        }
        if result.estimatedUSD > 0 {
            parts.append(String(format: "$%.4f", result.estimatedUSD))
        } else {
            parts.append("free")
        }
        return parts.joined(separator: " · ")
    }

    /// The probabilities, whole. A bench that showed only the winner would hide the thing
    /// worth looking at — a choice at 0.34 against a runner-up at 0.33 is a different
    /// situation from one at 0.99, and both say "the same answer" if you print only the
    /// label.
    @ViewBuilder
    private func answerRow(_ id: String, _ answer: ControlAPI.SystemOneAnswer) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            switch answer {
            case .noul(let p):
                Text("\(id) — noul").font(.caption.weight(.medium))
                bar(label: "P(true)", value: p)
            case .choice(let choice, let confidence, let probabilities):
                Text(String(format: "%@ — choice: %@ (%.0f%% sure)", id, choice, confidence * 100))
                    .font(.caption.weight(.medium))
                ForEach(probabilities.keys.sorted(), id: \.self) { key in
                    bar(label: key, value: probabilities[key] ?? 0)
                }
            case .score(let score, let confidence, let legend, let probabilities):
                Text(String(
                    format: "%@ — score: %.2f (%.0f%% sure)", id, score, confidence * 100
                ))
                .font(.caption.weight(.medium))
                ForEach(probabilities.keys.sorted(), id: \.self) { key in
                    bar(
                        label: legend[key]?.stringValue.map { "\(key): \($0)" } ?? key,
                        value: probabilities[key] ?? 0
                    )
                }
            }
        }
    }

    private func bar(label: String, value: Double) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption2)
                .frame(width: 170, alignment: .leading)
                .lineLimit(1)
            ProgressView(value: min(max(value, 0), 1))
                .frame(width: 200)
            Text(String(format: "%.3f", value))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private func run() {
        running = true
        problem = nil
        Task {
            defer { running = false }
            do {
                let decoder = JSONDecoder()
                let state = try decoder.decode(
                    JSONContent.self, from: Data(stateText.utf8)
                )
                let questions = try decoder.decode(
                    [String: ControlAPI.SystemOneQuestion].self,
                    from: Data(questionsText.utf8)
                )
                result = try await model.runDecisionTest(
                    .init(lane: lane, state: state, questions: questions)
                )
            } catch {
                result = nil
                problem = error.localizedDescription
            }
        }
    }

    // MARK: A set to start from

    static let sampleState = """
        {"from": "a customer", "subject": "Charged twice", \
        "body": "I was billed twice for the same order and would like one refunded."}
        """

    /// One of each kind, because the three are answered by different heads and a lane can
    /// be good at one and poor at another.
    static let sampleQuestions = """
        {
          "urgent": {
            "type": "noul",
            "instructions": "Does this need a reply today?"
          },
          "department": {
            "type": "choice",
            "instructions": "Which team should handle this?",
            "criteria": {
              "billing": "payments and refunds",
              "technical": "bugs and outages",
              "sales": "pricing and new business",
              "other": "anything else"
            }
          },
          "severity": {
            "type": "score",
            "instructions": "How severe is this for the customer?",
            "criteria": [
              "not a problem", "minor annoyance", "real problem",
              "blocking", "urgent harm"
            ]
          }
        }
        """
}
