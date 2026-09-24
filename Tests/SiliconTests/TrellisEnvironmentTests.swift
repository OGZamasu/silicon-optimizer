import Foundation
import Testing
@testable import SiliconRuntime

/// TRELLIS.2's recipe runs generate.py with the Metal extension overlay on `PYTHONPATH`, MPS
/// fallback on, unbuffered output and the venv's torch libraries on the dyld fallback path.
/// The runtime built that environment and then started the process without it. Here a
/// stand-in `python` in a scratch trellis folder records what it was given.
@Suite("TRELLIS.2 child environment")
struct TrellisEnvironmentTests {

    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("trellis-env-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func theRecipeIncludesTheVenvsTorchLibraries() throws {
        let base = try scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let venv = base.appendingPathComponent("trellis-mac/.venv", isDirectory: true)
        let torch = venv.appendingPathComponent("lib/python3.11/site-packages/torch/lib")
        try FileManager.default.createDirectory(at: torch, withIntermediateDirectories: true)

        let environment = TrellisRuntime.childEnvironment(base: base, venv: venv)
        #expect(environment["PYTHONPATH"] == base.appendingPathComponent("metal_overlay").path)
        #expect(environment["PYTORCH_ENABLE_MPS_FALLBACK"] == "1")
        #expect(environment["PYTHONUNBUFFERED"] == "1")
        let dyld = try #require(environment["DYLD_FALLBACK_LIBRARY_PATH"])
        #expect(URL(fileURLWithPath: dyld).resolvingSymlinksInPath().path
                == torch.resolvingSymlinksInPath().path)
    }

    @Test func generateHandsTheRecipeToTheProcess() async throws {
        let base = try scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let bin = base.appendingPathComponent("trellis-mac/.venv/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let record = base.appendingPathComponent("child-environment.txt")
        // What it was run with, then the mesh generate.py would write at `--output`.
        let python = bin.appendingPathComponent("python")
        try """
            #!/bin/sh
            printf 'PYTHONPATH=%s\\nPYTORCH_ENABLE_MPS_FALLBACK=%s\\nPYTHONUNBUFFERED=%s\\n' \
                "$PYTHONPATH" "$PYTORCH_ENABLE_MPS_FALLBACK" "$PYTHONUNBUFFERED" > "\(record.path)"
            out=""
            while [ $# -gt 0 ]; do
                if [ "$1" = --output ]; then out="$2"; fi
                shift
            done
            : > "$out.glb"
            """.write(to: python, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
        let image = base.appendingPathComponent("source.png")
        try Data([0]).write(to: image)
        let output = base.appendingPathComponent("out", isDirectory: true)

        let stream = try await TrellisRuntime(base: base).generate(
            MeshRequest(image: image, outputDirectory: output, baseName: "mesh")
        )
        var finished = false
        for try await event in stream {
            if case .finished = event { finished = true }
        }
        #expect(finished)

        let lines = try String(contentsOf: record, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        #expect(lines.contains("PYTHONPATH=\(base.appendingPathComponent("metal_overlay").path)"),
                "generate.py ran without the Metal extension overlay")
        #expect(lines.contains("PYTORCH_ENABLE_MPS_FALLBACK=1"))
        #expect(lines.contains("PYTHONUNBUFFERED=1"))
    }
}
