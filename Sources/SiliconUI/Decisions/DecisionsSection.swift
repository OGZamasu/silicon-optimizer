import SiliconControl
import SiliconRuntime
import SwiftUI

/// Settings → Decisions: the control panel for every decision this app makes.
///
/// One screen, four things on it, in the order somebody actually asks them:
///
/// 1. **The lanes.** Who *can* answer — Jev, Laya here, a node, the loaded model — with
///    what each one costs, whether it leaves the Mac, and what it is doing right now.
/// 2. **The abilities.** The eight things that ask questions, each with its switch, which
///    lane answers it, its thresholds, and what it has cost or how fast it has been.
/// 3. **The bench.** Send a question set to a lane you name and look at the probabilities,
///    which is the only way to find out that two lanes disagree.
/// 4. **What it has decided.** The guardrail's recent screenings, which already existed.
///
/// This is the home for all of it. The TypeSafe (Jev) section below keeps the key, the
/// budget and the model pin — everything that is about the *account* rather than about
/// deciding — so nothing that was reachable before has stopped being reachable.
struct DecisionsSection: View {
    @Environment(AppModel.self) private var model
    @State private var status: ControlAPI.DecisionsStatus?
    @State private var problem: String?
    @State private var showingBench = false
    @State private var busy = false
    private let installs = LayaInstallCenter.shared

    var body: some View {
        Section("Decisions") {
            Text(
                "Typed decisions — yes/no, pick one, score against a rubric — with a "
                + "probability on every answer. Three kinds of lane can answer them, and "
                + "which one does is the whole of this screen."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            if let status {
                ForEach(status.lanes, id: \.id) { lane in
                    laneRow(lane)
                }
                Divider()
                Text("Abilities")
                    .font(.headline)
                ForEach(status.abilities, id: \.id) { ability in
                    abilityRow(ability)
                }
                Divider()
                HStack {
                    Button("Test bench…") { showingBench = true }
                    Spacer()
                    Text(summaryLine(status))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                ProgressView().controlSize(.small)
            }

            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        }
        .task { await refresh() }
        .sheet(isPresented: $showingBench) {
            DecisionBenchSheet(lanes: status?.lanes ?? []) { showingBench = false }
                .environment(model)
        }
    }

    private func summaryLine(_ status: ControlAPI.DecisionsStatus) -> String {
        let paid = status.totalCalls
        guard paid > 0 else { return "Nothing paid for this month." }
        return String(
            format: "%d paid call%@ this month · about $%.2f",
            paid, paid == 1 ? "" : "s", status.totalEstimatedUSD
        )
    }

    // MARK: Lanes

    @ViewBuilder
    private func laneRow(_ lane: ControlAPI.DecisionLaneView) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: lane.available
                      ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(lane.available ? .green : .secondary)
                Text(lane.displayName).font(.body.weight(.medium))
                Spacer()
                // The two facts the owner is entitled to before anything is asked: does it
                // cost, and does it leave.
                if lane.costsMoney {
                    badge("costs money", .orange)
                } else {
                    badge("free", .green)
                }
                if lane.leavesTheMac {
                    badge("leaves the Mac", .orange)
                } else {
                    badge("stays here", .green)
                }
            }
            Text(lane.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let measured = lane.measuredPerQuestionMS {
                Text(String(format: "Measured here: %.0f ms a question.", measured))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let laya = lane.laya { layaControls(laya) }
            if let node = lane.node { nodeControls(node) }
        }
        .padding(.vertical, 2)
    }

    private func badge(_ text: String, _ colour: Color) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(colour.opacity(0.15), in: Capsule())
            .foregroundStyle(colour)
    }

    @ViewBuilder
    private func layaControls(_ laya: ControlAPI.LayaLaneDetail) -> some View {
        Toggle("Use Laya on this Mac", isOn: Binding(
            get: { laya.enabled },
            set: { on in apply(.init(layaEnabled: on)) }
        ))
        .disabled(busy)

        Picker("Checkpoint", selection: Binding(
            get: { laya.checkpoint },
            set: { id in apply(.init(layaCheckpoint: id)) }
        )) {
            ForEach(laya.checkpoints, id: \.id) { checkpoint in
                Text(
                    checkpoint.displayName
                    + (checkpoint.installed ? "" : " — not downloaded")
                ).tag(checkpoint.id)
            }
        }
        .disabled(busy || !laya.enabled)

        if let chosen = laya.checkpoints.first(where: { $0.id == laya.checkpoint }) {
            Text(
                chosen.summary + " "
                + "\(chosen.baseModel), \(chosen.parameterMillions)M parameters, "
                + "\(chosen.contextTokens) tokens of context, pinned to "
                + "\(chosen.revision.prefix(7))."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            if installs.isRunning {
                VStack(alignment: .leading, spacing: 2) {
                    ProgressView(value: installs.fraction)
                    Text([installs.step, installs.detail].compactMap { $0 }.joined(separator: " — "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else if !chosen.installed {
                HStack {
                    Button("Install Laya…") {
                        LayaInstallCenter.shared.install(
                            checkpoint: LayaCheckpoint(rawValue: chosen.id) ?? .default
                        )
                    }
                    .disabled(model.settings.resolvedModelLibraryDirectory == nil)
                    Text(
                        "\(ByteCountFormatter.string(fromByteCount: chosen.downloadBytes, countStyle: .file))"
                        + ", into your model library — never the startup disk."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } else if laya.loaded {
                HStack {
                    Button("Unload now") { apply(.init(unloadLaya: true)) }
                    if let peak = laya.peakMemoryBytes {
                        Text("Holding \(ByteCountFormatter.string(fromByteCount: peak, countStyle: .memory)).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let failure = installs.error {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }

        // The licence is two rightsholders under one licence, and Apache-2.0 asks for the
        // notice that ships with each. Shown rather than buried in a file nobody opens.
        Text(
            "\(laya.package) · \(laya.licence) · \(laya.weightsAttribution) · "
            + "\(laya.portAttribution)"
            + (laya.bytesOnDisk > 0
               ? " · \(ByteCountFormatter.string(fromByteCount: laya.bytesOnDisk, countStyle: .file)) on disk"
               : "")
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func nodeControls(_ node: ControlAPI.NodeLaneDetail) -> some View {
        Toggle("Let a swarm node answer decisions", isOn: Binding(
            get: { node.enabled },
            set: { on in apply(.init(nodeLaneEnabled: on)) }
        ))
        .disabled(busy)
        ForEach(node.candidates, id: \.name) { candidate in
            HStack(spacing: 6) {
                Image(systemName: candidate.ready ? "bolt.horizontal.circle.fill" : "moon.zzz")
                    .foregroundStyle(candidate.ready ? .green : .secondary)
                Text(candidate.name).font(.caption)
                if !candidate.checkpoints.isEmpty {
                    Text(candidate.checkpoints.joined(separator: ", "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let ms = candidate.perQuestionMS {
                    Text(String(format: "%.0f ms a question", ms))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !candidate.reachable {
                    Text("unreachable").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Abilities

    @ViewBuilder
    private func abilityRow(_ ability: ControlAPI.DecisionAbility) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(ability.displayName).font(.body.weight(.medium))
                Spacer()
                Picker("", selection: Binding(
                    get: { ability.laneOverride },
                    set: { choice in apply(.init(overrides: [ability.id: choice])) }
                )) {
                    ForEach(ControlAPI.DecisionLaneVocabulary.overrides, id: \.self) { id in
                        Text(DecisionLaneOverride(rawValue: id)?.displayName ?? id).tag(id)
                    }
                }
                .labelsHidden()
                .frame(width: 130)
                .disabled(busy || !ability.built)
            }
            Text(ability.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                if let lane = ability.lane {
                    Label(
                        "answered by \(DecisionLaneID.named(lane)?.displayName ?? lane)",
                        systemImage: "arrow.turn.down.right"
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                } else if let why = ability.unavailableReason {
                    Label(why, systemImage: "minus.circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let thresholds = ability.thresholds {
                    Text(String(
                        format: "act ≥ %.2f · confirm ≥ %.2f",
                        thresholds.act, thresholds.confirm
                    ))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
            if ability.calls > 0 || ability.lastLatencyMS != nil {
                Text(cost(ability))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let failure = ability.lastError {
                Text("Last try: \(failure)")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 1)
    }

    private func cost(_ ability: ControlAPI.DecisionAbility) -> String {
        var parts: [String] = []
        if ability.calls > 0 {
            parts.append(String(
                format: "%d paid call%@ · $%.3f",
                ability.calls, ability.calls == 1 ? "" : "s", ability.estimatedUSD
            ))
        }
        if let latency = ability.lastLatencyMS {
            parts.append(String(format: "last %.0f ms", latency))
        } else if let average = ability.averageLatencyMS {
            parts.append(String(format: "about %.0f ms", average))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Plumbing

    private func apply(_ update: ControlAPI.DecisionLanesUpdate) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                status = try await model.updateDecisionLanes(update)
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func refresh() async {
        status = await model.decisionsStatus()
    }
}
