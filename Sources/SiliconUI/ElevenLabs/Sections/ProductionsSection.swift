import AppKit
import SiliconElevenLabs
import SwiftUI

/// Productions: dubbing, subtitles and transcription done by ElevenLabs' producers — an order
/// holds media and quoted items, is submitted (which charges the workspace), and delivers
/// files.
struct ProductionsSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ProductionsScreen(model: VoicesStudioModels.model(ProductionsSectionModel.self, for: app) {
            ProductionsSectionModel(environment: $0)
        })
    }
}

struct ProductionsScreen: View {
    @Bindable var model: ProductionsSectionModel

    var body: some View {
        ElevenLabsSectionPage(.productions) {
            Button {
                Task { await model.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(model.isListing)
        } content: {
            ProductionsOrdersCard(model: model)
            if let order = model.selected {
                ProductionsOrderCard(model: model, order: order)
                if order.isOpen {
                    ProductionsMediaCard(model: model)
                    ProductionsItemCard(model: model)
                }
            } else if let orderID = model.wantedOrder {
                ProductionsOrderPendingCard(model: model, orderID: orderID)
            }
            VoicesStudioActivity(actions: model.actions, fallback: model.actions.runner("public_list_orders"))
        }
        .task { await model.refreshIfNeeded() }
    }
}

struct ProductionsOrdersCard: View {
    @Bindable var model: ProductionsSectionModel

    var body: some View {
        Card(title: "Orders", systemImage: "film.stack") {
            HStack(spacing: 8) {
                TextField("New order name (optional)", text: $model.newOrderName).textFieldStyle(.roundedBorder)
                Toggle("Sandbox", isOn: $model.newSandbox)
                    .help(VoicesStudioSchema.description("public_create_order", "sandbox"))
                Button("New order") { Task { await model.createOrder() } }
                    .disabled(model.actions.isRunning("public_create_order"))
            }
            Menu {
                ForEach(model.statuses, id: \.self) { status in
                    Toggle(VoicesStudioFormat.words(status), isOn: Binding(
                        get: { model.statusFilter.contains(status) },
                        set: { on in
                            if on { model.statusFilter.insert(status) } else { model.statusFilter.remove(status) }
                            Task { await model.refresh() }
                        }
                    ))
                }
            } label: {
                Text(model.statusFilter.isEmpty ? "Any status"
                     : model.statusFilter.sorted().map(VoicesStudioFormat.words).joined(separator: ", "))
            }
            .fixedSize()
            VoicesStudioListState(loading: model.isListing, problem: model.listProblem, isEmpty: model.orders.isEmpty,
                                  emptyText: "No orders yet.")
            ForEach(model.orders) { order in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(order.name).font(.callout.weight(.medium)).lineLimit(1)
                        Text([order.total.map { $0.formatted(.currency(code: "USD")) },
                              VoicesStudioFormat.date(iso: order.submittedAt ?? order.createdAt)]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if order.sandbox { Badge(text: "Sandbox") }
                    VoicesStudioStatusBadge(status: order.state)
                }
                .padding(.vertical, 4).padding(.horizontal, 6)
                .background(model.wantedOrder == order.id ? Color.accentColor.opacity(0.12) : .clear,
                            in: .rect(cornerRadius: 6))
                .contentShape(Rectangle())
                .onTapGesture { Task { await model.select(order.id) } }
            }
            VoicesStudioMoreButton(hasMore: model.hasMore, loading: model.isListing) {
                Task { await model.loadMore() }
            }
        }
    }
}

/// The order chosen while its details are on their way, or why they could not be read —
/// never the previously open order in its place.
struct ProductionsOrderPendingCard: View {
    let model: ProductionsSectionModel
    let orderID: String

    var body: some View {
        Card(title: model.orders.first { $0.id == orderID }?.name ?? orderID, systemImage: "doc.text") {
            if let problem = model.orderProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try again") { Task { await model.select(orderID) } }.controlSize(.small)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading the order…").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct ProductionsOrderCard: View {
    @Bindable var model: ProductionsSectionModel
    let order: ProductionsOrder

    var body: some View {
        Card(title: order.name, systemImage: "doc.text") {
            HStack {
                VoicesStudioStatusBadge(status: order.state)
                if order.sandbox { Badge(text: "Sandbox") }
                Text(order.id).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                Spacer()
                Button("Check status") { Task { await model.select(order.id) } }.controlSize(.small)
            }
            if order.isOpen {
                HStack(spacing: 8) {
                    Text("Name").font(.callout)
                    TextField("Name", text: $model.rename).textFieldStyle(.roundedBorder)
                    Button("Rename") { Task { await model.saveName() } }
                        .disabled(model.rename.trimmingCharacters(in: .whitespaces).isEmpty || model.rename == order.name)
                }
            }
            if let reason = order.cancelReason, !reason.isEmpty { VoicesStudioFact("Cancelled because", reason) }
            HStack {
                Text(order.items.isEmpty ? "No items yet." : "Items").font(.headline)
                Spacer()
                if model.itemsReadFailed {
                    Button("Read again") { Task { await model.select(order.id) } }.controlSize(.small)
                }
            }
            ForEach(order.items) { item in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.summary).font(.callout)
                        if let instructions = item.instructions, !instructions.isEmpty {
                            Text(instructions).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    Spacer()
                    if let quote = item.quote { Text(quote.formatted(.currency(code: "USD"))).monospacedDigit() }
                    if order.isOpen {
                        Button("Edit") { model.edit(item) }
                            .controlSize(.small)
                            .disabled(model.itemEditBlockReason != nil)
                            .help(model.itemEditBlockReason ?? "Change this item")
                        Button(role: .destructive) { Task { await model.remove(item) } } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove this item")
                    }
                }
            }
            if let total = order.total {
                HStack {
                    Spacer()
                    Text("Total \(total.formatted(.currency(code: "USD")))").font(.headline).monospacedDigit()
                }
            }
            if order.isOpen, !order.items.isEmpty, let runner = model.actions.runner("public_submit_order") {
                // Not the shell's Run button: submitting charges the workspace money, the
                // quote, and the question states it.
                HStack(spacing: 10) {
                    Button(model.quotedTotal.map { "Submit and pay \($0)…" } ?? "Submit order…") {
                        Task { await model.submit() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(runner.isRunning || model.submitHold != nil || model.actions.isBlocked(runner))
                    ElevenLabsRiskBadge(risk: .realWorld)
                    Text(model.submitHold ?? "Submitting charges the workspace \(model.quotedTotal ?? "")."
                         + (order.sandbox ? " " + ProductionsSectionModel.sandboxWords : ""))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if runner.isRunning { ProgressView().controlSize(.small) }
                }
                if let problem = model.submitProblem {
                    Label(problem, systemImage: "hourglass").font(.caption).foregroundStyle(.orange)
                }
            }
            Divider()
            HStack {
                Text("Deliverables").font(.headline)
                Spacer()
                Button("Fetch deliverables") { Task { await model.loadDeliverables() } }.controlSize(.small)
            }
            ForEach(model.deliverables) { file in
                HStack {
                    Image(systemName: "doc").foregroundStyle(.secondary)
                    Text(file.name).lineLimit(1).truncationMode(.middle)
                    Text(file.contentType).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if let link = file.link {
                        Button("Download") { NSWorkspace.shared.open(link) }
                            .controlSize(.small)
                            .help("Opens the signed download link in your browser")
                    }
                }
            }
        }
    }
}

struct ProductionsMediaCard: View {
    @Bindable var model: ProductionsSectionModel

    var body: some View {
        Card(title: "Media", systemImage: "photo.on.rectangle") {
            ForEach(model.orderMedia) { media in
                HStack {
                    Text(media.name).font(.callout)
                    Text([media.contentType, media.language].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(media.id).font(.caption.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled)
                }
            }
            VoicesStudioFilePicker(title: "File", files: $model.mediaFile,
                                   help: VoicesStudioSchema.description("public_register_media", "media"))
            TextField("…or a link to fetch it from", text: $model.mediaURL).textFieldStyle(.roundedBorder)
            if !model.mediaURL.isEmpty {
                HStack(spacing: 8) {
                    TextField("Content type (e.g. video/mp4)", text: $model.mediaURLType)
                    TextField("File name (e.g. episode.mp4)", text: $model.mediaURLName)
                }
                .textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 8) {
                TextField("Language of the media (e.g. en, es-ES)", text: $model.mediaLanguage).textFieldStyle(.roundedBorder)
                Button("Register media") { Task { await model.registerMedia() } }
                    .disabled(model.actions.isRunning("public_register_media"))
            }
            if !model.mediaProblems.isEmpty { ElevenLabsProblemList(problems: model.mediaProblems) }
            HStack(spacing: 8) {
                TextField("Look up a media id", text: $model.knownMediaID).textFieldStyle(.roundedBorder)
                Button("Look up") { Task { await model.lookUpMedia(model.knownMediaID) } }
                    .disabled(model.knownMediaID.isEmpty)
            }
        }
    }
}

struct ProductionsItemCard: View {
    @Bindable var model: ProductionsSectionModel

    var body: some View {
        Card(title: model.item.itemID == nil ? "Add an item" : "Edit the item", systemImage: "plus.square.on.square") {
            Picker("Work", selection: $model.item.kind) {
                ForEach(model.kinds, id: \.self) { Text(VoicesStudioFormat.words($0)).tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: model.item.kind) {
                model.item.destinationLanguages = []
                Task { await model.loadLanguages(for: model.item.kind) }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Media").font(.caption.weight(.medium))
                if model.orderMedia.isEmpty {
                    Text("Register media above first.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(model.orderMedia) { media in
                    Toggle(media.name, isOn: Binding(
                        get: { model.item.mediaIDs.contains(media.id) },
                        set: { on in
                            if model.item.kind == "dub" { model.item.mediaIDs = on ? [media.id] : [] }
                            else if on { model.item.mediaIDs.append(media.id) }
                            else { model.item.mediaIDs.removeAll { $0 == media.id } }
                        }
                    ))
                }
            }
            Picker("From", selection: $model.item.sourceLanguage) {
                Text("Choose").tag("")
                ForEach(model.languages[model.item.kind] ?? []) { Text($0.label).tag($0.code) }
            }
            .onChange(of: model.item.sourceLanguage) { model.item.destinationLanguages = [] }
            if model.item.kind != "transcription" {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Into").font(.caption.weight(.medium))
                    let choices = model.destinationChoices()
                    if choices.isEmpty {
                        Text("Choose the source language first.").font(.caption).foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading) {
                        ForEach(choices) { language in
                            Toggle(language.label, isOn: Binding(
                                get: { model.item.destinationLanguages.contains(language.code) },
                                set: { on in
                                    if on { model.item.destinationLanguages.append(language.code) }
                                    else { model.item.destinationLanguages.removeAll { $0 == language.code } }
                                }
                            ))
                        }
                    }
                }
            }
            switch model.item.kind {
            case "dub":
                Toggle("Captions for the dubs", isOn: $model.item.includeCaptions)
                Toggle("Captions for the source", isOn: $model.item.includeSourceCaptions)
                if model.item.includeCaptions || model.item.includeSourceCaptions {
                    Toggle("SDH captions (with sound descriptions)", isOn: $model.item.sdh)
                }
            case "subtitles":
                Toggle("SDH subtitles (with sound descriptions)", isOn: $model.item.sdh)
            default:
                Toggle("Verbatim (every word, fillers included)", isOn: $model.item.verbatim)
            }
            TextField("Instructions for the team (optional)", text: $model.item.instructions, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(1...4)
            if !model.itemProblems.isEmpty { ElevenLabsProblemList(problems: model.itemProblems) }
            HStack {
                if model.item.itemID != nil {
                    Button("Cancel edit") { model.item = ProductionsItemDraft(kind: model.item.kind) }
                }
                Spacer()
                Button(model.item.itemID == nil ? "Add item and get a quote" : "Save item") {
                    Task { await model.saveItem() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.actions.isRunning("public_upsert_order_item"))
            }
        }
    }
}
