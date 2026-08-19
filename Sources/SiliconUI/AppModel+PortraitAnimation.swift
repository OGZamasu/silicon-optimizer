import AppKit
import Foundation
import SiliconRuntime
import UniformTypeIdentifiers

/// Photoreal animation: the character's portrait, moved by a recorded performance.
extension AppModel {

    public var portraitAnimatorInstallation: PortraitAnimator.Installation {
        PortraitAnimator.installation()
    }

    public var isAnimatingPortrait: Bool {
        if case .running = portraitAnimationState { return true }
        return false
    }

    /// How far in, when the renderer says. Nil while nothing is measurable.
    public var portraitAnimationProgress: Double? {
        guard case .running(_, let progress) = portraitAnimationState, progress > 0
        else { return nil }
        return progress
    }

    public var portraitAnimationStage: String {
        switch portraitAnimationState {
        case .running(let stage, let progress):
            // A stage that already names its own percentage — everything a node sends does —
            // must not get a second one stapled on.
            progress > 0.05 && !stage.contains("%") ? "\(stage) — \(Int(progress * 100))%" : stage
        case .finished: "Done"
        case .failed(let message): message
        case .idle: ""
        }
    }

    /// A swarm node that can do this far faster than this Mac can. LivePortrait
    /// takes about 740 ms a frame here and 13 ms on a 4090, so when a node offers the
    /// capability it is not a close call.
    public var portraitAnimationNode: PeerStatus? {
        swarmPeers.first { peer in
            peer.reachable && peer.capabilities.contains {
                ["talking-head", "portrait-animate"].contains($0.kind) && $0.ready
            }
        }
    }

    /// Animates the selected character with a driving video the user picks. The
    /// result joins the video results like any other clip.
    public func animatePortrait(with driving: URL) {
        guard let persona = selectedPersona, let portrait = persona.portraitURL else {
            personaError = "Pick a character with a portrait first."
            return
        }
        guard !isAnimatingPortrait else { return }
        // A capable node beats this Mac by a factor of fifty; take it when it is there.
        if let node = portraitAnimationNode {
            animatePortraitRemotely(persona: persona, portrait: portrait,
                                    driving: driving, node: node)
            return
        }
        guard portraitAnimatorInstallation.isInstalled else {
            personaError = portraitAnimatorInstallation.detail
            return
        }

        portraitAnimationState = .running(stage: "Starting…", progress: 0)
        personaError = nil
        noteActivity()

        let animator = portraitAnimator ?? PortraitAnimator()
        portraitAnimator = animator
        let destination = settings.resolvedVideoOutputDirectory
            .appendingPathComponent("Photoreal", isDirectory: true)
        let name = persona.name

        Task {
            do {
                let file = try await animator.animate(
                    portrait: portrait, driving: driving, outputDirectory: destination
                ) { state in
                    Task { @MainActor in self.portraitAnimationState = state }
                }
                videoResults.insert(
                    VideoResult(
                        file: file, modelName: "\(name) (LivePortrait)",
                        prompt: "Driven by \(driving.lastPathComponent)", elapsed: 0
                    ),
                    at: 0
                )
                portraitAnimationState = .idle
            } catch {
                portraitAnimationState = .failed(message: error.localizedDescription)
                personaError = error.localizedDescription
            }
        }
    }

    /// Sends the job to a node and brings the clip back, in the same shape as every
    /// other delegated job: submit, poll, download.
    private func animatePortraitRemotely(
        persona: Persona, portrait: URL, driving: URL, node: PeerStatus
    ) {
        guard let base = URL(string: node.baseURL.trimmingCharacters(in: .whitespaces))
        else { return }
        portraitAnimationState = .running(stage: "Sending to \(node.name)…", progress: 0)
        personaError = nil
        noteActivity()

        let token = swarmConfig?.effectiveToken
        let destination = settings.resolvedVideoOutputDirectory
            .appendingPathComponent("Photoreal", isDirectory: true)
        let name = persona.name
        let runtime = videoRuntime

        Task {
            do {
                let file = try await runtime.animatePortrait(
                    portrait: portrait, driving: driving, node: base, token: token,
                    outputDirectory: destination
                ) { progress in
                    Task { @MainActor in
                        // The node's own numbers, not the half-way guess this used to show.
                        self.portraitAnimationState = .running(
                            stage: progress.line(fallback: "Animating on the node"),
                            progress: progress.fraction ?? 0
                        )
                    }
                }
                videoResults.insert(
                    VideoResult(
                        file: file, modelName: "\(name) (on \(node.name))",
                        prompt: "Driven by \(driving.lastPathComponent)", elapsed: 0
                    ),
                    at: 0
                )
                portraitAnimationState = .idle
            } catch {
                portraitAnimationState = .failed(message: error.localizedDescription)
                personaError = error.localizedDescription
            }
        }
    }

    public func cancelPortraitAnimation() {
        portraitAnimationState = .idle
        Task { await portraitAnimator?.cancel() }
    }

    /// Installs LivePortrait into its own environment.
    ///
    /// Its dependencies pin versions that only have wheels up to Python 3.11, so the
    /// environment is built on that specific version through `uv` — the app's other
    /// Python tools are on newer runtimes and cannot host it.
    public func installPortraitAnimator() {
        let environment = PortraitAnimator.environment
        let repository = PortraitAnimator.repository
        var steps: [RepairStep] = []

        guard let uv = Self.uvPath else {
            personaError = "Photoreal animation needs `uv` to build its environment "
                + "(`brew install uv`), because its dependencies only publish builds "
                + "for an older Python."
            return
        }

        if !FileManager.default.fileExists(atPath: repository.path) {
            steps.append(RepairStep(
                executable: URL(fileURLWithPath: "/usr/bin/git"),
                arguments: [
                    "clone", "--depth", "1",
                    "https://github.com/KwaiVGI/LivePortrait.git", repository.path,
                ],
                currentDirectory: nil,
                label: "Downloading LivePortrait —"
            ))
        }
        steps.append(RepairStep(
            executable: URL(fileURLWithPath: uv),
            arguments: [
                "venv", "--python", "3.11",
                environment.appendingPathComponent("venv").path,
            ],
            currentDirectory: nil,
            label: "Making its Python environment —"
        ))
        steps.append(RepairStep(
            executable: URL(fileURLWithPath: uv),
            arguments: [
                "pip", "install",
                "--python", PortraitAnimator.python.path,
                // Its requirements span PyPI and PyTorch's own index, which is what
                // this allows; both are named by the project itself.
                "--index-strategy", "unsafe-best-match",
                "-r", repository.appendingPathComponent("requirements_macOS.txt").path,
                // Their vendored insightface imports `requests` without declaring
                // it, so the first run dies on an import unless it is added here.
                "huggingface_hub", "requests",
            ],
            currentDirectory: repository,
            label: "Installing its tools (several minutes) —"
        ))
        steps.append(RepairStep(
            executable: environment.appendingPathComponent("venv/bin/hf"),
            arguments: [
                "download", "KwaiVGI/LivePortrait",
                "--local-dir", repository.appendingPathComponent("pretrained_weights").path,
            ],
            currentDirectory: repository,
            label: "Fetching the weights (about 2 GB) —"
        ))

        runRepair(id: "portrait-animator-install", steps: steps) { }
    }

    static var uvPath: String? {
        ["/opt/homebrew/bin/uv", "/usr/local/bin/uv"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Asks for the performance to copy: any video with a face in it.
    public func pickDrivingVideo() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a video of a face — its motion is what the character copies."
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }
}
