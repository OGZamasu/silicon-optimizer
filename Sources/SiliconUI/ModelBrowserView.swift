import AppKit
import SiliconCatalog
import SiliconCore
import SiliconPlanner
import SwiftUI
import UniformTypeIdentifiers

struct ModelBrowserView: View {
    @Environment(AppModel.self) private var model

    @State private var search = ""
    @State private var category: ModelCategory?
    @State private var showsOnlyRunnable = true
    @State private var inspecting: ModelEntry?
    @State private var inspectingRemote: HuggingFaceClient.SearchResult?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if search.isEmpty && category == nil {
                    recommendationBanner
                    installedSection
                }
                catalogSection
                imageSection
                meshSection
                remoteSection
            }
            .padding(20)
        }
        .background(.background)
        .navigationTitle("Models")
        .searchable(text: $search, placement: .toolbar, prompt: "Search models and Hugging Face")
        .onChange(of: search) { model.searchHuggingFace(search) }
        .task { if !search.isEmpty { model.searchHuggingFace(search) } }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker("Category", selection: $category) {
                    Text("All").tag(ModelCategory?.none)
                    ForEach(ModelCategory.allCases) { category in
                        Label(category.rawValue, systemImage: category.systemImage)
                            .tag(ModelCategory?.some(category))
                    }
                }
                .pickerStyle(.menu)
            }
            ToolbarItem(placement: .primaryAction) {
                Toggle("Only what fits", isOn: $showsOnlyRunnable)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    importExistingModel()
                } label: {
                    Label("Import…", systemImage: "square.and.arrow.down.on.square")
                        .labelStyle(.titleAndIcon)
                }
                .help(
                    "Register a .gguf file that's already on disk — moved there by hand, or "
                    + "downloaded some other way — without copying it."
                )
            }
        }
        .sheet(item: $inspecting) { entry in
            ModelDetailSheet(entry: entry)
                .environment(model)
        }
        .sheet(item: $inspectingRemote) { result in
            RemoteModelSheet(result: result)
                .environment(model)
        }
    }

    // MARK: - Recommendation

    @ViewBuilder
    private var recommendationBanner: some View {
        if let pick = model.autoConfigurator().topPick(otherAppsInUse: model.memoryUsedByOtherApps) {
            let installed = model.isInstalled(pick.entry, quantization: pick.quantization)
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .foregroundStyle(.yellow)
                        Text("Best for your \(model.profile.chipName)")
                            .font(.headline)
                        Spacer()
                        RatingStars(rating: pick.entry.rating)
                    }

                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(pick.entry.name)
                                .font(.title2.weight(.semibold))
                            Text(pick.entry.summary)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(pick.rationale)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        VStack(spacing: 8) {
                            if installed {
                                Button {
                                    if let installedModel = model.installedModels.first(where: {
                                        $0.catalogID == pick.entry.id
                                            && $0.quantization == pick.quantization
                                    }) {
                                        model.load(installedModel, configuration: pick.configuration)
                                        model.selectedTab = .chat
                                    }
                                } label: {
                                    Label("Load", systemImage: "play.fill")
                                        .frame(width: 96)
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
                            } else {
                                Button {
                                    model.install(pick.entry, quantization: pick.quantization)
                                } label: {
                                    Label("Install", systemImage: "arrow.down.circle.fill")
                                        .frame(width: 96)
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
                            }
                            Text(pick.entry.variant(for: pick.quantization)?
                                .downloadSize.formatted ?? "")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    MemoryPlanBreakdown(plan: pick.plan)
                }
            }
        }
    }

    // MARK: - Installed

    @ViewBuilder
    private var installedSection: some View {
        if !model.installedModels.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Installed")
                    .font(.title3.weight(.semibold))
                ForEach(model.installedModels) { installed in
                    InstalledModelRow(installed: installed)
                }
            }
        }
    }

    // MARK: - Catalog

    private var catalogSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(search.isEmpty ? "Catalog" : "Results")
                .font(.title3.weight(.semibold))

            if filteredEntries.isEmpty {
                Text(showsOnlyRunnable
                     ? "Nothing in this category fits in \(model.profile.totalMemory.formatted). Turn off “Only what fits” to see everything."
                     : "No models match that search.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            }

            ForEach(filteredEntries, id: \.entry.id) { row in
                CatalogRow(entry: row.entry, recommendation: row.recommendation) {
                    inspecting = row.entry
                }
            }
        }
    }

    // MARK: - Image models

    /// Image models live in their own section rather than the main catalog.
    ///
    /// They are not interchangeable with language models anywhere that matters: a different
    /// runtime, a phased memory plan instead of one number, and no quantization choice at install
    /// time because the precision is decided per run. Filing them under the same list would imply
    /// a sameness that breaks the moment you click anything.
    @ViewBuilder
    private var imageSection: some View {
        if search.isEmpty, category == nil {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Image models")
                        .font(.title3.weight(.semibold))
                    Text("run through MFLUX")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ForEach(DiffusionCatalog.all) { entry in
                    DiffusionCatalogRow(entry: entry)
                }
            }
        }
    }

    // MARK: - 3D models

    /// Same reasoning as the image section: 3D backends are their own programs with their
    /// own memory characters, so they get their own list — but they still belong in the
    /// one place someone looks to answer "what models do I have".
    @ViewBuilder
    private var meshSection: some View {
        if search.isEmpty, category == nil {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("3D models")
                        .font(.title3.weight(.semibold))
                    Text("image to mesh, in the 3D tab")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ForEach(MeshCatalog.all) { entry in
                    MeshCatalogRow(entry: entry)
                }
            }
        }
    }

    // MARK: - Hugging Face

    @ViewBuilder
    private var remoteSection: some View {
        if !search.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("On Hugging Face").font(.title3.weight(.semibold))
                    if model.isSearchingRemote {
                        ProgressView().controlSize(.small)
                    }
                }
                Text("Anything else with GGUF weights. The architecture is read from the file "
                     + "itself, so you still get a memory plan before downloading.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if let error = model.remoteSearchError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                } else if model.remoteResults.isEmpty,
                          !model.isSearchingRemote,
                          let searched = model.completedRemoteQuery {
                    Text("Nothing on Hugging Face matches “\(searched)”.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                ForEach(model.remoteResults) { result in
                    Button { inspectingRemote = result } label: {
                        Card {
                            HStack(spacing: 12) {
                                Image(systemName: "shippingbox")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(result.name).font(.callout.weight(.medium))
                                    Text(result.author)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Label(compact(result.downloads), systemImage: "arrow.down.circle")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func compact(_ value: Int) -> String {
        value >= 1_000_000 ? String(format: "%.1fM", Double(value) / 1e6)
            : value >= 1000 ? String(format: "%.0fk", Double(value) / 1000)
            : String(value)
    }

    private struct Row {
        var entry: ModelEntry
        var recommendation: AutoConfigurator.Recommendation?
    }

    private var filteredEntries: [Row] {
        let configurator = model.autoConfigurator()
        return ModelCatalog.all
            .filter { entry in
                if let category, entry.category != category { return false }
                guard !search.isEmpty else { return true }
                let haystack = "\(entry.name) \(entry.author) \(entry.summary)".lowercased()
                return haystack.contains(search.lowercased())
            }
            .map { entry in
                Row(
                    entry: entry,
                    recommendation: configurator.best(
                        for: entry, otherAppsInUse: model.memoryUsedByOtherApps
                    )
                )
            }
            .filter { !showsOnlyRunnable || $0.recommendation != nil }
            .sorted { lhs, rhs in
                (lhs.recommendation?.score ?? -1) > (rhs.recommendation?.score ?? -1)
            }
    }

    /// Registers a `.gguf` already sitting somewhere on disk, without moving or copying it.
    ///
    /// The way in for a model this app never wrote itself — most usefully, one downloaded to the
    /// managed library normally and then moved by hand in Finder to external media the app can't
    /// write to directly. macOS gates non-sandboxed write access to removable and network volumes
    /// behind a Developer ID signature this build doesn't have, but reading a file the user just
    /// explicitly chose in an open panel isn't subject to that same restriction.
    private func importExistingModel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.init(filenameExtension: "gguf")].compactMap { $0 }
        panel.prompt = "Import"
        panel.message = "Choose a .gguf file to register — its head shard, if it's split into "
            + "several parts."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.importModel(from: url) }
    }
}

// MARK: - Rows

private struct InstalledModelRow: View {
    @Environment(AppModel.self) private var model
    var installed: InstalledModel

    @State private var isShowingAdvanced = false

    private var isLoaded: Bool { model.loadedModel?.id == installed.id }

    var body: some View {
        Card {
            HStack(spacing: 14) {
                Image(systemName: isLoaded ? "cpu.fill" : "internaldrive")
                    .font(.title2)
                    .foregroundStyle(isLoaded ? .blue : .secondary)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text(installed.name).font(.headline)
                    HStack(spacing: 6) {
                        Badge(text: installed.quantization.rawValue)
                        Badge(text: installed.sizeOnDisk.formatted, systemImage: "internaldrive")
                        if installed.shape?.isMoE == true {
                            Badge(text: "MoE", systemImage: "square.grid.3x3", tint: .indigo)
                        }
                        if installed.supportsVision {
                            Badge(text: "Vision", systemImage: "eye", tint: .purple)
                        }
                    }
                }

                Spacer()

                if isLoaded {
                    Button("Unload") { Task { await model.unload() } }
                        .buttonStyle(.bordered)
                } else {
                    Button("Load") {
                        model.load(installed)
                        model.selectedTab = .chat
                    }
                    .buttonStyle(.borderedProminent)
                }

                Menu {
                    Button("Load with advanced settings…") { isShowingAdvanced = true }
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([installed.primaryFile])
                    }
                    Divider()
                    Button("Delete", role: .destructive) { model.uninstall(installed) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .sheet(isPresented: $isShowingAdvanced) {
                    AdvancedView(
                        installed: installed,
                        configuration: model.defaultConfiguration(for: installed),
                        extraArguments: model.extraArguments.joined(separator: " ")
                    )
                    .environment(model)
                }
            }
        }
    }
}

private struct CatalogRow: View {
    @Environment(AppModel.self) private var model
    var entry: ModelEntry
    var recommendation: AutoConfigurator.Recommendation?
    var onInspect: () -> Void

    private var downloadKey: String? {
        guard let quantization = recommendation?.quantization else { return nil }
        return "\(entry.id)@\(quantization.rawValue)"
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: entry.category.systemImage)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 26)

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Text(entry.name).font(.headline)
                            Text(entry.parameterLabel)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                            if let active = entry.activeParameterLabel {
                                Badge(text: active, systemImage: "bolt.fill", tint: .indigo)
                            }
                            RatingStars(rating: entry.rating)
                        }

                        Text(entry.summary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 6) {
                            ForEach(entry.capabilities.labels, id: \.0) { label, icon in
                                Badge(text: label, systemImage: icon)
                            }
                            Badge(text: entry.license, systemImage: "doc.text")
                        }
                    }

                    Spacer(minLength: 0)

                    actionColumn
                }

                if let download = downloadKey.flatMap({ model.downloads[$0] }) {
                    DownloadProgressView(download: download) {
                        model.cancelInstall(download.id)
                    }
                } else if let recommendation {
                    HStack(spacing: 10) {
                        Badge(
                            text: recommendation.plan.verdict.label,
                            tint: Palette.verdict(recommendation.plan.verdict)
                        )
                        Text(recommendation.rationale)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                } else {
                    Label(
                        "Too large for \(model.profile.totalMemory.formatted) of memory.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }
            .contentShape(.rect)
            .onTapGesture(perform: onInspect)
        }
    }

    @ViewBuilder
    private var actionColumn: some View {
        if let recommendation {
            let installed = model.isInstalled(entry, quantization: recommendation.quantization)
            VStack(spacing: 6) {
                if installed {
                    Button("Load") {
                        if let installedModel = model.installedModels.first(where: {
                            $0.catalogID == entry.id
                                && $0.quantization == recommendation.quantization
                        }) {
                            model.load(installedModel, configuration: recommendation.configuration)
                            model.selectedTab = .chat
                        }
                    }
                    .buttonStyle(.borderedProminent)
                } else if model.downloads[recommendation.id] == nil {
                    Button("Install") {
                        model.install(entry, quantization: recommendation.quantization)
                    }
                    .buttonStyle(.bordered)
                }
                Text(recommendation.quantization.rawValue)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 84)
        } else {
            Button("Details", action: onInspect)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }
}

struct DownloadProgressView: View {
    var download: AppModel.DownloadTask
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = download.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if let progress = download.progress {
                ProgressView(value: progress.fraction)
                    .progressViewStyle(.linear)
                HStack {
                    Text("\(progress.bytesReceived.formatted) of \(progress.bytesExpected.formatted)")
                    if progress.fileCount > 1 {
                        Text("· part \(progress.fileIndex + 1)/\(progress.fileCount)")
                    }
                    Spacer()
                    if progress.bytesPerSecond > 0 {
                        Text("\(Bytes(Int64(progress.bytesPerSecond)).formatted)/s")
                    }
                    if let remaining = progress.estimatedTimeRemaining, remaining > 1 {
                        Text("· \(remaining.durationLabel) left")
                    }
                    Button("Cancel", action: onCancel)
                        .buttonStyle(.link)
                        .controlSize(.small)
                }
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Resolving files on Hugging Face…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel", action: onCancel)
                        .buttonStyle(.link)
                        .controlSize(.small)
                }
            }
        }
    }
}

/// One image model in the browser, with its phased peak and install state.
private struct DiffusionCatalogRow: View {
    @Environment(AppModel.self) private var model
    var entry: DiffusionEntry

    var body: some View {
        let plan = model.diffusionPlan(
            for: entry, configuration: model.recommendedImageConfiguration(for: entry)
        )
        let isInstalled = model.isImageModelInstalled(entry)
        let download = model.imageDownloads[entry.id]

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "photo.on.rectangle.angled")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(entry.name).font(.headline)
                        if entry.isGated {
                            Image(systemName: "lock")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .help("Gated — accept the licence on Hugging Face first")
                        }
                        if isInstalled {
                            Badge(
                                text: "Installed", systemImage: "checkmark.circle.fill",
                                tint: .green
                            )
                        }
                    }
                    Text(entry.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Label(entry.parameterLabel, systemImage: "number")
                        Label("\(entry.shape.defaultSteps) steps", systemImage: "arrow.trianglehead.2.clockwise")
                        // The peak, not the download size: it is what decides whether this is
                        // worth the disk in the first place.
                        Label(
                            "peaks at \(plan.peak.formatted)",
                            systemImage: "memorychip"
                        )
                        .foregroundStyle(Palette.verdict(plan.verdict))
                        if isInstalled {
                            Label(model.installedImageModelSize(entry).formatted, systemImage: "internaldrive")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                if download == nil {
                    if isInstalled {
                        Button("Remove") { model.uninstallImageModel(entry) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    } else {
                        Button("Install") { model.installImageModel(entry) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                }
            }

            if let download {
                ImageDownloadProgressView(download: download) {
                    model.cancelImageInstall(entry.id)
                }
            }
        }
        .padding(12)
        .background(.background.secondary, in: .rect(cornerRadius: 10))
    }
}

/// One 3D backend in the browser: state, measured peak, and the download when weights are
/// the missing piece. Styled to match `DiffusionCatalogRow` — the sections read as siblings.
private struct MeshCatalogRow: View {
    @Environment(AppModel.self) private var model
    var entry: MeshEntry

    var body: some View {
        let installation = model.meshInstallation(for: entry)
        let download = model.meshDownloads[entry.id]

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "cube.transparent")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(entry.name).font(.headline)
                        if installation.isInstalled {
                            Badge(
                                text: "Ready", systemImage: "checkmark.circle.fill",
                                tint: .green
                            )
                        } else if entry.backend == .unsupported {
                            Badge(text: "Not available yet", tint: .secondary)
                        }
                    }
                    Text(entry.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Label(entry.typicalDuration, systemImage: "clock")
                        if entry.peakMemory > .zero {
                            Label(
                                "peaks at \(entry.peakMemory.formatted)",
                                systemImage: "memorychip"
                            )
                        }
                        Label(entry.outputs, systemImage: "shippingbox")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    if !installation.isInstalled, entry.backend != .unsupported {
                        Text(installation.detail)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 8)

                if download == nil, installation.missing == .weights,
                   model.meshWeightsDownload(for: entry) != nil {
                    Button("Download") { model.installMeshWeights(entry) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                } else if installation.isInstalled {
                    Button("Open 3D tab") { model.selectedTab = .threeD }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }

            if let download {
                MeshDownloadProgressView(download: download) {
                    model.cancelMeshInstall(entry.id)
                }
            }
        }
        .padding(12)
        .background(.background.secondary, in: .rect(cornerRadius: 10))
    }
}

/// Progress for a 3D-weights install — the same readout as every other download here.
private struct MeshDownloadProgressView: View {
    var download: AppModel.MeshDownloadTask
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = download.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let progress = download.progress, progress.bytesExpected > .zero {
                ProgressView(value: progress.fraction)
                    .progressViewStyle(.linear)
                HStack {
                    Text("\(progress.bytesReceived.formatted) of \(progress.bytesExpected.formatted)")
                    Spacer()
                    if progress.bytesPerSecond > 0 {
                        Text("\(Bytes(Int64(progress.bytesPerSecond)).formatted)/s")
                    }
                    Button("Cancel", action: onCancel)
                        .buttonStyle(.link)
                        .controlSize(.small)
                }
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Starting the download…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel", action: onCancel)
                        .buttonStyle(.link)
                        .controlSize(.small)
                }
            }
        }
    }
}

/// Progress for an image-model install.
///
/// Separate from `DownloadProgressView` only because the underlying task type differs; the
/// readout is deliberately identical, since to the reader it is the same activity.
private struct ImageDownloadProgressView: View {
    var download: AppModel.ImageDownloadTask
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = download.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let progress = download.progress, progress.bytesExpected > .zero {
                ProgressView(value: progress.fraction)
                    .progressViewStyle(.linear)
                HStack {
                    Text("\(progress.bytesReceived.formatted) of \(progress.bytesExpected.formatted)")
                    Spacer()
                    if progress.bytesPerSecond > 0 {
                        Text("\(Bytes(Int64(progress.bytesPerSecond)).formatted)/s")
                    }
                    if let remaining = progress.estimatedTimeRemaining, remaining > 1 {
                        Text("· \(remaining.durationLabel) left")
                    }
                    Button("Cancel", action: onCancel)
                        .buttonStyle(.link)
                        .controlSize(.small)
                }
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Working out what to fetch…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel", action: onCancel)
                        .buttonStyle(.link)
                        .controlSize(.small)
                }
            }
        }
    }
}
