import AppKit
import SiliconElevenLabs
import SwiftUI

/// Flows: speech, images and video from any model the API offers — each model's own settings,
/// the generations and their results — and published templates run with their inputs.
struct FlowsSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        FlowsScreen(model: VoicesStudioModels.model(FlowsSectionModel.self, for: app) {
            FlowsSectionModel(environment: $0)
        })
    }
}

struct FlowsScreen: View {
    @Bindable var model: FlowsSectionModel

    var body: some View {
        ElevenLabsSectionPage(.flows) {
            Button {
                Task {
                    if let kind = model.mode.kind { await model.refresh(kind) } else { await model.refreshTemplates() }
                }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        } content: {
            Picker("Show", selection: $model.mode) {
                ForEach(FlowsSectionModel.Mode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if let kind = model.mode.kind {
                FlowsCreateCard(model: model, kind: kind)
                FlowsGenerationsCard(model: model, kind: kind)
            } else {
                FlowsTemplatesCard(model: model)
                if let template = model.template { FlowsTemplateCard(model: model, template: template) }
            }
            if let notice = model.runNotice {
                HStack(spacing: 8) {
                    Label(notice.text, systemImage: "checkmark.circle")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Open “\(notice.templateName)”") {
                        model.mode = .templates
                        Task { await model.open(notice.templateID) }
                    }
                    .controlSize(.small)
                    Button("Dismiss") { model.dismissRunNotice() }.controlSize(.small)
                }
                .padding(10)
                .background(.green.opacity(0.08), in: .rect(cornerRadius: 8))
            }
            VoicesStudioActivity(
                actions: model.actions,
                fallback: model.actions.runner(model.mode.kind?.listID ?? "list_public_templates")
            )
        }
        .task(id: model.mode) {
            if let kind = model.mode.kind {
                if !model.loaded.contains(kind) { await model.refresh(kind) }
            } else if !model.loadedTemplates {
                await model.refreshTemplates()
            }
        }
    }
}

struct FlowsCreateCard: View {
    @Bindable var model: FlowsSectionModel
    let kind: FlowsKind

    var body: some View {
        Card(title: "New \(kind == .speech ? "speech" : kind == .image ? "image" : "video")", systemImage: "sparkles") {
            let variants = model.variants(kind)
            Picker("Model", selection: Binding(get: { model.model(kind) }, set: { model.choose($0, for: kind) })) {
                ForEach(variants) { Text($0.name).tag($0.modelID) }
            }
            Text(model.model(kind)).font(.caption.monospaced()).foregroundStyle(.secondary)
            if kind == .speech {
                ElevenLabsVoicePicker(selection: $model.speechVoiceID, title: "Voice", directory: model.directory)
            }
            if let form = model.form(kind) {
                ElevenLabsOperationForm(form: form, showsHeadings: false)
                    .id("\(kind.rawValue)/\(model.model(kind))")
            }
            if let runner = model.actions.runner(kind.createID) {
                VoicesStudioRunButton(actions: model.actions, runner: runner, title: "Generate", estimatedCharacters: model.estimatedCharacters(kind)) {
                    Task { await model.create(kind) }
                }
            }
        }
    }
}

struct FlowsGenerationsCard: View {
    @Bindable var model: FlowsSectionModel
    let kind: FlowsKind

    var body: some View {
        Card(title: "Generations", systemImage: "square.stack") {
            Picker("Status", selection: Binding(
                get: { model.statusFilter[kind] ?? "" },
                set: { model.statusFilter[kind] = $0; Task { await model.refresh(kind) } }
            )) {
                Text("Any status").tag("")
                ForEach(model.statuses(kind), id: \.self) { Text(VoicesStudioFormat.words($0)).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            let rows = model.generations[kind] ?? []
            VoicesStudioListState(loading: model.actions.isRunning(kind.listID), problem: model.actions.problem(kind.listID),
                                  isEmpty: rows.isEmpty, emptyText: "Nothing generated yet.")
            ForEach(rows) { generation in
                HStack(spacing: 8) {
                    Text(generation.id).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                    VoicesStudioStatusBadge(status: generation.status)
                    if let failure = generation.failure {
                        Text(failure).font(.caption).foregroundStyle(.red).lineLimit(2)
                    }
                    Spacer()
                    if let url = generation.contentURL {
                        Text(generation.contentType ?? "").font(.caption).foregroundStyle(.secondary)
                        Button("Open") { NSWorkspace.shared.open(url) }
                            .controlSize(.small)
                            .help("Opens the result's download link in your browser")
                    }
                    if generation.status == "pending" || generation.status == "generating" {
                        Button("Check") { Task { await model.check(generation, kind: kind) } }.controlSize(.small)
                    }
                }
            }
            VoicesStudioMoreButton(hasMore: model.cursors[kind] != nil, loading: model.actions.isRunning(kind.listID)) {
                Task { await model.loadMore(kind) }
            }
        }
    }
}

struct FlowsTemplatesCard: View {
    @Bindable var model: FlowsSectionModel

    var body: some View {
        Card(title: "Templates", systemImage: "rectangle.3.group") {
            TextField("Search templates", text: $model.templateSearch)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await model.refreshTemplates() } }
            VoicesStudioListState(loading: model.actions.isRunning("list_public_templates"),
                                  problem: model.actions.problem("list_public_templates"),
                                  isEmpty: model.templates.isEmpty, emptyText: "No published templates.")
            ForEach(model.templates) { template in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(template.name).font(.callout.weight(.medium))
                        if let description = template.description, !description.isEmpty {
                            Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    Spacer()
                    Text("\(template.versions.count) versions").font(.caption).foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4).padding(.horizontal, 6)
                .background(model.template?.id == template.id ? Color.accentColor.opacity(0.12) : .clear,
                            in: .rect(cornerRadius: 6))
                .contentShape(Rectangle())
                .onTapGesture { Task { await model.open(template.id) } }
            }
            VoicesStudioMoreButton(hasMore: model.templatesCursor != nil,
                                   loading: model.actions.isRunning("list_public_templates")) {
                Task { await model.moreTemplates() }
            }
        }
    }
}

struct FlowsTemplateCard: View {
    @Bindable var model: FlowsSectionModel
    let template: FlowsTemplate

    var body: some View {
        Card(title: template.name, systemImage: "play.rectangle.on.rectangle") {
            Picker("Version", selection: $model.versionID) {
                Text("Latest published").tag("latest")
                ForEach(template.versions) { version in
                    Text(VoicesStudioFormat.date(unixSeconds: version.publishedAt) ?? version.id).tag(version.id)
                }
            }
            if let version = model.chosenVersion {
                if version.inputs.isEmpty { Text("This template takes no inputs.").font(.callout).foregroundStyle(.secondary) }
                ForEach(version.inputs) { port in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(port.id).font(.caption.monospaced().weight(.medium))
                            Text(port.isText ? "text" : "JSON").font(.caption2).foregroundStyle(.tertiary)
                        }
                        if port.isText {
                            ElevenLabsTextArea(text: binding(port.id), minHeight: 44)
                        } else {
                            ElevenLabsJSONEditor(text: binding(port.id), minHeight: 60)
                        }
                    }
                }
                if !version.outputs.isEmpty {
                    Text("Outputs: " + version.outputs.map(\.id).joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle("Send the result to the workspace's flows webhooks", isOn: $model.notifyWebhooks)
                .help(VoicesStudioSchema.description("create_public_template_run", "webhook"))
            if !model.inputProblems.isEmpty { ElevenLabsProblemList(problems: model.inputProblems) }
            if let runner = model.actions.runner("create_public_template_run") {
                VoicesStudioRunButton(actions: model.actions, runner: runner, title: "Run template") { Task { await model.run() } }
            }
            Divider()
            HStack {
                Text("Runs").font(.headline)
                Spacer()
                Button("Refresh runs") { Task { await model.loadRuns() } }.controlSize(.small)
            }
            ForEach(model.runs) { run in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(run.id).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                        VoicesStudioStatusBadge(status: run.status)
                        Spacer()
                        if run.status == "pending" || run.status == "generating" {
                            Button("Check") { Task { await model.check(run) } }.controlSize(.small)
                        }
                    }
                    if run.outputs.objectValue?.isEmpty == false {
                        ElevenLabsJSONTree(run.outputs, label: "outputs")
                    }
                }
            }
        }
    }

    private func binding(_ port: String) -> Binding<String> {
        Binding(get: { model.inputs[port] ?? "" }, set: { model.inputs[port] = $0 })
    }
}
