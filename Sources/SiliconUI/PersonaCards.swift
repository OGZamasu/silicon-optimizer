import AppKit
import SiliconCatalog
import SwiftUI
import UniformTypeIdentifiers

/// The character workshop, the live stage, and the clip exporter — the three things
/// the Video tab does with a persona.
struct PersonaCards: View {
    @Environment(AppModel.self) private var model
    @State private var editing: Persona?

    var body: some View {
        VStack(spacing: 16) {
            castCard
            if model.selectedPersona != nil {
                performCard
                liveCard
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
        Card(title: "Characters", systemImage: "theatermasks") {
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
        return Card(title: "Perform", systemImage: "waveform.circle") {
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

    // MARK: - Live

    private var liveCard: some View {
        Card(title: "Live on stream", systemImage: "dot.radiowaves.left.and.right") {
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
                Button("Choose portrait…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.image]
                    panel.allowsMultipleSelection = false
                    NSApp.activate(ignoringOtherApps: true)
                    if panel.runModal() == .OK, let url = panel.url {
                        persona.portraitPath = url.path
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Text("Facing forward works best — the jaw moves at a fixed line.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
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
