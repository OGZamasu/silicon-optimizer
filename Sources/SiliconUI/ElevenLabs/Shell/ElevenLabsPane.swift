import SiliconElevenLabs
import SwiftUI

/// The ElevenLabs pane: a list of places on the left — the curated sections by group, with
/// how many operations each is built on, the Explorer, and this session's results — and the
/// chosen one on the right under the account header.
///
/// The search box filters the places and, below them, lists matching operations, each one
/// click from the Explorer. The pane remembers the section it was left on.
struct ElevenLabsPane: View {
    @Environment(AppModel.self) private var model
    /// Settings' own remembered pane, so "Reconnect" lands on the ElevenLabs settings.
    @AppStorage("dev.siliconoptimizer.settings.pane") private var settingsPane = ""
    @State private var confirmingDisconnect = false

    /// Operations listed under the places while searching; the Explorer has the rest.
    static let searchLimit = 25

    var body: some View {
        if model.elevenLabsLinked {
            linked
        } else {
            notConnected
        }
    }

    private var linked: some View {
        let pane = model.elevenLabsPane
        return HStack(spacing: 0) {
            ElevenLabsPaneSidebar(pane: pane)
                .frame(width: 236)
            Divider()
            VStack(spacing: 0) {
                ElevenLabsCreditsHeader(onDisconnect: { confirmingDisconnect = true })
                if let notice = pane.previousAccountNotice {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                            .foregroundStyle(.orange)
                        Text(notice)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button("Dismiss") { pane.previousAccountNotice = nil }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.orange.opacity(0.1))
                }
                if let problem = pane.connectionProblem {
                    ElevenLabsConnectionBanner(
                        problem: problem,
                        onReconnect: openSettings,
                        onRetry: { Task { await model.checkElevenLabsAccount() } }
                    )
                }
                Divider()
                Group {
                    if pane.showsRecents {
                        ElevenLabsRecentResultsView(pane: pane)
                    } else {
                        ElevenLabsSectionContent(section: pane.section)
                            .id(pane.section)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .navigationTitle("ElevenLabs")
        .elevenLabsConfirmations(of: pane)
        .task {
            // Free, and what the header shows; the key is read lazily, off the main actor.
            if model.elevenLabsAccount == nil { await model.checkElevenLabsAccount() }
        }
        .confirmationDialog(
            "Disconnect ElevenLabs?", isPresented: $confirmingDisconnect, titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) { model.disconnectElevenLabs() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "The key is removed from this Mac's Keychain and this pane leaves the sidebar. "
                + "Files already made stay in the output folder."
            )
        }
    }

    private var notConnected: some View {
        ContentUnavailableView {
            Label("ElevenLabs is not connected", systemImage: "waveform.and.mic")
        } description: {
            Text("Add an API key in Settings → ElevenLabs to use it here.")
        } actions: {
            Button("Open Settings", action: openSettings)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func openSettings() {
        settingsPane = SettingsView.Pane.elevenLabs.rawValue
        model.selectedTab = .settings
    }
}

/// The pane's list of places.
struct ElevenLabsPaneSidebar: View {
    @Bindable var pane: ElevenLabsPaneState

    /// What the list selects: a section, the recent results, or (while searching) an
    /// operation to open in the Explorer.
    enum Destination: Hashable {
        case section(ElevenLabsSection)
        case recents
        case operation(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search sections and operations", text: $pane.search)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            List(selection: selection) {
                ForEach(ElevenLabsSectionCategory.allCases) { category in
                    let sections = category.sections.filter(matches)
                    if !sections.isEmpty {
                        Section(category.rawValue) {
                            ForEach(sections) { section in
                                row(section).tag(Destination.section(section))
                            }
                        }
                    }
                }
                if !query.isEmpty {
                    let operations = ElevenLabsCatalog.search(query)
                    Section("Operations (\(operations.count))") {
                        ForEach(operations.prefix(ElevenLabsPane.searchLimit)) { operation in
                            ElevenLabsOperationRow(operation: operation)
                                .tag(Destination.operation(operation.id))
                        }
                        if operations.count > ElevenLabsPane.searchLimit {
                            Text("\(operations.count - ElevenLabsPane.searchLimit) more in the Explorer")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if operations.isEmpty {
                            Text("No operation matches “\(query)”.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Section("This session") {
                    Label {
                        HStack {
                            Text("Recent results")
                            Spacer()
                            Text("\(pane.recents.count)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "tray.full")
                    }
                    .tag(Destination.recents)
                }
            }
            .listStyle(.sidebar)
        }
    }

    private var query: String {
        pane.search.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A section stays listed while searching when its name matches or any operation it is
    /// built on does.
    private func matches(_ section: ElevenLabsSection) -> Bool {
        guard !query.isEmpty else { return true }
        if section.matches(query) { return true }
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        return section != .explorer && section.operations.contains { operation in
            let haystack = [operation.id, operation.path, operation.summary, operation.group]
                .joined(separator: " ").lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    private var selection: Binding<Destination?> {
        Binding(
            get: { pane.showsRecents ? .recents : .section(pane.section) },
            set: { destination in
                switch destination {
                case .section(let section)?:
                    pane.open(section)
                case .recents?:
                    pane.showRecents()
                case .operation(let id)?:
                    pane.openInExplorer(id)
                case nil:
                    break
                }
            }
        )
    }

    private func row(_ section: ElevenLabsSection) -> some View {
        Label {
            HStack {
                Text(section.title)
                Spacer(minLength: 4)
                Text("\(section.operations.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(section.operations.count) operations")
            }
        } icon: {
            Image(systemName: section.systemImage)
        }
    }
}

/// Why the account cannot be used right now, and what to do about it.
struct ElevenLabsConnectionBanner: View {
    let problem: ElevenLabsPaneState.ConnectionProblem
    let onReconnect: () -> Void
    let onRetry: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            if case .keyRejected = problem {
                Button("Reconnect…", action: onReconnect)
            }
            Button("Try again", action: onRetry)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.1))
    }

    private var icon: String {
        switch problem {
        case .keyRejected: "key.slash"
        case .offline: "wifi.slash"
        case .credentialUnavailable: "lock"
        }
    }

    private var title: String {
        switch problem {
        case .keyRejected: "ElevenLabs refused the key"
        case .offline: "ElevenLabs cannot be reached"
        case .credentialUnavailable: "The key could not be read from the Keychain"
        }
    }

    private var detail: String {
        switch problem {
        case .keyRejected(let message):
            "It may have been revoked or rotated, or it belongs to another region. \(message)"
        case .offline(let message):
            "Check the connection; nothing was charged. \(message)"
        case .credentialUnavailable(let message):
            "Unlock the Keychain or allow access when macOS asks. \(message)"
        }
    }
}

/// This session's results, newest first: each one's result as it was, with Save and Reveal
/// for files. Nothing here is written anywhere the output folder does not already hold.
struct ElevenLabsRecentResultsView: View {
    @Environment(AppModel.self) private var model
    let pane: ElevenLabsPaneState
    @State private var expanded: Set<ElevenLabsRecentResult.ID> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Recent results").font(.title2.weight(.semibold))
                        Text("What this session made. Files stay in the output folder after you quit; this list does not.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !pane.recents.isEmpty {
                        Button("Clear list") { pane.clearRecents() }
                    }
                }
                if pane.recents.isEmpty, model.elevenLabsRecentOutputs.isEmpty {
                    Text("Nothing yet. Results from every section and the Explorer appear here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(pane.recents) { recent in
                    recentRow(recent)
                }
                let outputs = model.elevenLabsRecentOutputs
                if !outputs.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Files written this session")
                            .font(.headline)
                            .padding(.top, 8)
                        Text("Everything ElevenLabs saved to the output folder — from this pane and from agents over MCP.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(outputs) { output in
                            HStack(spacing: 8) {
                                Image(systemName: output.contentType.hasPrefix("audio/") ? "waveform" : "doc")
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(output.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                    Text("\(output.operationID) · \(output.createdAt.formatted(date: .omitted, time: .shortened))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 6)
                                ElevenLabsFileActions(url: output.url)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 880, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func recentRow(_ recent: ElevenLabsRecentResult) -> some View {
        let isOpen = expanded.contains(recent.id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button {
                    if isOpen { expanded.remove(recent.id) } else { expanded.insert(recent.id) }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isOpen ? "Collapse" : "Expand")
                VStack(alignment: .leading, spacing: 1) {
                    Text(recent.title).lineLimit(1)
                    Text("\(recent.operationID) · \(recent.date.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let cost = recent.result.meta.characterCost {
                    Text("\(cost.formatted()) credits").font(.caption).foregroundStyle(.secondary)
                }
                if let file = recent.result.files.first {
                    ElevenLabsFileActions(url: file)
                }
                Button {
                    pane.removeRecent(recent.id)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Remove from this list (the file stays)")
                .accessibilityLabel("Remove from list")
            }
            if isOpen {
                ElevenLabsResultView(result: recent.result)
                    .padding(.leading, 20)
            }
        }
        .padding(12)
        .background(.background.secondary, in: .rect(cornerRadius: 10))
    }
}
