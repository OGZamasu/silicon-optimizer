import SiliconCore
import SiliconRuntime
import SwiftUI
import UniformTypeIdentifiers

struct ChatView: View {
    @Environment(AppModel.self) private var model

    @State private var draft = ""
    @State private var attachments: [String] = []
    @State private var isShowingImporter = false

    @State private var isNamingFolder = false
    @State private var renamingFolder: ConversationFolder?
    @State private var movingConversation: Conversation.ID?
    @State private var folderName = ""

    var body: some View {
        @Bindable var model = model

        // A plain split rather than a nested NavigationSplitView. Nesting one inside the
        // window's own split view produced two sidebars side by side, each too narrow to show
        // a conversation title or the search field without truncating it.
        HStack(spacing: 0) {
            conversationList
                .frame(width: 248)
            Divider()
            Group {
                if model.selectedConversation != nil {
                    transcript
                } else {
                    EmptyStateView(
                        systemImage: "bubble.left.and.bubble.right",
                        title: "No conversation selected",
                        message: "Pick one on the left, or start a new conversation.",
                        actionTitle: "New Conversation",
                        action: { model.newConversation() }
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Chat")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.newConversation() } label: {
                    Label("New Conversation", systemImage: "square.and.pencil")
                }
                .help("New conversation")
            }
        }
    }

    // MARK: - Sidebar

    private var conversationList: some View {
        @Bindable var model = model

        let matches = model.filteredConversations()
        let pinned = matches.filter(\.isPinned)
        let unfiled = model.conversations(in: nil)

        return List(selection: $model.selectedConversationID) {
            if !pinned.isEmpty {
                Section("Pinned") {
                    ForEach(pinned) { conversation in
                        conversationRow(conversation)
                    }
                }
            }

            ForEach(model.visibleFolders()) { folder in
                Section {
                    ForEach(model.conversations(in: folder.id)) { conversation in
                        conversationRow(conversation)
                    }
                } header: {
                    HStack(spacing: 5) {
                        Image(systemName: "folder").imageScale(.small)
                        Text(folder.name)
                    }
                    .contextMenu {
                        Button("Rename…") { renamingFolder = folder; folderName = folder.name }
                        Button("Delete Folder", role: .destructive) {
                            // Conversations survive; only the grouping goes.
                            model.deleteFolder(folder.id)
                        }
                    }
                }
            }

            Section(model.conversationSearch.isEmpty
                    ? (model.folders.isEmpty ? "Recent" : "Unfiled")
                    : "Results") {
                ForEach(unfiled) { conversation in
                    conversationRow(conversation)
                }
                if matches.isEmpty {
                    Text("No conversations match.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        // Searches message bodies, not just titles — a title is only ever the first line of
        // the opening prompt, which is rarely what you remember a conversation by.
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .imageScale(.small)
                TextField("Search conversations", text: $model.conversationSearch)
                    .textFieldStyle(.plain)
                    .font(.callout)
                if !model.conversationSearch.isEmpty {
                    Button { model.conversationSearch = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.background.secondary, in: .rect(cornerRadius: 7))
            .padding(10)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button {
                movingConversation = nil
                folderName = ""
                isNamingFolder = true
            } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .sheet(isPresented: $isNamingFolder) { folderSheet }
        .sheet(item: $renamingFolder) { folder in folderSheet(renaming: folder) }
    }

    // MARK: - Folder naming

    @ViewBuilder
    private var folderSheet: some View {
        folderForm(title: "New Folder", confirm: "Create") {
            let folder = model.createFolder(named: folderName)
            // Created from a conversation's "Move to" menu: file it immediately, which is
            // what the user was actually asking for.
            if let moving = movingConversation { model.move(moving, to: folder.id) }
        }
    }

    private func folderSheet(renaming folder: ConversationFolder) -> some View {
        folderForm(title: "Rename Folder", confirm: "Rename") {
            model.renameFolder(folder.id, to: folderName)
        }
    }

    private func folderForm(
        title: String, confirm: String, action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)
            TextField("Folder name", text: $folderName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { commitFolder(action) }
            HStack {
                Spacer()
                Button("Cancel") { dismissFolderSheet() }
                    .keyboardShortcut(.cancelAction)
                Button(confirm) { commitFolder(action) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(folderName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    private func commitFolder(_ action: () -> Void) {
        action()
        dismissFolderSheet()
    }

    private func dismissFolderSheet() {
        isNamingFolder = false
        renamingFolder = nil
        movingConversation = nil
        folderName = ""
    }

    private func conversationRow(_ conversation: Conversation) -> some View {
        HStack {
            Text(conversation.title)
                .lineLimit(1)
            Spacer()
            if conversation.isPinned {
                Image(systemName: "pin.fill")
                    .imageScale(.small)
                    .foregroundStyle(.tertiary)
            }
        }
        .tag(conversation.id)
        .contextMenu {
            Button(conversation.isPinned ? "Unpin" : "Pin") { togglePin(conversation) }

            Menu("Move to") {
                Button("New Folder…") {
                    movingConversation = conversation.id
                    folderName = ""
                    isNamingFolder = true
                }
                if !model.folders.isEmpty { Divider() }
                ForEach(model.folders) { folder in
                    Button(folder.name) { model.move(conversation.id, to: folder.id) }
                        .disabled(conversation.folderID == folder.id)
                }
                if conversation.folderID != nil {
                    Divider()
                    Button("Remove from Folder") { model.move(conversation.id, to: nil) }
                }
            }

            Button("Export as Markdown…") { export(conversation) }
            Divider()
            Button("Delete", role: .destructive) {
                model.deleteConversation(conversation.id)
            }
        }
    }

    // MARK: - Transcript

    private var transcript: some View {
        VStack(spacing: 0) {
            statusBar
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if model.selectedConversation?.messages.isEmpty ?? true {
                            emptyTranscript
                        }
                        ForEach(model.selectedConversation?.messages ?? []) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }
                        // Offered only on a finished answer: regenerating mid-stream would
                        // discard the tokens still arriving.
                        if canRegenerate {
                            Button { model.regenerate() } label: {
                                Label("Regenerate", systemImage: "arrow.clockwise")
                                    .font(.callout)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        // Anchor so the view can follow streaming output.
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(20)
                }
                .onChange(of: model.selectedConversation?.messages.last?.content) {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }

            Divider()
            composer
        }
        .background(.background)
    }

    /// Whether there is a completed answer worth asking for again.
    private var canRegenerate: Bool {
        guard !model.isGenerating, model.runtimeState.isRunning,
              let messages = model.selectedConversation?.messages,
              let last = messages.last
        else { return false }
        return last.role == .assistant && !last.content.isEmpty
    }

    /// Shown in place of a transcript before the first message. An empty pane reads as broken;
    /// this says what to do next and adapts to whether a model is actually loaded.
    private var emptyTranscript: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: model.runtimeState.isRunning ? "text.bubble" : "cpu")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            if let loaded = model.loadedModel {
                Text("Ask \(loaded.name) something.")
                    .font(.headline)
                Text("Everything runs on this Mac. Nothing is sent anywhere.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("No model is loaded yet.")
                    .font(.headline)
                Text("Choose one from the Models tab and it will appear here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Browse models") { model.selectedTab = .models }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 40)
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(model.runtimeState.isRunning ? Color.green : Color.secondary)
                .frame(width: 7, height: 7)

            Text(model.loadedModel?.name ?? model.runtimeState.label)
                .font(.callout.weight(.medium))

            if let configuration = model.activeConfiguration {
                Text("· \(configuration.contextLength.contextLabel) context")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let generation = model.lastGeneration, generation.generatedTokens > 0 {
                Text(String(format: "%.1f tok/s", generation.generationTokensPerSecond))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            if !model.runtimeState.isRunning && !model.runtimeState.isBusy {
                Button("Load a model") { model.selectedTab = .models }
                    .buttonStyle(.link)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(attachments.enumerated()), id: \.offset) { index, dataURL in
                            AttachmentThumbnail(dataURL: dataURL) {
                                attachments.remove(at: index)
                            }
                        }
                    }
                }
                .frame(height: 56)
            }

            HStack(alignment: .bottom, spacing: 10) {
                if model.loadedModel?.supportsVision == true {
                    Button { isShowingImporter = true } label: {
                        Image(systemName: "photo.on.rectangle.angled")
                    }
                    .buttonStyle(.borderless)
                    .help("Attach an image")
                }

                TextField("Message", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .padding(8)
                    .background(.background.secondary, in: .rect(cornerRadius: 8))
                    .onSubmit(send)

                if model.isGenerating {
                    Button { model.stopGenerating() } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.borderless)
                    .help("Stop generating")
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.borderless)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || !model.runtimeState.isRunning)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
        .padding(14)
        .fileImporter(
            isPresented: $isShowingImporter,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                attachments.append(contentsOf: urls.compactMap(Self.dataURL(for:)))
            }
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.send(text, images: attachments)
        draft = ""
        attachments = []
    }

    private func togglePin(_ conversation: Conversation) {
        guard let index = model.conversations.firstIndex(where: { $0.id == conversation.id })
        else { return }
        model.conversations[index].isPinned.toggle()
    }

    private func export(_ conversation: Conversation) {
        let markdown = conversation.messages.map { message in
            let heading = message.role == .user ? "## You" : "## Assistant"
            return "\(heading)\n\n\(message.content)"
        }.joined(separator: "\n\n")

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(conversation.title).md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        if panel.runModal() == .OK, let url = panel.url {
            try? markdown.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Images are inlined as data URLs because that is what the OpenAI vision schema expects.
    static func dataURL(for url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "image/png"
        return "data:\(mime);base64,\(data.base64EncodedString())"
    }
}

// MARK: - Message rendering

private struct MessageBubble: View {
    var message: ChatMessage

    @State private var isReasoningExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: message.role == .user ? "person.circle.fill" : "sparkle")
                    .foregroundStyle(message.role == .user ? .secondary : Color.accentColor)
                Text(message.role == .user ? "You" : "Assistant")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !message.content.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message.content, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .imageScale(.small)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tertiary)
                    .help("Copy")
                }
            }

            if let reasoning = message.reasoning, !reasoning.isEmpty {
                DisclosureGroup(isExpanded: $isReasoningExpanded) {
                    Text(reasoning)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(.top, 4)
                } label: {
                    Label("Reasoning", systemImage: "brain")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if message.content.isEmpty && message.role == .assistant {
                ThinkingIndicator()
            } else {
                MarkdownText(message.content)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            message.role == .user ? Color.accentColor.opacity(0.07) : Color.clear,
            in: .rect(cornerRadius: 10)
        )
    }
}

/// Renders assistant output, splitting fenced code blocks out so they get monospaced styling and
/// their own copy button. Inline markdown goes through `AttributedString`, which handles bold,
/// italics, links and inline code natively.
private struct MarkdownText: View {
    var text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Self.segments(of: text).enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .prose(let value):
                    Text(Self.attributed(value))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case .code(let language, let value):
                    CodeBlock(language: language, code: value)
                }
            }
        }
    }

    enum Segment {
        case prose(String)
        case code(language: String?, String)
    }

    static func segments(of text: String) -> [Segment] {
        var segments: [Segment] = []
        var current = ""
        var codeBuffer = ""
        var language: String?
        var inCode = false

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("```") {
                if inCode {
                    segments.append(.code(language: language, codeBuffer))
                    codeBuffer = ""
                    language = nil
                    inCode = false
                } else {
                    if !current.isEmpty {
                        segments.append(.prose(current))
                        current = ""
                    }
                    let tag = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    language = tag.isEmpty ? nil : tag
                    inCode = true
                }
                continue
            }
            if inCode {
                codeBuffer += (codeBuffer.isEmpty ? "" : "\n") + line
            } else {
                current += (current.isEmpty ? "" : "\n") + line
            }
        }

        // An unterminated fence means the model is still streaming the block.
        if inCode { segments.append(.code(language: language, codeBuffer)) }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            segments.append(.prose(current))
        }
        return segments
    }

    static func attributed(_ value: String) -> AttributedString {
        (try? AttributedString(
            markdown: value,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(value)
    }
}

private struct CodeBlock: View {
    var language: String?
    var code: String

    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language?.uppercased() ?? "CODE")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    didCopy = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        didCopy = false
                    }
                } label: {
                    Label(didCopy ? "Copied" : "Copy",
                          systemImage: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.5))

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(.background.secondary, in: .rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.separator.opacity(0.5), lineWidth: 0.5)
        }
    }
}

private struct ThinkingIndicator: View {
    @State private var phase = 0.0

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(.secondary)
                    .frame(width: 6, height: 6)
                    .opacity(0.3 + 0.7 * abs(sin(phase + Double(index) * 0.6)))
            }
        }
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                phase = .pi * 2
            }
        }
        .accessibilityLabel("Generating")
    }
}

private struct AttachmentThumbnail: View {
    var dataURL: String
    var onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let image = Self.image(from: dataURL) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 52, height: 52)
                    .clipShape(.rect(cornerRadius: 6))
            }
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .buttonStyle(.borderless)
            .padding(2)
        }
    }

    static func image(from dataURL: String) -> NSImage? {
        guard let range = dataURL.range(of: "base64,") else { return nil }
        let base64 = String(dataURL[range.upperBound...])
        guard let data = Data(base64Encoded: base64) else { return nil }
        return NSImage(data: data)
    }
}
