import AppKit
import Foundation
import Observation
import SiliconElevenLabs
import SwiftUI

/// The knowledge base agents answer from: documents from web pages, whole sites, text and
/// files, in folders; each document's content, the agents that use it, its RAG indexes and
/// chunks; searching inside documents; and trying an agent's retrieval with a question.
struct AgentKnowledgeSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        AgentKnowledgeScreen(model: AgentsPlatformStore.shared(for: app).knowledge)
    }
}

struct AgentKnowledgeScreen: View {
    @Bindable var model: AgentKnowledgeModel

    var body: some View {
        ElevenLabsSectionPage(.agentKnowledge, accessory: {
            AgentsRefreshButton(list: model.list, help: "Fetch the documents again")
        }) {
            AgentKnowledgeOverview(model: model)
            AgentKnowledgeAddCard(model: model)
            AgentsMasterDetail(masterWidth: 310) {
                AgentKnowledgeBrowser(model: model)
            } detail: {
                if let document = model.selectedDocument {
                    AgentKnowledgeDocumentView(model: model, document: document)
                } else {
                    AgentsCard("No document selected") {
                        AgentsEmptyState(title: "Choose a document",
                                         message: "Its content, the agents that use it and its RAG index appear here.",
                                         systemImage: "doc.text.magnifyingglass")
                    }
                }
            }
            AgentKnowledgeCrawlsCard(model: model)
            AgentKnowledgeRetrievalCard(model: model)
        }
        .task {
            await model.list.loadIfNeeded()
            if model.overview == .null { await model.loadOverview() }
        }
    }
}

// MARK: - View-model

/// A document found by searching inside documents, with the passage that matched.
struct AgentsKnowledgeHit: Identifiable, Hashable, Sendable {
    var id: String { document.id }
    var document: AgentsKnowledgeDocument
    var snippet: String
}

@MainActor
@Observable
final class AgentKnowledgeModel {
    enum AddKind: String, CaseIterable, Identifiable {
        case url = "Web page"
        case crawl = "Whole site"
        case text = "Text"
        case file = "File"
        case folder = "Folder"
        var id: String { rawValue }
    }

    @ObservationIgnored unowned let store: AgentsPlatformStore
    var calls: AgentsCalls { store.calls }

    // Browsing
    /// The folder shown; nil is the top.
    private(set) var folderID: String?
    /// The folders above, top first.
    private(set) var breadcrumb: [(id: String, name: String)] = []
    var search = ""
    var searchInside = false
    /// The spec's `types` values to show; empty for all.
    var types: Set<String> = []
    let list: AgentsPagedList<AgentsKnowledgeDocument>
    private(set) var contentHits: [AgentsKnowledgeHit] = []
    /// Documents ticked for a bulk action.
    var checked: Set<String> = []
    var bulkMoveTo = ""
    var forceDelete = false

    // Detail
    private(set) var selectedID: String?
    private(set) var detail: JSONValue = .null
    private(set) var content: String?
    private(set) var dependents: [String] = []
    private(set) var indexes: [AgentsRAGIndex] = []
    private(set) var chunks: [AgentsChunk] = []
    var embeddingModel = ""
    var renameText = ""
    var editedContent = ""
    var moveTo = ""

    // Adding
    var addKind: AddKind = .url
    var addURL = ""
    var addName = ""
    var addText = ""
    var addFile: URL?
    var autoSync = false
    var syncDays = 7
    var crawlMaxPages = 100
    var crawlMaxDepth = 3

    // Overview and crawls
    private(set) var overview: JSONValue = .null
    let crawls: AgentsPagedList<AgentsCrawlJob>

    // Retrieval test
    var testAgentID = ""
    var testQuery = ""
    private(set) var retrieved: [AgentsChunk] = []
    private(set) var agentPages: Double?

    init(store: AgentsPlatformStore) {
        self.store = store
        let box = AgentsWeakBox<AgentKnowledgeModel>()
        list = AgentsPagedList { cursor in await box.value?.fetchPage(cursor) }
        crawls = AgentsPagedList { cursor in await box.value?.fetchCrawls(cursor) }
        box.value = self
        embeddingModel = AgentsSchema.choices(AgentsOp.computeRAGIndex, "model").first ?? ""
    }

    var selectedDocument: AgentsKnowledgeDocument? {
        guard let selectedID else { return nil }
        return list.item(selectedID) ?? AgentsKnowledgeDocument(json: detail)
    }

    /// The folders in the list on screen, for "Move to".
    var folders: [AgentsKnowledgeDocument] {
        store.directory.documents.items.filter(\.isFolder)
    }

    func listArguments(cursor: String?) -> [String: JSONValue] {
        var arguments: [String: JSONValue] = ["page_size": 50, "folders_first": true]
        let search = search.trimmingCharacters(in: .whitespaces)
        if !search.isEmpty, !searchInside { arguments["search"] = .string(search) }
        if let folderID { arguments["parent_folder_id"] = .string(folderID) }
        if !types.isEmpty { arguments["types"] = .array(types.sorted().map(JSONValue.string)) }
        if let cursor { arguments["cursor"] = .string(cursor) }
        return arguments
    }

    private func fetchPage(_ cursor: String?) async -> AgentsPage<AgentsKnowledgeDocument>? {
        guard let json = await calls.json(AgentsOp.listDocuments, listArguments(cursor: cursor), quiet: true)
        else { return nil }
        return AgentsPage(
            items: (json["documents"].arrayValue ?? []).compactMap(AgentsKnowledgeDocument.init(json:)),
            cursor: json["next_cursor"].stringValue, hasMore: json["has_more"].boolValue
        )
    }

    func runSearch() async {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard searchInside, !query.isEmpty else {
            contentHits = []
            await list.refresh()
            return
        }
        var arguments: [String: JSONValue] = ["query": .string(query), "page_size": 30]
        if !types.isEmpty { arguments["types"] = .array(types.sorted().map(JSONValue.string)) }
        guard let json = await calls.json(AgentsOp.searchDocuments, arguments, quiet: true) else { return }
        contentHits = (json["results"].arrayValue ?? []).compactMap { hit in
            guard let document = AgentsKnowledgeDocument(json: hit["document"]) else { return nil }
            let snippet = (hit["search_snippet"].arrayValue ?? []).compactMap { $0["text"].stringValue }.joined()
            return AgentsKnowledgeHit(document: document, snippet: snippet)
        }
    }

    // MARK: Folders

    func open(folder: AgentsKnowledgeDocument) async {
        guard folder.isFolder else { return }
        breadcrumb.append((folder.id, folder.name))
        folderID = folder.id
        checked = []
        await list.refresh()
    }

    /// Back up to `index` in the breadcrumb; -1 is the top.
    func goUp(to index: Int) async {
        if index < 0 {
            breadcrumb = []
            folderID = nil
        } else if breadcrumb.indices.contains(index) {
            breadcrumb = Array(breadcrumb.prefix(index + 1))
            folderID = breadcrumb.last?.id
        }
        checked = []
        await list.refresh()
    }

    // MARK: Adding

    func add() async {
        let name = addName.trimmingCharacters(in: .whitespacesAndNewlines)
        var arguments: [String: JSONValue] = [:]
        if let folderID { arguments["parent_folder_id"] = .string(folderID) }
        let operation: String
        var files: [String: [ElevenLabsFile]] = [:]
        switch addKind {
        case .url:
            operation = AgentsOp.createURLDocument
            arguments["url"] = .string(addURL.trimmingCharacters(in: .whitespaces))
            if !name.isEmpty { arguments["name"] = .string(name) }
            if autoSync {
                arguments["enable_auto_sync"] = true
                arguments["minimum_frequency_days"] = .number(Double(syncDays))
            }
        case .crawl:
            operation = AgentsOp.createCrawl
            arguments["url"] = .string(addURL.trimmingCharacters(in: .whitespaces))
            arguments["max_pages"] = .number(Double(crawlMaxPages))
            arguments["max_depth"] = .number(Double(crawlMaxDepth))
            if autoSync {
                arguments["enable_auto_sync"] = true
                arguments["minimum_frequency_days"] = .number(Double(syncDays))
            }
        case .text:
            operation = AgentsOp.createTextDocument
            arguments["text"] = .string(addText)
            if !name.isEmpty { arguments["name"] = .string(name) }
        case .file:
            operation = AgentsOp.createFileDocument
            guard let addFile else { return }
            files["file"] = [ElevenLabsFile(url: addFile)]
            if !name.isEmpty { arguments["name"] = .string(name) }
        case .folder:
            operation = AgentsOp.createFolder
            arguments["name"] = .string(name)
        }
        guard let json = await calls.json(operation, arguments, files: files, title: "Knowledge base: \(addKind.rawValue.lowercased())")
        else { return }
        addURL = ""
        addName = ""
        addText = ""
        addFile = nil
        if addKind == .crawl {
            await crawls.refresh()
        } else if let id = json["id"].stringValue {
            await list.refresh()
            store.directory.documents.reset()
            await select(id)
        }
    }

    // MARK: Selecting

    func select(_ id: String) async {
        selectedID = id
        detail = .null
        content = nil
        dependents = []
        indexes = []
        chunks = []
        moveTo = ""
        guard let json = await calls.json(AgentsOp.getDocument, ["documentation_id": .string(id)], slot: id, quiet: true),
              selectedID == id
        else { return }
        detail = json
        renameText = json["name"].stringValue ?? ""
        editedContent = ""
    }

    func loadContent() async {
        guard let selectedID else { return }
        guard let result = await calls.run(AgentsOp.documentContent, ["documentation_id": .string(selectedID)],
                                           slot: selectedID, quiet: true)
        else { return }
        switch result {
        case .text(let text, _): content = text
        default: content = AgentsCalls.json(of: result)?.stringValue
        }
        editedContent = content ?? ""
    }

    func rename() async {
        guard let selectedID else { return }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, await calls.json(AgentsOp.updateDocument, [
            "documentation_id": .string(selectedID), "name": .string(name),
        ], slot: "\(selectedID)#name") != nil else { return }
        if var document = list.item(selectedID) {
            document.name = name
            list.upsert(document)
        }
    }

    func saveContent() async {
        guard let selectedID else { return }
        guard await calls.json(AgentsOp.updateDocument, [
            "documentation_id": .string(selectedID), "content": .string(editedContent),
        ], slot: "\(selectedID)#content", title: "Edited a document") != nil else { return }
        content = editedContent
    }

    func replaceFile(_ url: URL) async {
        guard let selectedID else { return }
        guard await calls.json(AgentsOp.replaceDocumentFile, ["documentation_id": .string(selectedID)],
                               files: ["file": [ElevenLabsFile(url: url)]], slot: selectedID,
                               title: "Replaced a document's file") != nil
        else { return }
        await select(selectedID)
    }

    func refreshFromSource() async {
        guard let selectedID else { return }
        guard await calls.json(AgentsOp.refreshURLDocument, ["documentation_id": .string(selectedID)], slot: selectedID) != nil
        else { return }
        await select(selectedID)
    }

    /// A signed link to download the uploaded original. Opened in the browser; nothing is
    /// fetched by the app.
    func openSourceFile() async {
        guard let selectedID else { return }
        guard let json = await calls.json(AgentsOp.documentSourceURL, ["documentation_id": .string(selectedID)],
                                          slot: selectedID, quiet: true),
              let link = json["signed_url"].stringValue, let url = URL(string: link), url.scheme == "https"
        else { return }
        NSWorkspace.shared.open(url)
    }

    func move() async {
        guard let selectedID else { return }
        let destination: JSONValue = moveTo.isEmpty ? .null : .string(moveTo)
        guard await calls.json(AgentsOp.moveDocument, ["document_id": .string(selectedID), "move_to": destination],
                               slot: selectedID) != nil
        else { return }
        await list.refresh()
    }

    func loadDependents() async {
        guard let selectedID else { return }
        guard let json = await calls.json(AgentsOp.documentDependents, ["documentation_id": .string(selectedID)],
                                          slot: selectedID, quiet: true)
        else { return }
        dependents = (json["agents"].arrayValue ?? []).map { $0["name"].stringValue ?? $0["id"].stringValue ?? "An agent" }
    }

    func loadIndexes() async {
        guard let selectedID else { return }
        guard let json = await calls.json(AgentsOp.ragIndexes, ["documentation_id": .string(selectedID)], slot: selectedID,
                                          quiet: true)
        else { return }
        indexes = (json["indexes"].arrayValue ?? []).compactMap(AgentsRAGIndex.init(json:))
    }

    /// Starts indexing the document with the chosen embedding model, or reports how far it got.
    func computeIndex() async {
        guard let selectedID, !embeddingModel.isEmpty else { return }
        guard let json = await calls.json(AgentsOp.computeRAGIndex, [
            "documentation_id": .string(selectedID), "model": .string(embeddingModel),
        ], slot: selectedID, title: "RAG index") else { return }
        if let index = AgentsRAGIndex(json: json) {
            indexes.removeAll { $0.id == index.id }
            indexes.append(index)
        }
    }

    func deleteIndex(_ index: AgentsRAGIndex) async {
        guard let selectedID else { return }
        let name = selectedDocument?.name ?? selectedID
        guard await calls.json(
            AgentsOp.deleteRAGIndex, ["documentation_id": .string(selectedID), "rag_index_id": .string(index.id)],
            slot: selectedID, subject: "the \(index.model) index of “\(name)”",
            consequence: "Agents that retrieve from “\(name)” with this model stop finding it until it is indexed again."
        ) != nil else { return }
        indexes.removeAll { $0.id == index.id }
    }

    func loadChunks() async {
        guard let selectedID, !embeddingModel.isEmpty else { return }
        guard let json = await calls.json(AgentsOp.documentChunks, [
            "documentation_id": .string(selectedID), "embedding_model": .string(embeddingModel), "page_size": 30,
        ], slot: selectedID, quiet: true) else { return }
        chunks = (json["chunks"].arrayValue ?? []).compactMap { chunk in
            chunk["id"].stringValue.map {
                AgentsChunk(id: $0, title: chunk["name"].stringValue ?? $0, content: chunk["content"].stringValue ?? "")
            }
        }
    }

    func openChunk(_ id: String) async {
        guard let selectedID else { return }
        guard let json = await calls.json(AgentsOp.documentChunk, [
            "documentation_id": .string(selectedID), "chunk_id": .string(id), "embedding_model": .string(embeddingModel),
        ], quiet: true), let index = chunks.firstIndex(where: { $0.id == id }) else { return }
        chunks[index].content = json["content"].stringValue ?? chunks[index].content
    }

    func delete() async {
        guard let selectedID, let document = selectedDocument else { return }
        var arguments: [String: JSONValue] = ["documentation_id": .string(selectedID)]
        if forceDelete { arguments["force"] = true }
        let what = document.isFolder ? "folder" : "document"
        guard await calls.json(
            AgentsOp.deleteDocument, arguments, slot: selectedID, subject: "the \(what) “\(document.name)”",
            consequence: forceDelete
                ? "ElevenLabs will delete it even though agents use it, and take it out of those agents."
                    + (document.isFolder ? " Everything inside the folder goes too." : "")
                : "ElevenLabs will delete it. If an agent still uses it, the deletion is refused."
        ) != nil else { return }
        list.remove(selectedID)
        self.selectedID = nil
        detail = .null
    }

    // MARK: Bulk

    func bulkDelete() async {
        let ids = checked.sorted()
        guard !ids.isEmpty else { return }
        var arguments: [String: JSONValue] = ["document_ids": .array(ids.map(JSONValue.string))]
        if forceDelete { arguments["force"] = true }
        guard await calls.json(
            AgentsOp.bulkDeleteDocuments, arguments, subject: AgentsFormat.count(ids.count, "document"),
            consequence: "ElevenLabs will delete \(AgentsFormat.count(ids.count, "document or folder", plural: "documents and folders")). "
                + (forceDelete ? "Agents using them lose them." : "Any still used by an agent are refused; the rest are deleted.")
        ) != nil else { return }
        checked = []
        await list.refresh()
    }

    func bulkMove() async {
        let ids = checked.sorted()
        guard !ids.isEmpty else { return }
        let destination: JSONValue = bulkMoveTo.isEmpty ? .null : .string(bulkMoveTo)
        guard await calls.json(AgentsOp.bulkMoveDocuments, [
            "document_ids": .array(ids.map(JSONValue.string)), "move_to": destination,
        ]) != nil else { return }
        checked = []
        await list.refresh()
    }

    /// Which agents use any of the ticked documents.
    private(set) var bulkDependents: [String] = []

    func loadBulkDependents() async {
        let ids = checked.sorted()
        guard !ids.isEmpty else { return }
        guard let json = await calls.json(AgentsOp.bulkDependents, ["document_ids": .array(ids.map(JSONValue.string))], quiet: true)
        else { return }
        bulkDependents = (json["agents"].arrayValue ?? []).map { $0["name"].stringValue ?? $0["id"].stringValue ?? "An agent" }
    }

    /// Indexes every ticked document with the chosen model (up to 100).
    func bulkIndex() async {
        let ids = Array(checked.sorted().prefix(100))
        guard !ids.isEmpty, !embeddingModel.isEmpty else { return }
        let items: [JSONValue] = ids.map {
            ["document_id": .string($0), "model": .string(embeddingModel), "create_if_missing": true]
        }
        await calls.json(AgentsOp.batchRAGIndexes, ["items": .array(items)], title: "RAG indexes")
    }

    // MARK: Overview, crawls, retrieval

    func loadOverview() async {
        overview = await calls.json(AgentsOp.ragOverview, quiet: true) ?? .null
    }

    private func fetchCrawls(_ cursor: String?) async -> AgentsPage<AgentsCrawlJob>? {
        var arguments: [String: JSONValue] = ["page_size": 20]
        if let cursor { arguments["cursor"] = .string(cursor) }
        guard let json = await calls.json(AgentsOp.listCrawls, arguments, quiet: true) else { return nil }
        return AgentsPage(
            items: (json["crawl_jobs"].arrayValue ?? []).compactMap(AgentsCrawlJob.init(json:)),
            cursor: json["next_cursor"].stringValue
        )
    }

    func refreshCrawl(_ id: String) async {
        guard let json = await calls.json(AgentsOp.getCrawl, ["crawl_job_id": .string(id)], slot: id, quiet: true),
              let job = AgentsCrawlJob(json: json) else { return }
        crawls.upsert(job)
    }

    func cancelCrawl(_ job: AgentsCrawlJob) async {
        guard await calls.json(
            AgentsOp.cancelCrawl, ["crawl_job_id": .string(job.id)], slot: job.id,
            subject: "the crawl of \(job.url) and everything it made",
            consequence: "ElevenLabs stops crawling and deletes every document and folder it made."
        ) != nil else { return }
        await refreshCrawl(job.id)
        await list.refresh()
    }

    func testRetrieval() async {
        let query = testQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !testAgentID.isEmpty, !query.isEmpty else { return }
        guard let json = await calls.json(AgentsOp.ragQuery, ["agent_id": .string(testAgentID), "query": .string(query)], quiet: true)
        else { return }
        retrieved = (json["chunks"].arrayValue ?? []).compactMap { chunk in
            chunk["chunk_id"].stringValue.map {
                AgentsChunk(id: $0, title: chunk["document_name"].stringValue ?? "", content: chunk["text"].stringValue ?? "",
                            score: chunk["vector_distance"].doubleValue)
            }
        }
        if let size = await calls.json(AgentsOp.agentKnowledgeSize, ["agent_id": .string(testAgentID)], quiet: true) {
            agentPages = size["number_of_pages"].doubleValue
        }
    }

    static let arguments: [AgentsArgument] = [
        AgentsArgument(AgentsOp.listDocuments, "page_size"), AgentsArgument(AgentsOp.listDocuments, "folders_first"),
        AgentsArgument(AgentsOp.listDocuments, "search"), AgentsArgument(AgentsOp.listDocuments, "parent_folder_id"),
        AgentsArgument(AgentsOp.listDocuments, "types"), AgentsArgument(AgentsOp.listDocuments, "cursor"),
        AgentsArgument(AgentsOp.searchDocuments, "query"), AgentsArgument(AgentsOp.searchDocuments, "page_size"),
        AgentsArgument(AgentsOp.searchDocuments, "types"),
        AgentsArgument(AgentsOp.createURLDocument, "url"), AgentsArgument(AgentsOp.createURLDocument, "name"),
        AgentsArgument(AgentsOp.createURLDocument, "parent_folder_id"),
        AgentsArgument(AgentsOp.createURLDocument, "enable_auto_sync"),
        AgentsArgument(AgentsOp.createURLDocument, "minimum_frequency_days"),
        AgentsArgument(AgentsOp.createCrawl, "url"), AgentsArgument(AgentsOp.createCrawl, "max_pages"),
        AgentsArgument(AgentsOp.createCrawl, "max_depth"), AgentsArgument(AgentsOp.createCrawl, "parent_folder_id"),
        AgentsArgument(AgentsOp.createCrawl, "enable_auto_sync"), AgentsArgument(AgentsOp.createCrawl, "minimum_frequency_days"),
        AgentsArgument(AgentsOp.createTextDocument, "text"), AgentsArgument(AgentsOp.createTextDocument, "name"),
        AgentsArgument(AgentsOp.createTextDocument, "parent_folder_id"),
        AgentsArgument(AgentsOp.createFileDocument, "file"), AgentsArgument(AgentsOp.createFileDocument, "name"),
        AgentsArgument(AgentsOp.createFileDocument, "parent_folder_id"),
        AgentsArgument(AgentsOp.createFolder, "name"), AgentsArgument(AgentsOp.createFolder, "parent_folder_id"),
        AgentsArgument(AgentsOp.getDocument, "documentation_id"),
        AgentsArgument(AgentsOp.documentContent, "documentation_id"),
        AgentsArgument(AgentsOp.updateDocument, "documentation_id"), AgentsArgument(AgentsOp.updateDocument, "name"),
        AgentsArgument(AgentsOp.updateDocument, "content"),
        AgentsArgument(AgentsOp.replaceDocumentFile, "documentation_id"), AgentsArgument(AgentsOp.replaceDocumentFile, "file"),
        AgentsArgument(AgentsOp.refreshURLDocument, "documentation_id"),
        AgentsArgument(AgentsOp.documentSourceURL, "documentation_id"),
        AgentsArgument(AgentsOp.moveDocument, "document_id"), AgentsArgument(AgentsOp.moveDocument, "move_to"),
        AgentsArgument(AgentsOp.documentDependents, "documentation_id"),
        AgentsArgument(AgentsOp.ragIndexes, "documentation_id"),
        AgentsArgument(AgentsOp.computeRAGIndex, "documentation_id"), AgentsArgument(AgentsOp.computeRAGIndex, "model"),
        AgentsArgument(AgentsOp.deleteRAGIndex, "documentation_id"), AgentsArgument(AgentsOp.deleteRAGIndex, "rag_index_id"),
        AgentsArgument(AgentsOp.documentChunks, "documentation_id"), AgentsArgument(AgentsOp.documentChunks, "embedding_model"),
        AgentsArgument(AgentsOp.documentChunks, "page_size"),
        AgentsArgument(AgentsOp.documentChunk, "documentation_id"), AgentsArgument(AgentsOp.documentChunk, "chunk_id"),
        AgentsArgument(AgentsOp.documentChunk, "embedding_model"),
        AgentsArgument(AgentsOp.deleteDocument, "documentation_id"), AgentsArgument(AgentsOp.deleteDocument, "force"),
        AgentsArgument(AgentsOp.bulkDeleteDocuments, "document_ids"), AgentsArgument(AgentsOp.bulkDeleteDocuments, "force"),
        AgentsArgument(AgentsOp.bulkMoveDocuments, "document_ids"), AgentsArgument(AgentsOp.bulkMoveDocuments, "move_to"),
        AgentsArgument(AgentsOp.bulkDependents, "document_ids"),
        AgentsArgument(AgentsOp.batchRAGIndexes, "items[].document_id"), AgentsArgument(AgentsOp.batchRAGIndexes, "items[].model"),
        AgentsArgument(AgentsOp.batchRAGIndexes, "items[].create_if_missing"),
        AgentsArgument(AgentsOp.listCrawls, "page_size"), AgentsArgument(AgentsOp.listCrawls, "cursor"),
        AgentsArgument(AgentsOp.getCrawl, "crawl_job_id"), AgentsArgument(AgentsOp.cancelCrawl, "crawl_job_id"),
        AgentsArgument(AgentsOp.ragQuery, "agent_id"), AgentsArgument(AgentsOp.ragQuery, "query"),
        AgentsArgument(AgentsOp.agentKnowledgeSize, "agent_id"),
    ]
}

// MARK: - Views

private struct AgentKnowledgeOverview: View {
    let model: AgentKnowledgeModel

    var body: some View {
        let overview = model.overview
        if overview != .null, let used = overview["total_used_bytes"].intValue, let max = overview["total_max_bytes"].intValue {
            AgentsCard("RAG storage", subtitle: "\(AgentsFormat.bytes(used)) of \(AgentsFormat.bytes(max)) used by indexes") {
                ProgressView(value: Double(used), total: Double(Swift.max(max, 1)))
                HStack(spacing: 14) {
                    ForEach(Array((overview["models"].arrayValue ?? []).enumerated()), id: \.offset) { _, entry in
                        Text("\(entry["model"].stringValue ?? ""): \(AgentsFormat.bytes(entry["used_bytes"].intValue))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private struct AgentKnowledgeAddCard: View {
    @Bindable var model: AgentKnowledgeModel

    var body: some View {
        let operation: String = switch model.addKind {
        case .url: AgentsOp.createURLDocument
        case .crawl: AgentsOp.createCrawl
        case .text: AgentsOp.createTextDocument
        case .file: AgentsOp.createFileDocument
        case .folder: AgentsOp.createFolder
        }
        let runner = model.calls.runner(operation)
        AgentsCard("Add to the knowledge base", subtitle: "Goes into \(model.breadcrumb.last.map { "“\($0.name)”" } ?? "the top folder").") {
            Picker("Kind", selection: $model.addKind) {
                ForEach(AgentKnowledgeModel.AddKind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Form {
                switch model.addKind {
                case .url, .crawl:
                    TextField("Address", text: $model.addURL, prompt: Text("https://example.com/help"))
                    if model.addKind == .url {
                        TextField("Name", text: $model.addName, prompt: Text("Optional"))
                    } else {
                        Stepper("At most \(model.crawlMaxPages) pages", value: $model.crawlMaxPages,
                                in: Int(AgentsSchema.range(AgentsOp.createCrawl, "max_pages", fallback: 1...10_000).lowerBound)...Int(AgentsSchema.range(AgentsOp.createCrawl, "max_pages", fallback: 1...10_000).upperBound),
                                step: 10)
                        Stepper("Follow links \(model.crawlMaxDepth) deep", value: $model.crawlMaxDepth, in: 1...10)
                    }
                    Toggle("Keep it in sync with the site", isOn: $model.autoSync)
                    if model.autoSync {
                        Stepper("Check at most every \(model.syncDays) days", value: $model.syncDays,
                                in: Int(AgentsSchema.range(AgentsOp.createURLDocument, "minimum_frequency_days", fallback: 1...180).lowerBound)...Int(AgentsSchema.range(AgentsOp.createURLDocument, "minimum_frequency_days", fallback: 1...180).upperBound))
                    }
                case .text:
                    TextField("Name", text: $model.addName, prompt: Text("Optional"))
                    LabeledContent("Text") {
                        TextEditor(text: $model.addText)
                            .font(.callout)
                            .frame(minHeight: 90)
                            .overlay { RoundedRectangle(cornerRadius: 5).stroke(.separator) }
                    }
                case .file:
                    LabeledContent("File") {
                        HStack {
                            Text(model.addFile?.lastPathComponent ?? "None chosen").foregroundStyle(.secondary)
                            Button("Choose…") {
                                model.addFile = AgentsFilePicker.choose(types: ["pdf", "txt", "docx", "html", "epub", "md"]).first
                            }
                        }
                    }
                    TextField("Name", text: $model.addName, prompt: Text("Optional"))
                case .folder:
                    TextField("Folder name", text: $model.addName)
                }
            }
            .formStyle(.columns)
            AgentsRunButton(runner: runner, title: model.addKind == .crawl ? "Start crawling" : "Add", disabled: !canAdd) {
                Task { await model.add() }
            }
            AgentsRunnerOutput(runner: runner, showsResult: false)
        }
    }

    private var canAdd: Bool {
        switch model.addKind {
        case .url, .crawl: URL(string: model.addURL.trimmingCharacters(in: .whitespaces))?.scheme?.hasPrefix("http") == true
        case .text: !model.addText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .file: model.addFile != nil
        case .folder: !model.addName.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }
}

private struct AgentKnowledgeBrowser: View {
    @Bindable var model: AgentKnowledgeModel

    var body: some View {
        AgentsCard("Documents") {
            HStack(spacing: 4) {
                Button("Top") { Task { await model.goUp(to: -1) } }
                    .buttonStyle(.link)
                ForEach(Array(model.breadcrumb.enumerated()), id: \.offset) { index, folder in
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    Button(folder.name) { Task { await model.goUp(to: index) } }
                        .buttonStyle(.link)
                        .lineLimit(1)
                }
            }
            .font(.caption)
            AgentsSearchField(prompt: model.searchInside ? "Search inside documents" : "Names starting with…", text: $model.search) {
                Task { await model.runSearch() }
            }
            HStack {
                Toggle("Inside documents", isOn: $model.searchInside)
                    .toggleStyle(.checkbox)
                    .onChange(of: model.searchInside) { Task { await model.runSearch() } }
                Spacer()
                Menu("Types") {
                    ForEach(AgentsSchema.choices(AgentsOp.listDocuments, "types"), id: \.self) { type in
                        Toggle(AgentsFormat.words(type), isOn: Binding(
                            get: { model.types.contains(type) },
                            set: { on in
                                if on { model.types.insert(type) } else { model.types.remove(type) }
                                Task { await model.runSearch() }
                            }
                        ))
                    }
                }
                .fixedSize()
            }
            .font(.caption)
            if model.searchInside, !model.search.isEmpty {
                AgentsRunnerError(runner: model.calls.runner(AgentsOp.searchDocuments))
                if model.contentHits.isEmpty {
                    Text("Nothing found inside documents.").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(model.contentHits) { hit in
                    AgentsRow(selected: model.selectedID == hit.document.id) {
                        Task { await model.select(hit.document.id) }
                    } content: {
                        VStack(alignment: .leading, spacing: 2) {
                            Label(hit.document.name, systemImage: hit.document.systemImage).lineLimit(1)
                            if !hit.snippet.isEmpty {
                                Text(hit.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                            }
                        }
                    }
                }
            } else {
                AgentsListBody(model.list, runner: model.calls.runner(AgentsOp.listDocuments),
                               empty: "Nothing here yet. Add a web page, a site, text or a file above.") { document in
                    HStack(spacing: 4) {
                        Toggle("", isOn: Binding(
                            get: { model.checked.contains(document.id) },
                            set: { on in
                                if on { model.checked.insert(document.id) } else { model.checked.remove(document.id) }
                            }
                        ))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .accessibilityLabel("Select \(document.name)")
                        AgentsRow(selected: model.selectedID == document.id) {
                            if document.isFolder {
                                Task { await model.open(folder: document) }
                            } else {
                                Task { await model.select(document.id) }
                            }
                        } content: {
                            HStack(spacing: 6) {
                                Image(systemName: document.systemImage).foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(document.name).lineLimit(1)
                                    Text(document.isFolder ? "Folder" : "\(document.typeName) · \(AgentsFormat.bytes(document.sizeBytes))\(document.dependentAgents > 0 ? " · \(AgentsFormat.count(document.dependentAgents, "agent"))" : "")")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                if document.isFolder {
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
            }
            if !model.checked.isEmpty { bulkBar }
        }
    }

    private var bulkBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text("\(AgentsFormat.count(model.checked.count, "item")) selected").font(.caption.weight(.medium))
            HStack {
                Picker("Move to", selection: $model.bulkMoveTo) {
                    Text("Top folder").tag("")
                    ForEach(model.folders) { Text($0.name).tag($0.id) }
                }
                .fixedSize()
                Button("Move") { Task { await model.bulkMove() } }
            }
            HStack {
                Button("Which agents use them") { Task { await model.loadBulkDependents() } }
                Button("Index them") { Task { await model.bulkIndex() } }
                    .help("Build RAG indexes for the selected documents with the embedding model chosen below")
            }
            if !model.bulkDependents.isEmpty {
                Text("Used by " + ListFormatter.localizedString(byJoining: model.bulkDependents))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Toggle("Even if agents use them", isOn: $model.forceDelete).toggleStyle(.checkbox)
                AgentsRunButton(runner: model.calls.runner(AgentsOp.bulkDeleteDocuments), title: "Delete…") {
                    Task { await model.bulkDelete() }
                }
            }
            ForEach([AgentsOp.bulkMoveDocuments, AgentsOp.bulkDeleteDocuments, AgentsOp.batchRAGIndexes], id: \.self) {
                AgentsRunnerOutput(runner: model.calls.runner($0), showsResult: false)
            }
        }
        .font(.callout)
        .task { await model.store.directory.documents.loadIfNeeded() }
    }
}

private struct AgentKnowledgeDocumentView: View {
    @Bindable var model: AgentKnowledgeModel
    let document: AgentsKnowledgeDocument

    var body: some View {
        let calls = model.calls
        let detail = model.detail
        VStack(alignment: .leading, spacing: 14) {
            AgentsCard(document.name) {
                AgentsFact(label: "Kind", value: document.typeName)
                if let url = document.url ?? detail["url"].stringValue { AgentsFact(label: "Address", value: url) }
                if let file = detail["filename"].stringValue { AgentsFact(label: "File", value: file) }
                AgentsFact(label: "Size", value: AgentsFormat.bytes(document.sizeBytes ?? detail["metadata"]["size_bytes"].intValue))
                AgentsFact(label: "Updated", value: AgentsFormat.date(document.updatedAt ?? AgentsJSON.date(detail["metadata"]["last_updated_at_unix_secs"])))
                if detail["auto_sync_info"] != .null {
                    AgentsFact(label: "Sync", value: "Every \(detail["auto_sync_info"]["minimum_frequency_days"].intValue ?? 0) days at most")
                }
                AgentsFact(label: "ID", value: document.id, monospaced: true)
                AgentsRunnerError(runner: calls.runner(AgentsOp.getDocument, slot: document.id))
                HStack {
                    TextField("Name", text: $model.renameText).textFieldStyle(.roundedBorder)
                    AgentsRunButton(runner: calls.runner(AgentsOp.updateDocument, slot: "\(document.id)#name"), title: "Rename",
                                        disabled: model.renameText.isEmpty || model.renameText == document.name) {
                        Task { await model.rename() }
                    }
                }
                HStack(spacing: 8) {
                    if document.type == "url" {
                        AgentsRunButton(runner: calls.runner(AgentsOp.refreshURLDocument, slot: document.id), title: "Fetch the page again") {
                            Task { await model.refreshFromSource() }
                        }
                    }
                    if document.type == "file" {
                        Button("Replace the file…") {
                            if let url = AgentsFilePicker.choose().first { Task { await model.replaceFile(url) } }
                        }
                        Button("Open the original") { Task { await model.openSourceFile() } }
                    }
                }
                HStack {
                    Picker("Move to", selection: $model.moveTo) {
                        Text("Top folder").tag("")
                        ForEach(model.folders.filter { $0.id != document.id }) { Text($0.name).tag($0.id) }
                    }
                    .fixedSize()
                    Button("Move") { Task { await model.move() } }
                }
                AgentsRunnerOutput(runner: calls.runner(AgentsOp.updateDocument, slot: "\(document.id)#name"))
                ForEach([AgentsOp.refreshURLDocument, AgentsOp.replaceDocumentFile, AgentsOp.documentSourceURL,
                         AgentsOp.moveDocument], id: \.self) {
                    AgentsRunnerOutput(runner: calls.runner($0, slot: document.id))
                }
            }
            .task { await model.store.directory.documents.loadIfNeeded() }
            AgentsCard("Content", subtitle: document.type == "text" ? "Text documents can be edited here." : "What agents read.") {
                if let content = model.content {
                    if document.type == "text" {
                        TextEditor(text: $model.editedContent)
                            .font(.callout)
                            .frame(minHeight: 160)
                            .overlay { RoundedRectangle(cornerRadius: 5).stroke(.separator) }
                        AgentsRunButton(runner: calls.runner(AgentsOp.updateDocument, slot: "\(document.id)#content"), title: "Save text",
                                            disabled: model.editedContent == content) {
                            Task { await model.saveContent() }
                        }
                        AgentsRunnerOutput(runner: calls.runner(AgentsOp.updateDocument, slot: "\(document.id)#content"), showsResult: false)
                    } else {
                        ElevenLabsTextBlock(text: content)
                    }
                } else {
                    Button("Show the content") { Task { await model.loadContent() } }
                    AgentsRunnerError(runner: calls.runner(AgentsOp.documentContent, slot: document.id))
                }
            }
            AgentsCard("Used by") {
                if model.dependents.isEmpty {
                    Button("Which agents use it") { Task { await model.loadDependents() } }
                } else {
                    Text(ListFormatter.localizedString(byJoining: model.dependents)).font(.callout)
                }
                AgentsRunnerError(runner: calls.runner(AgentsOp.documentDependents, slot: document.id))
            }
            ragCard
            AgentsCard("Delete") {
                Toggle("Even if agents use it", isOn: $model.forceDelete).toggleStyle(.checkbox)
                AgentsRunButton(runner: calls.runner(AgentsOp.deleteDocument, slot: document.id), title: "Delete…") {
                    Task { await model.delete() }
                }
                AgentsRunnerOutput(runner: calls.runner(AgentsOp.deleteDocument, slot: document.id), showsResult: false)
            }
        }
    }

    private var ragCard: some View {
        let calls = model.calls
        return AgentsCard("RAG index", subtitle: "How agents retrieve passages from this document when it is used “when relevant”.") {
            HStack {
                Picker("Embedding model", selection: $model.embeddingModel) {
                    ForEach(AgentsSchema.choices(AgentsOp.computeRAGIndex, "model"), id: \.self) { Text($0).tag($0) }
                }
                .fixedSize()
                AgentsRunButton(runner: calls.runner(AgentsOp.computeRAGIndex, slot: document.id), title: "Index") {
                    Task { await model.computeIndex() }
                }
                Button("Show indexes") { Task { await model.loadIndexes() } }
            }
            AgentsRunnerOutput(runner: calls.runner(AgentsOp.computeRAGIndex, slot: document.id), showsResult: false)
            ForEach(model.indexes) { index in
                HStack {
                    Text(index.model).font(.callout)
                    AgentsBadge(text: AgentsFormat.words(index.status), color: AgentsBadge.color(forStatus: index.status))
                    if index.progress < 100 { Text("\(Int(index.progress)) %").font(.caption.monospacedDigit()) }
                    Spacer()
                    Text(AgentsFormat.bytes(index.usedBytes)).font(.caption).foregroundStyle(.secondary)
                    Button("Delete…") { Task { await model.deleteIndex(index) } }.buttonStyle(.link).font(.caption)
                }
            }
            AgentsRunnerOutput(runner: calls.runner(AgentsOp.deleteRAGIndex, slot: document.id), showsResult: false)
            DisclosureGroup("Chunks") {
                VStack(alignment: .leading, spacing: 6) {
                    Button("Show chunks") { Task { await model.loadChunks() } }
                    AgentsRunnerError(runner: calls.runner(AgentsOp.documentChunks, slot: document.id))
                    ForEach(model.chunks) { chunk in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(chunk.title).font(.caption.weight(.medium))
                                Spacer()
                                Button("Full text") { Task { await model.openChunk(chunk.id) } }.buttonStyle(.link).font(.caption)
                            }
                            Text(chunk.content).font(.caption).foregroundStyle(.secondary).lineLimit(6).textSelection(.enabled)
                        }
                    }
                }
                .padding(.top, 4)
            }
            .font(.callout)
        }
    }
}

private struct AgentKnowledgeCrawlsCard: View {
    let model: AgentKnowledgeModel
    @State private var expanded = false

    var body: some View {
        AgentsCard("Site crawls", subtitle: "Whole-site imports in progress and recently finished.") {
            DisclosureGroup("Show crawls", isExpanded: $expanded) {
                AgentsListBody(model.crawls, runner: model.calls.runner(AgentsOp.listCrawls), empty: "No crawls.") { job in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(job.url).lineLimit(1)
                            Text("\(job.scraped) of \(job.identified) pages\(job.failed > 0 ? ", \(job.failed) failed" : "") · \(AgentsFormat.date(job.createdAt))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        AgentsBadge(text: AgentsFormat.words(job.status), color: AgentsBadge.color(forStatus: job.status))
                        Button {
                            Task { await model.refreshCrawl(job.id) }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Check the crawl again")
                        if job.status == "queued" || job.status == "processing" {
                            Button("Cancel…") { Task { await model.cancelCrawl(job) } }.buttonStyle(.link)
                        }
                    }
                    AgentsRunnerOutput(runner: model.calls.runner(AgentsOp.cancelCrawl, slot: job.id), showsResult: false)
                }
                .padding(.top, 4)
            }
        }
        .onChange(of: expanded) { if expanded { Task { await model.crawls.loadIfNeeded() } } }
    }
}

private struct AgentKnowledgeRetrievalCard: View {
    @Bindable var model: AgentKnowledgeModel

    var body: some View {
        AgentsCard("Try an agent's retrieval", subtitle: "The passages an agent would pull from its documents for a question. Nothing is said and no conversation is made.") {
            HStack(spacing: 8) {
                AgentsAgentPicker(directory: model.store.directory, selection: $model.testAgentID).fixedSize()
                TextField("Question", text: $model.testQuery, prompt: Text("What are your opening hours?"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await model.testRetrieval() } }
                AgentsRunButton(runner: model.calls.runner(AgentsOp.ragQuery), title: "Retrieve",
                                    disabled: model.testAgentID.isEmpty || model.testQuery.isEmpty) {
                    Task { await model.testRetrieval() }
                }
            }
            AgentsRunnerError(runner: model.calls.runner(AgentsOp.ragQuery))
            if let pages = model.agentPages {
                Text("This agent's knowledge base is about \(Int(pages)) pages.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(model.retrieved.enumerated()), id: \.offset) { index, chunk in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(index + 1). \(chunk.title)\(chunk.score.map { String(format: " · distance %.3f", $0) } ?? "")")
                        .font(.caption.weight(.medium))
                    Text(chunk.content).font(.callout).lineLimit(5).textSelection(.enabled)
                }
            }
        }
    }
}
