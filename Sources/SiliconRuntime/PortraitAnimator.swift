import Foundation

/// Photoreal portrait animation: a still picture of a character, driven by a recorded
/// performance, through LivePortrait.
///
/// This is the high-fidelity counterpart to the app's own puppet. The puppet is
/// instant and honest about being a puppet; this actually moves the face — eyes,
/// brows, mouth shape — because the model was trained on 69 million frames of people
/// doing exactly that.
///
/// It is deliberately offline. LivePortrait runs at 12.8 ms a frame on a 4090 and
/// roughly twenty times slower on Apple Silicon, so on this Mac it is a renderer, not
/// a live camera. The live path is the face swap; when the CUDA node offers this as a
/// capability, the same button can send the job there instead.
public actor PortraitAnimator {

    public enum State: Sendable, Equatable {
        case idle
        case running(stage: String, progress: Double)
        case finished(url: URL)
        case failed(message: String)
    }

    public struct Installation: Sendable {
        public var isInstalled: Bool
        public var detail: String
    }

    private var process: ServerProcess?

    public init() {}

    public nonisolated static var environment: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".silicon-liveportrait")
    }

    public nonisolated static var python: URL {
        environment.appendingPathComponent("venv/bin/python3")
    }

    public nonisolated static var repository: URL {
        environment.appendingPathComponent("LivePortrait")
    }

    public nonisolated static var weights: URL {
        repository.appendingPathComponent("pretrained_weights/liveportrait")
    }

    public nonisolated static func installation() -> Installation {
        let manager = FileManager.default
        guard manager.isExecutableFile(atPath: python.path),
              manager.fileExists(atPath: repository.appendingPathComponent("inference.py").path)
        else {
            return Installation(
                isInstalled: false,
                detail: "Photoreal animation isn't set up yet. It installs LivePortrait "
                    + "and about 2 GB of weights."
            )
        }
        guard manager.fileExists(atPath: weights.path) else {
            return Installation(
                isInstalled: false,
                detail: "LivePortrait's weights haven't finished downloading."
            )
        }
        return Installation(isInstalled: true, detail: "Ready.")
    }

    /// Animates `portrait` with the motion in `driving`, writing an MP4 into
    /// `outputDirectory` and returning where it landed.
    public func animate(
        portrait: URL,
        driving: URL,
        outputDirectory: URL,
        onState: @escaping @Sendable (State) -> Void
    ) async throws -> URL {
        let installation = Self.installation()
        guard installation.isInstalled else {
            throw Failure.notInstalled(installation.detail)
        }
        try FileManager.default.createDirectory(
            at: outputDirectory, withIntermediateDirectories: true
        )

        let process = ServerProcess()
        self.process = process
        onState(.running(stage: "Loading the model…", progress: 0))

        try await process.start(
            executable: Self.python,
            arguments: [
                "inference.py",
                "-s", portrait.path,
                "-d", driving.path,
                "-o", outputDirectory.path,
            ],
            // Some of LivePortrait's operations have no Metal kernel; without the
            // fallback the run dies partway through instead of finishing slower.
            environment: [
                "PYTHONUNBUFFERED": "1",
                "PYTORCH_ENABLE_MPS_FALLBACK": "1",
            ],
            currentDirectory: Self.repository,
            onLogLine: { line in
                if let state = Self.interpret(line) { onState(state) }
            }
        )

        while await process.isRunning {
            if Task.isCancelled {
                await process.terminate()
                throw Failure.cancelled
            }
            try? await Task.sleep(for: .milliseconds(300))
        }

        let log = await process.log
        guard let produced = Self.newestVideo(in: outputDirectory) else {
            throw Failure.failed(Self.diagnosis(from: log))
        }
        onState(.finished(url: produced))
        return produced
    }

    public func cancel() async {
        await process?.terminate()
    }

    // MARK: - Reading its output

    /// LivePortrait narrates with a progress bar and a handful of stage lines; this
    /// keeps the parts worth showing and drops the rest.
    static func interpret(_ line: String) -> State? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.contains("Load") && trimmed.contains("done") {
            return .running(stage: "Model loaded", progress: 0.1)
        }
        if let percent = progressPercentage(in: trimmed) {
            return .running(stage: "Animating", progress: percent)
        }
        if trimmed.contains("Animated video") || trimmed.contains("concat") {
            return .running(stage: "Writing the video", progress: 0.95)
        }
        return nil
    }

    /// tqdm writes bars like `  42%|████  | 42/100`; the number before the first
    /// percent sign is the only part worth reading.
    static func progressPercentage(in line: String) -> Double? {
        guard let percentIndex = line.firstIndex(of: "%") else { return nil }
        let digits = line[..<percentIndex].suffix(while: { $0.isNumber })
        guard !digits.isEmpty, let value = Double(digits) else { return nil }
        return min(0.94, max(0, value / 100))
    }

    static func newestVideo(in directory: URL) -> URL? {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        return contents
            .filter { $0.pathExtension.lowercased() == "mp4" }
            .max { a, b in
                let dateA = (try? a.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                let dateB = (try? b.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                return dateA < dateB
            }
    }

    static func diagnosis(from log: String) -> String {
        if log.contains("No face detected") || log.contains("no face") {
            return "No face was found in the portrait, so there was nothing to animate."
        }
        if log.contains("out of memory") || log.contains("MPS backend out of memory") {
            return "The Mac ran out of memory partway through. A shorter driving "
                + "video, or a smaller portrait, will fit."
        }
        let lines = log.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains("%|") }
        return lines.suffix(2).joined(separator: " ")
    }

    public enum Failure: LocalizedError {
        case notInstalled(String)
        case failed(String)
        case cancelled

        public var errorDescription: String? {
            switch self {
            case .notInstalled(let detail): detail
            case .failed(let message): message
            case .cancelled: "Cancelled."
            }
        }
    }
}

private extension Substring {
    func suffix(while predicate: (Character) -> Bool) -> Substring {
        var index = endIndex
        while index > startIndex, predicate(self[self.index(before: index)]) {
            index = self.index(before: index)
        }
        return self[index...]
    }
}

private extension String {
    subscript(range: PartialRangeUpTo<String.Index>) -> Substring {
        self[startIndex..<range.upperBound]
    }
}
