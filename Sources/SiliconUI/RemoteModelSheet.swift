import SiliconCatalog
import SiliconCore
import SiliconPlanner
import SwiftUI

/// Inspects a Hugging Face repository the bundled catalog has never seen.
///
/// The point is that leaving the curated list should not mean losing the memory plan. The GGUF
/// header is read over a range request — a few hundred kilobytes, no download — so an arbitrary
/// repository gets the same weights/KV/compute breakdown and the same verdict as a curated one.
struct RemoteModelSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var result: HuggingFaceClient.SearchResult

    @State private var files: [HuggingFaceClient.RepoFile] = []
    @State private var selected: HuggingFaceClient.RepoFile?
    @State private var shape: ModelShape?
    @State private var isLoadingFiles = true
    @State private var isReadingHeader = false
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 620, height: 640)
        .task { await loadFiles() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(result.name).font(.title3.weight(.semibold))
                HStack(spacing: 10) {
                    Text(result.author)
                    Label(formatted(result.downloads), systemImage: "arrow.down.circle")
                    Label(formatted(result.likes), systemImage: "heart")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                NSWorkspace.shared.open(HuggingFaceClient.pageURL(repository: result.id))
            } label: {
                Image(systemName: "arrow.up.forward.square")
            }
            .buttonStyle(.borderless)
            .help("View on Hugging Face")
        }
        .padding(20)
    }

    // MARK: - Body

    @ViewBuilder
    private var content: some View {
        if isLoadingFiles {
            centered { ProgressView("Reading the repository…") }
        } else if let failure {
            centered {
                EmptyStateView(
                    systemImage: "exclamationmark.triangle",
                    title: "Could not read this repository",
                    message: failure
                )
            }
        } else if files.isEmpty {
            centered {
                EmptyStateView(
                    systemImage: "questionmark.folder",
                    title: "No GGUF files here",
                    message: "This repository has no GGUF weights, so it cannot be loaded by "
                        + "llama.cpp. It may hold the original safetensors instead."
                )
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let plan { planSection(plan) }
                    if let shape { architecture(shape) }
                    Text("Quantizations").font(.headline)
                    ForEach(files, id: \.path) { file in
                        fileRow(file)
                    }
                }
                .padding(20)
            }
        }
    }

    private func fileRow(_ file: HuggingFaceClient.RepoFile) -> some View {
        let isSelected = selected?.path == file.path
        let quantization = Quantization.inferred(fromFilename: file.path)
        let label = Quantization.label(fromFilename: file.path)
            ?? (file.path as NSString).lastPathComponent

        return Button {
            selected = file
            Task { await readHeader(for: file) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.callout.weight(.medium))
                    if let quantization {
                        Text(quantization.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(file.size.formatted)
                    .font(.callout).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(
                isSelected ? Color.accentColor.opacity(0.08) : .clear,
                in: .rect(cornerRadius: 8)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func architecture(_ shape: ModelShape) -> some View {
        Card(title: "Architecture", systemImage: "square.grid.3x3") {
            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                spacing: 10
            ) {
                stat("Parameters", parameterLabel(shape.totalParameters))
                stat("Layers", String(shape.blockCount))
                stat("Context", shape.trainingContextLength.contextLabel)
                if let moe = shape.moe {
                    stat("Experts", String(moe.expertCount))
                    stat("Active per token", String(moe.expertsUsedPerToken))
                    stat("Expert FFN", String(moe.expertFeedForwardLength))
                } else {
                    stat("Type", "Dense")
                    stat("KV heads", String(shape.headCountKV))
                    stat("Head width", String(shape.headDimension))
                }
            }
            Text("Read from the file's own header, not guessed from its name.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func planSection(_ plan: MemoryPlan) -> some View {
        Card(title: "Memory plan", systemImage: "memorychip") {
            MemoryPlanBreakdown(plan: plan)
            ForEach(plan.remediations.prefix(2)) { remediation in
                Text("· " + remediation.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Downloading costs only disk, so a failing memory plan warns instead of blocking.
            if let warning = installWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if isReadingHeader {
                    ProgressView().controlSize(.small)
                    Text("Reading the header…").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    install()
                } label: {
                    Label(
                        selected.map { "Install \($0.size.formatted)" } ?? "Install",
                        systemImage: "arrow.down.circle.fill"
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(selected == nil)
            }
        }
        .padding(16)
    }

    /// Distinguishes "other apps are in the way right now" from "this Mac cannot run it at all",
    /// so the user knows whether the download is worth the bandwidth.
    private var installWarning: String? {
        guard let plan, !plan.verdict.isUsable, let shape, let selected else { return nil }
        let quantization = Quantization.inferred(fromFilename: selected.path) ?? .q4_K_M
        let context = min(shape.trainingContextLength, 8192)
        let idlePlan = model.planner().plan(
            shape: shape, quantization: quantization,
            configuration: LoadConfiguration(contextLength: context)
        )
        if idlePlan.verdict.isUsable {
            return "This fits on its own, but other apps are currently holding too much memory. "
                + "You can download now and free up memory before loading."
        }
        return "This file is not expected to fit in memory on this Mac. You can still download "
            + "it, but expect to reduce the context or pick a smaller quantization to run it."
    }

    // MARK: - Work

    private var plan: MemoryPlan? {
        guard let shape, let selected else { return nil }
        let quantization = Quantization.inferred(fromFilename: selected.path) ?? .q4_K_M
        // Planned at a context the machine can actually afford, rather than the model's
        // trained maximum, which for some models is 256K and would look alarming.
        let context = min(shape.trainingContextLength, 8192)
        return model.planner().plan(
            shape: shape, quantization: quantization,
            configuration: LoadConfiguration(contextLength: context),
            otherAppsInUse: model.memoryUsedByOtherApps
        )
    }

    private func loadFiles() async {
        defer { isLoadingFiles = false }
        let token = model.settings.huggingFaceToken.isEmpty ? nil : model.settings.huggingFaceToken
        do {
            let all = try await HuggingFaceClient(token: token).files(in: result.id)
            let weights = all
                .filter { $0.path.lowercased().hasSuffix(".gguf") }
                .filter { !ModelResolver.isCompanionFile($0.path) }
                // Shards are listed by their head only; the rest come along automatically.
                .filter { !$0.path.contains("-of-") || $0.path.contains("00001-of-") }
                .sorted { $0.size < $1.size }
            files = weights

            // Preselect the one most people should take.
            if let recommended = weights.first(where: {
                Quantization.inferred(fromFilename: $0.path) == .q4_K_M
            }) ?? weights.first {
                selected = recommended
                await readHeader(for: recommended)
            }
        } catch {
            failure = error.localizedDescription
        }
    }

    private func readHeader(for file: HuggingFaceClient.RepoFile) async {
        isReadingHeader = true
        defer { isReadingHeader = false }
        let token = model.settings.huggingFaceToken.isEmpty ? nil : model.settings.huggingFaceToken
        shape = await RemoteGGUFReader(token: token)
            .readShape(repository: result.id, file: file.path)
    }

    private func install() {
        guard let selected, let shape else { return }
        let quantization = Quantization.inferred(fromFilename: selected.path) ?? .q4_K_M
        let entry = model.makeEntry(
            repository: result.id, file: selected.path,
            quantization: quantization, size: selected.size, shape: shape
        )
        model.install(entry, quantization: quantization)
        dismiss()
    }

    private func parameterLabel(_ count: Int64) -> String {
        let billions = Double(count) / 1e9
        return billions >= 1
            ? String(format: "%.1fB", billions)
            : String(format: "%.0fM", Double(count) / 1e6)
    }

    private func formatted(_ value: Int) -> String {
        value >= 1_000_000 ? String(format: "%.1fM", Double(value) / 1e6)
            : value >= 1000 ? String(format: "%.1fk", Double(value) / 1000)
            : String(value)
    }
}
