import Testing
@testable import SiliconControl

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
}
