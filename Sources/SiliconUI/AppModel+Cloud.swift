import Foundation
import SiliconCatalog
import SiliconControl
import SiliconCore
import SiliconRuntime

/// Bring-your-own-key remote providers: asking each configured key what it can reach, and
/// keeping the answer where the gateway and the pickers can see it.
///
/// The list is discovered, never compiled in. GMI Cloud began serving MiniMax M3 before its
/// own catalogue page existed, so a hardcoded id would have shipped as a dead picker entry;
/// asking the provider costs one request, is right on the day a model lands, and is still
/// right on the day a promotional model goes away.
extension AppModel {

    // MARK: - Credentials

    /// Stores (or clears) a provider's key and refreshes what it can reach. Clearing the last
    /// key deletes the file and empties every cloud list, which is the point: opting out has
    /// to be as complete as never having opted in.
    public func setCloudKey(_ key: String?, for provider: CloudProvider) {
        var credentials = cloudCredentials
        credentials.set(key, for: provider)
        cloudCredentials = credentials
        do {
            try credentials.save()
            cloudRefreshError = nil
        } catch {
            cloudRefreshError = "Could not save the key: \(error.localizedDescription)"
        }
        // A provider that just lost its key should lose its models and its ticks with them,
        // or the gateway would keep advertising something nothing can answer.
        cloudModels.removeAll { $0.provider == provider && credentials.key(for: $0.provider) == nil }
        pruneEnabledCloudModels()
        Task { await refreshCloudModels() }
    }

    /// Drops enabled ids whose model is no longer reachable — a revoked key, a model the
    /// provider retired, a promotion that ended.
    func pruneEnabledCloudModels() {
        guard let enabled = settings.enabledCloudModels, !enabled.isEmpty else { return }
        let reachable = Set(cloudModels.map(\.gatewayID))
        let kept = enabled.filter { reachable.contains($0) }
        if kept.count != enabled.count {
            settings.enabledCloudModels = kept
            settings.save()
        }
    }

    // MARK: - Discovery

    /// Asks every configured provider for its model list. Failures are reported, not thrown:
    /// one provider being down must not take the other's models away.
    public func refreshCloudModels() async {
        let credentials = cloudCredentials
        guard !credentials.isEmpty else {
            cloudModels = []
            cloudRefreshing = false
            cloudRefreshError = nil
            return
        }

        cloudRefreshing = true
        defer { cloudRefreshing = false }

        var discovered: [CloudModel] = []
        var failures: [String] = []

        for provider in credentials.configured {
            guard let key = credentials.key(for: provider) else { continue }
            do {
                discovered += try await Self.fetchCloudModels(provider: provider, key: key)
            } catch {
                failures.append("\(provider.displayName): \(error.localizedDescription)")
            }
        }

        cloudModels = discovered.sorted {
            $0.provider == $1.provider
                ? $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
                : $0.provider.displayName < $1.provider.displayName
        }
        cloudRefreshError = failures.isEmpty ? nil : failures.joined(separator: " · ")
        pruneEnabledCloudModels()
    }

    /// `GET {base}/models`, in the OpenAI shape both providers serve.
    ///
    /// Static and taking its inputs plainly so a test can drive the parsing without a network
    /// or an AppModel.
    nonisolated static func fetchCloudModels(
        provider: CloudProvider, key: String, session: URLSession = .shared
    ) async throws -> [CloudModel] {
        var request = URLRequest(url: provider.chatBaseURL.appendingPathComponent("models"))
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await RemoteHTTP.data(
            for: request,
            session: session,
            policy: .publicHTTPS,
            credentialOrigin: provider.chatBaseURL
        )
        let status = (response as? HTTPURLResponse)?.statusCode ?? 502
        guard status == 200 else {
            throw CloudError.listing(status, Self.providerMessage(inBody: data) ?? "no detail")
        }
        return parseCloudModels(data, provider: provider)
    }

    /// Both providers answer `{"data": [{"id": …}]}`, but they disagree about everything
    /// else — OpenRouter names the window `context_length`, other OpenAI-compatible servers
    /// use `context_window` or `max_model_len`, and a display name may be absent entirely.
    /// Anything with an id is usable; the rest is decoration, so nothing here is required.
    nonisolated static func parseCloudModels(
        _ data: Data, provider: CloudProvider
    ) -> [CloudModel] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entries = root["data"] as? [[String: Any]]
        else { return [] }

        return entries.compactMap { entry in
            guard let id = entry["id"] as? String, !id.isEmpty else { return nil }
            let name = (entry["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
            let context = ["context_length", "context_window", "max_model_len"]
                .lazy.compactMap { entry[$0] as? Int }.first
            let owner = (entry["owned_by"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return CloudModel(
                id: id, displayName: name, provider: provider, contextWindow: context,
                owner: owner
            )
        }
    }

    /// A provider's own words about a failure, dug out of whichever envelope it used.
    nonisolated static func providerMessage(inBody body: Data) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        else { return nil }
        if let error = root["error"] as? [String: Any], let message = error["message"] as? String {
            return String(message.prefix(512))
        }
        if let message = root["message"] as? String { return String(message.prefix(512)) }
        if let error = root["error"] as? String { return String(error.prefix(512)) }
        return nil
    }

    // MARK: - What the gateway may serve

    /// The enabled models, in gateway shape. Only ticked ids appear, and only while their
    /// provider still has a key.
    func enabledCloudGatewayModels() -> [GatewayAPI.Model] {
        let enabled = Set(settings.enabledCloudModels ?? [])
        guard !enabled.isEmpty else { return [] }
        let credentials = cloudCredentials
        return cloudModels
            .filter { enabled.contains($0.gatewayID) && credentials.key(for: $0.provider) != nil }
            .map { model in
                GatewayAPI.Model(
                    id: model.gatewayID,
                    displayName: model.displayName,
                    where_: model.provider.displayName,
                    contextWindow: model.contextWindow,
                    // A remote model has nothing to load: it answers or it does not.
                    serving: true,
                    quantization: nil
                )
            }
    }

    /// The models an *automatic* choice may pick from — everything except remote ones.
    ///
    /// Remote models are listed as `serving: true`, because they are: there is nothing to
    /// load. That truth had a sharp edge. Codex, Pi and Qwen Code each pick a default with
    /// `first(where: \.serving)`, so on a Mac with nothing loaded the first model that
    /// looked ready was a remote one, and an agent would have started billing someone who
    /// had only ticked the box to make it *available*. Opting in to reachable is not opting
    /// in to chosen-for-you; an explicit pick still routes anywhere.
    func autoSelectableGatewayModels() -> [GatewayAPI.Model] {
        gatewayModelSnapshot().filter { !$0.id.hasPrefix("cloud/") }
    }

    /// Routing for a `cloud/…` id. There is no load and no wait — the work is on someone
    /// else's hardware — so this is a lookup that either finds a key or explains why not.
    func cloudBackend(provider rawProvider: String, model: String) throws -> GatewayReadyBackend {
        guard let provider = CloudProvider(rawValue: rawProvider) else {
            throw GatewayHostError.unknownModel("cloud/\(rawProvider)/\(model)")
        }
        let gatewayID = GatewayAPI.modelID(cloudProvider: provider.rawValue, model: model)
        let enabled = Set(settings.enabledCloudModels ?? [])
        guard enabled.contains(gatewayID),
              cloudModels.contains(where: { $0.gatewayID == gatewayID })
        else {
            // Enumeration and direct routing must enforce the same authority. Discovery is
            // deliberately part of the decision so a stale setting cannot resurrect a model
            // the provider no longer reports.
            throw GatewayHostError.unknownModel(gatewayID)
        }
        guard let key = cloudCredentials.key(for: provider) else {
            throw CloudError.noKey(provider.displayName)
        }
        return GatewayReadyBackend(
            baseURL: provider.chatBaseURL, backendModel: model, bearerToken: key
        )
    }
}

/// Failures that are worth reading. Both spell out the provider, because "it didn't work" is
/// useless when two of them are configured.
public enum CloudError: LocalizedError {
    case noKey(String)
    case listing(Int, String)

    public var errorDescription: String? {
        switch self {
        case .noKey(let provider):
            "\(provider) has no API key. Add one in Settings → Cloud providers."
        case .listing(let status, let message):
            "The provider answered \(status) when asked for its models: \(message)"
        }
    }
}

// MARK: - Remote speech and music

/// The Voice tab's remote half. Speech and music on a provider look exactly like a render on
/// a swarm node in the UI — same progress lines, same results list — because they are the
/// same shape of job, and nobody should have to learn a second one.
extension AppModel {

    /// Every speaking model that can actually be picked: the local catalogue, plus whatever
    /// audio the configured keys unlock. Local first, always.
    public var availableSpeakers: [VoiceEntry] {
        VoiceCatalog.speakers + cloudVoiceEntries(kind: .speak)
    }

    /// The same for the Music card.
    public var availableMusicians: [VoiceEntry] {
        VoiceCatalog.musicians + cloudVoiceEntries(kind: .music)
    }

    private func cloudVoiceEntries(kind: VoiceKind) -> [VoiceEntry] {
        let providers = cloudCredentials.configured.filter(\.offersAudio)
        let known = providers.flatMap { VoiceCatalog.cloudEntries(for: $0, kind: kind) }
        // Hand-typed ids go to the first provider with an audio queue — there is only one,
        // and inventing a per-id provider picker for a field this rarely used would cost
        // more attention than it saves.
        guard let provider = providers.first else { return known }
        let existing = Set(known.map(\.id))
        return known + customAudioEntries(provider: provider, kind: kind)
            .filter { !existing.contains($0.id) }
    }

    /// Entries for the ids someone typed into Settings.
    ///
    /// The kind is inferred from the id — anything containing "music" composes, everything
    /// else speaks. Crude, and correct for every id these providers have shipped; a wrong
    /// guess costs a model sitting under the wrong picker, not a failed render.
    private func customAudioEntries(
        provider: CloudProvider, kind: VoiceKind
    ) -> [VoiceEntry] {
        (settings.customCloudAudioModels ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { id in
                let looksMusical = id.localizedCaseInsensitiveContains("music")
                return kind == .music ? looksMusical : !looksMusical
            }
            .map { id in
                VoiceEntry(
                    id: VoiceCatalog.cloudEntryID(provider: provider, model: id),
                    name: "\(id) (added by you)",
                    author: "Unknown",
                    license: "Provider terms",
                    summary: "A model id you added by hand. It runs on "
                        + "\(provider.displayName); if the id is wrong, the provider will "
                        + "say so when you use it.",
                    backend: .cloud,
                    kind: kind,
                    repo: "",
                    weightsSize: .zero,
                    peakMemory: .zero,
                    typicalDuration: "unknown",
                    rating: 3
                )
            }
    }

    /// Looks up an id across both halves, so callers holding a persisted selection do not
    /// have to know whether it was local or remote when it was saved.
    func voiceEntry(id: String) -> VoiceEntry? {
        if let local = VoiceCatalog.entry(id: id) { return local }
        guard VoiceCatalog.parseCloudEntryID(id) != nil else { return nil }
        // Searched through the same lists the pickers show, so a hand-typed id resolves
        // exactly like a catalogued one.
        return (availableSpeakers + availableMusicians).first { $0.id == id }
    }

    func speakOnProvider(entry: VoiceEntry, text: String) {
        runCloudAudio(entry: entry) { model, directory in
            CloudAudioRequest(
                model: model, kind: .speech, text: text,
                voiceID: self.selectedPresetVoice.isEmpty ? nil : self.selectedPresetVoice,
                outputDirectory: directory
            )
        }
    }

    func composeOnProvider(entry: VoiceEntry, caption: String) {
        // The provider composes from lyrics and takes the caption as style direction — the
        // opposite emphasis to the local model, which leads with the caption. Sending an
        // empty lyric would be rejected, so the caption stands in when there are none.
        let lyrics = musicLyrics.trimmingCharacters(in: .whitespacesAndNewlines)
        runCloudAudio(entry: entry) { model, directory in
            CloudAudioRequest(
                model: model, kind: .music,
                text: lyrics.isEmpty ? caption : lyrics,
                stylePrompt: caption, outputDirectory: directory
            )
        }
    }

    /// One job at a time, the same rule the local runner has — not for memory here, but so
    /// the single progress line and results list stay truthful.
    private func runCloudAudio(
        entry: VoiceEntry,
        makeRequest: @escaping (String, URL) -> CloudAudioRequest
    ) {
        guard !isSpeaking else { return }
        guard let (provider, model) = VoiceCatalog.parseCloudEntryID(entry.id),
              let base = provider.jobsBaseURL else { return }
        guard let key = cloudCredentials.key(for: provider) else {
            voiceError = CloudError.noKey(provider.displayName).localizedDescription
            return
        }

        beginVoiceJob(stage: "Starting")
        noteActivity()

        let request = makeRequest(model, settings.resolvedVoiceOutputDirectory)
        let fallbackStage = "Working on \(provider.displayName)"
        Task {
            defer { endVoiceJob() }
            do {
                let result = try await cloudAudioRuntime.generate(
                    request, base: base, apiKey: key
                ) { progress in
                    Task { @MainActor in
                        self.setVoiceStage(progress.line(fallback: fallbackStage))
                    }
                }
                speechResults.insert(
                    SpeechResult(
                        audio: result.audio, modelName: entry.name, elapsed: result.elapsed
                    ),
                    at: 0
                )
            } catch {
                voiceError = error.localizedDescription
            }
        }
    }
}
