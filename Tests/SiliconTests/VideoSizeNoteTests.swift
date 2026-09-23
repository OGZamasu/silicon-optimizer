import Testing
@testable import SiliconUI

/// The Size picker's one line of honesty about LTX-2 at 1080p.
@Suite("Video size note")
struct VideoSizeNoteTests {
    @Test func ltxAt1080pSaysItIsUpscaledAndNothingElseSaysAnything() {
        let local = AppModel.videoSizeNote(modelID: "ltx2-distilled", resolution: "1080p",
                                           capabilityID: "ltx2-distilled")
        #expect(local?.contains("768×448") == true && local?.contains("same detail as 720p") == true)
        // A node that serves the model through the generic capability is not promised
        // the local adapter's canvas, only what is true of LTX-2 everywhere.
        let generic = AppModel.videoSizeNote(modelID: "ltx2-distilled", resolution: "1080p",
                                             capabilityID: "text-to-video")
        #expect(generic?.contains("not generate 1080p natively") == true)
        #expect(generic?.contains("768×448") == false)
        #expect(AppModel.videoSizeNote(modelID: "ltx2-distilled", resolution: "1080p", capabilityID: nil) == generic)
        for (model, size) in [("ltx2-distilled", "720p"), ("ltx2-distilled", "480p"),
                              ("hailuo-h3", "1080p"), ("wan22-ti2v-5b", "720p")] {
            #expect(AppModel.videoSizeNote(modelID: model, resolution: size,
                                           capabilityID: model) == nil, "\(model) \(size)")
        }
    }
}
