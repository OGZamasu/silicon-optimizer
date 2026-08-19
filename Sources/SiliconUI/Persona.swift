import Foundation

/// A character the app can speak and perform as: a portrait, a voice, and the notes
/// that keep both accountable.
///
/// `voiceCredit` is not decoration. A cloned voice belongs to whoever recorded it, and
/// a persona outlives the session that made it — so the licence or performer note
/// travels with the character rather than living in someone's memory. The same
/// discipline the asset library uses for generated meshes.
public struct Persona: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    /// Portrait file on disk. Front-facing artwork works best: the animator drops a jaw
    /// at a fixed line, the way a two-layer puppet does.
    public var portraitPath: String
    /// Which voice model speaks for this character.
    public var voiceModelID: String
    /// The preset voice, for models that ship a shelf of them.
    public var presetVoice: String
    /// The reference recording, for models that clone.
    public var referenceAudioPath: String
    /// Who the voice belongs to and under what permission — the performer's name, the
    /// licence, or "my own voice".
    public var voiceCredit: String
    /// What the character is like, for the agent that speaks as them.
    public var brief: String

    public init(
        id: String = UUID().uuidString,
        name: String = "",
        portraitPath: String = "",
        voiceModelID: String = "kokoro",
        presetVoice: String = "af_heart",
        referenceAudioPath: String = "",
        voiceCredit: String = "",
        brief: String = ""
    ) {
        self.id = id
        self.name = name
        self.portraitPath = portraitPath
        self.voiceModelID = voiceModelID
        self.presetVoice = presetVoice
        self.referenceAudioPath = referenceAudioPath
        self.voiceCredit = voiceCredit
        self.brief = brief
    }

    public var portraitURL: URL? {
        portraitPath.isEmpty ? nil : URL(fileURLWithPath: portraitPath)
    }

    public var referenceAudioURL: URL? {
        referenceAudioPath.isEmpty ? nil : URL(fileURLWithPath: referenceAudioPath)
    }
}

/// How a voice becomes a moving mouth.
///
/// Shared deliberately between the live overlay and the exported clip so a character
/// performs identically on stream and on film: the same envelope, the same attack and
/// release, the same jaw travel.
public enum PersonaAnimator {

    /// Frames per second the exported clip renders at.
    public static let fps = 30

    /// Loudness per frame, 0–1, normalized so the loudest moment of the line opens the
    /// mouth fully. Silence stays shut rather than being stretched into noise.
    public static func envelope(
        samples: [Float], sampleRate: Double, fps: Int = fps
    ) -> [Double] {
        guard !samples.isEmpty, sampleRate > 0, fps > 0 else { return [] }
        let windowSize = max(1, Int(sampleRate / Double(fps)))
        var levels: [Double] = []
        levels.reserveCapacity(samples.count / windowSize + 1)

        var index = 0
        while index < samples.count {
            let end = min(index + windowSize, samples.count)
            var sum = 0.0
            for position in index..<end {
                let value = Double(samples[position])
                sum += value * value
            }
            levels.append((sum / Double(end - index)).squareRoot())
            index = end
        }

        guard let peak = levels.max(), peak > 0.0001 else {
            return levels.map { _ in 0 }
        }
        // A little headroom under the peak keeps ordinary speech near the top of the
        // range instead of hugging the floor.
        return levels.map { min(1, ($0 / peak) * 1.15) }
    }

    /// The same asymmetric chase the browser overlay runs: mouths open fast and close
    /// slower, and anything else reads as a puppet snapping.
    public static func smoothed(_ envelope: [Double]) -> [Double] {
        var level = 0.0
        return envelope.map { target in
            let speed = target > level ? 0.45 : 0.2
            level += (target - level) * speed
            return level
        }
    }

    /// How far the jaw drops at this level, as a fraction of the portrait's height.
    public static func jawDrop(level: Double) -> Double {
        max(0, min(1, level)) * 0.055
    }

    /// Where the face is cut into a still head and a moving jaw.
    public static let mouthLine = 0.62

    /// Idle motion so a silent character still breathes, in fractions of the frame.
    public static func idleOffset(frame: Int, fps: Int = fps) -> (bob: Double, tilt: Double) {
        let seconds = Double(frame) / Double(fps)
        return (
            bob: sin(seconds * 2.4) * 0.005,
            tilt: sin(seconds * 4.5) * 0.25
        )
    }
}
