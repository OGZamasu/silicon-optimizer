import SiliconElevenLabs
import SwiftUI

/// The shared voice library: voices other people published, to search, listen to and add to
/// your own.
struct VoiceLibrarySection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VoiceLibraryScreen(model: VoicesStudioModels.model(VoiceLibrarySectionModel.self, for: app) {
            VoiceLibrarySectionModel(environment: $0)
        })
    }
}

struct VoiceLibraryScreen: View {
    @Bindable var model: VoiceLibrarySectionModel

    var body: some View {
        ElevenLabsSectionPage(.voiceLibrary) {
            Button {
                Task { await model.refresh() }
            } label: {
                Label("Search", systemImage: "magnifyingglass")
            }
            .disabled(model.isListing)
        } content: {
            VoiceLibraryFilters(model: model)
            Card(title: model.totalCount.map { "\($0.formatted()) voices" } ?? "Voices", systemImage: "books.vertical") {
                VoicesStudioListState(
                    loading: model.isListing, problem: model.listProblem, isEmpty: model.rows.isEmpty,
                    emptyText: model.loadedOnce ? "No voices match these filters." : "Search the library above."
                )
                ForEach(model.rows) { voice in
                    VoiceLibraryRow(model: model, voice: voice)
                    if voice.id != model.rows.last?.id { Divider() }
                }
                VoicesStudioMoreButton(hasMore: model.hasMore, loading: model.isListing) {
                    Task { await model.loadMore() }
                }
            }
            VoicesStudioActivity(actions: model.actions, fallback: model.listRunner)
        }
        .task { await model.refreshIfNeeded() }
    }
}

struct VoiceLibraryFilters: View {
    @Bindable var model: VoiceLibrarySectionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search the library", text: $model.search)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await model.refresh() } }
            HStack(spacing: 8) {
                Picker("Sort", selection: $model.sort) {
                    Text("Default order").tag("")
                    Text("Newest").tag("created_date")
                    Text("Most used this year").tag("usage_character_count_1y")
                    Text("Trending").tag("trending")
                    Text("Most added").tag("cloned_by_count")
                }
                .labelsHidden()
                .fixedSize()
                Toggle("Featured only", isOn: $model.featuredOnly)
                Spacer(minLength: 0)
            }
            // A grid, not one row: five pickers side by side do not fit a narrow window.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8, alignment: .leading)],
                      alignment: .leading, spacing: 6) {
                facet("Gender", field: "gender", selection: $model.gender)
                facet("Age", field: "age", selection: $model.age)
                facet("Accent", field: "accent", selection: $model.accent)
                facet("Language", field: "language", selection: $model.language)
                facet("Use", field: "use_case", selection: $model.useCase)
            }
        }
        .onChange(of: model.sort) { Task { await model.refresh() } }
        .onChange(of: model.featuredOnly) { Task { await model.refresh() } }
        .onChange(of: model.gender) { Task { await model.refresh() } }
        .onChange(of: model.age) { Task { await model.refresh() } }
        .onChange(of: model.accent) { Task { await model.refresh() } }
        .onChange(of: model.language) { Task { await model.refresh() } }
        .onChange(of: model.useCase) { Task { await model.refresh() } }
    }

    private func facet(_ title: String, field: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            Text("Any \(title.lowercased())").tag("")
            ForEach(model.options(field, current: selection.wrappedValue), id: \.self) {
                Text($0.replacingOccurrences(of: "_", with: " ").capitalized).tag($0)
            }
        }
        .labelsHidden()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct VoiceLibraryRow: View {
    @Bindable var model: VoiceLibrarySectionModel
    let voice: VoiceLibraryVoice

    /// One line that wraps: how often it was added and used, its notice period and rate — the
    /// rate is what changes what the voice costs to use.
    private var stats: String {
        var parts: [String] = []
        if let count = voice.clonedByCount { parts.append("Added \(count.formatted())×") }
        if let usage = voice.usageLastYear { parts.append("\(usage.formatted()) characters this year") }
        if let days = voice.noticePeriodDays, days > 0 { parts.append("\(days)-day notice") }
        if let rate = voice.rate, rate != 1 { parts.append("Rate ×\(rate.formatted(.number.precision(.fractionLength(0...2))))") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VoicesPreviewButton(entry: voice.directoryEntry, directory: model.directory)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(voice.name).font(.callout.weight(.medium))
                    if voice.featured { Badge(text: "Featured", systemImage: "star.fill", tint: .yellow) }
                    if let category = voice.category { Badge(text: VoicesStudioFormat.words(category)) }
                }
                if !voice.summary.isEmpty {
                    Text(voice.summary).font(.caption).foregroundStyle(.secondary)
                }
                if let description = voice.description, !description.isEmpty {
                    Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Text(stats)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            if model.isAdded(voice) {
                Label("In my voices", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            } else {
                VStack(alignment: .trailing, spacing: 4) {
                    TextField("Name", text: Binding(
                        get: { model.names[voice.id] ?? voice.name },
                        set: { model.names[voice.id] = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                    Button("Add to my voices") { Task { await model.add(voice) } }
                        .controlSize(.small)
                        .disabled(model.actions.isRunning("add_sharing_voice"))
                }
            }
        }
        .padding(.vertical, 3)
    }
}
