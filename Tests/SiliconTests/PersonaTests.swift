import AVFoundation
import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import SiliconControl
@testable import SiliconUI

@Suite("Persona performance")
struct PersonaTests {

    /// A sine burst followed by silence: the mouth should open on the burst and be shut
    /// on the silence, because a puppet that keeps chewing through silence is the whole
    /// failure mode of amplitude-driven animation.
    @Test func envelopeTracksLoudnessAndSilence() {
        let sampleRate = 48_000.0
        var samples = [Float](repeating: 0, count: Int(sampleRate))     // 1 s
        for index in 0..<Int(sampleRate / 2) {                          // loud first half
            samples[index] = sin(Float(index) * 0.05) * 0.8
        }
        let envelope = PersonaAnimator.envelope(samples: samples, sampleRate: sampleRate)

        #expect(envelope.count == PersonaAnimator.fps)
        let loud = envelope[0..<(PersonaAnimator.fps / 2 - 1)]
        let quiet = envelope[(PersonaAnimator.fps / 2 + 1)...]
        #expect(loud.allSatisfy { $0 > 0.5 })
        #expect(quiet.allSatisfy { $0 < 0.01 })
    }

    @Test func silenceNeverGetsAmplifiedIntoMotion() {
        let envelope = PersonaAnimator.envelope(
            samples: [Float](repeating: 0, count: 4800), sampleRate: 48_000
        )
        #expect(!envelope.isEmpty)
        #expect(envelope.allSatisfy { $0 == 0 })
    }

    @Test func handlesEmptyAudioWithoutCrashing() {
        #expect(PersonaAnimator.envelope(samples: [], sampleRate: 48_000).isEmpty)
        #expect(PersonaAnimator.envelope(samples: [0.5], sampleRate: 0).isEmpty)
    }

    /// Mouths open faster than they close; the smoother must reflect that asymmetry or
    /// speech looks like a hinge.
    @Test func smoothingOpensFasterThanItCloses() {
        let opening = PersonaAnimator.smoothed([0, 1, 1, 1])
        let closing = PersonaAnimator.smoothed([1, 1, 0, 0])
        let openStep = opening[1] - opening[0]
        let closeStep = closing[1] - closing[2]
        #expect(openStep > closeStep)
        #expect(opening.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    @Test func jawTravelStaysWithinTheFace() {
        #expect(PersonaAnimator.jawDrop(level: 0) == 0)
        #expect(PersonaAnimator.jawDrop(level: 1) > 0)
        #expect(PersonaAnimator.jawDrop(level: 1) < 0.1)
        // Out-of-range input cannot push the jaw off the portrait.
        #expect(PersonaAnimator.jawDrop(level: 9) == PersonaAnimator.jawDrop(level: 1))
        #expect(PersonaAnimator.jawDrop(level: -3) == 0)
    }

    /// Travel scales to the face that was found: a small face in a big frame moves a
    /// small amount, and a face with no room moves barely at all.
    @Test func travelScalesToTheFaceThatWasFound() {
        let tight = FaceGeometry(mouthTop: 0.70, chin: 0.74, detected: true)
        let roomy = FaceGeometry(mouthTop: 0.55, chin: 0.90, detected: true)
        #expect(tight.travel < roomy.travel)
        #expect(tight.travel >= 0.01)
        #expect(roomy.travel <= 0.09)
    }

    @Test func overlayCarriesTheMouthLineItFound() {
        let broadcast = OverlayBroadcast.shared
        broadcast.setPortrait(Data([1]), name: "X", mouthTop: 0.71, openMouth: Data([2]))
        #expect(broadcast.state.mouthTop == 0.71)
        #expect(broadcast.state.hasOpenMouth)
        #expect(broadcast.openMouthPortrait?.count == 1)
        broadcast.setPortrait(nil, name: "")
        #expect(!broadcast.state.hasOpenMouth)
    }

    @Test func idleMotionStaysSubtleAndKeepsMoving() {
        let offsets = (0..<90).map { PersonaAnimator.idleOffset(frame: $0) }
        #expect(offsets.allSatisfy { abs($0.bob) <= 0.006 && abs($0.tilt) <= 0.3 })
        #expect(Set(offsets.map { $0.bob }).count > 30)
    }

    /// The overlay is what OBS renders; a browser source cannot set headers, so the
    /// page must carry its token, and it must composite over whatever is behind it.
    @Test func overlayPageIsSelfContainedAndTransparent() {
        let html = OverlayPage.html(token: "test-token-123")
        #expect(html.contains("test-token-123"))
        #expect(html.contains("background: transparent"))
        #expect(html.contains("/overlay/state?token="))
        #expect(html.contains("/overlay/portrait?token="))
        // Nothing may be fetched from off the machine — a stream overlay must not
        // depend on the internet being up.
        #expect(!html.contains("http://") && !html.contains("https://"))
    }

    @Test func broadcastCarriesStateAndBumpsPortraitVersion() {
        let broadcast = OverlayBroadcast.shared
        let before = broadcast.state.portraitVersion

        broadcast.setPortrait(Data([0x89, 0x50]), name: "Vale")
        #expect(broadcast.state.name == "Vale")
        #expect(broadcast.state.portraitVersion == before + 1)
        #expect(broadcast.portrait?.count == 2)

        broadcast.setSpeaking(true, level: 0.7, caption: "Hello there")
        #expect(broadcast.state.speaking)
        #expect(broadcast.state.level == 0.7)
        #expect(broadcast.state.caption == "Hello there")

        broadcast.setSpeaking(false, level: 0)
        #expect(!broadcast.state.speaking)
        // A caption left unset survives, so the line stays readable as it ends.
        #expect(broadcast.state.caption == "Hello there")

        broadcast.setPortrait(nil, name: "")
        broadcast.setSpeaking(false, level: 0, caption: "")
    }

    /// Personas are persisted settings; a decoder that forgets them wipes the cast.
    @Test func personasSurviveASettingsRoundTrip() throws {
        var settings = Settings()
        settings.personas = [
            Persona(
                name: "Vale", portraitPath: "/tmp/vale.png",
                voiceModelID: "luxtts", referenceAudioPath: "/tmp/vale.wav",
                voiceCredit: "J. Doe, paid session 2026-08", brief: "dry, unhurried"
            )
        ]
        settings.selectedPersonaID = settings.personas[0].id

        let data = try JSONEncoder().encode(settings)
        let restored = try JSONDecoder().decode(Settings.self, from: data)

        #expect(restored.personas.count == 1)
        #expect(restored.personas[0].name == "Vale")
        #expect(restored.personas[0].voiceCredit == "J. Doe, paid session 2026-08")
        #expect(restored.selectedPersonaID == settings.selectedPersonaID)
    }

    @Test func renderSizeStaysEvenAndCapped() {
        let big = TalkingClipRenderer.renderSize(
            for: TestImages.solid(width: 3001, height: 1999)
        )
        #expect(max(big.width, big.height) <= 1080)
        #expect(Int(big.width) % 2 == 0 && Int(big.height) % 2 == 0)

        let small = TalkingClipRenderer.renderSize(
            for: TestImages.solid(width: 101, height: 51)
        )
        // Small portraits are not upscaled, only evened.
        #expect(small.width <= 102 && small.height <= 52)
        #expect(Int(small.width) % 2 == 0 && Int(small.height) % 2 == 0)
    }
}

/// The whole performance path, end to end, with nothing external: a synthesized
/// portrait and a synthesized voice go in, a real playable MP4 comes out.
@Suite("Talking clip rendering")
struct TalkingClipTests {

    @Test @MainActor func rendersAPlayableClipWithBothTracks() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("persona-clip-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        // A portrait, and two seconds of "speech": a tone that stops halfway, so the
        // jaw has something to follow and something to rest through.
        let portrait = scratch.appendingPathComponent("portrait.png")
        let image = TestImages.solid(width: 512, height: 512)
        let representation = NSBitmapImageRep(cgImage: image)
        try #require(representation.representation(using: .png, properties: [:]))
            .write(to: portrait)

        let sampleRate = 24_000
        var samples = [Float](repeating: 0, count: sampleRate * 2)
        for index in 0..<sampleRate {
            samples[index] = sin(Float(index) * 0.08) * 0.6
        }
        let audio = scratch.appendingPathComponent("line.wav")
        try MicRecorder.wavData(samples: samples, sampleRate: sampleRate).write(to: audio)

        let destination = scratch.appendingPathComponent("clip.mp4")
        let clip = try await TalkingClipRenderer.render(
            portrait: portrait, audio: audio, destination: destination, caption: "Hello."
        )

        #expect(FileManager.default.fileExists(atPath: clip.path))
        let size = try #require(
            FileManager.default.attributesOfItem(atPath: clip.path)[.size] as? Int
        )
        #expect(size > 10_000)

        // It must be a real movie: picture and sound, roughly as long as the line.
        let asset = AVURLAsset(url: clip)
        let video = try await asset.loadTracks(withMediaType: .video)
        let sound = try await asset.loadTracks(withMediaType: .audio)
        #expect(video.count == 1)
        #expect(sound.count == 1)
        let duration = try await asset.load(.duration).seconds
        #expect(duration > 1.7 && duration < 2.4)
    }

    /// The regression that shipped: the animator hinged the *forehead* because the
    /// slices were inverted, and every test passed because none looked at the picture.
    /// This one does — everything above the mouth must be pixel-identical between a
    /// silent frame and a loud one, and something below it must have moved.
    @Test func onlyTheFaceBelowTheMouthMoves() throws {
        let portrait = TestImages.stripes(width: 256, height: 256)
        let geometry = FaceGeometry(mouthTop: 0.66, chin: 0.85, detected: true)

        let quiet = try #require(TalkingClipRenderer.frame(
            portrait: portrait, geometry: geometry, level: 0, size: CGSize(width: 256, height: 256)
        ))
        let loud = try #require(TalkingClipRenderer.frame(
            portrait: portrait, geometry: geometry, level: 1, size: CGSize(width: 256, height: 256)
        ))

        // Rows are counted from the top, like the geometry.
        let mouthRow = Int(0.66 * 256)
        var movedBelow = false
        for row in 0..<256 {
            let same = TestImages.row(row, of: quiet) == TestImages.row(row, of: loud)
            if row < mouthRow - 4 {
                #expect(same, "row \(row) is above the mouth and must not move")
            } else if !same {
                movedBelow = true
            }
        }
        #expect(movedBelow, "nothing below the mouth moved")
    }

    @Test func aSecondDrawingIsWhatTalksWhenItExists() throws {
        let closed = TestImages.solid(width: 128, height: 128)
        let open = TestImages.stripes(width: 128, height: 128)
        let geometry = FaceGeometry(mouthTop: 0.66, chin: 0.85, detected: true)
        let size = CGSize(width: 128, height: 128)

        let quiet = try #require(TalkingClipRenderer.frame(
            portrait: closed, openMouth: open, geometry: geometry, level: 0, size: size
        ))
        let loud = try #require(TalkingClipRenderer.frame(
            portrait: closed, openMouth: open, geometry: geometry, level: 1, size: size
        ))
        // Silent shows the closed drawing; loud shows the open one, all the way up.
        #expect(TestImages.row(20, of: quiet) != TestImages.row(20, of: loud))
    }

    @Test @MainActor func namesTheProblemWhenThePortraitIsNotAnImage() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("persona-bad-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let notAnImage = scratch.appendingPathComponent("portrait.png")
        try Data("this is not a picture".utf8).write(to: notAnImage)
        let audio = scratch.appendingPathComponent("line.wav")
        try MicRecorder.wavData(samples: [0.1, 0.2], sampleRate: 24_000).write(to: audio)

        await #expect(throws: TalkingClipRenderer.RenderError.self) {
            try await TalkingClipRenderer.render(
                portrait: notAnImage, audio: audio,
                destination: scratch.appendingPathComponent("clip.mp4")
            )
        }
    }
}

enum TestImages {
    /// Horizontal bands, so a moved row is obvious in the pixels.
    static func stripes(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        )!
        for band in 0..<16 {
            context.setFillColor(CGColor(
                red: Double(band) / 16, green: 1 - Double(band) / 16, blue: 0.5, alpha: 1
            ))
            let bandHeight = Double(height) / 16
            context.fill(CGRect(
                x: 0, y: Double(band) * bandHeight,
                width: Double(width), height: bandHeight
            ))
        }
        return context.makeImage()!
    }

    /// One row of pixels, counted from the top.
    static func row(_ index: Int, of image: CGImage) -> [UInt8] {
        guard let data = image.dataProvider?.data as Data? else { return [] }
        let bytesPerRow = image.bytesPerRow
        let start = index * bytesPerRow
        guard start + bytesPerRow <= data.count else { return [] }
        return Array(data[start..<(start + bytesPerRow)])
    }

    static func solid(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        )!
        context.setFillColor(CGColor(red: 0.4, green: 0.5, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }
}
