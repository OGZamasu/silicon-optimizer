import SiliconCore
import SiliconHardware
import SiliconRuntime
import SwiftUI

/// The menu bar surface — the app's primary home.
///
/// The window is where you go to change things; this is where you check on them. It stays
/// glanceable: current model, what it is costing, and the two or three actions worth taking
/// without opening anything.
struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            metricsSection
            Divider()
            modelSection
            Divider()
            actions
        }
        .frame(width: 300)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "cpu.fill")
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 0) {
                Text("Silicon Optimizer")
                    .font(.callout.weight(.semibold))
                Text(model.profile.chipName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            statusDot
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var statusDot: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(model.runtimeState.isRunning ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 7, height: 7)
            Text(model.runtimeState.isRunning ? "Running" : "Idle")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Metrics

    private var metricsSection: some View {
        VStack(spacing: 10) {
            metricRow(
                "Memory",
                value: model.metrics.memoryUsed.formatted,
                detail: "of \(model.metrics.memoryTotal.formatted)",
                fraction: model.metrics.memoryUsedFraction,
                tint: Palette.pressure(model.metrics.memoryUsedFraction)
            )
            metricRow(
                "GPU",
                value: "\(Int(model.metrics.gpuUtilization * 100))%",
                detail: model.metrics.gpuMemoryInUse.formatted,
                fraction: model.metrics.gpuUtilization,
                tint: .blue
            )
            if model.metrics.swapUsed > .mib(256) {
                metricRow(
                    "Swap",
                    value: model.metrics.swapUsed.formatted,
                    detail: "in use",
                    fraction: model.metrics.swapUsed.fraction(of: model.metrics.swapTotal),
                    tint: .orange
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func metricRow(
        _ label: String, value: String, detail: String, fraction: Double, tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(value).font(.caption.weight(.medium)).monospacedDigit()
                Text(detail).font(.caption2).foregroundStyle(.tertiary)
            }
            ProgressView(value: fraction.clamped(to: 0...1))
                .progressViewStyle(.linear)
                .tint(tint)
        }
    }

    // MARK: - Model

    @ViewBuilder
    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let loaded = model.loadedModel {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(loaded.name)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            Text(loaded.quantization.rawValue)
                            if let configuration = model.activeConfiguration {
                                Text("· \(configuration.contextLength.contextLabel)")
                                if configuration.expertStreaming != nil {
                                    Text("· streaming")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Unload") { Task { await model.unload() } }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }

                if let generation = model.lastGeneration, generation.generatedTokens > 0 {
                    HStack {
                        Text(String(format: "%.1f tok/s", generation.generationTokensPerSecond))
                        Spacer()
                        Text(String(format: "%.2fs to first token", generation.timeToFirstToken))
                    }
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                }
                // An image or 3D render runs alongside the loaded language model.
                if let activity = model.activeGenerationSummary {
                    activityRow(activity)
                }
            } else if model.runtimeState.isBusy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.runtimeState.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let activity = model.activeGenerationSummary {
                // No language model, but a diffusion or 3D model is working — that is
                // absolutely a model, and "No model loaded" here would be false.
                activityRow(activity)
            } else {
                Text("No model loaded")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if !model.installedModels.isEmpty {
                Menu("Switch model") {
                    ForEach(model.installedModels) { installed in
                        Button {
                            model.load(installed)
                        } label: {
                            Label(
                                "\(installed.name) · \(installed.quantization.rawValue)",
                                systemImage: model.loadedModel?.id == installed.id
                                    ? "checkmark" : "circle"
                            )
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .font(.caption)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func activityRow(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(spacing: 0) {
            menuButton("Open Chat", systemImage: "bubble.left.and.bubble.right") {
                model.selectedTab = .chat
                openMainWindow()
            }
            menuButton("Dashboard", systemImage: "gauge.with.dots.needle.67percent") {
                model.selectedTab = .dashboard
                openMainWindow()
            }
            menuButton("Models", systemImage: "square.stack.3d.up") {
                model.selectedTab = .models
                openMainWindow()
            }
            menuButton("Images", systemImage: "photo.on.rectangle.angled") {
                model.selectedTab = .images
                openMainWindow()
            }
            menuButton("3D", systemImage: "cube.transparent") {
                model.selectedTab = .threeD
                openMainWindow()
            }
            Divider().padding(.vertical, 4)
            menuButton("Settings…", systemImage: "gearshape") {
                model.selectedTab = .settings
                openMainWindow()
            }
            menuButton("Quit", systemImage: "power") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func menuButton(
        _ title: String, systemImage: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func openMainWindow() {
        openWindow(id: MainWindow.identifier)
        // A menu bar app has no Dock icon, so it must ask to be brought forward explicitly.
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

/// The compact label drawn in the menu bar itself.
///
/// This view is instantiated as soon as the app launches, unlike the menu's content, which is
/// built lazily when the menu is first opened. That makes it the right place to hang first-run
/// behaviour off.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: model.runtimeState.isRunning ? "cpu.fill" : "cpu")
            if model.runtimeState.isRunning,
               let generation = model.lastGeneration,
               generation.generationTokensPerSecond > 0 {
                Text(String(format: "%.0f", generation.generationTokensPerSecond))
                    .font(.caption2.weight(.medium))
                    .monospacedDigit()
            }
        }
        .task {
            model.start()
            // A menu bar app that opens to nothing is invisible to a first-time user. Show the
            // window once, on the very first launch, so there is something to react to.
            if !model.hasLaunchedBefore {
                model.hasLaunchedBefore = true
                openWindow(id: MainWindow.identifier)
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
        }
    }
}
