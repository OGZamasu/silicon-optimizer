import AppKit
import SiliconCatalog
import SiliconCore
import SiliconPlanner
import SwiftUI

/// The sheet where a user picks a quantization and sees exactly what it will cost.
///
/// This is where the app earns its keep: instead of a filename list, the user gets a live memory
/// plan and a ranked set of things to change if it does not fit.
struct ModelDetailSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var entry: ModelEntry

    @State private var quantization: Quantization = .q4_K_M
    @State private var contextLength = 8192
    @State private var kvPrecision: KVCachePrecision = .f16
    @State private var flashAttention = true
    @State private var expertStreamingEnabled = false
    @State private var expertSlots: Double = 64
    /// Where this download's files go, chosen fresh each time the sheet opens rather than
    /// remembered as a standing default — moving one large model to external media isn't the
    /// same thing as deciding everything should live there from now on.
    @State private var externalDestination: URL?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    aboutSection
                    quantizationSection
                    configurationSection
                    planSection
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 620, height: 720)
        .task { applyRecommendedDefaults() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: entry.category.systemImage)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.name).font(.title2.weight(.semibold))
                HStack(spacing: 8) {
                    Text(entry.author).foregroundStyle(.secondary)
                    RatingStars(rating: entry.rating)
                    Badge(text: entry.license, systemImage: "doc.text")
                }
                .font(.callout)
            }
            Spacer()
            Button {
                NSWorkspace.shared.open(
                    HuggingFaceClient.pageURL(
                        repository: entry.variants.first?.repository ?? ""
                    )
                )
            } label: {
                Image(systemName: "arrow.up.forward.square")
            }
            .buttonStyle(.borderless)
            .help("View on Hugging Face")
        }
        .padding(20)
    }

    // MARK: - Sections

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(entry.summary)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                ForEach(entry.capabilities.labels, id: \.0) { label, icon in
                    Badge(text: label, systemImage: icon)
                }
            }

            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                spacing: 8
            ) {
                stat("Parameters", entry.parameterLabel)
                stat("Layers", String(entry.shape.blockCount))
                stat("Max context", entry.maxContext.contextLabel)
                if let moe = entry.shape.moe {
                    stat("Experts", "\(moe.expertCount)")
                    stat("Active per token", "\(moe.expertsUsedPerToken)")
                    stat("Active params", entry.activeParameterLabel ?? "—")
                } else {
                    stat("Type", "Dense")
                    stat("KV heads", String(entry.shape.headCountKV))
                    stat("Head width", String(entry.shape.headDimension))
                }
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.medium)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var quantizationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quantization").font(.headline)
            ForEach(entry.variants) { variant in
                quantizationRow(variant)
            }
        }
    }

    private func quantizationRow(_ variant: ModelVariant) -> some View {
        let isSelected = quantization == variant.quantization
        let installed = model.isInstalled(entry, quantization: variant.quantization)
        let plan = model.plan(
            for: entry, quantization: variant.quantization,
            configuration: currentConfiguration
        )

        return Button {
            quantization = variant.quantization
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(variant.quantization.rawValue).font(.callout.weight(.medium))
                        if installed { Badge(text: "Installed", tint: .green) }
                        Badge(
                            text: plan.verdict.label,
                            tint: Palette.verdict(plan.verdict)
                        )
                    }
                    Text(variant.quantization.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 1) {
                    Text(variant.downloadSize.formatted)
                        .font(.callout).monospacedDigit()
                    Text("download")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(10)
            .background(
                isSelected ? Color.accentColor.opacity(0.08) : Color.clear,
                in: .rect(cornerRadius: 8)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private var configurationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Configuration").font(.headline)

            HStack {
                Text("Context length")
                Spacer()
                Picker("", selection: $contextLength) {
                    ForEach(contextOptions, id: \.self) { option in
                        Text(option.contextLabel).tag(option)
                    }
                }
                .labelsHidden()
                .frame(width: 100)
            }

            HStack {
                Text("KV cache")
                Spacer()
                Picker("", selection: $kvPrecision) {
                    ForEach(KVCachePrecision.allCases) { precision in
                        Text(precision.rawValue.uppercased()).tag(precision)
                    }
                }
                .labelsHidden()
                .frame(width: 100)
            }

            Toggle("Flash Attention", isOn: $flashAttention)
                .help("Avoids materialising the attention score matrix. Faster and much smaller.")

            if let moe = entry.shape.moe {
                Divider()
                Toggle("Stream experts from disk", isOn: $expertStreamingEnabled)
                    .help("Keeps only some experts in memory and pages the rest from the GGUF.")

                if expertStreamingEnabled {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Resident experts")
                                .font(.callout)
                            Spacer()
                            Text("\(Int(expertSlots)) of \(moe.expertCount)")
                                .font(.callout).monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $expertSlots, in: 8...Double(moe.expertCount), step: 8)

                        let maxUBatch = ExpertStreamingConfiguration.maximumMicroBatch(
                            slotCount: Int(expertSlots),
                            expertsUsedPerToken: moe.expertsUsedPerToken
                        )
                        Label(
                            "Prompt processing will run at a micro-batch of \(maxUBatch) tokens, "
                            + "so long prompts take noticeably longer. Output is unchanged.",
                            systemImage: "info.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, 4)
                }
            }
        }
    }

    private var planSection: some View {
        let plan = model.plan(
            for: entry, quantization: quantization, configuration: currentConfiguration
        )
        let speed = SpeedEstimator(profile: model.profile).estimate(
            shape: entry.shape, quantization: quantization,
            configuration: currentConfiguration, plan: plan
        )

        return VStack(alignment: .leading, spacing: 12) {
            Text("Memory plan").font(.headline)
            MemoryPlanBreakdown(plan: plan)

            HStack {
                Readout(
                    label: "Generation",
                    value: String(format: "%.0f", speed.generationTokensPerSecond),
                    caption: "tokens/sec (estimated)"
                )
                Readout(
                    label: "Prompt",
                    value: String(format: "%.0f", speed.prefillTokensPerSecond),
                    caption: "tokens/sec (estimated)"
                )
                Readout(
                    label: "Headroom",
                    value: plan.headroom > .zero ? plan.headroom.formatted : "None",
                    caption: "left for other apps",
                    tint: plan.headroom > .zero ? .primary : .orange
                )
            }

            ForEach(plan.notes, id: \.self) { note in
                Label(note, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !plan.remediations.isEmpty {
                Text("Suggestions").font(.headline).padding(.top, 4)
                ForEach(plan.remediations) { remediation in
                    RemediationRow(remediation: remediation) {
                        apply(remediation)
                    }
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        let plan = model.plan(
            for: entry, quantization: quantization, configuration: currentConfiguration
        )
        let installed = model.isInstalled(entry, quantization: quantization)

        return VStack(alignment: .leading, spacing: 8) {
            // Downloading costs only disk, so it is never gated on memory — only loading is.
            if !installed, !plan.verdict.isUsable {
                Label(installWarning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !installed {
                saveLocationRow
            }
            HStack {
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()

                if installed {
                    Button {
                        if let installed = model.installedModels.first(where: {
                            $0.catalogID == entry.id && $0.quantization == quantization
                        }) {
                            model.load(installed, configuration: currentConfiguration)
                            model.selectedTab = .chat
                            dismiss()
                        }
                    } label: {
                        Label("Load model", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!plan.verdict.isUsable)
                } else {
                    Button {
                        model.install(entry, quantization: quantization, saveTo: externalDestination)
                        dismiss()
                    } label: {
                        Label(
                            "Install \(entry.variant(for: quantization)?.downloadSize.formatted ?? "")",
                            systemImage: "arrow.down.circle.fill"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(16)
    }

    /// Explains why the plan fails while the Install button stays enabled.
    ///
    /// Two very different situations produce the same verdict: other apps currently hogging
    /// memory (temporary — the download is fine) and a model that genuinely exceeds the machine
    /// (permanent — the user should know before spending the bandwidth).
    private var installWarning: String {
        let idlePlan = model.planner().plan(
            shape: entry.shape, quantization: quantization, configuration: currentConfiguration
        )
        if idlePlan.verdict.isUsable {
            return "This fits on its own, but other apps are currently holding too much memory. "
                + "You can download now and free up memory before loading."
        }
        return "This configuration is not expected to fit in memory on this Mac. You can still "
            + "download it — see the suggestions above for ways to make it run."
    }

    /// Lets one download go somewhere other than Silicon Optimizer's own managed library
    /// directory — an external drive, for a model too large to be worth keeping on the internal
    /// one. The library's index stays where it always is; only this model's files move, the same
    /// way an imported GGUF already can live anywhere.
    private var saveLocationRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "externaldrive")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Save to").font(.caption2).foregroundStyle(.secondary)
                Text(externalDestination?.path ?? "Silicon Optimizer's managed library")
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if externalDestination != nil {
                Button("Use Default") { externalDestination = nil }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button(externalDestination == nil ? "Choose Folder…" : "Change…") {
                chooseExternalDestination()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(10)
        .background(.background.secondary, in: .rect(cornerRadius: 8))
    }

    private func chooseExternalDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose where to save \(entry.name)'s files."
        let lastPath = model.settings.lastExternalModelDirectory
        if !lastPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: lastPath)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        externalDestination = url
        model.settings.lastExternalModelDirectory = url.path
        // This view isn't SettingsView, whose onChange is what normally persists edits — save
        // explicitly so the remembered folder survives a relaunch.
        model.settings.save()
    }

    // MARK: - State

    private var currentConfiguration: LoadConfiguration {
        var configuration = LoadConfiguration(
            contextLength: contextLength,
            kvCachePrecision: kvPrecision,
            flashAttention: flashAttention,
            threads: model.profile.performanceCores
        )
        if expertStreamingEnabled, let moe = entry.shape.moe {
            let slots = Int(expertSlots)
            configuration.expertStreaming = ExpertStreamingConfiguration(slotCount: slots)
            configuration.microBatchSize = ExpertStreamingConfiguration.maximumMicroBatch(
                slotCount: slots, expertsUsedPerToken: moe.expertsUsedPerToken
            )
            configuration.batchSize = max(configuration.microBatchSize, 256)
        }
        return configuration
    }

    private var contextOptions: [Int] {
        [4096, 8192, 16_384, 32_768, 65_536, 131_072].filter { $0 <= entry.maxContext }
    }

    private func applyRecommendedDefaults() {
        guard let recommendation = model.autoConfigurator().best(
            for: entry, otherAppsInUse: model.memoryUsedByOtherApps
        ) else {
            quantization = entry.variants.first?.quantization ?? .q4_K_M
            return
        }
        quantization = recommendation.quantization
        contextLength = recommendation.configuration.contextLength
        kvPrecision = recommendation.configuration.kvCachePrecision
        flashAttention = recommendation.configuration.flashAttention
        if let streaming = recommendation.configuration.expertStreaming {
            expertStreamingEnabled = true
            expertSlots = Double(streaming.slotCount)
        }
    }

    private func apply(_ remediation: MemoryPlan.Remediation) {
        switch remediation.kind {
        case .enableFlashAttention:
            flashAttention = true
        case .quantizeKVCache:
            kvPrecision = .q8_0
        case .reduceContext:
            if let index = contextOptions.firstIndex(of: contextLength), index > 0 {
                contextLength = contextOptions[index - 1]
            }
        case .lowerQuantization:
            let lower = entry.variants
                .map(\.quantization)
                .filter { $0.bitsPerWeight < quantization.bitsPerWeight }
                .max { $0.bitsPerWeight < $1.bitsPerWeight }
            if let lower { quantization = lower }
        case .enableExpertStreaming:
            guard let moe = entry.shape.moe else { return }
            expertStreamingEnabled = true
            // Size the pool from what the plan says is actually affordable.
            let perSlot = MemoryPlanner.weightBytes(
                MemoryPlanner.parametersPerExpertSlot(entry.shape), quantization
            )
            let plan = model.plan(
                for: entry, quantization: quantization, configuration: currentConfiguration
            )
            let available = plan.budget - plan.nonExpertWeights - plan.kvCache - plan.computeBuffers
            let affordable = perSlot.rawValue > 0 ? Int(available.rawValue / perSlot.rawValue) : 8
            expertSlots = Double(max(8, min(moe.expertCount, affordable)))
        case .switchRuntime, .closeApps:
            break
        }
    }
}

private struct RemediationRow: View {
    var remediation: MemoryPlan.Remediation
    var onApply: () -> Void

    private var isActionable: Bool {
        remediation.kind != .closeApps && remediation.saving > .zero
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(remediation.title).font(.callout.weight(.medium))
                Text(remediation.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(remediation.cost)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                if remediation.saving > .zero {
                    Text("−\(remediation.saving.formatted)")
                        .font(.callout.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(.green)
                }
                if isActionable {
                    Button("Apply", action: onApply)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
        .padding(10)
        .background(.background.secondary, in: .rect(cornerRadius: 8))
    }

    private var icon: String {
        switch remediation.kind {
        case .reduceContext: "arrow.down.right.and.arrow.up.left"
        case .lowerQuantization: "arrow.down.circle"
        case .quantizeKVCache: "square.stack.3d.down.right"
        case .enableFlashAttention: "bolt.fill"
        case .enableExpertStreaming: "arrow.down.doc"
        case .switchRuntime: "arrow.triangle.2.circlepath"
        case .closeApps: "xmark.app"
        }
    }
}
