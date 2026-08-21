import AppKit
import SiliconControl
import SwiftUI

/// The Swarm tab: the command center for every machine in the swarm. One card per
/// machine — what it is, what it's serving, what's queued on its GPU, with the same
/// start/stop/switch control the menu bar has — and underneath, the gateway's request
/// ledger with an inspector for any row. Pairing lives here too: this is where new
/// members are let in.
struct SwarmView: View {
    @Environment(AppModel.self) private var model

    @State private var entries: [GatewayLedgerEntry] = []
    @State private var stats: [String: GatewayModelStats] = [:]
    @State private var selectedEntryID: String?
    @State private var showingInvite = false
    @State private var showingJoin = false

    var body: some View {
        List(selection: $selectedEntryID) {
            Section {
                machineGrid
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    .listRowSeparator(.hidden)
                if let feedback = model.peerLLMError {
                    Label(feedback, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .listRowSeparator(.hidden)
                }
            } header: {
                machinesHeader
            }

            Section {
                if entries.isEmpty {
                    Text("No gateway traffic yet. Every request an engine routes through "
                         + "the model gateway shows up here — pick a row for the full story.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(entries) { entry in
                        activityRow(entry)
                            .tag(entry.id)
                    }
                }
            } header: {
                Text("Activity")
            }
        }
        .navigationTitle("Swarm")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showingInvite = true
                } label: {
                    Label("Invite…", systemImage: "person.crop.circle.badge.plus")
                }
                .help("Let another Silicon Optimizer join this swarm")
                Button {
                    showingJoin = true
                } label: {
                    Label("Join…", systemImage: "point.3.filled.connected.trianglepath.dotted")
                }
                .help("Join someone else's swarm")
                Menu {
                    Toggle("Keep request previews", isOn: previewsBinding)
                    Button("Reveal Ledger in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([ledgerURL])
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .inspector(isPresented: inspectorShown) {
            if let entry = entries.first(where: { $0.id == selectedEntryID }) {
                RequestInspector(entry: entry)
                    .inspectorColumnWidth(min: 300, ideal: 360, max: 460)
            }
        }
        .sheet(isPresented: $showingInvite) { SwarmInviteSheet() }
        .sheet(isPresented: $showingJoin) { SwarmJoinSheet() }
        .task {
            await model.refreshSwarm()
            while !Task.isCancelled {
                if let ledger = model.gatewayLedger {
                    entries = await ledger.snapshot()
                    stats = await ledger.stats()
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var inspectorShown: Binding<Bool> {
        Binding(
            get: { selectedEntryID != nil },
            set: { shown in if !shown { selectedEntryID = nil } }
        )
    }

    private var ledgerURL: URL {
        SwarmConfig.configURL.deletingLastPathComponent()
            .appendingPathComponent("gateway-ledger.jsonl")
    }

    private var previewsBinding: Binding<Bool> {
        Binding(
            get: { model.settings.fleetPreviewsEnabled ?? true },
            set: { enabled in
                model.settings.fleetPreviewsEnabled = enabled
                model.settings.save()
                if let ledger = model.gatewayLedger {
                    Task { await ledger.setPreviews(enabled) }
                }
            }
        )
    }

    // MARK: - Machines

    private var machinesHeader: some View {
        HStack {
            Text("Machines")
            Spacer()
            let reachable = model.swarmPeers.filter(\.reachable).count
            Text("\(model.swarmPeers.count + 1) in the swarm · "
                 + "\(reachable + 1) reachable")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(nil)
        }
    }

    private var machineGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 360), spacing: 12, alignment: .top)],
            alignment: .leading, spacing: 12
        ) {
            MachineCard(
                title: "This Mac", subtitle: model.profile.chipName, reachable: true
            ) {
                localMachineBody
            }
            ForEach(model.swarmPeers) { peer in
                MachineCard(
                    title: peer.name,
                    subtitle: peer.hardware ?? peer.platform ?? "node",
                    reachable: peer.reachable
                ) {
                    peerMachineBody(peer)
                }
            }
        }
    }

    @ViewBuilder
    private var localMachineBody: some View {
        let total = model.profile.totalMemory.gibibytes
        MeterRow(
            label: "Memory",
            detail: String(format: "%.1f of %.0f GB",
                           model.metrics.memoryUsedFraction * total, total),
            fraction: model.metrics.memoryUsedFraction
        )

        Divider()

        if let loaded = model.loadedModel {
            LLMRow(
                model: loaded.name,
                state: model.runtimeState.isRunning ? "serving" : model.runtimeState.label,
                healthy: model.runtimeState.isRunning,
                context: model.activeConfiguration?.contextLength,
                rate: localRate
            )
            HStack(spacing: 8) {
                Button("Unload") { Task { await model.unload() } }
                Button("Open Models") { model.selectedTab = .models }
            }
            .controlSize(.small)
        } else {
            LLMRow(model: "No model loaded", state: "idle", healthy: false,
                   context: nil, rate: localRate)
            HStack(spacing: 8) {
                if model.lastLoaded != nil {
                    Button("Reload Last") { model.reloadLastModel() }
                }
                Button("Open Models") { model.selectedTab = .models }
            }
            .controlSize(.small)
        }

        inFlightLine(forIDPrefix: "local/")
    }

    @ViewBuilder
    private func peerMachineBody(_ peer: AppModel.PeerStatus) -> some View {
        if !peer.reachable {
            Label(peer.error ?? "Not answering right now.",
                  systemImage: "wifi.exclamationmark")
                .font(.caption)
                .foregroundStyle(.orange)
        } else {
            if let total = peer.totalGB, let used = peer.usedGB {
                MeterRow(
                    label: "Memory",
                    detail: String(format: "%.1f of %.0f GB", used, total),
                    fraction: total > 0 ? used / total : 0
                )
            }
            if let gpu = peer.gpuUtil {
                MeterRow(
                    label: "GPU",
                    detail: "\(Int(gpu * 100))%",
                    fraction: gpu
                )
            }

            queueRow(peer)

            Divider()

            if let llm = peer.llm {
                LLMRow(
                    model: llm.model ?? "no model chosen",
                    state: llm.running ? (llm.healthy ? "serving" : "starting") : "stopped",
                    healthy: llm.running && llm.healthy,
                    context: llm.contextLength,
                    rate: peerRate(peer)
                )
                peerLLMButtons(peer, llm: llm)
            }

            if !peer.readyCapabilities.isEmpty {
                capabilityChips(peer.readyCapabilities)
            }

            inFlightLine(forIDPrefix: "node/\(GatewayAPI.peerSlug(peer.name))/")

            if let latency = peer.latency {
                Text(String(format: "answers in %.0f ms", latency * 1000))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// The GPU job queue, spelled out — this is the line that explains why chat
    /// suddenly refuses while a render runs.
    @ViewBuilder
    private func queueRow(_ peer: AppModel.PeerStatus) -> some View {
        let depth = peer.queueDepth ?? 0
        HStack(spacing: 8) {
            Image(systemName: depth > 0 ? "hourglass" : "checkmark.circle")
                .foregroundStyle(depth > 0 ? .orange : .green)
                .imageScale(.small)
            if depth > 0 {
                Text("\(depth) GPU job\(depth == 1 ? "" : "s") queued — chat returns "
                     + "~2 min after the queue drains")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel Queue") {
                    Task { await model.cancelPeerQueue(peer) }
                }
                .controlSize(.small)
                .help("Ask \(peer.name) to drop its pending GPU jobs")
            } else {
                Text("GPU queue clear")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private func peerLLMButtons(_ peer: AppModel.PeerStatus, llm: AppModel.PeerLLM) -> some View {
        HStack(spacing: 8) {
            if model.peerLLMBusy.contains(peer.name) {
                ProgressView().controlSize(.small)
            } else if llm.running {
                Button("Stop") {
                    Task { await model.setPeerLLM(peer, running: false) }
                }
            } else {
                Button("Start") {
                    Task { await model.setPeerLLM(peer, running: true) }
                }
            }
            if llm.availableModels.count > 1 {
                Menu("Switch Model") {
                    ForEach(llm.availableModels, id: \.self) { candidate in
                        Button(candidate) {
                            Task { await model.setPeerLLM(peer, running: true, model: candidate) }
                        }
                        .disabled(GatewayAPI.modelNamesMatch(candidate, llm.model ?? ""))
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .controlSize(.small)
    }

    private func capabilityChips(_ capabilities: [String]) -> some View {
        HStack(spacing: 5) {
            ForEach(capabilities.prefix(6), id: \.self) { capability in
                Text(capability)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
        }
    }

    @ViewBuilder
    private func inFlightLine(forIDPrefix prefix: String) -> some View {
        let flying = stats.filter { $0.key.hasPrefix(prefix) }
            .values.reduce(0) { $0 + $1.inFlight }
        if flying > 0 {
            Label("\(flying) request\(flying == 1 ? "" : "s") in flight",
                  systemImage: "circle.dotted")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private var localRate: Double? {
        stats.filter { $0.key.hasPrefix("local/") }
            .compactMap(\.value.tokensPerSecond).max()
    }

    private func peerRate(_ peer: AppModel.PeerStatus) -> Double? {
        let prefix = "node/\(GatewayAPI.peerSlug(peer.name))/"
        return stats.filter { $0.key.hasPrefix(prefix) }
            .compactMap(\.value.tokensPerSecond).max()
    }

    // MARK: - Activity

    private func activityRow(_ entry: GatewayLedgerEntry) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor(entry))
                .frame(width: 8, height: 8)
            Text(entry.startedAt, format: .dateTime.hour().minute().second())
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(requestLabel(entry))
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            if entry.warning != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .imageScale(.small)
                    .foregroundStyle(.orange)
            }
            Spacer()
            if let output = entry.outputTokens {
                Text("\(output) tok")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if let total = entry.totalMs {
                Text(total >= 1000
                     ? String(format: "%.1fs", Double(total) / 1000)
                     : "\(total)ms")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small).scaleEffect(0.6)
            }
        }
        .padding(.vertical, 1)
    }

    /// "asked qwen3.8-27b on silicon-node" — the sentence form, so a request never
    /// reads as another machine or another model instance.
    private func requestLabel(_ entry: GatewayLedgerEntry) -> String {
        switch GatewayAPI.parseModelID(entry.modelID) {
        case .local(let install):
            let tail = install.split(separator: "/").last.map(String.init) ?? install
            return "asked \(tail) on this Mac"
        case .node(let slug, let name):
            return "asked \(name) on \(slug)"
        case nil:
            return entry.modelID
        }
    }

    private func statusColor(_ entry: GatewayLedgerEntry) -> Color {
        switch entry.ok {
        case nil: .orange
        case true?: entry.warning == nil ? .green : .yellow
        case false?: .red
        }
    }
}

// MARK: - Pieces

/// One machine's card: header with reachability, then whatever the machine has to say.
private struct MachineCard<Content: View>: View {
    var title: String
    var subtitle: String
    var reachable: Bool
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Circle()
                    .fill(reachable ? Color.green : Color.orange)
                    .frame(width: 9, height: 9)
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct MeterRow: View {
    var label: String
    var detail: String
    var fraction: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.caption.weight(.medium))
                Spacer()
                Text(detail)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: min(max(fraction, 0), 1))
                .progressViewStyle(.linear)
                .tint(Palette.pressure(fraction))
        }
    }
}

private struct LLMRow: View {
    var model: String
    var state: String
    var healthy: Bool
    var context: Int?
    var rate: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                Text(model)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(state)
                    .font(.caption)
                    .foregroundStyle(healthy ? .green : .secondary)
            }
            HStack(spacing: 10) {
                if let context {
                    Text("\(context / 1024)K context")
                }
                if let rate {
                    Text(String(format: "%.1f tok/s measured", rate))
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }
}

/// The full story of one request, told beside the list.
private struct RequestInspector: View {
    @Environment(AppModel.self) private var model
    let entry: GatewayLedgerEntry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header

                if let warning = entry.warning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let detail = entry.detail {
                    Label(detail, systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(entry.ok == false ? .red : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                timing

                if let prompt = entry.promptPreview {
                    block(title: "Asked", text: prompt)
                }
                if let answer = entry.responsePreview {
                    block(title: "Answered", text: answer)
                }
                if entry.promptPreview == nil, entry.responsePreview == nil {
                    Text("Previews are off — only metadata was kept for this request.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                facts

                Button {
                    copyJSON()
                } label: {
                    Label("Copy as JSON", systemImage: "doc.on.doc")
                }
                .controlSize(.small)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.modelID)
                .font(.headline)
                .textSelection(.enabled)
            Text(entry.startedAt, format: .dateTime.month().day().hour().minute().second())
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Where the time went: making the model ready (loads, node starts, waits)
    /// versus actually generating.
    @ViewBuilder
    private var timing: some View {
        if let total = entry.totalMs {
            let ensure = entry.ensureMs ?? 0
            let generate = max(total - ensure, 0)
            VStack(alignment: .leading, spacing: 4) {
                Text("Timing")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                GeometryReader { proxy in
                    HStack(spacing: 1) {
                        if ensure > 0 {
                            Rectangle()
                                .fill(.orange.opacity(0.75))
                                .frame(width: proxy.size.width
                                       * CGFloat(ensure) / CGFloat(max(total, 1)))
                        }
                        Rectangle().fill(.blue.opacity(0.75))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                .frame(height: 8)
                HStack(spacing: 12) {
                    if ensure > 0 {
                        Label(seconds(ensure) + " getting ready", systemImage: "square.fill")
                            .foregroundStyle(.orange)
                    }
                    Label(seconds(generate) + " generating", systemImage: "square.fill")
                        .foregroundStyle(.blue)
                }
                .font(.caption2)
                .labelStyle(.titleAndIcon)
                .imageScale(.small)
            }
        }
    }

    private var facts: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            fact("Endpoint", entry.endpoint + (entry.stream ? " · streamed" : ""))
            if let backend = entry.backendModel { fact("Backend model", backend) }
            fact("Prompt size", "\(entry.promptChars) characters")
            if let prompt = entry.promptTokens { fact("Prompt tokens", "\(prompt)") }
            if let output = entry.outputTokens { fact("Output tokens", "\(output)") }
            if let rate = entry.tokensPerSecond {
                fact("Speed", String(format: "%.1f tok/s", rate))
            }
            fact("Verdict", entry.ok == nil ? "in flight"
                 : entry.ok == true ? "answered" : "failed")
        }
        .font(.caption)
    }

    private func fact(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    private func block(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func seconds(_ ms: Int) -> String {
        ms >= 1000 ? String(format: "%.1fs", Double(ms) / 1000) : "\(ms)ms"
    }

    private func copyJSON() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entry),
              let text = String(data: data, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}