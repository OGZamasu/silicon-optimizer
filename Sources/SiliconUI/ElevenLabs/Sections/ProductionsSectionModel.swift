import Foundation
import Observation
import SiliconElevenLabs

// MARK: - Data

/// A Productions order: human dubbing, subtitles or transcription, quoted and paid for.
struct ProductionsOrder: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var state: String
    var total: Double?
    var sandbox: Bool
    var submittedAt: String?
    var createdAt: String?
    var cancelReason: String?
    var items: [ProductionsItem]

    init?(json: JSONValue) {
        guard let id = json["order_id"].stringValue else { return nil }
        self.id = id
        name = json["name"].stringValue ?? id
        state = json["state"].stringValue ?? "open"
        total = json["total_amount_usd"].doubleValue
        sandbox = json["sandbox"].boolValue ?? false
        submittedAt = json["submitted_at"].stringValue
        createdAt = json["created_at"].stringValue
        cancelReason = json["cancel_reason"].stringValue
        items = (json["items"].arrayValue ?? []).compactMap(ProductionsItem.init(json:))
    }

    var isOpen: Bool { state == "open" }
}

struct ProductionsItem: Identifiable, Hashable, Sendable {
    var id: String
    var kind: String
    var mediaIDs: [String]
    var sourceLanguage: String?
    var destinationLanguages: [String]
    var instructions: String?
    var quote: Double?

    init?(json: JSONValue) {
        guard let id = json["item_id"].stringValue else { return nil }
        self.id = id
        let item = json["item"]
        kind = item["kind"].stringValue ?? "?"
        mediaIDs = item["media_ids"].arrayValue?.compactMap(\.stringValue) ?? [item["media_id"].stringValue].compactMap { $0 }
        sourceLanguage = item["source_language"].stringValue
        destinationLanguages = item["destination_languages"].arrayValue?.compactMap(\.stringValue) ?? []
        instructions = item["instructions"].stringValue
        quote = json["quote"]["amount_usd"].doubleValue
    }

    var summary: String {
        let languages = destinationLanguages.isEmpty ? (sourceLanguage ?? "") : "\(sourceLanguage ?? "?") → \(destinationLanguages.joined(separator: ", "))"
        return "\(VoicesStudioFormat.words(kind)) · \(languages) · \(mediaIDs.count) media"
    }
}

/// A media file registered to an order.
struct ProductionsMedia: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var contentType: String?
    var language: String?
    var link: URL?
}

/// A finished file of an order: a signed link to the owner's own delivery.
struct ProductionsDeliverable: Identifiable, Hashable, Sendable {
    var name: String
    var contentType: String
    var link: URL?
    var version: Int?
    var id: String { "\(name)#\(version ?? 0)" }
}

struct ProductionsLanguage: Identifiable, Hashable, Sendable {
    var code: String
    var label: String
    var id: String { code }
}

/// The item form: what kind of work, on which media, from and to which languages.
struct ProductionsItemDraft: Hashable, Sendable {
    var kind = "dub"
    var itemID: String?
    var mediaIDs: [String] = []
    var sourceLanguage = ""
    var destinationLanguages: [String] = []
    var includeCaptions = false
    var includeSourceCaptions = false
    var sdh = false
    var verbatim = false
    var instructions = ""
}

// MARK: - Model

/// Productions: orders for dubbing, subtitles and transcription done by people — media
/// registered, items quoted, the order submitted (which charges the workspace), deliverables
/// fetched.
@MainActor
@Observable
final class ProductionsSectionModel {
    let actions: VoicesStudioActions

    var statusFilter: Set<String> = []
    private(set) var orders: [ProductionsOrder] = []
    private(set) var loadedOnce = false
    private(set) var hasMore = false
    @ObservationIgnored private var offset = 0
    private(set) var selected: ProductionsOrder?
    var rename = ""
    var newSandbox = false
    var newOrderName = ""

    // Media
    var mediaFile: [URL] = []
    var mediaURL = ""
    var mediaURLType = ""
    var mediaURLName = ""
    var mediaLanguage = ""
    /// Media registered to each order this session, with what ElevenLabs says about it.
    private(set) var media: [String: [ProductionsMedia]] = [:]
    var knownMediaID = ""

    // Items
    var item = ProductionsItemDraft()
    private(set) var languages: [String: [ProductionsLanguage]] = [:]
    /// For paired kinds: the destinations each source allows.
    private(set) var destinations: [String: [String: [ProductionsLanguage]]] = [:]
    private(set) var itemProblems: [String] = []

    private(set) var deliverables: [ProductionsDeliverable] = []

    static let pageSize = 50

    init(environment: VoicesStudioEnvironment) {
        actions = VoicesStudioActions(context: environment.context)
        actions.onUnknownOutcome = { [weak self] _ in
            if let id = self?.selected?.id { await self?.select(id) }
        }
    }

    // MARK: Spec

    static let controls: [VoicesStudioControl] = [
        .init("public_list_orders", "status", enumerated: true),
        .init("public_list_orders", "page_size"),
        .init("public_list_orders", "offset"),
        .init("public_create_order", "sandbox"),
        .init("public_get_order", "order_id"),
        .init("public_update_order", "request.name"),
        .init("public_register_media", "media"),
        .init("public_register_media", "media_url"),
        .init("public_register_media", "media_url_content_type"),
        .init("public_register_media", "media_url_filename"),
        .init("public_register_media", "declared_language"),
        .init("public_get_media_info", "media_id"),
        .init("public_get_available_languages", "order_item_kind", enumerated: true),
        .init("public_upsert_order_item", "request.item_id"),
        .init("public_upsert_order_item", "request.item.kind"),
        .init("public_upsert_order_item", "request.item.media_id"),
        .init("public_upsert_order_item", "request.item.media_ids"),
        .init("public_upsert_order_item", "request.item.source_language"),
        .init("public_upsert_order_item", "request.item.destination_languages"),
        .init("public_upsert_order_item", "request.item.include_captions"),
        .init("public_upsert_order_item", "request.item.include_source_captions"),
        .init("public_upsert_order_item", "request.item.captions_sdh"),
        .init("public_upsert_order_item", "request.item.sdh"),
        .init("public_upsert_order_item", "request.item.verbatim"),
        .init("public_upsert_order_item", "request.item.instructions"),
        .init("public_remove_order_item", "item_id"),
        .init("public_submit_order", "order_id"),
        .init("public_get_order_deliverables", "order_id"),
    ]

    static let callsWithoutControls: Set<String> = []
    static let explorerOnly: [String: String] = [:]

    var statuses: [String] { VoicesStudioSchema.choices("public_list_orders", "status") }
    var kinds: [String] { VoicesStudioSchema.choices("public_get_available_languages", "order_item_kind") }

    // MARK: Orders

    var listProblem: String? { actions.problem("public_list_orders") }
    var isListing: Bool { actions.isRunning("public_list_orders") }

    func listArguments(offset: Int) -> [String: JSONValue] {
        var arguments: [String: JSONValue] = ["page_size": .number(Double(Self.pageSize)), "offset": .number(Double(offset))]
        if !statusFilter.isEmpty { arguments["status"] = .array(statusFilter.sorted().map(JSONValue.string)) }
        return arguments
    }

    func refresh() async {
        guard let json = await actions.perform("public_list_orders", listArguments(offset: 0), quietly: true)?
            .voicesStudioJSON else { return }
        orders = (json["orders"].arrayValue ?? []).compactMap(ProductionsOrder.init(json:))
        offset = orders.count
        hasMore = orders.count == Self.pageSize
        loadedOnce = true
    }

    func loadMore() async {
        guard hasMore,
              let json = await actions.perform("public_list_orders", listArguments(offset: offset), quietly: true)?
                .voicesStudioJSON else { return }
        let page = (json["orders"].arrayValue ?? []).compactMap(ProductionsOrder.init(json:))
        let known = Set(orders.map(\.id))
        orders += page.filter { !known.contains($0.id) }
        offset += page.count
        hasMore = page.count == Self.pageSize
    }

    func refreshIfNeeded() async {
        guard !loadedOnce else { return }
        await refresh()
    }

    func createOrder() async {
        guard let json = await actions.perform(
            "public_create_order", ["sandbox": .bool(newSandbox)], title: newSandbox ? "Sandbox order" : "New order"
        )?.voicesStudioJSON, let id = json["order_id"].stringValue else { return }
        let name = newOrderName.trimmingCharacters(in: .whitespaces)
        await select(id)
        if !name.isEmpty {
            rename = name
            await saveName()
        }
        newOrderName = ""
        await refresh()
    }

    func select(_ orderID: String?) async {
        guard let orderID else {
            selected = nil
            return
        }
        if selected?.id != orderID {
            deliverables = []
            item = ProductionsItemDraft()
            itemProblems = []
        }
        guard let json = await actions.perform("public_get_order", ["order_id": .string(orderID)], quietly: true)?
            .voicesStudioJSON, let order = ProductionsOrder(json: json) else { return }
        selected = order
        rename = order.name
        if let index = orders.firstIndex(where: { $0.id == order.id }) { orders[index] = order } else { orders.insert(order, at: 0) }
        await loadLanguages(for: item.kind)
    }

    func saveName() async {
        guard let order = selected else { return }
        guard await actions.perform(
            "public_update_order", ["order_id": .string(order.id), "request": ["name": .string(rename)]],
            title: "Rename order"
        ) != nil else { return }
        await select(order.id)
    }

    // MARK: Media

    func registerArguments() -> ([String: JSONValue], [String: [ElevenLabsFile]], [String])? {
        guard let order = selected else { return nil }
        var problems: [String] = []
        var arguments: [String: JSONValue] = ["order_id": .string(order.id)]
        let language = mediaLanguage.trimmingCharacters(in: .whitespaces)
        if language.isEmpty { problems.append("Say which language the media is in.") }
        arguments["declared_language"] = .string(language)
        var files: [String: [ElevenLabsFile]] = [:]
        let url = mediaURL.trimmingCharacters(in: .whitespaces)
        switch (mediaFile.first, url.isEmpty) {
        case (let file?, true):
            files["media"] = [ElevenLabsFile(url: file)]
        case (nil, false):
            arguments["media_url"] = .string(url)
            let type = mediaURLType.trimmingCharacters(in: .whitespaces)
            let name = mediaURLName.trimmingCharacters(in: .whitespaces)
            if type.isEmpty || name.isEmpty {
                problems.append("A link needs its content type and a file name, as the spec requires.")
            }
            arguments.voicesStudioSet("media_url_content_type", VoicesStudioFormat.text(type))
            arguments.voicesStudioSet("media_url_filename", VoicesStudioFormat.text(name))
        case (nil, true):
            problems.append("Choose a file or give a link.")
        case (.some, false):
            problems.append("Register a file or a link, not both.")
        }
        return (arguments, files, problems)
    }

    private(set) var mediaProblems: [String] = []

    func registerMedia() async {
        guard let (arguments, files, problems) = registerArguments(), let order = selected else { return }
        mediaProblems = problems
        guard problems.isEmpty,
              let json = await actions.perform("public_register_media", arguments, files: files, title: "Media for \(order.name)")?
                .voicesStudioJSON, let id = json["media_id"].stringValue else { return }
        mediaFile = []
        mediaURL = ""
        mediaURLName = ""
        mediaURLType = ""
        await lookUpMedia(id)
        if !item.mediaIDs.contains(id) { item.mediaIDs.append(id) }
    }

    /// Asks ElevenLabs about a media id — one registered now, or one typed in.
    func lookUpMedia(_ mediaID: String) async {
        guard let order = selected,
              let json = await actions.perform(
                "public_get_media_info", ["order_id": .string(order.id), "media_id": .string(mediaID)], quietly: true
              )?.voicesStudioJSON else { return }
        let entry = ProductionsMedia(
            id: json["media_id"].stringValue ?? mediaID, name: json["name"].stringValue ?? mediaID,
            contentType: json["content_type"].stringValue, language: json["language"].stringValue,
            link: json["signed_url"].stringValue.flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
        )
        media[order.id, default: []].removeAll { $0.id == entry.id }
        media[order.id, default: []].append(entry)
    }

    var orderMedia: [ProductionsMedia] { selected.map { media[$0.id] ?? [] } ?? [] }

    // MARK: Items

    func loadLanguages(for kind: String) async {
        guard languages[kind] == nil,
              let json = await actions.perform(
                "public_get_available_languages", ["order_item_kind": .string(kind)], quietly: true
              )?.voicesStudioJSON else { return }
        take(languagesJSON: json, for: kind)
    }

    func take(languagesJSON json: JSONValue, for kind: String) {
        func language(_ value: JSONValue) -> ProductionsLanguage? {
            guard let code = value["code"].stringValue else { return nil }
            return ProductionsLanguage(code: code, label: value["label"].stringValue ?? code)
        }
        if let pairs = json["language_pairs"].arrayValue {
            var sources: [ProductionsLanguage] = []
            var map: [String: [ProductionsLanguage]] = [:]
            for pair in pairs {
                guard let source = language(pair["source_language"]) else { continue }
                sources.append(source)
                map[source.code] = (pair["destination_languages"].arrayValue ?? []).compactMap(language)
            }
            languages[kind] = sources
            destinations[kind] = map
        } else {
            languages[kind] = (json["languages"].arrayValue ?? []).compactMap(language)
        }
    }

    /// The destinations offered for the chosen source: the pair list's when the kind is paired,
    /// every language otherwise.
    func destinationChoices() -> [ProductionsLanguage] {
        if let map = destinations[item.kind] { return map[item.sourceLanguage] ?? [] }
        return languages[item.kind] ?? []
    }

    /// The item as the spec's union takes it for its kind, and every problem with it.
    nonisolated static func itemArguments(orderID: String, draft: ProductionsItemDraft) -> ([String: JSONValue], [String]) {
        var problems: [String] = []
        var item: [String: JSONValue] = ["kind": .string(draft.kind)]
        if draft.mediaIDs.isEmpty { problems.append("Register or name the media first.") }
        if draft.sourceLanguage.isEmpty { problems.append("Choose the source language.") }
        item["source_language"] = .string(draft.sourceLanguage)
        item.voicesStudioSet("instructions", VoicesStudioFormat.text(draft.instructions))
        let destinations = JSONValue.array(draft.destinationLanguages.map(JSONValue.string))
        switch draft.kind {
        case "dub":
            if draft.mediaIDs.count > 1 { problems.append("A dub item takes one media file.") }
            if draft.destinationLanguages.isEmpty { problems.append("Choose at least one language to dub into.") }
            item["media_id"] = .string(draft.mediaIDs.first ?? "")
            item["destination_languages"] = destinations
            item["include_captions"] = .bool(draft.includeCaptions)
            item["include_source_captions"] = .bool(draft.includeSourceCaptions)
            if draft.includeCaptions || draft.includeSourceCaptions { item["captions_sdh"] = .bool(draft.sdh) }
        case "subtitles":
            if draft.destinationLanguages.isEmpty { problems.append("Choose at least one subtitle language.") }
            item["media_ids"] = .array(draft.mediaIDs.map(JSONValue.string))
            item["destination_languages"] = destinations
            item["sdh"] = .bool(draft.sdh)
        default:
            item["media_ids"] = .array(draft.mediaIDs.map(JSONValue.string))
            item["verbatim"] = .bool(draft.verbatim)
        }
        var request: [String: JSONValue] = ["item": .object(item)]
        request.voicesStudioSet("item_id", draft.itemID.map(JSONValue.string))
        return (["order_id": .string(orderID), "request": .object(request)], problems)
    }

    func saveItem() async {
        guard let order = selected else { return }
        let (arguments, problems) = Self.itemArguments(orderID: order.id, draft: item)
        itemProblems = problems
        guard problems.isEmpty,
              await actions.perform("public_upsert_order_item", arguments, title: "Item for \(order.name)") != nil
        else { return }
        item = ProductionsItemDraft(kind: item.kind)
        await select(order.id)
    }

    func edit(_ existing: ProductionsItem) {
        item = ProductionsItemDraft(
            kind: existing.kind, itemID: existing.id, mediaIDs: existing.mediaIDs,
            sourceLanguage: existing.sourceLanguage ?? "", destinationLanguages: existing.destinationLanguages,
            instructions: existing.instructions ?? ""
        )
    }

    func remove(_ existing: ProductionsItem) async {
        guard let order = selected,
              await actions.perform(
                "public_remove_order_item", ["order_id": .string(order.id), "item_id": .string(existing.id)],
                subject: "the \(VoicesStudioFormat.words(existing.kind).lowercased()) item from “\(order.name)”"
              ) != nil else { return }
        await select(order.id)
    }

    // MARK: Submit and deliver

    /// The spec's own words for a sandbox order — nothing about what it costs.
    static let sandboxWords = "A sandbox order auto-progresses without producer intervention."

    /// The quote to charge, as the order last fetched says; nil until ElevenLabs has quoted it
    /// (the spec leaves `total_amount_usd` out "until quotes are available").
    var quotedTotal: String? {
        selected?.total.map { $0.formatted(.currency(code: "USD")) }
    }

    /// Why Submit is held, when it is.
    var submitHold: String? {
        guard let order = selected else { return nil }
        if order.items.isEmpty { return "Add an item first." }
        if order.total == nil { return "Waiting for ElevenLabs' quote — check the order's status again in a moment." }
        return nil
    }

    /// The money question, from the order as fetched just before asking.
    func submitQuestion() -> VoicesStudioQuestion? {
        guard let order = selected, let amount = quotedTotal else { return nil }
        let count = order.items.count
        return VoicesStudioQuestion(
            "Submit “\(order.name)” and charge the workspace \(amount)?",
            button: "Submit and pay \(amount)",
            consequence: "The workspace is charged \(amount), the total ElevenLabs quoted for "
                + (count == 1 ? "its 1 item." : "its \(count) items.")
                + (order.sandbox ? " " + Self.sandboxWords : ""),
            warning: "Money, not credits: \(amount) charged to the workspace."
        )
    }

    private(set) var submitProblem: String?

    /// Fetches the order again, then asks with the amount it states now — never with a stale
    /// total, never without one.
    func submit() async {
        guard let id = selected?.id else { return }
        submitProblem = nil
        guard let json = await actions.perform("public_get_order", ["order_id": .string(id)], quietly: true)?
            .voicesStudioJSON, let fresh = ProductionsOrder(json: json), fresh.id == id else {
            submitProblem = "The order could not be fetched again, so nothing was submitted."
            return
        }
        selected = fresh
        if let index = orders.firstIndex(where: { $0.id == id }) { orders[index] = fresh }
        guard let order = selected, let question = submitQuestion() else {
            submitProblem = submitHold ?? "The order has no quote yet, so nothing was submitted."
            return
        }
        guard await actions.perform(
            "public_submit_order", ["order_id": .string(order.id)], subject: "the order “\(order.name)”",
            title: "Submit \(order.name)", question: question
        ) != nil else { return }
        await select(order.id)
    }

    func loadDeliverables() async {
        guard let order = selected,
              let json = await actions.perform(
                "public_get_order_deliverables", ["order_id": .string(order.id)], quietly: true
              )?.voicesStudioJSON else { return }
        deliverables = (json["deliverables"].arrayValue ?? []).map { entry in
            ProductionsDeliverable(
                name: entry["name"].stringValue ?? "file", contentType: entry["content_type"].stringValue ?? "",
                link: entry["signed_url"].stringValue.flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil },
                version: entry["version"].intValue
            )
        }
    }

    // MARK: Test support

    func load(orders: [ProductionsOrder], selected: ProductionsOrder? = nil, media: [ProductionsMedia] = [],
              languages: JSONValue? = nil, deliverables: [ProductionsDeliverable] = []) {
        self.orders = orders
        self.selected = selected
        rename = selected?.name ?? ""
        if let selected { self.media[selected.id] = media }
        if let languages { take(languagesJSON: languages, for: item.kind) }
        self.deliverables = deliverables
        loadedOnce = true
    }
}

extension ProductionsItemDraft {
    init(kind: String, itemID: String? = nil, mediaIDs: [String] = [], sourceLanguage: String = "",
         destinationLanguages: [String] = [], instructions: String = "") {
        self.init()
        self.kind = kind
        self.itemID = itemID
        self.mediaIDs = mediaIDs
        self.sourceLanguage = sourceLanguage
        self.destinationLanguages = destinationLanguages
        self.instructions = instructions
    }
}
