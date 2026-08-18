import Foundation
import Testing
@testable import SiliconCatalog
@testable import SiliconCore
@testable import SiliconPlanner
@testable import SiliconRuntime

@Suite("Image revision (img2img)")
struct ImageRevisionTests {

    private func carrier() -> InstalledModel {
        InstalledModel(
            id: "flux2-klein-4b", name: "FLUX.2 klein 4B", catalogID: "flux2-klein-4b",
            quantization: .mlx4, format: .mlx,
            primaryFile: URL(fileURLWithPath: "/tmp/out.png"), allFiles: [],
            projectorFile: nil, sizeOnDisk: .zero, installedAt: Date(),
            shape: nil, capabilities: []
        )
    }

    /// mflux's current form is the atomic `--image PATH STRENGTH`; the split
    /// `--image-path`/`--image-strength` pair is deprecated upstream.
    @Test func revisionPassesTheAtomicImageFlag() {
        let request = ImageRequest(
            prompt: "make the shelf walnut",
            configuration: ImageConfiguration(
                initImage: URL(fileURLWithPath: "/tmp/base.png"),
                initImageInfluence: 0.7
            ),
            output: URL(fileURLWithPath: "/tmp/out.png")
        )
        let arguments = MFluxArguments(request: request, model: carrier()).build()
        guard let index = arguments.firstIndex(of: "--image") else {
            Issue.record("--image flag missing: \(arguments)")
            return
        }
        #expect(arguments[index + 1] == "/tmp/base.png")
        #expect(arguments[index + 2] == "0.7")
        #expect(!arguments.contains("--image-path"))
    }

    /// A plain generation must not grow an --image flag by accident.
    @Test func plainGenerationHasNoImageFlag() {
        let request = ImageRequest(
            prompt: "a red sneaker",
            configuration: ImageConfiguration(),
            output: URL(fileURLWithPath: "/tmp/out.png")
        )
        let arguments = MFluxArguments(request: request, model: carrier()).build()
        #expect(!arguments.contains("--image"))
    }

    /// The revision fields survive Codable — presets and the control API depend on it.
    @Test func configurationRoundTripsRevisionFields() throws {
        var configuration = ImageConfiguration()
        configuration.initImage = URL(fileURLWithPath: "/tmp/base.png")
        configuration.initImageInfluence = 0.35
        let decoded = try JSONDecoder().decode(
            ImageConfiguration.self, from: JSONEncoder().encode(configuration)
        )
        #expect(decoded.initImage == configuration.initImage)
        #expect(decoded.initImageInfluence == 0.35)
    }
}
