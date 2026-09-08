import Testing
@testable import SiliconCatalog
@testable import SiliconControl
@testable import SiliconUI

@Suite("Video duration contract")
struct VideoDurationTests {

    @Test func pickerIncludesLongClips() {
        #expect(ControlAPI.VideoGenerateRequest.pickerSeconds == [3, 5, 8, 10, 15])
    }

    @Test func controlRequestsClampToThePublishedRange() {
        #expect(ControlAPI.VideoGenerateRequest.clampedSeconds(-1) == 1)
        #expect(ControlAPI.VideoGenerateRequest.clampedSeconds(10) == 10)
        #expect(ControlAPI.VideoGenerateRequest.clampedSeconds(15) == 15)
        #expect(ControlAPI.VideoGenerateRequest.clampedSeconds(99) == 15)
    }

    @Test func eachVideoModelPublishesOnlyTheLengthsItCanRun() {
        #expect(VideoCatalog.wan22.supportedSeconds == [3, 5, 8])
        #expect(VideoCatalog.ltx2.supportedSeconds == [3, 5, 8, 10, 15])
        #expect(VideoCatalog.hailuoH3.supportedSeconds == [3, 5, 10, 15])

        #expect(VideoCatalog.ltx2.normalizedSeconds(8) == 8)
        #expect(VideoCatalog.hailuoH3.normalizedSeconds(8) == 10)
        #expect(VideoCatalog.wan22.normalizedSeconds(15) == 8)
    }

    @Test @MainActor func videoRoutingRequiresTheExactReadyEnabledCapability() {
        func capability(
            id: String, kind: String = "video", ready: Bool = true,
            enabled: Bool? = nil
        ) -> AppModel.PeerCapability {
            .init(
                id: id, kind: kind, ready: ready, peakGB: nil,
                typicalSeconds: nil, detail: nil, description: nil,
                enabled: enabled, settings: [:]
            )
        }

        #expect(AppModel.isReadyVideoCapability(
            capability(id: "ltx2-distilled"), for: VideoCatalog.ltx2
        ))
        #expect(!AppModel.isReadyVideoCapability(
            capability(id: "wan22-ti2v-5b"), for: VideoCatalog.ltx2
        ))
        #expect(!AppModel.isReadyVideoCapability(
            capability(id: "text-to-video"), for: VideoCatalog.ltx2
        ))
        #expect(AppModel.isReadyVideoCapability(
            capability(id: "text-to-video"), for: VideoCatalog.wan22
        ))
        #expect(!AppModel.isReadyVideoCapability(
            capability(id: "ltx2-distilled", kind: "image"), for: VideoCatalog.ltx2
        ))
        #expect(!AppModel.isReadyVideoCapability(
            capability(id: "ltx2-distilled", ready: false), for: VideoCatalog.ltx2
        ))
        #expect(!AppModel.isReadyVideoCapability(
            capability(id: "ltx2-distilled", enabled: false), for: VideoCatalog.ltx2
        ))

        var wrongModel = AppModel.PeerStatus(
            name: "wan-node", baseURL: "http://wan", reachable: true
        )
        wrongModel.capabilities = [capability(id: "wan22-ti2v-5b")]
        var disabledH3 = AppModel.PeerStatus(
            name: "disabled-h3", baseURL: "http://disabled", reachable: true
        )
        disabledH3.capabilities = [capability(id: "hailuo-h3", enabled: false)]
        var h3 = AppModel.PeerStatus(
            name: "phosphene", baseURL: "http://phosphene", reachable: true
        )
        h3.capabilities = [capability(id: "hailuo-h3")]
        var unreachableH3 = AppModel.PeerStatus(
            name: "offline-h3", baseURL: "http://offline", reachable: false
        )
        unreachableH3.capabilities = [capability(id: "hailuo-h3")]

        let selected = AppModel.videoCapableNode(
            for: VideoCatalog.hailuoH3,
            among: [wrongModel, disabledH3, unreachableH3, h3]
        )
        #expect(selected?.name == "phosphene")
    }
}
