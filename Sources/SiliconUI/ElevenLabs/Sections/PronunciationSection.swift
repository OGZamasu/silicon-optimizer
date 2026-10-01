import SiliconElevenLabs
import SwiftUI

/// Pronunciation dictionaries: rules for how names and terms are said, used by speech, Studio
/// and Audio Native.
struct PronunciationSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        PronunciationScreen(model: VoicesStudioModels.model(PronunciationSectionModel.self, for: app) {
            PronunciationSectionModel(environment: $0)
        })
    }
}

struct PronunciationScreen: View {
    @Bindable var model: PronunciationSectionModel
    @State private var creating = false

    var body: some View {
        ElevenLabsSectionPage(.pronunciation) {
            Button {
                Task { await model.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(model.isListing)
        } content: {
            CollapsibleCard(title: "New dictionary", systemImage: "plus.circle", isExpanded: $creating) {
                TextField("Name", text: $model.newName).textFieldStyle(.roundedBorder)
                TextField("Description (optional)", text: $model.newDescription).textFieldStyle(.roundedBorder)
                VoicesStudioChoicePicker(title: "Workspace access", selection: $model.newAccess,
                                         choices: model.accessLevels, defaultLabel: "No access")
                    .help(VoicesStudioSchema.description("add_from_rules", "workspace_access"))
                Picker("From", selection: $model.newFromFile) {
                    Text("Rules written here").tag(false)
                    Text("A PLS lexicon file").tag(true)
                }
                .pickerStyle(.segmented)
                if model.newFromFile {
                    VoicesStudioFilePicker(title: "Lexicon (.pls)", files: $model.newFile,
                                           help: VoicesStudioSchema.description("add_from_file", "file"))
                } else {
                    PronunciationRuleEditor(rules: $model.rules)
                }
                if !model.problems.isEmpty { ElevenLabsProblemList(problems: model.problems) }
                HStack {
                    Spacer()
                    Button("Create dictionary") { Task { await model.create() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.actions.isRunning("add_from_rules") || model.actions.isRunning("add_from_file"))
                }
            }
            PronunciationListCard(model: model)
            if let dictionary = model.selected {
                PronunciationDictionaryCard(model: model, dictionary: dictionary)
            }
            VoicesStudioActivity(actions: model.actions,
                                 fallback: model.actions.runner("get_pronunciation_dictionaries_metadata"))
        }
        .task { await model.refreshIfNeeded() }
    }
}

struct PronunciationListCard: View {
    @Bindable var model: PronunciationSectionModel

    var body: some View {
        Card(title: "Dictionaries", systemImage: "character.book.closed") {
            HStack(spacing: 8) {
                Picker("Sort", selection: $model.sort) {
                    Text("Default order").tag("")
                    ForEach(model.sorts, id: \.self) { Text($0 == "name" ? "Name" : "Created").tag($0) }
                }
                Picker("Direction", selection: $model.sortDirection) {
                    Text("Default direction").tag("")
                    Text("Newest or Z first").tag("DESCENDING")
                    Text("Oldest or A first").tag("ASCENDING")
                }
            }
            .labelsHidden()
            .fixedSize()
            Toggle("Include archived dictionaries", isOn: $model.includeArchived)
            .onChange(of: model.sort) { Task { await model.refresh() } }
            .onChange(of: model.sortDirection) { Task { await model.refresh() } }
            .onChange(of: model.includeArchived) { Task { await model.refresh() } }
            VoicesStudioListState(loading: model.isListing, problem: model.listProblem, isEmpty: model.dictionaries.isEmpty,
                                  emptyText: "No pronunciation dictionaries yet.")
            ForEach(model.dictionaries) { dictionary in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(dictionary.name).font(.callout.weight(.medium)).lineLimit(1)
                        Text("\(dictionary.ruleCount) rules"
                             + (VoicesStudioFormat.date(unixSeconds: dictionary.createdAt).map { " · \($0)" } ?? ""))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if dictionary.isArchived { Badge(text: "Archived") }
                    if let permission = dictionary.permission { Badge(text: VoicesStudioFormat.words(permission)) }
                }
                .padding(.vertical, 4).padding(.horizontal, 6)
                .background(model.selected?.id == dictionary.id ? Color.accentColor.opacity(0.12) : .clear,
                            in: .rect(cornerRadius: 6))
                .contentShape(Rectangle())
                .onTapGesture { Task { await model.select(dictionary.id) } }
            }
            VoicesStudioMoreButton(hasMore: model.hasMore, loading: model.isListing) { Task { await model.loadMore() } }
        }
    }
}

struct PronunciationDictionaryCard: View {
    @Bindable var model: PronunciationSectionModel
    let dictionary: PronunciationDictionary

    var body: some View {
        Card(title: dictionary.name, systemImage: "text.book.closed") {
            HStack(spacing: 8) {
                TextField("Name", text: $model.rename).textFieldStyle(.roundedBorder)
                Button("Rename") { Task { await model.saveName() } }
                    .disabled(model.rename.trimmingCharacters(in: .whitespaces).isEmpty || model.rename == dictionary.name)
                Button(dictionary.isArchived ? "Restore" : "Archive") {
                    Task { await model.setArchived(!dictionary.isArchived) }
                }
            }
            if let description = dictionary.description, !description.isEmpty {
                Text(description).font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Text("Version \(dictionary.latestVersionID)").font(.caption.monospaced()).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer()
                Button("Download PLS") { Task { await model.downloadPLS() } }.controlSize(.small)
            }
            if let file = model.download {
                ElevenLabsFileResult(url: file.url, contentType: file.contentType, bytes: file.bytes)
            }
            Divider()
            HStack {
                Text("\(dictionary.rules.count) rules").font(.headline)
                Spacer()
                if !model.marked.isEmpty {
                    Button("Remove \(model.marked.count) rules") { Task { await model.removeMarked() } }
                        .controlSize(.small)
                }
                Button("Edit all in the editor") { model.editCurrentRules() }
                    .controlSize(.small)
                    .disabled(dictionary.rules.isEmpty || !model.rulesAreIn)
                    .help(model.rulesAreIn ? "Copy every rule into the editor, to change and replace them"
                          : "Waiting for this dictionary's rules as they are now")
            }
            ForEach(dictionary.rules) { rule in
                Toggle(isOn: Binding(
                    get: { model.marked.contains(rule.stringToReplace) },
                    set: { on in
                        if on { model.marked.insert(rule.stringToReplace) } else { model.marked.remove(rule.stringToReplace) }
                    }
                )) {
                    HStack(spacing: 6) {
                        Text(rule.summary).font(.callout)
                        if !rule.caseSensitive { Badge(text: "any case") }
                        if !rule.wordBoundaries { Badge(text: "inside words") }
                    }
                }
            }
            Divider()
            Text("Rules to add").font(.headline)
            PronunciationRuleEditor(rules: $model.rules)
            if !model.problems.isEmpty { ElevenLabsProblemList(problems: model.problems) }
            HStack {
                Spacer()
                Button("Replace all rules with these") { Task { await model.replaceRules() } }
                    .help("A new version holds only the rules in the editor")
                Button("Add rules") { Task { await model.addRules() } }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

/// Rows of rules: what to replace, and with an alias or a phoneme in an alphabet.
struct PronunciationRuleEditor: View {
    @Binding var rules: [PronunciationRule]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach($rules) { $rule in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Picker("Kind", selection: $rule.kind) {
                            Text("Alias").tag(PronunciationRule.Kind.alias)
                            Text("Phoneme").tag(PronunciationRule.Kind.phoneme)
                        }
                        .labelsHidden()
                        .fixedSize()
                        TextField("Text", text: $rule.stringToReplace)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        if rule.kind == .alias {
                            TextField("Say it as", text: $rule.alias)
                        } else {
                            TextField("Phonemes", text: $rule.phoneme)
                            TextField("Alphabet", text: $rule.alphabet).frame(width: 70)
                        }
                        Button {
                            rules.removeAll { $0.id == rule.id }
                            if rules.isEmpty { rules = [PronunciationRule()] }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove this rule")
                    }
                    .textFieldStyle(.roundedBorder)
                    HStack(spacing: 12) {
                        Toggle("Match case", isOn: $rule.caseSensitive)
                        Toggle("Whole words only", isOn: $rule.wordBoundaries)
                    }
                    .font(.caption)
                    .padding(.leading, 4)
                }
            }
            Button {
                rules.append(PronunciationRule())
            } label: {
                Label("Another rule", systemImage: "plus")
            }
            .controlSize(.small)
        }
    }
}
