import AppKit
import SiliconControl
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
    @State private var selectedEntryID: String?
    @State private var showingInvite = false
    @State private var showingJoin = false
    @State private var testing: Set<String> = []

    @State private var filterMachine = "all"
    @State private var filterOutcome = "all"
    @State private var filterEngine = "all"
    @State private var searchText = ""

    var body: some View {
        List(selection: $selectedEntryID) {
            Section {
                machineGrid
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 10, trailing: 12))
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
                peopleRows
            } header: {
                HStack(spacing: 8) {
                    Text("People")
                    if model.swarmMembersLoaded, model.swarmMembers.count > 1 {
                        Text("\(model.swarmMembers.count)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }

            Section {
                filterBar
                    .listRowSeparator(.hidden)
                let visible = filteredEntries
                if visible.isEmpty {
                    Text(entries.isEmpty
                         ? "Requests an engine sends through the model gateway appear "
                           + "here — the Test button on any machine makes the first one."
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
                HStack(spacing: 8) {
                    Text("Activity")
                    Spacer()
                    Button("Clear") {
                        selectedEntryID = nil
                        entries = []
                        if let ledger = model.gatewayLedger {
                            Task { await ledger.clear() }
                        }
                    }
                    .controlSize(.small)
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

    // MARK: - People

    /// Everyone holding a key to a node in this swarm, this Mac included. The nodes
    /// are the source of truth; revocation is immediate and takes only that person.
    @ViewBuilder
    private var peopleRows: some View {
        if model.swarmConfig?.effectiveToken == nil {
            Text("The member list is the owner's view — it needs the swarm's master "
                 + "key, which stays on the owner's Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .listRowSeparator(.hidden)
        } else if !model.swarmMembersLoaded {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Asking the nodes who holds keys…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .listRowSeparator(.hidden)
        } else if model.swarmMembers.isEmpty {
            Text(model.swarmPeers.contains(where: \.reachable)
                 ? "Just you so far — Invite… in the toolbar lets a friend in. (A node "
                   + "on an older silicon-node can't list members; update #125.)"
                 : "Members are listed by your nodes, and none are reachable right now.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .listRowSeparator(.hidden)
        } else {
            ForEach(model.swarmMembers) { member in
                memberRow(member)
                    .listRowSeparator(.hidden)
            }
            if !model.swarmMembers.contains(where: {
                $0.info.jobsTotal != nil || $0.info.llmRequests != nil
            }) {
                Text("Per-person usage counts arrive with node update #132.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .listRowSeparator(.hidden)
            }
        }
    }

    private func memberRow(_ member: AppModel.SwarmMember) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
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
        .padding(.vertical, 2)
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
            Spacer()
            Text(summaryLine)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .textCase(nil)
        }
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
                title: "This Mac", subtitle: model.profile.chipName, reachable: true
            ) {
                localMachineBody
            }
            ForEach(model.swarmPeers) { peer in
                MachineCard(
                    title: peer.name,
                    subtitle: peer.hardware ?? peer.platform ?? "node",
                    reachable: peer.reachable || model.peerLLMBusy.contains(peer.name)
                ) {
                    peerMachineBody(peer)
                }
            }
        }
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
                title: "Offered by this Mac",
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
                    title: "Offered by \(peer.name)",
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
        return names.map { (GatewayAPI.modelID(peerSlug: slug, model: $0), $0) }
    }

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
                Text("\(title) · \(rows.count) models")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
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

// MARK: - Card anatomy

/// One machine. Groups separate by space, not boxes: identity, resources, the model
/// (the lead), footnotes.
private struct MachineCard<Content: View>: View {
    var title: String
    var subtitle: String
    var reachable: Bool
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
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