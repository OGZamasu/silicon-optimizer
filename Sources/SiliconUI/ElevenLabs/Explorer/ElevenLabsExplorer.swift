import AppKit
import SiliconElevenLabs
import SwiftUI

/// The Explorer: every operation in the catalog, searchable and filterable by risk, cost and
/// deprecation, each with a form generated from its schema, a Run button and the result.
///
/// Side by side when there is room; on a narrow window the list and the chosen operation
/// take turns, with a way back.
struct ElevenLabsExplorer: View {
    @Environment(AppModel.self) private var model

    /// Below this width the list and the detail take turns.
    static let splitWidth: CGFloat = 760

    var body: some View {
        let pane = model.elevenLabsPane
        let explorer = pane.explorer(context: .app(model))
        GeometryReader { geometry in
            if geometry.size.width >= Self.splitWidth {
                HStack(spacing: 0) {
                    ElevenLabsExplorerList(explorer: explorer, pane: pane)
                        .frame(width: min(340, max(260, geometry.size.width * 0.34)))
                    Divider()
                    detail(explorer: explorer, pane: pane, showsBack: false)
                }
            } else if pane.explorerSelection == nil {
                ElevenLabsExplorerList(explorer: explorer, pane: pane)
            } else {
                detail(explorer: explorer, pane: pane, showsBack: true)
            }
        }
    }

    @ViewBuilder
    private func detail(explorer: ElevenLabsExplorerModel, pane: ElevenLabsPaneState, showsBack: Bool) -> some View {
        if let id = pane.explorerSelection, let session = explorer.session(for: id) {
            ElevenLabsExplorerDetail(
                session: session, explorer: explorer,
                onBack: showsBack ? { pane.explorerSelection = nil } : nil
            )
            .id(id)
        } else {
            ContentUnavailableView {
                Label("Choose an operation", systemImage: "list.bullet.rectangle")
            } description: {
                Text(
                    "All \(explorer.total) ElevenLabs operations are here, with a form built from "
                    + "each one's schema. Anything that deletes or reaches the real world asks first."
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The searchable, filterable list of operations by group.
struct ElevenLabsExplorerList: View {
    @Bindable var explorer: ElevenLabsExplorerModel
    @Bindable var pane: ElevenLabsPaneState

    var body: some View {
        let matching = explorer.grouped
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                TextField("Search \(explorer.total) operations", text: $explorer.search)
                    .textFieldStyle(.roundedBorder)
                filterMenu
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 6)
            if explorer.isFiltered {
                HStack {
                    Text("\(matching.reduce(0) { $0 + $1.operations.count }) of \(explorer.total)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear filters") { explorer.clearFilters() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
            }
            List(selection: $pane.explorerSelection) {
                ForEach(matching, id: \.group) { group in
                    Section {
                        ForEach(group.operations) { operation in
                            ElevenLabsOperationRow(operation: operation).tag(operation.id)
                        }
                    } header: {
                        HStack {
                            Text(group.group)
                            Spacer()
                            Text("\(group.operations.count)").monospacedDigit()
                        }
                    }
                }
                if matching.isEmpty {
                    Text("Nothing matches. Try fewer words, or clear the filters.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.inset)
        }
    }

    /// A filter other than the search is on.
    private var narrowing: Bool {
        !explorer.risks.isEmpty || explorer.billableOnly || explorer.deprecated != .show
    }

    private var filterMenu: some View {
        Menu {
            Section("Risk") {
                ForEach(ElevenLabsRisk.allCases, id: \.self) { risk in
                    Toggle(risk.displayName, isOn: Binding(
                        get: { explorer.risks.contains(risk) },
                        set: { _ in explorer.toggle(risk) }
                    ))
                }
            }
            Toggle("Only operations that use credits", isOn: $explorer.billableOnly)
            Picker("Deprecated", selection: $explorer.deprecated) {
                ForEach(ElevenLabsExplorerModel.DeprecatedFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            Divider()
            Button("Clear filters") { explorer.clearFilters() }
        } label: {
            Image(systemName: narrowing ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Filter by risk, cost and deprecation")
        .accessibilityLabel("Filters")
    }
}

/// One operation: what it is, what it costs and risks, its form, Run, and the result.
struct ElevenLabsExplorerDetail: View {
    let session: ElevenLabsExplorerModel.Session
    let explorer: ElevenLabsExplorerModel
    var onBack: (() -> Void)?

    @State private var curlProblems: [String] = []
    @State private var copiedCurl = false

    private var operation: ElevenLabsOperation { session.operation }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let onBack {
                    Button(action: onBack) {
                        Label("All operations", systemImage: "chevron.left")
                    }
                    .buttonStyle(.link)
                }
                header
                if !operation.details.isEmpty, operation.details != operation.summary {
                    DisclosureGroup("ElevenLabs' description") {
                        Text(operation.details)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                    }
                    .font(.callout)
                }
                Divider()
                ElevenLabsOperationForm(form: session.form)
                Divider()
                controls
                if !curlProblems.isEmpty {
                    ElevenLabsProblemList(problems: curlProblems)
                }
                ElevenLabsRunnerOutput(runner: session.runner)
            }
            .padding(20)
            .frame(maxWidth: 880, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(operation.summary.isEmpty ? operation.id : operation.summary)
                .font(.title3.weight(.semibold))
                .strikethrough(operation.deprecated)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                ElevenLabsMethodBadge(method: operation.method)
                Text(operation.path)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ElevenLabsFlowLayout(spacing: 6) {
                ElevenLabsRiskBadge(risk: operation.risk)
                if operation.supportsStreaming { tag("Streams", "dot.radiowaves.left.and.right") }
                if operation.returnsCredential { tag("Returns a secret", "key.fill") }
                if operation.deprecated { tag("Deprecated", "exclamationmark.triangle") }
                tag(operation.group, "folder")
                Text(operation.id)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// What running it costs and asks, in a sentence.
    private var note: String {
        var parts: [String] = []
        parts.append(ElevenLabsCostNote.text(for: operation) ?? "Does not spend credits.")
        if operation.requiresConfirmation {
            parts.append("Asks before running: \(operation.risk.displayName.lowercased()).")
        }
        if operation.returnsCredential {
            parts.append("The secret it returns is shown once here and never saved.")
        }
        switch operation.response {
        case .audio, .binary: parts.append("The answer is saved to the output folder.")
        case .json, .text, .events, .multipartMixed: break
        }
        return parts.joined(separator: " ")
    }

    private func tag(_ title: String, _ symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: .capsule)
    }

    private var controls: some View {
        ElevenLabsFlowLayout(spacing: 10) {
            if operation.supportsStreaming {
                Picker("Stream", selection: Binding(
                    get: { session.runner.streamMode },
                    set: { session.runner.streamMode = $0 }
                )) {
                    ForEach(ElevenLabsRunner.StreamMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            ElevenLabsRunButton(runner: session.runner, title: "Run") { explorer.run(session) }
            Button(copiedCurl ? "Copied" : "Copy as curl") { copyCurl() }
                .help("The command without your key: it reads $ELEVENLABS_API_KEY")
            Button("Reset form") {
                session.form.reset()
                curlProblems = []
            }
            .disabled(session.runner.isRunning)
        }
    }

    private func copyCurl() {
        switch explorer.curl(for: session) {
        case .success(let command):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            curlProblems = []
            copiedCurl = true
        case .failure(let problem):
            session.form.setProblems(problem.problems)
            curlProblems = []
            copiedCurl = false
        }
    }
}

/// Lays children out left to right, wrapping onto new lines — for badge rows and control rows
/// that must fit a narrow window.
struct ElevenLabsFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += lineHeight + spacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: min(widest, width), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += lineHeight + spacing
                x = bounds.minX
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
