import Foundation
import SiliconCatalog
import SiliconCore
import SiliconPlanner

// MARK: - TRELLIS.2

/// Runs TRELLIS.2 through the trellis-mac Python venv on MPS.
///
/// The invocation recipe is exact and verified: the Metal extension overlay is injected via
/// `PYTHONPATH`, and because those extensions bake an rpath to a venv location that predates the
/// project's move onto the T9 volume, `DYLD_FALLBACK_LIBRARY_PATH` points at the venv's real
/// torch libraries so the dlopen succeeds. Without the overlay the render still works — it just
/// falls back to a much slower CPU bake.
public actor TrellisRuntime: MeshRuntime {

    public private(set) var state: RuntimeState = .idle
    private let base: URL
    private let process = ServerProcess()
    private var cancelled = false

    public init(base: URL) {
        self.base = base
    }

    public func generate(_ request: MeshRequest) async throws
        -> AsyncThrowingStream<MeshEvent, any Error>
    {
        let repo = base.appendingPathComponent("trellis-mac")
        let python = repo.appendingPathComponent(".venv/bin/python")
        guard FileManager.default.fileExists(atPath: python.path) else {
            throw MeshRuntimeError.notInstalled(MeshLocator.trellis(base: base).detail)
        }

        try FileManager.default.createDirectory(
            at: request.outputDirectory, withIntermediateDirectories: true
        )
        let outputBase = request.outputDirectory.appendingPathComponent(request.baseName)

        var arguments = [
            "generate.py", request.image.path,
            "--output", outputBase.path,
            "--pipeline-type", request.configuration.pipelineType,
            "--texture-size", String(request.configuration.textureSize),
        ]
        if let seed = request.configuration.seed {
            arguments += ["--seed", String(seed)]
        }

        var environment = [
            "PYTHONUNBUFFERED": "1",
            "PYTORCH_ENABLE_MPS_FALLBACK": "1",
            "PYTHONPATH": base.appendingPathComponent("metal_overlay").path,
        ]
        if let torchLib = Self.torchLibraryDirectory(venv: repo.appendingPathComponent(".venv")) {
            environment["DYLD_FALLBACK_LIBRARY_PATH"] = torchLib.path
        }

        state = .starting(stage: "Starting TRELLIS.2…")
        cancelled = false
        let started = Date()
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: MeshEvent.self)
        let stages = MeshStageBox()

        try await process.start(
            executable: python, arguments: arguments, currentDirectory: repo
        ) { line in
            Task {
                if let event = await stages.interpretTrellis(line) {
                    continuation.yield(event)
                }
            }
        }

        let process = self.process
        let request = request
        Task {
            while await process.isRunning {
                try? await Task.sleep(for: .milliseconds(300))
            }
            let status = await process.terminationStatus
            let log = await process.log

            if await self.wasCancelled() {
                continuation.finish(throwing: MeshRuntimeError.cancelled)
                return
            }
            if status == 2 {
                continuation.finish(throwing: MeshRuntimeError.watchdog)
                return
            }
            guard status == 0 else {
                let tail = log.split(separator: "\n").suffix(6).joined(separator: "\n")
                continuation.finish(throwing: MeshRuntimeError.generationFailed(
                    "TRELLIS.2 exited with status \(status ?? -1).\n\(tail)"
                ))
                return
            }

            let glb = outputBase.appendingPathExtension("glb")
            let obj = outputBase.appendingPathExtension("obj")
            let basecolor = request.outputDirectory
                .appendingPathComponent("\(request.baseName)_basecolor.png")
            guard FileManager.default.fileExists(atPath: glb.path) else {
                continuation.finish(throwing: MeshRuntimeError.noMeshProduced)
                return
            }
            continuation.yield(.finished(MeshResult(
                baseName: request.baseName,
                glb: glb,
                obj: FileManager.default.fileExists(atPath: obj.path) ? obj : nil,
                textures: FileManager.default.fileExists(atPath: basecolor.path)
                    ? [basecolor] : [],
                sourceImage: request.image,
                modelName: "TRELLIS.2 4B",
                elapsed: Date().timeIntervalSince(started)
            )))
            continuation.finish()
        }
        return stream
    }

    private func wasCancelled() -> Bool { cancelled }

    public func cancel() {
        cancelled = true
        state = .idle
        Task { await process.terminate() }
    }

    /// The venv's torch library directory, whatever Python minor version it holds.
    static func torchLibraryDirectory(venv: URL) -> URL? {
        let lib = venv.appendingPathComponent("lib")
        let versions = (try? FileManager.default.contentsOfDirectory(
            at: lib, includingPropertiesForKeys: nil
        )) ?? []
        for version in versions where version.lastPathComponent.hasPrefix("python") {
            let torch = version.appendingPathComponent("site-packages/torch/lib")
            if FileManager.default.fileExists(atPath: torch.path) { return torch }
        }
        return nil
    }
}

// MARK: - Hunyuan3D

/// Runs Hunyuan3D 2 through the native MLX-Swift `hy3d` binary.
public actor HunyuanRuntime: MeshRuntime {

    public private(set) var state: RuntimeState = .idle
    private let base: URL
    private let weightsSlot: String
    private let modelName: String
    private let defaultSteps: Int
    private let process = ServerProcess()
    private var cancelled = false

    public init(base: URL, weightsSlot: String, modelName: String, defaultSteps: Int) {
        self.base = base
        self.weightsSlot = weightsSlot
        self.modelName = modelName
        self.defaultSteps = defaultSteps
    }

    public func generate(_ request: MeshRequest) async throws
        -> AsyncThrowingStream<MeshEvent, any Error>
    {
        guard let executable = MeshLocator.hy3dExecutable(base: base) else {
            throw MeshRuntimeError.notInstalled(
                MeshLocator.hunyuan(base: base, weightsSlot: weightsSlot).detail
            )
        }
        let weights = base.appendingPathComponent("hunyuan3d-swift/weights/\(weightsSlot)")

        try FileManager.default.createDirectory(
            at: request.outputDirectory, withIntermediateDirectories: true
        )
        let output = request.outputDirectory
            .appendingPathComponent(request.baseName)
            .appendingPathExtension("glb")

        var arguments = [
            "shape", request.image.path,
            "-o", output.path,
            "--weights", weights.path,
            "--steps", String(request.configuration.steps ?? defaultSteps),
            "--octree", String(request.configuration.octree),
        ]
        if let quantize = request.configuration.quantize {
            arguments += ["--quantize", String(quantize)]
        }
        if let seed = request.configuration.seed {
            arguments += ["--seed", String(seed)]
        }

        state = .starting(stage: "Starting Hunyuan3D…")
        cancelled = false
        let started = Date()
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: MeshEvent.self)
        let stages = MeshStageBox()

        try await process.start(executable: executable, arguments: arguments) { line in
            Task {
                if let event = await stages.interpretHunyuan(line) {
                    continuation.yield(event)
                }
            }
        }

        let process = self.process
        let request = request
        let modelName = self.modelName
        Task {
            while await process.isRunning {
                try? await Task.sleep(for: .milliseconds(200))
            }
            let status = await process.terminationStatus
            let log = await process.log

            if await self.wasCancelled() {
                continuation.finish(throwing: MeshRuntimeError.cancelled)
                return
            }
            guard status == 0, FileManager.default.fileExists(atPath: output.path) else {
                let tail = log.split(separator: "\n").suffix(6).joined(separator: "\n")
                continuation.finish(throwing: MeshRuntimeError.generationFailed(
                    "hy3d exited with status \(status ?? -1).\n\(tail)"
                ))
                return
            }
            continuation.yield(.finished(MeshResult(
                baseName: request.baseName,
                glb: output, obj: nil, textures: [],
                sourceImage: request.image,
                modelName: modelName,
                elapsed: Date().timeIntervalSince(started)
            )))
            continuation.finish()
        }
        return stream
    }

    private func wasCancelled() -> Bool { cancelled }

    public func cancel() {
        cancelled = true
        state = .idle
        Task { await process.terminate() }
    }
}

// MARK: - LATO.2 (remote)

/// Talks to the LATO.2 service over HTTP: submit the image, poll the job, download the meshes.
///
/// The API shape comes from the service plan (`POST /v1/image-to-mesh` → `{job_id}`, then
/// `GET /v1/jobs/{id}` until done, files by URL). Field names are parsed liberally — the
/// service is maintained on another machine and renaming a JSON key there should degrade to a
/// clear error here, not a crash.
public actor Lato2Runtime: MeshRuntime {

    public private(set) var state: RuntimeState = .idle
    private let baseURL: URL
    private var cancelled = false

    public init(baseURL: URL) {
        self.baseURL = baseURL
    }

    /// True when the service answers its health endpoint.
    public static func probe(baseURL: URL) async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.timeoutInterval = 4
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }

    public func generate(_ request: MeshRequest) async throws
        -> AsyncThrowingStream<MeshEvent, any Error>
    {
        cancelled = false
        state = .starting(stage: "Contacting the LATO.2 service…")
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: MeshEvent.self)
        let baseURL = self.baseURL
        let started = Date()

        let worker = Task {
            do {
                continuation.yield(.stage("Uploading image…"))
                let jobID = try await Self.submit(
                    image: request.image,
                    vertexBudget: request.configuration.vertexBudget,
                    seed: request.configuration.seed,
                    baseURL: baseURL
                )
                continuation.yield(.stage("Rendering on the LATO.2 machine…"))

                let deadline = Date().addingTimeInterval(30 * 60)
                var fileURLs: [URL] = []
                poll: while true {
                    try Task.checkCancellation()
                    if Date() > deadline {
                        throw MeshRuntimeError.generationFailed(
                            "The LATO.2 job did not finish within 30 minutes."
                        )
                    }
                    let job = try await Self.jobStatus(jobID: jobID, baseURL: baseURL)
                    if let progress = job.progress {
                        continuation.yield(.progress(progress))
                    }
                    // The same line every other swarm tool shows: stage, step, percentage,
                    // elapsed and what is left, in the node's own numbers.
                    if let reported = job.reported {
                        continuation.yield(
                            .stage(reported.line(fallback: "Rendering on the LATO.2 machine…"))
                        )
                    }
                    switch job.state {
                    case .done:
                        fileURLs = job.files
                        break poll
                    case .failed(let message):
                        throw MeshRuntimeError.generationFailed(message)
                    case .running:
                        try await Task.sleep(for: .seconds(3))
                    }
                }

                continuation.yield(.stage("Downloading meshes…"))
                try FileManager.default.createDirectory(
                    at: request.outputDirectory, withIntermediateDirectories: true
                )
                var glb: URL?
                var obj: URL?
                for remote in fileURLs {
                    let ext = remote.pathExtension.lowercased()
                    guard ext == "glb" || ext == "obj" else { continue }
                    let local = request.outputDirectory
                        .appendingPathComponent(request.baseName)
                        .appendingPathExtension(ext)
                    let (data, _) = try await URLSession.shared.data(from: remote)
                    try data.write(to: local)
                    if ext == "glb" { glb = local } else { obj = local }
                }
                guard glb != nil || obj != nil else {
                    throw MeshRuntimeError.noMeshProduced
                }
                continuation.yield(.finished(MeshResult(
                    baseName: request.baseName,
                    glb: glb, obj: obj, textures: [],
                    sourceImage: request.image,
                    modelName: "LATO.2",
                    elapsed: Date().timeIntervalSince(started)
                )))
                continuation.finish()
            } catch is CancellationError {
                continuation.finish(throwing: MeshRuntimeError.cancelled)
            } catch {
                continuation.finish(throwing: error)
            }
        }
        self.worker = worker
        return stream
    }

    private var worker: Task<Void, Never>?

    public func cancel() {
        cancelled = true
        state = .idle
        worker?.cancel()
    }

    // MARK: Wire helpers

    private static func submit(
        image: URL, vertexBudget: Int, seed: Int?, baseURL: URL
    ) async throws -> String {
        let imageData: Data
        do {
            imageData = try Data(contentsOf: image)
        } catch {
            throw MeshRuntimeError.generationFailed(
                "Could not read the input image: \(error.localizedDescription)"
            )
        }

        let boundary = "silicon-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data(
                "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8
            ))
        }
        field("vert_num", String(vertexBudget))
        if let seed { field("seed", String(seed)) }
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data(
            ("Content-Disposition: form-data; name=\"image\"; "
                + "filename=\"\(image.lastPathComponent)\"\r\n"
                + "Content-Type: application/octet-stream\r\n\r\n").utf8
        ))
        body.append(imageData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: baseURL.appendingPathComponent("v1/image-to-mesh"))
        request.httpMethod = "POST"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = body
        request.timeoutInterval = 120

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw MeshRuntimeError.remoteUnreachable(
                "Could not reach the LATO.2 service at \(baseURL.absoluteString): "
                    + error.localizedDescription
            )
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else {
            let bodyText = String(decoding: data.prefix(300), as: UTF8.self)
            throw MeshRuntimeError.generationFailed(
                "The LATO.2 service refused the job: \(bodyText)"
            )
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let jobID = (json?["job_id"] ?? json?["id"]) as? String else {
            throw MeshRuntimeError.generationFailed(
                "The LATO.2 service did not return a job id."
            )
        }
        return jobID
    }

    enum JobState {
        case running
        case done
        case failed(String)
    }

    struct JobSnapshot {
        var state: JobState
        var progress: Double?
        var files: [URL]
        /// Everything the node said about the job, for the status line.
        var reported: NodeJobProgress?
    }

    private static func jobStatus(jobID: String, baseURL: URL) async throws -> JobSnapshot {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/jobs/\(jobID)"))
        request.timeoutInterval = 30
        let (data, _): (Data, URLResponse)
        do {
            (data, _) = try await URLSession.shared.data(for: request)
        } catch {
            throw MeshRuntimeError.remoteUnreachable(
                "Lost the LATO.2 service mid-job: \(error.localizedDescription)"
            )
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MeshRuntimeError.generationFailed("Unreadable job status from LATO.2.")
        }

        let status = (json["status"] as? String)?.lowercased() ?? "running"
        let progress = (json["progress"] as? Double)
            ?? (json["progress"] as? Int).map(Double.init)

        // Every string in the response that looks like a mesh URL counts as a result file —
        // resilient to the service naming them result_urls, glb_url, files, or anything else.
        var files: [URL] = []
        func collect(_ value: Any) {
            if let text = value as? String,
               let url = URL(string: text, relativeTo: baseURL)?.absoluteURL,
               ["glb", "obj"].contains(url.pathExtension.lowercased())
            {
                files.append(url)
            } else if let array = value as? [Any] {
                array.forEach(collect)
            } else if let object = value as? [String: Any] {
                object.values.forEach(collect)
            }
        }
        collect(json)

        let reported = NodeJobProgress(from: json)
        switch status {
        case "done", "completed", "complete", "succeeded", "finished":
            return JobSnapshot(state: .done, progress: 1.0, files: files, reported: nil)
        case "failed", "error":
            let message = (json["error"] as? String) ?? "The LATO.2 job failed."
            return JobSnapshot(state: .failed(message), progress: progress, files: [])
        default:
            return JobSnapshot(
                state: .running, progress: progress ?? reported.fraction,
                files: files, reported: reported
            )
        }
    }
}

// MARK: - Log interpretation

/// Turns backend log lines into user-facing stages, keeping the last stage so a stream of
/// similar lines does not spam identical events.
private actor MeshStageBox {
    private var lastStage: String?
    private let progressPattern = /(\d+)\s*\/\s*(\d+)/

    private func stage(_ text: String) -> MeshEvent? {
        guard text != lastStage else { return nil }
        lastStage = text
        return .stage(text)
    }

    func interpretTrellis(_ line: String) -> MeshEvent? {
        let lower = line.lowercased()
        if lower.contains("download") || lower.contains("fetching") {
            return stage("Downloading weights (first run, ~13 GB)…")
        }
        if lower.contains("loading") && lower.contains("pipeline") {
            return stage("Loading the pipeline…")
        }
        if lower.contains("sparse structure") {
            return stage("Sampling the rough shape…")
        }
        if lower.contains("shape") && lower.contains("slat") {
            return stage("Refining geometry…")
        }
        if lower.contains("tex") && lower.contains("slat") {
            return stage("Generating surface detail…")
        }
        if lower.contains("simplif") {
            return stage("Simplifying the mesh…")
        }
        if lower.contains("bake") || lower.contains("uv") || lower.contains("unwrap")
            || lower.contains("xatlas")
        {
            return stage("Baking the texture…")
        }
        if let match = line.firstMatch(of: progressPattern),
           let step = Int(match.1), let total = Int(match.2), total > 1, step <= total
        {
            return .progress(Double(step) / Double(total))
        }
        return nil
    }

    /// hy3d prints `  [ 62%] Denoising (26/30)` — a percentage and a stage on every line.
    private let hy3dPattern = /\[\s*(\d+)%\]\s*(.+)/

    func interpretHunyuan(_ line: String) -> MeshEvent? {
        if let match = line.firstMatch(of: hy3dPattern), let percent = Int(match.1) {
            let text = String(match.2).trimmingCharacters(in: .whitespaces)
            if text != lastStage {
                lastStage = text
                return .stage(text + "…")
            }
            return .progress(Double(percent) / 100)
        }
        if line.lowercased().hasPrefix("shape:") {
            return stage("Loading weights…")
        }
        return nil
    }
}
