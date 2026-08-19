import AVFoundation
import AppKit
import Foundation
import SiliconCatalog
import SiliconControl
import SiliconRuntime

/// Performing as a character: speaking in their voice, moving their face on an OBS
/// overlay while they speak, and exporting the same performance as a video clip.
extension AppModel {

    // MARK: - The cast

    public var personas: [Persona] { settings.personas }

    public var selectedPersona: Persona? {
        settings.personas.first { $0.id == settings.selectedPersonaID }
            ?? settings.personas.first
    }

    public func selectPersona(_ persona: Persona) {
        settings.selectedPersonaID = persona.id
        settings.save()
        publishPersonaToOverlay()
    }

    public func addPersona(_ persona: Persona) {
        settings.personas.append(persona)
        settings.selectedPersonaID = persona.id
        settings.save()
        publishPersonaToOverlay()
    }

    public func updatePersona(_ persona: Persona) {
        guard let index = settings.personas.firstIndex(where: { $0.id == persona.id })
        else { return }
        settings.personas[index] = persona
        settings.save()
        if persona.id == selectedPersona?.id { publishPersonaToOverlay() }
    }

    public func deletePersona(_ persona: Persona) {
        settings.personas.removeAll { $0.id == persona.id }
        if settings.selectedPersonaID == persona.id {
            settings.selectedPersonaID = settings.personas.first?.id ?? ""
        }
        settings.save()
        publishPersonaToOverlay()
    }

    /// Pushes the current character's face to any overlay OBS has open. PNG because a
    /// browser source composites its alpha, and cutout portraits are the point.
    public func publishPersonaToOverlay() {
        guard let persona = selectedPersona, let url = persona.portraitURL,
              let image = NSImage(contentsOf: url),
              let frame = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            OverlayBroadcast.shared.setPortrait(nil, name: selectedPersona?.name ?? "")
            return
        }
        let representation = NSBitmapImageRep(cgImage: frame)
        let data = representation.representation(using: .png, properties: [:])
        OverlayBroadcast.shared.setPortrait(data, name: persona.name)
    }

    /// The address to paste into OBS as a Browser Source.
    public func refreshOverlayURL() {
        Task {
            let url = await controlServer?.overlayURL
            await MainActor.run { self.overlayURL = url }
        }
    }

    // MARK: - Performing

    /// Speaks a line as the selected character: their voice, their face moving on the
    /// overlay in time with it, and the audio saved like any other generated take.
    public func performLine(_ text: String, alsoRenderClip: Bool = false) {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, !isPerforming, let persona = selectedPersona else { return }
        guard let entry = VoiceCatalog.entry(id: persona.voiceModelID) else { return }
        if entry.requiresReference && persona.referenceAudioURL == nil {
            personaError = "\(persona.name) speaks with a cloned voice — add their "
                + "reference recording in the persona editor first."
            return
        }

        isPerforming = true
        personaError = nil
        performanceStage = "Finding their voice…"
        noteActivity()

        let request = SpeechRequest(
            entryID: entry.id,
            text: line,
            voice: entry.voices.isEmpty ? nil : persona.presetVoice,
            referenceAudio: entry.supportsCloning ? persona.referenceAudioURL : nil,
            hubCache: settings.resolvedEngineCacheDirectory,
            outputDirectory: settings.resolvedVoiceOutputDirectory
        )

        Task {
            defer {
                isPerforming = false
                performanceStage = nil
            }
            do {
                let spoken = try await voiceRuntime.speak(request) { stage in
                    Task { @MainActor in self.performanceStage = stage }
                }
                speechResults.insert(spoken, at: 0)

                if alsoRenderClip {
                    try await renderClip(for: persona, audio: spoken.audio, line: line)
                } else {
                    await performLive(audio: spoken.audio, caption: line)
                }
            } catch {
                personaError = error.localizedDescription
                OverlayBroadcast.shared.setSpeaking(false, level: 0, caption: "")
            }
        }
    }

    /// Plays the take while publishing its live loudness to the overlay, so the mouth
    /// on stream moves with the voice the audience hears.
    private func performLive(audio: URL, caption: String) async {
        guard let player = try? AVAudioPlayer(contentsOf: audio) else { return }
        player.isMeteringEnabled = true
        livePlayer = player
        performanceStage = "On air"
        OverlayBroadcast.shared.setSpeaking(true, level: 0, caption: caption)
        player.play()

        while player.isPlaying {
            player.updateMeters()
            // Decibels are logarithmic and mostly negative; -45 dB is a practical floor
            // for speech, and mapping from there fills the mouth's range.
            let decibels = Double(player.averagePower(forChannel: 0))
            let level = max(0, min(1, (decibels + 45) / 45))
            OverlayBroadcast.shared.setSpeaking(true, level: level, caption: caption)
            try? await Task.sleep(for: .milliseconds(40))
        }

        OverlayBroadcast.shared.setSpeaking(false, level: 0, caption: "")
        livePlayer = nil
    }

    private func renderClip(for persona: Persona, audio: URL, line: String) async throws {
        guard let portrait = persona.portraitURL else {
            personaError = "\(persona.name) has no portrait yet — add one to make clips."
            return
        }
        performanceStage = "Animating…"
        let destination = settings.resolvedVideoOutputDirectory
            .appendingPathComponent(
                NodeVideoRuntime.outputName(extension: "mp4")
                    .replacingOccurrences(of: "silicon-video", with: "silicon-persona")
            )
        let caption = includeCaptions ? line : nil
        let file = try await TalkingClipRenderer.render(
            portrait: portrait, audio: audio, destination: destination, caption: caption
        ) { fraction in
            Task { @MainActor in
                self.performanceStage = "Animating — \(Int(fraction * 100))%"
            }
        }
        videoResults.insert(
            VideoResult(
                file: file, modelName: "\(persona.name) (persona)",
                prompt: line, elapsed: 0
            ),
            at: 0
        )
    }

    public func stopPerforming() {
        livePlayer?.stop()
        livePlayer = nil
        OverlayBroadcast.shared.setSpeaking(false, level: 0, caption: "")
        isPerforming = false
        performanceStage = nil
    }
}
