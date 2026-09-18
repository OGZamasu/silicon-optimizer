import Foundation
import Testing
@testable import SiliconCatalog
@testable import SiliconControl
@testable import SiliconCore
@testable import SiliconRuntime
@testable import SiliconUI

/// Bring-your-own-key remote providers: the id scheme that routes them, the discovery that
/// finds them, and the audio queue that is not OpenAI-shaped at all.
///
/// Everything here is hermetic — no key, no network. What these pin is the wire contract as
/// the providers document it, so a rename upstream shows up as a failing test rather than as
/// a picker entry that 404s.
@Suite("Cloud providers")
struct CloudProviderTests {

    // MARK: - Gateway ids

    /// The reason `cloud/` needs the same two-separator rule `node/` has: real model names
    /// carry slashes. GMI spells one "MiniMaxAI/MiniMax-M2.7" and OpenRouter spells the same
    /// family "minimax/minimax-m3"; splitting on every slash would lose half of each.
    @Test func aModelNameKeepsItsOwnSlashes() throws {
        let gmi = try #require(GatewayAPI.parseModelID("cloud/gmi/MiniMaxAI/MiniMax-M2.7"))
        #expect(gmi == .cloud(provider: "gmi", model: "MiniMaxAI/MiniMax-M2.7"))

        let router = try #require(
            GatewayAPI.parseModelID("cloud/open-router/minimax/minimax-m3")
        )
        #expect(router == .cloud(provider: "open-router", model: "minimax/minimax-m3"))
    }

    /// A `CloudModel` builds its own gateway id, so the picker and the router cannot disagree
    /// about what a model is called. Round-tripping is the only thing that proves it.
    @Test func aDiscoveredModelRoundTripsThroughItsGatewayID() throws {
        for id in ["MiniMaxAI/MiniMax-M2.7", "minimax/minimax-m3", "gpt-5.4-mini"] {
            for provider in CloudProvider.allCases {
                let model = CloudModel(id: id, displayName: id, provider: provider)
                let parsed = try #require(GatewayAPI.parseModelID(model.gatewayID))
                #expect(parsed == .cloud(provider: provider.rawValue, model: id))
            }
        }
    }

    @Test func aMalformedCloudIDIsRejectedRatherThanGuessedAt() {
        for id in ["cloud/", "cloud/gmi", "cloud/gmi/", "cloud//model"] {
            #expect(GatewayAPI.parseModelID(id) == nil, "\(id) should not parse")
        }
    }

    @Test @MainActor
    func directCloudRoutingRequiresTheEnabledDiscoveredModel() throws {
        let app = AppModel(settings: .init())
        let model = CloudModel(
            id: "minimax/minimax-m3", displayName: "MiniMax M3", provider: .openRouter
        )
        var credentials = CloudCredentials()
        credentials.set("test-secret", for: .openRouter)
        app.cloudCredentials = credentials
        app.cloudModels = [model]

        app.settings.enabledCloudModels = []
        #expect(throws: GatewayHostError.self) {
            try app.cloudBackend(provider: CloudProvider.openRouter.rawValue, model: model.id)
        }

        app.settings.enabledCloudModels = [model.gatewayID]
        let backend = try app.cloudBackend(
            provider: CloudProvider.openRouter.rawValue, model: model.id
        )
        #expect(backend.backendModel == model.id)
        #expect(backend.baseURL == CloudProvider.openRouter.chatBaseURL)
        #expect(backend.bearerToken == "test-secret")

        app.cloudModels = []
        #expect(throws: GatewayHostError.self) {
            try app.cloudBackend(provider: CloudProvider.openRouter.rawValue, model: model.id)
        }
    }

    // MARK: - Credentials

    /// Opting out has to be as complete as never having opted in: clearing the last key
    /// leaves nothing configured, and the file is deleted rather than left empty.
    @Test func clearingTheLastKeyLeavesNothingConfigured() {
        var credentials = CloudCredentials()
        #expect(credentials.isEmpty)

        credentials.set("gmi-key", for: .gmi)
        credentials.set("or-key", for: .openRouter)
        #expect(credentials.configured.count == 2)
        #expect(credentials.key(for: .gmi) == "gmi-key")

        credentials.set(nil, for: .gmi)
        #expect(credentials.configured == [.openRouter])

        credentials.set("   ", for: .openRouter)
        #expect(credentials.isEmpty, "whitespace is not a key")
    }

    @Test func onlyTheProviderWithAnAudioQueueOffersAudio() {
        #expect(CloudProvider.gmi.offersAudio)
        #expect(CloudProvider.gmi.jobsBaseURL != nil)
        // OpenRouter brokers chat only — advertising speech there would be a dead button.
        #expect(!CloudProvider.openRouter.offersAudio)
        #expect(CloudAudioCatalog.entries(for: .openRouter, kind: .speech).isEmpty)
    }

    // MARK: - Discovery

    /// OpenRouter's shape. The window is `context_length` here and something else elsewhere,
    /// which is why the parser reads several spellings.
    @Test func discoveryReadsTheOpenRouterShape() throws {
        let body = Data("""
        {"data": [
          {"id": "minimax/minimax-m3", "name": "MiniMax: MiniMax M3", "context_length": 1048576},
          {"id": "minimax/minimax-m2.7", "name": "MiniMax: MiniMax M2.7", "context_length": 204800}
        ]}
        """.utf8)

        let models = AppModel.parseCloudModels(body, provider: .openRouter)
        #expect(models.count == 2)
        let m3 = try #require(models.first { $0.id == "minimax/minimax-m3" })
        #expect(m3.displayName == "MiniMax: MiniMax M3")
        #expect(m3.contextWindow == 1_048_576)
        #expect(m3.gatewayID == "cloud/open-router/minimax/minimax-m3")
    }

    /// A bare OpenAI-compatible listing: ids and nothing else. Everything but the id is
    /// decoration, so a sparse answer still yields usable models.
    @Test func discoverySurvivesAListingWithNothingButIDs() throws {
        let body = Data("""
        {"data": [{"id": "MiniMaxAI/MiniMax-M2.7", "object": "model"},
                  {"id": "", "object": "model"},
                  {"object": "model"}]}
        """.utf8)

        let models = AppModel.parseCloudModels(body, provider: .gmi)
        #expect(models.count == 1, "entries without a usable id are dropped, not faked")
        let only = try #require(models.first)
        #expect(only.displayName == "MiniMaxAI/MiniMax-M2.7", "the id stands in for a name")
        #expect(only.contextWindow == nil)
    }

    @Test func garbageFromAProviderIsNoModelsRatherThanACrash() {
        #expect(AppModel.parseCloudModels(Data("not json".utf8), provider: .gmi).isEmpty)
        #expect(AppModel.parseCloudModels(Data("{}".utf8), provider: .gmi).isEmpty)
        #expect(AppModel.parseCloudModels(Data("[]".utf8), provider: .gmi).isEmpty)
    }

    @Test func aProvidersOwnWordsAreDugOutOfWhicheverEnvelopeItUsed() {
        #expect(AppModel.providerMessage(
            inBody: Data(#"{"error":{"message":"no credit"}}"#.utf8)
        ) == "no credit")
        #expect(AppModel.providerMessage(
            inBody: Data(#"{"message":"API key is required."}"#.utf8)
        ) == "API key is required.")
        #expect(AppModel.providerMessage(inBody: Data("nonsense".utf8)) == nil)
    }

    /// NVIDIA's hosted catalogue, in the shape it actually answers with: no display name and
    /// no context length, just an id and an owner. Every id carries a slash, which is the
    /// case that would break a naive `cloud/` parser.
    @Test func discoveryReadsTheSparseNVIDIAShape() throws {
        let body = Data(#"""
        {"object": "list", "data": [
          {"id": "nvidia/llama-3.1-nemotron-ultra-253b-v1", "object": "model",
           "created": 735790403, "owned_by": "nvidia"},
          {"id": "moonshotai/kimi-k3", "object": "model",
           "created": 735790403, "owned_by": "moonshotai"}
        ]}
        """#.utf8)

        let models = AppModel.parseCloudModels(body, provider: .nvidia)
        #expect(models.count == 2)

        let nemotron = try #require(models.first)
        // No name and no window are offered, so none are invented.
        #expect(nemotron.displayName == "nvidia/llama-3.1-nemotron-ultra-253b-v1")
        #expect(nemotron.contextWindow == nil)

        // The id's own slash must survive the round trip through the gateway id.
        let parsed = try #require(GatewayAPI.parseModelID(nemotron.gatewayID))
        #expect(parsed == .cloud(
            provider: "nvidia", model: "nvidia/llama-3.1-nemotron-ultra-253b-v1"
        ))
    }

    @Test func nvidiaIsChatOnlyAndPointsAtItsHostedCatalogue() {
        #expect(
            CloudProvider.nvidia.chatBaseURL.absoluteString
                == "https://integrate.api.nvidia.com/v1"
        )
        // Riva is NVIDIA's speech brand, but the three riva-* entries in this catalogue are
        // translation models. There is no audio queue here, so none is advertised.
        #expect(!CloudProvider.nvidia.offersAudio)
        #expect(CloudProvider.nvidia.jobsBaseURL == nil)
        #expect(VoiceCatalog.cloudEntries(for: .nvidia, kind: .speak).isEmpty)
    }

    /// Token Harbor's ids carry no maker slash at all — "deepseek-v4-flash:free" — which is
    /// the one shape the two-separator rule had not yet been asked to round-trip.
    @Test func tokenHarborIsChatOnlyAndItsSlashlessIDsRoundTrip() throws {
        #expect(CloudProvider.tokenHarbor.chatBaseURL.absoluteString == "https://tokenharbor.ai/v1")
        #expect(!CloudProvider.tokenHarbor.offersAudio)

        let body = Data("""
        {"data": [{"id": "deepseek-v4-flash:free", "object": "model"},
                  {"id": "claude-opus-5", "object": "model"}]}
        """.utf8)
        let models = AppModel.parseCloudModels(body, provider: .tokenHarbor)
        #expect(models.count == 2)

        let free = try #require(models.first { $0.id == "deepseek-v4-flash:free" })
        let parsed = try #require(GatewayAPI.parseModelID(free.gatewayID))
        #expect(parsed == .cloud(provider: "token-harbor", model: "deepseek-v4-flash:free"))
    }

    /// The free tier is read off the id the provider sent — "never charges your balance",
    /// by suffix — not off a list kept here that would rot the day a model moved tiers.
    @Test func theFreeTierIsReadFromTheSuffix() {
        #expect(CloudModel(id: "deepseek-v4-flash:free", displayName: "x", provider: .tokenHarbor).isFree)
        #expect(!CloudModel(id: "deepseek-v4-flash", displayName: "x", provider: .tokenHarbor).isFree)
        // A ":free" anywhere but the end is not the tier.
        #expect(!CloudModel(id: "free:model", displayName: "x", provider: .tokenHarbor).isFree)
    }

    /// AIHubMix's public listing, in the shape it actually answers: id and owned_by, no
    /// context, no slash in the id. The owner is the only maker information there is.
    @Test func aiHubMixListsAreReadWithTheirOwnerAndTheirFreeSuffix() throws {
        #expect(CloudProvider.aiHubMix.chatBaseURL.absoluteString == "https://aihubmix.com/v1")
        #expect(!CloudProvider.aiHubMix.offersAudio)

        let body = Data("""
        {"data": [{"id": "coding-glm-5.3-free", "object": "model", "created": 1626777600, "owned_by": "Z.AI"},
                  {"id": "glm-5.3-flash", "object": "model", "created": 1626777600, "owned_by": "Z.AI"},
                  {"id": "gpt-5.5-free", "object": "model", "created": 1626777600, "owned_by": ""}]}
        """.utf8)
        let models = AppModel.parseCloudModels(body, provider: .aiHubMix)
        #expect(models.count == 3)

        let free = try #require(models.first { $0.id == "coding-glm-5.3-free" })
        #expect(free.isFree)
        #expect(free.owner == "Z.AI")
        #expect(free.contextWindow == nil)
        // No slash to split, so the listing's owner becomes the second line.
        let labels = CloudView.labels(for: free)
        #expect(labels.title == "coding-glm-5.3-free")
        #expect(labels.subtitle == "Z.AI")
        #expect(CloudView.maker(of: free) == "Z.AI")

        let paid = try #require(models.first { $0.id == "glm-5.3-flash" })
        #expect(!paid.isFree)

        // An empty owned_by is no owner, not an owner called "".
        let blank = try #require(models.first { $0.id == "gpt-5.5-free" })
        #expect(blank.owner == nil)
        #expect(CloudView.labels(for: blank).subtitle.isEmpty)
    }

    /// Each provider spells "free" its own way, and one provider's spelling must not be
    /// read as the tier on another — a "-free" on Token Harbor is just a name.
    @Test func theFreeSuffixIsPerProvider() {
        #expect(CloudModel(id: "x-free", displayName: "x", provider: .aiHubMix).isFree)
        #expect(!CloudModel(id: "x:free", displayName: "x", provider: .aiHubMix).isFree)
        #expect(CloudModel(id: "x:free", displayName: "x", provider: .tokenHarbor).isFree)
        #expect(!CloudModel(id: "x-free", displayName: "x", provider: .tokenHarbor).isFree)
        // Providers with no free tier never claim one, whatever the id says.
        #expect(!CloudModel(id: "x-free", displayName: "x", provider: .nvidia).isFree)
        #expect(!CloudModel(id: "x:free", displayName: "x", provider: .openRouter).isFree)
    }

    /// When both are present the id's own slash wins: it is the provider's canonical
    /// grouping, and owned_by is sometimes a gateway's name rather than the maker's.
    @Test func aSlashInTheIDOutranksOwnedBy() {
        let entry = CloudModel(id: "nvidia/nemotron-x", displayName: "nvidia/nemotron-x",
                               provider: .nvidia, owner: "NVIDIA Corp")
        #expect(CloudView.maker(of: entry) == "nvidia")
        #expect(CloudView.labels(for: entry).subtitle == "nvidia")
    }

    // MARK: - What a row prints

    /// NVIDIA and GMI return ids with no display name, so `displayName` falls back to the id.
    /// Printed naively that was ninety-five rows of the same string stacked on itself.
    @Test func aRowWithNoNameFromTheProviderSplitsTheIDInstead() {
        let nvidia = CloudModel(
            id: "deepseek-ai/deepseek-v4-flash-0731",
            displayName: "deepseek-ai/deepseek-v4-flash-0731",  // the parser's own fallback
            provider: .nvidia
        )
        let labels = CloudView.labels(for: nvidia)
        #expect(labels.title == "deepseek-v4-flash-0731")
        #expect(labels.subtitle == "deepseek-ai")
        #expect(labels.title != labels.subtitle)
    }

    /// OpenRouter does send names, and a real name beats anything derived from the id.
    @Test func aRealNameIsPreferredOverTheID() {
        let router = CloudModel(
            id: "minimax/minimax-m3", displayName: "MiniMax: MiniMax M3",
            provider: .openRouter, contextWindow: 1_048_576
        )
        let labels = CloudView.labels(for: router)
        #expect(labels.title == "MiniMax: MiniMax M3")
        #expect(labels.subtitle == "minimax/minimax-m3")
    }

    /// An id with no maker has nothing to split, and must not lose its name to an empty line.
    @Test func anIDWithoutAMakerKeepsItsWholeName() {
        let bare = CloudModel(id: "gpt-4o", displayName: "gpt-4o", provider: .nvidia)
        let labels = CloudView.labels(for: bare)
        #expect(labels.title == "gpt-4o")
        #expect(labels.subtitle.isEmpty, "an empty subtitle takes no room in the row")
    }

    // MARK: - Never chosen for you

    /// The sharp edge of listing a remote model as `serving: true`: it *is* serving, so the
    /// `first(where: \.serving)` that Codex, Pi and Qwen Code each use to pick a default
    /// would land on it whenever nothing local was loaded — and start billing someone who
    /// had only ticked the box to make it reachable.
    @Test func anAutomaticChoiceNeverLandsOnARemoteModel() {
        let localIdle = GatewayAPI.Model(
            id: "local/qwen3", displayName: "Qwen3", where_: "This Mac", serving: false
        )
        let remote = GatewayAPI.Model(
            id: "cloud/nvidia/moonshotai/kimi-k3", displayName: "Kimi K3",
            where_: "NVIDIA", serving: true
        )

        // The shape the bug needed: nothing local serving, a remote one that always is.
        let snapshot = [localIdle, remote]
        let autoSelectable = snapshot.filter { !$0.id.hasPrefix("cloud/") }

        #expect(autoSelectable.first(where: \.serving) == nil, "nothing local is ready")
        #expect(
            autoSelectable.first?.id == "local/qwen3",
            "the fallback is the idle local model — loading it is the right cost to pay"
        )
        #expect(!autoSelectable.contains { $0.id.hasPrefix("cloud/") })

        // And the unfiltered list is exactly what would have gone wrong.
        #expect(snapshot.first(where: \.serving)?.id == remote.id)
    }

    // MARK: - Remote models as catalogue entries

    /// The Voice tab's pickers hold entry ids, and the runner has to get a provider and a
    /// model id back out of one. Round-tripping is the whole contract.
    @Test func aRemoteVoiceEntryRoundTripsThroughItsID() throws {
        let entries = VoiceCatalog.cloudEntries(for: .gmi, kind: .music)
        #expect(!entries.isEmpty)

        let music = try #require(entries.first { $0.name.contains("Music 3.0") })
        #expect(music.backend == .cloud)
        let (provider, model) = try #require(VoiceCatalog.parseCloudEntryID(music.id))
        #expect(provider == .gmi)
        #expect(model == "minimax-music-3.0")

        // A remote model occupies none of this Mac's memory, and the entry says so rather
        // than carrying a number borrowed from somewhere.
        #expect(music.weightsSize == .zero)
        #expect(music.peakMemory == .zero)
    }

    /// A local entry id must not be mistaken for a remote one, or the Voice tab would try to
    /// send Kokoro to a provider.
    @Test func aLocalEntryIDIsNotMistakenForARemoteOne() {
        #expect(VoiceCatalog.parseCloudEntryID(VoiceCatalog.kokoro.id) == nil)
        #expect(VoiceCatalog.parseCloudEntryID(VoiceCatalog.minimaxMusic.id) == nil)
        #expect(VoiceCatalog.parseCloudEntryID("cloud/nonsense-provider/x") == nil)
        #expect(VoiceCatalog.parseCloudEntryID("cloud/gmi/") == nil)
    }

    /// Transcription and sound effects have no remote counterpart wired, so they must offer
    /// none rather than offering one that cannot run.
    @Test func onlySpeechAndMusicHaveRemoteCounterparts() {
        #expect(!VoiceCatalog.cloudEntries(for: .gmi, kind: .speak).isEmpty)
        #expect(!VoiceCatalog.cloudEntries(for: .gmi, kind: .music).isEmpty)
        #expect(VoiceCatalog.cloudEntries(for: .gmi, kind: .transcribe).isEmpty)
        #expect(VoiceCatalog.cloudEntries(for: .gmi, kind: .soundEffect).isEmpty)
        // And a provider with no audio queue offers nothing at all.
        #expect(VoiceCatalog.cloudEntries(for: .openRouter, kind: .speak).isEmpty)
    }

    // MARK: - The audio queue

    /// Speech and music share an envelope and share almost no payload. This pins both against
    /// the documented request bodies.
    @Test func speechAndMusicSendDifferentPayloadsUnderTheSameEnvelope() throws {
        let directory = URL(fileURLWithPath: "/tmp")

        let speech = CloudAudioRuntime.submissionBody(for: CloudAudioRequest(
            model: "minimax-tts-speech-2.6-turbo", kind: .speech,
            text: "Let's convert text to speech.", voiceID: "English_expressive_narrator",
            speed: 1, outputDirectory: directory
        ))
        #expect(speech["model"] as? String == "minimax-tts-speech-2.6-turbo")
        let speechPayload = try #require(speech["payload"] as? [String: Any])
        #expect(speechPayload["text"] as? String == "Let's convert text to speech.")
        #expect(speechPayload["voice_id"] as? String == "English_expressive_narrator")
        #expect(speechPayload["lyrics"] == nil, "speech has no lyrics")
        // Quoted, as every documented example on this endpoint quotes them.
        #expect(speechPayload["speed"] as? String == "1")

        let music = CloudAudioRuntime.submissionBody(for: CloudAudioRequest(
            model: "minimax-music-3.0", kind: .music,
            text: "[verse]\nStreetlights flicker", stylePrompt: "Indie folk, melancholic",
            sampleRate: 44100, outputDirectory: directory
        ))
        let musicPayload = try #require(music["payload"] as? [String: Any])
        #expect(musicPayload["lyrics"] as? String == "[verse]\nStreetlights flicker")
        #expect(musicPayload["prompt"] as? String == "Indie folk, melancholic")
        #expect(musicPayload["text"] == nil, "music takes lyrics, not text")
        // Music quotes nothing — same provider, different convention per model family.
        #expect(musicPayload["sample_rate"] as? Int == 44100)
    }

    /// Music answers with the same URL three ways. Reading all three and de-duplicating is
    /// what keeps one renamed key upstream from becoming a failed render here.
    @Test func everySpellingOfTheResultURLIsRead() throws {
        let base = URL(string: "https://console.gmicloud.ai")!
        let musicOutcome: [String: Any] = [
            "audio_url": "https://cdn.example.com/song.mp3",
            "medias": [["id": "0", "url": "https://cdn.example.com/song.mp3"]],
            "media_urls": [["id": "0", "url": "https://cdn.example.com/song.mp3"]],
        ]
        let fromMusic = CloudAudioRuntime.audioURLs(inOutcome: musicOutcome, base: base)
        #expect(fromMusic.count == 1, "the same URL three ways is still one file")

        // Speech uses media_urls alone.
        let speechOutcome: [String: Any] = [
            "media_urls": [["id": "0", "url": "https://cdn.example.com/speech.mp3"]],
            "voice_id": "",
        ]
        #expect(CloudAudioRuntime.audioURLs(inOutcome: speechOutcome, base: base).count == 1)

        #expect(CloudAudioRuntime.audioURLs(inOutcome: [:], base: base).isEmpty)
        #expect(CloudAudioRuntime.audioURLs(
            inOutcome: ["audio_url": "http://127.0.0.1/admin"], base: base
        ).isEmpty)
    }

    /// A failed or cancelled job has to end the poll. Treating only "success" as terminal
    /// would leave someone watching a spinner for the full fifteen-minute deadline after the
    /// provider had already given up.
    @Test func aFinishedJobEndsThePollWhetherOrNotItWorked() {
        for state in ["success", "failed", "cancelled", "SUCCESS", "Failed"] {
            #expect(CloudAudioRuntime.terminalStatus(state), "\(state) is terminal")
        }
        for state in ["queued", "processing", ""] {
            #expect(!CloudAudioRuntime.terminalStatus(state), "\(state) is not terminal")
        }
        #expect(CloudAudioRuntime.succeeded("success"))
        #expect(!CloudAudioRuntime.succeeded("failed"))
        #expect(!CloudAudioRuntime.succeeded("cancelled"))
    }

    /// The queue path is shared by submission and polling, and the poll appends an id to it.
    @Test func theQueuePathMatchesWhatTheProviderDocuments() {
        #expect(CloudAudioRuntime.requestsPath == "api/v1/ie/requestqueue/apikey/requests")
        let base = try! #require(CloudProvider.gmi.jobsBaseURL)
        #expect(
            base.appendingPathComponent(CloudAudioRuntime.requestsPath).absoluteString
                == "https://console.gmicloud.ai/api/v1/ie/requestqueue/apikey/requests"
        )
    }
}


@Suite("Install requests")
struct InstallRequestTests {
    /// The MCP binary in the bundle and the app it talks to can differ by a release, so the
    /// install request must decode with or without the newer `directory` field, and must
    /// not put an empty one on the wire.
    @Test func directoryIsOptionalOnTheWire() throws {
        let legacy = try JSONDecoder().decode(
            ControlAPI.LoadRequest.self,
            from: Data(#"{"modelID":"bonsai-2-27b","quantization":"PTQ1_0"}"#.utf8)
        )
        #expect(legacy.directory == nil)

        let external = try JSONDecoder().decode(
            ControlAPI.LoadRequest.self,
            from: Data(#"{"modelID":"bonsai-2-27b","directory":"/Volumes/T9/Local Models"}"#.utf8)
        )
        #expect(external.directory == "/Volumes/T9/Local Models")

        let encoded = try JSONEncoder().encode(ControlAPI.LoadRequest(modelID: "x"))
        #expect(!String(decoding: encoded, as: UTF8.self).contains("directory"))
    }
}
