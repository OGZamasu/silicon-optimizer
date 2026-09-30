import SiliconElevenLabs
import SwiftUI

/// Which view draws each section. The curated ones live in `ElevenLabs/Sections/`, one file
/// each, owned by the builder of that feature; the Explorer is the shell's own.
struct ElevenLabsSectionContent: View {
    let section: ElevenLabsSection

    var body: some View {
        switch section {
        case .speech: SpeechSection()
        case .dialogue: DialogueSection()
        case .voiceChanger: VoiceChangerSection()
        case .soundEffects: SoundEffectsSection()
        case .music: MusicSection()
        case .isolation: IsolationSection()
        case .transcription: TranscriptionSection()
        case .alignment: AlignmentSection()
        case .history: HistorySection()
        case .models: ModelsSection()
        case .voices: VoicesSection()
        case .voiceDesign: VoiceDesignSection()
        case .voiceLibrary: VoiceLibrarySection()
        case .dubbing: DubbingSection()
        case .studio: StudioSection()
        case .productions: ProductionsSection()
        case .flows: FlowsSection()
        case .pronunciation: PronunciationSection()
        case .audioNative: AudioNativeSection()
        case .agents: AgentsSection()
        case .agentConversations: AgentConversationsSection()
        case .agentKnowledge: AgentKnowledgeSection()
        case .agentTools: AgentToolsSection()
        case .agentPhoneNumbers: AgentPhoneNumbersSection()
        case .agentBatchCalls: AgentBatchCallsSection()
        case .agentMCPServers: AgentMCPServersSection()
        case .agentSecrets: AgentSecretsSection()
        case .agentTesting: AgentTestingSection()
        case .agentAnalytics: AgentAnalyticsSection()
        case .workspace: WorkspaceSection()
        case .usage: UsageSection()
        case .serviceAccounts: ServiceAccountsSection()
        case .webhooks: WebhooksSection()
        case .explorer: ElevenLabsExplorer()
        }
    }
}

/// The frame every section draws in: its title and one-line purpose, an optional accessory
/// at the trailing edge (a refresh button, a filter), then the content, scrolling, at a
/// comfortable reading width.
struct ElevenLabsSectionPage<Accessory: View, Content: View>: View {
    let section: ElevenLabsSection
    let accessory: Accessory
    let content: Content

    init(
        _ section: ElevenLabsSection, @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content
    ) {
        self.section = section
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(section.title)
                            .font(.title2.weight(.semibold))
                        Text(section.subtitle)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    accessory
                }
                content
            }
            .padding(20)
            .frame(maxWidth: 880, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension ElevenLabsSectionPage where Accessory == EmptyView {
    init(_ section: ElevenLabsSection, @ViewBuilder content: () -> Content) {
        self.init(section, accessory: { EmptyView() }, content: content)
    }
}

/// What a curated section shows until its builder's screen replaces it: the operations it
/// will be built on, each one click from the Explorer, which already runs all of them.
struct ElevenLabsSectionPlaceholder: View {
    @Environment(AppModel.self) private var model
    let section: ElevenLabsSection

    var body: some View {
        ElevenLabsSectionPage(section) {
            VStack(alignment: .leading, spacing: 12) {
                Text("A native screen for this is on its way. Everything it covers already works from the Explorer:")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                let operations = section.operations
                if operations.isEmpty {
                    Text("The operations catalog is not loaded in this build.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(operations) { operation in
                    ElevenLabsOperationRow(operation: operation) {
                        model.elevenLabsPane.openInExplorer(operation.id)
                    }
                }
            }
        }
    }
}

/// An operation in a list: method, summary, path, and its risk and cost at a glance.
struct ElevenLabsOperationRow: View {
    let operation: ElevenLabsOperation
    var action: (() -> Void)?

    var body: some View {
        let row = HStack(alignment: .firstTextBaseline, spacing: 8) {
            ElevenLabsMethodBadge(method: operation.method)
            VStack(alignment: .leading, spacing: 1) {
                Text(operation.summary.isEmpty ? operation.id : operation.summary)
                    .lineLimit(1)
                    .strikethrough(operation.deprecated)
                Text(operation.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 6)
            // Only what asks first gets a capsule; a long list of "Uses credits" capsules
            // would crowd out the names, so spending is a small icon.
            if operation.requiresConfirmation {
                ElevenLabsRiskBadge(risk: operation.risk)
            } else if operation.billable {
                Image(systemName: "creditcard")
                    .font(.caption)
                    .foregroundStyle(.blue)
                    .help("Uses credits")
                    .accessibilityLabel("Uses credits")
            }
        }
        .contentShape(Rectangle())
        if let action {
            Button(action: action) { row }
                .buttonStyle(.plain)
                .help("Open \(operation.id) in the Explorer")
        } else {
            row
        }
    }
}

/// `GET`, `POST`… as a fixed-width tag, so paths line up in a list.
struct ElevenLabsMethodBadge: View {
    let method: String

    var body: some View {
        Text(method)
            .font(.caption2.monospaced().weight(.semibold))
            .foregroundStyle(color)
            .frame(width: 48, alignment: .leading)
    }

    private var color: Color {
        switch method {
        case "GET": .blue
        case "POST": .green
        case "PATCH", "PUT": .orange
        case "DELETE": .red
        default: .secondary
        }
    }
}
