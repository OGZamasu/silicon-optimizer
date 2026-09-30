import SiliconElevenLabs

/// Where a section sits in the ElevenLabs pane's list, in the order the list shows them.
enum ElevenLabsSectionCategory: String, CaseIterable, Identifiable, Hashable {
    case create = "Create"
    case voices = "Voices"
    case studio = "Studio"
    case agents = "Agents"
    case workspace = "Workspace"
    case explorer = "Explorer"

    var id: String { rawValue }

    /// This category's sections, in list order.
    var sections: [ElevenLabsSection] {
        ElevenLabsSection.allCases.filter { $0.category == self }
    }
}

/// One place in the ElevenLabs pane: a curated screen for a feature, or the Explorer that
/// reaches every operation.
///
/// Each curated section is a view in `ElevenLabs/Sections/<Name>Section.swift`, built by the
/// builder that owns it; the shell only knows the name, where it sits and which operations it
/// is built on. Which operations belong to a section is decided by path prefix (the spec's
/// paths are stable; its tags are not — 24 operations have none), and the longest matching
/// prefix across all sections wins, so `/v1/workspace/webhooks` lands in Webhooks rather than
/// Workspace. Operations no section claims are reached through the Explorer only.
enum ElevenLabsSection: String, CaseIterable, Identifiable, Hashable {
    // Create
    case speech
    case dialogue
    case voiceChanger
    case soundEffects
    case music
    case isolation
    case transcription
    case alignment
    case history
    case models
    // Voices
    case voices
    case voiceDesign
    case voiceLibrary
    // Studio
    case dubbing
    case studio
    case productions
    case flows
    case pronunciation
    case audioNative
    // Agents
    case agents
    case agentConversations
    case agentKnowledge
    case agentTools
    case agentPhoneNumbers
    case agentBatchCalls
    case agentMCPServers
    case agentSecrets
    case agentTesting
    case agentAnalytics
    // Workspace
    case workspace
    case usage
    case serviceAccounts
    case webhooks
    // Explorer
    case explorer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .speech: "Speech"
        case .dialogue: "Dialogue"
        case .voiceChanger: "Voice changer"
        case .soundEffects: "Sound effects"
        case .music: "Music"
        case .isolation: "Voice isolation"
        case .transcription: "Transcription"
        case .alignment: "Forced alignment"
        case .history: "History"
        case .models: "Models"
        case .voices: "My voices"
        case .voiceDesign: "Voice design"
        case .voiceLibrary: "Voice library"
        case .dubbing: "Dubbing"
        case .studio: "Studio projects"
        case .productions: "Productions"
        case .flows: "Flows"
        case .pronunciation: "Pronunciation"
        case .audioNative: "Audio Native"
        case .agents: "Agents"
        case .agentConversations: "Conversations"
        case .agentKnowledge: "Knowledge base"
        case .agentTools: "Tools"
        case .agentPhoneNumbers: "Phone numbers"
        case .agentBatchCalls: "Batch calls"
        case .agentMCPServers: "MCP servers"
        case .agentSecrets: "Secrets"
        case .agentTesting: "Testing"
        case .agentAnalytics: "Analytics"
        case .workspace: "Members & sharing"
        case .usage: "Usage"
        case .serviceAccounts: "Service accounts"
        case .webhooks: "Webhooks"
        case .explorer: "All operations"
        }
    }

    /// One line on what the section is for. Searched along with the title.
    var subtitle: String {
        switch self {
        case .speech: "Text to speech with a voice, model and settings, streamed or whole."
        case .dialogue: "Several voices in one conversation, from a script."
        case .voiceChanger: "Speech to speech: say it in another voice."
        case .soundEffects: "Sound effects from a description."
        case .music: "Songs from a prompt or a plan, stems, fine-tunes and music for video."
        case .isolation: "Voice isolation: speech lifted out of background noise."
        case .transcription: "Speech to text with speakers, key terms and entities."
        case .alignment: "Word and character timings for audio and its transcript."
        case .history: "Everything generated with this account, to play or download."
        case .models: "The models this account can use and what each supports."
        case .voices: "Your voices: clone, edit, samples and professional voice training."
        case .voiceDesign: "New voices designed from a description, with previews."
        case .voiceLibrary: "The shared voice library: search and add to your voices."
        case .dubbing: "Dub audio or video into other languages."
        case .studio: "Long-form projects, chapters and snapshots."
        case .productions: "Productions."
        case .flows: "Flows."
        case .pronunciation: "Pronunciation dictionaries and their rules."
        case .audioNative: "The embeddable Audio Native player for your pages."
        case .agents: "Voice agents: prompt, voice, model, tools, branches and versions."
        case .agentConversations: "Agent conversations with transcripts, audio and feedback."
        case .agentKnowledge: "Documents agents answer from, and their RAG index."
        case .agentTools: "Tools agents can call."
        case .agentPhoneNumbers: "Phone numbers, outbound calls and WhatsApp."
        case .agentBatchCalls: "Batch calling: many real phone calls at once."
        case .agentMCPServers: "Outside tool servers connected to agents."
        case .agentSecrets: "Secrets and environment variables agents use."
        case .agentTesting: "Agent tests, test runs and simulated conversations."
        case .agentAnalytics: "Agent analytics, LLM usage, tags and triage tickets."
        case .workspace: "Workspace members, groups, invites, sharing and sign-in connections."
        case .usage: "Your plan, balance and usage over time."
        case .serviceAccounts: "Service accounts and their API keys."
        case .webhooks: "Workspace webhooks."
        case .explorer: "Every ElevenLabs operation, with a form for each."
        }
    }

    /// An SF Symbol, distinct across the pane.
    var systemImage: String {
        switch self {
        case .speech: "text.bubble"
        case .dialogue: "bubble.left.and.bubble.right"
        case .voiceChanger: "person.wave.2"
        case .soundEffects: "speaker.wave.3"
        case .music: "music.note"
        case .isolation: "waveform.badge.minus"
        case .transcription: "text.quote"
        case .alignment: "text.alignleft"
        case .history: "clock.arrow.circlepath"
        case .models: "cpu"
        case .voices: "person.crop.circle"
        case .voiceDesign: "wand.and.stars"
        case .voiceLibrary: "books.vertical"
        case .dubbing: "globe"
        case .studio: "book"
        case .productions: "film.stack"
        case .flows: "arrow.triangle.pull"
        case .pronunciation: "character.book.closed"
        case .audioNative: "play.rectangle"
        case .agents: "person.2.wave.2"
        case .agentConversations: "phone.bubble"
        case .agentKnowledge: "doc.text.magnifyingglass"
        case .agentTools: "wrench.and.screwdriver"
        case .agentPhoneNumbers: "phone"
        case .agentBatchCalls: "phone.arrow.up.right"
        case .agentMCPServers: "server.rack"
        case .agentSecrets: "key"
        case .agentTesting: "checkmark.seal"
        case .agentAnalytics: "chart.bar.xaxis"
        case .workspace: "person.3"
        case .usage: "gauge.with.needle"
        case .serviceAccounts: "person.badge.key"
        case .webhooks: "arrow.up.forward.app"
        case .explorer: "list.bullet.rectangle"
        }
    }

    var category: ElevenLabsSectionCategory {
        switch self {
        case .speech, .dialogue, .voiceChanger, .soundEffects, .music, .isolation,
             .transcription, .alignment, .history, .models:
            .create
        case .voices, .voiceDesign, .voiceLibrary:
            .voices
        case .dubbing, .studio, .productions, .flows, .pronunciation, .audioNative:
            .studio
        case .agents, .agentConversations, .agentKnowledge, .agentTools, .agentPhoneNumbers,
             .agentBatchCalls, .agentMCPServers, .agentSecrets, .agentTesting, .agentAnalytics:
            .agents
        case .workspace, .usage, .serviceAccounts, .webhooks:
            .workspace
        case .explorer:
            .explorer
        }
    }

    /// The spec paths this section is built on, as prefixes that end on a segment boundary
    /// (`/v1/music` claims `/v1/music/plan` but not `/v1/musicians`). Placeholders are written
    /// as the spec writes them.
    var pathPrefixes: [String] {
        switch self {
        case .speech: ["/v1/text-to-speech"]
        case .dialogue: ["/v1/text-to-dialogue"]
        case .voiceChanger: ["/v1/speech-to-speech"]
        case .soundEffects: ["/v1/sound-generation"]
        case .music: ["/v1/music"]
        case .isolation: ["/v1/audio-isolation"]
        case .transcription: ["/v1/speech-to-text"]
        case .alignment: ["/v1/forced-alignment"]
        case .history: ["/v1/history"]
        case .models: ["/v1/models"]
        case .voices: ["/v1/voices", "/v2/voices", "/v1/similar-voices"]
        case .voiceDesign: ["/v1/text-to-voice"]
        case .voiceLibrary: ["/v1/shared-voices", "/v1/voices/add/{public_user_id}"]
        case .dubbing: ["/v1/dubbing"]
        case .studio: ["/v1/studio"]
        case .productions: ["/v1/productions"]
        case .flows: ["/v1/flows"]
        case .pronunciation: ["/v1/pronunciation-dictionaries"]
        case .audioNative: ["/v1/audio-native"]
        case .agents: ["/v1/convai/agents", "/v1/convai/agent", "/v1/convai/llm", "/v1/convai/settings"]
        case .agentConversations:
            ["/v1/convai/conversations", "/v1/convai/conversation", "/v1/convai/users"]
        case .agentKnowledge:
            ["/v1/convai/knowledge-base", "/v1/convai/agent/{agent_id}/knowledge-base",
             "/v1/convai/agents/{agent_id}/knowledge-base"]
        case .agentTools: ["/v1/convai/tools"]
        case .agentPhoneNumbers:
            ["/v1/convai/phone-numbers", "/v1/convai/v2/phone-numbers", "/v1/convai/twilio",
             "/v1/convai/exotel", "/v1/convai/sip-trunk", "/v1/convai/whatsapp",
             "/v1/convai/whatsapp-accounts"]
        case .agentBatchCalls: ["/v1/convai/batch-calling"]
        case .agentMCPServers: ["/v1/convai/mcp-servers"]
        case .agentSecrets: ["/v1/convai/secrets", "/v1/convai/environment-variables"]
        case .agentTesting:
            ["/v1/convai/agent-testing", "/v1/convai/test-invocations",
             "/v1/convai/agents/{agent_id}/simulate-conversation",
             "/v1/convai/agents/{agent_id}/run-tests"]
        case .agentAnalytics:
            ["/v1/convai/analytics", "/v1/convai/llm-usage", "/v1/convai/agent/{agent_id}/llm-usage",
             "/v1/convai/tags", "/v1/convai/triage-tickets",
             "/v1/convai/agents/{agent_id}/triage-tickets", "/v1/convai/agents/{agent_id}/topics"]
        case .workspace: ["/v1/workspace"]
        case .usage: ["/v1/usage", "/v1/user", "/v1/workspace/analytics"]
        case .serviceAccounts: ["/v1/service-accounts", "/v1/workspaces/api-keys"]
        case .webhooks: ["/v1/workspace/webhooks"]
        case .explorer: []
        }
    }

    /// The operations this section is built on, in catalog order. The Explorer's are all of
    /// them.
    var operations: [ElevenLabsOperation] {
        self == .explorer ? ElevenLabsCatalog.all : Self.catalogIndex[self] ?? []
    }

    /// Every catalog operation by the section it belongs to, worked out once: the pane's list
    /// shows a count per section on every draw.
    static let catalogIndex: [ElevenLabsSection: [ElevenLabsOperation]] =
        Dictionary(grouping: ElevenLabsCatalog.all.compactMap { operation in
            section(for: operation).map { (section: $0, operation: operation) }
        }, by: \.section).mapValues { $0.map(\.operation) }

    /// `operations`, from a given list — what tests and the search box use.
    func operations(in catalog: [ElevenLabsOperation]) -> [ElevenLabsOperation] {
        self == .explorer ? catalog : catalog.filter { Self.section(forPath: $0.path) == self }
    }

    /// The catalog display groups this section's operations belong to, in catalog order.
    var groups: [String] {
        var seen = Set<String>()
        return operations.map(\.group).filter { seen.insert($0).inserted }
    }

    /// The curated section built on an operation, or nil when only the Explorer reaches it.
    static func section(for operation: ElevenLabsOperation) -> ElevenLabsSection? {
        section(forPath: operation.path)
    }

    /// The curated section whose longest prefix matches `path`.
    static func section(forPath path: String) -> ElevenLabsSection? {
        var best: (section: ElevenLabsSection, length: Int)?
        for section in allCases where section != .explorer {
            for prefix in section.pathPrefixes where matches(path, prefix: prefix) {
                if prefix.count > best?.length ?? -1 { best = (section, prefix.count) }
            }
        }
        return best?.section
    }

    static func matches(_ path: String, prefix: String) -> Bool {
        path == prefix || path.hasPrefix(prefix.hasSuffix("/") ? prefix : prefix + "/")
    }

    /// Whether every word of `query` appears in the title, subtitle or category.
    func matches(_ query: String) -> Bool {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let haystack = [title, subtitle, category.rawValue].joined(separator: " ").lowercased()
        return words.allSatisfy { haystack.contains($0) }
    }

    /// The section to show, given what was remembered from last time: an unknown value (a
    /// section renamed in a later build) falls back to Speech rather than an empty pane.
    static func resolve(remembered: String) -> ElevenLabsSection {
        ElevenLabsSection(rawValue: remembered) ?? .speech
    }
}
