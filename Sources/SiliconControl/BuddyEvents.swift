import Foundation

/// One frame of `GET /events`. The case name is the SSE event name, so a client switches on
/// the same word the server wrote.
public enum BuddyEvent: Sendable {
    case status(ControlAPI.Status)
    case download(ControlAPI.DownloadEvent)
    case job(ControlAPI.JobEvent)
    case heartbeat(ControlAPI.HeartbeatEvent)
    /// What Jev made of a finished answer, once it knows.
    ///
    /// Here as well as on the chat stream because the stream closes at `finished` and the
    /// verdict often lands after it. This frame carries the conversation and message ids,
    /// so a phone can attach it to the bubble it is about — or ignore it and read the same
    /// verdict from `GET /conversations/{id}` later.
    case verdict(ControlAPI.ChatVerdict)
    /// What one of the Chat tab's agent engines just did: a row appeared, a turn started,
    /// a call is waiting, somebody answered one. See `ControlAPI.AgentEvent` for which
    /// fields each kind fills in.
    ///
    /// Posted from the Mac's own state rather than from the routes, which is what makes
    /// the owner's typing and the owner's approvals show up on the phone exactly as a
    /// phone's do. Delivered only to an audience that may see agent sessions — see
    /// `BuddyEventHub.Audience`.
    case agent(ControlAPI.AgentEvent)
    /// This subscriber fell behind and lost frames. See `ControlAPI.ResyncEvent`.
    case resync(ControlAPI.ResyncEvent)

    public var name: String {
        switch self {
        case .status: "status"
        case .download: "download"
        case .job: "job"
        case .heartbeat: "heartbeat"
        case .verdict: "verdict"
        case .agent: "agent"
        case .resync: "resync"
        }
    }

    /// Compact on purpose: an SSE frame ends at a blank line, so a pretty-printed payload
    /// would need escaping that no client should have to undo.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        switch self {
        case .status(let value): return try encoder.encode(value)
        case .download(let value): return try encoder.encode(value)
        case .job(let value): return try encoder.encode(value)
        case .heartbeat(let value): return try encoder.encode(value)
        case .verdict(let value): return try encoder.encode(value)
        case .agent(let value): return try encoder.encode(value)
        case .resync(let value): return try encoder.encode(value)
        }
    }

    /// A frame as it goes down the wire: its event name and its bytes, encoded once.
    ///
    /// The hub encodes when it posts rather than each writer when it sends, so three phones
    /// watching a transcript cost one encoding of each row rather than three.
    public struct Frame: Sendable, Equatable {
        public var name: String
        public var data: Data

        public init(name: String, data: Data) {
            self.name = name
            self.data = data
        }
    }

    /// Whether this is one of the frames that describe an agent session — and so one only
    /// an audience that may drive those sessions is sent.
    var describesAgentSession: Bool {
        if case .agent = self { return true }
        return false
    }

    /// Whether this is the Mac fetching a model for the phone. Those routes are full
    /// scope only, so what they would answer is too: a chat-only device and the swarm are
    /// not told what this Mac is downloading for the owner's phone.
    var describesPhoneModel: Bool {
        guard case .download(let download) = self else { return false }
        return download.id.hasPrefix(ControlAPI.PhoneModel.downloadEventPrefix)
    }

    /// Sent only to this Mac's own token and full-control devices.
    var needsFullScope: Bool { describesAgentSession || describesPhoneModel }

    /// Queue entries, conversation verdicts, and the owner's model download activity
    /// belong to their devices. A shared peer bearer cannot use the corresponding owner
    /// controls, so the event stream must not recover those details either.
    var hiddenFromPeers: Bool {
        switch self {
        case .job, .verdict, .download: true
        default: false
        }
    }

    /// The same frame with what only a full-control audience may see taken out, or nil when
    /// there is nothing to take out — which is every frame but a failed load's `status`.
    var withoutPrivilegedDetail: BuddyEvent? {
        guard case .status(let status) = self, status.failure?.detail != nil else { return nil }
        return .status(status.withoutPrivilegedDetail)
    }
}

/// Where the app posts what changed, and where every subscribed device reads it.
///
/// A broadcaster rather than a callback on `ControlHost`, because nothing in the app should
/// have to know whether a phone happens to be listening. When nobody is subscribed, posting
/// is a no-op that costs an actor hop.
public actor BuddyEventHub {

    public static let shared = BuddyEventHub()

    /// Who a subscription is for, which decides what it is sent.
    ///
    /// A security boundary rather than bookkeeping. `/events` is open to every credential
    /// this server honours, but owner activity frames do not go to peers. An agent
    /// session does not go to peers or chat-only devices either: a transcript carries the
    /// commands an agent ran and what they printed, and an approval names what it is about
    /// to do. A device paired for chat was deliberately given less than that, and the
    /// swarm secret is a node's credential, not a person's; neither may call the agent
    /// routes, and neither is sent what those routes would have answered.
    public enum Audience: Sendable, Equatable {
        /// This Mac's own control token, on its own loopback listener.
        case thisMac
        /// A paired phone or tablet, at the scope it was paired for.
        case device(id: String, scope: BuddyScope)
        /// The swarm secret.
        case peer

        /// Whether this audience has the Mac's full confidence: its own token, or a device
        /// paired for full control. A phone paired for chat, and a peer node, have less.
        public var hasFullControl: Bool {
            switch self {
            case .thisMac, .device(_, .full): true
            case .device(_, .chat), .peer: false
            }
        }

        /// Whether `agent` frames may be sent to this audience — the same rule the agent
        /// routes enforce, so the side channel cannot tell anyone more than the front door.
        public var seesAgentSessions: Bool { hasFullControl }

        /// Whether a frame may carry a runtime's own log. Same rule, different question:
        /// `GET /status` withholds `failure.detail` from these two, and a `status` frame is
        /// the same payload on a socket they are already holding.
        public var seesRuntimeLogs: Bool { hasFullControl }
    }

    private var listeners: [UUID: AsyncStream<BuddyEvent.Frame>.Continuation] = [:]
    private var audiences: [UUID: Audience] = [:]
    /// Frames dropped per subscriber since its reader last took the count — that is, since
    /// the last `resync` it was actually sent. See `takeDropped`.
    private var dropped: [UUID: Int] = [:]
    /// Agent subscribers that have not been sent their opening frames yet. The agent
    /// watcher takes them on its next reading, so what a phone is opened with and what
    /// changes after it come from one reading, with nothing able to fall between the two.
    private var awaitingOpening: Set<UUID> = []
    /// When each paired device last used an agent route. See `agentWatcherCount`.
    private var agentActivity: [String: Date] = [:]

    /// How many frames a subscriber may fall behind before the oldest are dropped.
    public static let bufferedFrames = 32

    public init() {}

    public var subscriberCount: Int { listeners.count }

    /// How many subscribers may be sent agent frames. The agent watcher runs only while
    /// this is above zero: sampling transcripts for an audience that may not see them
    /// would spend the main actor on frames that are thrown away.
    public var agentAudienceCount: Int {
        audiences.values.count(where: \.seesAgentSessions)
    }

    public func subscribe(
        as audience: Audience
    ) -> (id: UUID, stream: AsyncStream<BuddyEvent.Frame>) {
        let id = UUID()
        // Buffering the newest few: a phone on a slow link should get the current state,
        // not a queue of every percentage point it missed. A drop is counted, and the
        // reader announces it — see `takeDropped`.
        let stream = AsyncStream<BuddyEvent.Frame>(
            bufferingPolicy: .bufferingNewest(Self.bufferedFrames)
        ) { continuation in
            listeners[id] = continuation
        }
        audiences[id] = audience
        if audience.seesAgentSessions { awaitingOpening.insert(id) }
        return (id, stream)
    }

    /// Ends one subscription. Also what a cancelled `/events` task calls, because finishing
    /// the continuation is the only thing that breaks the reader out of its `for await`.
    public func cancel(_ id: UUID) {
        audiences.removeValue(forKey: id)
        dropped.removeValue(forKey: id)
        awaitingOpening.remove(id)
        listeners.removeValue(forKey: id)?.finish()
    }

    /// To every subscriber allowed to see it.
    public func post(_ event: BuddyEvent) {
        deliver([event], to: { _ in true })
    }

    /// In order, to every subscriber allowed to see them except `skipped`.
    public func post(_ events: [BuddyEvent], excluding skipped: Set<UUID>) {
        deliver(events, to: { !skipped.contains($0) })
    }

    /// In order, to exactly these subscribers, where they are allowed to see them.
    public func post(_ events: [BuddyEvent], to recipients: Set<UUID>) {
        deliver(events, to: { recipients.contains($0) })
    }

    /// The agent subscribers still owed their opening frames, handed over once.
    public func takeNewAgentSubscribers() -> Set<UUID> {
        defer { awaitingOpening.removeAll() }
        return awaitingOpening
    }

    private func deliver(_ events: [BuddyEvent], to chosen: (UUID) -> Bool) {
        guard !listeners.isEmpty else { return }
        for event in events {
            // Encoded at most once each, and only if somebody is going to receive it. Two,
            // because one frame can have two legitimate shapes: a `status` carrying a failed
            // load carries the runtime's log with it, and the audiences that are refused
            // that log on `GET /status` must not be handed it here instead.
            var frame: BuddyEvent.Frame?
            var narrowedFrame: BuddyEvent.Frame?
            let narrowed = event.withoutPrivilegedDetail
            for (id, listener) in listeners where chosen(id) {
                // Role filtering also applies to this side channel: peers cannot see
                // owner activity by holding the event stream.
                let audience = audiences[id]
                if event.needsFullScope, audience?.seesAgentSessions != true { continue }
                if event.hiddenFromPeers, audience == .peer { continue }

                let full = audience?.seesRuntimeLogs ?? false
                if let narrowed, !full {
                    if narrowedFrame == nil {
                        guard let data = try? narrowed.encoded() else { break }
                        narrowedFrame = BuddyEvent.Frame(name: narrowed.name, data: data)
                    }
                    if case .dropped = listener.yield(narrowedFrame!) {
                        dropped[id, default: 0] += 1
                    }
                    continue
                }
                if frame == nil {
                    guard let data = try? event.encoded() else { break }
                    frame = BuddyEvent.Frame(name: event.name, data: data)
                }
                if case .dropped = listener.yield(frame!) { dropped[id, default: 0] += 1 }
            }
        }
    }

    /// How many frames this subscriber has lost since the count was last taken, and
    /// zero from now on.
    ///
    /// Taken by the subscriber's own reader, just before it sends the frame it has just
    /// taken off the stream — and never announced from here. The buffer drops its
    /// *oldest* frames, so everything lost is older than the frame about to go out: a
    /// `resync` sent in front of that frame lands exactly where the gap is, before
    /// anything newer, and the cursor the phone holds at that moment is the right one to
    /// fetch from. Appended here instead, a `resync` would queue behind the survivors;
    /// the phone would read past the gap first and then fetch from beyond it. And a
    /// stalled reader would fill its buffer with announcements, each pushing out a real
    /// frame to make room.
    public func takeDropped(_ id: UUID) -> Int {
        dropped.removeValue(forKey: id) ?? 0
    }

    // MARK: - Who is watching the agents

    /// A paired, full-control device just used an agent route.
    public func noteAgentActivity(deviceID: String, at moment: Date = Date()) {
        agentActivity[deviceID] = moment
    }

    /// How many paired devices with full control are following the agent sessions: every
    /// one with `/events` open, and every one that used an agent route within `window`.
    ///
    /// The Chat tab's "Silicon Buddy is watching" badge, and nothing else. Both halves,
    /// because a phone can follow a session without holding the stream — polling
    /// `GET /agent/sessions/{engine}`, or sending and walking away — and a badge that went
    /// dark the moment the stream dropped would say nobody was there while a phone had just
    /// answered an approval. Full scope only, because that is exactly the set of devices
    /// that can reach these sessions; this Mac's own token and the swarm secret are not
    /// devices at all.
    public func agentWatcherCount(
        within window: Duration = .seconds(180), now: Date = Date()
    ) -> Int {
        let horizon = now.addingTimeInterval(-Self.seconds(window))
        agentActivity = agentActivity.filter { $0.value >= horizon }
        var devices = Set(agentActivity.keys)
        for audience in audiences.values {
            if case .device(let id, .full) = audience { devices.insert(id) }
        }
        return devices.count
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let (seconds, attoseconds) = duration.components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
