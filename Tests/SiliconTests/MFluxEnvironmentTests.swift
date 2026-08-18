import Foundation
import Testing
@testable import SiliconRuntime

/// mflux fetches its own weights rather than going through this app's `HuggingFaceClient`, so a
/// gated repository is only reachable if the token reaches the child process. A GUI app launched
/// from the Dock inherits no shell environment either, so there is no fallback path — if these
/// are not set, "accept the licence" is shown to someone who already has.
@Suite("MFLUX child environment")
struct MFluxEnvironmentTests {

    @Test func passesTheTokenUnderBothNames() {
        let environment = MFluxRuntime.childEnvironment(huggingFaceToken: "hf_example")
        #expect(environment["HF_TOKEN"] == "hf_example")
        // huggingface_hub still honours the older name, and which one applies depends on the
        // version resolved as a transitive dependency rather than on anything we control.
        #expect(environment["HUGGING_FACE_HUB_TOKEN"] == "hf_example")
    }

    @Test func alwaysUnbuffersOutput() {
        // Progress is parsed from stderr as it streams; buffering it would stall the progress bar
        // until the run finished.
        #expect(MFluxRuntime.childEnvironment(huggingFaceToken: nil)["PYTHONUNBUFFERED"] == "1")
        #expect(MFluxRuntime.childEnvironment(huggingFaceToken: "hf_x")["PYTHONUNBUFFERED"] == "1")
    }

    @Test func omitsTheTokenWhenThereIsNone() {
        let environment = MFluxRuntime.childEnvironment(huggingFaceToken: nil)
        #expect(environment["HF_TOKEN"] == nil)
        #expect(environment["HUGGING_FACE_HUB_TOKEN"] == nil)
    }

    /// An empty Settings field must not become an empty credential. `huggingface_hub` treats a
    /// set-but-empty `HF_TOKEN` as an explicit anonymous credential, which fails differently —
    /// and less legibly — than sending no token at all.
    @Test(arguments: ["", "   ", "\n", " \t "])
    func treatsBlankTokensAsAbsent(_ blank: String) {
        let environment = MFluxRuntime.childEnvironment(huggingFaceToken: blank)
        #expect(environment["HF_TOKEN"] == nil)
        #expect(environment["HUGGING_FACE_HUB_TOKEN"] == nil)
    }

    @Test func trimsSurroundingWhitespace() {
        // Pasting a token from a browser commonly brings a trailing newline with it.
        let environment = MFluxRuntime.childEnvironment(huggingFaceToken: "  hf_example\n")
        #expect(environment["HF_TOKEN"] == "hf_example")
    }
}
