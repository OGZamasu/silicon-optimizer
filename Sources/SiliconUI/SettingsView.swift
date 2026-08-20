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

    var body: some View {
        @Bindable var model = model

        Form {
            Section("Runtimes") {
                runtimeRow(.llamaCpp)
                runtimeRow(.mlx)

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
                } else {
                    Text("The built-in chat streams straight from the local server. "
                         + "No tools, no web access.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
                    "Let other Silicon nodes reach this Mac",
                    isOn: Binding(
                        get: { model.settings.exposeControlOnLAN },
                        set: { newValue in
                            model.settings.exposeControlOnLAN = newValue
                            SwarmConfig.ensureExists()
                            model.applySwarmSettings()
                        }
                    )
                )
                HStack {
                    Text(swarmStatusText)
                    Spacer()
                    Button("Reveal swarm config") {
                        SwarmConfig.ensureExists()
                        NSWorkspace.shared.activateFileViewerSelecting([SwarmConfig.configURL])
                    }
                    .buttonStyle(.link)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

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
        .onChange(of: model.settings) {
            model.settings.save()
            model.settings.applyLaunchAtLogin()
        }
        .onChange(of: model.settings.chatEngineRaw) {
            model.chatEngineDidChange()
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
                } else {
                    Badge(text: "Not installed", systemImage: "xmark.circle", tint: .secondary)
                }
            }
        }
        .help(kind.summary)
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
        parts.append(model.controlIsOnLAN
            ? "Reachable on the LAN at port \(ControlServer.lanPort)."
            : "Local only.")
        if config?.effectiveToken == nil {
            parts.append("No swarm token yet — the LAN stays off until swarm.json has one "
                + "(shared with your other nodes).")
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
