import AppKit
import SiliconControl
import SwiftUI

/// The Swarm tab: the command center for every machine in the swarm. A capacity strip,
/// then one card per machine — meters, abilities with their real figures, the serving
/// model with planner-gated context control and per-model visibility switches, a GPU
/// queue spelled out in consequences, and a Test button that proves the whole path.
/// Underneath, the gateway's request ledger with filters and an inspector.
struct SwarmView: View {
    @Environment(AppModel.self) private var model

    @State private var entries: [GatewayLedgerEntry] = []
    @State private var stats: [String: GatewayModelStats] = [:]
    @State private var selectedEntryID: String?
    @State private var showingInvite = false
    @State private var showingJoin = false
    @State private var testing: Set<String> = []

    // Activity filters
    @State private var filterMachine = "all"
    @State private var filterOutcome = "all"
    @State private var filterEngine = "all"
    @State private var searchText = ""

    var body: some View {
        List(selection: $selectedEntryID) {
            Section {
                capacityStrip
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 2, trailing: 12))
                    .listRowSeparator(.hidden)
                machineGrid
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 8, trailing: 12))
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
                filterBar
                    .listRowSeparator(.hidden)
                let visible = filteredEntries
                if visible.isEmpty {
                    Text(entries.isEmpty
                         ? "No gateway traffic yet. Every request an engine routes through "
                           + "the model gateway shows up here — pick a row for the full story."
                         : "Nothing matches these filters.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(visible) { entry in
                        activityRow(entry)
                            .tag(entry.id)
                    }
                }
            } header: {
                HStack {
                    Text("Activity")
                    Spacer()
                    Button("Clear") {
                        selectedEntryID = nil
                        entries = []
                        if let ledger = model.gatewayLedger {
                            Task { await ledger.clear() }
                        }
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Empty the list — the log file on disk is left alone")
                }
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

    // MARK: - Capacity

    /// One glance: what the whole swarm can do right now.
    private var capacityStrip: some View {
        let localTotal = model.profile.totalMemory.gibibytes
        let localUsed = model.metrics.memoryUsedFraction * localTotal
        let peers = model.swarmPeers.filter(\.reachable)
        let memTotal = localTotal + peers.compactMap(\.totalGB).reduce(0, +)
        let memUsed = localUsed + peers.compactMap(\.usedGB).reduce(0, +)
        var serving = model.loadedModel != nil && model.runtimeState.isRunning ? 1 : 0
        serving += peers.filter { $0.llm?.running == true && $0.llm?.healthy == true }.count
        let queued = peers.compactMap(\.queueDepth).reduce(0, +)
        let flying = stats.values.reduce(0) { $0 + $1.inFlight }

        return HStack(spacing: 10) {
            capacityCell(
                value: String(format: "%.0f of %.0f GB", memUsed, memTotal),
                label: "memory across the swarm"
            )
            capacityCell(
                value: "\(serving)",
                label: serving == 1 ? "model serving" : "models serving"
            )
            capacityCell(
                value: "\(queued)",
                label: queued == 1 ? "GPU job queued" : "GPU jobs queued",
                tint: queued > 0 ? .orange : nil
            )
            capacityCell(
                value: "\(flying)",
                label: flying == 1 ? "request in flight" : "requests in flight",
                tint: flying > 0 ? .blue : nil
            )
        }
    }

    private func capacityCell(value: String, label: String, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(tint ?? .primary)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
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
            columns: [GridItem(.adaptive(minimum: 380), spacing: 12, alignment: .top)],
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
                Button("Unload \(loaded.name)") { Task { await model.unload() } }
                localContextMenu
                testButton(
                    machineKey: "local",
                    gatewayID: GatewayAPI.modelID(local: loaded.id),
                    ready: model.runtimeState.isRunning
                )
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

        modelSwitches(
            title: "Offered by this Mac",
            rows: model.installedModels.map { installed in
                (id: GatewayAPI.modelID(local: installed.id),
                 label: "\(installed.name) — \(installed.quantization.rawValue)")
            }
        )

        inFlightLine(forIDPrefix: "local/")
    }

    /// Planner-gated context presets: sizes that fit are one click; sizes that don't
    /// say why they're off instead of failing later.
    private var localContextMenu: some View {
        Menu("Context") {
            ForEach(model.localContextChoices()) { choice in
                Button {
                    model.reloadLoadedModel(atContext: choice.tokens)
                } label: {
                    if choice.current {
                        Label(choice.label, systemImage: "checkmark")
                    } else if choice.fits {
                        Text(choice.label)
                    } else {
                        Text("\(choice.label) — \(choice.reason ?? "won't fit")")
                    }
                }
                .disabled(!choice.fits || choice.current)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Reload the model at a different context window")
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
                MeterRow(label: "GPU", detail: "\(Int(gpu * 100))%", fraction: gpu)
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
                modelSwitches(
                    title: "Offered by \(peer.name)",
                    rows: peerModelRows(peer, llm: llm)
                )
            }

            if !peer.capabilities.isEmpty {
                abilities(peer)
            }

            inFlightLine(forIDPrefix: "node/\(GatewayAPI.peerSlug(peer.name))/")

            if let latency = peer.latency {
                Text(String(format: "answers in %.0f ms", latency * 1000))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// The abilities list, the way the Dashboard tells it: one row each, ready dot,
    /// and the real figures — peak memory, typical duration — not a pile of chips.
    private func abilities(_ peer: AppModel.PeerStatus) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Abilities")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(peer.capabilities) { capability in
                HStack(spacing: 6) {
                    Circle()
                        .fill(capability.ready ? Color.green : Color.secondary.opacity(0.35))
                        .frame(width: 5, height: 5)
                    Text(capability.id)
                        .font(.caption2)
                    Spacer()
                    Text(capabilityFigures(capability))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                .help(capability.detail ?? capability.id)
            }
        }
    }

    private func capabilityFigures(_ capability: AppModel.PeerCapability) -> String {
        var parts: [String] = []
        if let peak = capability.peakGB { parts.append(String(format: "%.0f GB", peak)) }
        if let seconds = capability.typicalSeconds {
            parts.append(seconds >= 60
                         ? String(format: "%.0f min", seconds / 60)
                         : String(format: "%.0fs", seconds))
        }
        return parts.joined(separator: " · ")
    }

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
                // Named, so there is no wondering what stops: the chat model, not
                // the node and not its render queue.
                Button("Stop \(llm.model ?? "chat model")") {
                    Task { await model.setPeerLLM(peer, running: false) }
                }
                .help("Stop the chat model on \(peer.name) — renders are unaffected")
            } else {
                Button("Start \(llm.model ?? "chat model")") {
                    Task { await model.setPeerLLM(peer, running: true) }
                }
                .help("Start the chat model on \(peer.name)")
            }
            if llm.availableModels.count > 1 {
                Menu("Switch") {
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
            peerContextMenu(peer, llm: llm)
            testButton(
                machineKey: peer.name,
                gatewayID: llm.model.map {
                    GatewayAPI.modelID(peerSlug: GatewayAPI.peerSlug(peer.name), model: $0)
                },
                ready: llm.running && llm.healthy
            )
        }
        .controlSize(.small)
    }

    private func peerContextMenu(_ peer: AppModel.PeerStatus, llm: AppModel.PeerLLM) -> some View {
        Menu("Context") {
            ForEach(AppModel.swarmContextPresets, id: \.self) { size in
                Button {
                    Task {
                        await model.setPeerLLM(
                            peer, running: true, model: llm.model, contextLength: size
                        )
                    }
                } label: {
                    if size == llm.contextLength {
                        Label("\(size / 1024)K", systemImage: "checkmark")
                    } else {
                        Text("\(size / 1024)K")
                    }
                }
                .disabled(size == llm.contextLength)
            }
            Divider()
            Text("Restarts the model at that size — needs the node update (#127); "
                 + "older nodes start at their own profile.")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Restart \(peer.name)'s chat model with a different context window")
    }

    /// Per-model visibility: switched-off models stay installed and startable from
    /// Models, but vanish from the gateway and every engine picker.
    @ViewBuilder
    private func modelSwitches(title: String, rows: [(id: String, label: String)]) -> some View {
        if rows.count > 1 {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(rows, id: \.id) { row in
                        Toggle(isOn: Binding(
                            get: { !model.isGatewayModelHidden(row.id) },
                            set: { model.setGatewayModel(row.id, hidden: !$0) }
                        )) {
                            Text(row.label)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                    }
                    Text("Unchecked models disappear from every engine's picker.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.top, 2)
            } label: {
                Text("\(title) (\(rows.count) models)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func peerModelRows(
        _ peer: AppModel.PeerStatus, llm: AppModel.PeerLLM
    ) -> [(id: String, label: String)] {
        let slug = GatewayAPI.peerSlug(peer.name)
        var names: [String] = []
        if let current = llm.model { names.append(current) }
        for candidate in llm.availableModels
        where !names.contains(where: { GatewayAPI.modelNamesMatch($0, candidate) }) {
            names.append(candidate)
        }
        return names.map { (GatewayAPI.modelID(peerSlug: slug, model: $0), $0) }
    }

    @ViewBuilder
    private func testButton(machineKey: String, gatewayID: String?, ready: Bool) -> some View {
        if testing.contains(machineKey) {
            ProgressView().controlSize(.small)
        } else {
            Button("Test") {
                guard let gatewayID else { return }
                testing.insert(machineKey)
                Task {
                    await model.testMachine(gatewayModelID: gatewayID)
                    testing.remove(machineKey)
                }
            }
            .disabled(gatewayID == nil || !ready)
            .help(ready
                  ? "Send a one-line prompt through the gateway — the result lands in Activity"
                  : "Start the model first, then prove the path with one click")
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

    private var filterBar: some View {
        HStack(spacing: 10) {
            Picker("Machine", selection: $filterMachine) {
                Text("All machines").tag("all")
                Text("This Mac").tag("local")
                ForEach(model.swarmPeers) { peer in
                    Text(peer.name).tag(GatewayAPI.peerSlug(peer.name))
                }
            }
            .fixedSize()
            Picker("Outcome", selection: $filterOutcome) {
                Text("Any outcome").tag("all")
                Text("Warnings").tag("warnings")
                Text("Failures").tag("failures")
            }
            .fixedSize()
            Picker("Engine", selection: $filterEngine) {
                Text("Any engine").tag("all")
                Text("chat").tag("chat")
                Text("responses").tag("responses")
            }
            .fixedSize()
            TextField("Search prompts and answers", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
            Spacer()
        }
        .labelsHidden()
        .font(.caption)
    }

    private var filteredEntries: [GatewayLedgerEntry] {
        entries.filter { entry in
            switch filterMachine {
            case "all": break
            case "local":
                guard entry.modelID.hasPrefix("local/") else { return false }
            default:
                guard entry.modelID.hasPrefix("node/\(filterMachine)/") else { return false }
            }
            switch filterOutcome {
            case "warnings": guard entry.warning != nil else { return false }
            case "failures": guard entry.ok == false else { return false }
            default: break
            }
            if filterEngine != "all", entry.endpoint != filterEngine { return false }
            if !searchText.isEmpty {
                let haystack = [entry.promptPreview, entry.responsePreview, entry.modelID]
                    .compactMap(\.self).joined(separator: " ").lowercased()
                guard haystack.contains(searchText.lowercased()) else { return false }
            }
            return true
        }
    }

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