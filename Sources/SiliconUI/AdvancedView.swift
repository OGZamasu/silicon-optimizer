import SiliconCatalog
import SiliconCore
import SiliconPlanner
import SiliconRuntime
import SwiftUI

/// Full manual control over how a model is launched.
///
/// The rest of the app exists so this screen is unnecessary. It is here for the case the
/// planner cannot anticipate — an unusual model, a patched runtime, a flag added upstream last
/// week — and it is built around one rule: every change is costed in the same memory plan the
/// automatic path uses, so a power user is never flying blind either.
struct AdvancedView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var installed: InstalledModel

    @State private var configuration: LoadConfiguration
    @State private var extraArguments: String
    @State private var didCopy = false

    init(installed: InstalledModel, configuration: LoadConfiguration, extraArguments: String) {
        self.installed = installed
        _configuration = State(initialValue: configuration)
        _extraArguments = State(initialValue: extraArguments)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    contextSection
                    batchSection
                    computeSection
                    if installed.shape?.isMoE == true { expertSection }
                    customSection
                    commandSection
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 660, height: 720)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Advanced settings").font(.title3.weight(.semibold))
                Text(installed.name + " · " + installed.quantization.rawValue)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Reset to recommended") {
                configuration = model.defaultConfiguration(for: installed)
                extraArguments = ""
            }
            .controlSize(.small)
        }
        .padding(20)
    }

    // MARK: - Sections

    private var contextSection: some View {
        Card(title: "Context", systemImage: "text.alignleft") {
            VStack(alignment: .leading, spacing: 12) {
                stepperRow(
                    "Context length",
                    value: $configuration.contextLength,
                    options: [2048, 4096, 8192, 16_384, 32_768, 65_536, 131_072, 262_144],
                    format: { $0.contextLabel },
                    help: "Tokens the model can see at once. The KV cache grows linearly with this."
                )
                Picker("KV cache precision", selection: $configuration.kvCachePrecision) {
                    ForEach(KVCachePrecision.allCases) { precision in
                        Text(precision.label).tag(precision)
                    }
                }
                Text("Quantizing the cache is the cheapest way to buy context. Q8_0 halves it "
                     + "with no measurable quality loss.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var batchSection: some View {
        Card(title: "Batching", systemImage: "square.stack.3d.down.right") {
            VStack(alignment: .leading, spacing: 12) {
                stepperRow(
                    "Batch size",
                    value: $configuration.batchSize,
                    options: [128, 256, 512, 1024, 2048, 4096],
                    format: { String($0) },
                    help: "Tokens submitted per evaluation. Larger is faster to a point."
                )
                stepperRow(
                    "Micro-batch size",
                    value: $configuration.microBatchSize,
                    options: [1, 2, 4, 8, 16, 32, 64, 128, 256, 512],
                    format: { String($0) },
                    help: "Tokens actually processed at once. This is what sizes the compute "
                        + "buffers, and what expert streaming constrains."
                )
                if configuration.microBatchSize > configuration.batchSize {
                    warning("Micro-batch cannot exceed batch size; llama.cpp will refuse to start.")
                }
            }
        }
    }

    private var computeSection: some View {
        Card(title: "Compute", systemImage: "cpu") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Flash Attention", isOn: $configuration.flashAttention)
                Text("Computes attention without materialising the score matrix. Smaller and "
                     + "faster; there is no reason to turn this off except to compare.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                HStack {
                    Text("GPU layers")
                    Spacer()
                    Text(configuration.gpuLayerFraction >= 1
                         ? "All"
                         : "\(Int(Double(installed.shape?.blockCount ?? 32) * configuration.gpuLayerFraction))"
                         + " of \(installed.shape?.blockCount ?? 32)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $configuration.gpuLayerFraction, in: 0...1)
                Text("On Apple Silicon the GPU shares memory with the CPU, so there is rarely a "
                     + "reason to leave layers behind. Lowering this trades speed for nothing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                HStack {
                    Text("Threads")
                    Spacer()
                    Text(configuration.threads == 0 ? "Automatic" : String(configuration.threads))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { Double(configuration.threads) },
                        set: { configuration.threads = Int($0) }
                    ),
                    in: 0...Double(model.profile.performanceCores + model.profile.efficiencyCores),
                    step: 1
                )
                Text("Only the \(model.profile.performanceCores) performance cores are worth "
                     + "scheduling on. Including efficiency cores slows generation, because the "
                     + "fast cores wait at every barrier.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var expertSection: some View {
        if let moe = installed.shape?.moe {
            Card(title: "Expert streaming", systemImage: "arrow.down.doc") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Page experts from disk", isOn: Binding(
                        get: { configuration.expertStreaming != nil },
                        set: { enabled in
                            configuration.expertStreaming = enabled
                                ? ExpertStreamingConfiguration(slotCount: max(8, moe.expertCount / 4))
                                : nil
                        }
                    ))
                    .disabled(!model.selector.expertStreamingAvailable)

                    if !model.selector.expertStreamingAvailable {
                        warning("The installed llama.cpp does not accept --moe-n-slots. Build one "
                                + "with the expert-paging patch to enable this.")
                    }

                    if let streaming = configuration.expertStreaming {
                        HStack {
                            Text("Resident experts")
                            Spacer()
                            Text("\(streaming.slotCount) of \(moe.expertCount)")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(
                            value: Binding(
                                get: { Double(streaming.slotCount) },
                                set: { configuration.expertStreaming?.slotCount = Int($0) }
                            ),
                            in: 8...Double(moe.expertCount), step: 8
                        )

                        let maximum = ExpertStreamingConfiguration.maximumMicroBatch(
                            slotCount: streaming.slotCount,
                            expertsUsedPerToken: moe.expertsUsedPerToken
                        )
                        if configuration.microBatchSize > maximum {
                            warning("The pool must hold every expert the in-flight batch could "
                                    + "select: ubatch × \(moe.expertsUsedPerToken) ≤ "
                                    + "\(streaming.slotCount). Lower the micro-batch to \(maximum).")
                            Button("Set micro-batch to \(maximum)") {
                                configuration.microBatchSize = maximum
                                configuration.batchSize = max(configuration.batchSize, maximum)
                            }
                            .controlSize(.small)
                        }

                        if let speed = model.profile.ssdReadMBps, speed < 1500 {
                            warning("This volume reads at \(Int(speed)) MB/s. Streaming from it "
                                    + "will be slow.")
                        }
                    }
                }
            }
        }
    }

    private var customSection: some View {
        Card(title: "Extra arguments", systemImage: "terminal") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("--some-flag value", text: $extraArguments, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(2...5)
                    .padding(10)
                    .background(.background.secondary, in: .rect(cornerRadius: 8))
                Text("Appended verbatim, after everything above. Anything llama.cpp accepts but "
                     + "this app does not model yet goes here — including flags added upstream "
                     + "since this build.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var commandSection: some View {
        Card(title: "Launch command", systemImage: "chevron.left.forwardslash.chevron.right") {
            VStack(alignment: .leading, spacing: 10) {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(command)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                }
                .background(.background.secondary, in: .rect(cornerRadius: 8))

                HStack {
                    ForEach(problems, id: \.self) { problem in
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                        didCopy = true
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            didCopy = false
                        }
                    } label: {
                        Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        let plan = currentPlan
        return VStack(spacing: 12) {
            MemoryPlanBreakdown(plan: plan)
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    model.setExtraArguments(extraArguments)
                    model.load(installed, configuration: configuration)
                    dismiss()
                } label: {
                    Label("Load with these settings", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!plan.verdict.isUsable || !problems.isEmpty)
            }
        }
        .padding(16)
    }

    // MARK: - Derived

    private var currentPlan: MemoryPlan {
        guard let shape = installed.shape else {
            return model.planner().plan(
                shape: ModelShape(
                    totalParameters: 0, blockCount: 0, embeddingLength: 0, feedForwardLength: 0,
                    headCount: 1, headCountKV: 1, trainingContextLength: 0
                ),
                quantization: installed.quantization, configuration: configuration
            )
        }
        return model.planner().plan(
            shape: shape, quantization: installed.quantization,
            configuration: configuration, otherAppsInUse: model.memoryUsedByOtherApps
        )
    }

    private var arguments: LlamaArguments {
        LlamaArguments(
            model: installed, configuration: configuration, port: 8080,
            installation: model.selector.available[.llamaCpp],
            extraArguments: LlamaArguments.split(extraArguments)
        )
    }

    private var command: String {
        let executable = model.selector.available[.llamaCpp]?.executable
            ?? URL(fileURLWithPath: "llama-server")
        return arguments.displayCommand(executable: executable)
    }

    private var problems: [String] { arguments.validate() }

    // MARK: - Controls

    private func stepperRow(
        _ label: String,
        value: Binding<Int>,
        options: [Int],
        format: @escaping (Int) -> String,
        help: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Picker("", selection: value) {
                    ForEach(options, id: \.self) { option in
                        Text(format(option)).tag(option)
                    }
                }
                .labelsHidden()
                .frame(width: 110)
            }
            Text(help).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func warning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}
