import SiliconCatalog
import SiliconCore
import SiliconPlanner
import SiliconRuntime
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

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
                    Text("A loaded model holds wired memory that macOS cannot reclaim on its own.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("Show advanced controls", isOn: $model.settings.showAdvancedControls)
            }

            Section("Updates") {
                LabeledContent("Version", value: model.updates.currentVersion)
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

            Section("Generated images") {
                LabeledContent("Save to") {
                    HStack {
                        TextField(
                            Settings.defaultImageOutputDirectory.path,
                            text: $model.settings.imageOutputDirectory
                        )
                        .textFieldStyle(.roundedBorder)
                        Button("Choose…") { chooseImageOutputDirectory() }
                        if !model.settings.imageOutputDirectory.isEmpty {
                            Button("Reset") { model.settings.imageOutputDirectory = "" }
                        }
                    }
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

            if model.settings.showAdvancedControls {
                Section("Advanced") {
                    LabeledContent("llama-server path") {
                        TextField("Auto-detect", text: $model.settings.llamaServerPath)
                            .textFieldStyle(.roundedBorder)
                    }
                    LabeledContent("mlx_lm.server path") {
                        TextField("Auto-detect", text: $model.settings.mlxServerPath)
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
}
