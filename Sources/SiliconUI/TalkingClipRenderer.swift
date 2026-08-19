import AVFoundation
import AppKit
import CoreGraphics

/// Turns a portrait and a spoken line into a video of the character saying it.
///
/// Two ways to talk, both puppetry rather than a face model. With a second drawing of
/// the character mouth-open, the two cross — the PNGTuber technique, and the one that
/// looks right on stylized art because an artist drew both states. Without one, the
/// face below the lips stretches about the line Vision found, so the jaw travels and
/// the mouth opens without any seam.
///
/// Both run in seconds on any Mac and never invent an expression the performer did not
/// give. The high-fidelity path — a real lip-sync or face-swap model — slots in beside
/// this without changing anything the user does.
enum TalkingClipRenderer {

    enum RenderError: LocalizedError {
        case unreadablePortrait
        case unreadableAudio
        case writerFailed(String)

        var errorDescription: String? {
            switch self {
            case .unreadablePortrait: "That portrait could not be read as an image."
            case .unreadableAudio: "The spoken audio could not be read back."
            case .writerFailed(let detail): detail
            }
        }
    }

    /// Renders `audio` over `portrait` and writes an MP4 to `destination`.
    ///
    /// - Parameter openMouth: a second drawing of the same character with their mouth
    ///   open. When supplied it drives the talking directly — the PNGTuber technique,
    ///   and the only one that looks truly right on stylized art. Without it the jaw
    ///   is warped, anchored at the mouth Vision found.
    static func render(
        portrait: URL,
        audio: URL,
        destination: URL,
        openMouth: URL? = nil,
        mouthLine: Double = 0,
        caption: String? = nil,
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        guard let image = NSImage(contentsOf: portrait),
              let portraitFrame = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { throw RenderError.unreadablePortrait }
        let openFrame = openMouth
            .flatMap { NSImage(contentsOf: $0) }
            .flatMap { $0.cgImage(forProposedRect: nil, context: nil, hints: nil) }
        let geometry = mouthLine > 0
            ? FaceGeometry.manual(mouthTop: mouthLine)
            : FaceGeometry.detect(in: portraitFrame)

        let (samples, sampleRate) = try readSamples(audio)
        let levels = PersonaAnimator.smoothed(
            PersonaAnimator.envelope(samples: samples, sampleRate: sampleRate)
        )
        guard !levels.isEmpty else { throw RenderError.unreadableAudio }

        let size = renderSize(for: portraitFrame)
        let silent = FileManager.default.temporaryDirectory
            .appendingPathComponent("talking-\(UUID().uuidString.prefix(8)).mp4")
        defer { try? FileManager.default.removeItem(at: silent) }

        try await writeVideo(
            frame: portraitFrame, openFrame: openFrame, geometry: geometry,
            levels: levels, size: size,
            caption: caption, to: silent, onProgress: onProgress
        )
        return try await mux(video: silent, audio: audio, to: destination)
    }

    // MARK: - Audio

    /// Mono float samples, whatever the file's own layout.
    static func readSamples(_ url: URL) throws -> ([Float], Double) {
        guard let file = try? AVAudioFile(forReading: url) else {
            throw RenderError.unreadableAudio
        }
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)
        ) else { throw RenderError.unreadableAudio }
        try file.read(into: buffer)

        guard let channels = buffer.floatChannelData else { throw RenderError.unreadableAudio }
        let count = Int(buffer.frameLength)
        let channelCount = Int(format.channelCount)
        var mono = [Float](repeating: 0, count: count)
        for frame in 0..<count {
            var sum: Float = 0
            for channel in 0..<channelCount { sum += channels[channel][frame] }
            mono[frame] = sum / Float(channelCount)
        }
        return (mono, format.sampleRate)
    }

    // MARK: - Video

    /// Portrait aspect preserved, long edge capped at 1080, both edges even because
    /// H.264 macroblocks require it.
    static func renderSize(for image: CGImage) -> CGSize {
        let width = Double(image.width)
        let height = Double(image.height)
        let scale = min(1, 1080 / max(width, height))
        func even(_ value: Double) -> Double { max(2, (value * scale / 2).rounded() * 2) }
        return CGSize(width: even(width), height: even(height))
    }

    private static func writeVideo(
        frame portrait: CGImage,
        openFrame: CGImage?,
        geometry: FaceGeometry,
        levels: [Double],
        size: CGSize,
        caption: String?,
        to destination: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
            ]
        )
        guard writer.canAdd(input) else {
            throw RenderError.writerFailed("The video writer refused its own input.")
        }
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let fps = PersonaAnimator.fps
        for (index, level) in levels.enumerated() {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            guard let pool = adaptor.pixelBufferPool else {
                throw RenderError.writerFailed("The video writer ran out of buffers.")
            }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else {
                throw RenderError.writerFailed("The video writer ran out of buffers.")
            }
            draw(
                portrait: portrait, openMouth: openFrame, geometry: geometry,
                level: level, frameIndex: index,
                caption: caption, size: size, into: buffer
            )
            adaptor.append(
                buffer,
                withPresentationTime: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps))
            )
            if index % 15 == 0 {
                onProgress(Double(index) / Double(levels.count))
            }
        }

        input.markAsFinished()
        await writer.finishWriting()
        if writer.status == .failed {
            throw RenderError.writerFailed(
                writer.error?.localizedDescription ?? "The video could not be written."
            )
        }
    }

    /// One frame as an image, for previewing and for the tests that check *which*
    /// part of the face moves — the first version animated the forehead, and nothing
    /// in the suite noticed.
    static func frame(
        portrait: CGImage, openMouth: CGImage? = nil,
        geometry: FaceGeometry, level: Double, frameIndex: Int = 0,
        size: CGSize? = nil
    ) -> CGImage? {
        let size = size ?? renderSize(for: portrait)
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(
            nil, Int(size.width), Int(size.height), kCVPixelFormatType_32ARGB,
            [kCVPixelBufferCGImageCompatibilityKey: true] as CFDictionary, &buffer
        )
        guard let buffer else { return nil }
        draw(
            portrait: portrait, openMouth: openMouth, geometry: geometry,
            level: level, frameIndex: frameIndex, caption: nil,
            size: size, into: buffer
        )
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }
        return context.makeImage()
    }

    /// One frame: the character at this loudness, plus idle sway and any caption.
    private static func draw(
        portrait: CGImage,
        openMouth: CGImage?,
        geometry: FaceGeometry,
        level: Double,
        frameIndex: Int,
        caption: String?,
        size: CGSize,
        into buffer: CVPixelBuffer
    ) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return }

        context.setFillColor(CGColor(gray: 0.06, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))

        // Idle breathing only. Tying the whole body to loudness made the character
        // lurch on every syllable — speech belongs in the mouth.
        let idle = PersonaAnimator.idleOffset(frame: frameIndex)
        let bob = idle.bob * size.height
        let full = CGRect(origin: CGPoint(x: 0, y: bob), size: size)

        if let openMouth {
            // The artist drew both states; just cross between them. This is what every
            // PNGTuber setup does, and nothing synthesized beats it on stylized art.
            context.draw(portrait, in: full)
            if level > 0.02 {
                context.saveGState()
                context.setAlpha(min(1, level * 1.4))
                context.draw(openMouth, in: full)
                context.restoreGState()
            }
        } else {
            // No second drawing: stretch the face below the lips instead of slicing it.
            // Core Graphics counts from the bottom, so the mouth line measured from the
            // top of the image sits this far up from the bottom.
            let mouthY = size.height * (1 - geometry.mouthTop)
            let drop = PersonaAnimator.jawDrop(level: level, geometry: geometry) * size.height

            // Everything below the lips, scaled vertically about the lip line so the
            // chin travels and the mouth opens. The anchor row is shared with the
            // still upper half exactly, so no seam can appear — the earlier version
            // cut the face into two slabs and the join showed on every frame.
            // The lower half is drawn a couple of pixels past the line and the upper
            // half painted over it. Two clips that merely abut leave both their
            // antialiased edges half-covered, which reads as a hairline across the
            // whole frame — visible even where the picture is plain background.
            context.saveGState()
            context.clip(to: CGRect(
                x: 0, y: bob - drop, width: size.width, height: mouthY + drop + 2
            ))
            context.translateBy(x: 0, y: bob + mouthY)
            context.scaleBy(x: 1, y: (mouthY + drop) / max(1, mouthY))
            context.translateBy(x: 0, y: -(bob + mouthY))
            context.draw(portrait, in: full)
            context.restoreGState()

            // Everything above the lips, untouched.
            context.saveGState()
            context.clip(to: CGRect(
                x: 0, y: bob + mouthY, width: size.width, height: size.height - mouthY
            ))
            context.draw(portrait, in: full)
            context.restoreGState()
        }

        if let caption, !caption.isEmpty {
            drawCaption(caption, in: context, size: size)
        }
    }

    private static func drawCaption(_ text: String, in context: CGContext, size: CGSize) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byWordWrapping
        let fontSize = max(14, size.height * 0.042)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: style,
            .strokeColor: NSColor.black.withAlphaComponent(0.9),
            .strokeWidth: -3.0,
        ]
        let inset = size.width * 0.06
        let box = CGRect(
            x: inset, y: size.height * 0.04,
            width: size.width - inset * 2, height: size.height * 0.22
        )
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        NSAttributedString(string: text, attributes: attributes).draw(in: box)
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: - Muxing

    /// Marries the silent render to the spoken audio and writes the final MP4.
    private static func mux(video: URL, audio: URL, to destination: URL) async throws -> URL {
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: video)
        let audioAsset = AVURLAsset(url: audio)

        guard let videoSource = try await videoAsset.loadTracks(withMediaType: .video).first,
              let videoTrack = composition.addMutableTrack(
                  withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
              )
        else { throw RenderError.writerFailed("The rendered frames could not be reopened.") }

        let duration = try await videoAsset.load(.duration)
        try videoTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: duration), of: videoSource, at: .zero
        )

        if let audioSource = try await audioAsset.loadTracks(withMediaType: .audio).first,
           let audioTrack = composition.addMutableTrack(
               withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            let audioDuration = try await audioAsset.load(.duration)
            try audioTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: min(audioDuration, duration)),
                of: audioSource, at: .zero
            )
        }

        try? FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: destination)

        guard let export = AVAssetExportSession(
            asset: composition, presetName: AVAssetExportPresetHighestQuality
        ) else { throw RenderError.writerFailed("The exporter could not be created.") }
        try await export.export(to: destination, as: .mp4)
        return destination
    }
}
