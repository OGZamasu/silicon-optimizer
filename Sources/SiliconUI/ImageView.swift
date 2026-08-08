import SiliconCatalog
import SiliconCore
import SiliconPlanner
import SiliconRuntime
import SwiftUI

/// Image generation.
///
/// Structured around the same promise as the rest of the app: you see what it will cost before
/// you start. The difference is that a diffusion model's cost is phased, so the plan shows three
/// bars rather than one total, and names which stage decides whether it fits.
struct ImageView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        GeometryReader { proxy in
            ScrollView {
                Group {
                    if proxy.size.width >= 900 {
                        HStack(alignment: .top, spacing: 16) {
                            VStack(spacing: 16) {
                                composer
                                planCard
                            }
                            .frame(width: 380)
                            resultCard
                        }
                    } else {
                        // Plan above result, not below it: the cost estimate is the reason this
                        // tab exists, and stacked behind a full-height empty result card it was
                        // off-screen until you scrolled past everything.
                        VStack(spacing: 16) {
                            composer
                            planCard
                            resultCard
                        }
                    }
                }
                .padding(20)
            }
        }
        .background(.background)
        .navigationTitle("Images")
    }

    // MARK: - Composer

    private var composer: some View {
        @Bindable var model = model

        return Card(title: "Prompt", systemImage: "text.cursor") {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Describe the image", text: $model.imagePrompt, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(3...8)
                    .padding(10)
                    .background(.background.secondary, in: .rect(cornerRadius: 8))

                Picker("Model", selection: $model.selectedDiffusionModel) {
                    ForEach(DiffusionCatalog.all) { entry in
                        Text(entry.name).tag(entry.id)
                    }
                }

                if let entry = currentEntry {
                    if entry.isGated {
                        Label(
                            "Gated on Hugging Face. Accept its licence there and add a token in "
                            + "Settings before generating.",
                            systemImage: "lock"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(entry.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                HStack {
                    Text("Size")
                    Spacer()
                    Picker("", selection: sizeBinding) {
                        ForEach([512, 768, 1024, 1536, 2048], id: \.self) { side in
                            Text(verbatim: "\(side)²").tag(side)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 100)
                }

                HStack {
                    Text("Steps")
                    Spacer()
                    Text(String(model.imageConfiguration.steps))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Stepper("", value: $model.imageConfiguration.steps, in: 1...50)
                        .labelsHidden()
                }

                HStack {
                    Text("Precision")
                    Spacer()
                    Picker("", selection: $model.imageConfiguration.quantization) {
                        ForEach([Quantization.mlx4, .mlx6, .mlx8]) { quantization in
                            Text(quantization.rawValue.replacingOccurrences(of: "MLX-", with: ""))
                                .tag(quantization)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 100)
                }

                Toggle("Decode in tiles", isOn: $model.imageConfiguration.tiledDecode)
                    .help("Caps the final VAE step, which is often the tallest moment of a run.")

                HStack {
                    if model.isGeneratingImage {
                        Button("Stop") { model.cancelImage() }
                            .buttonStyle(.bordered)
                    } else {
                        Button {
                            model.generateImage()
                        } label: {
                            Label("Generate", systemImage: "sparkles")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canGenerate)
                    }
                }

                if model.imageRuntime == nil {
                    Label(
                        "MFLUX is not installed. Run `pip install mflux` in a Python environment.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Plan

    @ViewBuilder
    private var planCard: some View {
        if let entry = currentEntry {
            let plan = model.diffusionPlan(for: entry, configuration: model.imageConfiguration)
            Card(title: "Memory plan", systemImage: "memorychip") {
                VStack(alignment: .leading, spacing: 12) {
                    // Three bars rather than one total: the stages do not overlap, so what
                    // matters is the tallest, not the sum.
                    ForEach(plan.phases) { phase in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(phase.name)
                                    .font(.callout.weight(
                                        phase.name == plan.peakPhase?.name ? .semibold : .regular
                                    ))
                                Spacer()
                                Text(phase.resident.formatted)
                                    .font(.callout).monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            ProgressView(value: phase.resident.fraction(of: plan.budget))
                                .progressViewStyle(.linear)
                                .tint(phase.name == plan.peakPhase?.name
                                      ? Palette.verdict(plan.verdict) : .secondary)
                            Text(phase.detail)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Divider()

                    HStack {
                        Badge(
                            text: plan.verdict.label,
                            systemImage: plan.verdict.isUsable
                                ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                            tint: Palette.verdict(plan.verdict)
                        )
                        Spacer()
                        Text("peak \(plan.peak.formatted) of \(plan.budget.formatted)")
                            .font(.caption).monospacedDigit()
                            .foregroundStyle(.secondary)
                    }

                    ForEach(plan.notes, id: \.self) { note in
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    ForEach(plan.remediations.prefix(3)) { remediation in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(remediation.title).font(.caption.weight(.medium))
                                Spacer()
                                Text("−\(remediation.saving.formatted)")
                                    .font(.caption).monospacedDigit()
                                    .foregroundStyle(.green)
                            }
                            Text(remediation.cost)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Result

    private var resultCard: some View {
        Card(title: "Result", systemImage: "photo") {
            VStack(spacing: 14) {
                if model.isGeneratingImage {
                    VStack(spacing: 12) {
                        ProgressView(
                            value: model.imageProgress.map {
                                Double($0.step) / Double(max(1, $0.total))
                            } ?? 0
                        )
                        .progressViewStyle(.linear)
                        Text(model.imageState.label)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text("The first run downloads the weights, which can take a while.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 260)
                } else if let result = model.lastImage,
                          let image = NSImage(contentsOf: result.image) {
                    // Capped rather than free: at 1024² the image otherwise takes the full column
                    // and pushes the measured peak below the fold, which is the one number worth
                    // reading after a run — it is what the plan above gets checked against.
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: 460)
                        .clipShape(.rect(cornerRadius: 8))

                    HStack {
                        Readout(
                            label: "Time",
                            value: String(format: "%.1fs", result.elapsed),
                            caption: "total"
                        )
                        Readout(
                            label: "Speed",
                            value: String(format: "%.2f", result.stepsPerSecond),
                            caption: "steps/sec"
                        )
                        if let peak = result.peakMemory {
                            Readout(
                                label: "Peak memory",
                                value: peak.formatted,
                                caption: "measured"
                            )
                        }
                    }

                    HStack {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([result.image])
                        } label: {
                            Label("Reveal in Finder", systemImage: "folder")
                        }
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.writeObjects([image])
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        Spacer()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else if case .failed(let message) = model.imageState {
                    EmptyStateView(
                        systemImage: "exclamationmark.triangle",
                        title: "Generation failed",
                        message: message
                    )
                } else {
                    EmptyStateView(
                        systemImage: "photo.on.rectangle.angled",
                        title: "No image yet",
                        message: "Describe something and press Generate. Everything runs on this "
                            + "Mac — nothing is uploaded."
                    )
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Helpers

    private var currentEntry: DiffusionEntry? {
        DiffusionCatalog.entry(id: model.selectedDiffusionModel)
    }

    private var canGenerate: Bool {
        model.imageRuntime != nil
            && !model.imagePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Images here are square, so one control drives both dimensions.
    private var sizeBinding: Binding<Int> {
        Binding(
            get: { model.imageConfiguration.width },
            set: {
                model.imageConfiguration.width = $0
                model.imageConfiguration.height = $0
            }
        )
    }
}
