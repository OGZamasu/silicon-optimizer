import AVFoundation
import AppKit
import CoreGraphics

/// Turns a portrait and a spoken line into a video of the character saying it.
///
/// Two layers, like the live overlay: the head above the mouth line holds still while
/// the jaw below it drops with the voice. It is a puppet, not a face model — which is
/// the point. It runs in seconds on any Mac, it never invents a expression the
/// performer did not give, and the high-fidelity path (a real lip-sync model on the
/// CUDA node) can slot in beside it later without changing anything the user does.
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
    static func render(
        portrait: URL,
        audio: URL,
        destination: URL,
        caption: String? = nil,
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        guard let image = NSImage(contentsOf: portrait),
              let portraitFrame = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { throw RenderError.unreadablePortrait }

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
            frame: portraitFrame, levels: levels, size: size,
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
                portrait: portrait, level: level, frameIndex: index,
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

    /// One frame: still head, dropped jaw, idle sway, optional caption.
    private static func draw(
        portrait: CGImage,
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

        let idle = PersonaAnimator.idleOffset(frame: frameIndex)
        let bob = idle.bob * size.height - level * 0.008 * size.height
        let full = CGRect(origin: CGPoint(x: 0, y: bob), size: size)

        // Core Graphics counts from the bottom, so the head is the *upper* slice and
        // the jaw the lower one — the mouth line measured from the top.
        let headHeight = size.height * (1 - PersonaAnimator.mouthLine)
        let jawHeight = size.height - headHeight

        context.saveGState()
        context.clip(to: CGRect(
            x: 0, y: bob + jawHeight, width: size.width, height: headHeight
        ))
        context.draw(portrait, in: full)
        context.restoreGState()

        let drop = PersonaAnimator.jawDrop(level: level) * size.height
        context.saveGState()
        context.clip(to: CGRect(x: 0, y: bob - drop, width: size.width, height: jawHeight))
        context.draw(portrait, in: full.offsetBy(dx: 0, dy: -drop))
        context.restoreGState()

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
