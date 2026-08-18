import SiliconCatalog
import SiliconCore
import SiliconHardware
import SiliconPlanner
import SiliconRuntime
import SwiftUI

struct DashboardView: View {
    @Environment(AppModel.self) private var model

    /// Below this the two-column layout squeezes the readouts, so the cards stack instead.
    private static let twoColumnBreakpoint: CGFloat = 820

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                // A LazyVGrid would lock each row to the tallest card and leave dead space
                // under the shorter one. Two independent columns let cards stack naturally.
                // The breakpoint is measured rather than inferred — ViewThatFits reads these
                // cards' ideal width as far wider than they need and always picks one column.
                Group {
                    if proxy.size.width >= Self.twoColumnBreakpoint {
                        HStack(alignment: .top, spacing: 16) {
                            VStack(spacing: 16) {
                                machineCard
                                loadedModelCard
                                if model.loadedModel != nil { BenchmarkCard() }
                            }
                            VStack(spacing: 16) {
                                liveMemoryCard
                                throughputCard
                                swarmCard
                            }
                        }
                    } else {
                        VStack(spacing: 16) {
                            machineCard
                            liveMemoryCard
                            loadedModelCard
                            if model.loadedModel != nil { BenchmarkCard() }
                            throughputCard
                            swarmCard
                        }
                    }
                }
                .padding(20)
            }
        }
        .background(.background)
        .navigationTitle("Dashboard")
    }

    // MARK: - Machine

    private var machineCard: some View {
        Card(title: "This Mac", systemImage: "desktopcomputer") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text(model.profile.chipName)
                        .font(.title3.weight(.semibold))
                    Spacer()
                    Text(model.profile.totalMemory.formatted)
                        .font(.title3.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    specRow("CPU", "\(model.profile.performanceCores)P + \(model.profile.efficiencyCores)E")
                    specRow("GPU", "\(model.profile.gpuCores) cores")
                    specRow("Neural Engine", "\(model.profile.neuralEngineCores) cores")
                    specRow("Bandwidth", "\(Int(model.profile.memoryBandwidthGBps)) GB/s")
                    specRow("Disk free", model.profile.diskFree.formatted)
                    specRow("Model budget", model.profile.safeModelBudget.formatted)
                }

                Text(
                    "Memory bandwidth is what limits generation speed. Everything this app "
                    + "recommends is derived from these numbers."
                )
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func specRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.callout.weight(.medium))
                .monospacedDigit()
        }
    }

    // MARK: - Live memory

    private var liveMemoryCard: some View {
        Card(title: "Memory", systemImage: "memorychip") {
            VStack(alignment: .leading, spacing: 14) {
                SegmentedBar(
                    segments: [
                        .init(label: "Wired", bytes: model.metrics.memoryWired, color: .orange),
                        .init(
                            label: "Apps",
                            bytes: Bytes(max(0, model.metrics.memoryUsed.rawValue
                                - model.metrics.memoryWired.rawValue
                                - model.metrics.memoryCompressed.rawValue)),
                            color: .blue
                        ),
                        .init(label: "Compressed", bytes: model.metrics.memoryCompressed, color: .purple),
                    ],
                    total: model.metrics.memoryTotal,
                    height: 12
                )

                VStack(spacing: 6) {
                    LegendRow(color: .orange, label: "Wired", value: model.metrics.memoryWired.formatted)
                    LegendRow(color: .blue, label: "Apps",
                              value: Bytes(max(0, model.metrics.memoryUsed.rawValue
                                  - model.metrics.memoryWired.rawValue
                                  - model.metrics.memoryCompressed.rawValue)).formatted)
                    LegendRow(color: .purple, label: "Compressed",
                              value: model.metrics.memoryCompressed.formatted)
                    LegendRow(color: .secondary.opacity(0.3), label: "Free",
                              value: Bytes(max(0, model.metrics.memoryTotal.rawValue
                                  - model.metrics.memoryUsed.rawValue)).formatted)
                }

                Divider()

                HStack {
                    Label(model.metrics.memoryPressure.label,
                          systemImage: model.metrics.memoryPressure == .normal
                            ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(
                            model.metrics.memoryPressure == .normal ? .green : .orange
                        )
                    Spacer()
                    if model.metrics.swapUsed > .mib(64) {
                        Text("Swap \(model.metrics.swapUsed.formatted)")
                            .font(.callout)
                            .monospacedDigit()
                            .foregroundStyle(.orange)
                    }
                }

                Sparkline(
                    values: model.history.map(\.memoryUsedFraction),
                    tint: Palette.pressure(model.metrics.memoryUsedFraction)
                )
                .frame(height: 44)
            }
        }
    }

    // MARK: - Loaded model

    private var loadedModelCard: some View {
        Card(title: "Loaded model", systemImage: "cpu") {
            if let loaded = model.loadedModel, let configuration = model.activeConfiguration {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(loaded.name).font(.title3.weight(.semibold))
                            Text("\(loaded.quantization.rawValue) · \(configuration.contextLength.contextLabel) context")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Unload") { Task { await model.unload() } }
                            .buttonStyle(.bordered)
                    }

                    if let shape = loaded.shape {
                        let plan = model.planner().plan(
                            shape: shape, quantization: loaded.quantization,
                            configuration: configuration
                        )
                        MemoryPlanBreakdown(plan: plan)
                    }

                    if configuration.expertStreaming != nil {
                        Label(
                            "Expert streaming is on — inactive experts are being paged from disk.",
                            systemImage: "arrow.down.doc"
                        )
                        .font(.caption)
                        .foregroundStyle(.blue)
                    }

                    // An image or 3D render running alongside the loaded language model.
                    if let activity = model.activeGenerationSummary {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(activity)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else if let activity = model.activeGenerationSummary {
                // No language model, but the Images or 3D pipeline has a model working —
                // say so instead of an idle "no model" shrug.
                VStack(spacing: 10) {
                    ProgressView()
                    Text(activity)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "cpu")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text(model.runtimeState.label)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if !model.runtimeState.isBusy {
                        Button("Choose a model") { model.selectedTab = .models }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            }
        }
    }

    // MARK: - Swarm

    /// The read-only swarm: every registry peer's advertised state, polled on arrival.
    /// Absent entirely until a peer is configured — an empty card would advertise a
    /// feature instead of showing machines.
    @ViewBuilder
    private var swarmCard: some View {
        if !(model.swarmConfig?.peers.isEmpty ?? true) {
            Card(title: "Swarm", systemImage: "point.3.connected.trianglepath.dotted") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.swarmPeers) { peer in
                        peerRow(peer)
                    }
                    if model.swarmPeers.isEmpty {
                        Text("Checking peers…")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    HStack {
                        Text(model.controlIsOnLAN
                            ? "This Mac is reachable by its peers."
                            : "This Mac is local-only — enable swarm access in Settings.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Button {
                            Task { await model.refreshSwarm() }
                        } label: {
                            if model.isRefreshingSwarm {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .buttonStyle(.borderless)
                        .help("Poll the peers again")
                    }
                }
            }
            .task { await model.refreshSwarm() }
        }
    }

    private func peerRow(_ peer: AppModel.PeerStatus) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(peer.reachable ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(peer.name)
                    .font(.callout.weight(.medium))
                Text(peer.reachable
                    ? (peer.platform ?? "online")
                    : (peer.error ?? "unreachable"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if peer.reachable {
                VStack(alignment: .trailing, spacing: 1) {
                    if let headroom = peer.headroomGB {
                        Text(String(format: "%.0f GB free", headroom))
                            .font(.caption)
                            .monospacedDigit()
                    }
                    HStack(spacing: 6) {
                        if let queue = peer.queueDepth {
                            Text(queue == 0 ? "idle" : "\(queue) queued")
                        }
                        if !peer.readyCapabilities.isEmpty {
                            Text("· \(peer.readyCapabilities.count) capabilities")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: - Throughput

    private var throughputCard: some View {
        Card(title: "Performance", systemImage: "speedometer") {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 20) {
                    Gauge(
                        value: model.metrics.gpuUtilization,
                        label: "GPU",
                        caption: model.metrics.gpuMemoryInUse.formatted,
                        tint: .blue
                    )
                    Gauge(
                        value: model.metrics.cpuUtilization,
                        label: "CPU",
                        caption: "\(model.profile.performanceCores + model.profile.efficiencyCores) cores",
                        tint: .green
                    )
                    Gauge(
                        value: model.metrics.memoryUsedFraction,
                        label: "Memory",
                        caption: model.metrics.memoryUsed.formatted,
                        tint: Palette.pressure(model.metrics.memoryUsedFraction)
                    )
                }
                .frame(maxWidth: .infinity)

                Divider()

                if let generation = model.lastGeneration, generation.generatedTokens > 0 {
                    HStack {
                        Readout(
                            label: "Generation",
                            value: String(format: "%.1f", generation.generationTokensPerSecond),
                            caption: "tokens/sec"
                        )
                        Readout(
                            label: "Prompt",
                            value: String(format: "%.0f", generation.prefillTokensPerSecond),
                            caption: "tokens/sec"
                        )
                        Readout(
                            label: "First token",
                            value: String(format: "%.2fs", generation.timeToFirstToken),
                            caption: "latency"
                        )
                    }
                } else {
                    Text("Send a message to measure real throughput.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 6)
                }

                Sparkline(
                    values: model.history.map(\.gpuUtilization),
                    tint: .blue
                )
                .frame(height: 40)
            }
        }
    }
}

/// Shared memory breakdown, used on the dashboard and in the install sheet.
struct MemoryPlanBreakdown: View {
    var plan: MemoryPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SegmentedBar(
                segments: segments,
                total: plan.budget,
                height: 10
            )

            VStack(spacing: 5) {
                if plan.nonExpertWeights > .zero {
                    LegendRow(color: .blue, label: "Weights",
                              value: plan.nonExpertWeights.formatted)
                }
                if plan.expertWeights > .zero {
                    LegendRow(color: .indigo, label: "Experts (resident)",
                              value: plan.expertWeights.formatted)
                }
                LegendRow(color: .teal, label: "KV cache", value: plan.kvCache.formatted)
                LegendRow(color: .mint, label: "Compute buffers",
                          value: plan.computeBuffers.formatted)
                if plan.streamedFromDisk > .zero {
                    LegendRow(color: .gray, label: "Streamed from disk",
                              value: plan.streamedFromDisk.formatted)
                }
            }

            HStack {
                Badge(
                    text: plan.verdict.label,
                    systemImage: plan.verdict.isUsable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                    tint: Palette.verdict(plan.verdict)
                )
                Spacer()
                Text("\(plan.resident.formatted) of \(plan.budget.formatted)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var segments: [SegmentedBar.Segment] {
        var result: [SegmentedBar.Segment] = [
            .init(label: "Weights", bytes: plan.nonExpertWeights, color: .blue)
        ]
        if plan.expertWeights > .zero {
            result.append(.init(label: "Experts", bytes: plan.expertWeights, color: .indigo))
        }
        result.append(.init(label: "KV cache", bytes: plan.kvCache, color: .teal))
        result.append(.init(label: "Compute", bytes: plan.computeBuffers, color: .mint))
        return result
    }
}
