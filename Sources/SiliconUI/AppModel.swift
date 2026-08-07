import Foundation
import Observation
import SiliconCatalog
import SiliconControl
import SiliconCore
import SiliconHardware
import SiliconPlanner
import SiliconRuntime
import SwiftUI

/// The application's single source of truth.
///
/// Everything that touches the filesystem, the network or a child process lives behind an actor;
/// this type is the main-actor façade that SwiftUI observes. Keeping the boundary in one place is
/// what makes the concurrency story simple enough to reason about.
@MainActor
@Observable
public final class AppModel {

    // MARK: - Hardware

    public private(set) var profile: SystemProfile
    public private(set) var metrics = SystemMetrics()
    /// Rolling window for the dashboard graphs, newest last.
    public private(set) var history: [SystemMetrics] = []

    static let historyLength = 120        // two minutes at one sample per second

    // MARK: - Library

    public private(set) var installedModels: [InstalledModel] = []
    public private(set) var libraryError: String?
    public private(set) var downloads: [String: DownloadTask] = [:]

    private let library = ModelLibrary()

    // MARK: - Runtime

    public private(set) var runtimeState: RuntimeState = .idle
    public private(set) var loadedModel: InstalledModel?
    public private(set) var activeConfiguration: LoadConfiguration?
    public private(set) var selector = RuntimeSelector(available: [:])
    public internal(set) var lastGeneration: GenerationMetrics?
    public private(set) var runtimeLog: String = ""

    // MARK: - Benchmark

    public internal(set) var benchmarkPhase: BenchmarkRunner.Phase?
    public internal(set) var benchmarkReport: BenchmarkRunner.Report?
    public internal(set) var benchmarkFindings: [BenchmarkRunner.Finding] = []
    /// Correction applied to speed predictions, learned from a benchmark on this machine.
    /// Correction learned for one model, or 1.0 when it has never been benchmarked.
    public func calibration(for model: InstalledModel) -> Double {
        settings.speedCalibrations[model.catalogID ?? model.id] ?? 1.0
    }

    private var runtime: (any InferenceRuntime)?

    /// The live runtime, for the control API to send prompts through.
    var activeRuntime: (any InferenceRuntime)? { runtime }

    // MARK: - Chat

    public var conversations: [Conversation] = [] {
        didSet { scheduleConversationSave() }
    }
    public var selectedConversationID: Conversation.ID?
    /// Filter applied to the conversation list.
    public var conversationSearch = ""

    // MARK: - Settings

    public var settings = Settings()

    // MARK: - UI state

    public var selectedTab: Tab = .dashboard
    public var alert: AlertContent?

    public enum Tab: String, CaseIterable, Identifiable, Hashable {
        case dashboard = "Dashboard"
        case models = "Models"
        case chat = "Chat"
        case settings = "Settings"

        public var id: String { rawValue }

        public var systemImage: String {
            switch self {
            case .dashboard: "gauge.with.dots.needle.67percent"
            case .models: "square.stack.3d.up"
            case .chat: "bubble.left.and.bubble.right"
            case .settings: "gearshape"
            }
        }
    }

    public struct AlertContent: Identifiable {
        public let id = UUID()
        public var title: String
        public var message: String
    }

    private var sampler = MetricsSampler()
    private var samplingTask: Task<Void, Never>?
    private var controlServer: ControlServer?

    // MARK: - Init

    public init() {
        self.profile = HardwareProbe.detect()
        self.settings = Settings.load()
    }

    /// Whether the app has been launched before on this machine. Backed by `UserDefaults` so
    /// the first-run window appears exactly once.
    public var hasLaunchedBefore: Bool {
        get { UserDefaults.standard.bool(forKey: "dev.siliconoptimizer.hasLaunched") }
        set { UserDefaults.standard.set(newValue, forKey: "dev.siliconoptimizer.hasLaunched") }
    }

    private var hasStarted = false

    public func start() {
        guard !hasStarted else { return }
        hasStarted = true
        selector = RuntimeSelector.discover()
        RuntimeLocator.customPaths = settings.customRuntimePaths

        beginSampling()
        startControlServer()

        Task {
            await refreshLibrary()
            loadConversations()
            if conversations.isEmpty { newConversation() }
        }
    }

    /// Publishes the local control API that the MCP bridge talks to, so Claude and ChatGPT can
    /// drive the model this app has loaded rather than starting a second copy of it.
    private func startControlServer() {
        let server = ControlServer(host: self)
        controlServer = server
        Task {
            do {
                try await server.start()
            } catch {
                // Not fatal: the app is fully usable without external control.
                self.libraryError = "Control API unavailable: \(error.localizedDescription)"
            }
        }
        // The handshake file advertises a live app; make sure a quit does not leave it behind
        // pointing at a dead port.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            try? FileManager.default.removeItem(at: ControlAPI.handshakeURL)
        }
    }

    // MARK: - Metrics sampling

    private func beginSampling() {
        samplingTask?.cancel()
        let sampler = self.sampler
        samplingTask = Task { [weak self] in
            while !Task.isCancelled {
                // Sampling is cheap but not free; do it off the main actor so a slow IORegistry
                // walk can never stutter the UI.
                let sample = await Task.detached(priority: .utility) { sampler.sample() }.value
                guard let self else { return }
                self.ingest(sample)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func ingest(_ sample: SystemMetrics) {
        metrics = sample
        history.append(sample)
        if history.count > Self.historyLength {
            history.removeFirst(history.count - Self.historyLength)
        }
        enforceIdleUnload()
    }

    /// Runs the benchmark suite against the loaded model and recalibrates the estimator.
    public func runBenchmark() {
        guard let runtime = activeRuntime, runtimeState.isRunning,
              let loaded = loadedModel, let shape = loaded.shape,
              let configuration = activeConfiguration, benchmarkPhase == nil
        else { return }

        noteActivity()
        let plan = planner().plan(
            shape: shape, quantization: loaded.quantization,
            configuration: configuration, otherAppsInUse: memoryUsedByOtherApps
        )
        // Predict with the *uncalibrated* model, so the benchmark measures the physics rather
        // than grading a previous benchmark's correction.
        let predicted = SpeedEstimator(profile: profile).estimate(
            shape: shape, quantization: loaded.quantization,
            configuration: configuration, plan: plan
        )

        benchmarkPhase = .warmup
        benchmarkReport = nil
        benchmarkFindings = []

        Task {
            defer { benchmarkPhase = nil }
            do {
                let report = try await BenchmarkRunner(runtime: runtime).run(
                    model: loaded, configuration: configuration, predicted: predicted
                ) { phase in
                    Task { @MainActor in self.benchmarkPhase = phase }
                }
                let analyzer = BenchmarkAnalyzer()
                benchmarkReport = report
                benchmarkFindings = analyzer.findings(
                    for: report, configuration: configuration, model: loaded
                )
                // Ground every later estimate in what this Mac actually did.
                settings.speedCalibrations[loaded.catalogID ?? loaded.id] =
                    analyzer.calibration(from: report)
                settings.save()
                // A benchmark is a long generation; do not let it trigger an idle unload.
                noteActivity()
            } catch {
                alert = AlertContent(
                    title: "Benchmark failed", message: error.localizedDescription
                )
            }
        }
    }

    // MARK: - Conversation persistence

    private static var conversationsURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("SiliconOptimizer/conversations.json")
    }

    private var conversationSaveTask: Task<Void, Never>?
    private var isLoadingConversations = false

    private func loadConversations() {
        isLoadingConversations = true
        defer { isLoadingConversations = false }
        guard let data = try? Data(contentsOf: Self.conversationsURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        conversations = (try? decoder.decode([Conversation].self, from: data)) ?? []
        selectedConversationID = conversations.first?.id
    }

    /// Debounced: `conversations` mutates on every streamed token, and writing the whole
    /// transcript to disk that often would peg a core during generation.
    private func scheduleConversationSave() {
        guard !isLoadingConversations else { return }
        conversationSaveTask?.cancel()
        let snapshot = conversations
        conversationSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, self != nil else { return }
            await Self.writeConversations(snapshot)
        }
    }

    private static func writeConversations(_ conversations: [Conversation]) async {
        // Resolved on the main actor before hopping off it.
        let url = conversationsURL
        await Task.detached(priority: .background) {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(conversations) else { return }
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? data.write(to: url, options: .atomic)
        }.value
    }

    /// Conversations matching the current search, newest first, pinned handled by the view.
    public func filteredConversations() -> [Conversation] {
        let query = conversationSearch.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return conversations }
        return conversations.filter { conversation in
            if conversation.title.lowercased().contains(query) { return true }
            // Searching message bodies is what makes this useful — titles are just the first
            // line of the opening prompt.
            return conversation.messages.contains { $0.content.lowercased().contains(query) }
        }
    }

    // MARK: - Idle unload

    /// When the user last did something that needed the model.
    private var lastActivityAt = Date()

    /// Records activity so an idle unload does not fire out from under someone.
    func noteActivity() { lastActivityAt = Date() }

    /// Releases the model after a period of inactivity.
    ///
    /// A loaded model holds tens of gigabytes of wired memory that macOS cannot reclaim on its
    /// own, so leaving one loaded overnight quietly costs the user their whole machine.
    private func enforceIdleUnload() {
        guard settings.unloadWhenIdle, loadedModel != nil, !isGenerating else { return }
        let idleSeconds = Date().timeIntervalSince(lastActivityAt)
        guard idleSeconds >= Double(settings.idleUnloadMinutes) * 60 else { return }

        Task {
            // Re-check after the hop: the user may have started generating in the meantime.
            guard !isGenerating, loadedModel != nil else { return }
            await unload()
            runtimeState = .idle
        }
        // Reset immediately so the unload is not queued repeatedly while it runs.
        lastActivityAt = Date()
    }

    /// Wired memory held by everything other than our own model.
    ///
    /// Deliberately wired rather than total used: wired pages cannot be compressed or swapped,
    /// so they are the only ones that genuinely reduce what a model can claim. Charging the
    /// planner for ordinary app memory would make a machine with a browser open look unable to
    /// run anything.
    public var memoryUsedByOtherApps: Bytes {
        let ours = loadedModel != nil ? estimatedResidentBytes : .zero
        return Bytes(max(0, metrics.memoryWired.rawValue - ours.rawValue))
    }

    private var estimatedResidentBytes: Bytes {
        guard let model = loadedModel, let shape = model.shape,
              let configuration = activeConfiguration else { return .zero }
        return MemoryPlanner(profile: profile)
            .plan(shape: shape, quantization: model.quantization, configuration: configuration)
            .resident
    }

    // MARK: - Library

    public func refreshLibrary() async {
        do {
            try await library.load()
            installedModels = await library.installed
            libraryError = nil
        } catch {
            libraryError = error.localizedDescription
        }
    }

    public func planner() -> MemoryPlanner { MemoryPlanner(profile: profile) }

    public func autoConfigurator() -> AutoConfigurator {
        AutoConfigurator(profile: profile, calibrations: settings.speedCalibrations)
    }

    public func plan(
        for entry: ModelEntry, quantization: Quantization, configuration: LoadConfiguration
    ) -> MemoryPlan {
        planner().plan(
            shape: entry.shape, quantization: quantization,
            configuration: configuration, otherAppsInUse: memoryUsedByOtherApps
        )
    }

    public func isInstalled(_ entry: ModelEntry, quantization: Quantization) -> Bool {
        installedModels.contains {
            $0.catalogID == entry.id && $0.quantization == quantization
        }
    }

    // MARK: - Downloads

    @MainActor
    @Observable
    public final class DownloadTask: Identifiable {
        public let id: String
        public var entry: ModelEntry
        public var quantization: Quantization
        public var progress: ModelDownloader.Progress?
        public var error: String?
        public var isFinished = false
        var task: Task<Void, Never>?

        init(id: String, entry: ModelEntry, quantization: Quantization) {
            self.id = id
            self.entry = entry
            self.quantization = quantization
        }
    }

    public func install(_ entry: ModelEntry, quantization: Quantization) {
        let key = "\(entry.id)@\(quantization.rawValue)"
        guard downloads[key] == nil else { return }

        let download = DownloadTask(id: key, entry: entry, quantization: quantization)
        downloads[key] = download

        download.task = Task { [weak self] in
            guard let self else { return }
            let token = self.settings.huggingFaceToken.isEmpty ? nil : self.settings.huggingFaceToken
            let client = HuggingFaceClient(token: token)
            let resolver = ModelResolver(client: client)
            let downloader = ModelDownloader(token: token)

            do {
                let resolution = try await resolver.resolve(entry: entry, quantization: quantization)
                let destination = await self.library.directory(
                    for: entry.id, quantization: quantization
                )
                // The progress callback is @Sendable and fires off-actor, so it must not
                // capture the observable task object directly — only the key.
                let files = try await downloader.download(resolution, to: destination) {
                    [weak self] progress in
                    Task { @MainActor in self?.downloads[key]?.progress = progress }
                }
                let projector = resolution.projector.map { file in
                    destination.appendingPathComponent((file.path as NSString).lastPathComponent)
                }
                // The projector is downloaded alongside the weights, so exclude it from the
                // weights list the runtime is handed.
                let weights = files.filter { $0 != projector }
                _ = try await self.library.register(
                    entry: entry, quantization: quantization,
                    files: weights, projector: projector
                )
                download.isFinished = true
                await self.refreshLibrary()
                self.downloads[key] = nil
            } catch is CancellationError {
                self.downloads[key] = nil
            } catch {
                download.error = error.localizedDescription
            }
        }
    }

    public func cancelInstall(_ key: String) {
        downloads[key]?.task?.cancel()
        downloads[key] = nil
    }

    public func uninstall(_ model: InstalledModel) {
        Task {
            if loadedModel?.id == model.id { await unload() }
            try? await library.remove(id: model.id)
            await refreshLibrary()
        }
    }

    // MARK: - Loading

    public func load(_ model: InstalledModel, configuration: LoadConfiguration? = nil) {
        Task { await loadAsync(model, configuration: configuration) }
    }

    public func loadAsync(_ model: InstalledModel, configuration: LoadConfiguration? = nil) async {
        await unload()
        noteActivity()

        let resolved = configuration ?? defaultConfiguration(for: model)

        do {
            let selection = try selector.select(model: model, configuration: resolved)
            let runtime = selector.makeRuntime(for: selection)
            self.runtime = runtime

            // Bridge the actor's state changes onto the main actor for SwiftUI.
            if let llama = runtime as? LlamaCppRuntime {
                await llama.observeState { [weak self] state in
                    Task { @MainActor in self?.runtimeState = state }
                }
            } else if let mlx = runtime as? MLXRuntime {
                await mlx.observeState { [weak self] state in
                    Task { @MainActor in self?.runtimeState = state }
                }
            }

            try await runtime.start(LoadRequest(model: model, configuration: resolved))
            loadedModel = model
            activeConfiguration = resolved
        } catch {
            runtimeState = .failed(message: error.localizedDescription)
            alert = AlertContent(
                title: "Could not load \(model.name)",
                message: error.localizedDescription
            )
            if let llama = runtime as? LlamaCppRuntime {
                runtimeLog = await llama.serverLog()
            }
            runtime = nil
        }
    }

    public func unload() async {
        guard let runtime else { return }
        await runtime.stop()
        self.runtime = nil
        loadedModel = nil
        activeConfiguration = nil
        runtimeState = .idle
    }

    /// The settings the app would choose for this model on this machine.
    public func defaultConfiguration(for model: InstalledModel) -> LoadConfiguration {
        guard let shape = model.shape else {
            return LoadConfiguration(threads: profile.performanceCores)
        }
        if let catalogID = model.catalogID, let entry = ModelCatalog.entry(id: catalogID),
           let recommendation = autoConfigurator().best(
               for: entry, otherAppsInUse: memoryUsedByOtherApps
           ), recommendation.quantization == model.quantization {
            return recommendation.configuration
        }

        // Fall back to walking the context ladder directly for imported models the catalog has
        // never heard of.
        let planner = planner()
        for context in [32_768, 16_384, 8192, 4096] {
            let candidate = LoadConfiguration(
                contextLength: min(context, shape.trainingContextLength),
                kvCachePrecision: .f16, flashAttention: true,
                threads: profile.performanceCores
            )
            let plan = planner.plan(
                shape: shape, quantization: model.quantization,
                configuration: candidate, otherAppsInUse: memoryUsedByOtherApps
            )
            if plan.verdict == .comfortable { return candidate }
        }
        return LoadConfiguration(
            contextLength: 4096, kvCachePrecision: .q8_0, flashAttention: true,
            threads: profile.performanceCores
        )
    }

    public func rediscoverRuntimes() {
        RuntimeLocator.customPaths = settings.customRuntimePaths
        selector = RuntimeSelector.discover()
    }

    /// The exact command the app would run for the current model, shown in Advanced mode so a
    /// power user can reproduce or report it.
    public var currentLaunchCommand: String? {
        guard let model = loadedModel, let configuration = activeConfiguration,
              let installation = selector.available[.llamaCpp], model.format == .gguf
        else { return nil }
        return LlamaArguments(
            model: model, configuration: configuration, port: 8080, installation: installation
        ).displayCommand(executable: installation.executable)
    }

    // MARK: - Chat

    public var selectedConversation: Conversation? {
        get { conversations.first { $0.id == selectedConversationID } }
        set {
            guard let newValue, let index = conversations.firstIndex(where: { $0.id == newValue.id })
            else { return }
            conversations[index] = newValue
        }
    }

    public func newConversation() {
        let conversation = Conversation()
        conversations.insert(conversation, at: 0)
        selectedConversationID = conversation.id
    }

    public func deleteConversation(_ id: Conversation.ID) {
        conversations.removeAll { $0.id == id }
        if selectedConversationID == id { selectedConversationID = conversations.first?.id }
    }

    private var generationTask: Task<Void, Never>?

    public var isGenerating: Bool { generationTask != nil }

    public func send(_ text: String, images: [String] = []) {
        guard let runtime, runtimeState.isRunning else {
            alert = AlertContent(
                title: "No model loaded",
                message: "Load a model from the Models tab before starting a conversation."
            )
            return
        }
        guard let index = conversations.firstIndex(where: { $0.id == selectedConversationID })
        else { return }
        noteActivity()

        conversations[index].messages.append(
            ChatMessage(role: .user, content: text, images: images)
        )
        let reply = ChatMessage(role: .assistant, content: "")
        conversations[index].messages.append(reply)
        let replyID = reply.id

        if conversations[index].title == Conversation.untitled {
            conversations[index].title = String(text.prefix(60))
        }

        let request = ChatRequest(
            messages: conversations[index].messages.dropLast().map { $0 },
            temperature: settings.temperature,
            topP: settings.topP,
            maxTokens: settings.maxTokens > 0 ? settings.maxTokens : nil,
            reasoningEffort: settings.reasoningEffort.isEmpty ? nil : settings.reasoningEffort
        )

        generationTask = Task { [weak self] in
            defer { Task { @MainActor in self?.generationTask = nil } }
            do {
                let stream = try await runtime.chat(request)
                for try await event in stream {
                    guard let self else { return }
                    switch event {
                    case .token(let token):
                        self.append(token, toMessage: replyID, reasoning: false)
                    case .reasoningToken(let token):
                        self.append(token, toMessage: replyID, reasoning: true)
                    case .finished(let metrics):
                        self.lastGeneration = metrics
                    }
                }
            } catch is CancellationError {
                // Stopping mid-stream is a normal user action, not an error.
            } catch {
                guard let self else { return }
                self.append(
                    "\n\n_Generation failed: \(error.localizedDescription)_",
                    toMessage: replyID, reasoning: false
                )
            }
        }
    }

    private func append(_ token: String, toMessage id: UUID, reasoning: Bool) {
        guard let conversationIndex = conversations.firstIndex(
            where: { $0.id == selectedConversationID }
        ), let messageIndex = conversations[conversationIndex].messages.firstIndex(
            where: { $0.id == id }
        ) else { return }

        if reasoning {
            conversations[conversationIndex].messages[messageIndex].reasoning =
                (conversations[conversationIndex].messages[messageIndex].reasoning ?? "") + token
        } else {
            conversations[conversationIndex].messages[messageIndex].content += token
        }
    }

    public func stopGenerating() {
        generationTask?.cancel()
        generationTask = nil
    }

    public func regenerate() {
        guard let index = conversations.firstIndex(where: { $0.id == selectedConversationID }),
              let lastUser = conversations[index].messages.last(where: { $0.role == .user })
        else { return }

        // Drop the previous answer and everything after the prompt we are re-running.
        if let userIndex = conversations[index].messages.firstIndex(where: { $0.id == lastUser.id }) {
            conversations[index].messages.removeSubrange(userIndex...)
        }
        send(lastUser.content, images: lastUser.images)
    }
}

/// A saved conversation.
public struct Conversation: Identifiable, Hashable, Codable, Sendable {
    public static let untitled = "New Conversation"

    public var id = UUID()
    public var title = Conversation.untitled
    public var messages: [ChatMessage] = []
    public var isPinned = false
    public var createdAt = Date()

    public init() {}
}
