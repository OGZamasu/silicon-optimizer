import SiliconCatalog
import SiliconControl
import SiliconCore
import SiliconPlanner
import SiliconRuntime
import SwiftUI

// The TypeSafe account, and the Jev settings that hang off it. These used to live at the
// bottom of Settings; they moved here with the Decisions panel, because a key, a budget
// and a model pin are only ever looked at while deciding who answers a question.

/// The TypeSafe key field. A saved key is not read back into the field — the app has no
/// reason to show a credential it already holds — so the row says whether one is stored and
/// takes a replacement or a removal.
struct TypeSafeKeyRow: View {
    var onKeyChanged: () -> Void = {}

    @State private var draft = ""
    @State private var stored = TypeSafeCredential.isSet
    @State private var failed = false
    @State private var switchedOn = false

    var body: some View {
        HStack {
            SecureField(stored ? "Key stored — paste a new one to replace it" : "API key (sk-…)", text: $draft)
                .textFieldStyle(.roundedBorder)
            Button(stored && draft.isEmpty ? "Remove" : "Save") { save() }
                .disabled(!stored && draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        if failed {
            Text("The Keychain refused to store the key.")
                .font(.caption)
                .foregroundStyle(.red)
        }
        if switchedOn {
            Text("Jev is now on for the decide tool. Turn it off below if you would rather "
                 + "keep decisions local.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func save() {
        let hadNoKey = !stored
        let wantsAKey = !draft.trimmingCharacters(in: .whitespaces).isEmpty
        failed = !TypeSafeCredential.write(draft)
        stored = TypeSafeCredential.isSet
        draft = ""
        // Pasting a key into an empty slot is somebody saying yes to this, and leaving them
        // with a stored key and a feature still switched off reads as "it did not work".
        // Replacing an existing key is not: they may have turned it off on purpose.
        let turningOn = hadNoKey && wantsAKey && !failed
        Task {
            if turningOn {
                switchedOn = (try? await JevService.shared.update { $0.enabled = true }) != nil
            } else if !stored {
                switchedOn = false
            }
            onKeyChanged()
        }
    }
}

/// Everything Jev is allowed to do, and what it has cost.
///
/// The rows mirror `JevSettings`, which lives in a file an actor owns rather than in the
/// app's settings object — so this view holds a copy, writes through `JevService` and reads
/// the result back. Optimistic: the toggle moves at once and the reload confirms it, because
/// a switch that waits for a file write feels broken.
struct JevSection: View {
    @State private var settings = JevSettings()
    @State private var month = JevLedger.monthKey()
    @State private var totals = JevLedger.Month()
    @State private var keySet = TypeSafeCredential.isSet
    @State private var connection: String?
    @State private var connectionFailed = false
    @State private var testing = false
    @State private var budgetText = ""
    @State private var saveError: String?
    @State private var ledgerProblem: String?

    var body: some View {
        Group {
            Toggle("Use Jev", isOn: Binding(
                get: { settings.enabled },
                set: { value in apply { $0.enabled = value } }
            ))

            Picker("Model", selection: Binding(
                get: { settings.model },
                set: { value in apply { $0.model = value } }
            )) {
                ForEach(JevService.allowedModels, id: \.self) { model in
                    Text(model == JevService.pinnedModel ? "\(model) (pinned)" : model)
                        .tag(model)
                }
            }
            Text(
                "Pinned to a version on purpose. `jev-latest` and `jev-preview` move when "
                + "TypeSafe ships a release, and thresholds tuned against one version are not "
                + "promises about the next one."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                Button(testing ? "Testing…" : "Test connection") { testConnection() }
                    .disabled(testing || !keySet)
                if let connection {
                    Text(connection)
                        .font(.caption)
                        .foregroundStyle(connectionFailed ? .red : .secondary)
                        .textSelection(.enabled)
                } else if !keySet {
                    Text("Add a key first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(JevFeature.allCases, id: \.self) { feature in
                VStack(alignment: .leading, spacing: 2) {
                    Toggle(feature.displayName, isOn: Binding(
                        get: { settings.isOn(feature) },
                        set: { value in apply { $0.features[feature] = value } }
                    ))
                    .disabled(!feature.isBuilt)
                    Text(
                        feature.isBuilt
                            ? feature.summary
                            : "Coming. \(feature.summary)"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if feature == .routing, settings.isOn(.routing) {
                        JevRoutingFallbackRow(
                            selected: settings.routingFallbackModel,
                            pick: { model in apply { $0.routingFallbackModel = model } }
                        )
                    }
                    if feature == .mediaRouting, settings.isOn(.mediaRouting) {
                        MediaRoutingOptions()
                    }

                    // The guardrail's one sub-switch, indented under it because it is
                    // meaningless on its own: it decides what happens to a verdict, and
                    // without the guardrail there are no verdicts.
                    if feature == .guardrails {
                        Toggle("Auto-approve calls Jev rates safe", isOn: Binding(
                            get: { settings.autoApproveSafeToolCalls },
                            set: { value in apply { $0.autoApproveSafeToolCalls = value } }
                        ))
                        .disabled(!settings.isOn(.guardrails))
                        .padding(.leading, 18)
                        Text(
                            "Off by default. On, an agent's tool call that Jev rates safe is "
                            + "approved without asking and one it blocks is declined without "
                            + "asking; anything it wants reviewed still waits for you, and so "
                            + "does everything if Jev cannot answer."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 18)
                    }
                    if feature == .verification, settings.isOn(.verification) {
                        JevEscalationTargetRow(
                            selected: settings.verificationEscalationModel,
                            pick: { model in
                                apply { $0.verificationEscalationModel = model }
                            }
                        )
                    }

                    // Under its own toggle, like the two above: the run is what this switch
                    // pays for, and the floors are the only thing it changes.
                    if feature == .calibration, settings.isOn(.calibration) {
                        JevCalibrationRow()
                    }
                    // Tool selection's one sub-switch, indented under it for the same
                    // reason the guardrail's is: it is a different act. Suggesting a tool
                    // changes what a model is told; this changes what it is given.
                    if feature == .skillSelection {
                        Toggle("Drop tool results a small model no longer needs", isOn: Binding(
                            get: { settings.pruneToolHistory },
                            set: { value in apply { $0.pruneToolHistory = value } }
                        ))
                        .disabled(!settings.isOn(.skillSelection))
                        .padding(.leading, 18)
                        Text(
                            "Off by default. On, a chat request bound for a model on this Mac "
                            + "or a machine on your network has its older tool results "
                            + "replaced by one-line stubs once the prompt is crowding that "
                            + "model's context window. Your messages, the assistant's replies, "
                            + "the system prompt and the two newest results are never touched, "
                            + "and nothing is dropped when Jev is unsure or cannot answer. "
                            + "Models at a provider are never pruned."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 18)

                        JevPruneFractionRow(
                            fraction: settings.pruneAboveFraction,
                            enabled: settings.isOn(.skillSelection) && settings.pruneToolHistory,
                            pick: { value in apply { $0.pruneAboveFraction = value } }
                        )
                        .padding(.leading, 18)
                    }
                }
            }

            LabeledContent {
                TextField(
                    "Monthly budget", text: $budgetText, prompt: Text("No cap")
                )
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .onSubmit { commitBudget() }
            } label: {
                Text("Monthly budget (USD)")
            }
            Text(
                "Press return to save. Once the month's estimated spend reaches the cap, every "
                + "feature stops asking Jev until the next month or a higher cap."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Text(spendLine)
                .font(.callout)
                .monospacedDigit()

            if let ledgerProblem {
                Label(
                    "The spend above is this session only — the ledger file could not be "
                    + "written (\(ledgerProblem)). The monthly budget will not carry across "
                    + "a restart until that is fixed.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            if let saveError {
                Text(saveError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Text(
                "Only the state each feature needs is sent, nothing else. Your key stays in the "
                + "Keychain on this Mac; phones and the swarm never receive it."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .task { await reload() }
    }

    private var spendLine: String {
        let cost = totals.total.estimatedUSD
        // Two decimals would read "$0.00" for a month of real use, and "$0" for none.
        let money = cost == 0 ? "$0" : String(format: cost < 0.01 ? "$%.4f" : "$%.2f", cost)
        return "This month: \(totals.total.calls.formatted()) calls · "
            + "\(totals.total.inputTokens.formatted()) input tokens · about \(money)"
    }

    private func reload() async {
        settings = await JevService.shared.settings()
        month = JevLedger.monthKey()
        totals = await JevService.shared.ledger().month(month)
        keySet = TypeSafeCredential.isSet
        ledgerProblem = await JevService.shared.ledgerWriteError
        budgetText = settings.monthlyBudgetUSD.map { String(format: "%.2f", $0) } ?? ""
    }

    /// The same edit twice: once to the copy on screen, once to the file the actor owns.
    /// The service normalises, so the reload afterwards is what makes the row honest when
    /// it clamped something.
    private func apply(_ change: @escaping @Sendable (inout JevSettings) -> Void) {
        change(&settings)
        Task {
            do {
                try await JevService.shared.update(change)
                saveError = nil
            } catch {
                saveError = "Could not save the Jev settings: \(error.localizedDescription)"
            }
            await reload()
        }
    }

    private func commitBudget() {
        let trimmed = budgetText.trimmingCharacters(in: .whitespaces)
        // An empty field is "no cap", which is a real answer and not an error.
        let budget = trimmed.isEmpty ? nil : Double(trimmed.replacingOccurrences(of: "$", with: ""))
        guard trimmed.isEmpty || budget != nil else {
            saveError = "That budget is not a number."
            return
        }
        apply { $0.monthlyBudgetUSD = budget }
    }

    private func testConnection() {
        testing = true
        connection = nil
        Task {
            do {
                let names = try await JevService.shared.testConnection()
                connectionFailed = false
                connection = names.isEmpty
                    ? "Reached TypeSafe; it listed no models."
                    : "Reached TypeSafe: \(names.joined(separator: ", "))"
            } catch {
                connectionFailed = true
                connection = error.localizedDescription
            }
            testing = false
        }
    }
}

/// Which model a flagged answer is re-run on.
///
/// Shown under the verification toggle, and only while verification is on — the same
/// arrangement, and for the same reason, as the routing fallback below it: it is that
/// feature's setting and means nothing without it. The value lives in `jev.json` with the
/// rest of what Jev is allowed to do, so this row owns none of it.
///
/// Two things are deliberately absent from the list.
///
/// **This Mac's own models.** Escalating to one would unload the model that just answered,
/// in the middle of the request that answered with it, so offering them would be offering a
/// choice the code then refuses to honour.
///
/// **`silicon/auto`.** It is a virtual id that asks the router to choose, and "escalate to
/// whatever routing picks" is not an escalation — it is a coin toss that can land back on
/// the model under test. `gatewayServableModels()` is the list without it.
private struct JevEscalationTargetRow: View {
    let selected: String?
    let pick: (String?) -> Void

    @Environment(AppModel.self) private var app
    /// Read once when the row appears rather than in `body`: building the list walks the
    /// library, the swarm and the cloud lists, and a picker redraws often.
    @State private var models: [GatewayAPI.Model] = []

    /// Everything that could actually take an escalation: the swarm's models and, for
    /// someone who has opted into one, a provider's. Never this Mac's own.
    private var offered: [GatewayAPI.Model] {
        models.filter {
            if case .local = GatewayAPI.parseModelID($0.id) { return false }
            return true
        }
    }

    /// A pick that is no longer in the list — deleted, hidden, or its node went away.
    /// Saying so beats a picker that silently shows "Work it out" and leaves someone
    /// thinking their choice is still in force.
    private var missing: String? {
        guard let selected, !offered.contains(where: { $0.id == selected }) else { return nil }
        return selected
    }

    /// Whose hardware the chosen model runs on, when it is not the owner's.
    private var cloudProvider: String? {
        guard let selected, case .cloud(let provider, _) = GatewayAPI.parseModelID(selected)
        else { return nil }
        return CloudProvider(rawValue: provider)?.displayName ?? provider
    }

    var body: some View {
        Picker(
            "Re-run flagged answers on",
            selection: Binding(
                get: { selected ?? "" },
                set: { pick($0.isEmpty ? nil : $0) }
            )
        ) {
            Text("Work it out — a model a node is already serving").tag("")
            ForEach(offered, id: \.id) { model in
                Text(model.displayName).tag(model.id)
            }
            if let missing {
                Text("\(missing) (not available)").tag(missing)
            }
        }
        .onAppear {
            Task { models = await app.gatewayServableModels() }
        }
        Text(
            "When Jev says an answer does not answer the question, describes a document it "
            + "was never given, contradicts its context or was cut off, `POST /chat` and the "
            + "MCP `chat` tool ask this model the same thing and return its answer instead, "
            + "with the reasons attached. One re-run per request, never a loop. Streaming "
            + "answers are only flagged — their tokens are already on your screen, so they "
            + "say what they found and suggest the re-run rather than replacing what you are "
            + "reading."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        Text(
            "Left as \"work it out\" this only ever uses a model one of your own machines is "
            + "already serving, and otherwise just flags the answer. It never picks a cloud "
            + "model for you and never picks one on this Mac."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        if let cloudProvider {
            Label(
                "A re-run sends the whole conversation — every turn, and any images "
                + "attached to it — to \(cloudProvider).",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(.orange)
        }
        if let missing {
            Text(
                "\(missing) is not installed or reachable right now, so a flagged answer "
                + "will only be annotated until it comes back or you pick something else."
            )
            .font(.caption)
            .foregroundStyle(.orange)
        }
    }
}

/// Where a routed request goes when Jev cannot be asked or is not sure enough.
///
/// Shown under the routing toggle, and only while routing is on: it is that feature's
/// setting, and an eighth row about a switch nobody has flipped is noise. The value lives in
/// `jev.json` with the rest of what Jev is allowed to do, so this row owns none of it — the
/// selection comes down and the pick goes back up through the same `JevService.update` every
/// other row here uses.
private struct JevRoutingFallbackRow: View {
    let selected: String?
    let pick: (String?) -> Void

    @Environment(AppModel.self) private var app
    /// Read once when the row appears rather than in `body`: building the gateway's model
    /// list walks the library, the swarm and the cloud lists, and a picker redraws often.
    @State private var models: [GatewayAPI.Model] = []

    /// A pick that is no longer in the list — the model was deleted, hidden, or its node
    /// went away. Saying so beats a picker that silently shows "Whatever is loaded" and
    /// leaves someone thinking their choice is still in force.
    private var missing: String? {
        guard let selected, !models.contains(where: { $0.id == selected }) else { return nil }
        return selected
    }

    var body: some View {
        Picker(
            "Fall back to",
            selection: Binding(
                get: { selected ?? "" },
                set: { pick($0.isEmpty ? nil : $0) }
            )
        ) {
            Text("Whatever is loaded").tag("")
            ForEach(models, id: \.id) { model in
                Text(model.displayName).tag(model.id)
            }
            if let missing {
                Text("\(missing) (not available)").tag(missing)
            }
        }
        .onAppear { models = app.gatewayModelSnapshot() }
        Text(
            "Auto (`silicon/auto` in the model list) asks Jev which model should answer each "
            + "request. This is where it sends one when Jev is off, over budget, or not sure "
            + "enough to choose — by default the model loaded here, or the first one that "
            + "would answer without a load."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        if let missing {
            Text(
                "\(missing) is not installed or reachable right now, so routing is falling "
                + "back to whatever is loaded until it comes back or you pick something else."
            )
            .font(.caption)
            .foregroundStyle(.orange)
        }
    }
}

/// How full a model's context window has to be before its tool history is pruned.
///
/// A picker over four written fractions rather than a free number field, because the useful
/// range is narrow and each option says what it means: the row is about when the history
/// stops being free, and "0.55" on its own says nothing about that.
private struct JevPruneFractionRow: View {
    let fraction: Double
    let enabled: Bool
    let pick: (Double) -> Void

    /// The offered fractions, and what each one is for. Anything hand-edited into `jev.json`
    /// between them still works — it is clamped to 0.1…0.95 and used as written; it is just
    /// shown here as the nearest of these.
    static let choices: [(value: Double, label: String)] = [
        (0.55, "Over half full — prune early"),
        (0.7, "About two thirds full (default)"),
        (0.85, "Nearly full — prune late"),
        (0.95, "Only when it is about to overflow"),
    ]

    private var nearest: Double {
        Self.choices
            .min { abs($0.value - fraction) < abs($1.value - fraction) }?.value ?? 0.7
    }

    var body: some View {
        Picker(
            "Prune when the prompt is",
            selection: Binding(get: { nearest }, set: { pick($0) })
        ) {
            ForEach(Self.choices, id: \.value) { choice in
                Text(choice.label).tag(choice.value)
            }
        }
        .disabled(!enabled)
        Text(
            "Below this the history is not the problem, and the cheapest correct thing to do "
            + "is nothing. A pruned request says how many results it dropped — in an "
            + "`X-Silicon-Pruned` header, or a `: silicon-pruned:` comment on a stream — and "
            + "the Fleet log keeps the step numbers."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// The one thing the owner decides about media routing beyond switching it on.
///
/// Shown under the Media routing toggle rather than in a section of its own, because it is
/// meaningless without it: if nothing is reading prompts, nothing is deciding which lane an
/// adult one goes to. It writes through `JevService` like every other row here, so a paired
/// phone reading `GET /jev` sees the same answer.
private struct MediaRoutingOptions: View {
    @Environment(AppModel.self) private var model
    /// The stored answer: nil until the owner actually chooses, which is what keeps the
    /// default following what is installed rather than freezing the first time this is drawn.
    @State private var stored: Bool?
    @State private var laneInstalled = false
    @State private var saveError: String?

    private var automatic: Bool { stored ?? laneInstalled }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle("Send adult prompts to the uncensored lane automatically", isOn: Binding(
                get: { automatic },
                set: { value in save(value) }
            ))
            .disabled(!laneInstalled)
            Text(
                laneInstalled
                    ? (automatic
                        ? "A prompt Jev reads as asking for nudity or sexual content goes "
                            + "straight to the uncensored model. Off, it is not routed at all "
                            + "and nothing is queued — name the model yourself to render it."
                        : "Adult prompts are not routed automatically. Nothing is queued and "
                            + "nothing is sent to a model that would refuse it; name the model "
                            + "yourself to render one.")
                    : "No uncensored lane is installed and ready on any node here, so there "
                        + "is nowhere to route an adult prompt. Jev says so rather than "
                        + "sending one to a model that would refuse it."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Text(
                "Sexual content depicting a named real person is never routed, whatever this "
                + "is set to."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            if let saveError {
                Text(saveError).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.leading, 18)
        .task { await reload() }
    }

    private func reload() async {
        laneInstalled = model.hasUncensoredVideoLane
        stored = await JevService.shared.settings().automaticUncensoredLane
    }

    private func save(_ value: Bool) {
        stored = value
        Task {
            do {
                try await JevService.shared.update { $0.automaticUncensoredLane = value }
                saveError = nil
            } catch {
                saveError = "Could not save that: \(error.localizedDescription)"
            }
            await reload()
        }
    }
}

/// The calibration run and what the last one found.
///
/// Sits under the Decision calibration switch because it belongs to it: that switch is what
/// pays for the run, and the floors it produces are the only thing the run changes. The
/// summary is deliberately specific — which model, when, how much agreement, how much of the
/// set would be escalated, which floors — because a calibration measured against a model you
/// are no longer running is a number that has quietly stopped applying, and the row should
/// say so rather than imply otherwise by showing it.
private struct JevCalibrationRow: View {
    @Environment(AppModel.self) private var model
    @State private var last: ControlAPI.JevCalibration?
    @State private var running = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button(running ? "Calibrating…" : "Calibrate local decisions") { run() }
                    .disabled(running)
                if running {
                    ProgressView().controlSize(.small)
                    // Forty cases is a minute or two of the loaded model doing nothing else.
                    // A run you cannot stop is a run you will not start.
                    Button("Cancel") { CalibrationRun.cancel() }
                }
            }

            if let last {
                Text(last.summary)
                    .font(.caption)
                    .monospacedDigit()
                    .textSelection(.enabled)
                if last.appliesToLoadedModel == false {
                    Text(
                        "Not in effect: measured against \(last.modelName), and "
                        + "\(model.loadedModel?.name ?? "another model") is loaded. `auto` is "
                        + "using the default floors until this is run again."
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            } else {
                Text(Self.neverRun)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(Self.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .task { last = await model.jevCalibration() }
    }

    /// Built once as a plain string rather than inline in the view: the type checker times
    /// out on a `Text` assembled from this many `String(format:)` pieces.
    static let neverRun = String(
        format: "Never run. Until it is, `auto` escalates on the default floors: a choice or "
        + "score under %.2f confidence, or a noul between %.2f and %.2f.",
        JevSettings.defaultCascadeFloor, JevSettings.defaultCascadeNoulLow,
        JevSettings.defaultCascadeNoulHigh
    )

    static let explanation =
        "Runs \(CalibrationQuestions.builtIn.count) short cases through the loaded model and "
        + "through Jev, and sets where `decide` stops trusting this Mac on its own. About "
        + "\(ControlAPI.JevCalibration.estimatedCents(cases: CalibrationQuestions.builtIn.count)) "
        + "cent of Jev tokens and a minute or two of the model. Jev is the reference, not "
        + "ground truth — agreement means the two landed in the same place, which they can do "
        + "while both being wrong. Add cases of your own to `jev-calibration.json` beside "
        + "`jev.json`."

    private func run() {
        running = true
        problem = nil
        Task {
            do {
                last = try await model.calibrateJev()
            } catch is CancellationError {
                problem = "Calibration cancelled. The previous result is unchanged."
            } catch {
                problem = error.localizedDescription
            }
            running = false
        }
    }
}
