import SiliconCatalog
import SiliconCore
import SiliconPlanner
import SwiftUI

struct ModelBrowserView: View {
    @Environment(AppModel.self) private var model

    @State private var search = ""
    @State private var category: ModelCategory?
    @State private var showsOnlyRunnable = true
    @State private var inspecting: ModelEntry?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if search.isEmpty && category == nil {
                    recommendationBanner
                    installedSection
                }
                catalogSection
            }
            .padding(20)
        }
        .background(.background)
        .navigationTitle("Models")
        .searchable(text: $search, placement: .toolbar, prompt: "Search models")
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
        }
        .sheet(item: $inspecting) { entry in
            ModelDetailSheet(entry: entry)
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
