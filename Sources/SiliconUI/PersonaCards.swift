import AppKit
import SiliconCatalog
import SwiftUI
import UniformTypeIdentifiers

/// The character workshop, the live stage, and the clip exporter — the three things
/// the Video tab does with a persona.
struct PersonaCards: View {
    @Environment(AppModel.self) private var model
    @State private var editing: Persona?
    @State private var recorder = TakeRecorder()

    var body: some View {
        VStack(spacing: 16) {
            castCard
            if model.selectedPersona != nil {
                performCard
                liveCard
                TrackerCard()
                FaceCamCard()
            }
        }
        .sheet(item: $editing) { persona in
            PersonaEditor(persona: persona) { edited in
                if model.personas.contains(where: { $0.id == edited.id }) {
                    model.updatePersona(edited)
                } else {
                    model.addPersona(edited)
                }
            }
        }
        .task {
            model.refreshOverlayURL()
            model.publishPersonaToOverlay()
        }
    }

    // MARK: - Cast

    private var castCard: some View {
        CollapsibleCard(
            title: "Characters", systemImage: "theatermasks",
            badge: model.selectedPersona?.name,
            isExpanded: model.videoPanel(.cast)
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if model.personas.isEmpty {
                    EmptyStateView(
                        systemImage: "theatermasks",
                        title: "No characters yet",
                        message: "A character is a portrait plus a voice. Make one and "
                            + "this tab can speak as them, live on stream or as a clip."
                    )
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(model.personas) { persona in
                                personaChip(persona)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                HStack(spacing: 8) {
                    Button {
                        editing = Persona()
                    } label: {
                        Label("New character", systemImage: "plus")
                    }
                    if let persona = model.selectedPersona {
                        Button {
                            editing = persona
                        } label: {
                            Label("Edit", systemImage: "slider.horizontal.3")
                        }
                        Button(role: .destructive) {
                            model.deletePersona(persona)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private func personaChip(_ persona: Persona) -> some View {
        let isSelected = model.selectedPersona?.id == persona.id
        return Button {
            model.selectPersona(persona)
        } label: {
            VStack(spacing: 5) {
                ZStack {
                    if let url = persona.portraitURL,
                       let image = NSImage(contentsOf: url) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "person.crop.square")
                            .font(.title)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(width: 74, height: 74)
                .background(.background.secondary)
                .clipShape(.rect(cornerRadius: 9))
                .overlay {
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(
                            isSelected ? Color.accentColor : .clear, lineWidth: 2
                        )
                }
                Text(persona.name.isEmpty ? "Unnamed" : persona.name)
                    .font(.caption2)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
                    .frame(width: 74)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Perform

    private var performCard: some View {
        @Bindable var model = model
        let persona = model.selectedPersona
        return CollapsibleCard(
            title: "Perform", systemImage: "waveform.circle",
            isExpanded: model.videoPanel(.perform)
        ) {
            VStack(alignment: .leading, spacing: 12) {
                TextEditor(text: $model.personaLine)
                    .font(.body)
                    .frame(minHeight: 70)
                    .padding(6)
                    .background(.background.secondary, in: .rect(cornerRadius: 7))
                    .overlay(alignment: .topLeading) {
                        if model.personaLine.isEmpty {
                            Text("What should \(persona?.name ?? "they") say?")
                                .foregroundStyle(.tertiary)
                                .padding(.top, 12)
                                .padding(.leading, 11)
                                .allowsHitTesting(false)
                        }
                    }

                if let error = model.personaError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let note = animationNote {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(note)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let persona = model.selectedPersona,
                           persona.openMouthPortraitPath.isEmpty,
                           !persona.portraitPath.isEmpty {
                            Button("Draw them talking") {
                                model.generateOpenMouthDrawing(for: persona)
                            }
                            .buttonStyle(.borderless)
                            .font(.caption2)
                            .disabled(model.isGenerating
                                || model.routeNextImageToPersonaMouth != nil)
                            .help("Reworks the portrait through the image model into a "
                                + "matching mouth-open drawing")
                        }
                    }
                    photorealRow
                    if model.routeNextImageToPersonaMouth != nil {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Drawing the talking version…")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        model.performLine(model.personaLine)
                    } label: {
                        Label("Say it live", systemImage: "dot.radiowaves.left.and.right")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isPerforming || model.personaLine.isEmpty)
                    .help("Speaks through your speakers and moves the face on the overlay")

                    Button {
                        model.performLine(model.personaLine, alsoRenderClip: true)
                    } label: {
                        Label("Make a clip", systemImage: "film")
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isPerforming || model.personaLine.isEmpty)
                    .help("Renders an MP4 of the character saying the line")

                    Toggle("Captions", isOn: $model.includeCaptions)
                        .toggleStyle(.checkbox)
                        .font(.caption)

                    if model.isPerforming {
                        ProgressView().controlSize(.small)
                        Text(model.performanceStage ?? "Working")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Button("Stop") { model.stopPerforming() }
                            .buttonStyle(.borderless)
                            .font(.caption)
                    }
                }
            }
        }
    }

    /// The high-fidelity path: LivePortrait moving the portrait's real features
    /// from a recorded performance, rather than the puppet's warp.
    @ViewBuilder
    private var photorealRow: some View {
        if let job = model.repairs["portrait-animator-install"] {
            HStack(spacing: 8) {
                if job.error == nil { ProgressView().controlSize(.small) }
                Text(job.error ?? job.stage)
                    .font(.caption2)
                    .foregroundStyle(job.error == nil ? .secondary : Color.orange)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        } else if model.portraitAnimatorInstallation.isInstalled
                    || model.portraitAnimationNode != nil {
            VStack(alignment: .leading, spacing: 8) {
                if let session = recorder.session {
                    CameraPreview(session: session)
                        .frame(height: 150)
                        .clipShape(.rect(cornerRadius: 8))
                        .overlay(alignment: .topLeading) {
                            if recorder.isRecording {
                                HStack(spacing: 5) {
                                    Circle().fill(.red).frame(width: 7, height: 7)
                                    Text(recorder.elapsedLabel)
                                        .font(.caption2.monospacedDigit())
                                }
                                .padding(6)
                                .background(.black.opacity(0.55), in: Capsule())
                                .padding(8)
                            }
                        }
                }

                HStack(spacing: 8) {
                    Button(recorder.isRecording ? "Stop and animate" : "Record a take…") {
                        if recorder.isRecording {
                            recorder.stop()
                        } else {
                            Task { await recordTake() }
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(recorder.isRecording ? .red : nil)
                    .disabled(model.isAnimatingPortrait)

                    Button("Use a video…") {
                        if let driving = model.pickDrivingVideo() {
                            model.animatePortrait(with: driving)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.isAnimatingPortrait || recorder.isRecording)

                    if model.isAnimatingPortrait {
                        if let fraction = model.portraitAnimationProgress {
                            ProgressView(value: fraction)
                                .progressViewStyle(.linear)
                                .frame(width: 70)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                        Text(model.portraitAnimationStage)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Button("Stop") { model.cancelPortraitAnimation() }
                            .buttonStyle(.borderless)
                            .font(.caption2)
                    }
                }

                if case .failed(let message) = recorder.state {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(photorealNote)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            HStack(spacing: 8) {
                Button("Set up photoreal animation") {
                    model.installPortraitAnimator()
                }
                .buttonStyle(.borderless)
                .font(.caption2)
                Text(model.portraitAnimatorInstallation.detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Records a performance, then animates the character with it as soon as the
    /// file lands — the two halves of one intention, not two chores.
    private func recordTake() async {
        await recorder.prepare(cameraIndex: model.selectedCameraIndex)
        guard recorder.session != nil else { return }
        let directory = model.settings.resolvedVideoOutputDirectory
            .appendingPathComponent("Takes", isDirectory: true)
        recorder.start(into: directory) { url in
            recorder.close()
            model.animatePortrait(with: url)
        }
    }

    private var photorealNote: String {
        if let node = model.portraitAnimationNode {
            return "Photoreal — copies a real performance onto the portrait. Renders "
                + "on \(node.name), which is far faster than this Mac."
        }
        return "Photoreal — copies a real performance onto the portrait. About a "
            + "minute of rendering per second of video on this Mac."
    }

    /// What the animator is actually working with — said out loud, because guessing
    /// wrong is what made a character talk out of its forehead.
    private var animationNote: String? {
        guard let persona = model.selectedPersona else { return nil }
        if !persona.openMouthPortraitPath.isEmpty {
            return "Talking crosses between your two drawings."
        }
        guard let geometry = model.personaGeometry else { return nil }
        return geometry.detected
            ? "Found their mouth — the jaw moves from there."
            : "No face detected in this portrait, so the mouth is a guess. A "
                + "mouth-open drawing would be exact."
    }

    // MARK: - Live

    private var liveCard: some View {
        CollapsibleCard(
            title: "Live on stream", systemImage: "dot.radiowaves.left.and.right",
            isExpanded: model.videoPanel(.live)
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Add a Browser Source in OBS pointed at this address. The "
                    + "character appears on a transparent background and their mouth "
                    + "moves whenever they speak.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let url = model.overlayURL {
                    HStack(spacing: 8) {
                        Text(url.absoluteString)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .padding(7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.background.secondary, in: .rect(cornerRadius: 7))

                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(
                                url.absoluteString, forType: .string
                            )
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            Label("Preview", systemImage: "safari")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Text("The address includes this session's key, so it changes each "
                        + "time the app restarts — recopy it if OBS shows nothing.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for the local server…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Check again") { model.refreshOverlayURL() }
                            .buttonStyle(.borderless)
                            .font(.caption)
                    }
                }
            }
        }
    }
}

// MARK: - Editor

/// Making a character: a portrait, a voice, and who that voice belongs to.
struct PersonaEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var persona: Persona
    var onSave: (Persona) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(persona.name.isEmpty ? "New character" : persona.name)
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 12)

            Form {
                Section("Who they are") {
                    TextField("Name", text: $persona.name, prompt: Text("Character name"))
                    portraitRow
                    if !persona.portraitPath.isEmpty && persona.openMouthPortraitPath.isEmpty {
                        mouthLineRow
                    }
                    TextField(
                        "Brief", text: $persona.brief,
                        prompt: Text("How they talk and behave — used when an agent speaks as them"),
                        axis: .vertical
                    )
                    .lineLimit(2...4)
                }

                Section("Their voice") {
                    Picker("Model", selection: $persona.voiceModelID) {
                        ForEach(VoiceCatalog.speakers) { entry in
                            Text(entry.name).tag(entry.id)
                        }
                    }
                    if let entry = VoiceCatalog.entry(id: persona.voiceModelID) {
                        if !entry.voices.isEmpty {
                            Picker("Voice", selection: $persona.presetVoice) {
                                ForEach(entry.voices, id: \.self) { voice in
                                    Text(VoiceView.voiceLabel(voice)).tag(voice)
                                }
                            }
                        }
                        if entry.supportsCloning {
                            referenceRow(required: entry.requiresReference)
                        }
                    }
                    TextField(
                        "Voice credit", text: $persona.voiceCredit,
                        prompt: Text("Whose voice this is, and your permission to use it")
                    )
                    Text("Kept with the character so the performer stays credited "
                        + "wherever the clips end up.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    onSave(persona)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(persona.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 540, height: 560)
    }

    private var portraitRow: some View {
        HStack(spacing: 10) {
            ZStack {
                if let url = persona.portraitURL, let image = NSImage(contentsOf: url) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "person.crop.square")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 56, height: 56)
            .background(.background.secondary)
            .clipShape(.rect(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Button("Choose portrait…") {
                        if let url = pickImage() { persona.portraitPath = url.path }
                    }
                    Button(persona.openMouthPortraitPath.isEmpty
                        ? "Add mouth-open drawing…" : "Replace mouth-open…") {
                        if let url = pickImage() { persona.openMouthPortraitPath = url.path }
                    }
                    Button(persona.closedEyesPortraitPath.isEmpty
                        ? "Add eyes-closed…" : "Replace eyes-closed…") {
                        if let url = pickImage() { persona.closedEyesPortraitPath = url.path }
                    }
                    .help("Used for blinks when motion tracking is running")
                    if !persona.openMouthPortraitPath.isEmpty {
                        Button {
                            persona.openMouthPortraitPath = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Text(persona.openMouthPortraitPath.isEmpty
                    ? "A second drawing with the mouth open gives the best result — it "
                        + "is how PNGTuber avatars work. Without one the jaw is warped "
                        + "at the mouth line below, which stretches a closed mouth "
                        + "rather than opening it."
                    : "Talking crosses between the two drawings.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    /// Setting the mouth by eye. Vision reads photographic faces well and drawn ones
    /// badly, so anything stylized needs the line placed by the person who can see it.
    private var mouthLineRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let url = persona.portraitURL, let image = NSImage(contentsOf: url) {
                GeometryReader { proxy in
                    ZStack(alignment: .topLeading) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(height: 2)
                            .offset(y: proxy.size.height * effectiveMouthLine)
                            .shadow(color: .black.opacity(0.6), radius: 2)
                    }
                    .contentShape(.rect)
                    .gesture(
                        DragGesture(minimumDistance: 0).onChanged { value in
                            persona.mouthLineOverride = max(
                                0.2, min(0.92, value.location.y / proxy.size.height)
                            )
                        }
                    )
                }
                .frame(height: 170)
                .clipShape(.rect(cornerRadius: 8))
            }
            HStack {
                Text("Mouth line")
                Slider(
                    value: Binding(
                        get: { effectiveMouthLine },
                        set: { persona.mouthLineOverride = $0 }
                    ),
                    in: 0.2...0.92
                )
                Text(String(format: "%.0f%%", effectiveMouthLine * 100))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if persona.mouthLineOverride > 0 {
                    Button("Auto") { persona.mouthLineOverride = 0 }
                        .buttonStyle(.borderless)
                }
            }
            .font(.caption)
            Text(detectionNote)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The line in use: the one set by hand, else whatever Vision found, else the guess.
    private var effectiveMouthLine: Double {
        if persona.mouthLineOverride > 0 { return persona.mouthLineOverride }
        return detectedGeometry.mouthTop
    }

    private var detectedGeometry: FaceGeometry {
        guard let url = persona.portraitURL, let image = NSImage(contentsOf: url),
              let frame = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return .fallback }
        return FaceGeometry.detect(in: frame)
    }

    private var detectionNote: String {
        if persona.mouthLineOverride > 0 {
            return "Drag the line onto their mouth. Everything below it moves when they talk."
        }
        return detectedGeometry.detected
            ? "Found the mouth automatically. Drag the line if it looks off."
            : "No face found automatically — drawn characters usually need the line "
                + "placed by hand. Drag it onto their mouth."
    }

    private func pickImage() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func referenceRow(required: Bool) -> some View {
        HStack(spacing: 8) {
            if persona.referenceAudioPath.isEmpty {
                Text(required ? "Reference recording required" : "Reference recording")
                    .font(.caption)
                    .foregroundStyle(required ? .primary : .secondary)
            } else {
                Text(URL(fileURLWithPath: persona.referenceAudioPath).lastPathComponent)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button(persona.referenceAudioPath.isEmpty ? "Choose…" : "Replace…") {
                if let url = VoiceView.pickAudio() {
                    persona.referenceAudioPath = url.path
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}
