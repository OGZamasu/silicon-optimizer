import Foundation
import Testing
@testable import SiliconCatalog
@testable import SiliconRuntime

/// The command lines the app hands MFLUX, held to what mflux 0.20.0 actually reads.
///
/// Pure: nothing here runs mflux or touches a cache. The facts pinned below were read from the
/// 0.20.0 source (`pyproject.toml`'s entry points, `ModelConfig`, the qwen entry point) when
/// the lock moved from 0.18.1.
@Suite("MFLUX 0.20.0 command lines")
struct MFluxVersionTests {

    private func arguments(for entry: DiffusionEntry) -> (executable: String, arguments: [String]) {
        let carrier = InstalledModel(
            id: entry.id, name: entry.name, catalogID: entry.id,
            quantization: .mlx4, format: .mlx,
            primaryFile: URL(fileURLWithPath: "/tmp/out.png"), allFiles: [],
            projectorFile: nil, sizeOnDisk: .zero, installedAt: Date(),
            shape: nil, capabilities: []
        )
        let builder = MFluxArguments(
            request: ImageRequest(prompt: "a lighthouse", output: URL(fileURLWithPath: "/tmp/out.png")),
            model: carrier
        )
        return (builder.executableName, builder.build())
    }

    /// `mflux-generate-qwen` takes a built-in name as "use my default", and its default moved
    /// from Qwen/Qwen-Image to Qwen/Qwen-Image-2512 — which `qwen` now also names. Passing the
    /// repository is the only spelling that still loads the model the installer fetched.
    @Test func qwenImageNamesItsRepositoryRatherThanAnAlias() throws {
        let (executable, arguments) = arguments(for: DiffusionCatalog.qwenImage)
        #expect(executable == "mflux-generate-qwen")
        let index = try #require(arguments.firstIndex(of: "--model"))
        #expect(arguments[index + 1] == DiffusionCatalog.qwenImage.repository)
        #expect(arguments[index + 1] == "Qwen/Qwen-Image")
        #expect(!arguments.contains("qwen"))
    }

    /// Every entry point the catalogue relies on is one 0.20.0 installs.
    @Test func everyEntryPointExistsInTheLockedRelease() {
        // From `[project.scripts]` in mflux 0.20.0's pyproject.toml.
        let installed: Set<String> = [
            "mflux-generate", "mflux-generate-flux2", "mflux-generate-qwen",
            "mflux-generate-qwen-2.1", "mflux-generate-z-image", "mflux-generate-z-image-turbo",
            "mflux-generate-ernie-image", "mflux-generate-ernie-image-turbo",
        ]
        for entry in DiffusionCatalog.all {
            let executable = MFluxArguments.executableName(for: entry.id)
            // Qwen-Image 2.1 runs the app's runner on the environment's own Python — which
            // is 0.20 only if the 2.1 entry point is installed beside it.
            let isQwen21 = entry.weightsRepository == DiffusionCatalog.qwenImage21.repository
            let expected = isQwen21 ? [MFluxArguments.runnerInterpreter] : installed
            #expect(expected.contains(executable), "\(entry.id) runs \(executable)")
        }
        #expect(installed.contains(MFluxRuntime.qwenImage21EntryPoint))
    }

    /// The other families keep the aliases 0.20.0 still resolves to the same repositories.
    @Test func unchangedFamiliesKeepTheirAliases() {
        let expected = [
            "flux1-schnell": "schnell", "flux1-dev": "dev", "flux1-krea-dev": "krea-dev",
            "flux2-klein-4b": "flux2-klein-4b", "flux2-klein-9b": "flux2-klein-9b",
            "z-image-turbo": "z-image-turbo", "z-image": "z-image",
            "ernie-image-turbo": "ernie-image-turbo", "ernie-image": "ernie-image",
        ]
        for (id, alias) in expected {
            #expect(MFluxArguments.mfluxAlias(id) == alias, "\(id)")
        }
    }
}
