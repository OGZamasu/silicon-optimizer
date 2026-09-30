import AppKit
import Foundation
import SiliconElevenLabs
import SwiftUI
import Testing
@testable import SiliconUI

/// Every agents screen drawn with realistic fake data — light and dark, narrow and wide — to
/// PNG files, so a person can look at them. Written to `ELEVENLABS_SNAPSHOT_DIR` when that names
/// an existing folder outside the repository; otherwise to a scratch folder that is removed at
/// the end (the test still proves every screen draws).
@Suite("ElevenLabs agents screens", .serialized)
@MainActor
struct AgentsSnapshotTests {

    @Test func everyAgentsScreenDrawsInLightAndDarkNarrowAndWide() async throws {
        let output = try AgentsSnapshot.Output()
        defer { output.finish() }
        let rig = AgentsFixtures.Rig()
        defer { rig.clean() }
        let app = AppModel(settings: .init())
        AgentsPlatformStore.register(rig.store, for: app)
        await AgentsSnapshot.fill(rig.store)

        var written: [URL] = []
        for (name, screen) in AgentsSnapshot.screens(rig.store) {
            for dark in [false, true] {
                for width in [640.0, 1120.0] {
                    let data = try await AgentsSnapshot.png(screen, app: app, width: width, height: 1800, dark: dark)
                    #expect(data.count > 20_000, "\(name) drew next to nothing")
                    let url = output.directory.appendingPathComponent(
                        "agents-\(name)-\(dark ? "dark" : "light")-\(Int(width)).png"
                    )
                    try data.write(to: url)
                    written.append(url)
                }
            }
        }
        #expect(written.count == AgentsSnapshot.screens(rig.store).count * 4)
        // Drawing reads only what the fixtures hold; nothing was placed, sent or deleted.
        let risky = rig.transport.requests.compactMap { ElevenLabsCatalog.operation($0.operationID) }
            .filter { $0.requiresConfirmation || $0.risk == .generate || $0.billable }
        #expect(risky.isEmpty, "drawing sent \(risky.map(\.id))")
    }

    /// The section views the pane shows find their store through the pane, not a new one.
    @Test func theSectionViewsUseThePanesStore() async throws {
        let rig = AgentsFixtures.Rig()
        defer { rig.clean() }
        let app = AppModel(settings: .init())
        AgentsPlatformStore.register(rig.store, for: app)
        #expect(AgentsPlatformStore.shared(for: app) === rig.store)
        for section in AgentsSections.all {
            let data = try await AgentsSnapshot.png(ElevenLabsSectionContent(section: section), app: app,
                                                    width: 900, height: 700, dark: false)
            #expect(data.count > 5_000, "\(section)")
        }
    }
}

@MainActor
enum AgentsSnapshot {

    /// Where the PNGs go, and the require-scratch check before anything is removed.
    struct Output {
        let directory: URL
        let isScratch: Bool

        init() throws {
            if let path = ProcessInfo.processInfo.environment["ELEVENLABS_SNAPSHOT_DIR"], path.hasPrefix("/"),
               !path.contains("/Tests/"), !path.contains("/Sources/") {
                let url = URL(fileURLWithPath: path, isDirectory: true)
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    directory = url
                    isScratch = false
                    return
                }
            }
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("elevenlabs-agents-snapshots-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            isScratch = true
        }

        /// Removes the folder only when this test made it in the temporary directory.
        func finish() {
            guard isScratch else { return }
            let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
            let target = directory.standardizedFileURL.resolvingSymlinksInPath()
            guard target.deletingLastPathComponent().path == temporary.path,
                  target.lastPathComponent.hasPrefix("elevenlabs-agents-snapshots-") else { return }
            try? FileManager.default.removeItem(at: target)
        }
    }

    /// Loads the fixtures into every section's view-model, as a session of use would.
    static func fill(_ store: AgentsPlatformStore) async {
        let directory = store.directory
        await directory.agents.refresh()
        await directory.phoneNumbers.refresh()
        await directory.tools.refresh()
        await directory.documents.refresh()
        await directory.mcpServers.refresh()
        await directory.secrets.refresh()
        await directory.tags.refresh()
        await directory.tests.refresh()
        await store.voices.refresh()

        await store.agents.list.refresh()
        await store.agents.select(AgentsFixtures.agentID)
        await store.agents.loadLLMs()
        await store.agents.branches.load()
        await store.agents.branches.loadProcedures()
        await store.agents.workspace.load()

        let conversations = store.conversations
        await conversations.list.refresh()
        await conversations.select(AgentsFixtures.conversationID)

        let knowledge = store.knowledge
        await knowledge.list.refresh()
        await knowledge.loadOverview()
        await knowledge.select(AgentsFixtures.documentID)
        await knowledge.loadContent()
        await knowledge.loadIndexes()
        knowledge.testAgentID = AgentsFixtures.agentID
        knowledge.testQuery = "When are you open?"
        await knowledge.testRetrieval()

        let tools = store.tools
        await tools.list.refresh()
        await tools.select(AgentsFixtures.toolID)
        await tools.loadExecutions()

        let numbers = store.phoneNumbers
        await numbers.list.refresh()
        await numbers.select(AgentsFixtures.phoneID)
        numbers.callFromID = AgentsFixtures.phoneID
        numbers.callAgentID = AgentsFixtures.agentID
        numbers.callTo = "+15550199"

        let batches = store.batchCalls
        await batches.list.refresh()
        await batches.select(AgentsFixtures.batchID)
        batches.composing = true
        batches.name = "November check-in"
        batches.agentID = AgentsFixtures.agentID
        batches.phoneNumberID = AgentsFixtures.phoneID
        batches.recipientsText = "phone_number,first_name\n+15550131,Ana\n+15550132,Ben\n+15550133,Cy\n+15550133,Cy"

        let servers = store.mcpServers
        await servers.list.refresh()
        await servers.select(AgentsFixtures.serverID)
        await servers.loadTools()

        let secrets = store.secrets
        await secrets.list.refresh()
        await secrets.select(AgentsFixtures.secretID)

        let testing = store.testing
        await testing.list.refresh()
        await testing.select(AgentsFixtures.testID)
        testing.runAgentID = AgentsFixtures.agentID
        testing.runTestIDs = [AgentsFixtures.testID]
        await testing.invocations.refresh()
        await testing.openInvocation("inv_1")

        let analytics = store.analytics
        analytics.agentID = AgentsFixtures.agentID
        await analytics.loadLiveCount()
        await analytics.loadTopics()
        await analytics.estimateCost()
        await analytics.tickets.refresh()
        await analytics.openTicket("tkt_1")
        await analytics.tags.refresh()
    }

    static func screens(_ store: AgentsPlatformStore) -> [(String, AnyView)] {
        [
            ("agents", AnyView(AgentsScreen(model: store.agents))),
            ("agents-branches", AnyView(AgentsBranchesSnapshot(model: store.agents))),
            ("conversations", AnyView(AgentConversationsScreen(model: store.conversations))),
            ("knowledge", AnyView(AgentKnowledgeScreen(model: store.knowledge))),
            ("tools", AnyView(AgentToolsScreen(model: store.tools))),
            ("phone-numbers", AnyView(AgentPhoneNumbersScreen(model: store.phoneNumbers))),
            ("batch-calls", AnyView(AgentBatchCallsScreen(model: store.batchCalls))),
            ("mcp-servers", AnyView(AgentMCPServersScreen(model: store.mcpServers))),
            ("secrets", AnyView(AgentSecretsScreen(model: store.secrets))),
            ("testing", AnyView(AgentTestingScreen(model: store.testing))),
            ("analytics", AnyView(AgentAnalyticsScreen(model: store.analytics))),
        ]
    }

    /// Draws `view` in an off-screen window of the given size and appearance, lets its tasks
    /// run a moment against the fake transport, and returns a PNG.
    static func png<V: View>(_ view: V, app: AppModel, width: CGFloat, height: CGFloat, dark: Bool) async throws -> Data {
        let root = view
            .environment(app)
            .frame(width: width, height: height, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        host.display()
        defer { window.close() }
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw CocoaError(.fileWriteUnknown)
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        return data
    }
}

/// The Agents screen with its Branches tab open.
private struct AgentsBranchesSnapshot: View {
    let model: AgentsModel

    var body: some View {
        AgentsScreen(model: model)
            .onAppear { model.tab = .branches }
    }
}
