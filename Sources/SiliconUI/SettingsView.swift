import SiliconCatalog
import SiliconControl
import SiliconCore
import SiliconPlanner
import SiliconRuntime
import SwiftUI

/// Settings, in six panes.
///
/// This was one `Form` with twenty sections in it, and finding anything meant scrolling
/// past everything. The sections themselves were fine; the single scroll was not. They are
/// grouped here by what you came to do — how the app behaves, which models it can run, what
/// answers chat, where media lands, what other machines may reach — with the pane you last
/// used remembered, and Advanced offered only when the Behaviour toggle asks for it.
///
/// Nothing was dropped. Decisions and the TypeSafe account moved out of Settings entirely,
/// to ``DecisionsView`` in the sidebar, because a control panel for every decision the app
/// makes is a place you go, not a section you scroll to.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var templateStatus = ""
    @State private var fetchingTemplate = false
    @State private var showingSwarmInvite = false
    @State private var showingSwarmJoin = false

    /// One group of settings, in the order the segmented control shows them.
    enum Pane: String, CaseIterable, Identifiable {
        case general = "General"
        case models = "Models"
        case chat = "Chat"
        case media = "Media"
        case devices = "Devices"
        case advanced = "Advanced"

        var id: String { rawValue }

        /// The panes on offer. Advanced appears only while Behaviour asks for it: hiding it
        /// keeps the gate that was already on those controls, and an empty pane would be a
        /// worse answer than no pane.
        static func offered(showingAdvanced: Bool) -> [Pane] {
            showingAdvanced ? allCases : allCases.filter { $0 != .advanced }
        }

        /// The pane to show, given what was remembered from last time. A remembered pane
        /// that is no longer offered — Advanced, after the toggle goes off — falls back to
        /// General rather than leaving the window blank.
        static func resolve(remembered: String, showingAdvanced: Bool) -> Pane {
            let offered = offered(showingAdvanced: showingAdvanced)
            guard let pane = Pane(rawValue: remembered), offered.contains(pane) else {
                return .general
            }
            return pane
        }
    }

    /// Remembered across launches: settings are usually reopened to change the same thing
    /// again, and landing back on General every time is its own small tax.
    @AppStorage("settings.pane") private var storedPane = Pane.general.rawValue

    /// The panes the segmented control offers right now.
    private var panes: [Pane] {
        Pane.offered(showingAdvanced: model.settings.showAdvancedControls)
    }

    /// The pane on screen.
    private var pane: Pane {
        Pane.resolve(
            remembered: storedPane,
            showingAdvanced: model.settings.showAdvancedControls
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Settings pane", selection: Binding(
                get: { pane },
                set: { storedPane = $0.rawValue }
            )) {
                ForEach(panes) { pane in
                    Text(pane.rawValue).tag(pane)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 10)

            Divider()

            Form {
                switch pane {
                case .general: generalPane
                case .models: modelsPane
                case .chat: chatPane
                case .media: mediaPane
                case .devices: devicesPane
                case .advanced: advancedPane
                }
            }
            .formStyle(.grouped)
        }
        .navigationTitle("Settings")
        .sheet(isPresented: $showingSwarmInvite) { SwarmInviteSheet() }
        .sheet(isPresented: $showingSwarmJoin) { SwarmJoinSheet() }
        .onChange(of: model.settings) {
            model.settings.save()
            model.settings.applyLaunchAtLogin()
        }
        .onChange(of: model.settings.chatEngineRaw) {
            model.chatEngineDidChange()
        }
        .task { model.refreshAgentBridges() }
    }

    // MARK: - Panes

    @ViewBuilder
    private var generalPane: some View {
        behaviourSection
        updatesSection
        decisionsPointer
    }

    @ViewBuilder
    private var modelsPane: some View {
        runtimesSection
        modelLibrarySection
        huggingFaceSection
        chatTemplateSection
    }

    @ViewBuilder
    private var chatPane: some View {
        chatSection
        generationSection
        otherAIsSection
        CloudProvidersSection()
    }

    @ViewBuilder
    private var mediaPane: some View {
        generatedImagesSection
        voiceAndVideoSection
        videoProductionSection
        threeDSection
    }

    @ViewBuilder
    private var devicesPane: some View {
        swarmSection
        BuddySettingsSection()
    }

    @ViewBuilder
    private var advancedPane: some View {
        advancedSection
        storageSection
    }

    /// Decisions used to be a section in this window and is now its own place. Anyone who
    /// remembers where it was comes back here first, so leave a signpost rather than a gap.
    private var decisionsPointer: some View {
        Section("Decisions") {
            HStack(alignment: .firstTextBaseline) {
                Text(
                    "Which lane answers a typed question — the paid cloud, Laya on this Mac, "
                    + "a node, or the loaded model — now has its own place in the sidebar."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Button("Open Decisions") { model.selectedTab = .decisions }
            }
        }
    }

    // MARK: - Sections


    /// The runtimes that can serve a model, and the rescan that finds them.
    @ViewBuilder
    private var runtimesSection: some View {
        Section("Runtimes") {
            runtimeRow(.llamaCpp)
            runtimeRow(.mlx)
            runtimeRow(.llamaCppPrism)

            if !model.selector.isAnythingInstalled {
                Label(
                    "No runtime found. Install llama.cpp with `brew install llama.cpp`, "
                    + "then reopen this window.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
                .font(.callout)
            }

            Button("Re-scan for runtimes") {
                RuntimeLocator.customPaths = model.settings.customRuntimePaths
                model.rediscoverRuntimes()
            }
        }
    }

    /// Which agent runs the chat, and what that choice means.
    @ViewBuilder
    private var chatSection: some View {
        @Bindable var model = model

        Section("Chat") {
            Picker("Chat engine", selection: $model.settings.chatEngine) {
                Text("DeepSeek Harness — agent with tools").tag(ChatEngine.harness)
                Text("Codex — OpenAI's agent, on your models").tag(ChatEngine.codex)
                Text("Qwen Code — Qwen's agent, on your models").tag(ChatEngine.qwenCode)
                Text("Pi — earendil's agent, on your models").tag(ChatEngine.pi)
                Text("Built-in — plain chat (legacy)").tag(ChatEngine.legacy)
            }
            if model.settings.chatEngine == .harness {
                Text(
                    "The harness gives the model tools: fetching web pages, searching, "
                    + "reading and editing files in a workspace, and running commands "
                    + "with your approval. It runs locally on Node.js and talks to the "
                    + "model this app serves. Web search needs a provider key, added "
                    + "inside the harness under Settings → Web search; web fetch works "
                    + "without one."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                harnessStatusRow

                if model.settings.showAdvancedControls {
                    LabeledContent("Node.js path") {
                        TextField(
                            "Node.js path",
                            text: Binding(
                                get: { model.settings.nodeBinaryPath ?? "" },
                                set: { model.settings.nodeBinaryPath = $0.isEmpty ? nil : $0 }
                            ),
                            prompt: Text("Auto-detect")
                        )
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                    }
                    LabeledContent("Harness home") {
                        HStack(spacing: 8) {
                            Text(HarnessRuntime.homeDirectory.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .truncationMode(.middle)
                                .lineLimit(1)
                            Button("Reveal") {
                                NSWorkspace.shared.open(HarnessRuntime.homeDirectory)
                            }
                            .controlSize(.small)
                        }
                    }
                }
            } else if model.settings.chatEngine == .codex {
                Text(
                    "Codex is OpenAI's open-source coding agent. It runs here on your "
                    + "own models — every model in this app and on your swarm nodes is "
                    + "in its picker, no OpenAI account needed. It reads and edits files "
                    + "in a folder you choose and runs commands with your approval."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                codexStatusRow

                if model.settings.showAdvancedControls {
                    LabeledContent("Codex home") {
                        HStack(spacing: 8) {
                            Text(CodexRuntime.homeDirectory.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .truncationMode(.middle)
                                .lineLimit(1)
                            Button("Reveal") {
                                NSWorkspace.shared.open(CodexRuntime.homeDirectory)
                            }
                            .controlSize(.small)
                        }
                    }
                }
            } else if model.settings.chatEngine == .qwenCode {
                Text(
                    "Qwen Code is the Qwen team's open-source agent; its Web Shell is "
                    + "embedded here like the harness. Every model in this app and on "
                    + "your swarm nodes is in its picker — no Qwen account. Its model "
                    + "list is written when it starts, so use Restart after installing "
                    + "new models."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                qwenStatusRow
            } else if model.settings.chatEngine == .pi {
                Text(
                    "Pi is earendil-works' open-source coding agent, driven natively "
                    + "over its RPC protocol. Every model in this app and on your "
                    + "swarm nodes is in its picker, and the app's whole toolbox — "
                    + "images, video, 3D, benchmarks — is bridged in as native Pi "
                    + "tools. Media it produces plays right in the chat."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Text("The built-in chat streams straight from the local server. "
                     + "No tools, no web access.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The assistants already on this Mac, and the one button that connects them.
    @ViewBuilder
    private var otherAIsSection: some View {
        Section("Your other AIs") {
            if model.agentBridgeEnvironment == nil {
                Text(
                    "This build has no bridge binary, so there's nothing to connect. "
                    + "Builds made with Scripts/build-app.sh include it."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if model.agentBridgeRows.isEmpty {
                Text(
                    "No other AI apps found on this Mac. This looks for Claude "
                    + "Desktop, Claude Code, Codex and ChatGPT — install one and a "
                    + "Connect button appears here."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Text(
                    "Connect an AI you already use and it gets every tool in this "
                    + "app — chat on your local models, images, 3D, voice, the swarm. "
                    + "The heavy work runs here instead of spending your "
                    + "subscription's tokens."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                ForEach(model.agentBridgeRows) { row in
                    agentBridgeRow(row)
                }
            }
        }
    }

    /// OpenMontage, the editor the video tools hand work to.
    @ViewBuilder
    private var videoProductionSection: some View {
        Section("Video production") {
            openMontageRow
        }
    }

    /// The replacement chat template for Qwen.
    @ViewBuilder
    private var chatTemplateSection: some View {
        Section("Chat template") {
            Toggle("Use the sharp template for Qwen", isOn: sharpTemplateBinding)
            Text(
                "A replacement chat template that tells Qwen to lead with the answer "
                + "and skip the preamble — the published claim is fewer thinking "
                + "tokens for the same accuracy. It changes nothing about the weights, "
                + "and it only applies to Qwen 3.5, 3.6 and 3.8; every other model "
                + "keeps its own template. Reload the model to apply a change."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button(SharpTemplate.isDownloaded ? "Update template" : "Download template") {
                    downloadSharpTemplate()
                }
                .disabled(fetchingTemplate)
                if fetchingTemplate { ProgressView().controlSize(.small) }
                Text(templateStatus.isEmpty ? defaultTemplateStatus : templateStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Link("Source", destination: URL(
                    string: "https://huggingface.co/\(SharpTemplate.repository)"
                )!)
                .font(.caption)
            }
        }
    }

    /// Sampling: what every generation starts from.
    @ViewBuilder
    private var generationSection: some View {
        @Bindable var model = model

        Section("Generation") {
            LabeledContent("Temperature") {
                HStack {
                    Slider(value: $model.settings.temperature, in: 0...2)
                    Text(String(format: "%.2f", model.settings.temperature))
                        .monospacedDigit()
                        .frame(width: 42, alignment: .trailing)
                }
            }
            LabeledContent("Top-p") {
                HStack {
                    Slider(value: $model.settings.topP, in: 0...1)
                    Text(String(format: "%.2f", model.settings.topP))
                        .monospacedDigit()
                        .frame(width: 42, alignment: .trailing)
                }
            }
            Picker("Reasoning effort", selection: $model.settings.reasoningEffort) {
                Text("Model default").tag("")
                Text("Low").tag("low")
                Text("Medium").tag("medium")
                Text("High").tag("high")
            }
            .help("Only affects models that expose an effort control, such as gpt-oss.")
        }
    }

    /// How the app behaves when you are not looking at it.
    @ViewBuilder
    private var behaviourSection: some View {
        @Bindable var model = model

        Section("Behaviour") {
            Toggle("Open at login", isOn: $model.settings.launchAtLogin)
            Toggle("Unload the model when idle", isOn: $model.settings.unloadWhenIdle)
            if model.settings.unloadWhenIdle {
                Stepper(
                    "After \(model.settings.idleUnloadMinutes) minutes",
                    value: $model.settings.idleUnloadMinutes, in: 5...240, step: 5
                )
                Text("A loaded model holds wired memory that macOS cannot reclaim on its "
                     + "own. You get a warning five minutes before, in the menu bar and as "
                     + "a notification, with a button to keep it loaded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle("Show advanced controls", isOn: $model.settings.showAdvancedControls)
        }
    }

    /// The version now, and the one waiting.
    @ViewBuilder
    private var updatesSection: some View {
        Section("Updates") {
            LabeledContent("Version", value: model.updates.currentVersion)
            if let pending = model.updates.pendingUpdateVersion {
                HStack {
                    Label("Version \(pending) is ready to install", systemImage: "sparkles")
                    Spacer()
                    Button("Show update") { model.updates.checkForUpdates() }
                }
            }
            if let problem = model.updates.startupError {
                // Deliberately a row and not an alert. The usual cause is the app bundle
                // being replaced while this copy runs, and reopening the app fixes it.
                Label(
                    "Updates are off for this session: \(problem) Reopen the app to try again.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
                .font(.callout)
            }
            if model.updates.feedURL != nil {
                Toggle("Check automatically", isOn: Binding(
                    get: { model.updates.automaticallyChecks },
                    set: { model.updates.automaticallyChecks = $0 }
                ))
                HStack {
                    Button("Check now") { model.updates.checkForUpdates() }
                        .disabled(!model.updates.canCheckForUpdates)
                    if let last = model.updates.lastCheck {
                        Text("Last checked \(last.formatted(.relative(presentation: .named)))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Updates are signed with the project's own key and refused if they do "
                     + "not verify, which is what makes them safe without Apple notarization.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("This build has no update feed configured, which is normal for a local "
                     + "build from source.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The token that raises the download limit and opens gated repositories.
    @ViewBuilder
    private var huggingFaceSection: some View {
        @Bindable var model = model

        Section("Hugging Face") {
            SecureField("Access token", text: $model.settings.huggingFaceToken)
                .textFieldStyle(.roundedBorder)
            Text(
                "Optional. Raises the anonymous download rate limit and is required for "
                + "gated repositories such as Llama."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    /// Where models are downloaded to.
    @ViewBuilder
    private var modelLibrarySection: some View {
        @Bindable var model = model

        Section("Model library") {
            LabeledContent {
                HStack {
                    TextField(
                        "Download models to",
                        text: $model.settings.modelLibraryDirectory,
                        prompt: Text("Default")
                    )
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    Button("Choose…") { chooseModelLibraryDirectory() }
                    if !model.settings.modelLibraryDirectory.isEmpty {
                        Button("Reset") { model.settings.modelLibraryDirectory = "" }
                    }
                }
            } label: {
                fieldLabel(
                    "Download models to", caption: ModelLibrary.defaultRoot.path
                )
            }
            HStack {
                Text(
                    "Changing this only affects new downloads — models in earlier "
                        + "locations stay listed and loadable. Already have models in a "
                        + "folder?"
                )
                Spacer()
                Button("Add models from a folder…") { adoptModelsFolder() }
                    .buttonStyle(.link)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    /// Where generated images are written.
    @ViewBuilder
    private var generatedImagesSection: some View {
        @Bindable var model = model

        Section("Generated images") {
            LabeledContent {
                HStack {
                    TextField(
                        "Save to",
                        text: $model.settings.imageOutputDirectory,
                        prompt: Text("Default")
                    )
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    Button("Choose…") { chooseImageOutputDirectory() }
                    if !model.settings.imageOutputDirectory.isEmpty {
                        Button("Reset") { model.settings.imageOutputDirectory = "" }
                    }
                }
            } label: {
                fieldLabel("Save to", caption: Settings.defaultImageOutputDirectory.path)
            }
            HStack {
                Text("Images are written here as `silicon-<date>-<id>.png`.")
                Spacer()
                Button("Reveal in Finder") {
                    let directory = model.settings.resolvedImageOutputDirectory
                    try? FileManager.default.createDirectory(
                        at: directory, withIntermediateDirectories: true
                    )
                    NSWorkspace.shared.activateFileViewerSelecting([directory])
                }
                .buttonStyle(.link)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    /// Where voice and video output is written.
    @ViewBuilder
    private var voiceAndVideoSection: some View {
        @Bindable var model = model

        Section("Voice and video") {
            LabeledContent {
                HStack {
                    TextField(
                        "Audio",
                        text: $model.settings.voiceOutputDirectory,
                        prompt: Text("Default")
                    )
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    Button("Choose…") {
                        chooseDirectory(
                            message: "Where should spoken audio be saved?",
                            current: model.settings.resolvedVoiceOutputDirectory
                        ) { model.settings.voiceOutputDirectory = $0.path }
                    }
                    if !model.settings.voiceOutputDirectory.isEmpty {
                        Button("Reset") { model.settings.voiceOutputDirectory = "" }
                    }
                }
            } label: {
                fieldLabel(
                    "Audio", caption: "~/Music/Silicon Optimizer"
                )
            }
            LabeledContent {
                HStack {
                    TextField(
                        "Clips",
                        text: $model.settings.videoOutputDirectory,
                        prompt: Text("Default")
                    )
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    Button("Choose…") {
                        chooseDirectory(
                            message: "Where should generated clips be saved?",
                            current: model.settings.resolvedVideoOutputDirectory
                        ) { model.settings.videoOutputDirectory = $0.path }
                    }
                    if !model.settings.videoOutputDirectory.isEmpty {
                        Button("Reset") { model.settings.videoOutputDirectory = "" }
                    }
                }
            } label: {
                fieldLabel(
                    "Clips", caption: "~/Movies/Silicon Optimizer"
                )
            }
        }
    }

    /// The 3D toolkit's folders and its checkpoints.
    @ViewBuilder
    private var threeDSection: some View {
        @Bindable var model = model

        Section("3D toolkit") {
            LabeledContent {
                HStack {
                    TextField(
                        "Save models to",
                        text: $model.settings.meshOutputDirectory,
                        prompt: Text("Default")
                    )
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    Button("Choose…") { chooseMeshOutputDirectory() }
                    if !model.settings.meshOutputDirectory.isEmpty {
                        Button("Reset") { model.settings.meshOutputDirectory = "" }
                    }
                }
            } label: {
                fieldLabel(
                    "Save models to", caption: Settings.defaultMeshOutputDirectory.path
                )
            }
            LabeledContent {
                TextField(
                    "trellis2 folder",
                    text: $model.settings.trellisBaseDirectory,
                    prompt: Text("Default")
                )
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
            } label: {
                fieldLabel("trellis2 folder", caption: "/Volumes/T9/trellis2")
            }
            LabeledContent {
                TextField(
                    "LATO.2 service URL",
                    text: $model.settings.lato2ServiceURL,
                    prompt: Text("Not connected")
                )
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
            } label: {
                fieldLabel(
                    "LATO.2 service URL", caption: "e.g. http://192.168.1.20:8790"
                )
            }
            Text(
                "The trellis2 folder holds the TRELLIS.2 venv and the hy3d binary; each "
                    + "generation gets its own subfolder of the save location. LATO.2 runs "
                    + "on your CUDA machine — paste its service URL to enable it."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    /// This Mac on the tailnet: who may reach it, and how to let them.
    @ViewBuilder
    private var swarmSection: some View {
        Section("Swarm") {
            Toggle(
                "Let other Silicon nodes reach this Mac over your tailnet",
                isOn: Binding(
                    get: { model.settings.exposeControlOnLAN },
                    set: { newValue in
                        model.settings.exposeControlOnLAN = newValue
                        SwarmConfig.ensureExists()
                        model.applySwarmSettings()
                    }
                )
            )
            Text(
                "This Mac binds its tailscale address and port "
                    + "\(ControlServer.tailnetPort), never 0.0.0.0 — a café Wi-Fi "
                    + "cannot see the control API, only your tailnet can. Silicon "
                    + "Buddy shares the same listener."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack {
                Text(swarmStatusText)
                Spacer()
                // Tailscale is often just not up yet. Asking again is a second; being
                // told to restart the app for it is not.
                if !SwarmExposure.shared.isListening {
                    Button("Retry") {
                        Task {
                            await SwarmExposure.shared.retryNow(server: model.controlServer)
                        }
                    }
                    .buttonStyle(.link)
                }
                Button("Reveal swarm config") {
                    SwarmConfig.ensureExists()
                    NSWorkspace.shared.activateFileViewerSelecting([SwarmConfig.configURL])
                }
                .buttonStyle(.link)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            // Bluetooth-style membership: the owner opens an invite, the new
            // member scans and knocks, both screens show one code, one click
            // admits them. Discoverable only while the invite sheet is open.
            HStack(spacing: 10) {
                Button("Invite to the Swarm…") { showingSwarmInvite = true }
                Button("Join a Swarm…") { showingSwarmJoin = true }
                Spacer()
            }
        }
    }

    /// Hand-set server paths, and the command a load actually runs.
    @ViewBuilder
    private var advancedSection: some View {
        @Bindable var model = model

        Section("Advanced") {
            LabeledContent("llama-server path") {
                TextField(
                    "llama-server path",
                    text: $model.settings.llamaServerPath,
                    prompt: Text("Auto-detect")
                )
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
            }
            LabeledContent("mlx_lm.server path") {
                TextField(
                    "mlx_lm.server path",
                    text: $model.settings.mlxServerPath,
                    prompt: Text("Auto-detect")
                )
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
            }
            LabeledContent("PrismML llama-server path") {
                TextField(
                    "PrismML llama-server path",
                    text: $model.settings.prismServerPath,
                    prompt: Text("Fetched by the app when needed")
                )
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
            }
            if let command = model.currentLaunchCommand {
                LabeledContent("Launch command") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(command)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    /// How fast the disk is, and what the library has on it.
    @ViewBuilder
    private var storageSection: some View {
        Section("Storage") {
            LabeledContent("Read speed") {
                HStack(spacing: 8) {
                    if model.isMeasuringStorage {
                        ProgressView().controlSize(.small)
                        Text("Measuring…").foregroundStyle(.secondary)
                    } else if let speed = model.profile.ssdReadMBps {
                        Text("\(Int(speed)) MB/s").monospacedDigit()
                        if speed < 1500 {
                            Badge(text: "Too slow to stream experts",
                                  systemImage: "exclamationmark.triangle.fill",
                                  tint: .orange)
                        }
                    } else {
                        Text("Not measured").foregroundStyle(.secondary)
                    }
                    Button("Measure") { model.measureStorageIfNeeded(force: true) }
                        .controlSize(.small)
                        .disabled(model.isMeasuringStorage)
                }
            }
            Text("Decides whether expert streaming is worth offering, and how fast a "
                 + "streamed model will run.")
                .font(.caption)
                .foregroundStyle(.secondary)
            LabeledContent("Library", value: ModelLibrary.defaultRoot.path)
            LabeledContent("Installed models", value: "\(model.installedModels.count)")
            LabeledContent(
                "Disk used",
                value: model.installedModels
                    .reduce(Bytes.zero) { $0 + $1.sizeOnDisk }.formatted
            )
            Button("Reveal library in Finder") {
                NSWorkspace.shared.open(ModelLibrary.defaultRoot)
            }
        }
    }

    // MARK: - Helpers

    /// One assistant found on this Mac: name, where it stands, and the one button.
    @ViewBuilder
    private func agentBridgeRow(_ row: AgentBridge.Row) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(row.client.displayName)
                Text(agentBridgeCaption(for: row))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let note = model.agentBridgeNotes[row.client.id] {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Spacer()
            if model.agentBridgeBusy == row.client {
                ProgressView().controlSize(.small)
            } else {
                switch row.status {
                case .connected:
                    Badge(text: "Connected", systemImage: "checkmark.circle.fill",
                          tint: .green)
                case .notConnected:
                    Button("Connect") {
                        Task { await model.connectAgentBridge(row.client) }
                    }
                case .outdated:
                    Button("Update") {
                        Task { await model.connectAgentBridge(row.client) }
                    }
                case .manualOnly:
                    EmptyView()
                }
            }
        }
    }

    // MARK: - OpenMontage

    /// One row, four states. The caption always says what the button will do, because a
    /// button called "Set up" that takes ten minutes deserves a sentence of warning.
    private var openMontageRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("OpenMontage")
                Text(openMontageCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let stage = model.openMontageStage {
                    Text(stage + "…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let note = model.openMontageNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if model.openMontageStage != nil {
                ProgressView().controlSize(.small)
            } else {
                switch model.openMontageStatus {
                case .notInstalled:
                    Button("Set up") { Task { await model.setUpOpenMontage() } }
                case .ready:
                    HStack(spacing: 8) {
                        Badge(text: "Linked", systemImage: "checkmark.circle.fill", tint: .green)
                        Button("Open in Chat") { model.openOpenMontageInChat() }
                    }
                case .providerOutdated:
                    Button("Update") { model.relinkOpenMontage() }
                case .checkoutWithoutProvider:
                    Button("Link") { model.relinkOpenMontage() }
                case .unavailable:
                    EmptyView()
                }
            }
        }
        .onAppear { model.refreshOpenMontage() }
    }

    private var openMontageCaption: String {
        switch model.openMontageStatus {
        case .notInstalled:
            return "An open-source video studio your agent drives: research, script, shots, "
                + "edit, render. Set up downloads it to ~/OpenMontage and installs what it "
                + "needs — several minutes and a few gigabytes — then links this app in, so "
                + "its images, video and 3D show up there at $0."
        case .ready:
            return "In ~/OpenMontage, with this app as a provider. Open in Chat puts Codex "
                + "in that folder; ask it for a video."
        case .providerOutdated(let installed, let available):
            return "Linked, but the provider in ~/OpenMontage is version \(installed) and "
                + "this app carries \(available)."
        case .checkoutWithoutProvider:
            return "Found at ~/OpenMontage. Link drops this app in as a provider — nothing "
                + "else in the checkout is touched."
        case .unavailable(let reason):
            return reason
        }
    }

    private func agentBridgeCaption(for row: AgentBridge.Row) -> String {
        if case .manualOnly(let reason) = row.status { return reason }
        if case .outdated(let path) = row.status {
            return "Connected, but pointing at an old copy of the bridge (\(path))."
        }
        switch row.client {
        case .claudeDesktop:
            return "The Claude app. One click adds this app's tools to every chat."
        case .claudeCode:
            return "Claude in the terminal. Connects for every project at once."
        case .codex:
            return "OpenAI's coding agent — included with ChatGPT plans."
        case .chatGPTDesktop:
            return "The ChatGPT app."
        }
    }

    /// Live status of the harness process, with a restart escape hatch.
    private var harnessStatusRow: some View {
        LabeledContent("Harness") {
            HStack(spacing: 8) {
                switch model.harnessState {
                case .idle:
                    Badge(text: "Starts with the Chat tab", systemImage: "moon", tint: .secondary)
                case .starting:
                    ProgressView().controlSize(.small)
                    Text("Starting…").font(.caption).foregroundStyle(.secondary)
                case .ready:
                    Badge(text: "Running", systemImage: "checkmark.circle.fill", tint: .green)
                case .stopping:
                    ProgressView().controlSize(.small)
                    Text("Stopping…").font(.caption).foregroundStyle(.secondary)
                case .failed:
                    Badge(text: "Failed", systemImage: "xmark.circle", tint: .orange)
                }
                if case .ready = model.harnessState {
                    Button("Restart") { model.restartHarness() }
                        .controlSize(.small)
                }
            }
        }
    }

    private var codexStatusRow: some View {
        LabeledContent("Codex") {
            HStack(spacing: 8) {
                switch model.codexState {
                case .idle:
                    Badge(text: "Starts with the Chat tab", systemImage: "moon", tint: .secondary)
                case .starting:
                    ProgressView().controlSize(.small)
                    Text("Starting…").font(.caption).foregroundStyle(.secondary)
                case .ready:
                    Badge(text: "Running", systemImage: "checkmark.circle.fill", tint: .green)
                case .stopping:
                    ProgressView().controlSize(.small)
                    Text("Stopping…").font(.caption).foregroundStyle(.secondary)
                case .failed:
                    Badge(text: "Failed", systemImage: "xmark.circle", tint: .orange)
                }
                if case .ready = model.codexState {
                    Button("Restart") { model.restartCodex() }
                        .controlSize(.small)
                }
            }
        }
    }

    private var qwenStatusRow: some View {
        LabeledContent("Qwen Code") {
            HStack(spacing: 8) {
                switch model.qwenState {
                case .idle:
                    Badge(text: "Starts with the Chat tab", systemImage: "moon", tint: .secondary)
                case .starting:
                    ProgressView().controlSize(.small)
                    Text("Starting…").font(.caption).foregroundStyle(.secondary)
                case .ready:
                    Badge(text: "Running", systemImage: "checkmark.circle.fill", tint: .green)
                case .stopping:
                    ProgressView().controlSize(.small)
                    Text("Stopping…").font(.caption).foregroundStyle(.secondary)
                case .failed:
                    Badge(text: "Failed", systemImage: "xmark.circle", tint: .orange)
                }
                if case .ready = model.qwenState {
                    Button("Restart") { model.restartQwen() }
                        .controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder
    private func runtimeRow(_ kind: RuntimeKind) -> some View {
        let installation = model.selector.available[kind]
        LabeledContent(kind.rawValue) {
            HStack(spacing: 8) {
                if let installation {
                    VStack(alignment: .trailing, spacing: 1) {
                        HStack(spacing: 6) {
                            Badge(text: "Found", systemImage: "checkmark.circle.fill", tint: .green)
                            if installation.hasExpertStreaming {
                                Badge(
                                    text: "Expert streaming",
                                    systemImage: "arrow.down.doc",
                                    tint: .blue
                                )
                            }
                        }
                        Text(installation.version ?? installation.source.rawValue)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else if kind == .llamaCppPrism {
                    prismInstallControl
                } else {
                    Badge(text: "Not installed", systemImage: "xmark.circle", tint: .secondary)
                }
            }
        }
        .help(kind.summary)
    }

    /// The fork is fetched by the app rather than found on the machine: one button, with
    /// its progress and any failure right beside it.
    @ViewBuilder
    private var prismInstallControl: some View {
        if let install = model.prismRuntimeInstall, install.error == nil {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(install.stage).font(.caption2).foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .trailing, spacing: 2) {
                Button("Install (12 MB)") { model.installPrismRuntime() }
                    .controlSize(.small)
                if let error = model.prismRuntimeInstall?.error {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .frame(maxWidth: 320, alignment: .trailing)
                }
            }
        }
    }

    /// Folder picker for the image output directory.
    ///
    /// Stored as a plain path rather than a security-scoped bookmark: this app is not sandboxed,
    /// so a path is sufficient and survives being edited by hand in the field beside the button.
    /// A row label with its default value underneath in a quieter voice. The caption lives
    /// in the label column's whitespace, where there is room for a whole path on one line —
    /// instead of word-wrapping into three beside the field.
    /// Switching this on with no template on disk would silently do nothing at the
    /// next load, so the toggle fetches it.
    private var sharpTemplateBinding: Binding<Bool> {
        Binding(
            get: { model.settings.useSharpChatTemplate },
            set: { newValue in
                model.settings.useSharpChatTemplate = newValue
                if newValue, !SharpTemplate.isDownloaded { downloadSharpTemplate() }
            }
        )
    }

    private var defaultTemplateStatus: String {
        guard SharpTemplate.isDownloaded else { return "Not downloaded yet." }
        guard let model = model.loadedModel else { return "Ready." }
        return SharpTemplate.suits(modelName: model.name, identifier: model.catalogID)
            ? "In use by \(model.name)."
            : "Ready — \(model.name) is not a Qwen it was written for."
    }

    private func downloadSharpTemplate() {
        fetchingTemplate = true
        templateStatus = "Downloading…"
        let token = model.settings.huggingFaceToken
        Task {
            do {
                _ = try await SharpTemplate.download(token: token)
                templateStatus = "Downloaded. Reload the model to apply it."
            } catch {
                templateStatus = error.localizedDescription
            }
            fetchingTemplate = false
        }
    }

    private func fieldLabel(_ title: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private func chooseDirectory(
        message: String, current: URL, onPick: (URL) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = message
        panel.directoryURL = current
        if panel.runModal() == .OK, let url = panel.url {
            onPick(url)
        }
    }

    private func chooseImageOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Where should generated images be saved?"
        panel.directoryURL = model.settings.resolvedImageOutputDirectory
        if panel.runModal() == .OK, let url = panel.url {
            model.settings.imageOutputDirectory = url.path
        }
    }

    private var swarmStatusText: String {
        let config = model.swarmConfig
        let peerCount = config?.peers.count ?? 0
        var parts: [String] = []
        parts.append(SwarmExposure.shared.summary)
        if config?.effectiveToken == nil {
            parts.append("No swarm token yet — nothing leaves loopback until swarm.json has "
                + "one (shared with your other nodes).")
        }
        parts.append(peerCount == 1 ? "1 peer configured." : "\(peerCount) peers configured.")
        return parts.joined(separator: " ")
    }

    private func chooseModelLibraryDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Where should downloaded models be stored?"
        panel.directoryURL = model.settings.resolvedModelLibraryDirectory
            ?? ModelLibrary.defaultRoot
        if panel.runModal() == .OK, let url = panel.url {
            model.settings.modelLibraryDirectory = url.path
            Task { await model.applyModelLibrarySettings() }
        }
    }

    private func adoptModelsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = "Choose a folder to scan for model files (.gguf) — they are "
            + "registered in place, not copied."
        if panel.runModal() == .OK, let url = panel.url {
            Task { await model.adoptModelsFromFolder(url) }
        }
    }

    private func chooseMeshOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Where should generated 3D models be saved?"
        panel.directoryURL = model.settings.resolvedMeshOutputDirectory
        if panel.runModal() == .OK, let url = panel.url {
            model.settings.meshOutputDirectory = url.path
        }
    }
}
