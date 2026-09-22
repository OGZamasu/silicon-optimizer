import AppKit
import SiliconControl
import SiliconCore
import SwiftUI

/// The Swarm tab: the command center for every machine in the swarm.
///
/// Layout thesis: machines lead. Each card reads identity → resources → the model
/// (the actionable core, and the visual lead) → quiet footnotes. Summary numbers live
/// in one prose line, not stat tiles; groups are separated by space, not boxes; every
/// control shares one chrome. Activity is the page's second act, with filters and an
/// inspector.
struct SwarmView: View {
    @Environment(AppModel.self) private var model

    @State private var entries: [GatewayLedgerEntry] = []
    @State private var stats: [String: GatewayModelStats] = [:]
    /// One selection for the whole page: "machine/…", "member/…", or a ledger entry
    /// id. Whatever is selected fills the always-open detail panel on the right —
    /// it defaults to this Mac, so the panel is never blank space.
    @State private var selectedItemID: String? = SwarmView.localMachineID
    @State private var collapsedMachines: Set<String> = []
    @State private var showingInvite = false
    @State private var showingJoin = false
    @State private var testing: Set<String> = []

    @State private var filterMachine = "all"
    @State private var filterOutcome = "all"
    @State private var filterEngine = "all"
    @State private var searchText = ""

    /// Selection and collapse keys a peer cannot claim: peer cards name themselves
    /// `machine/<name>` and collapse under the same key, so this Mac uses neither scheme.
    static let localMachineID = "local"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                machinesHeader
                machineGrid
                if let feedback = model.peerLLMError {
                    Label(feedback, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                peoplePanel
                activityPanel
            }
            .padding(EdgeInsets(top: 12, leading: 14, bottom: 24, trailing: 14))
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
        .inspector(isPresented: alwaysOpenInspector) {
            inspectorContent
                .inspectorColumnWidth(min: 300, ideal: 360, max: 460)
        }
        .sheet(isPresented: $showingInvite) { SwarmInviteSheet() }
        .sheet(isPresented: $showingJoin) { SwarmJoinSheet() }
        .task {
            await model.refreshSwarm()
            await model.refreshSwarmMembers()
            var tick = 0
            while !Task.isCancelled {
                if let ledger = model.gatewayLedger {
                    entries = await ledger.snapshot()
                    stats = await ledger.stats()
                }
                // Membership moves slowly; every ~30 s is plenty.
                tick += 1
                if tick.isMultiple(of: 15) {
                    await model.refreshSwarmMembers()
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// The detail panel is part of the page, not a drawer: closing it just returns
    /// it to its default subject, this Mac.
    private var alwaysOpenInspector: Binding<Bool> {
        Binding(
            get: { true },
            set: { shown in if !shown { selectedItemID = Self.localMachineID } }
        )
    }

    // MARK: - The detail panel

    @ViewBuilder
    private var inspectorContent: some View {
        if let id = selectedItemID, let entry = entries.first(where: { $0.id == id }) {
            RequestInspector(entry: entry)
        } else if let id = selectedItemID, id.hasPrefix("member/"),
                  let member = model.swarmMembers.first(where: {
                      "member/\($0.id)" == id
                  }) {
            memberInspector(member)
        } else if let id = selectedItemID, id.hasPrefix("machine/"),
                  id != Self.localMachineID,
                  let peer = model.swarmPeers.first(where: {
                      "machine/\($0.name)" == id
                  }) {
            peerMachineInspector(peer)
        } else {
            localMachineInspector
        }
    }

    private var localMachineInspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("This Mac").font(.headline)
                    Text(model.profile.chipName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                let total = model.profile.totalMemory.gibibytes
                inspectorFact(
                    "Memory",
                    String(format: "%.1f of %.0f GB in use",
                           model.metrics.memoryUsedFraction * total, total)
                )
                if let loaded = model.loadedModel {
                    inspectorFact(
                        "Serving",
                        model.runtimeState.isRunning
                            ? loaded.name : "\(loaded.name) — \(model.runtimeState.label)"
                    )
                    if let context = model.activeConfiguration?.contextLength {
                        inspectorFact("Context", "\(context / 1024)K tokens")
                    }
                } else {
                    inspectorFact("Serving", "nothing loaded")
                }
                if let rate = localRate {
                    inspectorFact("Measured", String(format: "%.1f tok/s", rate))
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Models it offers")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if model.installedModels.isEmpty {
                        Text("None installed yet — the Models tab is where they come from.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.installedModels) { installed in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(installed.name).font(.callout)
                                Text(installed.quantization.rawValue)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if model.loadedModel?.id == installed.id {
                                Text(
                                    model.runtimeState.isRunning
                                        ? "serving" : model.runtimeState.label
                                )
                                .font(.caption)
                                .foregroundStyle(.teal)
                                .lineLimit(1)
                            } else {
                                Button("Load") { model.load(installed) }
                                    .controlSize(.small)
                            }
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func peerMachineInspector(_ peer: AppModel.PeerStatus) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(peer.name).font(.headline)
                    Text(peer.hardware ?? peer.platform ?? "node")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !peer.reachable {
                    Label(peer.error ?? "Not answering right now.",
                          systemImage: "wifi.exclamationmark")
                        .font(.callout)
                        .foregroundStyle(.orange)
                } else {
                    if let total = peer.totalGB, let used = peer.usedGB {
                        inspectorFact("Memory", String(format: "%.1f of %.0f GB", used, total))
                    }
                    if let gpu = peer.gpuUtil {
                        inspectorFact("GPU", "\(Int(gpu * 100))%"
                            + (gpuCaption(peer).map { " — \($0)" } ?? ""))
                    }
                    if let llm = peer.llm {
                        inspectorFact("Chat model", llm.model.map {
                            "\($0) — \(llm.running ? (llm.healthy ? "serving" : "starting") : "stopped")"
                        } ?? "none chosen")
                        if let context = llm.contextLength {
                            inspectorFact("Context", "\(context / 1024)K tokens")
                        }
                        if let engine = llm.engine {
                            inspectorFact("Engine", engine)
                        }
                    }
                    if let rate = peerRate(peer) {
                        inspectorFact("Measured", String(format: "%.1f tok/s", rate))
                    }
                    let ready = peer.capabilities.filter(\.ready).count
                    if !peer.capabilities.isEmpty {
                        inspectorFact("Abilities",
                                      "\(ready) of \(peer.capabilities.count) ready")
                    }
                    let queued = max(
                        peer.queueDepth ?? 0,
                        peer.pendingJobs.count + (peer.runningJob == nil ? 0 : 1)
                    )
                    inspectorFact("Queue", queued == 0 ? "clear" : "\(queued) job\(queued == 1 ? "" : "s")")
                    let keys = model.swarmMembers.filter { $0.peerName == peer.name }.count
                    if keys > 0 {
                        inspectorFact("Keys", "\(keys) member\(keys == 1 ? "" : "s")")
                    }
                    if let latency = peer.latency {
                        inspectorFact("Answers in", String(format: "%.0f ms", latency * 1000))
                    }

                    if let llm = peer.llm, llm.availableModels.count > 1 {
                        Divider()
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Models it offers")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ForEach(llm.availableModels, id: \.self) { candidate in
                                HStack(spacing: 8) {
                                    Text(candidate)
                                        .font(.callout)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                    if GatewayAPI.modelNamesMatch(candidate, llm.model ?? "") {
                                        Text(llm.running ? "serving" : "chosen")
                                            .font(.caption)
                                            .foregroundStyle(llm.running ? .teal : .secondary)
                                    } else {
                                        Button("Serve") {
                                            Task {
                                                await model.setPeerLLM(
                                                    peer, running: true, model: candidate
                                                )
                                            }
                                        }
                                        .controlSize(.small)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func memberInspector(_ member: AppModel.SwarmMember) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(member.info.name).font(.headline)
                        if member.info.name == model.localMachineName {
                            Text("this Mac")
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.secondary.opacity(0.15)))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("a key to \(member.peerName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let created = member.info.created {
                    inspectorFact("Joined", String(created.prefix(16)))
                }
                if let seen = member.info.lastSeen {
                    inspectorFact("Last seen", String(seen.prefix(16)))
                }
                if let usage = memberUsage(member) {
                    inspectorFact("Usage", usage)
                }
                if let live = memberLiveActivity(member) {
                    inspectorFact("Right now", live)
                }
                if member.info.name != model.localMachineName {
                    Divider()
                    Button("Revoke their key", role: .destructive) {
                        Task { await revokeMember(member) }
                    }
                    .help("Immediate, and only them — everyone else keeps working")
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func inspectorFact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .leading)
            Text(value)
                .font(.callout)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        }
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

    // MARK: - People

    private var peoplePanel: some View {
        SwarmPanel {
            Text("People").font(.headline)
            if model.swarmMembersLoaded, !model.swarmMembers.isEmpty {
                Text("\(model.swarmMembers.count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        } content: {
            peopleRows
        }
    }

    /// Everyone holding a key to a node in this swarm, this Mac included. The nodes
    /// are the source of truth; revocation is immediate and takes only that person.
    @ViewBuilder
    private var peopleRows: some View {
        if model.swarmConfig?.effectiveToken == nil {
            Text("The member list is the owner's view — it needs the swarm's master "
                 + "key, which stays on the owner's Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if !model.swarmMembersLoaded {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Asking the nodes who holds keys…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if model.swarmMembers.isEmpty {
            Text(model.swarmPeers.contains(where: \.reachable)
                 ? "Just you so far — Invite… in the toolbar lets a friend in. (A node "
                   + "on an older silicon-node can't list members; update #125.)"
                 : "Members are listed by your nodes, and none are reachable right now.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ForEach(model.swarmMembers) { member in
                memberRow(member)
            }
            if !model.swarmMembers.contains(where: {
                $0.info.jobsTotal != nil || $0.info.llmRequests != nil
            }) {
                Text("Per-person usage counts arrive with node update #132.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func memberRow(_ member: AppModel.SwarmMember) -> some View {
        let rowID = "member/\(member.id)"
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: member.info.name == model.localMachineName
                  ? "laptopcomputer" : "person.crop.circle")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(member.info.name)
                        .fontWeight(.medium)
                    if member.info.name == model.localMachineName {
                        Text("this Mac")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(memberFacts(member))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let usage = memberUsage(member) {
                    Text(usage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if let live = memberLiveActivity(member) {
                    Text(live)
                        .font(.caption)
                        .foregroundStyle(.teal)
                }
            }
            Spacer()
            if member.info.name != model.localMachineName {
                Button("Revoke") {
                    Task { await revokeMember(member) }
                }
                .controlSize(.small)
                .help("Take back \(member.info.name)'s key to \(member.peerName) — "
                      + "immediate, and only them")
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(
            selectedItemID == rowID
                ? Color.accentColor.opacity(0.12) : .clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .contentShape(Rectangle())
        .onTapGesture { selectedItemID = rowID }
    }

    private func memberFacts(_ member: AppModel.SwarmMember) -> String {
        var parts = ["a key to \(member.peerName)"]
        if let created = member.info.created {
            parts.append("joined \(String(created.prefix(16)))")
        }
        if let seen = member.info.lastSeen {
            parts.append("seen \(String(seen.prefix(16)))")
        }
        return parts.joined(separator: " · ")
    }

    private func memberUsage(_ member: AppModel.SwarmMember) -> String? {
        var parts: [String] = []
        if let jobs = member.info.jobsTotal {
            if let byKind = member.info.jobsByKind, !byKind.isEmpty {
                let detail = byKind.sorted { $0.value > $1.value }
                    .map { "\($0.value) \($0.key)" }
                    .joined(separator: ", ")
                parts.append("\(jobs) job\(jobs == 1 ? "" : "s") — \(detail)")
            } else {
                parts.append("\(jobs) job\(jobs == 1 ? "" : "s")")
            }
        }
        if let chats = member.info.llmRequests {
            parts.append("\(chats) chat request\(chats == 1 ? "" : "s")")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// What this member is putting through the node right now, read from the queue.
    private func memberLiveActivity(_ member: AppModel.SwarmMember) -> String? {
        guard let peer = model.swarmPeers.first(where: { $0.name == member.peerName })
        else { return nil }
        var parts: [String] = []
        if let job = peer.runningJob, job.submittedBy == member.info.name {
            if let progress = job.progress {
                parts.append("rendering \(job.kind) — \(Int(progress * 100))%")
            } else {
                parts.append("rendering \(job.kind)")
            }
        }
        let queued = peer.pendingJobs.filter { $0.submittedBy == member.info.name }.count
        if queued > 0 {
            parts.append("\(queued) queued")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func revokeMember(_ member: AppModel.SwarmMember) async {
        guard let entry = model.swarmConfig?.peers
            .first(where: { $0.name == member.peerName })
        else { return }
        await model.revokeClientToken(
            on: entry, clientName: member.info.name,
            admin: model.swarmConfig?.effectiveToken
        )
        await model.refreshSwarmMembers()
    }

    // MARK: - Machines

    /// The swarm's summary is one sentence, not a row of stat tiles.
    private var machinesHeader: some View {
        HStack {
            Text("Machines")
                .font(.headline)
            Spacer()
            Text(summaryLine)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 2)
    }

    private var summaryLine: String {
        let localTotal = model.profile.totalMemory.gibibytes
        let localUsed = model.metrics.memoryUsedFraction * localTotal
        let peers = model.swarmPeers.filter(\.reachable)
        let memTotal = localTotal + peers.compactMap(\.totalGB).reduce(0, +)
        let memUsed = localUsed + peers.compactMap(\.usedGB).reduce(0, +)
        var serving = model.loadedModel != nil && model.runtimeState.isRunning ? 1 : 0
        serving += peers.filter { $0.llm?.running == true && $0.llm?.healthy == true }.count
        let queued = peers.compactMap(\.queueDepth).reduce(0, +)
        let flying = stats.values.reduce(0) { $0 + $1.inFlight }

        var parts = [
            String(format: "%.0f of %.0f GB in use", memUsed, memTotal),
            "\(serving) serving",
        ]
        parts.append(queued == 0 ? "queue clear" : "\(queued) queued")
        if flying > 0 { parts.append("\(flying) in flight") }
        return parts.joined(separator: " · ")
    }

    private var machineGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 390), spacing: 12, alignment: .top)],
            alignment: .leading, spacing: 12
        ) {
            MachineCard(
                title: "This Mac", subtitle: model.profile.chipName, reachable: true,
                collapsed: collapsedMachines.contains(Self.localMachineID),
                statusLine: localStatusLine,
                selected: selectedItemID == Self.localMachineID,
                onToggleCollapse: { toggleCollapse(Self.localMachineID) },
                onSelect: { selectedItemID = Self.localMachineID }
            ) {
                localMachineBody
            }
            ForEach(model.swarmPeers) { peer in
                MachineCard(
                    title: peer.name,
                    subtitle: peer.hardware ?? peer.platform ?? "node",
                    reachable: peer.reachable || model.peerLLMBusy.contains(peer.name),
                    collapsed: collapsedMachines.contains("machine/\(peer.name)"),
                    statusLine: peerStatusLine(peer),
                    selected: selectedItemID == "machine/\(peer.name)",
                    onToggleCollapse: { toggleCollapse("machine/\(peer.name)") },
                    onSelect: { selectedItemID = "machine/\(peer.name)" }
                ) {
                    peerMachineBody(peer)
                }
            }
        }
    }

    private func toggleCollapse(_ key: String) {
        if collapsedMachines.contains(key) {
            collapsedMachines.remove(key)
        } else {
            collapsedMachines.insert(key)
        }
    }

    /// The one line a collapsed card keeps: enough to know the machine is fine
    /// without expanding it.
    private var localStatusLine: String {
        let total = model.profile.totalMemory.gibibytes
        let memory = String(
            format: "%.1f of %.0f GB", model.metrics.memoryUsedFraction * total, total
        )
        if let loaded = model.loadedModel {
            return "\(loaded.name) \(model.runtimeState.isRunning ? "serving" : model.runtimeState.label) · \(memory)"
        }
        return "nothing loaded · \(memory)"
    }

    private func peerStatusLine(_ peer: AppModel.PeerStatus) -> String {
        if model.peerLLMBusy.contains(peer.name), !peer.reachable {
            return "working — restarting the chat model"
        }
        guard peer.reachable else {
            return peer.error ?? "not answering right now"
        }
        var parts: [String] = []
        if let llm = peer.llm, let name = llm.model {
            parts.append("\(name) \(llm.running ? (llm.healthy ? "serving" : "starting") : "stopped")")
        }
        if let total = peer.totalGB, let used = peer.usedGB {
            parts.append(String(format: "%.1f of %.0f GB", used, total))
        }
        let queued = max(
            peer.queueDepth ?? 0,
            peer.pendingJobs.count + (peer.runningJob == nil ? 0 : 1)
        )
        parts.append(queued == 0 ? "queue clear" : "\(queued) queued")
        return parts.joined(separator: " · ")
    }

    // MARK: Local card

    @ViewBuilder
    private var localMachineBody: some View {
        let total = model.profile.totalMemory.gibibytes
        MeterGrid(rows: [
            .init(label: "Memory",
                  detail: String(format: "%.1f of %.0f GB",
                                 model.metrics.memoryUsedFraction * total, total),
                  fraction: model.metrics.memoryUsedFraction)
        ])

        if let loaded = model.loadedModel {
            ModelBlock(
                name: loaded.name,
                state: model.runtimeState.isRunning ? "serving" : model.runtimeState.label,
                healthy: model.runtimeState.isRunning,
                sub: modelSubline(
                    context: model.activeConfiguration?.contextLength, rate: localRate
                )
            ) {
                Button("Unload") { Task { await model.unload() } }
                    .help("Unload \(loaded.name) from memory")
                localContextMenu
                testButton(
                    machineKey: "local",
                    gatewayID: GatewayAPI.modelID(local: loaded.id),
                    ready: model.runtimeState.isRunning
                )
            }
        } else {
            ModelBlock(
                name: "No model loaded", state: "idle", healthy: false,
                sub: localRate.map { String(format: "%.1f tok/s measured", $0) }
            ) {
                if model.lastLoaded != nil {
                    Button("Reload Last") { model.reloadLastModel() }
                }
                Button("Open Models") { model.selectedTab = .models }
            }
        }

        CardFootnotes {
            modelSwitches(
                title: "Offers",
                names: model.installedModels.map(\.name),
                rows: model.installedModels.map { installed in
                    (id: GatewayAPI.modelID(local: installed.id),
                     label: "\(installed.name) — \(installed.quantization.rawValue)")
                }
            )
            inFlightLine(forIDPrefix: "local/")
        }
    }

    /// Planner-gated presets: only sizes this model supports, and only sizes memory
    /// can hold are clickable — the rest say why they're off.
    private var localContextMenu: some View {
        Menu("Context") {
            ForEach(model.localContextChoices()) { choice in
                Button {
                    model.reloadLoadedModel(atContext: choice.tokens)
                } label: {
                    if choice.current {
                        Label(choice.label, systemImage: "checkmark")
                    } else if choice.fits {
                        Text("Reload at \(choice.label)")
                    } else {
                        Text("\(choice.label) — \(choice.reason ?? "won't fit")")
                    }
                }
                .disabled(!choice.fits || choice.current)
            }
        }
        .fixedSize()
        .help("Reload the model at a different context window — the menu only lists "
              + "sizes this model was trained for")
    }

    // MARK: Peer card

    @ViewBuilder
    private func peerMachineBody(_ peer: AppModel.PeerStatus) -> some View {
        if model.peerLLMBusy.contains(peer.name), !peer.reachable {
            // Mid start/stop the node's control server often pauses too; that is
            // busy, not gone.
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Working on it — restarting the chat model usually takes "
                     + "under a minute.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else if !peer.reachable {
            Label(peer.error ?? "Not answering right now.",
                  systemImage: "wifi.exclamationmark")
                .font(.callout)
                .foregroundStyle(.orange)
        } else {
            MeterGrid(rows: peerMeterRows(peer))

            queueBlock(peer)

            if let llm = peer.llm {
                ModelBlock(
                    name: llm.model ?? "No model chosen",
                    state: llm.running ? (llm.healthy ? "serving" : "starting") : "stopped",
                    healthy: llm.running && llm.healthy,
                    sub: peerModelSubline(peer, llm: llm)
                ) {
                    peerModelControls(peer, llm: llm)
                }
            }

            CardFootnotes {
                if !peer.capabilities.isEmpty {
                    abilitiesBlock(peer)
                }
                modelSwitches(
                    title: "Offers",
                    names: peer.llm.map { llm in
                        peerModelRows(peer, llm: llm).map(\.label)
                    } ?? [],
                    rows: peer.llm.map { peerModelRows(peer, llm: $0) } ?? []
                )
                inFlightLine(forIDPrefix: "node/\(GatewayAPI.peerSlug(peer.name))/")
                if let latency = peer.latency {
                    Text(String(format: "answers in %.0f ms", latency * 1000))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func peerMeterRows(_ peer: AppModel.PeerStatus) -> [MeterGrid.Row] {
        var rows: [MeterGrid.Row] = []
        if let total = peer.totalGB, let used = peer.usedGB {
            rows.append(.init(
                label: "Memory",
                detail: String(format: "%.1f of %.0f GB", used, total),
                fraction: total > 0 ? used / total : 0
            ))
        }
        if let gpu = peer.gpuUtil {
            rows.append(.init(
                label: "GPU",
                detail: "\(Int(gpu * 100))%",
                fraction: gpu,
                caption: gpuCaption(peer)
            ))
        }
        return rows
    }

    /// Names what the GPU is doing when the node says — and says who can't when it
    /// doesn't.
    private func gpuCaption(_ peer: AppModel.PeerStatus) -> String? {
        switch peer.gpuConsumer {
        case "llm": return "busy with the chat model"
        case "external": return "busy with something outside the swarm"
        case let consumer? where consumer.hasPrefix("job:"):
            return "busy with \(consumer.dropFirst(4))"
        case _?: return nil
        case nil:
            let util = peer.gpuUtil ?? 0
            let depth = peer.queueDepth ?? 0
            if util > 0.9, depth == 0 {
                return "busy — attribution arrives with node update #128"
            }
            return nil
        }
    }

    /// The queue as jobs when the node lists them, as consequences either way.
    @ViewBuilder
    private func queueBlock(_ peer: AppModel.PeerStatus) -> some View {
        let depth = peer.queueDepth ?? 0
        let hasJobList = peer.runningJob != nil || !peer.pendingJobs.isEmpty
        if depth > 0 || hasJobList {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "hourglass")
                        .foregroundStyle(.orange)
                        .imageScale(.small)
                    Text("\(max(depth, peer.pendingJobs.count + (peer.runningJob == nil ? 0 : 1))) "
                         + "GPU job\(depth == 1 ? "" : "s") — chat returns ~2 min after "
                         + "the queue drains")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel Queue") {
                        Task { await model.cancelPeerQueue(peer) }
                    }
                    .controlSize(.small)
                    .help("Ask \(peer.name) to drop its pending GPU jobs")
                }
                if hasJobList {
                    if let running = peer.runningJob {
                        jobRow(peer, job: running)
                    }
                    ForEach(peer.pendingJobs) { job in
                        jobRow(peer, job: job)
                    }
                } else {
                    Text("Per-job detail arrives with node update #128.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 18)
                }
            }
        }
    }

    private func jobRow(_ peer: AppModel.PeerStatus, job: AppModel.PeerJob) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(job.running ? Color.blue : Color.secondary.opacity(0.4))
                .frame(width: 5, height: 5)
            Text(job.kind)
                .font(.caption)
            if job.running, let progress = job.progress {
                Text("\(Int(progress * 100))%")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else if !job.running {
                Text("waiting")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if let submitter = job.submittedBy {
                Text("from \(submitter)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                Task { await model.cancelPeerJob(peer, jobID: job.id) }
            } label: {
                Image(systemName: "xmark.circle")
                    .imageScale(.small)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(job.running ? "Abort this job" : "Drop this job from the queue")
        }
        .padding(.leading, 18)
    }

    @ViewBuilder
    private func peerModelControls(_ peer: AppModel.PeerStatus, llm: AppModel.PeerLLM) -> some View {
        if model.peerLLMBusy.contains(peer.name) {
            ProgressView().controlSize(.small)
        } else if llm.running {
            Button("Stop \(llm.model ?? "chat model")") {
                Task { await model.setPeerLLM(peer, running: false) }
            }
            .help("Stop the chat model on \(peer.name) — renders are unaffected")
        } else {
            Button("Start \(llm.model ?? "chat model")") {
                Task {
                    await model.setPeerLLM(
                        peer, running: true,
                        contextLength: model.pendingNodeContext[peer.name]
                    )
                }
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

    /// Context choice never launches anything: a running model restarts at the size,
    /// a stopped model remembers it for the next Start.
    private func peerContextMenu(_ peer: AppModel.PeerStatus, llm: AppModel.PeerLLM) -> some View {
        Menu("Context") {
            ForEach(AppModel.swarmContextPresets, id: \.self) { size in
                Button {
                    if llm.running {
                        Task {
                            await model.setPeerLLM(
                                peer, running: true, model: llm.model, contextLength: size
                            )
                        }
                    } else {
                        model.pendingNodeContext[peer.name] = size
                    }
                } label: {
                    if size == llm.contextLength {
                        Label("\(size / 1024)K", systemImage: "checkmark")
                    } else {
                        Text(llm.running
                             ? "Restart at \(size / 1024)K"
                             : "Start next at \(size / 1024)K")
                    }
                }
                .disabled(size == llm.contextLength)
            }
            Divider()
            Text("The node clamps to what its card can hold (node update #127); "
                 + "the card shows what it actually serves.")
        }
        .fixedSize()
        .help("Choose the chat model's context window on \(peer.name)")
    }

    private func modelSubline(context: Int?, rate: Double?) -> String? {
        var parts: [String] = []
        if let context { parts.append("\(context / 1024)K context") }
        if let rate { parts.append(String(format: "%.1f tok/s measured", rate)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func peerModelSubline(
        _ peer: AppModel.PeerStatus, llm: AppModel.PeerLLM
    ) -> String? {
        var parts: [String] = []
        if let context = llm.contextLength { parts.append("\(context / 1024)K context") }
        if let staged = model.pendingNodeContext[peer.name], !llm.running {
            parts.append("starts at \(staged / 1024)K next launch")
        }
        if let rate = peerRate(peer) {
            parts.append(String(format: "%.1f tok/s measured", rate))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The abilities list, Dashboard-told: a row each, ready dot, real figures —
    /// and a click opens the full story with whatever configuration the node allows.
    private func abilitiesBlock(_ peer: AppModel.PeerStatus) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Abilities")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(peer.capabilities) { capability in
                AbilityRow(peer: peer, capability: capability)
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
        return names.map { name in
            // Nodes with more than one serving engine say which one backs the
            // loaded model (#133); a single-engine node sends nothing and the
            // label stays plain.
            var label = name
            if let engine = llm.engine, let current = llm.model,
               GatewayAPI.modelNamesMatch(name, current) {
                label += " · via \(engine)"
            }
            return (GatewayAPI.modelID(peerSlug: slug, model: name), label)
        }
    }

    @ViewBuilder
    private func modelSwitches(
        title: String, names: [String], rows: [(id: String, label: String)]
    ) -> some View {
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
                // The names themselves, not a count — "3 models" told nobody anything.
                Text("\(title) \(Self.offerSummary(names))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// "A · B · C", capped so a hoarder's library doesn't swallow the card.
    static func offerSummary(_ names: [String]) -> String {
        if names.count <= 4 { return names.joined(separator: " · ") }
        return names.prefix(3).joined(separator: " · ") + " · +\(names.count - 3) more"
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

    private var activityPanel: some View {
        SwarmPanel {
            Text("Activity").font(.headline)
        } content: {
            filterBar
            let visible = filteredEntries
            if visible.isEmpty {
                Text(entries.isEmpty
                     ? "Requests an engine sends through the model gateway appear "
                       + "here — the Test button on any machine makes the first one."
                     : "Nothing matches these filters.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(visible) { entry in
                        activityRow(entry)
                    }
                }
            }
        }
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
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
                .frame(maxWidth: 240)
            Spacer()
            // In line with the rest of the log controls, where a log control belongs.
            Button("Clear") {
                if entries.contains(where: { $0.id == selectedItemID }) {
                    selectedItemID = Self.localMachineID
                }
                entries = []
                if let ledger = model.gatewayLedger {
                    Task { await ledger.clear() }
                }
            }
            .help("Empty the list — the log file on disk is left alone")
        }
        .controlSize(.small)
        .labelsHidden()
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
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(
            selectedItemID == entry.id
                ? Color.accentColor.opacity(0.12) : .clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .contentShape(Rectangle())
        .onTapGesture { selectedItemID = entry.id }
    }

    private func requestLabel(_ entry: GatewayLedgerEntry) -> String {
        switch GatewayAPI.parseModelID(entry.modelID) {
        case .local(let install):
            let tail = install.split(separator: "/").last.map(String.init) ?? install
            return "asked \(tail) on this Mac"
        case .node(let slug, let name):
            return "asked \(name) on \(slug)"
        case .cloud(let provider, let name):
            let label = CloudProvider(rawValue: provider)?.displayName ?? provider
            return "asked \(name) on \(label)"
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

// MARK: - Card anatomy

/// The page's one panel chrome — machines, people and activity all wear it, so
/// nothing on the page lies naked next to a card.
private struct SwarmPanel<Header: View, Content: View>: View {
    @ViewBuilder var header: Header
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                header
                Spacer(minLength: 0)
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// One machine. Groups separate by space, not boxes: identity, resources, the model
/// (the lead), footnotes. Collapses to its header plus one status line — with several
/// nodes, the grid stays a glanceable list. Clicking the header puts the machine in
/// the detail panel.
private struct MachineCard<Content: View>: View {
    var title: String
    var subtitle: String
    var reachable: Bool
    var collapsed: Bool
    var statusLine: String?
    var selected: Bool
    var onToggleCollapse: () -> Void
    var onSelect: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: collapsed ? 6 : 12) {
            HStack(spacing: 7) {
                Circle()
                    .fill(reachable ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button(action: onToggleCollapse) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(collapsed ? "Expand \(title)" : "Collapse \(title) to one line")
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)

            if collapsed {
                if let statusLine {
                    Text(statusLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.leading, 15)
                }
            } else {
                content
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    selected ? Color.accentColor.opacity(0.55) : .clear, lineWidth: 1
                )
        )
    }
}

/// Meters as one aligned grid: labels share a column, bars share their width,
/// values share the trailing edge.
private struct MeterGrid: View {
    struct Row {
        var label: String
        var detail: String
        var fraction: Double
        var caption: String?
    }

    var rows: [Row]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
            ForEach(rows, id: \.label) { row in
                GridRow {
                    Text(row.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.leading)
                    ProgressView(value: min(max(row.fraction, 0), 1))
                        .progressViewStyle(.linear)
                        .tint(Palette.pressure(row.fraction))
                    Text(row.detail)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                }
                if let caption = row.caption {
                    GridRow {
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        Text(caption)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .gridCellColumns(2)
                    }
                }
            }
        }
    }
}

/// The card's lead: what this machine serves, and everything you can do about it.
private struct ModelBlock<Controls: View>: View {
    var name: String
    var state: String
    var healthy: Bool
    var sub: String?
    @ViewBuilder var controls: Controls

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(name)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(state)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(healthy ? .green : .secondary)
            }
            if let sub {
                Text(sub)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) { controls }
                .controlSize(.small)
        }
    }
}

/// The quiet tail of a card — abilities, offered models, telemetry — grouped tight
/// and set apart from the lead by space alone.
private struct CardFootnotes<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) { content }
    }
}

/// One ability row; clicking tells its full story and offers whatever configuration
/// the node allows.
private struct AbilityRow: View {
    @Environment(AppModel.self) private var model
    var peer: AppModel.PeerStatus
    var capability: AppModel.PeerCapability

    @State private var showingInfo = false
    @State private var draftSettings: [String: String] = [:]

    var body: some View {
        Button {
            draftSettings = capability.settings
            showingInfo = true
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 5, height: 5)
                Text(capability.id)
                    .font(.caption)
                Spacer()
                Text(figures)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                Image(systemName: "info.circle")
                    .imageScale(.small)
                    .foregroundStyle(.quaternary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingInfo, arrowEdge: .trailing) {
            info
        }
    }

    private var dotColor: Color {
        if capability.enabled == false { return .secondary.opacity(0.35) }
        return capability.ready ? .green : .orange
    }

    private var figures: String {
        var parts: [String] = []
        if let peak = capability.peakGB { parts.append(String(format: "%.0f GB", peak)) }
        if let seconds = capability.typicalSeconds {
            parts.append(seconds >= 60
                         ? String(format: "%.0f min", seconds / 60)
                         : String(format: "%.0fs", seconds))
        }
        return parts.joined(separator: " · ")
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(capability.id)
                    .font(.headline)
                if !capability.kind.isEmpty {
                    Text(capability.kind)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(capability.ready ? "ready" : "not ready")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(capability.ready ? .green : .orange)
            }

            Text(capability.description ?? capability.detail
                 ?? "No description from the node yet — richer ability info arrives "
                 + "with node update #129.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                if let peak = capability.peakGB {
                    GridRow {
                        Text("Peak memory").foregroundStyle(.secondary)
                        Text(String(format: "%.0f GB", peak)).monospacedDigit()
                    }
                }
                if let seconds = capability.typicalSeconds {
                    GridRow {
                        Text("Typical run").foregroundStyle(.secondary)
                        Text(seconds >= 60
                             ? String(format: "%.0f min", seconds / 60)
                             : String(format: "%.0f s", seconds)).monospacedDigit()
                    }
                }
            }
            .font(.caption)

            if capability.enabled != nil || !capability.settings.isEmpty {
                Divider()
            }

            if let enabled = capability.enabled {
                Toggle("Enabled on \(peer.name)", isOn: Binding(
                    get: { enabled },
                    set: { newValue in
                        Task {
                            await model.configurePeerCapability(
                                peer, id: capability.id, enabled: newValue
                            )
                        }
                    }
                ))
                .controlSize(.small)
            }

            if !capability.settings.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Settings")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(capability.settings.keys.sorted(), id: \.self) { key in
                        HStack(spacing: 6) {
                            Text(key)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextField("", text: Binding(
                                get: { draftSettings[key] ?? "" },
                                set: { draftSettings[key] = $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                            .frame(width: 130)
                        }
                    }
                    Button("Apply") {
                        Task {
                            await model.configurePeerCapability(
                                peer, id: capability.id, settings: draftSettings
                            )
                        }
                    }
                    .controlSize(.small)
                    .disabled(draftSettings == capability.settings)
                }
            }

            if capability.enabled == nil, capability.settings.isEmpty {
                Text("On/off and settings arrive with node update #129.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
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