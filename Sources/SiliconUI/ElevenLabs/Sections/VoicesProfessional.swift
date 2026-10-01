import SiliconElevenLabs
import SwiftUI

/// The professional-clone workflow, in the order ElevenLabs needs it: the voice's details,
/// its samples (trimmed, cleaned, one speaker picked), proof that the voice is the owner's,
/// then training.
struct VoicesProfessionalView: View {
    @Bindable var model: VoicesSectionModel

    var body: some View {
        Card(title: "Professional voice", systemImage: "person.badge.shield.checkmark") {
            Text("A professional clone is trained on long, clean recordings of one speaker, and needs "
                 + "proof that the voice is yours before training starts.")
                .font(.callout).foregroundStyle(.secondary)
            Picker("Voice", selection: Binding(
                get: { model.selected?.isProfessional == true ? model.selected?.id ?? "" : "" },
                set: { id in Task { await model.select(id.isEmpty ? nil : id) } }
            )) {
                Text("New professional voice").tag("")
                ForEach(model.professionalVoices) { Text($0.name).tag($0.id) }
            }
        }
        if let voice = model.selected, voice.isProfessional {
            VoicesProfessionalDetails(model: model, voice: voice)
            VoicesProfessionalSamples(model: model, voice: voice)
            VoicesProfessionalVerification(model: model, voice: voice)
            VoicesProfessionalTraining(model: model, voice: voice)
        } else {
            VoicesProfessionalCreate(model: model)
        }
    }
}

private struct VoicesProfessionalFields: View {
    @Binding var draft: VoicesProfessionalDraft

    var body: some View {
        LabeledContent("Name") {
            TextField("Name", text: $draft.name).textFieldStyle(.roundedBorder).labelsHidden()
        }
        LabeledContent("Language") {
            TextField("Language of the recordings (e.g. en)", text: $draft.language)
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .help(VoicesStudioSchema.description("create_pvc_voice", "language"))
        }
        LabeledContent("Description") {
            TextField("Optional", text: $draft.description, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .lineLimit(1...3)
        }
        VStack(alignment: .leading, spacing: 2) {
            Text("Labels, one “key: value” per line (language, accent, gender, age)")
                .font(.caption).foregroundStyle(.secondary)
            ElevenLabsTextArea(text: $draft.labels, prompt: "accent: Irish", minHeight: 44)
        }
    }
}

struct VoicesProfessionalCreate: View {
    @Bindable var model: VoicesSectionModel

    var body: some View {
        Card(title: "1 · Create the voice", systemImage: "plus.circle") {
            VoicesProfessionalFields(draft: $model.professional)
            HStack {
                Spacer()
                Button("Create professional voice") { Task { await model.createProfessional() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.professional.name.trimmingCharacters(in: .whitespaces).isEmpty
                              || model.professional.language.trimmingCharacters(in: .whitespaces).isEmpty
                              || model.actions.isRunning("create_pvc_voice"))
            }
        }
    }
}

struct VoicesProfessionalDetails: View {
    @Bindable var model: VoicesSectionModel
    let voice: VoicesVoice

    var body: some View {
        Card(title: "1 · Details", systemImage: "info.circle") {
            VoicesProfessionalFields(draft: $model.professional)
            HStack {
                if let waiting = model.waitingForDetails {
                    Text(waiting).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Save details") { Task { await model.editProfessional() } }
                    .disabled(model.actions.isRunning("edit_pvc_voice") || !model.detailsAreIn)
            }
        }
    }
}

struct VoicesProfessionalSamples: View {
    @Bindable var model: VoicesSectionModel
    let voice: VoicesVoice

    var body: some View {
        Card(title: "2 · Samples", systemImage: "waveform") {
            VoicesStudioFilePicker(title: "Add recordings", files: $model.professionalFiles, multiple: true,
                                   help: VoicesStudioSchema.description("add_pvc_voice_samples", "files"))
            HStack {
                Toggle("Remove background noise", isOn: $model.professionalRemoveNoise)
                    .help(VoicesStudioSchema.description("add_pvc_voice_samples", "remove_background_noise"))
                Spacer()
                Button("Upload") { Task { await model.addProfessionalSamples() } }
                    .disabled(model.professionalFiles.isEmpty || model.actions.isRunning("add_pvc_voice_samples"))
            }
            if let seconds = voice.fineTuning?.datasetDuration {
                VoicesStudioFact("Usable audio", VoicesStudioFormat.duration(seconds))
            }
            ForEach(voice.samples) { sample in
                Divider()
                VoicesProfessionalSampleRow(model: model, voice: voice, sample: sample)
            }
        }
    }
}

struct VoicesProfessionalSampleRow: View {
    @Bindable var model: VoicesSectionModel
    let voice: VoicesVoice
    let sample: VoicesSample

    private var draft: Binding<VoicesSampleDraft> {
        Binding(
            get: { model.sampleDrafts[sample.id] ?? VoicesSampleDraft(sample: sample) },
            set: { model.sampleDrafts[sample.id] = $0 }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(sample.fileName).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Text(VoicesStudioFormat.duration(sample.durationSecs) ?? "").font(.caption).foregroundStyle(.secondary)
                if let status = sample.separationStatus, status != "not_started" {
                    VoicesStudioStatusBadge(status: status)
                }
                Spacer(minLength: 4)
                Button("Play") { Task { await model.playSample(sample) } }.controlSize(.small)
                Button("Waveform") { Task { await model.loadWaveform(sample) } }.controlSize(.small)
                Button(role: .destructive) {
                    Task { await model.deleteSample(sample) }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Delete \(sample.fileName)")
            }
            if let url = model.sampleFiles[sample.id] {
                ElevenLabsAudioPlayerView(url: url).id(url)
            }
            if let waveform = model.waveforms[sample.id], !waveform.isEmpty {
                VoicesWaveform(values: waveform)
                    .frame(height: 36)
            }
            HStack(spacing: 8) {
                TextField("Name for training", text: draft.fileName).textFieldStyle(.roundedBorder)
                TextField("Trim start, ms", text: draft.trimStart).textFieldStyle(.roundedBorder).frame(width: 110)
                TextField("Trim end, ms", text: draft.trimEnd).textFieldStyle(.roundedBorder).frame(width: 110)
            }
            .help(VoicesStudioSchema.description("edit_pvc_voice_sample", "trim_start_time"))
            HStack(spacing: 8) {
                Toggle("Remove background noise", isOn: draft.removeBackgroundNoise)
                Spacer()
                Button("Find speakers") { Task { await model.separateSpeakers(sample) } }
                    .controlSize(.small)
                    .help("Separate the speakers in this recording, to train on one of them")
                Button("Check speakers") { Task { await model.loadSpeakers(sample) } }
                    .controlSize(.small)
                Button("Save sample") { Task { await model.saveSample(sample) } }
                    .controlSize(.small)
            }
            if let found = model.speakers[sample.id] {
                VoicesSpeakerPicker(model: model, sample: sample, speakers: found, selection: draft.selectedSpeakers)
            }
        }
    }
}

/// The speakers found in a sample; the checked ones are what training uses.
struct VoicesSpeakerPicker: View {
    let model: VoicesSectionModel
    let sample: VoicesSample
    let speakers: VoicesSpeakers
    @Binding var selection: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Speakers").font(.caption.weight(.medium))
                VoicesStudioStatusBadge(status: speakers.status)
            }
            if speakers.speakers.isEmpty {
                Text(speakers.status == "completed" ? "No speakers found." : "Not separated yet.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(speakers.speakers) { speaker in
                HStack(spacing: 8) {
                    Toggle(isOn: Binding(
                        get: { selection.contains(speaker.id) },
                        set: { on in
                            if on { selection.append(speaker.id) } else { selection.removeAll { $0 == speaker.id } }
                        }
                    )) {
                        Text("\(speaker.id) · \(VoicesStudioFormat.duration(speaker.duration) ?? "?") · \(speaker.utterances) parts")
                            .font(.caption.monospaced())
                    }
                    Spacer()
                    Button("Listen") { Task { await model.playSpeaker(speaker.id, in: sample) } }
                        .controlSize(.small)
                }
                if let url = model.speakerFile(speaker.id, in: sample) {
                    ElevenLabsAudioPlayerView(url: url).id(url)
                }
            }
        }
        .padding(8)
        .background(.background, in: .rect(cornerRadius: 8))
    }
}

/// A sample's visual waveform: one bar per value, scaled to the tallest.
struct VoicesWaveform: View {
    let values: [Double]

    var body: some View {
        Canvas { context, size in
            guard !values.isEmpty else { return }
            let peak = max(values.map(abs).max() ?? 1, 0.0001)
            let width = size.width / CGFloat(values.count)
            for (index, value) in values.enumerated() {
                let height = max(1, CGFloat(abs(value) / peak) * size.height)
                let rect = CGRect(x: CGFloat(index) * width, y: (size.height - height) / 2,
                                  width: max(0.5, width * 0.7), height: height)
                context.fill(Path(rect), with: .color(.accentColor.opacity(0.7)))
            }
        }
        .accessibilityLabel("Waveform")
    }
}

struct VoicesProfessionalVerification: View {
    @Bindable var model: VoicesSectionModel
    let voice: VoicesVoice

    var body: some View {
        Card(title: "3 · Verify it is your voice", systemImage: "checkmark.shield") {
            if let fineTuning = voice.fineTuning {
                VoicesStudioFact("Attempts", "\(fineTuning.verificationAttempts)")
                if !fineTuning.verificationFailures.isEmpty {
                    VoicesStudioFact("Failures", fineTuning.verificationFailures.joined(separator: "; "))
                }
                if fineTuning.manualVerificationRequested {
                    VoicesStudioFact("Manual review", "Requested")
                }
            }
            Text("Get the verification text, record yourself reading it aloud, and upload the recording.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Get verification text") { Task { await model.loadCaptcha() } }
                    .disabled(model.actions.isRunning("get_pvc_voice_captcha"))
                Spacer()
            }
            if let captcha = model.captcha {
                ElevenLabsResultView(result: captcha, showsMeta: false)
            }
            VoicesStudioFilePicker(title: "Your recording", files: $model.captchaRecording,
                                   help: VoicesStudioSchema.description("verify_pvc_voice_captcha", "recording"))
            HStack {
                Spacer()
                Button("Verify") { Task { await model.verifyCaptcha() } }
                    .disabled(model.captchaRecording.isEmpty || model.actions.isRunning("verify_pvc_voice_captcha"))
            }
            DisclosureGroup("Ask for a manual review instead") {
                VStack(alignment: .leading, spacing: 8) {
                    VoicesStudioFilePicker(title: "Documents", files: $model.verificationFiles, multiple: true,
                                           help: VoicesStudioSchema.description("request_pvc_manual_verification", "files"))
                    TextField("Anything the reviewer should know", text: $model.verificationNote, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                    HStack {
                        Spacer()
                        Button("Request review") { Task { await model.requestManualVerification() } }
                            .disabled(model.verificationFiles.isEmpty
                                      || model.actions.isRunning("request_pvc_manual_verification"))
                    }
                }
                .padding(.top, 6)
            }
            .font(.callout)
        }
    }
}

struct VoicesProfessionalTraining: View {
    @Bindable var model: VoicesSectionModel
    let voice: VoicesVoice

    var body: some View {
        Card(title: "4 · Train", systemImage: "cpu") {
            if let fineTuning = voice.fineTuning, !fineTuning.states.isEmpty {
                ForEach(fineTuning.states.keys.sorted(), id: \.self) { modelID in
                    HStack(spacing: 8) {
                        Text(modelID).font(.callout.monospaced())
                        VoicesStudioStatusBadge(status: fineTuning.states[modelID] ?? "")
                        if let progress = fineTuning.progress[modelID], progress > 0, progress < 1 {
                            ProgressView(value: progress).frame(width: 120)
                        }
                        if let message = fineTuning.messages[modelID], !message.isEmpty {
                            Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
            } else {
                Text("Not trained yet.").font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Picker("Model", selection: $model.trainingModel) {
                    Text("ElevenLabs' choice").tag("")
                    ForEach(model.trainingModels, id: \.self) { Text($0).tag($0) }
                }
                .help(VoicesStudioSchema.description("run_pvc_voice_training", "model_id"))
                Button("Start training") { Task { await model.train() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.actions.isRunning("run_pvc_voice_training") || model.isTraining)
                    .help(model.isTraining ? "Training is already under way" : "")
                Button("Check progress") { Task { await model.reloadSelected() } }
            }
        }
    }
}
