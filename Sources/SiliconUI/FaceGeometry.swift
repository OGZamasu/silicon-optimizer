import CoreGraphics
import Foundation
import Vision

/// Where the mouth actually is in a portrait.
///
/// The first version of the animator guessed a fixed line and hinged whatever happened
/// to be there — on a portrait framed differently from the assumption, that was the
/// forehead. Vision knows where the lips are, so it is asked; the guess survives only
/// as the fallback for artwork it cannot read.
public struct FaceGeometry: Sendable, Equatable {
    /// Top of the upper lip, as a fraction of image height from the top. Everything
    /// above this stays still; everything below stretches when the mouth opens.
    public var mouthTop: Double
    /// Bottom of the chin, same units — how far the jaw has to travel before it runs
    /// out of face.
    public var chin: Double
    /// Whether Vision actually found a face, or this is the fallback guess.
    public var detected: Bool

    /// The fallback: a head-and-shoulders portrait puts the mouth around here. Stated
    /// as a guess in the UI rather than presented as fact.
    public static let fallback = FaceGeometry(mouthTop: 0.66, chin: 0.82, detected: false)

    public init(mouthTop: Double, chin: Double, detected: Bool) {
        self.mouthTop = mouthTop
        self.chin = chin
        self.detected = detected
    }

    /// How much the jaw can travel without tearing the face apart: a fraction of the
    /// distance from lip to chin, not of the whole image, so a small face in a big
    /// frame moves a small amount.
    public var travel: Double {
        max(0.01, min(0.09, (chin - mouthTop) * 0.55))
    }

    /// A line the user set by eye. Chin is assumed a little below it, which is all
    /// the warp needs to know.
    public static func manual(mouthTop: Double) -> FaceGeometry {
        let clamped = max(0.2, min(0.92, mouthTop))
        return FaceGeometry(
            mouthTop: clamped, chin: min(0.98, clamped + 0.16), detected: true
        )
    }

    public static func detect(in image: CGImage) -> FaceGeometry {
        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([request])

        guard let face = (request.results)?.first,
              let landmarks = face.landmarks,
              let lips = landmarks.outerLips?.normalizedPoints, !lips.isEmpty
        else { return .fallback }

        // Landmark points are normalized inside the face's bounding box, which is
        // itself normalized bottom-up in the image.
        let box = face.boundingBox
        func imageY(_ pointY: CGFloat) -> Double {
            Double(box.minY + pointY * box.height)
        }
        // Vision counts from the bottom; the renderer counts from the top.
        let lipTop = 1 - (lips.map { imageY($0.y) }.max() ?? 0.34)

        var chin = 1 - Double(box.minY)
        if let contour = landmarks.faceContour?.normalizedPoints, !contour.isEmpty {
            chin = 1 - (contour.map { imageY($0.y) }.min() ?? Double(box.minY))
        }

        // Nonsense geometry is worse than the honest guess.
        guard lipTop > 0.05, lipTop < 0.95, chin > lipTop else { return .fallback }
        return FaceGeometry(mouthTop: lipTop, chin: min(1, chin), detected: true)
    }
}
