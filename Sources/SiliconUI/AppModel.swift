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

    // MARK: - Harness chat

    /// State of the DeepSeek Harness sidecar that serves the agentic chat.
    public internal(set) var harnessState: RuntimeState = .idle
    var harnessRuntime: HarnessRuntime?
    /// Ports for this app session, resolved once from the persisted choice after checking it
    /// is still free — a crashed predecessor can leave a squatter on it.
    var resolvedHarnessPorts: (web: Int, inference: Int)?
    /// The harness process id, kept here so app termination can reach it synchronously.
    var harnessProcessID: Int32?
    var harnessTerminationRegistered = false

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
    /// Sidebar visibility for the main window, so the harness chat can take the whole
    /// window over and give it back.
    public var chatColumnVisibility: NavigationSplitViewVisibility = .all

    public enum Tab: String, CaseIterable, Identifiable, Hashable {
        case dashboard = "Dashboard"
        case models = "Models"
        case chat = "Chat"
        case images = "Images"
        case threeD = "3D"
        case settings = "Settings"

        public var id: String { rawValue }

        public var systemImage: String {
            switch self {
            case .dashboard: "gauge.with.dots.needle.67percent"
            case .models: "square.stack.3d.up"
            case .chat: "bubble.left.and.bubble.right"
            case .images: "photo.on.rectangle.angled"
            case .threeD: "cube.transparent"
            case .settings: "gearshape"
            }
        }
    }

    public struct AlertContent: Identifiable {
        public let id = UUID()
        public var title: String
        public var message: String
        /// When set, the alert offers this as a second button that opens `linkURL` —
        /// for errors whose fix lives on a web page, like a Hugging Face licence gate.
        public var linkTitle: String?
        public var linkURL: URL?
    }

    // MARK: - Image generation

    public internal(set) var imageRuntime: RuntimeInstallation?
    public internal(set) var imageState: RuntimeState = .idle
    /// Every image generated this session, newest first. Nothing is pruned — each one is already
    /// on disk in the configured output directory, so keeping the in-memory list around too is
    /// just what makes the gallery scrollable instead of showing only the latest.
    public internal(set) var generatedImages: [ImageResult] = []
    /// Set when an image had to be written somewhere other than the configured directory.
    public internal(set) var imageOutputWarning: String?
    public internal(set) var imageProgress: (step: Int, total: Int)?
    public var imagePrompt = ""
    public var imageConfiguration = ImageConfiguration()

    /// One prompt submitted for generation, either running now or waiting its turn.
    ///
    /// Captured at submit time rather than read live off `imagePrompt`/`imageConfiguration`, so
    /// editing the composer to queue up the next image does not retroactively change a job that
    /// is already queued or running.
    public struct ImageJob: Identifiable {
        public let id = UUID()
        public var prompt: String
        public var configuration: ImageConfiguration
        public var modelID: String
        public var modelName: String
    }

    /// Jobs waiting for the current generation to finish. Only one MFLUX process runs at a time —
    /// concurrent runs would fight over the same memory budget the plan is checked against.
    public internal(set) var imageQueue: [ImageJob] = []
    public internal(set) var currentImageJob: ImageJob?
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
    /// The runtime actually running `currentImageJob`, kept so `cancelImage()` can terminate the
    /// child process rather than merely stop listening to it — otherwise a stopped job's mflux
    /// process would keep running unseen while the next queued job starts a second one alongside
    /// it, fighting over the same memory budget.
    private var activeImageRuntime: MFluxRuntime?
    private var imageWasCancelled = false

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
                // The gated case gets the token-aware guidance instead of the generic
                // "add a token" — which is wrong advice for anyone who already has one.
                if case DiffusionInstaller.InstallError.accessDenied = error, let self {
                    self.imageDownloads[entry.id]?.error = self.gatedGuidance(for: entry)
                } else {
                    self?.imageDownloads[entry.id]?.error = error.localizedDescription
                }
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

    /// Queues the composer's current prompt. Starts immediately if nothing else is running;
    /// otherwise waits behind whatever is already queued, so a second and third idea can be
    /// typed in while the first is still rendering instead of waiting for it to finish.
    public func generateImage() {
        guard let entry = DiffusionCatalog.entry(id: selectedDiffusionModel),
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

        imageQueue.append(ImageJob(
            prompt: imagePrompt, configuration: imageConfiguration,
            modelID: entry.id, modelName: entry.name
        ))
        imagePrompt = ""
        advanceImageQueue()
    }

    /// Removes one job that has not started running yet. The one already in flight cannot be
    /// removed this way — use `cancelImage()` for that.
    public func removeQueuedImageJob(_ id: ImageJob.ID) {
        imageQueue.removeAll { $0.id == id }
    }

    public func clearImageQueue() {
        imageQueue.removeAll()
    }

    /// Starts the next queued job if nothing is running. Called after a job finishes, fails, or
    /// is cancelled, and after `generateImage()` queues a new one.
    private func advanceImageQueue() {
        guard !isGeneratingImage, !imageQueue.isEmpty else { return }
        let job = imageQueue.removeFirst()
        currentImageJob = job
        runImageJob(job)
    }

    private func runImageJob(_ job: ImageJob) {
        noteActivity()
        let output = nextImageOutputURL()
        // Diffusion runs as a standalone process, so an InstalledModel is only a carrier for
        // the catalog id the runtime maps to its own alias.
        let carrier = InstalledModel(
            id: job.modelID, name: job.modelName, catalogID: job.modelID,
            quantization: job.configuration.quantization, format: .mlx,
            primaryFile: output, allFiles: [], projectorFile: nil,
            sizeOnDisk: .zero, installedAt: Date(), shape: nil, capabilities: []
        )
        let request = ImageRequest(
            prompt: job.prompt, configuration: job.configuration,
            seed: nil, output: output
        )

        imageState = .starting(stage: "Starting MFLUX…")
        imageProgress = nil
        imageWasCancelled = false
        let runtime = MFluxRuntime(
            installation: imageRuntime, huggingFaceToken: settings.huggingFaceToken
        )
        activeImageRuntime = runtime

        imageTask = Task { [weak self] in
            defer {
                Task { @MainActor in
                    guard let self else { return }
                    self.imageTask = nil
                    self.activeImageRuntime = nil
                    self.currentImageJob = nil
                    self.advanceImageQueue()
                }
            }
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
                        generatedImages.insert(result, at: 0)
                        imageProgress = nil
                        imageState = .idle
                        if routeNextImageToMesh {
                            routeNextImageToMesh = false
                            meshInputImage = result.image
                            // The 3D flow sets revision state per click; leaving it set
                            // would quietly turn the Images tab into revision mode too.
                            imageConfiguration.initImage = nil
                        }
                    }
                }
            } catch {
                guard let self else { return }
                // A user-requested stop tears down the process the same way a real failure does
                // — terminating it makes mflux exit non-zero — so it lands in this catch block
                // too. Report it as idle rather than as a failure the user didn't cause.
                if imageWasCancelled {
                    imageState = .idle
                } else if case ImageRuntimeError.gated = error,
                          let entry = DiffusionCatalog.entry(id: job.modelID) {
                    // The fix is on a web page, so the alert must carry the way there —
                    // "accept the licence" with no model name and no link helps nobody.
                    imageState = .failed(
                        message: "\(entry.name) needs its licence accepted on Hugging Face."
                    )
                    alert = AlertContent(
                        title: "\(entry.name) needs a licence agreement",
                        message: gatedGuidance(for: entry),
                        linkTitle: "Open licence page",
                        linkURL: Self.licenceURL(for: entry.repository)
                    )
                } else {
                    imageState = .failed(message: error.localizedDescription)
                    alert = AlertContent(
                        title: "Could not generate \"\(job.prompt)\"",
                        message: error.localizedDescription
                    )
                }
                imageWasCancelled = false
            }
        }
    }

    /// Gated-model guidance that respects what is already done: telling someone to add a
    /// token they already added sends them hunting in the wrong place, so the message
    /// changes depending on whether Settings holds one.
    public func gatedGuidance(for entry: DiffusionEntry) -> String {
        let base = "\(entry.name) is gated on Hugging Face (\(entry.repository)). "
            + "Open the licence page, sign in, and accept or request access."
        if settings.huggingFaceToken.isEmpty {
            return base + " Then add your access token in Settings → Credentials and "
                + "try again."
        }
        return base + " Your access token is already in Settings, so the licence is the "
            + "only missing step — then try again."
    }

    public static func licenceURL(for repository: String) -> URL? {
        URL(string: "https://huggingface.co/\(repository)")
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

    /// Stops the job in flight and moves on to the next queued one, if any — stopping one job
    /// is not a reason to also give up on the rest of the queue.
    /// Stops the job in flight and moves on to the next queued one, if any — stopping one job is
    /// not a reason to also give up on the rest of the queue.
    ///
    /// Waits for the mflux process to actually exit before starting the next job: `imageTask`,
    /// `activeImageRuntime` and the queue advance all stay untouched here and are cleared by the
    /// running task's own completion once `runtime.cancel()` below has made that happen. Clearing
    /// them immediately instead would let a second process start while the first was still being
    /// torn down — two runs fighting over the same memory budget, which is exactly what the plan
    /// this app shows before every run is trying to prevent.
    public func cancelImage() {
        guard let runtime = activeImageRuntime else { return }
        imageWasCancelled = true
        imageTask?.cancel()
        imageState = .starting(stage: "Stopping…")
        Task { await runtime.cancel() }
    }

    // MARK: - 3D generation

    public internal(set) var meshState: RuntimeState = .idle
    /// Every mesh generated this session, newest first. Like images, each is already on disk.
    public internal(set) var meshResults: [MeshResult] = []
    /// Fractional progress when the backend reports one.
    public internal(set) var meshProgress: Double?
    /// The image the composer will generate from.
    public var meshInputImage: URL?
    public var meshConfiguration = MeshConfiguration()

    /// Same capture-at-submit reasoning as `ImageJob`.
    public struct MeshJob: Identifiable {
        public let id = UUID()
        public var image: URL
        public var configuration: MeshConfiguration
        public var modelID: String
        public var modelName: String
    }

    public internal(set) var meshQueue: [MeshJob] = []
    public internal(set) var currentMeshJob: MeshJob?

    /// Defaults to Hunyuan mini: it is installed, fast, and greets a first try with a result
    /// in under a minute rather than a 13 GB download.
    public var selectedMeshModel: String = MeshCatalog.hunyuanMini.id {
        didSet {
            guard selectedMeshModel != oldValue,
                  let entry = MeshCatalog.entry(id: selectedMeshModel) else { return }
            meshConfiguration.steps = entry.defaultSteps
        }
    }

    private var meshTask: Task<Void, Never>?
    private var activeMeshRuntime: (any MeshRuntime)?
    private var meshWasCancelled = false
    /// Bumped to re-run the filesystem install probes.
    public private(set) var meshLibraryVersion = 0

    public var isGeneratingMesh: Bool { meshTask != nil }

    public func refreshMeshInstallations() { meshLibraryVersion += 1 }

    static func hunyuanWeightsSlot(for entryID: String) -> String {
        entryID == MeshCatalog.hunyuanTurbo.id ? "shape-large" : "shape-small"
    }

    /// Whether a backend can run right now, and why not when it cannot.
    public func meshInstallation(for entry: MeshEntry) -> MeshInstallation {
        _ = meshLibraryVersion
        let base = settings.resolvedTrellisBaseDirectory
        switch entry.backend {
        case .trellis:
            return MeshLocator.trellis(base: base)
        case .hunyuan:
            return MeshLocator.hunyuan(
                base: base, weightsSlot: Self.hunyuanWeightsSlot(for: entry.id)
            )
        case .latoRemote:
            let configured = settings.lato2ServiceURL
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !configured.isEmpty, URL(string: configured) != nil else {
                return MeshInstallation(
                    isInstalled: false,
                    missing: .serviceURL,
                    detail: entry.setupHint
                        ?? "Paste its service address in Settings → 3D toolkit."
                )
            }
            // "Configured" is all this can honestly say — the banner's live probe answers
            // whether the service is actually there. Claiming "connected" from a typed-in
            // URL once sent someone hunting a server that was fine.
            return MeshInstallation(
                isInstalled: true,
                detail: "Will send jobs to \(configured)."
            )
        case .unsupported:
            return MeshInstallation(
                isInstalled: false,
                missing: .unsupported,
                detail: entry.setupHint ?? "Not available yet."
            )
        }
    }

    // MARK: - 3D weights installation

    @Observable
    public final class MeshDownloadTask: Identifiable {
        public let id: String
        public var entry: MeshEntry
        public var progress: ModelDownloader.Progress?
        public var error: String?
        var task: Task<Void, Never>?

        init(entry: MeshEntry) {
            self.id = entry.id
            self.entry = entry
        }
    }

    public private(set) var meshDownloads: [String: MeshDownloadTask] = [:]

    /// The one-click fix when a backend's `missing` is `.weights`.
    public func meshWeightsDownload(for entry: MeshEntry) -> MeshInstaller.Download? {
        let base = settings.resolvedTrellisBaseDirectory
        switch entry.backend {
        case .trellis:
            return MeshInstaller.Download(
                repository: "microsoft/TRELLIS.2-4B",
                destination: .hubCache,
                expectedSize: entry.weightsSize
            )
        case .hunyuan:
            let slot = Self.hunyuanWeightsSlot(for: entry.id)
            let repository = entry.id == MeshCatalog.hunyuanTurbo.id
                ? "zimengxiong/hunyuan3d-mlx-shape-large"
                : "zimengxiong/hunyuan3d-mlx-shape-small"
            return MeshInstaller.Download(
                repository: repository,
                destination: .localDirectory(
                    base.appendingPathComponent("hunyuan3d-swift/weights/\(slot)")
                ),
                expectedSize: entry.weightsSize
            )
        case .latoRemote, .unsupported:
            return nil
        }
    }

    /// The `hf` CLI rides with MFLUX like image installs do, with the Homebrew copy as a
    /// fallback so 3D downloads still work on a machine without MFLUX.
    private func meshInstaller() -> MeshInstaller? {
        var hf: URL?
        if let mflux = (imageRuntime ?? MFluxRuntime.locate())?.executable {
            hf = DiffusionInstaller.locate(besideMFlux: mflux)
        }
        if hf == nil {
            let brew = URL(fileURLWithPath: "/opt/homebrew/bin/hf")
            if FileManager.default.isExecutableFile(atPath: brew.path) { hf = brew }
        }
        guard let hf else { return nil }
        let token = settings.huggingFaceToken.isEmpty ? nil : settings.huggingFaceToken
        return MeshInstaller(executable: hf, token: token)
    }

    public func installMeshWeights(_ entry: MeshEntry) {
        guard meshDownloads[entry.id] == nil,
              let download = meshWeightsDownload(for: entry) else { return }
        guard let installer = meshInstaller() else {
            alert = AlertContent(
                title: "Cannot download 3D models",
                message: MeshInstaller.InstallError.toolMissing.localizedDescription
            )
            return
        }

        let task = MeshDownloadTask(entry: entry)
        meshDownloads[entry.id] = task

        task.task = Task { [weak self] in
            do {
                try await installer.download(download) { progress in
                    Task { @MainActor in self?.meshDownloads[entry.id]?.progress = progress }
                }
                guard let self else { return }
                self.meshDownloads[entry.id] = nil
                self.refreshMeshInstallations()
            } catch is CancellationError {
                self?.meshDownloads[entry.id] = nil
            } catch {
                self?.meshDownloads[entry.id]?.error = error.localizedDescription
            }
        }
    }

    public func cancelMeshInstall(_ id: String) {
        meshDownloads[id]?.task?.cancel()
        meshDownloads[id] = nil
    }

    // MARK: - Swarm

    /// Whether the control server is currently reachable beyond loopback.
    public internal(set) var controlIsOnLAN = false

    /// One peer's last-polled state, for the dashboard's read-only swarm view.
    public struct PeerCapability: Identifiable, Sendable {
        public var id: String
        public var kind: String
        public var ready: Bool
        public var peakGB: Double?
        public var typicalSeconds: Double?
        public var detail: String?
    }

    public struct PeerStatus: Identifiable, Sendable {
        public var id: String { name }
        public var name: String
        public var baseURL: String
        public var reachable: Bool
        public var platform: String?
        /// "NVIDIA GeForce RTX 3090 Ti" on a CUDA node, "Apple M4 Pro" on a Mac.
        public var hardware: String?
        /// The card or machine's working memory: VRAM on a discrete GPU, unified
        /// memory on a Mac. Used/total tell the real story — a busy 24 GB card and
        /// a free 4 GB one advertise the same headroom.
        public var totalGB: Double?
        public var usedGB: Double?
        public var gpuUtil: Double?
        public var queueDepth: Int?
        public var headroomGB: Double?
        public var capabilities: [PeerCapability] = []
        public var latency: TimeInterval?
        public var error: String?

        public var readyCapabilities: [String] {
            capabilities.filter(\.ready).map(\.id)
        }
    }

    public private(set) var swarmPeers: [PeerStatus] = []
    public private(set) var isRefreshingSwarm = false

    public var swarmConfig: SwarmConfig? { SwarmConfig.load() }

    /// Applies swarm settings live: tears the control server down and brings it back with
    /// the new bind — the handshake file is rewritten, so local MCP clients reconnect on
    /// their next call.
    public func applySwarmSettings() {
        Task {
            await controlServer?.stop()
            startControlServer()
        }
    }

    /// Polls every registry peer's `/v1/node` — the read-only swarm. Parsed leniently:
    /// a peer that renames a field degrades to "reachable, details unknown", not a crash.
    public func refreshSwarm() async {
        guard let config = SwarmConfig.load(), !config.peers.isEmpty else {
            swarmPeers = []
            return
        }
        isRefreshingSwarm = true
        defer { isRefreshingSwarm = false }

        var statuses: [PeerStatus] = []
        for peer in config.peers {
            statuses.append(await Self.poll(peer: peer, token: config.effectiveToken))
        }
        swarmPeers = statuses.sorted {
            $0.name.localizedCompare($1.name) == .orderedAscending
        }
    }

    private nonisolated static func poll(peer: SwarmPeer, token: String?) async -> PeerStatus {
        var status = PeerStatus(name: peer.name, baseURL: peer.baseURL, reachable: false)
        guard let base = URL(string: peer.baseURL) else {
            status.error = "Not a valid URL."
            return status
        }
        var request = URLRequest(url: base.appendingPathComponent("v1/node"))
        request.timeoutInterval = 5
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

        let started = Date()
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else {
            status.error = "Unreachable."
            return status
        }
        guard (200..<300).contains(http.statusCode) else {
            status.error = "Answered \(http.statusCode)."
            return status
        }
        status.reachable = true
        status.latency = Date().timeIntervalSince(started)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return status }
        Self.parseNode(json, into: &status)
        return status
    }

    /// The lenient half of peer polling, separated from the network so the wire shapes
    /// both platforms actually send — a CUDA node names VRAM fields, a Mac names
    /// unified-memory ones — stay pinned by tests without a server.
    nonisolated static func parseNode(_ json: [String: Any], into status: inout PeerStatus) {
        status.platform = json["platform"] as? String
        if let profile = json["profile"] as? [String: Any] {
            status.hardware = profile["gpu"] as? String ?? profile["chip"] as? String
            status.totalGB = number(profile["vram_mb"]).map { $0 / 1024 }
                ?? number(profile["memory_gb"])
        }
        if let metrics = json["metrics"] as? [String: Any] {
            status.queueDepth = number(metrics["queue_depth"]).map { Int($0) }
            status.gpuUtil = number(metrics["gpu_util_pct"]).map { $0 / 100 }
            status.usedGB = number(metrics["vram_used_mb"]).map { $0 / 1024 }
            if status.usedGB == nil,
               let percent = number(metrics["memory_used_pct"]),
               let total = status.totalGB {
                status.usedGB = total * percent / 100
            }
            status.headroomGB = number(metrics["headroom_gb"])
                ?? number(metrics["vram_free_mb"]).map { $0 / 1024 }
            if status.headroomGB == nil,
               let total = status.totalGB, let used = status.usedGB {
                status.headroomGB = max(0, total - used)
            }
        }
        if let capabilities = json["capabilities"] as? [[String: Any]] {
            status.capabilities = capabilities.compactMap { entry in
                guard let id = entry["id"] as? String else { return nil }
                return PeerCapability(
                    id: id,
                    kind: entry["kind"] as? String ?? "",
                    ready: entry["ready"] as? Bool ?? false,
                    peakGB: number(entry["peak_gb"]) ?? number(entry["peak_vram_gb"]),
                    typicalSeconds: number(entry["typical_seconds"]),
                    detail: entry["detail"] as? String
                )
            }
        }
    }

    /// JSON numbers arrive as whatever the decoder felt like — NSNumber, Int, Double —
    /// and a field that parses on one shape and not another is a silent blank on the
    /// dashboard. One door for all of them.
    private nonisolated static func number(_ value: Any?) -> Double? {
        switch value {
        case let double as Double: return double
        case let int as Int: return Double(int)
        default: return nil
        }
    }

    // MARK: - In-app repairs

    /// A fix the app runs itself instead of dictating a Terminal command. If the error
    /// message knows the exact command, the button belongs next to the message.
    @Observable
    public final class RepairJob: Identifiable {
        public let id: String
        public var stage: String = "Starting…"
        public var error: String?
        var task: Task<Void, Never>?
        @ObservationIgnored var lastStageUpdate = Date.distantPast

        init(id: String) { self.id = id }
    }

    public private(set) var repairs: [String: RepairJob] = [:]

    public struct RepairStep: Sendable {
        public var executable: URL
        public var arguments: [String]
        public var currentDirectory: URL?
        /// Shown while this step runs, ahead of the tool's own output.
        public var label: String
    }

    /// Runs the steps in order, streaming the tool's output into `stage` (throttled — a
    /// compiler emits thousands of lines), and re-probes on success.
    func runRepair(id: String, steps: [RepairStep], onSuccess: @escaping @MainActor () -> Void) {
        guard repairs[id] == nil else { return }
        let job = RepairJob(id: id)
        repairs[id] = job

        job.task = Task { [weak self] in
            for step in steps {
                await MainActor.run { job.stage = step.label }
                let outcome = await Self.runProcess(step: step) { line in
                    Task { @MainActor in
                        guard let self else { return }
                        let job = self.repairs[id]
                        guard let job, Date().timeIntervalSince(job.lastStageUpdate) > 0.25
                        else { return }
                        job.lastStageUpdate = Date()
                        job.stage = "\(step.label) \(line)"
                    }
                }
                if Task.isCancelled { return }
                if let failure = outcome {
                    await MainActor.run { job.error = failure }
                    return
                }
            }
            await MainActor.run {
                guard let self else { return }
                self.repairs[id] = nil
                onSuccess()
            }
        }
    }

    public func cancelRepair(_ id: String) {
        repairs[id]?.task?.cancel()
        repairs[id] = nil
    }

    /// Runs one process to completion off the main actor; returns nil on success or a
    /// human-sized failure message.
    private nonisolated static func runProcess(
        step: RepairStep, onLine: @Sendable @escaping (String) -> Void
    ) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = step.executable
            process.arguments = step.arguments
            if let cwd = step.currentDirectory { process.currentDirectoryURL = cwd }
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice

            let tail = TailBox()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                for line in String(decoding: data, as: UTF8.self)
                    .split(separator: "\n", omittingEmptySubsequences: true)
                {
                    let text = String(line).trimmingCharacters(in: .whitespaces)
                    guard !text.isEmpty else { continue }
                    tail.append(text)
                    onLine(text)
                }
            }
            process.terminationHandler = { finished in
                pipe.fileHandleForReading.readabilityHandler = nil
                if finished.terminationStatus == 0 {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: tail.lastLines(4).joined(separator: "\n"))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: error.localizedDescription)
            }
        }
    }

    /// Bounded, lock-guarded tail of a process's output for failure messages.
    private final class TailBox: @unchecked Sendable {
        private var lines: [String] = []
        private let lock = NSLock()
        func append(_ line: String) {
            lock.lock()
            lines.append(line)
            if lines.count > 40 { lines.removeFirst(lines.count - 40) }
            lock.unlock()
        }
        func lastLines(_ count: Int) -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return Array(lines.suffix(count))
        }
    }

    /// The one-time hy3d build, run for the user — xcodebuild because command-line SwiftPM
    /// never compiles mlx-swift's Metal shaders.
    public func buildHy3DEngine() {
        let package = settings.resolvedTrellisBaseDirectory
            .appendingPathComponent("hunyuan3d-swift")
        runRepair(id: "hy3d-build", steps: [
            RepairStep(
                executable: URL(fileURLWithPath: "/usr/bin/xcodebuild"),
                arguments: [
                    "-scheme", "hy3d", "-configuration", "Release",
                    "-destination", "platform=macOS,arch=arm64",
                    "-derivedDataPath", ".xcbuild", "build",
                ],
                currentDirectory: package,
                label: "Building the engine —"
            ),
        ]) { [weak self] in
            self?.refreshMeshInstallations()
        }
    }

    /// Sets up MFLUX for image generation: a private Python environment plus the package.
    /// The venv step is instant; the install downloads a few hundred megabytes.
    public func installMFlux() {
        let venv = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".silicon-mlx")
        runRepair(id: "mflux-install", steps: [
            RepairStep(
                executable: URL(fileURLWithPath: "/usr/bin/python3"),
                arguments: ["-m", "venv", venv.path],
                currentDirectory: nil,
                label: "Creating the Python environment —"
            ),
            RepairStep(
                executable: venv.appendingPathComponent("bin/pip"),
                arguments: ["install", "--upgrade", "mflux"],
                currentDirectory: nil,
                label: "Installing MFLUX —"
            ),
        ]) { [weak self] in
            self?.rediscoverRuntimes()
        }
    }

    // MARK: - Image-to-3D chaining

    /// Set while a "describe it" draft from the 3D tab is rendering: the next finished image
    /// becomes the 3D source, so the two tools chain without the user ferrying files.
    public private(set) var routeNextImageToMesh = false

    /// Drafts an image from the composer prompt and routes the result to the 3D tab's
    /// source slot. Same queue and models as the Images tab — one pipeline, two doors.
    public func draftImageForMesh() {
        routeNextImageToMesh = true
        generateImage()
    }

    /// Hands an already-generated image to the 3D tab — the "Make it 3D" button.
    public func makeImage3D(_ image: URL) {
        meshInputImage = image
        selectedTab = .threeD
    }

    // MARK: - Image revision (img2img)

    /// Puts the composer in revision mode: generation starts from this image instead of
    /// noise, and the prompt describes the change. Sticky until ended — iterating on one
    /// image is the whole point — and visible the whole time via the composer banner.
    public func beginImageRevision(from image: URL) {
        imageConfiguration.initImage = image
    }

    public func endImageRevision() {
        imageConfiguration.initImage = nil
    }

    /// Revises the 3D tab's drafted source image in place: img2img from the current draft,
    /// routed back into the source slot. The words describe the change; the composition
    /// survives, which is what keeps the regenerated mesh recognizably the same object.
    public func reviseDraftForMesh() {
        guard let base = meshInputImage else { return }
        imageConfiguration.initImage = base
        draftImageForMesh()
    }

    public func meshPlanner() -> MeshPlanner { MeshPlanner(profile: profile) }

    public func meshPlan(
        for entry: MeshEntry, configuration: MeshConfiguration
    ) -> MeshPlan {
        meshPlanner().plan(
            entry: entry, configuration: configuration,
            otherAppsInUse: memoryUnavailableDuringImage
        )
    }

    /// Set when a mesh had to be written somewhere other than the configured directory.
    public internal(set) var meshOutputWarning: String?

    /// One folder per generation: a mesh is several files, and interleaving two jobs' GLB,
    /// OBJ and textures in one directory would make "which texture goes with which mesh"
    /// a puzzle. Falls back to the temporary directory like images do — and says so, since
    /// a silently relocated result is a result the user cannot find.
    func nextMeshOutputLocation() -> (directory: URL, baseName: String) {
        let baseName = Settings.meshBaseName()
        let root = settings.resolvedMeshOutputDirectory
        do {
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true
            )
            meshOutputWarning = nil
            return (root.appendingPathComponent(baseName), baseName)
        } catch {
            meshOutputWarning =
                "Could not write to \(root.path) — saving to the temporary folder instead. "
                + "Check the save location in Settings → 3D toolkit."
            return (
                FileManager.default.temporaryDirectory.appendingPathComponent(baseName),
                baseName
            )
        }
    }

    func makeMeshRuntime(for entry: MeshEntry) -> (any MeshRuntime)? {
        let base = settings.resolvedTrellisBaseDirectory
        switch entry.backend {
        case .trellis:
            return TrellisRuntime(base: base)
        case .hunyuan:
            return HunyuanRuntime(
                base: base,
                weightsSlot: Self.hunyuanWeightsSlot(for: entry.id),
                modelName: entry.name,
                defaultSteps: entry.defaultSteps ?? 30
            )
        case .latoRemote:
            let configured = settings.lato2ServiceURL
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: configured) else { return nil }
            return Lato2Runtime(baseURL: url)
        case .unsupported:
            return nil
        }
    }

    /// Queues the composer's current image. Same warn-don't-refuse policy as images.
    public func generateMesh() {
        guard let entry = MeshCatalog.entry(id: selectedMeshModel),
              let image = meshInputImage else { return }

        let plan = meshPlan(for: entry, configuration: meshConfiguration)
        if !plan.verdict.isUsable {
            alert = AlertContent(
                title: "This may not fit in memory",
                message: "\(entry.name) would peak at \(plan.peak.formatted) against a "
                    + "\(plan.budget.formatted) budget. The run is queued anyway — expect "
                    + "swapping and a long wait, or cancel and free memory first."
            )
        }

        meshQueue.append(MeshJob(
            image: image, configuration: meshConfiguration,
            modelID: entry.id, modelName: entry.name
        ))
        advanceMeshQueue()
    }

    public func removeQueuedMeshJob(_ id: MeshJob.ID) {
        meshQueue.removeAll { $0.id == id }
    }

    private func advanceMeshQueue() {
        guard !isGeneratingMesh, !meshQueue.isEmpty else { return }
        let job = meshQueue.removeFirst()
        currentMeshJob = job
        runMeshJob(job)
    }

    private func runMeshJob(_ job: MeshJob) {
        noteActivity()
        guard let entry = MeshCatalog.entry(id: job.modelID),
              let runtime = makeMeshRuntime(for: entry) else {
            currentMeshJob = nil
            meshState = .failed(message: "No runtime available for \(job.modelName).")
            return
        }
        let (directory, baseName) = nextMeshOutputLocation()
        let request = MeshRequest(
            image: job.image, configuration: job.configuration,
            outputDirectory: directory, baseName: baseName
        )

        meshState = .starting(stage: "Starting \(job.modelName)…")
        meshProgress = nil
        meshWasCancelled = false
        activeMeshRuntime = runtime

        meshTask = Task { [weak self] in
            defer {
                Task { @MainActor in
                    guard let self else { return }
                    self.meshTask = nil
                    self.activeMeshRuntime = nil
                    self.currentMeshJob = nil
                    self.advanceMeshQueue()
                }
            }
            do {
                for try await event in try await runtime.generate(request) {
                    guard let self else { return }
                    switch event {
                    case .stage(let stage):
                        meshState = .starting(stage: stage)
                        meshProgress = nil
                    case .progress(let fraction):
                        meshProgress = fraction
                    case .finished(let result):
                        meshResults.insert(result, at: 0)
                        meshProgress = nil
                        meshState = .idle
                    }
                }
            } catch {
                guard let self else { return }
                if meshWasCancelled {
                    meshState = .idle
                } else {
                    meshState = .failed(message: error.localizedDescription)
                    alert = AlertContent(
                        title: "Could not generate a 3D model",
                        message: error.localizedDescription
                    )
                }
                meshWasCancelled = false
            }
        }
    }

    // MARK: - Recent results on disk

    public struct RecentFile: Identifiable, Equatable, Sendable {
        public var id: String { url.path }
        public var url: URL
        public var date: Date
    }

    /// Images in the output folder, newest first — the session gallery only knows this
    /// launch; the folder knows every launch.
    public func recentImages(limit: Int = 60) -> [RecentFile] {
        let directory = settings.resolvedImageOutputDirectory
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        )) ?? []
        return urls
            .filter { ["png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
            .map { url in
                RecentFile(
                    url: url,
                    date: (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate ?? .distantPast
                )
            }
            .sorted { $0.date > $1.date }
            .prefix(limit)
            .map { $0 }
    }

    /// Saved meshes rediscovered from the output folder — one generation per subfolder,
    /// reassembled into the same `MeshResult` shape the session gallery uses so the viewer
    /// and the open-externally actions work identically on both.
    public func recentMeshes(limit: Int = 40) -> [MeshResult] {
        let root = settings.resolvedMeshOutputDirectory
        let manager = FileManager.default
        let folders = (try? manager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: .skipsHiddenFiles
        )) ?? []

        return folders
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .sorted { lhs, rhs in
                let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return left > right
            }
            .prefix(limit)
            .compactMap { folder in
                let files = (try? manager.contentsOfDirectory(
                    at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
                )) ?? []
                let glb = files.first { $0.pathExtension.lowercased() == "glb" }
                let obj = files.first { $0.pathExtension.lowercased() == "obj" }
                guard glb != nil || obj != nil else { return nil }
                return MeshResult(
                    baseName: folder.lastPathComponent,
                    glb: glb,
                    obj: obj,
                    textures: files.filter { $0.pathExtension.lowercased() == "png" },
                    sourceImage: nil,
                    modelName: "",
                    elapsed: 0
                )
            }
    }

    /// What the machine is generating outside the language model, as one status line —
    /// e.g. "Generating image — FLUX.2 klein (4/8)". The Images and 3D pipelines run real
    /// models of their own, so a status surface that says "no model loaded" while a
    /// diffusion model is denoising is lying; every such surface checks this first.
    public var activeGenerationSummary: String? {
        if let job = currentImageJob {
            var line = "Generating image — \(job.modelName)"
            if let progress = imageProgress {
                line += " (\(progress.step)/\(progress.total))"
            }
            return line
        }
        if let job = currentMeshJob {
            var line = "Generating 3D — \(job.modelName)"
            if let progress = meshProgress {
                line += " (\(Int(progress * 100))%)"
            }
            return line
        }
        return nil
    }

    /// Same teardown discipline as `cancelImage()`: state clears when the stream ends.
    public func cancelMesh() {
        guard let runtime = activeMeshRuntime else { return }
        meshWasCancelled = true
        meshTask?.cancel()
        meshState = .starting(stage: "Stopping…")
        Task { await runtime.cancel() }
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
                // The hard swarm rule lives in the server: LAN exposure without a token
                // silently stays loopback, so a half-configured setup fails safe.
                let swarm = SwarmConfig.load()
                try await server.start(
                    exposeOnLAN: settings.exposeControlOnLAN,
                    swarmToken: swarm?.effectiveToken
                )
                self.controlIsOnLAN = await server.isExposedOnLAN
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
            // App-side accounting cannot see clients that talk to the server directly over
            // HTTP — the harness above all. A 29-minute agent turn looks exactly like 29
            // minutes of idleness from here, so the server itself gets the last word.
            switch await serverBusyVerdict() {
            case .some(true):
                noteActivity()
                return
            case .none:
                // Could not tell (no /slots on this backend, or the server was too busy to
                // answer). While the harness is up, killing a possibly-active generation is
                // the worse mistake; without it, this is the same dead server it always was.
                if settings.chatEngine == .harness, case .ready = harnessState {
                    noteActivity()
                    return
                }
            case .some(false):
                break
            }
            // Re-check after the hops: the user may have started generating in the meantime.
            guard !isGenerating, loadedModel != nil else { return }
            await unload()
            runtimeState = .idle
        }
        // Reset immediately so the unload is not queued repeatedly while it runs.
        lastActivityAt = Date()
    }

    /// Asks the running server whether a generation is in flight. Returns nil when the
    /// question cannot be answered — an unreachable server, or a backend without `/slots`.
    private func serverBusyVerdict() async -> Bool? {
        guard case .ready(let endpoint) = runtimeState else { return false }
        var request = URLRequest(url: endpoint.appendingPathComponent("slots"))
        request.timeoutInterval = 3

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let slots = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }

        return slots.contains { slot in
            // The field has been renamed across llama.cpp versions; accept either spelling.
            if let processing = slot["is_processing"] as? Bool { return processing }
            if let state = slot["state"] as? Int { return state != 0 }
            return false
        }
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

    var estimatedResidentBytes: Bytes {
        guard let model = loadedModel, let shape = model.shape,
              let configuration = activeConfiguration else { return .zero }
        return MemoryPlanner(profile: profile)
            .plan(shape: shape, quantization: model.quantization, configuration: configuration)
            .resident
    }

    // MARK: - Library

    /// Applies the configured download destination to the library. Called on every
    /// refresh — the setter is an idempotent actor hop — so a Settings change takes
    /// effect for the very next download without a relaunch.
    public func applyModelLibrarySettings() async {
        await library.setDownloadRoot(settings.resolvedModelLibraryDirectory)
    }

    /// Registers every GGUF found in a folder, so a directory of models from another
    /// machine or an old install becomes loadable in one action instead of one import
    /// panel per file.
    public func adoptModelsFromFolder(_ folder: URL) async {
        let manager = FileManager.default
        let known = Set(installedModels.map(\.primaryFile.path))
        var added = 0
        var skipped = 0
        var failed = 0

        let enumerator = manager.enumerator(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )
        while let item = enumerator?.nextObject() as? URL {
            guard item.pathExtension.lowercased() == "gguf",
                  !ModelResolver.isCompanionFile(item.lastPathComponent)
            else { continue }
            // Split models are registered by their head shard only.
            let name = item.lastPathComponent
            if name.contains("-of-"), !name.contains("00001-of-") { continue }
            guard !known.contains(item.path) else {
                skipped += 1
                continue
            }
            do {
                _ = try await library.importExternal(file: item)
                added += 1
            } catch {
                failed += 1
            }
        }
        await refreshLibrary()

        var summary = added == 1 ? "Added 1 model." : "Added \(added) models."
        if skipped > 0 { summary += " \(skipped) already in the library." }
        if failed > 0 { summary += " \(failed) couldn't be read as models." }
        alert = AlertContent(title: "Folder scanned", message: summary)
    }

    public func refreshLibrary() async {
        await applyModelLibrarySettings()
        do {
            try await library.load()
            installedModels = await library.installed
            libraryError = nil
        } catch {
            libraryError = error.localizedDescription
        }
    }

    /// Registers a GGUF file already on disk without copying it — the same path `install()`'s
    /// `saveTo` writes new downloads to, but for a file that already exists wherever it is: moved
    /// there by hand in Finder, or fetched by something other than this app.
    public func importModel(from file: URL, name: String? = nil) async {
        do {
            _ = try await library.importExternal(file: file, name: name)
            await refreshLibrary()
        } catch {
            alert = AlertContent(
                title: "Could not import \(file.lastPathComponent)",
                message: error.localizedDescription
            )
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

    /// - Parameter saveTo: A folder to save this model's files under instead of Silicon
    ///   Optimizer's own managed library directory — an external drive, say. The library's index
    ///   still lives where it always does; only these files move. Pass `nil` for the default.
    public func install(_ entry: ModelEntry, quantization: Quantization, saveTo: URL? = nil) {
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
                let destination = if let saveTo {
                    saveTo.appendingPathComponent(
                        "\(entry.id)/\(quantization.rawValue)", isDirectory: true
                    )
                } else {
                    await self.library.directory(for: entry.id, quantization: quantization)
                }
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
        public enum Kind: Sendable { case language, image, mesh }

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
        let meshes = meshDownloads.values.map {
            ActiveTransfer(
                id: $0.id, name: $0.entry.name, detail: "3D model",
                progress: $0.progress, error: $0.error, kind: .mesh
            )
        }
        return (language + images + meshes)
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    /// Combined throughput across every transfer, which is what the machine is actually doing.
    public var transferBytesPerSecond: Double {
        activeTransfers.compactMap(\.progress?.bytesPerSecond).reduce(0, +)
    }

    public func cancelTransfer(_ transfer: ActiveTransfer) {
        switch transfer.kind {
        case .language: cancelInstall(transfer.id)
        case .image: cancelImageInstall(transfer.id)
        case .mesh: cancelMeshInstall(transfer.id)
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

        // Harness chat needs headroom for its system prompt and tools; raise the context when
        // memory allows, whichever path chose the configuration.
        let resolved = harnessContextAdjusted(
            configuration ?? defaultConfiguration(for: model), for: model
        )

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
                model: model, configuration: resolved,
                // A stable port rather than an ephemeral one, so the harness's generated
                // provider config keeps pointing at a live server across model switches.
                port: harnessPorts().inference,
                extraArguments: extraArguments
            ))
            loadedModel = model
            activeConfiguration = resolved
            // The harness reads its settings document per request, so telling it the new
            // model's name and true context takes effect from the next message.
            refreshHarnessProviderIfNeeded()
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
