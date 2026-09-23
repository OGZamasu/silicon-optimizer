import Foundation

/// The wire contract Silicon Buddy — the phone and tablet companion — speaks to this Mac.
///
/// These shapes are what the mobile apps are generated from, so they are pinned by
/// `ContractExportTests` rather than left to follow the Mac UI around. Timestamps are
/// ISO-8601 strings rather than Codable `Date`s: the control server encodes with a plain
/// `JSONEncoder`, which would otherwise hand a phone a reference-date double and make every
/// client re-derive the epoch.
extension ControlAPI {

    /// The one timestamp format on this wire.
    public static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    public static func date(fromTimestamp text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    // MARK: - Pairing

    /// The body of `POST /buddy/invitations` — the Mac asking itself for the same code
    /// BuddyCenter's "Pair a device" would put on screen.
    ///
    /// Only the scope, because nothing else about a code is the caller's to choose: where
    /// it points is wherever the tailnet listener actually is, and how long it lives is
    /// `BuddyPairing.codeLifetime`. The field is optional so a caller with nothing to say
    /// can send `{}`, or no body at all, and get what the Settings window offers by default.
    public struct BuddyInvitationRequest: Codable, Sendable, Equatable {
        /// "full" or "chat". Absent means full control.
        public var scope: String?

        public init(scope: String? = nil) { self.scope = scope }
    }

    /// A code the owner would otherwise be reading aloud off the Settings window, with the
    /// two things a device needs in order to spend it: where to dial, and when it stops
    /// working.
    ///
    /// This response is the only place the code exists outside the Mac's own memory. It is
    /// never logged and never handed out twice — a second `GET` for it would turn a code
    /// with a five-minute life into one that lasts as long as the process does.
    public struct BuddyInvitationResponse: Codable, Sendable, Equatable {
        public var code: String
        /// The tailnet listener's address and port, never loopback's: loopback takes a
        /// fresh ephemeral port every launch, so a device sent there would lose this Mac
        /// the next time it restarted.
        public var host: String
        public var port: Int
        public var expiresAt: String
        /// "full" or "chat" — what `POST /buddy/pair` will grant whoever spends this code.
        public var scope: String

        public init(
            code: String, host: String, port: Int, expiresAt: String, scope: String = "full"
        ) {
            self.code = code
            self.host = host
            self.port = port
            self.expiresAt = expiresAt
            self.scope = scope
        }
    }

    /// The body of the one unauthenticated POST on this server. A device offers the code the
    /// owner is looking at and says what it is; it gets back a credential of its own.
    public struct BuddyPairRequest: Codable, Sendable, Equatable {
        public var code: String
        public var deviceName: String
        public var platform: String

        public init(code: String, deviceName: String, platform: String) {
            self.code = code
            self.deviceName = deviceName
            self.platform = platform
        }
    }

    /// What a device may do. The phone does not ask for this — the owner chose it on the
    /// Mac before the code was shown — so it arrives in the answer, not the request.
    public static let buddyScopes = ["full", "chat"]

    /// The only time a device token exists in plaintext. The Mac keeps a hash; the phone
    /// keeps this in its own keychain and presents it as a bearer from then on.
    public struct BuddyPairResponse: Codable, Sendable, Equatable {
        public var deviceID: String
        public var token: String
        public var macName: String
        public var port: Int
        /// "full" or "chat". A chat-only device should hide the controls it cannot use
        /// rather than discovering them as 403s.
        public var scope: String

        public init(
            deviceID: String, token: String, macName: String, port: Int,
            scope: String = "full"
        ) {
            self.deviceID = deviceID
            self.token = token
            self.macName = macName
            self.port = port
            self.scope = scope
        }
    }

    /// A paired device as the Settings list and `GET /buddy/devices` show it — never the
    /// token hash, which has no reason to leave the file it is written in.
    public struct BuddyDeviceSummary: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var name: String
        public var platform: String
        /// "full" or "chat".
        public var scope: String
        public var pairedAt: String
        public var lastSeen: String?
        /// True when this device was paired before the tailnet listener took a fixed port
        /// and therefore holds an address that no longer answers. Nothing is wrong with the
        /// token — the device simply cannot find this Mac until it is paired again.
        public var needsRepair: Bool

        public init(
            id: String, name: String, platform: String, scope: String = "full",
            pairedAt: String, lastSeen: String? = nil, needsRepair: Bool = false
        ) {
            self.id = id
            self.name = name
            self.platform = platform
            self.scope = scope
            self.pairedAt = pairedAt
            self.lastSeen = lastSeen
            self.needsRepair = needsRepair
        }
    }

    // MARK: - Streaming chat

    /// One frame of `POST /chat/stream`, named after the SSE event that carries it.
    ///
    /// **`finished` ends the reply.** A client may stop rendering there. `verdict` is an
    /// optional extra frame that follows it when answer verification is on *and* Jev
    /// answered quickly enough to catch the stream; otherwise the verdict arrives later on
    /// `/events`, or on the message itself in `GET /conversations/{id}`. Any event name a
    /// client does not recognise must be ignored rather than treated as an error — that is
    /// what lets this contract grow without breaking the apps generated from it.
    public enum ChatStreamEvent: Sendable, Equatable {
        case token(String)
        case reasoning(String)
        case finished(ChatMetrics)
        case verdict(ChatVerdict)
    }

    /// What Jev made of a finished answer.
    ///
    /// One shape for both places it appears — the `verification` field of a `/chat`
    /// response and the `verdict` SSE frame — so a client parses it once.
    public struct ChatVerdict: Codable, Sendable, Equatable, Hashable {
        /// `accept`, `annotate` or `escalate`.
        public var verdict: String
        /// Plain sentences, already written for a reader. Empty on `accept`.
        public var reasons: [String]
        /// The gateway model that answered instead, when one did. Always nil on a stream:
        /// the tokens are already on screen there, so a stream reports and suggests rather
        /// than silently replacing what the reader has been watching arrive.
        public var escalatedTo: String?
        /// What to do about it, when nothing was done automatically — including the case
        /// where there was nowhere to escalate to. A reason says what is wrong with the
        /// answer; a suggestion says what the reader can do, and the two are kept apart so
        /// a client can show one without the other.
        public var suggestion: String?
        /// Which conversation and which message this is about, when it is about one.
        ///
        /// Both nil for `POST /chat` and `POST /chat/stream`, which have no transcript to
        /// point at. Set on `/conversations/{id}/messages`, and it is what makes the
        /// `verdict` frame on `/events` usable: a verdict that arrives after the stream has
        /// closed has to say which bubble it belongs to.
        public var conversationID: String?
        public var messageID: String?

        public init(
            verdict: String, reasons: [String] = [], escalatedTo: String? = nil,
            suggestion: String? = nil, conversationID: String? = nil,
            messageID: String? = nil
        ) {
            self.verdict = verdict
            self.reasons = reasons
            self.escalatedTo = escalatedTo
            self.suggestion = suggestion
            self.conversationID = conversationID
            self.messageID = messageID
        }
    }

    /// The payload of a `token` or `reasoning` event. An object rather than a bare string so
    /// a client parses every frame the same way, whatever the event is called.
    public struct StreamToken: Codable, Sendable, Equatable {
        public var text: String

        public init(text: String) { self.text = text }
    }

    /// The payload of a `finished` event.
    public struct ChatMetrics: Codable, Sendable, Equatable {
        public var promptTokens: Int
        public var generatedTokens: Int
        public var tokensPerSecond: Double
        public var timeToFirstToken: Double

        public init(
            promptTokens: Int, generatedTokens: Int,
            tokensPerSecond: Double, timeToFirstToken: Double
        ) {
            self.promptTokens = promptTokens
            self.generatedTokens = generatedTokens
            self.tokensPerSecond = tokensPerSecond
            self.timeToFirstToken = timeToFirstToken
        }
    }

    // MARK: - The /events side channel

    public struct DownloadEvent: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var fraction: Double
        public var bytesReceived: Int64
        public var bytesExpected: Int64
        public var bytesPerSecond: Double
        public var error: String?
        /// What an unfinished transfer is doing, for the ones that have more than one thing
        /// to do: a model the Mac keeps for the phone is fetched, then checked, and follows
        /// the library when it moves (`ControlAPI.phoneModelStages`). Absent on the frame
        /// that says it is done — and on the Mac's own model downloads, which have no stages.
        public var stage: String?

        public init(
            id: String, name: String, fraction: Double, bytesReceived: Int64,
            bytesExpected: Int64, bytesPerSecond: Double, error: String? = nil,
            stage: String? = nil
        ) {
            self.id = id
            self.name = name
            self.fraction = fraction
            self.bytesReceived = bytesReceived
            self.bytesExpected = bytesExpected
            self.bytesPerSecond = bytesPerSecond
            self.error = error
            self.stage = stage
        }
    }

    /// A render in flight — a video clip or an image — as a phone needs to see it.
    public struct JobEvent: Codable, Sendable, Equatable {
        public var id: String
        public var kind: String
        public var status: String
        public var title: String
        public var fraction: Double?
        /// What the renderer is doing right now — "Rendering", "video-denoise", "Texture
        /// bake". Only ever set for the job the Mac is actually following; a clip waiting
        /// its turn has a status and no stage.
        public var stage: String?
        /// Why it failed, in the words the queue would show. Present only on a terminal
        /// failure (or a confirmed cancel, with the node's words for it), and the reason a
        /// phone no longer has to poll `GET /video/queue` alongside the stream to have
        /// something true to say when a render breaks.
        public var reason: String?
        /// The finished file, fetchable at `GET /media/{mediaID}`. Set on the frame that
        /// says the job is done, which is the frame a notification is written from.
        public var mediaID: String?

        public init(
            id: String, kind: String, status: String, title: String, fraction: Double? = nil,
            stage: String? = nil, reason: String? = nil, mediaID: String? = nil
        ) {
            self.id = id
            self.kind = kind
            self.status = status
            self.title = title
            self.fraction = fraction
            self.stage = stage
            self.reason = reason
            self.mediaID = mediaID
        }
    }

    /// Proof of life on an otherwise silent stream.
    public struct HeartbeatEvent: Codable, Sendable, Equatable {
        public var at: String

        public init(at: String) { self.at = at }
    }

    /// The `resync` frame: this stream fell behind and frames were dropped to catch it up.
    ///
    /// A subscriber that reads slower than the Mac writes keeps the newest frames and loses
    /// the oldest — a phone on a bad link wants now, not a queue of every percentage point
    /// it missed. That trade is only honest if the phone is *told*, so this frame arrives
    /// **exactly where the gap is**: after the last frame read before it and before
    /// anything newer, one per gap. What to do about it is the same for every kind of
    /// frame: fetch what you show again — `GET /status`, `GET /video/queue`, and each agent
    /// session with the `since`/`epoch` from the last frame you read before this one. That
    /// cursor sits just before the gap, so the answer holds exactly what was dropped.
    public struct ResyncEvent: Codable, Sendable, Equatable {
        /// How many frames were dropped since the last `resync` this stream was sent.
        public var dropped: Int

        public init(dropped: Int) { self.dropped = dropped }
    }

    // MARK: - Conversations

    public struct ConversationSummary: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var title: String
        public var updatedAt: String
        public var messageCount: Int

        public init(id: String, title: String, updatedAt: String, messageCount: Int) {
            self.id = id
            self.title = title
            self.updatedAt = updatedAt
            self.messageCount = messageCount
        }
    }

    public struct ConversationDetail: Codable, Sendable, Equatable, Identifiable {
        /// Images are deliberately absent. A transcript with a few photographs in it is
        /// megabytes of base64 that a phone has already got, or never wanted.
        public struct Message: Codable, Sendable, Equatable {
            public var role: String
            public var content: String
            public var createdAt: String
            /// Stable within this Mac's transcript, and what a `verdict` event on `/events`
            /// points at. Absent on a transcript written by a build before verification.
            public var id: String?
            /// What Jev made of this message, when it was verified. It is kept on the
            /// message rather than only sent down the stream because the stream closes at
            /// `finished` and a verdict may land after it — a phone that reconnects, or
            /// opens the thread tomorrow, reads it here.
            public var verification: ChatVerdict?

            public init(
                role: String, content: String, createdAt: String, id: String? = nil,
                verification: ChatVerdict? = nil
            ) {
                self.role = role
                self.content = content
                self.createdAt = createdAt
                self.id = id
                self.verification = verification
            }
        }

        public var id: String
        public var title: String
        public var updatedAt: String
        /// True while an answer is still being written into this conversation, here or on
        /// the Mac. Sending into it would poison the prompt, so the server answers 409.
        public var isGenerating: Bool
        public var messages: [Message]

        public init(
            id: String, title: String, updatedAt: String,
            isGenerating: Bool = false, messages: [Message]
        ) {
            self.id = id
            self.title = title
            self.updatedAt = updatedAt
            self.isGenerating = isGenerating
            self.messages = messages
        }
    }

    public struct NewConversationRequest: Codable, Sendable, Equatable {
        public var title: String?

        public init(title: String? = nil) { self.title = title }
    }

    /// A message sent from a phone. Answered as a stream, and both halves are written into
    /// the Mac's own history, so the exchange is on screen there too.
    public struct NewMessageRequest: Codable, Sendable, Equatable {
        public var content: String
        /// Base64 `data:` URLs, for vision models. Accepted, never returned.
        public var images: [String]
        public var temperature: Double?
        public var maxTokens: Int?

        public init(
            content: String, images: [String] = [],
            temperature: Double? = nil, maxTokens: Int? = nil
        ) {
            self.content = content
            self.images = images
            self.temperature = temperature
            self.maxTokens = maxTokens
        }

        /// Everything but `content` is optional on the wire. A phone sending plain text
        /// should not have to spell out that it attached no photographs.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.content = try container.decode(String.self, forKey: .content)
            self.images = try container.decodeIfPresent([String].self, forKey: .images) ?? []
            self.temperature = try container.decodeIfPresent(Double.self, forKey: .temperature)
            self.maxTokens = try container.decodeIfPresent(Int.self, forKey: .maxTokens)
        }
    }
}

/// Raised by hosts that have no conversation store or no model to stream from, so the
/// server can answer with a sentence and a status instead of dropping the connection.
public enum BuddyHostError: Error, LocalizedError, Equatable {
    case noSuchConversation(String)
    case conversationBusy(String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .noSuchConversation(let id): "No conversation with id \(id)."
        case .conversationBusy:
            "That conversation is still being answered. Wait for it to finish, or start "
                + "another one."
        case .unsupported(let what): "\(what) is not available on this host."
        }
    }

    /// What the server answers. A phone can act on 404 and 409; it cannot act on 400.
    public var status: Int {
        switch self {
        case .noSuchConversation: 404
        case .conversationBusy: 409
        case .unsupported: 501
        }
    }
}

/// What a device may send, and how much of it.
///
/// A paired phone is trusted, not unlimited: these caps are what stop a bug on the other
/// side — or a lost handset — from turning a tailnet into a memory exhaustion tool.
public enum BuddyLimits {
    /// A phone sends prompts and photographs, not model weights.
    public static let requestBodyBytes = 4 * 1_048_576
    /// What an unauthenticated tailnet caller may send — which is `/buddy/pair` and
    /// nothing else. Its body is a code, a name and a platform.
    public static let unauthenticatedBodyBytes = 65_536
    public static let imagesPerMessage = 8
    /// A base64 `data:` URL, so roughly 1.5 MB of actual image.
    public static let imageCharacters = 2_000_000

    /// Nil when the attachments are within reach, a sentence when they are not.
    public static func refusal(forImages images: [String]) -> String? {
        if images.count > imagesPerMessage {
            return "At most \(imagesPerMessage) images in one message."
        }
        if images.contains(where: { $0.count > imageCharacters }) {
            return "One of those images is too large. The limit is about 1.5 MB each."
        }
        return nil
    }
}
