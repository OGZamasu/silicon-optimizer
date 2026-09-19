import SiliconCatalog
import SiliconControl
import SiliconCore
import SiliconPlanner
import SiliconRuntime
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var templateStatus = ""
    @State private var fetchingTemplate = false
    @State private var showingSwarmInvite = false
    @State private var jevRevision = 0
    @State private var showingSwarmJoin = false

    var body: some View {
        @Bindable var model = model

        Form {
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

            Section("Video production") {
                openMontageRow
            }

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

            Section("TypeSafe (Jev)") {
                TypeSafeKeyRow(onKeyChanged: { jevRevision += 1 })
                Text(
                    "Optional. Lets the decide tool and POST /decide ask TypeSafe's Jev for typed "
                    + "decisions ($0.042 per million input tokens, output free). Without a key the "
                    + "same questions are answered by the model loaded here, one forward pass each, "
                    + "and nothing leaves the Mac."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Link("Get a key at console.typesafe.ai", destination: URL(string: "https://console.typesafe.ai/settings/keys")!)
                    .font(.caption)
                // Rebuilt when the key row changes the stored key, so the master toggle
                // it may just have flipped is on screen rather than one launch behind.
                JevSection().id(jevRevision)
            }

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

            BuddySettingsSection()

            CloudProvidersSection()

            if model.settings.showAdvancedControls {
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
        }
        .formStyle(.grouped)
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

/// The TypeSafe key field. A saved key is not read back into the field — the app has no
/// reason to show a credential it already holds — so the row says whether one is stored and
/// takes a replacement or a removal.
private struct TypeSafeKeyRow: View {
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
private struct JevSection: View {
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
/// Sits under the feature switches because it belongs to one of them: Decision calibration
/// is what pays for the run, and the two floors below are the only thing the run changes.
/// The summary is deliberately specific — which model, when, how much agreement, which
/// floors — because a calibration measured against a model you are no longer running is a
/// number that has quietly stopped applying, and the row should say so rather than imply
/// otherwise by showing it.
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
                }
            }

            if let last {
                Text(last.summary)
                    .font(.caption)
                    .monospacedDigit()
                    .textSelection(.enabled)
                if last.modelID != model.loadedModel?.id {
                    Text(
                        "Measured against a different model from the one loaded now, so "
                        + "`auto` is using the default floors until this is run again."
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
        + "\(ControlAPI.JevCalibration.estimatedCents()) cent of Jev tokens and a minute or "
        + "two of the model. Jev is the reference, not ground truth — agreement means the two "
        + "landed in the same place, which they can do while both being wrong. Add cases of "
        + "your own to `jev-calibration.json` beside `jev.json`."

    private func run() {
        running = true
        problem = nil
        Task {
            do {
                last = try await model.calibrateJev()
            } catch {
                problem = error.localizedDescription
            }
            running = false
        }
    }
}
