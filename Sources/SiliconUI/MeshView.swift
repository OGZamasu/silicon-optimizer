import AppKit
import SiliconCatalog
import SiliconCore
import SiliconPlanner
import SiliconRuntime
import SwiftUI
import UniformTypeIdentifiers

/// The 3D tab: image in, mesh out, with the same promise as everything else in the app —
/// what it costs is stated before it runs, and the result is a real file you can take
/// anywhere, not a preview trapped in the window.
struct MeshView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedResultID: String?

    /// Two ways in: bring a picture, or describe one and let the local image model draft it.
    enum SourceMode: String, CaseIterable {
        case picture = "Use a picture"
        case describe = "Describe it"
    }
    @State private var sourceMode: SourceMode = .picture

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                if proxy.size.width >= 900 {
                    HStack(alignment: .top, spacing: 16) {
                        VStack(spacing: 16) {
                            composer
                            planCard
                        }
                        .frame(width: 380)
                        resultCard
                    }
                    .padding(20)
                } else {
                    VStack(spacing: 16) {
                        composer
                        planCard
                        resultCard
                    }
                    .padding(20)
                }
            }
        }
        .background(.background)
        .navigationTitle("3D")
    }

    // MARK: - Composer

    private var composer: some View {
        @Bindable var model = model
        return Card(title: "Source image", systemImage: "cube.transparent") {
            Picker("Source", selection: $sourceMode) {
                ForEach(SourceMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch sourceMode {
            case .picture:
                imageWell
                if !model.generatedImages.isEmpty {
                    Button {
                        model.meshInputImage = model.generatedImages.first?.image
                    } label: {
                        Label(
                            "Use the latest generated image",
                            systemImage: "photo.on.rectangle"
                        )
                    }
                    .buttonStyle(.link)
                    .controlSize(.small)
                }
            case .describe:
                describePanel
            }

            Divider()

            HStack {
                Text("Model")
                Spacer()
                Picker("Model", selection: $model.selectedMeshModel) {
                    ForEach(MeshCatalog.all) { entry in
                        Text(entry.name).tag(entry.id)
                    }
                }
                .labelsHidden()
                .frame(width: 190)
            }

            if let entry = currentEntry {
                Text(entry.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                statusBanner(entry)
                options(entry)
                generateControls(entry)
                queueList
            }
        }
    }

    private var imageWell: some View {
        Button(action: chooseImage) {
            Group {
                if let image = model.meshInputImage,
                   let preview = NSImage(contentsOf: image) {
                    Image(nsImage: preview)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: 160)
                        .clipShape(.rect(cornerRadius: 8))
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "photo.badge.plus")
                            .font(.system(size: 26, weight: .light))
                            .foregroundStyle(.secondary)
                        Text("Drop an image, or click to choose")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 110)
                    .background(.background.secondary, in: .rect(cornerRadius: 8))
                }
            }
        }
        .buttonStyle(.plain)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            model.meshInputImage = url
            return true
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            model.meshInputImage = url
        }
    }

    /// Describe → draft → approve → generate. The draft goes through the same image pipeline
    /// as the Images tab; when it lands it fills the source slot above the Generate button,
    /// so the person sees the picture before committing minutes to the mesh.
    @ViewBuilder
    private var describePanel: some View {
        @Bindable var model = model

        TextField(
            "What should it look like? e.g. \"a red sneaker, plain background\"",
            text: $model.imagePrompt,
            axis: .vertical
        )
        .lineLimit(2...4)
        .textFieldStyle(.plain)
        .padding(8)
        .background(.background.secondary, in: .rect(cornerRadius: 8))

        HStack {
            Picker("Image model", selection: $model.selectedDiffusionModel) {
                ForEach(DiffusionCatalog.all) { entry in
                    Text(entry.name).tag(entry.id)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 170)
            Spacer()
            Button {
                model.draftImageForMesh()
            } label: {
                Label("Draft the picture", systemImage: "wand.and.stars")
            }
            .disabled(
                model.imagePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || model.isGeneratingImage
            )
        }

        if model.isGeneratingImage, model.routeNextImageToMesh || model.currentImageJob != nil {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(model.imageState.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        if let image = model.meshInputImage, let preview = NSImage(contentsOf: image) {
            VStack(alignment: .leading, spacing: 6) {
                Image(nsImage: preview)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 140)
                    .clipShape(.rect(cornerRadius: 8))
                Text("Happy with it? Generate below — or change the words and draft again.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private func statusBanner(_ entry: MeshEntry) -> some View {
        let installation = model.meshInstallation(for: entry)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: installation.isInstalled
                    ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(installation.isInstalled ? .green : .orange)
                    .imageScale(.small)
                Text(installation.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            if let download = model.meshDownloads[entry.id] {
                if let error = download.error {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Try again") {
                        model.cancelMeshInstall(entry.id)
                        model.installMeshWeights(entry)
                    }
                    .controlSize(.small)
                } else {
                    HStack(spacing: 8) {
                        ProgressView(value: download.progress?.fraction ?? 0)
                            .progressViewStyle(.linear)
                        if let progress = download.progress {
                            Text("\(Int(progress.fraction * 100))%")
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Button {
                            model.cancelMeshInstall(entry.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .imageScale(.small)
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Cancel this download")
                    }
                }
            } else if installation.missing == .weights,
                      let download = model.meshWeightsDownload(for: entry) {
                Button {
                    model.installMeshWeights(entry)
                } label: {
                    Label(
                        "Download (\(download.expectedSize.formatted))",
                        systemImage: "arrow.down.circle"
                    )
                }
                .controlSize(.small)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 7))
    }

    @ViewBuilder
    private func options(_ entry: MeshEntry) -> some View {
        @Bindable var model = model

        if entry.supportsPipelineType {
            HStack {
                Text("Pipeline")
                Spacer()
                Picker("Pipeline", selection: $model.meshConfiguration.pipelineType) {
                    Text("512 · measured").tag("512")
                    Text("1024").tag("1024")
                    Text("1024 cascade").tag("1024_cascade")
                }
                .labelsHidden()
                .frame(width: 140)
            }
        }
        if entry.supportsTextureSize {
            HStack {
                Text("Texture")
                Spacer()
                Picker("Texture", selection: $model.meshConfiguration.textureSize) {
                    Text("512").tag(512)
                    Text("1024").tag(1024)
                    Text("2048").tag(2048)
                }
                .labelsHidden()
                .frame(width: 100)
            }
        }
        if entry.supportsSteps {
            HStack {
                Text("Steps")
                Spacer()
                Stepper(
                    value: Binding(
                        get: { model.meshConfiguration.steps ?? entry.defaultSteps ?? 30 },
                        set: { model.meshConfiguration.steps = $0 }
                    ),
                    in: 4...60
                ) {
                    Text("\(model.meshConfiguration.steps ?? entry.defaultSteps ?? 30)")
                        .monospacedDigit()
                }
                .frame(width: 100)
            }
        }
        if entry.supportsQuantization {
            HStack {
                Text("Precision")
                Spacer()
                Picker("Precision", selection: $model.meshConfiguration.quantize) {
                    Text("fp16").tag(Int?.none)
                    Text("8-bit").tag(Int?.some(8))
                    Text("4-bit").tag(Int?.some(4))
                }
                .labelsHidden()
                .frame(width: 100)
            }
        }
        if entry.supportsVertexBudget {
            HStack {
                Text("Vertices")
                Spacer()
                Text("\(model.meshConfiguration.vertexBudget)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { Double(model.meshConfiguration.vertexBudget) },
                        set: { model.meshConfiguration.vertexBudget = Int($0 / 100) * 100 }
                    ),
                    in: 200...5000
                )
                .frame(width: 140)
            }
        }
    }

    @ViewBuilder
    private func generateControls(_ entry: MeshEntry) -> some View {
        if model.isGeneratingMesh {
            Button(role: .destructive) {
                model.cancelMesh()
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
        } else {
            Button {
                model.generateMesh()
            } label: {
                Label("Generate 3D model", systemImage: "cube")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canGenerate(entry))

            if model.meshInputImage == nil {
                Text("Pick a source image first — a photo, or something from the Images tab.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var queueList: some View {
        if !model.meshQueue.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.meshQueue) { job in
                    HStack(spacing: 6) {
                        Image(systemName: "clock")
                            .imageScale(.small)
                            .foregroundStyle(.tertiary)
                        Text(job.image.lastPathComponent)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(job.modelName)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Button {
                            model.removeQueuedMeshJob(job.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .imageScale(.small)
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(10)
            .background(.background.secondary, in: .rect(cornerRadius: 8))
        }
    }

    private func canGenerate(_ entry: MeshEntry) -> Bool {
        model.meshInputImage != nil && model.meshInstallation(for: entry).isInstalled
    }

    // MARK: - Plan

    @ViewBuilder
    private var planCard: some View {
        if let entry = currentEntry {
            let plan = model.meshPlan(for: entry, configuration: model.meshConfiguration)
            Card(title: "Memory plan", systemImage: "memorychip") {
                if plan.isRemote {
                    HStack(spacing: 8) {
                        Image(systemName: "network")
                            .foregroundStyle(.secondary)
                        Text("Runs on the LATO.2 machine — this Mac's memory is untouched.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(plan.phases) { phase in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(phase.name)
                                    .font(.caption.weight(.medium))
                                Spacer()
                                Text(phase.resident.formatted)
                                    .font(.caption)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            ProgressView(value: min(1, phase.resident.fraction(of: plan.budget)))
                                .progressViewStyle(.linear)
                                .tint(phase.id == plan.peakPhase?.id
                                    ? Palette.verdict(plan.verdict) : .secondary)
                            Text(phase.detail)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    HStack {
                        Badge(
                            text: plan.verdict.label,
                            systemImage: plan.verdict.isUsable
                                ? "checkmark.circle" : "exclamationmark.triangle",
                            tint: Palette.verdict(plan.verdict)
                        )
                        Spacer()
                        Text("budget \(plan.budget.formatted)")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }

                ForEach(plan.notes, id: \.self) { note in
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(plan.remediations.prefix(2)) { remediation in
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Image(systemName: "arrow.turn.down.right")
                            .imageScale(.small)
                            .foregroundStyle(.tertiary)
                        Text(remediation.title)
                            .font(.caption)
                        if remediation.saving > .zero {
                            Text("−\(remediation.saving.formatted)")
                                .font(.caption.weight(.medium))
                                .monospacedDigit()
                                .foregroundStyle(.green)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Result

    private var resultCard: some View {
        Card(title: "Result", systemImage: "rotate.3d") {
            if model.isGeneratingMesh {
                generationProgress
            } else if case .failed(let message) = model.meshState {
                EmptyStateView(
                    systemImage: "exclamationmark.triangle",
                    title: "Generation failed",
                    message: message
                )
            } else if let result = displayedResult {
                meshResult(result)
            } else {
                EmptyStateView(
                    systemImage: "cube.transparent",
                    title: "No model yet",
                    message: "Pick an image and generate. The result lands here as an "
                        + "interactive 3D preview, and on disk as a file for any tool."
                )
            }
        }
    }

    private var generationProgress: some View {
        VStack(spacing: 10) {
            if let progress = model.meshProgress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 300)
            } else {
                ProgressView()
            }
            if let job = model.currentMeshJob {
                Text(job.modelName)
                    .font(.callout.weight(.medium))
            }
            Text(model.meshState.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, minHeight: 260)
    }

    private var displayedResult: MeshResult? {
        if let id = selectedResultID,
           let match = model.meshResults.first(where: { $0.id == id }) {
            return match
        }
        return model.meshResults.first
    }

    @ViewBuilder
    private func meshResult(_ result: MeshResult) -> some View {
        if let file = result.primaryFile {
            MeshViewer(url: file)
                .frame(maxWidth: .infinity, minHeight: 340)
                .background(.background.secondary, in: .rect(cornerRadius: 8))
        }

        HStack(spacing: 16) {
            Readout(label: "Model", value: result.modelName)
            Readout(label: "Time", value: result.elapsed.durationLabel)
            Readout(label: "Files", value: fileSummary(result))
            Spacer()
        }

        HStack(spacing: 8) {
            if let file = result.primaryFile {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([file])
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                openExternallyMenu(file: file, result: result)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)

        if model.meshResults.count > 1 {
            Divider()
            historyList
        }
    }

    private func fileSummary(_ result: MeshResult) -> String {
        var parts: [String] = []
        if result.glb != nil { parts.append("GLB") }
        if result.obj != nil { parts.append("OBJ") }
        if !result.textures.isEmpty { parts.append("textures") }
        return parts.joined(separator: " + ")
    }

    /// "Open in…" — Fusion 360 first when installed, then every app that claims the file.
    private func openExternallyMenu(file: URL, result: MeshResult) -> some View {
        Menu {
            // Fusion 360 imports OBJ, not GLB, so hand it the OBJ when there is one.
            if let fusion = Self.fusion360 {
                let target = result.obj ?? file
                Button("Fusion 360\(result.obj != nil ? " (OBJ)" : "")") {
                    NSWorkspace.shared.open(
                        [target], withApplicationAt: fusion,
                        configuration: NSWorkspace.OpenConfiguration()
                    )
                }
                Divider()
            }
            ForEach(Self.applications(for: file), id: \.self) { app in
                Button(Self.applicationName(app)) {
                    NSWorkspace.shared.open(
                        [file], withApplicationAt: app,
                        configuration: NSWorkspace.OpenConfiguration()
                    )
                }
            }
            if let obj = result.obj, file != obj {
                Divider()
                ForEach(Self.applications(for: obj), id: \.self) { app in
                    Button("\(Self.applicationName(app)) (OBJ)") {
                        NSWorkspace.shared.open(
                            [obj], withApplicationAt: app,
                            configuration: NSWorkspace.OpenConfiguration()
                        )
                    }
                }
            }
        } label: {
            Label("Open in…", systemImage: "arrow.up.forward.app")
        }
    }

    static var fusion360: URL? {
        let candidates = [
            "/Applications/Autodesk Fusion 360.app",
            "/Applications/Autodesk Fusion.app",
            NSHomeDirectory() + "/Applications/Autodesk Fusion 360.app",
            NSHomeDirectory() + "/Applications/Autodesk Fusion.app",
        ]
        return candidates.map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func applications(for file: URL) -> [URL] {
        var seen = Set<String>()
        return NSWorkspace.shared.urlsForApplications(toOpen: file)
            .filter { app in
                let name = applicationName(app)
                guard name != "Silicon Optimizer", !name.isEmpty else { return false }
                return seen.insert(name).inserted
            }
    }

    static func applicationName(_ url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    private var historyList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Earlier this session")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            ForEach(model.meshResults) { result in
                Button {
                    selectedResultID = result.id
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: result.id == displayedResult?.id
                            ? "cube.fill" : "cube")
                            .imageScale(.small)
                            .foregroundStyle(result.id == displayedResult?.id
                                ? Color.accentColor : Color.secondary)
                        Text(result.baseName)
                            .font(.caption)
                            .monospacedDigit()
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(result.modelName)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(result.elapsed.durationLabel)
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Helpers

    private var currentEntry: MeshEntry? {
        MeshCatalog.entry(id: model.selectedMeshModel)
    }
}
