import Foundation

/// The models a paired phone runs by itself when this Mac is out of reach — and the Mac's
/// part in getting one onto it.
///
/// The phone stays tailnet-only: it never talks to Hugging Face. The Mac fetches the pinned
/// file, verifies it, and serves it to the phone from `/ondevice/models/{id}/file` with
/// ranges, so a phone that walks out of range halfway through a 3.35 GB transfer picks up
/// where it stopped. Nothing here loads a model on the Mac; these files are only ever
/// passed along.
///
/// Every route is full scope only. A chat-only device is refused by the scope gate before
/// it gets here — none of these paths is in `chatOnlyRoutes` — and the swarm token is
/// refused at the route with its own sentence: a node has no phone, and fetching gigabytes
/// onto this Mac's disk for one is the owner's decision.
extension ControlAPI {

    /// What `onMac.state` can say.
    public static let phoneModelStates = ["absent", "downloading", "ready", "failed"]

    /// What `onMac.failure` can say when the state is `failed` — what a phone can do
    /// about it, in one word. `diskFull`: free space on the Mac; retrying will not help.
    /// `checksumMismatch`: the bytes were wrong and have been deleted; a retry starts over.
    /// `network`: the connection was cut; a retry resumes. `server`: Hugging Face refused.
    /// `interrupted`: the app quit mid-transfer; a retry resumes. `other`: see `reason`.
    public static let phoneModelFailures = [
        "diskFull", "checksumMismatch", "network", "server", "interrupted", "other",
    ]

    /// `GET /ondevice/models`.
    public struct PhoneModelList: Codable, Sendable, Equatable {
        public var models: [PhoneModel]

        public init(models: [PhoneModel]) { self.models = models }
    }

    /// One model a phone can run, pinned to exact bytes, and where the Mac's copy of it is.
    public struct PhoneModel: Codable, Sendable, Equatable {
        /// The catalogue key. The only thing a route takes; never a path.
        public var id: String
        public var label: String
        /// The one to offer first.
        public var isDefault: Bool
        public var sizeBytes: Int64
        /// Lower-case hex. The file route's `ETag` and `X-Content-SHA256`, and what the
        /// phone checks at the end of its own transfer.
        public var sha256: String
        public var licence: String
        public var source: Source
        public var onMac: OnMac
        public var recommended: Recommended
        public var measured: Measured?
        /// Larger and noticeably slower on the phone than the default.
        public var slowerOnPhone: Bool

        /// Where the bytes come from — a Hugging Face repository at a fixed commit.
        public struct Source: Codable, Sendable, Equatable {
            public var repo: String
            public var commit: String
            public var file: String

            public init(repo: String, commit: String, file: String) {
                self.repo = repo
                self.commit = commit
                self.file = file
            }
        }

        /// The Mac's own copy.
        public struct OnMac: Codable, Sendable, Equatable {
            /// One of `ControlAPI.phoneModelStates`.
            public var state: String
            /// How much of the file the Mac has: while `downloading`, and on a `failed` that
            /// left a partial to resume from.
            public var fraction: Double?
            /// Why it is `failed`, in a sentence a phone can show.
            public var reason: String?
            /// One of `ControlAPI.phoneModelFailures`, when `failed`.
            public var failure: String?

            public init(
                state: String, fraction: Double? = nil, reason: String? = nil,
                failure: String? = nil
            ) {
                self.state = state
                self.fraction = fraction
                self.reason = reason
                self.failure = failure
            }
        }

        /// How to run it on the phone.
        public struct Recommended: Codable, Sendable, Equatable {
            public var threadsPrompt: Int
            public var threadsGenerate: Int
            public var contextLength: Int
            public var minFreeMemoryBytes: Int64
            /// Render the chat template with thinking on or off.
            public var thinking: Bool

            public init(
                threadsPrompt: Int, threadsGenerate: Int, contextLength: Int,
                minFreeMemoryBytes: Int64, thinking: Bool
            ) {
                self.threadsPrompt = threadsPrompt
                self.threadsGenerate = threadsGenerate
                self.contextLength = contextLength
                self.minFreeMemoryBytes = minFreeMemoryBytes
                self.thinking = thinking
            }
        }

        /// What a real phone measured, so the phone can say what to expect.
        public struct Measured: Codable, Sendable, Equatable {
            public var device: String
            public var runtime: String
            public var conditions: String
            /// Seconds to the first word of an answer to a 300-token question.
            public var secondsToFirstWord300: Double
            /// Writing speed: the low end of the measured range…
            public var tokensPerSecond: Double
            /// …and its high end, when a range was measured.
            public var tokensPerSecondMax: Double?
            /// What a long answer settles to once the phone is hot.
            public var sustainedTokensPerSecond: Double?

            public init(
                device: String, runtime: String, conditions: String,
                secondsToFirstWord300: Double, tokensPerSecond: Double,
                tokensPerSecondMax: Double? = nil, sustainedTokensPerSecond: Double? = nil
            ) {
                self.device = device
                self.runtime = runtime
                self.conditions = conditions
                self.secondsToFirstWord300 = secondsToFirstWord300
                self.tokensPerSecond = tokensPerSecond
                self.tokensPerSecondMax = tokensPerSecondMax
                self.sustainedTokensPerSecond = sustainedTokensPerSecond
            }
        }

        public init(
            id: String, label: String, isDefault: Bool, sizeBytes: Int64, sha256: String,
            licence: String, source: Source, onMac: OnMac, recommended: Recommended,
            measured: Measured?, slowerOnPhone: Bool
        ) {
            self.id = id
            self.label = label
            self.isDefault = isDefault
            self.sizeBytes = sizeBytes
            self.sha256 = sha256
            self.licence = licence
            self.source = source
            self.onMac = onMac
            self.recommended = recommended
            self.measured = measured
            self.slowerOnPhone = slowerOnPhone
        }

        /// The `id` a `download` frame on `/events` carries while the Mac fetches this model:
        /// `ondevice:` and the model's id. The Mac's own model downloads never start with it.
        public var downloadEventID: String { Self.downloadEventPrefix + id }

        public static let downloadEventPrefix = "ondevice:"
    }

    /// What a prepare did, for the server to pick its status from: 200 for a model that was
    /// already ready, 202 for one that is — or now is — on its way. Never on the wire.
    public struct PhoneModelPreparation: Sendable, Equatable {
        public var model: PhoneModel
        public var wasReady: Bool

        public init(model: PhoneModel, wasReady: Bool) {
            self.model = model
            self.wasReady = wasReady
        }
    }

    /// A verified file, as the route that streams it needs it. Never on the wire: a phone
    /// is handed an id, never a path.
    public struct PhoneModelFile: Sendable, Equatable {
        public var url: URL
        public var sizeBytes: Int64
        public var sha256: String
        /// The name offered in `Content-Disposition` — the pinned file's own, which carries
        /// nothing about where it sits on this Mac.
        public var fileName: String

        public init(url: URL, sizeBytes: Int64, sha256: String, fileName: String) {
            self.url = url
            self.sizeBytes = sizeBytes
            self.sha256 = sha256
            self.fileName = fileName
        }
    }
}

/// What the `/ondevice/models` routes are answered from. The app implements it over its
/// phone-model store; a host without one serves an empty list and 404s.
public protocol PhoneModelProvider: Sendable {
    /// `GET /ondevice/models`.
    func phoneModels() async -> ControlAPI.PhoneModelList
    /// `POST /ondevice/models/{id}/prepare`.
    func preparePhoneModel(id: String) async throws -> ControlAPI.PhoneModelPreparation
    /// `GET /ondevice/models/{id}/file` — the verified file, or `PhoneModelError.notReady`.
    func phoneModelFile(id: String) async throws -> ControlAPI.PhoneModelFile
    /// `DELETE /ondevice/models/{id}` — the entry as it is afterwards.
    func removePhoneModel(id: String) async throws -> ControlAPI.PhoneModel
}

/// Why a phone-model route said no.
public enum PhoneModelError: Error, LocalizedError, ControlStatusError, Equatable {
    /// Not a catalogue id. Answered the same whatever was sent — a path, a file name, a
    /// traversal — because an id is looked up and never read.
    case unknownModel(String)
    /// The Mac's copy is not verified and in place yet.
    case notReady(String)
    /// The Mac has no room for it, said before anything was fetched.
    case noSpace(String)

    public var errorDescription: String? {
        switch self {
        case .unknownModel: ControlServer.noSuchPhoneModel
        case .notReady: ControlServer.phoneModelNotReady
        case .noSpace(let reason): reason
        }
    }

    public var status: Int {
        switch self {
        case .unknownModel: 404
        case .notReady: 409
        case .noSpace: 507
        }
    }
}

extension ControlServer {

    /// What the swarm token is told on every `/ondevice` route.
    public static let phoneModelsAreNotForPeers =
        "A swarm node may not fetch or manage the models this Mac keeps for your phone. "
        + "They are for the owner's own devices: pair one from Settings → Silicon Buddy."

    /// What a loopback caller with the wrong `Host` is told on a phone-model route.
    public static let phoneModelsAreForLoopbackHosts =
        "Only loopback clients may use the phone-model routes on this listener."

    /// An id that is not in the phone-model catalogue.
    public static let noSuchPhoneModel =
        "No phone model with that id. GET /ondevice/models lists the ones this Mac can "
        + "fetch for a phone."

    /// Asked for the file before the Mac has it, verified, in place.
    public static let phoneModelNotReady =
        "This Mac does not have that model ready yet. Ask for it with "
        + "POST /ondevice/models/{id}/prepare, and fetch it once GET /ondevice/models says "
        + "it is ready."
}

extension ControlHost {
    /// No phone models: the list is empty and every id is a 404.
    public func phoneModelProvider() async -> (any PhoneModelProvider)? { nil }
}
