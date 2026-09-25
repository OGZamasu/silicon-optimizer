import Foundation
import Testing
@testable import SiliconCatalog
import SiliconCore
import SiliconHardware
@testable import SiliconPlanner
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

    /// The prompt travels attached to its flag, so one that starts with "-" is a prompt to
    /// mflux's argparse, not an option it refuses ("expected one argument").
    @Test func thePromptIsAttachedToItsFlag() {
        let carrier = InstalledModel(
            id: "flux2-klein-4b", name: "FLUX.2 klein 4B", catalogID: "flux2-klein-4b",
            quantization: .mlx4, format: .mlx,
            primaryFile: URL(fileURLWithPath: "/tmp/out.png"), allFiles: [],
            projectorFile: nil, sizeOnDisk: .zero, installedAt: Date(),
            shape: nil, capabilities: []
        )
        let arguments = MFluxArguments(
            request: ImageRequest(prompt: "-a dash first, --steps 99", output: URL(fileURLWithPath: "/tmp/out.png")),
            model: carrier
        ).build()
        #expect(arguments.contains("--prompt=-a dash first, --steps 99"))
        #expect(!arguments.contains("--prompt"))
        #expect(arguments.firstIndex(of: "--steps").map { arguments[$0 + 1] } != "99")
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

/// What 0.20.0's quantization predicates mean for the planner. Checked across every family in
/// the catalogue: only Qwen-Image's changed — `QwenWeightDefinition.quantization_predicate`
/// keeps `img_mod_linear` at 8-bit when asked for 4 — and FLUX.1, FLUX.2, Z-Image, ERNIE and
/// Qwen-Image 2.1 still quantize every quantizable layer at the bit width asked for.
@Suite("MFLUX 0.20.0 quantization in the plan")
struct MFluxQuantizationPlanTests {

    static let m3Max36 = SystemProfile(
        chipName: "Apple M3 Max", generation: .m3, variant: .max, modelIdentifier: "Mac15,11",
        totalMemory: .gib(36), performanceCores: 10, efficiencyCores: 4, gpuCores: 30,
        neuralEngineCores: 16, diskTotal: .gib(1024), diskFree: .gib(500),
        memoryBandwidthGBps: 300, ssdReadMBps: 5000
    )

    /// 60 blocks of a 3072 → 18432 projection, about 1.70 GB more at 4-bit than the naive
    /// all-4-bit figure, and nothing more at 6 or 8.
    @Test func qwenImageKeepsItsModulationLayersAt8BitWhenAskedFor4() {
        let shape = DiffusionCatalog.qwenImage.shape
        #expect(shape.parametersKeptAt8BitWhen4Bit == 3_397_386_240)
        let naive = DiffusionPlanner.weightBytes(shape.transformerParameters, .mlx4)
        let protected = DiffusionPlanner.quantizedTransformerBytes(shape, .mlx4)
        let delta = Double((protected - naive).rawValue) / 1e9
        #expect(delta > 1.69 && delta < 1.71, "\(delta) GB")
        for quantization in [Quantization.mlx6, .mlx8] {
            #expect(DiffusionPlanner.quantizedTransformerBytes(shape, quantization)
                    == DiffusionPlanner.weightBytes(shape.transformerParameters, quantization))
        }
        // A streamed block carries its share.
        let block = DiffusionPlanner.quantizedTransformerBytes(shape, .mlx4, parameters: shape.parametersPerBlock)
        let naiveBlock = DiffusionPlanner.weightBytes(shape.parametersPerBlock, .mlx4)
        #expect(abs(Double((block - naiveBlock).rawValue) * 60 - Double((protected - naive).rawValue)) < 1e6)
    }

    /// Every phase that holds the transformer at its quantized size moves by that much at
    /// 4-bit: the encode stage, and the load of a copy already at 4-bit. The denoise and decode
    /// stages charge the running transformer at the measured two bytes a parameter, which is
    /// above its 8-bit size, so they — and Qwen-Image's peak, the decode — do not.
    @Test func qwenImagesFourBitPlanCarriesTheProtectedLayers() {
        let planner = DiffusionPlanner(profile: Self.m3Max36)
        var unprotectedShape = DiffusionCatalog.qwenImage.shape
        unprotectedShape.parametersKeptAt8BitWhen4Bit = 0
        let delta = DiffusionPlanner.quantizedTransformerBytes(DiffusionCatalog.qwenImage.shape, .mlx4)
            - DiffusionPlanner.weightBytes(unprotectedShape.transformerParameters, .mlx4)
        #expect(Double(delta.rawValue) / 1e9 > 1.69, "the protected layers cost ~1.7 GB at 4-bit")
        func phases(_ shape: DiffusionShape, prequantized: Bool) -> [String: Bytes] {
            let plan = planner.plan(shape: shape, configuration: ImageConfiguration(
                width: 1024, height: 1024, steps: 20, quantization: .mlx4,
                weightsArePrequantized: prequantized, canReuseQuantizedSave: false
            ))
            return Dictionary(uniqueKeysWithValues: plan.phases.map { ($0.name, $0.resident) })
        }
        for prequantized in [false, true] {
            let now = phases(DiffusionCatalog.qwenImage.shape, prequantized: prequantized)
            let before = phases(unprotectedShape, prequantized: prequantized)
            let encode = (now["Encode"]! - before["Encode"]!).rawValue
            #expect(abs(encode - delta.rawValue) <= 2, "encode moves by the protected layers")
            if prequantized {
                #expect(abs((now["Load"]! - before["Load"]!).rawValue - delta.rawValue) <= 2)
            } else {
                // Loading unquantized reads the transformer at full precision regardless.
                #expect(now["Load"] == before["Load"])
            }
            #expect(now["Denoise"] == before["Denoise"])
            #expect(now["Decode"] == before["Decode"])
        }
    }

    @Test func noOtherEntryProtectsAnything() {
        for entry in DiffusionCatalog.all where entry.id != DiffusionCatalog.qwenImage.id {
            #expect(entry.shape.parametersKeptAt8BitWhen4Bit == 0, "\(entry.id)")
            #expect(DiffusionPlanner.quantizedTransformerBytes(entry.shape, .mlx4)
                    == DiffusionPlanner.weightBytes(entry.shape.transformerParameters, .mlx4))
        }
    }
}
