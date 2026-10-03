import Foundation
import Observation
import SiliconRuntime

/// A frozen receipt belongs to the endpoint that accepted it, even after connection settings change.
struct FreeVideoPendingClip: Codable, Sendable, Equatable {
    var job: FreeVideoJob
    var endpoint: URL
    var outputDirectory: URL
    var prompt: String
}

struct FreeVideoSavedClip: Codable, Sendable, Identifiable, Equatable {
    var id: String
    var file: URL
    var prompt: String
    var endpoint: URL
    var completedAt: Date
}

struct FreeVideoStudioSnapshot: Codable, Sendable {
    var endpoint = "http://127.0.0.1:8188"
    var pending: FreeVideoPendingClip?
    var history: [FreeVideoSavedClip] = []
    var uncertainSubmission = false
    var uncertainEndpoint: URL?
}

actor FreeVideoStudioStore {
    let url: URL?

    init(url: URL?) { self.url = url }

    static var applicationURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return root.appendingPathComponent("SiliconOptimizer/FreeVideo/studio.json")
    }

    func load() throws -> FreeVideoStudioSnapshot? {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        let info = try url.resourceValues(forKeys: [.fileSizeKey])
        guard (info.fileSize ?? 0) <= 8 * 1_024 * 1_024 else {
            throw CocoaError(.fileReadTooLarge)
        }
        return try JSONDecoder().decode(FreeVideoStudioSnapshot.self, from: Data(contentsOf: url))
    }

    func save(_ state: FreeVideoStudioSnapshot) throws {
        guard let url else { return }
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Closure dependencies keep UI-state tests independent of a running GPU engine.
struct FreeVideoStudioClient: Sendable {
    var check: @Sendable (URL) async throws -> FreeVideoEngineStatus
    var submit: @Sendable (FreeVideoRequest, URL) async throws -> FreeVideoJob
    var follow: @Sendable (FreeVideoJob, URL, URL, @escaping @Sendable (String) -> Void) async throws -> FreeVideoResult
    var cancel: @Sendable (FreeVideoJob, URL) async throws -> FreeVideoCancelOutcome

    static func live(runtime: FreeVideoRuntime = FreeVideoRuntime()) -> Self {
        .init(check: { try await runtime.check(node: $0) },
              submit: { try await runtime.submit($0, node: $1) },
              follow: { try await runtime.follow($0, node: $1, outputDirectory: $2, onProgress: $3) },
              cancel: { try await runtime.cancel($0, node: $1) })
    }
}

@MainActor
@Observable
final class FreeVideoStudio {
    var endpoint = "http://127.0.0.1:8188" {
        didSet {
            if endpoint != oldValue { checkedEndpoint = nil; engineStatus = nil }
        }
    }
    var prompt = ""
    var width = 768
    var height = 448
    var seconds = 5.0
    var seed = ""
    var twoPass = true
    var firstFrame: URL?
    var lastFrame: URL?
    private(set) var engineStatus: FreeVideoEngineStatus?
    private(set) var isChecking = false
    private(set) var isRestored = false
    private(set) var isRestoring = false
    private(set) var isBusy = false
    private(set) var isCancelling = false
    private(set) var pending: FreeVideoPendingClip?
    private(set) var history: [FreeVideoSavedClip] = []
    private(set) var uncertainSubmission = false
    private(set) var uncertainEndpoint: URL?
    private(set) var stage: String?
    var error: String?
    var selectedClip: URL?

    @ObservationIgnored private var checkedEndpoint: URL?
    @ObservationIgnored private let client: FreeVideoStudioClient
    @ObservationIgnored private let store: FreeVideoStudioStore

    init(storageURL: URL? = nil, client: FreeVideoStudioClient = .live()) {
        store = FreeVideoStudioStore(url: storageURL)
        self.client = client
    }

    var isReady: Bool {
        engineStatus?.ready == true
            && checkedEndpoint == (try? FreeVideoRuntime.validatedBaseURL(endpoint))
    }

    var canGenerate: Bool {
        isRestored && isReady && !isChecking && !isBusy && !isCancelling
            && pending == nil && !uncertainSubmission
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var displayedClip: URL? { selectedClip ?? history.first?.file }

    /// Restore receipts without contacting or starting the remote engine.
    func restore() async {
        guard !isRestored, !isRestoring else { return }
        isRestoring = true
        error = nil
        defer { isRestoring = false }
        do {
            if let saved = try await store.load() {
                endpoint = saved.endpoint
                pending = saved.pending
                history = saved.history
                uncertainSubmission = saved.uncertainSubmission
                uncertainEndpoint = saved.uncertainEndpoint
            }
            isRestored = true
        } catch {
            self.error = "Could not read the saved FreeVideo state: \(error.localizedDescription)"
            return
        }
    }

    func saveConnection() async {
        guard isRestored else { return }
        do { try await persist() }
        catch { self.error = "Could not save the connection: \(error.localizedDescription)" }
    }

    func checkConnection() async {
        guard isRestored, !isChecking else { return }
        isChecking = true
        engineStatus = nil
        checkedEndpoint = nil
        error = nil
        defer { isChecking = false }
        do {
            let base = try FreeVideoRuntime.validatedBaseURL(endpoint)
            let status = try await client.check(base)
            // A slow response from a previous address cannot enable the new address.
            guard base == (try? FreeVideoRuntime.validatedBaseURL(endpoint)) else { return }
            checkedEndpoint = base
            engineStatus = status
            try await persist()
        } catch { self.error = error.localizedDescription }
    }

    func generate(outputDirectory: URL) async {
        guard canGenerate else { return }
        isBusy = true
        error = nil
        stage = "Sending the job"
        var submittedEndpoint: URL?
        defer { isBusy = false }
        do {
            let base = try FreeVideoRuntime.validatedBaseURL(endpoint)
            submittedEndpoint = base
            let requestSeed: UInt32
            if seed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                requestSeed = UInt32.random(in: .min ... .max)
            } else if let parsed = UInt32(seed.trimmingCharacters(in: .whitespacesAndNewlines)) {
                requestSeed = parsed
            } else {
                error = "Seed must be a whole number from 0 to 4294967295, or blank for a random seed."
                stage = nil
                return
            }
            let frozenPrompt = prompt
            let request = FreeVideoRequest(prompt: frozenPrompt, width: width, height: height,
                                           seconds: seconds, seed: requestSeed, twoPass: twoPass,
                                           firstFrame: firstFrame, lastFrame: lastFrame)
            let job = try await client.submit(request, base)
            pending = .init(job: job, endpoint: base, outputDirectory: outputDirectory, prompt: frozenPrompt)
            // Keep an accepted job even if saving fails. Resume follows it and never resubmits it.
            try await persist()
            await followPending()
        } catch FreeVideoError.submissionUnknown {
            uncertainSubmission = true
            uncertainEndpoint = submittedEndpoint
            stage = nil
            error = "The connection ended before FreeVideo confirmed the job. Open the workspace and check its queue or history before trying again."
            do { try await persist() }
            catch { self.error = "\(self.error ?? "") The uncertain outcome could not be saved: \(error.localizedDescription)" }
        } catch {
            stage = nil
            self.error = pending == nil ? error.localizedDescription
                : "The job was accepted, but its receipt could not be saved. Use Resume to follow the same job. \(error.localizedDescription)"
        }
    }

    func resume() async {
        guard isRestored, !isBusy, pending != nil else { return }
        isBusy = true
        error = nil
        defer { isBusy = false }
        do {
            try await persist()
            await followPending()
        } catch { self.error = "Could not save the accepted job: \(error.localizedDescription)" }
    }

    private func followPending() async {
        guard let receipt = pending else { return }
        stage = "Following the accepted job"
        do {
            let result = try await client.follow(receipt.job, receipt.endpoint, receipt.outputDirectory) { [weak self] message in
                Task { @MainActor in
                    guard self?.pending?.job.id == receipt.job.id else { return }
                    self?.stage = message
                }
            }
            // A confirmed cancel can race with a completed follow. Only this receipt owns state.
            guard pending?.job.id == receipt.job.id else { return }
            let clip = FreeVideoSavedClip(id: result.jobID, file: result.file, prompt: receipt.prompt,
                                         endpoint: receipt.endpoint, completedAt: Date())
            history.removeAll { $0.id == clip.id && $0.endpoint == clip.endpoint }
            history.insert(clip, at: 0)
            history = Array(history.prefix(60))
            selectedClip = result.file
            pending = nil
            stage = "Video saved"
            do { try await persist() }
            catch { self.error = "The video was saved, but its history could not be saved: \(error.localizedDescription)" }
        } catch FreeVideoError.cancelled {
            guard pending?.job.id == receipt.job.id else { return }
            pending = nil
            stage = "Generation cancelled"
            do { try await persist() }
            catch { self.error = "Could not save the cancelled job state: \(error.localizedDescription)" }
        } catch {
            guard pending?.job.id == receipt.job.id else { return }
            stage = nil
            self.error = "\(error.localizedDescription) The accepted job is saved; Resume checks it without starting another render."
        }
    }

    func cancel() async {
        guard isRestored, !isCancelling, let receipt = pending else { return }
        isCancelling = true
        defer { isCancelling = false }
        do {
            let outcome = try await client.cancel(receipt.job, receipt.endpoint)
            stage = outcome.message
            if outcome == .cancelled {
                pending = nil
                try await persist()
            } else if !isBusy {
                await resume()
            }
        } catch { self.error = "Could not confirm cancellation. The job receipt is retained. \(error.localizedDescription)" }
    }

    func acknowledgeUnknownSubmission() async {
        guard isRestored else { return }
        uncertainSubmission = false
        uncertainEndpoint = nil
        error = nil
        do { try await persist() }
        catch { self.error = "Could not save the outcome acknowledgement: \(error.localizedDescription)" }
    }

    /// This only drops the receipt after the user inspected ComfyUI; it never cancels a job.
    func forgetSavedJob() async {
        guard isRestored, !isBusy, !isCancelling else { return }
        pending = nil
        stage = nil
        error = nil
        do { try await persist() }
        catch { self.error = "Could not save the forgotten receipt state: \(error.localizedDescription)" }
    }

    private func persist() async throws {
        guard isRestored else {
            throw FreeVideoError.notReady("The saved FreeVideo state has not loaded. Retry loading it before changing the connection or job state.")
        }
        try await store.save(.init(endpoint: endpoint, pending: pending, history: history,
                                   uncertainSubmission: uncertainSubmission, uncertainEndpoint: uncertainEndpoint))
    }
}
