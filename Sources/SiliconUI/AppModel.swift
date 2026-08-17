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

    public internal(set) var profile: SystemProfile
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

    /// User-supplied llama.cpp flags from Advanced mode, applied to the next load.
    public private(set) var extraArguments: [String] = []

    public func setExtraArguments(_ line: String) {
        extraArguments = LlamaArguments.split(line)
    }

    /// The live runtime, for the control API to send prompts through.
    var activeRuntime: (any InferenceRuntime)? { runtime }

    // MARK: - Chat

    public var conversations: [Conversation] = [] {
        didSet { scheduleConversationSave() }
    }
    public var folders: [ConversationFolder] = [] {
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
        case images = "Images"
        case settings = "Settings"

        public var id: String { rawValue }

        public var systemImage: String {
            switch self {
            case .dashboard: "gauge.with.dots.needle.67percent"
            case .models: "square.stack.3d.up"
            case .chat: "bubble.left.and.bubble.right"
            case .images: "photo.on.rectangle.angled"
            case .settings: "gearshape"
            }
        }
    }

    public struct AlertContent: Identifiable {
        public let id = UUID()
        public var title: String
        public var message: String
    }

    // MARK: - Image generation

    public internal(set) var imageRuntime: RuntimeInstallation?
    public internal(set) var imageState: RuntimeState = .idle
    public internal(set) var lastImage: ImageResult?
    /// Set when an image had to be written somewhere other than the configured directory.
    public internal(set) var imageOutputWarning: String?
    public internal(set) var imageProgress: (step: Int, total: Int)?
    public var imagePrompt = ""
    public var imageConfiguration = ImageConfiguration()
    /// Switching model adopts that model's step count.
    ///
    /// These are not interchangeable numbers: schnell is distilled to finish in 4 steps and klein
    /// expects 8, so carrying a step count across a model switch quietly produces a worse image
    /// than the model is capable of. An explicit change to the stepper still stands until the
    /// next switch.
    ///
    /// Defaults to klein-4B rather than schnell: schnell is gated on Hugging Face and peaks at
    /// around 35 GB at 1024x1024, so it is the wrong thing to greet anyone with.
    public var selectedDiffusionModel: String = DiffusionCatalog.flux2Klein4B.id {
        didSet {
            guard selectedDiffusionModel != oldValue,
                  let entry = DiffusionCatalog.entry(id: selectedDiffusionModel) else { return }
            imageConfiguration.steps = entry.shape.defaultSteps
        }
    }

    private var imageTask: Task<Void, Never>?

    public var isGeneratingImage: Bool { imageTask != nil }

    // MARK: - Image model installation

    @Observable
    public final class ImageDownloadTask: Identifiable {
        public let id: String
        public var entry: DiffusionEntry
        public var progress: ModelDownloader.Progress?
        public var error: String?
        var task: Task<Void, Never>?

        init(entry: DiffusionEntry) {
            self.id = entry.id
            self.entry = entry
        }
    }

    public private(set) var imageDownloads: [String: ImageDownloadTask] = [:]
    /// Bumped when an install finishes, to re-run the installed checks, which hit the filesystem.
    public private(set) var imageLibraryVersion = 0

    public func isImageModelInstalled(_ entry: DiffusionEntry) -> Bool {
        _ = imageLibraryVersion
        return DiffusionInstaller.isInstalled(entry)
    }

    public func installedImageModelSize(_ entry: DiffusionEntry) -> Bytes {
        _ = imageLibraryVersion
        return DiffusionInstaller.installedSize(entry.repository)
    }

    private func imageInstaller() -> DiffusionInstaller? {
        guard let mflux = (imageRuntime ?? MFluxRuntime.locate())?.executable,
              let hf = DiffusionInstaller.locate(besideMFlux: mflux) else { return nil }
        let token = settings.huggingFaceToken.isEmpty ? nil : settings.huggingFaceToken
        return DiffusionInstaller(executable: hf, token: token)
    }

    public func installImageModel(_ entry: DiffusionEntry) {
        guard imageDownloads[entry.id] == nil else { return }
        guard let installer = imageInstaller() else {
            alert = AlertContent(
                title: "Cannot download image models",
                message: DiffusionInstaller.InstallError.toolMissing.localizedDescription
            )
            return
        }

        let download = ImageDownloadTask(entry: entry)
        imageDownloads[entry.id] = download

        download.task = Task { [weak self] in
            do {
                try await installer.download(entry) { progress in
                    Task { @MainActor in self?.imageDownloads[entry.id]?.progress = progress }
                }
                guard let self else { return }
                self.imageLibraryVersion += 1
                self.imageDownloads[entry.id] = nil
            } catch is CancellationError {
                self?.imageDownloads[entry.id] = nil
            } catch {
                self?.imageDownloads[entry.id]?.error = error.localizedDescription
            }
        }
    }

    public func cancelImageInstall(_ id: String) {
        imageDownloads[id]?.task?.cancel()
        imageDownloads[id] = nil
    }

    public func uninstallImageModel(_ entry: DiffusionEntry) {
        let directory = DiffusionInstaller.cacheDirectory(for: entry.repository)
        try? FileManager.default.removeItem(at: directory)
        imageLibraryVersion += 1
    }

    public func diffusionPlanner() -> DiffusionPlanner { DiffusionPlanner(profile: profile) }

    /// A path for the next generated image, inside the user's configured output directory.
    ///
    /// Falls back to the temporary directory if that directory cannot be created — an external
    /// volume that is no longer mounted, say. Throwing away an image that has already cost
    /// minutes of compute because a folder is missing would be the worse failure, so the run
    /// proceeds and `imageOutputWarning` explains where the file actually went.
    func nextImageOutputURL() -> URL {
        let directory = settings.resolvedImageOutputDirectory
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            imageOutputWarning = nil
            return directory.appendingPathComponent(Settings.imageFilename())
        } catch {
            imageOutputWarning =
                "Could not write to \(directory.path) — saving to the temporary folder instead. "
                + "Check the output directory in Settings."
            return FileManager.default.temporaryDirectory
                .appendingPathComponent(Settings.imageFilename())
        }
    }

    public func diffusionPlan(
        for entry: DiffusionEntry, configuration: ImageConfiguration
    ) -> DiffusionPlan {
        // Whether a quantized copy can be read back is a fact about the model family, not
        // something the caller should have to remember to set, so it is filled in here — every
        // plan in the app goes through this method.
        var configuration = configuration
        configuration.canReuseQuantizedSave = entry.supportsQuantizedReuse
        return diffusionPlanner().plan(
            shape: entry.shape, configuration: configuration,
            otherAppsInUse: memoryUnavailableDuringImage
        )
    }

    /// The best image configuration this Mac can run for a given model — same idea as the
    /// language recommendation, walking down resolution and precision until it fits.
    public func recommendedImageConfiguration(for entry: DiffusionEntry) -> ImageConfiguration {
        let planner = diffusionPlanner()
        for quantization in entry.quantizations.reversed() {
            for side in [entry.shape.nativeResolution, 768, 512] {
                let candidate = ImageConfiguration(
                    width: side, height: side,
                    steps: entry.shape.defaultSteps, quantization: quantization
                )
                if planner.plan(
                    shape: entry.shape, configuration: candidate,
                    otherAppsInUse: memoryUnavailableDuringImage
                ).verdict == .comfortable {
                    return candidate
                }
            }
        }
        // Nothing fit outright; fall back to the cheapest thing that runs at all. Low-memory
        // mode is on here not because it lowers the peak — it does not — but because at this
        // point the machine is tight enough that freeing between images is worth having.
        return ImageConfiguration(
            width: 512, height: 512, steps: entry.shape.defaultSteps,
            quantization: .mlx4, lowRAM: true
        )
    }

    public func generateImage() {
        guard !isGeneratingImage,
              let entry = DiffusionCatalog.entry(id: selectedDiffusionModel),
              !imagePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }

        // Warn rather than refuse: the estimate is not always right, and a hard block leaves
        // someone unable to run a model that would in fact work, with no way to proceed.
        let plan = diffusionPlan(for: entry, configuration: imageConfiguration)
        if !plan.verdict.isUsable {
            alert = AlertContent(
                title: "This may not fit in memory",
                message: refusalMessage(for: entry, plan: plan)
            )
        }

        noteActivity()
        let output = nextImageOutputURL()
        // Diffusion runs as a standalone process, so an InstalledModel is only a carrier for
        // the catalog id the runtime maps to its own alias.
        let carrier = InstalledModel(
            id: entry.id, name: entry.name, catalogID: entry.id,
            quantization: imageConfiguration.quantization, format: .mlx,
            primaryFile: output, allFiles: [], projectorFile: nil,
            sizeOnDisk: .zero, installedAt: Date(), shape: nil, capabilities: []
        )
        let request = ImageRequest(
            prompt: imagePrompt, configuration: imageConfiguration,
            seed: nil, output: output
        )

        imageState = .starting(stage: "Starting MFLUX…")
        imageProgress = nil
        let runtime = MFluxRuntime(
            installation: imageRuntime, huggingFaceToken: settings.huggingFaceToken
        )

        imageTask = Task { [weak self] in
            defer { Task { @MainActor in self?.imageTask = nil } }
            do {
                for try await event in try await runtime.generate(request, model: carrier) {
                    guard let self else { return }
                    switch event {
                    case .stage(let stage):
                        imageState = .starting(stage: stage)
                    case .step(let index, let total):
                        imageProgress = (index, total)
                        imageState = .starting(stage: "Denoising \(index)/\(total)…")
                    case .finished(let result):
                        lastImage = result
                        imageProgress = nil
                        imageState = .idle
                    }
                }
            } catch {
                guard let self else { return }
                imageState = .failed(message: error.localizedDescription)
                alert = AlertContent(
                    title: "Could not generate the image", message: error.localizedDescription
                )
            }
        }
    }

    /// Explains a refusal, naming the loaded language model when that is the thing in the way.
    ///
    /// "Won't fit" is useless on its own when the fix is one button away in another tab.
    func refusalMessage(for entry: DiffusionEntry, plan: DiffusionPlan) -> String {
        var message = "\(entry.name) would peak at \(plan.peak.formatted) during "
            + "\(plan.peakPhase?.name.lowercased() ?? "generation"), against a "
            + "\(plan.budget.formatted) budget."
        let reclaimable = memoryReclaimableByUnloading
        if let loaded = loadedModel, reclaimable > .zero {
            message += " \(loaded.name) is loaded and holding about \(reclaimable.formatted); "
                + "unloading it would give that back."
        } else if let first = plan.remediations.first {
            message += " Try: \(first.title)."
        }
        return message
    }

    /// Free the language model, then generate. One action, because they are one intention.
    public func unloadAndGenerateImage() {
        Task { [weak self] in
            await self?.unload()
            self?.generateImage()
        }
    }

    public func cancelImage() {
        imageTask?.cancel()
        imageTask = nil
        imageState = .idle
        imageProgress = nil
    }

    /// Automatic updates. Created lazily because instantiating Sparkle starts its scheduler.
    public let updates = UpdateController()

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
        imageRuntime = MFluxRuntime.locate()
        RuntimeLocator.customPaths = settings.customRuntimePaths

        beginSampling()
        startControlServer()
        measureStorageIfNeeded()

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

    // MARK: - Storage speed

    public private(set) var isMeasuringStorage = false

    /// Measures the library volume's read throughput, once, and caches it.
    ///
    /// This is not cosmetic. Three separate decisions read `ssdReadMBps`: whether to offer
    /// expert streaming at all, how fast a streamed model will generate, and whether to warn
    /// that the volume is too slow for it. With no measurement they all fall back to assuming
    /// a fast internal SSD, so a model library on a slow external disk would be told expert
    /// streaming is a good idea when it is not.
    func measureStorageIfNeeded(force: Bool = false) {
        let volume = Self.volumeIdentifier(for: ModelLibrary.defaultRoot)

        if !force,
           let cached = settings.measuredSSDReadMBps,
           settings.measuredSSDVolumeID == volume {
            profile.ssdReadMBps = cached
            return
        }
        guard !isMeasuringStorage else { return }
        isMeasuringStorage = true

        Task { [weak self] in
            defer { Task { @MainActor in self?.isMeasuringStorage = false } }
            let directory = ModelLibrary.defaultRoot
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            // Deliberately small. This runs unprompted on first launch, and a quarter of a
            // gigabyte is enough to separate an internal SSD from a USB enclosure.
            guard let result = try? await StorageBenchmark().run(in: directory, sizeMB: 128)
            else { return }

            guard let self else { return }
            self.profile.ssdReadMBps = result.readMBps
            self.settings.measuredSSDReadMBps = result.readMBps
            self.settings.measuredSSDVolumeID = volume
            self.settings.save()
        }
    }

    /// Identifies the volume a path lives on, so a library moved to another disk is re-measured.
    private static func volumeIdentifier(for url: URL) -> String? {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path),
              probe.pathComponents.count > 1 {
            probe = probe.deletingLastPathComponent()
        }
        let values = try? probe.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeNameKey])
        return values?.volumeUUIDString ?? values?.volumeName
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

        if let archive = try? decoder.decode(ChatArchive.self, from: data) {
            folders = archive.folders
            conversations = archive.conversations
        } else if let legacy = try? decoder.decode([Conversation].self, from: data) {
            // Histories written before folders existed were a bare array. Read them rather
            // than silently starting someone over with an empty sidebar.
            conversations = legacy
        }
        selectedConversationID = conversations.first?.id
    }

    /// Debounced: `conversations` mutates on every streamed token, and writing the whole
    /// transcript to disk that often would peg a core during generation.
    private func scheduleConversationSave() {
        guard !isLoadingConversations else { return }
        conversationSaveTask?.cancel()
        let snapshot = ChatArchive(folders: folders, conversations: conversations)
        conversationSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, self != nil else { return }
            await Self.writeConversations(snapshot)
        }
    }

    private static func writeConversations(_ archive: ChatArchive) async {
        // Resolved on the main actor before hopping off it.
        let url = conversationsURL
        await Task.detached(priority: .background) {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(archive) else { return }
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

    /// Wired memory that will *still* be held while an image is generated.
    ///
    /// The difference from `memoryUsedByOtherApps` is the loaded language model. Loading a
    /// language model replaces whatever was there, so the planner excludes the current one from
    /// its own budget. Generating an image does not replace anything — llama-server keeps its
    /// weights the whole time — so the loaded model has to be charged against the image.
    ///
    /// Getting this wrong is not a rounding error: a 20 GB model and a 19 GB image run were both
    /// called comfortable on a 38 GB machine, and the machine ran out of memory.
    public var memoryUnavailableDuringImage: Bytes { metrics.memoryWired }

    /// What unloading the current model would give back to an image run.
    public var memoryReclaimableByUnloading: Bytes {
        loadedModel != nil ? estimatedResidentBytes : .zero
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

    // MARK: - Hugging Face search

    public private(set) var remoteResults: [HuggingFaceClient.SearchResult] = []
    public private(set) var isSearchingRemote = false
    public private(set) var remoteSearchError: String?
    /// The query the current results belong to. Nil means nothing has been searched yet, which
    /// is not the same as a search that came back empty — saying "nothing found" before asking
    /// is just wrong.
    public private(set) var completedRemoteQuery: String?

    private var remoteSearchTask: Task<Void, Never>?

    /// Searches Hugging Face for GGUF repositories.
    ///
    /// The bundled catalog is 17 models chosen for Apple Silicon; this is the escape hatch for
    /// everything else. Debounced, because it fires from a text field.
    public func searchHuggingFace(_ query: String) {
        remoteSearchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            remoteResults = []
            isSearchingRemote = false
            remoteSearchError = nil
            completedRemoteQuery = nil
            return
        }

        isSearchingRemote = true
        remoteSearchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self else { return }
            defer { isSearchingRemote = false }
            do {
                let token = settings.huggingFaceToken.isEmpty ? nil : settings.huggingFaceToken
                let results = try await HuggingFaceClient(token: token).search(query: trimmed)
                guard !Task.isCancelled else { return }
                remoteResults = results
                remoteSearchError = nil
                completedRemoteQuery = trimmed
            } catch {
                guard !Task.isCancelled else { return }
                remoteResults = []
                remoteSearchError = error.localizedDescription
                completedRemoteQuery = trimmed
            }
        }
    }

    /// Builds a catalog entry for a repository the bundled catalog has never seen, so an
    /// arbitrary Hugging Face model flows through exactly the same install, planning and
    /// loading machinery as a curated one.
    public func makeEntry(
        repository: String,
        file: String,
        quantization: Quantization,
        size: Bytes,
        shape: ModelShape
    ) -> ModelEntry {
        let name = (repository.split(separator: "/").last).map(String.init) ?? repository
        return ModelEntry(
            id: "hf:\(repository)",
            name: name,
            author: repository.split(separator: "/").first.map(String.init) ?? "",
            license: "See the model card",
            summary: "From Hugging Face. Architecture read from the file itself.",
            category: shape.isMoE ? .general : .general,
            capabilities: [],
            format: .gguf,
            shape: shape,
            variants: [ModelVariant(
                quantization: quantization, repository: repository,
                filename: file, downloadSize: size
            )],
            rating: 0,
            maxContext: shape.trainingContextLength
        )
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

    // MARK: - Transfers

    /// Every download in flight, language models and image models alike.
    ///
    /// The places a download *starts* are not the places it can be watched. A catalog row shows
    /// progress underneath itself, which works until the model came from a Hugging Face search:
    /// there is no row for it, the sheet dismisses on tap, and several gigabytes then move with
    /// nothing on screen to say so. The sidebar reads this instead, so a transfer is visible
    /// wherever it was started from and whichever tab you are on.
    public struct ActiveTransfer: Identifiable, Sendable {
        public enum Kind: Sendable { case language, image }

        public var id: String
        public var name: String
        public var detail: String
        public var progress: ModelDownloader.Progress?
        public var error: String?
        public var kind: Kind
    }

    /// Sorted by name rather than by start time: the list is read at a glance while the numbers
    /// inside it are changing, and rows that reorder under the cursor are worse than rows that
    /// appear in an arbitrary but stable order.
    public var activeTransfers: [ActiveTransfer] {
        let language = downloads.values.map {
            ActiveTransfer(
                id: $0.id, name: $0.entry.name, detail: $0.quantization.rawValue,
                progress: $0.progress, error: $0.error, kind: .language
            )
        }
        let images = imageDownloads.values.map {
            ActiveTransfer(
                id: $0.id, name: $0.entry.name, detail: "Image model",
                progress: $0.progress, error: $0.error, kind: .image
            )
        }
        return (language + images).sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    /// Combined throughput across every transfer, which is what the machine is actually doing.
    public var transferBytesPerSecond: Double {
        activeTransfers.compactMap(\.progress?.bytesPerSecond).reduce(0, +)
    }

    public func cancelTransfer(_ transfer: ActiveTransfer) {
        switch transfer.kind {
        case .language: cancelInstall(transfer.id)
        case .image: cancelImageInstall(transfer.id)
        }
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

            try await runtime.start(LoadRequest(
                model: model, configuration: resolved, extraArguments: extraArguments
            ))
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
        imageRuntime = MFluxRuntime.locate()
    }

    /// The exact command the app would run for the current model, shown in Advanced mode so a
    /// power user can reproduce or report it.
    public var currentLaunchCommand: String? {
        guard let model = loadedModel, let configuration = activeConfiguration,
              let installation = selector.available[.llamaCpp], model.format == .gguf
        else { return nil }
        return LlamaArguments(
            model: model, configuration: configuration, port: 8080,
            installation: installation, extraArguments: extraArguments
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

    // MARK: - Folders

    @discardableResult
    public func createFolder(named name: String) -> ConversationFolder {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = ConversationFolder(name: trimmed.isEmpty ? "New Folder" : trimmed)
        folders.append(folder)
        return folder
    }

    public func renameFolder(_ id: ConversationFolder.ID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = folders.firstIndex(where: { $0.id == id })
        else { return }
        folders[index].name = trimmed
    }

    /// Removes a folder without removing what is in it — the conversations become unfiled.
    /// Deleting a container should never destroy the contents the user actually cares about.
    public func deleteFolder(_ id: ConversationFolder.ID) {
        for index in conversations.indices where conversations[index].folderID == id {
            conversations[index].folderID = nil
        }
        folders.removeAll { $0.id == id }
    }

    public func move(_ conversation: Conversation.ID, to folder: ConversationFolder.ID?) {
        guard let index = conversations.firstIndex(where: { $0.id == conversation }) else { return }
        conversations[index].folderID = folder
    }

    /// Conversations in a folder, or unfiled ones when `folder` is nil. Pinned conversations are
    /// excluded because they are listed separately at the top.
    public func conversations(in folder: ConversationFolder.ID?) -> [Conversation] {
        filteredConversations().filter { !$0.isPinned && $0.folderID == folder }
    }

    /// Folders worth drawing. While searching, a folder with no matches is hidden rather than
    /// left as an empty heading.
    public func visibleFolders() -> [ConversationFolder] {
        guard !conversationSearch.trimmingCharacters(in: .whitespaces).isEmpty else { return folders }
        return folders.filter { !conversations(in: $0.id).isEmpty }
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
    /// Folder this belongs to, or nil for unfiled.
    public var folderID: ConversationFolder.ID?

    public init() {}
}

/// A user-created group of conversations.
public struct ConversationFolder: Identifiable, Hashable, Codable, Sendable {
    public var id = UUID()
    public var name: String
    public var createdAt = Date()

    public init(name: String) { self.name = name }
}

/// What gets written to disk.
///
/// Versioned as a record rather than a bare array so folders could be added without orphaning
/// anyone's existing history — see `loadConversations` for the migration.
struct ChatArchive: Codable {
    var folders: [ConversationFolder] = []
    var conversations: [Conversation] = []
}
