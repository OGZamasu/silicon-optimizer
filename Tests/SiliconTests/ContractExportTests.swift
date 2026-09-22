import Foundation
import Testing
@testable import SiliconCatalog
@testable import SiliconControl
import SiliconCore
import SiliconRuntime

/// The machine-readable contract the Silicon Buddy apps are generated from.
///
/// Every example here is built from the real `ControlAPI` type, never from a hand-written
/// dictionary — which is the whole point. A field renamed on this side changes the fixtures,
/// and the generated iOS and Android clients change with them, instead of the phone quietly
/// dropping a key three weeks later.
///
/// Run with `SILICON_EXPORT_CONTRACT=<dir> swift test --filter ContractExportTests` to write
/// the fixtures into the silicon-buddy repository. Without that variable this is a plain
/// round-trip test and touches no files at all.
@Suite("Silicon Buddy contract export")
struct ContractExportTests {

    @Test func everyWireTypeSurvivesARoundTrip() throws {
        for route in Self.routes {
            for (label, example) in route.examples {
                let encoded = try example.encode()
                let again = try example.roundTrip(encoded)
                #expect(
                    encoded == again,
                    "\(route.method) \(route.path) — \(label) does not survive a round trip"
                )
            }
        }
    }

    /// The routes the companion apps are generated from — which is not quite every route
    /// the server answers, and the difference is listed rather than left implicit.
    ///
    /// This is two literals compared, so it catches a route added to `ControlServer` and
    /// forgotten here only when someone updates one of them. It is a checklist with teeth,
    /// not a derivation: the server has no enumerable route table to derive from, and
    /// inventing one so a test could read it would be a worse trade than this comment.
    @Test func theRouteTableIsTheOneTheAppsAreGeneratedFrom() {
        let names = Self.routes.map { "\($0.method) \($0.path)" }
        #expect(Set(names).count == names.count)
        #expect(Set(names) == [
            "POST /buddy/pair", "GET /buddy/devices", "DELETE /buddy/devices/{id}",
            "POST /buddy/invitations", "DELETE /buddy/invitations",
            "POST /chat/stream", "GET /events",
            "GET /conversations", "POST /conversations", "GET /conversations/{id}",
            "POST /conversations/{id}/messages",
            "GET /health", "GET /profile", "GET /metrics", "GET /status", "GET /installed",
            "GET /catalog", "GET /recommend", "POST /recommend",
            "POST /plan", "POST /install", "POST /load",
            "POST /unload", "POST /chat", "POST /decide", "POST /v1/systemone",
            "GET /jev", "POST /jev", "GET /jev/guardrails/recent",
            "GET /jev/calibration", "POST /jev/calibrate",
            "POST /benchmark", "GET /swarm", "GET /v1/node",
            "GET /image/models", "POST /image/plan", "POST /image/generate",
            "GET /mesh/models", "POST /mesh/plan", "POST /mesh/generate",
            "GET /video/models", "GET /video/queue", "POST /video/queue",
            "POST /video/queue/control", "POST /video/generate",
            "GET /media/{id}", "POST /uploads", "GET /swarm/peers/{name}/status",
            "GET /agent/sessions", "GET /agent/sessions/{engine}",
            "DELETE /agent/sessions/{engine}",
            "POST /agent/sessions/{engine}/start", "POST /agent/sessions/{engine}/new",
            "POST /agent/sessions/{engine}/messages",
            "POST /agent/sessions/{engine}/interrupt",
            "POST /agent/sessions/{engine}/approvals/{id}",
            "GET /ondevice/models", "POST /ondevice/models/{id}/prepare",
            "GET /ondevice/models/{id}/file", "DELETE /ondevice/models/{id}",
        ])
        // Deliberately absent, and a phone must never be told to use them: the overlay is
        // an OBS browser source, which cannot set headers and so carries its token in the
        // URL. It is read-only and serves the character on screen.
        #expect(Self.excludedRoutes == [
            "GET /overlay", "GET /overlay/state", "GET /overlay/portrait",
            "GET /overlay/portrait-eyes", "GET /overlay/portrait-open",
        ])
        #expect(Set(names).isDisjoint(with: Self.excludedRoutes))
        #expect(Self.routes.filter(\.isStream).count == 3)
        #expect(Self.routes.allSatisfy { !$0.summary.isEmpty })
        // Every route says what it answers when it says no, so a generated client has the
        // failure shapes as well as the happy one.
        // Every route says how it refuses — except the one that cannot. /health exists to
        // separate "the app is not running" from "bad token", so it has no failure mode.
        #expect(Self.routes.allSatisfy { $0.path == "/health" || !$0.errors.isEmpty })
        #expect(Self.routes.first { $0.path == "/health" }?.errors.isEmpty == true)

        func errors(_ method: String, _ path: String) -> [Int: String] {
            Self.routes.first { $0.method == method && $0.path == path }?.errors ?? [:]
        }
        // Authenticated routes all carry the two framing refusals and a 401.
        for route in Self.routes where route.auth != "none" {
            #expect(route.errors[401] != nil && route.errors[411] != nil
                && route.errors[413] != nil, "\(route.method) \(route.path)")
            // And a route with a body can always be sent one it cannot read.
            #expect((route.request != nil) == (route.errors[400] != nil)
                || route.errors[400] != nil, "\(route.method) \(route.path)")
        }
        #expect(errors("GET", "/recommend")[404] != nil)
        // The free verb says where the paid one is, in the server's own words.
        #expect(errors("GET", "/recommend")[400] == ControlServer.taskBelongsInAPost)
        #expect(errors("POST", "/recommend")[403] == ControlServer.chatOnlyRefusal)
        #expect(errors("POST", "/video/generate")[429]?.contains("/video/queue") == true)
        #expect(errors("POST", "/chat/stream")[429]?.contains("Close one") == true)
        #expect(errors("POST", "/conversations/{id}/messages")[409] != nil)
        #expect(errors("POST", "/conversations/{id}/messages")[429] != nil)
        // The control-only routes refuse with their own sentence, not each other's.
        #expect(errors("GET", "/buddy/devices")[403]?.contains("list") == true)
        #expect(errors("DELETE", "/buddy/devices/{id}")[403]?.contains("revoke") == true)
        #expect(errors("POST", "/buddy/invitations")[403]?.contains("mint") == true)
        #expect(errors("DELETE", "/buddy/invitations")[403]?.contains("cancel") == true)
        // The two the phone side has to be able to act on: a code that could not be minted
        // because nothing is listening, and a scope this server does not have.
        #expect(errors("POST", "/buddy/invitations")[409] == ControlServer.buddyListenerDown)
        #expect(errors("POST", "/buddy/invitations")[400] == ControlServer.unknownScopeRefusal)
        // Minting admits the next device, so it is the Mac's own business — never a
        // paired phone's, at either scope.
        for invitation in Self.routes.filter({ $0.path == "/buddy/invitations" }) {
            #expect(invitation.auth == "control")
            #expect(invitation.scopes == ["full"])
        }
        // And the code in the fixture is a placeholder, so nothing that reads these files
        // is ever reading a credential.
        #expect(Self.exampleInvitation.code == "000000")
        #expect(errors("POST", "/jev")[403] == ControlServer.jevWriteRefusal)
        #expect(errors("POST", "/jev/calibrate")[403] == ControlServer.jevCalibrateRefusal)
        // Two different refusals for two different things, so a client can tell "you may not
        // change what this Mac spends" from "you may not start it spending".
        #expect(ControlServer.jevCalibrateRefusal != ControlServer.jevWriteRefusal)
        #expect(errors("GET", "/jev/calibration")[404] == ControlServer.noCalibrationYet)
        // A generated client is taught the cascade shape by the route that produces it: two
        // lanes in one answer, and the map that says which answered what.
        let decide = Self.routes.first { $0.method == "POST" && $0.path == "/decide" }
        let decideBody = String(
            decoding: (try? decide?.response?.encode()) ?? Data(), as: UTF8.self
        )
        #expect(decideBody.contains("\"provider\":\"local+typesafe\""))
        #expect(decideBody.contains("\"sources\""))
        #expect(decideBody.contains("\"team\":\"typesafe\""))
        #expect(decideBody.contains("\"refund\":\"local\""))
        // And the single-lane shape is still in the fixtures, on TypeSafe's own path.
        let systemOne = Self.routes.first { $0.path == "/v1/systemone" }
        let systemOneBody = String(
            decoding: (try? systemOne?.response?.encode()) ?? Data(), as: UTF8.self
        )
        #expect(!systemOneBody.contains("sources"))
        // A full-control phone may read what Jev costs; only the Mac may change it.
        #expect(Self.routes.first { $0.method == "GET" && $0.path == "/jev" }?.auth == "device")
        #expect(Self.routes.first { $0.method == "POST" && $0.path == "/jev" }?.auth == "control")
        // The calibration pair follows the same split: reading is free, running is not.
        #expect(Self.routes.first {
            $0.method == "GET" && $0.path == "/jev/calibration"
        }?.auth == "device")
        #expect(Self.routes.first {
            $0.method == "POST" && $0.path == "/jev/calibrate"
        }?.auth == "control")
        // And the key is not in the shape at all — the one thing this contract must never
        // teach a generated client to expect.
        let jevFixture = String(
            decoding: (try? Self.encoder.encode(Self.exampleJevStatus)) ?? Data(), as: UTF8.self
        )
        #expect(jevFixture.contains("keySet"))
        #expect(!jevFixture.lowercased().contains("apikey"))
        #expect(!jevFixture.lowercased().contains("\"key\""))
        // And the chat-only refusal is the server's own string, not a copy of it.
        #expect(errors("POST", "/load")[403] == ControlServer.chatOnlyRefusal)
        // A route a chat-only device may call must not advertise the refusal it would get
        // if it could not, and one it may not must.
        let chatRoutes = Set(
            Self.routes.filter { $0.scopes.contains("chat") }.map { "\($0.method) \($0.path)" }
        )
        #expect(chatRoutes.contains("GET /recommend"))
        // Reading and advising is free; ranking against a job asks Jev and costs money, so
        // a paired phone may do the first and not the second.
        #expect(!chatRoutes.contains("POST /recommend"))
        #expect(chatRoutes.contains("GET /v1/node"))
        #expect(chatRoutes.contains("POST /plan"))
        #expect(!chatRoutes.contains("POST /load"))
        #expect(!chatRoutes.contains("POST /benchmark"))
        // One route breaks this, and it is written out rather than left to be noticed:
        // `GET /media/{id}` is reachable at either scope, but *what* a chat-only device may
        // fetch through it depends on the id — a poster yes, the render itself no. So it is
        // the only route that is both open to chat and advertises a 403.
        #expect(Self.routes.allSatisfy { route in
            route.path == "/media/{id}"
                || route.auth != "device"
                || route.scopes.contains("chat") == (route.errors[403] == nil)
        })
        #expect(errors("GET", "/media/{id}")[403] == ControlServer.fullResultsNeedFullControl)
        // Its own sentence: being told "pair again to use this" about a route the device is
        // using right now would be wrong.
        #expect(ControlServer.fullResultsNeedFullControl != ControlServer.chatOnlyRefusal)
        // File names carry no spaces and no braces, so a generator can use them as symbols.
        #expect(Self.routes.allSatisfy {
            !$0.fileName.contains(" ") && !$0.fileName.contains("{")
        })

        // MARK: The media routes

        // Fetching a result is as open as reading the queue that mentions it; sending one,
        // and asking a node about itself, are not.
        #expect(chatRoutes.contains("GET /media/{id}"))
        #expect(!chatRoutes.contains("POST /uploads"))
        #expect(!chatRoutes.contains("GET /swarm/peers/{name}/status"))
        #expect(errors("GET", "/media/{id}")[404] == ControlServer.noSuchMedia)
        #expect(errors("POST", "/uploads")[415] == ControlServer.unreadableUpload)
        // The one route whose 413 is not the shared one: the whole point of it is a
        // ceiling six times the ordinary device body.
        #expect(errors("POST", "/uploads")[413]?.contains("\(BuddyUploads.maximumBytes)") == true)
        #expect(errors("POST", "/uploads")[413] != errors("POST", "/load")[413])
        #expect(BuddyUploads.maximumBytes > BuddyLimits.requestBodyBytes)
        // A render told to start from an id that has been swept says so, rather than
        // reading as "you forgot to send a picture".
        #expect(errors("POST", "/video/generate")[404] == ControlServer.expiredSubject)
        // What a device is told when the bytes could not be written: one sentence, and
        // nothing about this Mac's disk.
        #expect(errors("POST", "/uploads")[500] == ControlServer.uploadNotSaved)
        #expect(!ControlServer.uploadNotSaved.contains("/"))

        // A device is never handed a path to send back. Every route that takes a subject
        // image advertises both ids, and the fixture shows them.
        func requestJSON(_ method: String, _ path: String) -> [String: Any] {
            let route = Self.routes.first { $0.method == method && $0.path == path }
            let data = (try? route?.request?.encode()) ?? Data()
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        }
        #expect(requestJSON("POST", "/mesh/generate")["uploadID"] != nil)
        #expect(requestJSON("POST", "/video/generate")["uploadID"] != nil)
        // …and a result says how to fetch it, in the relative form a phone appends to
        // whatever address it dialled.
        func responseJSON(_ method: String, _ path: String) -> [String: Any] {
            let route = Self.routes.first { $0.method == method && $0.path == path }
            let data = (try? route?.response?.encode()) ?? Data()
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        }
        for (method, path) in [
            ("POST", "/image/generate"), ("POST", "/mesh/generate"),
            ("POST", "/video/generate"), ("POST", "/uploads"),
        ] {
            let body = responseJSON(method, path)
            let id = body["mediaID"] as? String
            #expect(id?.isEmpty == false, "\(method) \(path) has no mediaID")
            #expect(body["mediaURL"] as? String == "/media/\(id ?? "")")
        }
        // And nothing in the export is a real id or a real credential.
        let exported = Self.routes.compactMap { route -> String? in
            (try? route.fixture()).map { String(decoding: $0, as: UTF8.self) }
        }.joined()
        #expect(!exported.lowercased().contains("swarm_token"))
        #expect(!exported.contains("/Users/you/Movies/Silicon/Lisbon/lisbon-0002.mp4/"))
    }

    /// The queue's verbs, and the two constants the phone was guessing.
    @Test func theQueueContractNamesEveryVerbAndItsFields() throws {
        let control = try #require(
            Self.routes.first { $0.method == "POST" && $0.path == "/video/queue/control" }
        )
        // Every verb the Mac accepts has an example, and the refusal names the same six.
        let actions = control.requests.map(\.0)
        #expect(actions == [
            "pause", "resume", "retry", "remove", "stop_following", "clear_finished",
        ])
        for action in actions {
            #expect(ControlServer.unknownQueueAction.contains(action), "\(action)")
        }
        // Deliberately absent: a clip already handed to a node keeps rendering there.
        #expect(!ControlServer.unknownQueueAction.contains("cancel"))

        var bodies: [String: [String: Any]] = [:]
        for (action, example) in control.requests {
            bodies[action] = try JSONSerialization.jsonObject(with: try example.encode())
                as? [String: Any] ?? [:]
        }
        // Which verbs need an id is the thing one example cannot teach.
        for action in ["retry", "remove", "stop_following"] {
            #expect(bodies[action]?["id"] as? String != nil, "\(action) needs an id")
        }
        for action in ["pause", "resume", "clear_finished"] {
            #expect(bodies[action]?["id"] == nil, "\(action) takes no id")
        }
        // And `confirmNewRender` belongs to retry alone.
        #expect(bodies["retry"]?["confirmNewRender"] as? Bool == true)
        for action in actions where action != "retry" {
            #expect(bodies[action]?["confirmNewRender"] == nil, "\(action)")
        }
        #expect(control.errors[400] == ControlServer.unknownQueueAction)
    }

    /// The optional fields a phone reads off a queue item and off a lane — populated in
    /// the fixture, because a client generated from three nulls hard-codes the Mac's
    /// defaults and then disagrees with it.
    @Test func theQueueAndLaneFixturesCarryTheirOptionalFields() throws {
        let queue = try #require(Self.routes.first { $0.path == "/video/queue" && $0.method == "GET" })
        let view = try JSONSerialization.jsonObject(
            with: try #require(queue.response).encode()
        ) as! [String: Any]
        #expect(view["message"] as? String != nil)
        let items = try #require(view["items"] as? [[String: Any]])
        #expect(items.count >= 3)
        // A finished clip: a file, and the two ids that make it fetchable.
        let done = try #require(items.first { $0["status"] as? String == "completed" })
        #expect(done["file"] as? String != nil)
        #expect(done["mediaID"] as? String == Self.exampleClipMediaID)
        #expect(done["thumbnailMediaID"] as? String == Self.examplePosterMediaID)
        // A failed one: the sentence the Mac would show, on the item rather than only in
        // the queue's own message.
        let failed = try #require(items.first { $0["status"] as? String == "failed" })
        #expect((failed["error"] as? String)?.isEmpty == false)
        #expect(failed["file"] == nil || failed["file"] is NSNull)
        // And a running one still shows the null shape, so both are in the export.
        let running = try #require(items.first { $0["status"] as? String == "running" })
        #expect(running["file"] == nil || running["file"] is NSNull)
        #expect(running["mediaID"] == nil || running["mediaID"] is NSNull)

        let lanes = try #require(Self.routes.first { $0.path == "/video/models" })
        let laneBody = try #require(lanes.response).encode()
        let model = try #require(
            (try JSONSerialization.jsonObject(with: laneBody) as? [[String: Any]])?.first
        )
        #expect((model["supportedParameters"] as? [String])?.isEmpty == false)
        #expect((model["supportedResolutions"] as? [String])?.isEmpty == false)
        #expect(model["supportsNegativePrompt"] as? Bool == true)
        #expect((model["supportedSeconds"] as? [Int])?.isEmpty == false)
    }

    /// `job` is one event with three lives. All three are in the export, because the two
    /// the running frame cannot show are the ones a notification is written from.
    @Test func theJobEventCarriesItsStageReasonAndResult() throws {
        let events = try #require(Self.routes.first { $0.path == "/events" })
        func frame(_ example: Example) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: try example.encode()) as? [String: Any] ?? [:]
        }
        let running = try frame(try #require(events.events.first { $0.0 == "job" }).1)
        #expect((running["stage"] as? String)?.isEmpty == false)
        #expect(running["reason"] == nil || running["reason"] is NSNull)
        #expect(running["mediaID"] == nil || running["mediaID"] is NSNull)

        let finished = try frame(
            try #require(events.eventVariants.first { $0.0 == "job" && $0.1 == "finished" }).2
        )
        #expect(finished["mediaID"] as? String == Self.exampleClipMediaID)
        #expect(finished["reason"] == nil || finished["reason"] is NSNull)

        let failed = try frame(
            try #require(events.eventVariants.first { $0.0 == "job" && $0.1 == "failed" }).2
        )
        #expect((failed["reason"] as? String)?.isEmpty == false)
        #expect(failed["mediaID"] == nil || failed["mediaID"] is NSNull)
        // Every variant is of an event the route really sends.
        #expect(events.eventVariants.allSatisfy { variant in
            events.events.contains { $0.0 == variant.0 }
        })
    }

    /// The `verdict` frame, in the contract the phone apps are generated from.
    ///
    /// Both streaming chat routes carry it, both say `escalatedTo: null`, and the field
    /// names are pinned here rather than in prose: a phone reads this fixture, not the
    /// README, and a rename on this side has to change the generated client with it.
    /// The `verification` field on `POST /chat`, and what it says about the counters.
    @Test func theChatResponseCarriesItsVerdictAndZeroesTheDiscardedRun() throws {
        let route = try #require(Self.routes.first { $0.method == "POST" && $0.path == "/chat" })
        let json = try JSONSerialization.jsonObject(
            with: try #require(route.response).encode()
        ) as! [String: Any]
        let verification = try #require(json["verification"] as? [String: Any])
        #expect(verification["verdict"] as? String == "escalate")
        #expect((verification["reasons"] as? [String])?.isEmpty == false)
        // Unlike the stream, this route really did re-run it, and names who answered.
        #expect(verification["escalatedTo"] as? String == "node/studio/qwen3.8-27b")
        // …so the local run's numbers describe text that is no longer in `content`.
        #expect(json["promptTokens"] as? Int == 0)
        #expect(json["generatedTokens"] as? Int == 0)
        #expect(json["tokensPerSecond"] as? Double == 0)

        // A verdict that missed its stream reaches a phone on /events instead, and the
        // transcript keeps it either way.
        let events = try #require(Self.routes.first { $0.path == "/events" })
        let late = try JSONSerialization.jsonObject(
            with: try #require(events.events.first { $0.0 == "verdict" }).1.encode()
        ) as! [String: Any]
        #expect(late["conversationID"] as? String != nil)
        #expect(late["messageID"] as? String != nil)

        let detail = try JSONSerialization.jsonObject(
            with: try #require(
                Self.routes.first { $0.path == "/conversations/{id}" }?.response
            ).encode()
        ) as! [String: Any]
        let assistant = (detail["messages"] as! [[String: Any]]).last!
        #expect(assistant["id"] as? String == late["messageID"] as? String)
        #expect(assistant["verification"] != nil)
    }

    @Test func bothChatStreamsCarryTheVerificationVerdict() throws {
        for path in ["/chat/stream", "/conversations/{id}/messages"] {
            let route = try #require(Self.routes.first { $0.method == "POST" && $0.path == path })
            let verdict = try #require(route.events.first { $0.0 == "verdict" })
            let json = try JSONSerialization.jsonObject(
                with: try verdict.1.encode()
            ) as! [String: Any]
            #expect(json["verdict"] as? String == "escalate")
            #expect((json["reasons"] as? [String])?.isEmpty == false)
            // Never on a stream. The whole answer has already been sent.
            #expect(json["escalatedTo"] == nil || json["escalatedTo"] is NSNull)
            #expect((json["suggestion"] as? String)?.isEmpty == false)
            // And it is the last frame before `error`, so a client reading in order has the
            // metrics before it has the verdict about them.
            let names = route.events.map(\.0)
            #expect(names.firstIndex(of: "finished")! < names.firstIndex(of: "verdict")!)
        }
        // `accept` is silence, not a frame: the three verdicts the wire uses are these.
        #expect(
            Set(["accept", "annotate", "escalate"])
                .contains(Self.exampleVerdict.verdict)
        )
    }

    /// The agent sessions, in the contract the phone apps are generated from.
    ///
    /// The vocabularies matter more here than anywhere else in this file: two engines are
    /// mapped onto one set of words, and a generated client that learned a kind the server
    /// never sends — or missed one it does — would render half a transcript.
    @Test func theAgentSessionsAreOneVocabularyForTwoEngines() throws {
        let agent = Self.routes.filter { $0.path.hasPrefix("/agent/") }
        #expect(agent.count == 8)

        for route in agent {
            // A paired phone's token, never the Mac-only kind: the point is remote parity.
            #expect(route.auth == "device", "\(route.method) \(route.path)")
            // Full scope only, and the 403 in the fixture is the one a phone can actually
            // provoke — pairing for chat and then reaching for an agent.
            #expect(route.scopes == ["full"], "\(route.method) \(route.path)")
            #expect(route.errors[403] == ControlServer.chatOnlyRefusal)
            // …and the swarm's, its own sentence, on every one of them.
            #expect(
                route.errorVariants.contains {
                    $0.0 == 403 && $0.1 == "swarm" && $0.2 == ControlServer.agentsAreNotForPeers
                },
                "\(route.method) \(route.path)"
            )
            // Every variant is a status the route already lists: a variant is a second
            // sentence, never a status a client has not been told about.
            #expect(route.errorVariants.allSatisfy { route.errors[$0.0] != nil })
            // Every one of them has an engine in the path, so every one of them can be
            // asked about an engine that does not exist.
            #expect(route.errors[404] != nil || route.path == "/agent/sessions")
        }
        // The swarm's refusal is its own sentence, not a copy of the chat-only one: a peer
        // is not a device that was paired for less, it is not a device at all.
        #expect(ControlServer.agentsAreNotForPeers != ControlServer.chatOnlyRefusal)
        #expect(ControlServer.agentsAreNotForPeers.contains("swarm node"))

        func body(_ method: String, _ path: String) throws -> [String: Any] {
            let route = try #require(
                Self.routes.first { $0.method == method && $0.path == path }
            )
            return try JSONSerialization.jsonObject(
                with: try #require(route.response).encode()
            ) as? [String: Any] ?? [:]
        }

        // Both engines are listed whatever they are doing, and the stopped one carries a
        // model list anyway — a phone has to be able to pick before it starts.
        let sessions = try #require(try body("GET", "/agent/sessions")["sessions"]
            as? [[String: Any]])
        #expect(sessions.map { $0["engine"] as? String } == ControlAPI.agentEngines)
        #expect(sessions.contains { $0["state"] as? String == "stopped" })
        #expect(sessions.allSatisfy {
            ($0["modelChoices"] as? [[String: Any]])?.isEmpty == false
        })
        #expect(sessions.allSatisfy {
            ControlAPI.agentSessionStates.contains($0["state"] as? String ?? "")
        })
        // Whether anything stands between the agent and the Mac, and in which words.
        #expect(sessions.allSatisfy {
            ControlAPI.agentApprovalModes.contains($0["approvals"] as? String ?? "")
                && ControlAPI.agentSandboxes.contains($0["sandbox"] as? String ?? "")
                && ($0["epoch"] as? String)?.isEmpty == false
        })
        #expect(sessions.first { $0["engine"] as? String == "pi" }?["sandbox"] as? String
            == "none")
        // Home-relative, never an account name.
        #expect(sessions.allSatisfy { ($0["cwd"] as? String)?.hasPrefix("~/") == true })
        #expect(!sessions.contains { ($0["cwd"] as? String)?.hasPrefix("/Users/") == true })
        // …and absent altogether for Codex before a folder was chosen.
        let unplaced = try JSONSerialization.jsonObject(
            with: try Self.encoder.encode(Self.exampleUnplacedCodexSession)
        ) as? [String: Any] ?? [:]
        #expect(unplaced["cwd"] == nil || unplaced["cwd"] is NSNull)
        // `where` is what a picker on a phone shows, and the fixture proves both sides of
        // the swarm appear in it.
        let choices = try #require(sessions.first?["modelChoices"] as? [[String: Any]])
        #expect(Set(choices.compactMap { $0["where"] as? String }).count == 2)

        // The transcript: every kind and every status in the fixture is one the contract
        // names, and the command row is the one that proves `text` and `output` are kept
        // apart rather than concatenated.
        let detail = try body("GET", "/agent/sessions/{engine}")
        let items = try #require(detail["items"] as? [[String: Any]])
        #expect(items.allSatisfy {
            ControlAPI.agentItemKinds.contains($0["kind"] as? String ?? "")
        })
        #expect(items.allSatisfy {
            $0["status"] == nil || $0["status"] is NSNull
                || ControlAPI.agentItemStatuses.contains($0["status"] as? String ?? "")
        })
        let command = try #require(items.first { $0["kind"] as? String == "command" })
        #expect((command["text"] as? String)?.isEmpty == false)
        #expect((command["output"] as? String)?.isEmpty == false)
        #expect(command["text"] as? String != command["output"] as? String)
        // A cut log says it was cut, and is never longer than the limit.
        #expect(command["truncated"] as? Bool == true)
        #expect(((command["output"] as? String)?.count ?? .max) <= ControlAPI.agentOutputLimit)
        // Prose has no status, and neither does a file change: the contract does not
        // invent one for either.
        for kind in ["assistant", "fileChange"] {
            let row = try #require(items.first { $0["kind"] as? String == kind })
            #expect(row["status"] == nil || row["status"] is NSNull, "\(kind)")
        }
        // The model is stamped on the row that was the sending, and nowhere else: it is
        // knowable exactly once.
        #expect(items.filter { $0["model"] is String }.count == 1)
        #expect(items.first { $0["model"] is String }?["kind"] as? String == "user")
        // The cursor, in both halves, and the flags that say what to do with the items.
        #expect(detail["seq"] is Int)
        #expect((detail["epoch"] as? String)?.isEmpty == false)
        #expect(detail["complete"] as? Bool == true)
        #expect(detail["omitted"] as? Int == 0)
        // A listed approval has been screened, and says what the Mac's card says.
        let approvals = try #require(detail["approvals"] as? [[String: Any]])
        let screening = try #require(approvals.first?["screening"] as? [String: Any])
        #expect(ControlAPI.agentScreeningVerdicts.contains(screening["verdict"] as? String ?? ""))
        #expect((screening["summary"] as? String)?.hasPrefix("Jev:") == true)

        // 202, not 200: the turn was accepted, not answered — and the model is sticky.
        let send = try #require(Self.routes.first {
            $0.method == "POST" && $0.path == "/agent/sessions/{engine}/messages"
        })
        #expect(send.summary.contains("202"))
        #expect(send.summary.contains("sticky"))
        #expect(try body("POST", "/agent/sessions/{engine}/messages")["itemID"] is String)

        // The refusals a phone acts on differently, and each says a different thing.
        func errors(_ method: String, _ path: String) -> [Int: String] {
            Self.routes.first { $0.method == method && $0.path == path }?.errors ?? [:]
        }
        func variants(_ method: String, _ path: String) -> [String] {
            Self.routes.first { $0.method == method && $0.path == path }?
                .errorVariants.map(\.2) ?? []
        }
        let approvalRoute = ("POST", "/agent/sessions/{engine}/approvals/{id}")
        let answered = errors(approvalRoute.0, approvalRoute.1)
        #expect(answered[409] == AgentSessionError.alreadyAnsweredOnTheMac)
        #expect(answered[404] != answered[409])
        #expect(answered[400]?.contains("accept") == true)
        #expect(variants(approvalRoute.0, approvalRoute.1)
            .contains(AgentSessionError.stillBeingScreened))
        #expect(variants("POST", "/agent/sessions/{engine}/messages")
            .contains(AgentSessionError.waitForTheTurn))
        // …and the one that keeps the folder the owner's to pick.
        #expect(errors("POST", "/agent/sessions/{engine}/start")[409]
            == AgentSessionError.workingDirectoryIsTheMacsToPick)

        // The `agent` frame's kinds, all in the export, because each fills in different
        // optional fields.
        let events = try #require(Self.routes.first { $0.path == "/events" })
        var frames: [[String: Any]] = []
        for (name, example) in events.events where name == "agent" {
            frames.append(
                try JSONSerialization.jsonObject(with: try example.encode())
                    as? [String: Any] ?? [:]
            )
        }
        for (name, _, example) in events.eventVariants where name == "agent" {
            frames.append(
                try JSONSerialization.jsonObject(with: try example.encode())
                    as? [String: Any] ?? [:]
            )
        }
        #expect(Set(frames.compactMap { $0["kind"] as? String })
            == Set(ControlAPI.agentEventKinds))
        #expect(frames.allSatisfy {
            $0["seq"] is Int && $0["engine"] is String
                && ($0["epoch"] as? String)?.isEmpty == false
        })
        // An `item` frame carries the row whole — that is what lets a missed frame cost
        // nothing — and never a delta field.
        let item = try #require(frames.first { $0["kind"] as? String == "item" })
        #expect((item["item"] as? [String: Any])?["text"] is String)
        #expect(item["delta"] == nil)
        // A reset names the transcript that replaced the old one.
        let reset = try #require(frames.first { $0["kind"] as? String == "reset" })
        #expect(reset["epoch"] as? String == Self.exampleFreshEpoch)
        #expect(reset["state"] is String && reset["turnActive"] is Bool)
        // Both halves of an approval's life, so a card can appear and disappear.
        let approvalFrames = frames.filter { $0["kind"] as? String == "approval" }
        #expect(Set(approvalFrames.compactMap { $0["state"] as? String })
            == ["pending", "accepted"])
        #expect(approvalFrames.allSatisfy {
            ControlAPI.agentApprovalStates.contains($0["state"] as? String ?? "")
        })
        // Both engines appear across the frames: this is not a Codex-only feature with a
        // second engine bolted to the list.
        #expect(Set(frames.compactMap { $0["engine"] as? String })
            == Set(ControlAPI.agentEngines))
        // And the frame that tells any subscriber it fell behind.
        #expect(events.events.contains { $0.0 == "resync" })
    }

    /// The phone's fallback models, in the contract the phone apps are generated from:
    /// full scope, never the swarm, and pinned to the exact bytes a phone will verify.
    @Test func thePhoneModelRoutesArePinnedAndFullScope() throws {
        let routes = Self.routes.filter { $0.path.hasPrefix("/ondevice/") }
        #expect(routes.count == 4)
        for route in routes {
            #expect(route.auth == "device", "\(route.method) \(route.path)")
            #expect(route.scopes == ["full"], "\(route.method) \(route.path)")
            #expect(route.errors[403] == ControlServer.chatOnlyRefusal)
            #expect(route.errors[401] != nil)
            #expect(
                route.errorVariants.contains {
                    $0.0 == 403 && $0.1 == "swarm"
                        && $0.2 == ControlServer.phoneModelsAreNotForPeers
                },
                "\(route.method) \(route.path)"
            )
            #expect(route.errorVariants.allSatisfy { route.errors[$0.0] != nil })
            // Every route with an id in it can be sent one that is not a catalogue key.
            #expect(route.errors[404] == ControlServer.noSuchPhoneModel
                || route.path == "/ondevice/models")
        }
        // Its own sentence: not the chat refusal, and not the agents' either.
        #expect(ControlServer.phoneModelsAreNotForPeers != ControlServer.chatOnlyRefusal)
        #expect(ControlServer.phoneModelsAreNotForPeers != ControlServer.agentsAreNotForPeers)

        func route(_ method: String, _ path: String) throws -> Route {
            try #require(Self.routes.first { $0.method == method && $0.path == path })
        }
        let file = try route("GET", "/ondevice/models/{id}/file")
        #expect(file.errors[409] == ControlServer.phoneModelNotReady)
        #expect(file.errors[416] == ControlServer.rangeOutsideFile)
        #expect(file.response == nil)
        for header in ["ETag", "X-Content-SHA256", "Range", "If-Range", "Content-Length"] {
            #expect(file.summary.contains(header), "\(header)")
        }
        let prepare = try route("POST", "/ondevice/models/{id}/prepare")
        #expect(prepare.errors[507]?.contains("not enough space") == true)
        #expect(prepare.errors[507]?.contains("startup") == false)
        #expect(prepare.summary.contains("202") && prepare.summary.contains("200"))
        #expect(prepare.summary.contains("?verify=1"))
        #expect(prepare.errors[400] == ControlServer.phoneModelVerifyValues)
        // A drive that is not connected is its own refusal, naming the drive, on every
        // route that would touch it.
        for touching in [prepare, file, try route("DELETE", "/ondevice/models/{id}")] {
            #expect(touching.errors[503] == Self.examplePhoneModelDriveMissing)
        }
        #expect(Self.examplePhoneModelDriveMissing.contains("“External SSD”"))
        // The client rule for a resume, in the words a generated client is built from.
        #expect(file.summary.contains("If-Range") && file.summary.contains("discard"))

        // The list is the catalogue, pinned exactly, the default first.
        let list = try JSONDecoder().decode(
            ControlAPI.PhoneModelList.self,
            from: try #require(try route("GET", "/ondevice/models").response).encode()
        )
        #expect(list.models.map(\.id)
            == ["qwen3.5-2b-q4_0", "qwen3.5-0.8b-q4_0", "gemma-4-e2b-q4_0"])
        let qwen = try #require(list.models.first)
        #expect(qwen.isDefault)
        #expect(qwen.sizeBytes == 1_296_764_000)
        #expect(qwen.sha256 == "91c102fc9a86de80e427057ee938e1e34fcaf3bba956b7296e252406e05f36f6")
        #expect(qwen.source == .init(
            repo: "bartowski/Qwen_Qwen3.5-2B-GGUF",
            commit: "7d26695454df6de5fbcce2e58681e62dae06ce43",
            file: "Qwen_Qwen3.5-2B-Q4_0.gguf"
        ))
        #expect(qwen.onMac == .init(state: "ready"))
        #expect(qwen.measured?.tokensPerSecond == 19.2)
        #expect(qwen.measured?.firstWordEstimated == true)
        #expect(qwen.measured?.sustainedMeasured == false)
        #expect(qwen.measured?.sustainedTokensPerSecond == nil)
        // The fallback a phone is offered when the default will not fit: pinned the same
        // way, never the default, and the one entry in the export that shows a generated
        // client what "nobody has run this on a phone" looks like.
        let small = list.models[1]
        #expect(small.id == "qwen3.5-0.8b-q4_0")
        #expect(!small.isDefault)
        #expect(!small.slowerOnPhone)
        #expect(small.sizeBytes == 563_036_064)
        #expect(small.sha256
            == "57d1997790d1744fba5b40a7317df71ea5e2acee28c47e78f0cce39c0703f8cf")
        #expect(small.source == .init(
            repo: "ggml-org/Qwen3.5-0.8B-GGUF",
            commit: "8fea620810c4afa23dd6443f999a48574c1611a3",
            file: "Qwen3.5-0.8B-Q4_0.gguf"
        ))
        #expect(small.measured == nil)
        #expect(small.onMac == .init(state: "absent"))
        // The smallest gate of the three, which is the whole reason the entry exists.
        #expect(small.recommended.minFreeMemoryBytes == 1_400_000_000)
        #expect(small.recommended.minFreeMemoryBytes
            == list.models.map(\.recommended.minFreeMemoryBytes).min())

        // And in the bytes a generator actually reads, "not measured" is the key simply
        // not being there — the same way every unset optional is carried here.
        let listRoute = try route("GET", "/ondevice/models")
        let listBytes = try #require(listRoute.response).encode()
        let listObject = try #require(
            JSONSerialization.jsonObject(with: listBytes) as? [String: Any]
        )
        let rows = try #require(listObject["models"] as? [[String: Any]])
        #expect(rows.map { $0["id"] as? String } == list.models.map(\.id))
        #expect(rows.filter { $0["measured"] == nil }.map { $0["id"] as? String }
            == ["qwen3.5-0.8b-q4_0"])

        let gemma = try #require(list.models.last)
        #expect(gemma.sizeBytes == 3_349_516_256)
        #expect(gemma.sha256 == "fa401b55b07ee70a54c6dae3903c783a6e65064312529ea57175cb5f8dec6634")
        #expect(gemma.slowerOnPhone)
        #expect(gemma.measured?.sustainedTokensPerSecond == 7.5)
        #expect(gemma.measured?.sustainedMeasured == true)
        #expect(gemma.measured?.threadSweep.map(\.threads) == [4, 6])
        // Every optional in `onMac` is populated somewhere in the export, so a generated
        // client has seen each of them carry a value.
        #expect(gemma.onMac.state == "failed")
        #expect(gemma.onMac.fraction == 0.25)
        #expect(gemma.onMac.reason?.isEmpty == false)
        #expect(ControlAPI.phoneModelFailures.contains(gemma.onMac.failure ?? ""))
        let preparing = try JSONDecoder().decode(
            ControlAPI.PhoneModel.self, from: try #require(prepare.response).encode()
        )
        // A model on its way says what the Mac is doing with it.
        #expect(preparing.onMac.stage == "fetching")
        let states = Set(list.models.map(\.onMac.state))
            .union([preparing.onMac.state])
            .union([try JSONDecoder().decode(
                ControlAPI.PhoneModel.self,
                from: try #require(try route("DELETE", "/ondevice/models/{id}").response).encode()
            ).onMac.state])
        #expect(states == Set(ControlAPI.phoneModelStates))

        // The frames a phone ties to a model on /events: the prefix, and the three lives.
        let events = try route("GET", "/events")
        let frames = try events.eventVariants.filter { $0.0 == "download" }.map {
            try JSONDecoder().decode(ControlAPI.DownloadEvent.self, from: try $0.2.encode())
        }
        #expect(frames.count == 6)
        #expect(frames.allSatisfy {
            $0.id.hasPrefix(ControlAPI.PhoneModel.downloadEventPrefix)
        })
        // Done is the one with no stage and no error.
        #expect(frames.filter { $0.stage == nil && $0.error == nil }.map(\.fraction) == [1])
        #expect(frames.contains { $0.error?.contains("checksum") == true })
        #expect(frames.contains { $0.error == PhoneModelService.removedWhileDownloading })
        #expect(Set(frames.compactMap(\.stage)) == Set(ControlAPI.phoneModelStages))
        #expect(frames.allSatisfy {
            $0.stage == nil || ControlAPI.phoneModelStages.contains($0.stage!)
        })
        // The Mac's own download frame is still the plain one.
        let mac = try #require(events.events.first { $0.0 == "download" })
        #expect(try !JSONDecoder().decode(
            ControlAPI.DownloadEvent.self, from: try mac.1.encode()
        ).id.hasPrefix(ControlAPI.PhoneModel.downloadEventPrefix))
    }

    /// The shape a phone has to be able to rely on for a failed load.
    ///
    /// Every assertion here is the contract, not a restatement of the code: `state` stays a
    /// single line, the facts live beside it under `failure`, and the key is absent rather
    /// than null when nothing has failed — which is what makes this additive for a client
    /// written before it existed.
    @Test func aFailedLoadIsCarriedAsOneLinePlusItsFacts() throws {
        let healthy = try JSONSerialization.jsonObject(
            with: try Self.encoder.encode(Self.exampleStatus)
        ) as? [String: Any]
        #expect(try #require(healthy)["failure"] == nil)

        let failed = try #require(try JSONSerialization.jsonObject(
            with: try Self.encoder.encode(Self.exampleFailedStatus)
        ) as? [String: Any])
        let state = try #require(failed["state"] as? String)
        #expect(state.split(separator: "\n").count == 1)
        #expect(state.contains("signal 9"))

        let failure = try #require(failed["failure"] as? [String: Any])
        #expect(Set(failure.keys) == ["reason", "detail", "runtime", "signal", "wasReplaced", "at"])
        #expect(failure["reason"] as? String == "killed")
        #expect(failure["signal"] as? Int == 9)
        #expect(failure["wasReplaced"] as? Bool == false)
        #expect(failure["runtime"] as? String == "llama.cpp")
        #expect(ControlAPI.date(fromTimestamp: try #require(failure["at"] as? String)) != nil)
        // The detail is the log, and it is not the sentence.
        #expect((failure["detail"] as? String)?.contains("load_tensors") == true)
        #expect(failure["detail"] as? String != state)

        // Every reason the runtimes can produce is one the contract names.
        #expect(Set(LoadFailure.Reason.allCases.map(\.rawValue)) == [
            "exited", "killed", "replaced", "cancelled", "timedOut",
            "launchFailed", "notInstalled",
        ])

        // And the slow-load answer is a `Status` like any other: nothing loaded yet, and
        // nothing claimed to have failed.
        #expect(Self.exampleLoadingStatus.loadedModelID == nil)
        #expect(Self.exampleLoadingStatus.failure == nil)

        // Every ending a client may meet has an example, not only the one the bug was
        // about: a generated client that has seen `killed` and nothing else has no reason
        // to expect `wasReplaced`, which is the one that is not a fault at all.
        let variants = try #require(
            Self.routes.first { $0.method == "GET" && $0.path == "/status" }
        ).responseVariants
        let reasons = try variants.map { label, example -> String in
            try #require(try JSONDecoder().decode(
                ControlAPI.Status.self, from: try example.encode()
            ).failure?.reason)
        }
        #expect(Set(reasons) == ["killed", "replaced", "cancelled", "timedOut"])
        #expect(Self.exampleReplacedStatus.failure?.wasReplaced == true)

        // And the shape a chat-scope device or a peer is answered: the whole failure except
        // the runtime's log, which names files on this Mac.
        let withheld = try #require(Self.exampleWithheldStatus.failure)
        #expect(withheld.detail == nil)
        #expect(withheld.reason == "killed" && withheld.signal == 9)
        #expect(Self.exampleWithheldStatus.state == Self.exampleFailedStatus.state)

        // The refusal a second load gets says what is running and that nothing changed.
        let refusal = try #require(
            Self.routes.first { $0.method == "POST" && $0.path == "/load" }?.errors[409]
        )
        #expect(refusal.contains("bonsai-2-27b"))
        #expect(refusal.contains("Nothing was changed"))
        #expect(refusal.contains("GET /status"))
        // Scoped to the route, because it is: the Mac's own window can still start a load,
        // and the one it displaces says so rather than being refused.
        #expect(refusal.contains("this route runs one load at a time"))
    }

    @Test func exportsWhenAskedTo() throws {
        guard let directory = ProcessInfo.processInfo.environment["SILICON_EXPORT_CONTRACT"],
              !directory.trimmingCharacters(in: .whitespaces).isEmpty
        else { return }

        let root = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        var expected = Set(Self.routes.map(\.fileName))
        expected.insert("routes.md")
        // A renamed or deleted route leaves a fixture behind, and a stale fixture is worse
        // than a missing one — a generator would build a client for a route that is gone.
        for stale in try FileManager.default.contentsOfDirectory(atPath: root.path)
        where !expected.contains(stale) && (stale.hasSuffix(".json") || stale == "routes.md") {
            try FileManager.default.removeItem(at: root.appendingPathComponent(stale))
        }

        for route in Self.routes {
            try route.fixture().write(
                to: root.appendingPathComponent(route.fileName), options: .atomic
            )
        }
        try Data(Self.routesMarkdown().utf8).write(
            to: root.appendingPathComponent("routes.md"), options: .atomic
        )

        let written = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
        #expect(written.isSuperset(of: expected))
    }

    // MARK: - Shapes

    /// One example value, kept with the two things a fixture needs from it: its bytes, and
    /// proof that those bytes decode back into the same thing.
    struct Example: Sendable {
        var encode: @Sendable () throws -> Data
        var roundTrip: @Sendable (Data) throws -> Data

        static func of<T: Codable & Sendable>(_ value: T) -> Example {
            Example(
                encode: { try ContractExportTests.encoder.encode(value) },
                roundTrip: { data in
                    try ContractExportTests.encoder.encode(
                        try JSONDecoder().decode(T.self, from: data)
                    )
                }
            )
        }
    }

    struct Route: Sendable {
        var method: String
        var path: String
        /// control — this Mac's own token. device — a paired phone's token, which the
        /// control token also satisfies. none — open, and there are only two of those.
        var auth: String
        var summary: String
        var request: Example?
        /// More request shapes than one, for a route whose body is a verb rather than a
        /// payload. `POST /video/queue/control` has six, and a generated client that has
        /// only ever seen `pause` has to guess the other five — including which of them
        /// need an `id` and what `confirmNewRender` is for.
        var requests: [(String, Example)] = []
        var response: Example?
        /// More answer shapes than one, for a route that can answer in more than one state
        /// without failing. `POST /load` has two: the load finished inside the request, or
        /// it is still running and the answer is the live status. A generated client that
        /// has only ever seen the first would read the second as a load that succeeded.
        var responseVariants: [(String, Example)] = []
        /// SSE event name to payload example, for the routes that answer a stream.
        var events: [(String, Example)] = []
        /// More shapes of an event already in `events`: its name, a label for the shape,
        /// and the payload. Kept apart from `events` because that map is "the frames this
        /// route sends", keyed by the word on the wire, and a second entry called
        /// "job finished" would teach a generated client an event name that does not
        /// exist.
        var eventVariants: [(String, String, Example)] = []
        /// What this route says when it says no, keyed by status. Every entry is an
        /// `ErrorResponse`, which is the only failure envelope this server has.
        var errors: [Int: String] = [:]
        /// More sentences for a status already in `errors`: the status, a label, and the
        /// sentence. For a route that refuses two different callers, or two different
        /// situations, with the same status and different words — a generated client that
        /// has seen only one would show the wrong reason for the other.
        var errorVariants: [(Int, String, String)] = []
        /// The device scopes that may call it. Filled in from the server's own gate.
        var scopes: [String] = ["full"]

        var isStream: Bool { !events.isEmpty }

        var examples: [(String, Example)] {
            var all: [(String, Example)] = []
            if let request { all.append(("request", request)) }
            all.append(contentsOf: requests.map { ("request \($0.0)", $0.1) })
            if let response { all.append(("response", response)) }
            all.append(contentsOf: responseVariants.map { ("response \($0.0)", $0.1) })
            all.append(contentsOf: events.map { ("event \($0.0)", $0.1) })
            all.append(contentsOf: eventVariants.map { ("event \($0.0) \($0.1)", $0.2) })
            all.append(contentsOf: errors.sorted { $0.key < $1.key }.map {
                ("error \($0.key)", .of(ControlAPI.ErrorResponse(error: $0.value)))
            })
            all.append(contentsOf: errorVariants.map {
                ("error \($0.0) \($0.1)", .of(ControlAPI.ErrorResponse(error: $0.2)))
            })
            return all
        }

        /// The refusals every authenticated route shares, so each entry below only has to
        /// name what is particular to it.
        static func commonErrors(
            auth: String, openToChatOnly: Bool, takesABody: Bool
        ) -> [Int: String] {
            // An unauthenticated route can only fail in ways particular to it, so it says
            // so itself rather than inheriting refusals it has no token to refuse.
            guard auth != "none" else { return [:] }
            var shared = [
                401: "Invalid or missing control token.",
                411: "This server needs a Content-Length. Chunked bodies are not read.",
                413: "That request body is larger than this device may send (4194304 bytes).",
            ]
            if takesABody {
                // Every route with a body can be sent one it cannot read.
                shared[400] = "The data couldn’t be read because it isn’t in the correct format."
            }
            if auth == "control" {
                shared[403] = "Only this Mac can list paired devices."
            } else if !openToChatOnly {
                // Taken from the server rather than retyped: a fixture that promises a body
                // the server does not send is worse than one that promises nothing.
                shared[403] = ControlServer.chatOnlyRefusal
            }
            return shared
        }

        /// A path cannot be a file name, so its slashes become underscores. The mapping is
        /// exact in both directions, which is what lets a generator read the route back out
        /// of the file name.
        /// A path is not a file name, so `/`, `{` and `}` all become `_`. The mapping is
        /// documented in `routes.md` and the result has no spaces or braces in it, which is
        /// what lets a generator turn a file name into a symbol.
        var fileName: String {
            let flattened = path
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "{", with: "_")
                .replacingOccurrences(of: "}", with: "_")
            return "\(method)_\(flattened).json"
        }

        func fixture() throws -> Data {
            var body: [String: Any] = [
                "method": method, "path": path, "auth": auth, "summary": summary,
                "scopes": scopes,
            ]
            body["request"] = try request.map { try json($0) } ?? NSNull()
            if !requests.isEmpty {
                var named: [String: Any] = [:]
                for (label, example) in requests { named[label] = try json(example) }
                body["requests"] = named
            }
            body["response"] = try response.map { try json($0) } ?? NSNull()
            if !responseVariants.isEmpty {
                var named: [String: Any] = [:]
                for (label, example) in responseVariants { named[label] = try json(example) }
                body["responseVariants"] = named
            }
            if !events.isEmpty {
                var frames: [String: Any] = [:]
                for (name, example) in events { frames[name] = try json(example) }
                body["events"] = frames
                body["contentType"] = "text/event-stream"
            }
            if !eventVariants.isEmpty {
                var variants: [String: [String: Any]] = [:]
                for (name, label, example) in eventVariants {
                    variants[name, default: [:]][label] = try json(example)
                }
                body["eventVariants"] = variants
            }
            var refusals: [String: Any] = [:]
            for (status, message) in errors {
                refusals[String(status)] = try json(
                    .of(ControlAPI.ErrorResponse(error: message))
                )
            }
            body["errors"] = refusals
            if !errorVariants.isEmpty {
                var variants: [String: [String: Any]] = [:]
                for (status, label, message) in errorVariants {
                    variants[String(status), default: [:]][label] = try json(
                        .of(ControlAPI.ErrorResponse(error: message))
                    )
                }
                body["errorVariants"] = variants
            }
            return try JSONSerialization.data(
                withJSONObject: body, options: [.prettyPrinted, .sortedKeys]
            )
        }

        private func json(_ example: Example) throws -> Any {
            try JSONSerialization.jsonObject(with: try example.encode())
        }
    }

    /// Routes the server answers that the mobile contract deliberately leaves out.
    static let excludedRoutes: Set<String> = [
        "GET /overlay", "GET /overlay/state", "GET /overlay/portrait",
        "GET /overlay/portrait-eyes", "GET /overlay/portrait-open",
    ]

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func routesMarkdown() -> String {
        var lines = [
            "# Silicon Optimizer control API",
            "",
            "Generated by `ContractExportTests` in the silicon-optimizer repository.",
            "Do not edit by hand: re-run the export instead.",
            "",
            "Every route takes `Authorization: Bearer <token>` unless its auth column says",
            "`none`. A `control` token is the Mac's own, rotated every launch and readable",
            "only by processes running as the owner. A `device` token is minted by",
            "`POST /buddy/pair` and is what a phone holds; the control token satisfies those",
            "routes too, but not the other way round.",
            "",
            "Every body must carry a `Content-Length`; chunked requests are answered 411.",
            "A device may send at most 4 MiB, 8 images per message and about 1.5 MB per",
            "image; over that is a 413. Failures are always `{\"error\": \"...\"}`, and each",
            "fixture lists the ones its route can produce.",
            "",
            "Fixture file names replace `/`, `{` and `}` with `_`, so",
            "`POST /conversations/{id}/messages` is `POST__conversations__id__messages.json`.",
            "",
            "Each fixture lists the device `scopes` that may call it; an empty list means the",
            "route needs no token at all.",
            "",
            "`full` and `chat` are the two device scopes. A `chat` device may use the routes",
            "that only read or advise — `/health`, `/status`, `/profile`, `/metrics`,",
            "`/catalog`, `/installed`, `GET /recommend`, `/plan`, `/swarm`, `/v1/node`,",
            "`/image/models`, `/mesh/models`, `/video/models`, `/video/queue`, `/events` —",
            "plus `/chat`, `/chat/stream`, `/decide`, `/v1/systemone` and every",
            "`/conversations` route. Everything else answers 403: installing, loading,",
            "unloading, benchmarking, rendering, queue control, the device list and the",
            "Jev settings — and `POST /recommend`, which ranks the catalogue against a",
            "described job by asking Jev and so spends the owner's money.",
            "`POST /jev` and `POST /jev/calibrate` go further and take the Mac's own control",
            "token: they govern what this Mac spends, so a paired phone may read both, and",
            "the matching `GET /jev` and `GET /jev/calibration`, without being able to",
            "change either.",
            "",
            "`POST /buddy/invitations` and `DELETE /buddy/invitations` take that same control",
            "token, and for a stronger reason: minting a pairing code admits the *next*",
            "device to this Mac. A phone that could mint one could pair the phone after it",
            "without the owner ever seeing a code, so these two are answered on the Mac's own",
            "loopback listener only and are not reachable from the tailnet at all — at any",
            "device scope, and with any token. A minted code carries the tailnet listener's",
            "address and port, lives five minutes and is spent once; with that listener down",
            "the mint is a 409 rather than a code pointing nowhere.",
            "",
            "## Results, uploads and the queue's verbs",
            "",
            "`GET /media/{id}` is the only route that answers bytes. The id is opaque and",
            "issued by the Mac: it arrives as `mediaID` or `thumbnailMediaID` on a result,",
            "and a client never builds one. Ids only ever name files inside the app's own",
            "output folders, so there is no path to send and no traversal to attempt. The",
            "route carries the file's content type, `Accept-Ranges: bytes` and an `ETag`;",
            "send `Range` for a 206 and `If-None-Match` for a 304. A multi-range `Range` is",
            "ignored and the whole file sent, because this server does not write",
            "`multipart/byteranges`. Media is the one family of responses that is cacheable",
            "— `Cache-Control: private, max-age=3600` — and everything else stays",
            "`no-store`. Anything that is not an image or a video also carries",
            "`Content-Disposition: attachment`, and all of it carries `nosniff`.",
            "",
            "**Scope is per id, not per route.** A full-control device may fetch anything it",
            "has an id for. A chat-only device may fetch the preview images —",
            "`thumbnailMediaID` — and gets a 403 on the renders themselves: a device paired",
            "for chat is one that was lent out, and pulling a clip onto it is the permission",
            "the owner withheld. Both scopes see both ids in `GET /video/queue`.",
            "",
            "An id stops working when its file is deleted, moved out of the app's output",
            "folders, or replaced by a link pointing outside them — the roots are rechecked",
            "on every fetch, not remembered from when the id was issued. All of those are",
            "the same 404, and so is another device's upload id: \"that is not yours\" and",
            "\"that does not exist\" have to look alike, or the route is an oracle.",
            "",
            "`POST /uploads` is how a device names a picture without naming a path. Send the",
            "bytes with a `Content-Type` and an `X-Filename`, or a `multipart/form-data`",
            "body; both are read, and neither is believed — the type is decided from the",
            "file's own first bytes, and anything that is not a PNG, JPEG, GIF, WebP, MP4,",
            "MOV or WebM is a 415. The ceiling is 24 MiB for this route alone; every other",
            "route a device can reach keeps its 4 MiB. Uploads land in a folder per device",
            "and are deleted after seven days — swept on every upload and on every queue",
            "poll — so `uploadID` and `mediaID` both stop resolving then. An upload belongs",
            "to the device that sent it: another device's id resolves to nothing, by either",
            "name. `POST /mesh/plan`, `POST /mesh/generate`, `POST /image/plan`,",
            "`POST /image/generate` and `POST /video/generate` each take `uploadID` or",
            "`mediaID` in place of a path. A device or swarm peer may only use those IDs",
            "to supply an image: a request with a path is refused, even if it also has",
            "a valid ID, because a peer that could name one file could name any file.",
            "For paired devices, full scope is required — uploading spends this Mac's disk, and",
            "the 24 MiB ceiling is granted to an identified full-scope device rather than to",
            "the path, so an unknown bearer gets the ordinary 4 MiB.",
            "",
            "`GET /swarm` says what the Mac's last poll saw, which is why every field beyond",
            "name, address and reachability is optional there. `GET /swarm/peers/{name}/status`",
            "asks one node now, and is the only place the adapter riding on its loaded GGUF",
            "appears. The Mac's credential for that node goes out in a header and is never",
            "in the answer. Full scope only.",
            "",
            "`POST /video/queue/control` takes one of six verbs, and the fixture has an",
            "example of each. `pause` and `resume` and `clear_finished` take no `id`;",
            "`retry`, `remove` and `stop_following` need one. There is no `cancel`: a clip",
            "already handed to a node keeps rendering there, and `stop_following` says what",
            "actually happens — this Mac stops following it and the queue pauses.",
            "`confirmNewRender` matters on `retry` alone. A failed clip the Mac can",
            "reconnect to is reconnected; one whose submission is uncertain is refused until",
            "the caller passes `confirmNewRender: true`, which is the caller saying it has",
            "checked the node and accepts that a second render may start. A verb that is not",
            "one of the six is a 400 saying exactly which six there are.",
            "",
            "Two constants the phone should stop guessing. A batch is at most 20 variations",
            "per prompt, at most 200 unfinished clips at once and at most 2,000 items of",
            "history — over any of those, `POST /video/queue` is a 400 naming all three. And",
            "the length rule: `seconds` must be one of the chosen model's",
            "`supportedSeconds` on `POST /video/generate`, which refuses anything else by",
            "name; an omitted `seconds` falls back to the Mac's current setting snapped to",
            "the nearest value that model supports. `GET /video/models` carries",
            "`supportedSeconds`, `supportedResolutions` and `supportsNegativePrompt` per",
            "lane, so a picker never has to offer a size or a field the renderer would",
            "quietly ignore.",
            "",
            "## Loading a model, and what a failed load says",
            "",
            "`POST /load` is not a request the Mac abandons when the caller goes away. The",
            "load is started, detached from the request, and runs to its end whatever",
            "happens to the connection — a phone that locks its screen, a client that times",
            "out, a tab that closes. The request only *watches* it: if it finishes within 25",
            "seconds the answer is the load's own status, exactly as before; if it is still",
            "going, the answer is the live status instead — the same shape, with `state`",
            "carrying the stage line and `loadedModelID` still null. Follow it with",
            "`GET /status`, or on `/events`.",
            "",
            "**One load at a time on this route.** A second `POST /load` while one is",
            "running is a 409 naming the model already loading and how long it has been",
            "going, and nothing is changed: obeying it would mean killing a load the owner",
            "asked for, possibly minutes into reading a 30 GB file, and the first load would",
            "then fail in a way that looked like the model's fault. `POST /unload` stops the",
            "load in flight if that is really what is wanted. The Mac's own window is not",
            "held by this route and can still start a load that replaces one; the load that",
            "loses says so (`failure.wasReplaced`) rather than reporting a fault.",
            "",
            "**A failed load.** `state` is one sentence — \"llama-server stopped on its own",
            "after 8 seconds (exit 1)\", \"…was killed (signal 9), which usually means the",
            "system reclaimed its memory\", \"…was replaced by another load\", \"…never",
            "answered in 10 minutes\" — and it is meant to be shown as it is. Beside it,",
            "`failure` carries the same failure's facts: `reason` (`exited`, `killed`,",
            "`replaced`, `cancelled`, `timedOut`, `launchFailed`, `notInstalled` — treat an",
            "unknown one as `exited`), `detail` (the tail of the runtime's log, at most 20",
            "lines: put it behind a tap, never in the line a person reads first), `runtime`,",
            "`exitStatus`, `signal`, `wasReplaced` and `at`. The key is **absent** unless a",
            "load has failed, so a client written before it existed reads what it always",
            "did.",
            "",
            "`detail` is the only part of this that is scoped. It is the runtime's raw log,",
            "and on a Mac that log names files — so a device paired for **chat**, and the",
            "swarm, are answered the whole failure *without* it, on `GET /status` and in the",
            "`status` frame on `/events` alike. Absolute paths inside it are reduced to the",
            "file's own name before it leaves the Mac at all, for everyone.",
            "",
            "## Agent sessions",
            "",
            "`/agent/sessions` mirrors the Mac's Chat tab: one session per engine — `codex`",
            "and `pi` — and it is *the* session, not a copy. The session id is the engine",
            "id; there is no thread registry. Sending appends to the transcript the owner is",
            "looking at, and an approval answered on either side is answered once, for both.",
            "",
            "Every route here is **full scope only**, because every one of them runs commands",
            "on this Mac — and so is what they reveal: `agent` frames on `/events` go only to",
            "this Mac's own token and to full-control devices. A chat-only device is answered",
            "403 by the same gate that refuses it `POST /load`. So is the swarm secret, with",
            "its own sentence (in each fixture's `errorVariants`): a node is a machine with a",
            "token in a config file, not a person with a phone.",
            "",
            "Engines are listed even when stopped, so a phone can offer to start one. The",
            "summary says whether anything stands between the agent and the Mac: `approvals`",
            "is `screened` (it asks, and the Jev guardrail judges each ask first), `asked` (it",
            "asks, a person decides — including while the guardrail is on but cannot judge, with",
            "no key or no budget left) or `unattended` (nothing asks — Codex under \"never ask\",",
            "or Pi with the guardrail off), and `sandbox` is Codex's mode or `none` for Pi.",
            "`cwd` is home-relative (`~/…`) and null for Codex until the owner has picked a",
            "folder on the Mac — the one thing a device may not choose.",
            "",
            "`POST .../start` is what opening the tab does, or the Mac's Retry from `failed`,",
            "and is idempotent. `POST .../new` starts a fresh thread — stopping a turn in",
            "flight first — and clears the Mac's transcript with it. `DELETE` stops the",
            "sidecar. `POST .../messages` answers **202** with the transcript row the send",
            "became; a Codex turn already running is a 409, as the Mac's own send button is",
            "disabled, while Pi takes a message mid-turn as steering. `model` must be one of",
            "the session's `modelChoices`, and it is **sticky**: it becomes the engine's model,",
            "saved and shown in the Mac's own menu, exactly as picking it there does.",
            "",
            "`GET /agent/sessions/{engine}` carries the transcript in one normalised shape for",
            "both engines — `user`, `assistant`, `reasoning`, `command`, `fileChange`, `tool`,",
            "`notice`, `error` — oldest first. `output` is at most its last 8,192 characters,",
            "with `truncated: true` when it was cut. The answer's `seq` and `epoch` are one",
            "cursor: send both back as `?since=<seq>&epoch=<epoch>` and the answer carries only",
            "the rows that changed after it, with `complete: false`. A cursor from another",
            "epoch — a new thread, a restart, the Mac's app relaunched — or a `seq` never",
            "reached answers the whole transcript with `complete: true`, so replace rather",
            "than merge. `?limit=` caps the rows (default 500, at most 2000); `omitted` counts",
            "what it left out, and a slice that would not fit is answered as the transcript's",
            "newest rows with `complete: true` rather than a slice missing its oldest changes.",
            "",
            "Approvals are what a *person* still has to decide, once the guardrail has had its",
            "say: a call Jev is still screening is not listed and cannot be answered (409), and",
            "each listed one carries `screening` — the verdict and the line the Mac's own card",
            "shows. Answering is `accept` or `decline`. An id that is not waiting is a 404 —",
            "answered already, or never there — except when the Mac answered it first, which",
            "is a 409 saying so: the decision was made, the agent has it, and nothing was sent",
            "twice. A stopped engine is asking nobody anything, so it lists no approvals and",
            "answering one of its leftover cards is a 409.",
            "",
            "On `/events`, the `agent` frame carries all of it live, and every frame carries",
            "`epoch` and `threadID`. `reset` says the transcript was replaced: drop every row",
            "and card for that engine and fetch again. `state` fires when a session starts,",
            "stops or fails or its thread gets an id; `turn` when a turn begins or ends; `item`",
            "when a row appears or changes, carrying the row whole rather than a delta and",
            "sampled ten times a second per engine; `approval` — with `pending`, `accepted` or",
            "`declined` — when a call starts or stops waiting. Frames arrive in `seq` order, so",
            "a phone resuming from the last frame it read misses nothing. A phone that has",
            "just connected is sent each engine's `state`, `turn` and pending `approval`s",
            "first, at the current `seq`. A subscriber that falls more than 32 frames behind",
            "loses the oldest, and a `resync` frame saying how many arrives exactly where they",
            "were: after the last frame read before the gap and before anything newer, one per",
            "gap. Fetch what you show again with the cursor from that last frame — it sits just",
            "before the gap, so the answer holds exactly what was dropped.",
            "",
            "## Models for the phone",
            "",
            "`/ondevice/models` is how a phone gets the small model it runs by itself when the",
            "Mac is out of reach, without ever leaving the tailnet: the Mac fetches the file",
            "from Hugging Face and serves it. Each entry is pinned — repository, commit, file,",
            "`sizeBytes` and `sha256` — and carries what the phone needs to run it",
            "(`recommended`: threads for the prompt and for writing, context length, free",
            "memory needed, `thinking`) and what a real phone measured (`measured`).",
            "`measured` is one benchmark on the owner's phone: `tokensPerSecond` at",
            "`recommended.threadsGenerate`, the `threadSweep` it was picked from,",
            "`promptTokensPerSecond`, and `secondsToFirstWord300` — an estimate",
            "(`firstWordEstimated: true`), 300 ÷ the prompt speed rounded up to a tenth.",
            "`sustainedTokensPerSecond` is null when it was not measured, and",
            "`sustainedMeasured` says which. `peakMemoryBytes` was taken at no more than",
            "`peakMemoryContextTokens`. `recommended.minFreeMemoryBytes` is a gate: the",
            "weights, which are memory-mapped and get no margin, plus the rest of the peak",
            "grown to the recommended context with a quarter on top.",
            "",
            "`onMac.state` is `absent`, `downloading`, `ready` or `failed`. While downloading,",
            "`stage` says what the Mac is doing — `fetching`, `checking` (hashing what it has)",
            "or `moving` (following the model library to a new folder) — and `fraction` how",
            "far it has got; on a failure that kept a partial, `fraction` is how much the Mac",
            "has. A failure carries `reason`, a sentence to show, and `failure`, one of",
            "`diskFull` (free space on the Mac), `checksumMismatch` (deleted; a retry starts",
            "over), `network` and `interrupted` (a retry resumes or checks), `server`,",
            "`driveMissing` (the drive the Mac's model library is on is not connected) or",
            "`other`. A model whose move to a new library folder could not finish reads",
            "`failed` too — `diskFull` when the new drive has no room, and it moves by itself",
            "once there is; `other` otherwise, and a prepare tries the move again.",
            "",
            "`POST .../{id}/prepare` answers **202** with the entry while the fetch is on its",
            "way — started now, resumed, or already running, which it never restarts — and",
            "**200** once it is ready; a Mac without room is a **507** before a byte moves, and",
            "one whose library drive is unplugged a **503** naming it (as are the file and",
            "`DELETE`). Progress is on `/events` as `download` frames whose `id` is",
            "`ondevice:<id>`, sent only to full-control devices and this Mac: in progress they",
            "carry `stage`; done is `fraction: 1` with no `stage` and no `error`; a failure",
            "carries the `error`, and a removal says so. `GET .../{id}/file` is 409 until the",
            "Mac has the file *verified*, then answers bytes with the SHA-256 as the `ETag`",
            "and in `X-Content-SHA256`. Resume with `Range: bytes=N-` and `If-Range` set to",
            "the `ETag`: a 206 is exactly the rest, and a **200 means the file changed** —",
            "discard the partial and keep the whole body. Check the digest at the end; if it",
            "does not match, call `POST .../{id}/prepare?verify=1` once, then fetch again from",
            "zero (`verify` takes `1`/`true`, or `0`/`false` for an ordinary prepare). A Mac with",
            "no network fails a fetch at once; a Hub that never answers, after 60 seconds.",
            "`DELETE .../{id}` removes the Mac's copy and any partial, including one a move",
            "left in a former folder. Ids are catalogue keys and nothing else — anything else",
            "is a 404. Full scope only, and the swarm secret is refused with its own sentence.",
            "",
            "| Method | Path | Auth | What it does |",
            "|---|---|---|---|",
        ]
        for route in routes {
            let streaming = route.isStream ? " _(SSE)_" : ""
            lines.append("| `\(route.method)` | `\(route.path)` | \(route.auth) | \(route.summary)\(streaming) |")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - The table

    /// Each entry below names only the refusals particular to it; the ones every route of
    /// its auth class shares are folded in here, so they cannot drift apart.
    ///
    /// Which scope may call a route is asked of the server's own gate rather than restated,
    /// so the fixtures cannot claim a 403 that cannot happen — or miss one that can.
    static let routes: [Route] = (
        buddyRoutes + coreRoutes + agentRoutes + mediaRoutes + phoneModelRoutes
    ).map { route in
        var decorated = route
        let openToChat = ControlServer.Caller.device(id: "fixture", scope: .chat)
            .mayReach(method: route.method, path: route.path)
        // Empty means no token at all, which is a different thing from "full only" and
        // would be a lie to tell about /health.
        decorated.scopes = route.auth == "none"
            ? [] : (route.auth == "device" && openToChat ? ["full", "chat"] : ["full"])
        decorated.errors = Route.commonErrors(
            auth: route.auth, openToChatOnly: openToChat, takesABody: route.request != nil
        ).merging(route.errors) { _, particular in particular }
        return decorated
    }

    // MARK: Silicon Buddy's own

    static let buddyRoutes: [Route] = [
        Route(
            method: "POST", path: "/buddy/pair", auth: "none",
            summary: "Spend the six-digit code on screen for a device token of your own.",
            request: .of(ControlAPI.BuddyPairRequest(
                code: "417082", deviceName: "Galaxy S24 Ultra", platform: "android"
            )),
            response: .of(ControlAPI.BuddyPairResponse(
                deviceID: "7A1E0C6E-2C6A-4F4E-9F1E-0B2D3C4A5B6C",
                token: "V0hBVC1BLVRPS0VOLVdPVUxELUxPT0stTElLRS1IRVJF",
                macName: "Mac Studio", port: 8788, scope: "full"
            )),
            errors: [
                400: "The request does not name a device.",
                403: BuddyRegistry.wrongCode,
                429: "Too many pairing attempts. Wait a minute.",
            ]
        ),
        Route(
            method: "GET", path: "/buddy/devices", auth: "control",
            summary: "The paired devices, without their token hashes.",
            response: .of([exampleDevice])
        ),
        Route(
            method: "DELETE", path: "/buddy/devices/{id}", auth: "control",
            summary: "Revoke one device. Its token stops working at once, streams included.",
            response: .of(["status": "revoked"]),
            errors: [
                403: "Only this Mac can revoke a paired device.",
                404: "No paired device with id 7A1E0C6E-2C6A-4F4E-9F1E-0B2D3C4A5B6C.",
            ]
        ),
        Route(
            method: "POST", path: "/buddy/invitations", auth: "control",
            summary: "Mint the pairing code the Mac's own Settings window would show.",
            request: .of(ControlAPI.BuddyInvitationRequest(scope: "chat")),
            response: .of(exampleInvitation),
            errors: [
                // Written out rather than inherited: the shared 400 is "that body does not
                // parse", and a scope this server does not have parses perfectly well.
                400: ControlServer.unknownScopeRefusal,
                403: "Only this Mac can mint a pairing code.",
                409: ControlServer.buddyListenerDown,
            ]
        ),
        Route(
            method: "DELETE", path: "/buddy/invitations", auth: "control",
            summary: "Cancel the code on screen. Succeeds whether or not one was open.",
            response: .of(["status": "cancelled"]),
            errors: [403: "Only this Mac can cancel a pairing code."]
        ),
        Route(
            method: "POST", path: "/chat/stream", auth: "device",
            summary: "The same body as /chat, answered token by token.",
            request: .of(exampleChatRequest),
            events: [
                ("token", .of(ControlAPI.StreamToken(text: "Because "))),
                ("reasoning", .of(ControlAPI.StreamToken(text: "The user asked about "))),
                ("finished", .of(exampleMetrics)),
                ("verdict", .of(exampleVerdict)),
                ("error", .of(ControlAPI.ErrorResponse(error: "The device stopped reading."))),
            ],
            errors: [
                400: "No model is loaded.",
                429: "Too many open streams. Close one before opening another.",
            ]
        ),
        Route(
            method: "GET", path: "/events", auth: "device",
            summary: "What the Mac is doing: loaded model, downloads, render jobs — and, "
                + "for full control, the agent sessions.",
            events: [
                ("status", .of(exampleStatus)),
                // A verdict that missed its stream arrives here instead, keyed by the two
                // ids, so a phone can attach it to the bubble it is about.
                ("verdict", .of(ControlAPI.ChatVerdict(
                    verdict: "annotate",
                    reasons: ["The reply declines or deflects the request."],
                    conversationID: "3F5C1A88-9C1D-4E2B-8A70-1D2E3F405162",
                    messageID: "6B2A9D14-40F7-4E85-9C33-2E5A7B1C0D9E"
                ))),
                ("download", .of(ControlAPI.DownloadEvent(
                    id: "qwen3-coder-30b", name: "Qwen3-Coder 30B A3B", fraction: 0.42,
                    bytesReceived: 8_589_934_592, bytesExpected: 20_401_094_656,
                    bytesPerSecond: 41_943_040
                ))),
                // Three frames of the same clip's life, because the interesting fields
                // are the ones a running job does not have. A phone that has only ever
                // seen the middle frame has to poll `GET /video/queue` beside the stream
                // to find out why a render failed or what to fetch when it finished —
                // which is exactly what the phone was doing.
                ("job", .of(ControlAPI.JobEvent(
                    id: "9C2F-0001", kind: "video", status: "running",
                    title: "Opening shot", fraction: 0.33, stage: "video-denoise 18/30"
                ))),

                // The Chat tab's agent sessions, mirrored — sent only to this Mac's own
                // token and to devices paired with full control. The `item` kind is the
                // one that arrives constantly — a row whole, never a delta — so it is the
                // shape under the event's own name; the other kinds are variants below.
                ("agent", .of(ControlAPI.AgentEvent(
                    engine: "codex", kind: "item", seq: 39, epoch: exampleCodexEpoch,
                    threadID: exampleCodexSession.threadID, item: exampleAgentItems[3]
                ))),
                // This stream fell behind and frames were dropped: fetch again what you
                // show, from the cursor of the last frame before this one. Sent exactly at
                // the gap, one per gap, to every kind of subscriber.
                ("resync", .of(ControlAPI.ResyncEvent(dropped: 7))),

                ("heartbeat", .of(ControlAPI.HeartbeatEvent(at: "2026-09-18T09:41:00Z"))),
            ],
            // The same `job` event later in the same clip's life. Not more event names —
            // there is one — but the two shapes of it that carry the fields a running
            // frame cannot, and that a phone otherwise has to poll `GET /video/queue`
            // beside the stream to learn.
            eventVariants: [
                ("job", "finished", .of(ControlAPI.JobEvent(
                    id: "9C2F-0002", kind: "video", status: "completed",
                    title: "The same tram, from the tracks",
                    mediaID: exampleClipMediaID
                ))),
                ("job", "failed", .of(ControlAPI.JobEvent(
                    id: "9C2F-0003", kind: "video", status: "failed",
                    title: "Alfama rooftops at first light",
                    reason: "silicon-node ran out of VRAM at the decode stage."
                ))),
                // The other `agent` kinds. Each fills in different optionals, and a client
                // that has only ever seen an `item` frame would not know that `state`
                // means two things: the session's, on a `state` or `reset` frame, and the
                // approval's resolution on an `approval` one.
                ("agent", "state", .of(ControlAPI.AgentEvent(
                    engine: "pi", kind: "state", seq: 12, epoch: examplePiEpoch,
                    state: "running"
                ))),
                ("agent", "turn", .of(ControlAPI.AgentEvent(
                    engine: "codex", kind: "turn", seq: 34, epoch: exampleCodexEpoch,
                    threadID: exampleCodexSession.threadID, turnActive: true
                ))),
                ("agent", "approval", .of(ControlAPI.AgentEvent(
                    engine: "codex", kind: "approval", seq: 37, epoch: exampleCodexEpoch,
                    threadID: exampleCodexSession.threadID,
                    approval: exampleAgentApproval, state: "pending"
                ))),
                // And the frame that makes both screens agree: the owner answered this at
                // the Mac, so the card on the phone goes away by itself.
                ("agent", "approval answered", .of(ControlAPI.AgentEvent(
                    engine: "codex", kind: "approval", seq: 40, epoch: exampleCodexEpoch,
                    threadID: exampleCodexSession.threadID,
                    approval: exampleAgentApproval, state: "accepted"
                ))),
                // A new thread: the rows and cards a phone holds belong to a transcript
                // that is gone. Drop them, take this epoch, fetch again.
                ("agent", "reset", .of(ControlAPI.AgentEvent(
                    engine: "codex", kind: "reset", seq: 41, epoch: exampleFreshEpoch,
                    threadID: nil, turnActive: false, state: "running"
                ))),
                // The Mac fetching a model for the phone. The same `download` event, with an
                // id a phone can tie to the model: `ondevice:` and the model's id. The last
                // frame of a fetch is either `fraction: 1` or the reason it stopped.
                ("download", "phone model", .of(PhoneModelService.downloadEvent(
                    PhoneModelCatalog.gemma4E2B,
                    state: .downloading(
                        bytesReceived: 837_379_064, bytesPerSecond: 48_234_496, stage: .fetching
                    )
                ))),
                // Every byte is here and the Mac is hashing it: not done yet.
                ("download", "phone model checking", .of(PhoneModelService.downloadEvent(
                    PhoneModelCatalog.qwen35_2B,
                    state: .downloading(bytesReceived: 648_382_000, bytesPerSecond: 0, stage: .checking)
                ))),
                // Following the model library to a new folder.
                ("download", "phone model moving", .of(PhoneModelService.downloadEvent(
                    PhoneModelCatalog.gemma4E2B,
                    state: .downloading(bytesReceived: 0, bytesPerSecond: 0, stage: .moving)
                ))),
                // Done: `fraction` 1, no `stage`, no `error`.
                ("download", "phone model ready", .of(PhoneModelService.downloadEvent(
                    PhoneModelCatalog.qwen35_2B, state: .ready
                ))),
                ("download", "phone model failed", .of(PhoneModelService.downloadEvent(
                    PhoneModelCatalog.gemma4E2B, state: .failed(examplePhoneModelMismatch)
                ))),
                // The Mac's copy was deleted while it was still arriving.
                ("download", "phone model removed", .of(PhoneModelService.downloadEvent(
                    PhoneModelCatalog.gemma4E2B, state: .absent
                ))),
            ],
            errors: [429: "Too many open streams. Close one before opening another."]
        ),
        Route(
            method: "GET", path: "/conversations", auth: "device",
            summary: "Every conversation on the Mac, newest first.",
            response: .of([exampleConversationSummary])
        ),
        Route(
            method: "POST", path: "/conversations", auth: "device",
            summary: "Start a conversation. It appears in the Mac's own sidebar at once.",
            request: .of(ControlAPI.NewConversationRequest(title: "Weekend in Lisbon")),
            response: .of(exampleConversationSummary)
        ),
        Route(
            method: "GET", path: "/conversations/{id}", auth: "device",
            summary: "One transcript. Images are omitted.",
            response: .of(ControlAPI.ConversationDetail(
                id: "3F5C1A88-9C1D-4E2B-8A70-1D2E3F405162",
                title: "Weekend in Lisbon",
                updatedAt: "2026-09-18T09:41:12Z",
                isGenerating: false,
                messages: [
                    .init(role: "user", content: "Three days in Lisbon — what would you do?",
                          createdAt: "2026-09-18T09:40:58Z"),
                    .init(role: "assistant", content: "Start in Alfama, early.",
                          createdAt: "2026-09-18T09:41:12Z",
                          id: "6B2A9D14-40F7-4E85-9C33-2E5A7B1C0D9E",
                          verification: exampleVerdict),
                ]
            )),
            errors: [404: "No conversation with id 3F5C1A88-9C1D-4E2B-8A70-1D2E3F405162."]
        ),
        Route(
            method: "POST", path: "/conversations/{id}/messages", auth: "device",
            summary: "Send a message and stream the answer. Both are saved on the Mac.",
            request: .of(ControlAPI.NewMessageRequest(
                content: "Three days in Lisbon — what would you do?"
            )),
            events: [
                ("token", .of(ControlAPI.StreamToken(text: "Start "))),
                ("reasoning", .of(ControlAPI.StreamToken(text: "Three days is "))),
                ("finished", .of(exampleMetrics)),
                ("verdict", .of(exampleVerdict)),
                ("error", .of(ControlAPI.ErrorResponse(error: "The device stopped reading."))),
            ],
            errors: [
                400: "No model is loaded.",
                404: "No conversation with id 3F5C1A88-9C1D-4E2B-8A70-1D2E3F405162.",
                409: "That conversation is still being answered. Wait for it to finish, or "
                    + "start another one.",
                429: "Too many open streams. Close one before opening another.",
            ]
        ),
    ]

    // MARK: Everything that was already there

    static let coreRoutes: [Route] = [
        Route(
            method: "GET", path: "/health", auth: "none",
            summary: "Unauthenticated, so a client can tell a dead app from a bad token.",
            response: .of(["status": "ok", "version": "0.1.0"])
        ),
        Route(
            method: "GET", path: "/profile", auth: "device",
            summary: "What this Mac is, and how much of it a model may have.",
            response: .of(ControlAPI.Profile(
                chip: "Apple M3 Max", generation: "M3", totalMemoryBytes: 41_553_527_603,
                modelBudgetBytes: 29_200_000_000, performanceCores: 12, efficiencyCores: 4,
                gpuCores: 40, neuralEngineCores: 16, memoryBandwidthGBps: 300,
                diskFreeBytes: 890_000_000_000
            ))
        ),
        Route(
            method: "GET", path: "/metrics", auth: "device",
            summary: "Memory, swap, GPU and CPU right now.",
            response: .of(ControlAPI.Metrics(
                memoryUsedBytes: 21_474_836_480, memoryWiredBytes: 6_442_450_944,
                memoryTotalBytes: 41_553_527_603, swapUsedBytes: 0,
                gpuUtilization: 0.12, cpuUtilization: 0.24, memoryPressure: "normal"
            ))
        ),
        Route(
            method: "GET", path: "/status", auth: "device",
            summary: "What is loaded, at what settings, how fast it last ran. `state` is "
                + "one line for a person; when a load has failed, `failure` carries the "
                + "same failure's facts — show `state`, keep `failure.detail` behind a tap.",
            response: .of(exampleStatus),
            responseVariants: [
                ("after a failed load", .of(exampleFailedStatus)),
                ("after a load that was replaced", .of(exampleReplacedStatus)),
                ("after a load that was cancelled", .of(exampleCancelledStatus)),
                ("after a load that never answered", .of(exampleTimedOutStatus)),
                ("as a chat-scope device or a peer sees it", .of(exampleWithheldStatus)),
            ]
        ),
        Route(
            method: "GET", path: "/installed", auth: "device",
            summary: "The models on this Mac's disk.",
            response: .of([ControlAPI.InstalledModel(
                id: "qwen3-coder-30b", name: "Qwen3-Coder 30B A3B", quantization: "Q4_K_M",
                sizeOnDiskBytes: 20_401_094_656, isLoaded: true, supportsVision: false
            )])
        ),
        Route(
            method: "GET", path: "/catalog", auth: "device",
            summary: "The catalogue, each entry judged against this Mac.",
            response: .of([exampleCatalogModel])
        ),
        Route(
            method: "GET", path: "/recommend", auth: "device",
            summary: "The strongest model this machine can actually run.",
            response: .of(exampleCatalogModel),
            errors: [
                400: ControlServer.taskBelongsInAPost,
                404: "No model in the catalog fits this machine.",
            ]
        ),
        Route(
            method: "POST", path: "/recommend", auth: "device",
            summary: "The best model for a described job, with the runners-up and why. "
                + "Asks Jev, so it costs the owner money and takes full control.",
            request: .of(ControlAPI.RecommendRequest(
                category: "Vision", task: "Reading scanned handwritten field notes into markdown."
            )),
            response: .of(exampleRecommendedModel),
            errors: [404: "No model in the catalog fits this machine."]
        ),
        Route(
            method: "POST", path: "/plan", auth: "device",
            summary: "Will this fit at this context, and what would you change?",
            request: .of(ControlAPI.PlanRequest(
                modelID: "qwen3-coder-30b", quantization: "Q4_K_M", contextLength: 16_384
            )),
            response: .of(examplePlan)
        ),
        Route(
            method: "POST", path: "/install", auth: "device",
            summary: "Download a model. Progress arrives on /events.",
            request: .of(ControlAPI.LoadRequest(modelID: "qwen3-coder-30b", quantization: "Q4_K_M")),
            response: .of(["status": "Downloading Qwen3-Coder 30B A3B (Q4_K_M)."])
        ),
        Route(
            method: "POST", path: "/load", auth: "device",
            summary: "Load a model into memory. The load belongs to the Mac once it has "
                + "been asked for: it is not cancelled if this request goes away. A load "
                + "still running after 25 seconds answers with the live status instead of "
                + "holding the connection — follow it with GET /status.",
            request: .of(ControlAPI.LoadRequest(
                modelID: "qwen3-coder-30b", quantization: "Q4_K_M", contextLength: 16_384
            )),
            response: .of(exampleStatus),
            responseVariants: [("still loading", .of(exampleLoadingStatus))],
            errors: [
                409: ControlAPI.LoadAlreadyRunning(
                    modelID: "bonsai-2-27b", secondsAgo: 12
                ).localizedDescription,
            ]
        ),
        Route(
            method: "POST", path: "/unload", auth: "device",
            summary: "Free the loaded model.",
            response: .of(["status": "unloaded"])
        ),
        Route(
            method: "POST", path: "/chat", auth: "device",
            summary: "Ask the loaded model and wait for the whole answer.",
            request: .of(exampleChatRequest),
            // With a verdict attached, because this is the one route that escalates and a
            // generated client has to know the field exists before it meets one. Note the
            // zeroed counters: `content` is the escalation model's answer, so the local
            // run's throughput would describe text this response no longer contains.
            response: .of(ControlAPI.ChatResponse(
                content: "Start in Alfama, early.", reasoning: nil, promptTokens: 0,
                generatedTokens: 0, tokensPerSecond: 0,
                verification: exampleEscalatedVerdict
            ))
        ),
        Route(
            method: "POST", path: "/decide", auth: "device",
            summary: "Typed probabilistic decisions, in the TypeSafe/Jev shape.",
            request: .of(ControlAPI.DecideRequest(
                state: .string("Customer was charged twice and wants it fixed."),
                questions: [
                    "refund": .init(type: "noul", instructions: .string("Asks for money back")),
                    "team": .init(
                        type: "choice", instructions: .string("Which team should take it"),
                        criteria: .object(["billing": .null, "technical": .null])
                    ),
                ]
            )),
            // The cascade, because that is what `provider: "auto"` does on a Mac with a
            // model loaded and Jev turned on — and because `sources` is the field a
            // generated client would otherwise never be taught to expect. The single-lane
            // shape is next door on /v1/systemone.
            response: .of(ControlAPI.DecideResponse(
                model: "Qwen3-Coder 30B A3B + jev-1.13.0",
                usage: .init(inputTokens: 1_020, outputTokens: 2),
                answers: [
                    "refund": .noul(0.94),
                    "team": .choice(
                        choice: "billing", confidence: 0.91,
                        probabilities: ["billing": 0.91, "technical": 0.09]
                    ),
                ],
                provider: "local+typesafe",
                sources: ["refund": "local", "team": "typesafe"]
            ))
        ),
        Route(
            method: "POST", path: "/v1/systemone", auth: "device",
            summary: "The same route as /decide, at the path TypeSafe's own clients use.",
            request: .of(ControlAPI.DecideRequest(
                state: .string("Customer was charged twice and wants it fixed."),
                questions: [
                    "refund": .init(type: "noul", instructions: .string("Asks for money back")),
                ]
            )),
            response: .of(ControlAPI.DecideResponse(
                model: "Qwen3-Coder 30B A3B",
                usage: .init(inputTokens: 120, outputTokens: 1),
                answers: ["refund": .noul(0.94)],
                provider: "local"
            ))
        ),
        Route(
            method: "GET", path: "/jev", auth: "device",
            summary: "How the TypeSafe (Jev) lane is set up, and what it has cost this month.",
            response: .of(exampleJevStatus)
        ),
        Route(
            method: "GET", path: "/jev/guardrails/recent", auth: "device",
            summary: "The last screenings the tool-call guardrail made: verdicts, the "
                + "question ids that fired, and how long each took.",
            response: .of(exampleGuardrailScreenings)
        ),
        Route(
            method: "POST", path: "/jev", auth: "control",
            summary: "Change what Jev is allowed to do. Only sent fields change.",
            request: .of(ControlAPI.JevUpdate(
                enabled: true, features: ["decideTool": true], monthlyBudgetUSD: 5
            )),
            response: .of(exampleJevStatus),
            errors: [403: ControlServer.jevWriteRefusal]
        ),
        Route(
            method: "GET", path: "/jev/calibration", auth: "device",
            summary: "The last calibration of the local decision lane against Jev.",
            response: .of(exampleJevCalibration),
            errors: [404: ControlServer.noCalibrationYet]
        ),
        Route(
            method: "POST", path: "/jev/calibrate", auth: "control",
            summary: "Measure the local decision lane against Jev and retune the cascade.",
            response: .of(exampleJevCalibration),
            errors: [403: ControlServer.jevCalibrateRefusal]
        ),
        Route(
            method: "POST", path: "/benchmark", auth: "device",
            summary: "Measure the loaded model here, and recalibrate its estimates.",
            response: .of(ControlAPI.BenchmarkResult(
                modelName: "Qwen3-Coder 30B A3B", score: 82, grade: "Fast",
                generationTokensPerSecond: 89.4, promptTokensPerSecond: 1120,
                timeToFirstToken: 0.31, longContextFalloff: 0.86,
                predictedGenerationTokensPerSecond: 91, calibration: 0.98,
                findings: [.init(
                    title: "Within 2% of prediction",
                    detail: "The planner's estimate needed no correction.",
                    severity: "info"
                )]
            ))
        ),
        Route(
            method: "GET", path: "/swarm", auth: "device",
            summary: "The other machines this Mac can delegate to.",
            response: .of(ControlAPI.SwarmView(
                peers: [.init(
                    name: "silicon-node", baseURL: "http://silicon-node:8790",
                    reachable: true, error: nil,
                    capabilities: [
                        .init(id: "image-to-mesh", kind: "mesh", ready: true),
                        .init(id: "text-to-video", kind: "video", ready: true),
                        .init(id: "text-to-image", kind: "image", ready: false),
                    ],
                    // Everything from here down is what the Mac's last poll already knew
                    // and used to keep to itself. A peer that is down carries its error
                    // and none of this, which is why every field is optional.
                    platform: "windows-cuda",
                    hardware: "NVIDIA GeForce RTX 3090 Ti",
                    totalMemoryGB: 24, usedMemoryGB: 9.4, headroomGB: 14.6,
                    gpuUtilization: 0.38, queueDepth: 1, gpuConsumer: "job:text-to-video",
                    loadedModel: "qwen3.8-27b-q4_k_m.gguf", modelEngine: "stock",
                    modelContextLength: 65_536,
                    lanes: .init(video: true, image: false, mesh: true, gguf: true)
                )],
                polledSecondsAgo: 4,
                // This Mac's own tailnet address, not a peer's: the block says where
                // *we* can be reached, which is the half of the swarm a node cannot see.
                //
                // 100.64.0.9 is the placeholder the rest of this export uses, and it is a
                // placeholder on purpose: this fixture is committed to a public repository
                // and copied into the companion-app repositories, and any other address in
                // the tailscale range would read as somebody's real machine.
                exposure: .init(
                    requested: true, listening: true, address: "100.64.0.9",
                    port: 8788, problem: nil
                )
            ))
        ),
        Route(
            method: "GET", path: "/v1/node", auth: "device",
            summary: "What this Mac advertises to its peers.",
            response: .of(ControlAPI.NodeAdvertisement(
                name: "Mac Studio", platform: "macos-apple-silicon",
                profile: .init(
                    chip: "Apple M3 Max", memoryGB: 38.7, bandwidthGBps: 300, gpuCores: 40
                ),
                capabilities: [.init(
                    id: "llm-qwen3-coder-30b", kind: "llm", ready: true, peakGB: 20.3,
                    typicalSeconds: nil, detail: "Loaded at 16K context"
                )],
                metrics: .init(
                    queueDepth: 0, headroomGB: 8.9, gpuUtilPct: 12, memoryUsedPct: 52
                )
            ))
        ),
    ]

    // MARK: The Chat tab's agent sessions

    /// One session per engine, and it is the one the owner is looking at. Every route here
    /// runs commands on this Mac, so every one of them is full scope — and none is reachable
    /// with the swarm secret, which is a node's credential and not a person's. That second
    /// 403 is its own sentence, so it rides in `errorVariants` beside the chat-only one.
    static let agentRoutes: [Route] = [
        Route(
            method: "GET", path: "/agent/sessions", auth: "device",
            summary: "Every agent engine, running or not, as the Mac has it right now.",
            response: .of(ControlAPI.AgentSessionList(
                sessions: [exampleCodexSession, examplePiSession]
            )),
            errorVariants: agentErrorVariants()
        ),
        Route(
            method: "GET", path: "/agent/sessions/{engine}", auth: "device",
            summary: "One session: the summary, the transcript, and what is waiting. "
                + "`?since=<seq>&epoch=<epoch>` answers only what changed after that point; "
                + "`?limit=` caps the rows (default 500, at most 2000).",
            response: .of(ControlAPI.AgentSessionDetail(
                session: exampleCodexSession,
                items: exampleAgentItems,
                approvals: [exampleAgentApproval],
                seq: 41, epoch: exampleCodexEpoch,
                complete: true, omitted: 0
            )),
            errors: [
                400: AgentSessionError.badQuery("since").localizedDescription,
                404: AgentSessionError.unknownEngine("claude").localizedDescription,
            ],
            errorVariants: agentErrorVariants()
        ),
        Route(
            method: "POST", path: "/agent/sessions/{engine}/start", auth: "device",
            summary: "Start the engine, exactly as opening its tab does — or as the Mac's "
                + "own Retry does, from `failed`. Idempotent.",
            response: .of(exampleCodexSession),
            errors: [
                404: AgentSessionError.unknownEngine("claude").localizedDescription,
                409: AgentSessionError.workingDirectoryIsTheMacsToPick,
            ],
            errorVariants: agentErrorVariants([
                (409, "stopping", AgentSessionError.stillStopping("pi").localizedDescription),
            ])
        ),
        Route(
            method: "POST", path: "/agent/sessions/{engine}/new", auth: "device",
            summary: "Start a fresh thread, stopping a turn in flight first. The Mac's own "
                + "transcript clears with it, and `/events` sends a `reset`.",
            response: .of(exampleFreshCodexSession),
            errors: [
                404: AgentSessionError.unknownEngine("claude").localizedDescription,
                409: AgentSessionError.notRunning("pi").localizedDescription,
            ],
            errorVariants: agentErrorVariants()
        ),
        Route(
            method: "DELETE", path: "/agent/sessions/{engine}", auth: "device",
            summary: "Stop the engine. Its sidecar goes with it.",
            response: .of(examplePiSession),
            errors: [404: AgentSessionError.unknownEngine("claude").localizedDescription],
            errorVariants: agentErrorVariants()
        ),
        Route(
            method: "POST", path: "/agent/sessions/{engine}/messages", auth: "device",
            summary: "Send a turn. 202: it is on the Mac's screen, and the answer arrives "
                + "on /events. `model` is sticky: it becomes the engine's model, as picking it "
                + "in the Mac's own menu does.",
            request: .of(ControlAPI.AgentMessageRequest(
                text: "Run the tests and fix whatever the first failure is.",
                model: "local/qwen3-coder-30b"
            )),
            response: .of(ControlAPI.AgentMessageAccepted(
                itemID: "7C3E1A50-6B2D-4F19-8E44-0A1B2C3D4E5F"
            )),
            errors: [
                400: AgentSessionError.unknownModel("gpt-5").localizedDescription,
                404: AgentSessionError.unknownEngine("claude").localizedDescription,
                409: AgentSessionError.notRunning("codex").localizedDescription,
            ],
            errorVariants: agentErrorVariants([
                (409, "turn in progress", AgentSessionError.waitForTheTurn),
            ])
        ),
        Route(
            method: "POST", path: "/agent/sessions/{engine}/interrupt", auth: "device",
            summary: "Stop the turn in flight. The turn still ends through its own events.",
            response: .of(exampleCodexSession),
            errors: [
                404: AgentSessionError.unknownEngine("claude").localizedDescription,
                409: AgentSessionError.notRunning("codex").localizedDescription,
            ],
            errorVariants: agentErrorVariants()
        ),
        Route(
            method: "POST", path: "/agent/sessions/{engine}/approvals/{id}", auth: "device",
            summary: "Answer a held call. The runtime is told once, whichever side answers.",
            request: .of(ControlAPI.AgentApprovalDecision(decision: "accept")),
            response: .of(ControlAPI.AgentApprovalResult(
                id: exampleAgentApproval.id, decision: "accepted",
                session: exampleAnsweredCodexSession
            )),
            errors: [
                400: AgentSessionError.unknownDecision("maybe").localizedDescription,
                404: AgentSessionError.unknownApproval(exampleAgentApproval.id)
                    .localizedDescription,
                409: AgentSessionError.alreadyAnsweredOnTheMac,
            ],
            errorVariants: agentErrorVariants([
                (409, "still screening", AgentSessionError.stillBeingScreened),
                (409, "engine stopped", AgentSessionError.notRunning("pi").localizedDescription),
            ])
        ),
    ]

    /// The refusals every agent route shares beyond its status's first sentence: the
    /// swarm's own 403.
    static func agentErrorVariants(
        _ particular: [(Int, String, String)] = []
    ) -> [(Int, String, String)] {
        [(403, "swarm", ControlServer.agentsAreNotForPeers)] + particular
    }

    // MARK: Models for the phone

    /// What a phone runs when this Mac is out of reach, fetched and served by the Mac so
    /// the phone never leaves the tailnet. Full scope only, and never the swarm — whose 403
    /// is its own sentence, like the agent routes'. The examples are built from the real
    /// catalogue, so a pin changed on this side changes the fixtures with it.
    static let phoneModelRoutes: [Route] = [
        Route(
            method: "GET", path: "/ondevice/models", auth: "device",
            summary: "The models a phone can run by itself, pinned to exact bytes, and the "
                + "state of this Mac's copy of each: absent, downloading, ready or failed.",
            response: .of(examplePhoneModels),
            errorVariants: phoneModelErrorVariants
        ),
        Route(
            method: "POST", path: "/ondevice/models/{id}/prepare", auth: "device",
            summary: "Have the Mac fetch the pinned file from Hugging Face and verify it. "
                + "202 with the entry while it is on its way — started now, resumed, or "
                + "already running — and 200 once it is ready. Progress arrives on /events "
                + "as `download` frames with the id `ondevice:<id>`. `?verify=1` has the Mac "
                + "hash a ready copy again first: call it once when the file you fetched does "
                + "not hash to `sha256`, then fetch from zero.",
            response: .of(PhoneModelService.wire(
                PhoneModelCatalog.gemma4E2B,
                state: .downloading(bytesReceived: 0, bytesPerSecond: 0, stage: .fetching)
            )),
            errors: [
                400: ControlServer.phoneModelVerifyValues,
                404: ControlServer.noSuchPhoneModel,
                503: examplePhoneModelDriveMissing,
                507: examplePhoneModelNoSpace.reason,
            ],
            errorVariants: phoneModelErrorVariants
        ),
        Route(
            method: "GET", path: "/ondevice/models/{id}/file", auth: "device",
            summary: "The verified file. Answers bytes, not JSON: `application/octet-stream`, "
                + "`Content-Length`, `Accept-Ranges: bytes`, an `ETag` that is the quoted "
                + "SHA-256, `X-Content-SHA256` and `Content-Disposition: attachment`. 206 for "
                + "a `Range` — `bytes=N-` resumes with exactly the rest — and 304 for a "
                + "matching `If-None-Match`. Resume with `If-Range` set to the `ETag`: a 200 "
                + "to that request means the file is not the one you started, so discard the "
                + "partial and keep the whole body.",
            // No response example: the answer is the file. What a client has to get right
            // is the headers and the resume, which the summary and the refusals carry.
            errors: [
                404: ControlServer.noSuchPhoneModel,
                409: ControlServer.phoneModelNotReady,
                416: ControlServer.rangeOutsideFile,
                503: examplePhoneModelDriveMissing,
            ],
            errorVariants: phoneModelErrorVariants
        ),
        Route(
            method: "DELETE", path: "/ondevice/models/{id}", auth: "device",
            summary: "Delete the Mac's copy and any partial download, stopping a fetch in "
                + "flight. Idempotent; answers the entry as it now is.",
            response: .of(PhoneModelService.wire(PhoneModelCatalog.qwen35_2B, state: .absent)),
            errors: [
                404: ControlServer.noSuchPhoneModel,
                503: examplePhoneModelDriveMissing,
            ],
            errorVariants: phoneModelErrorVariants
        ),
    ]

    static let phoneModelErrorVariants: [(Int, String, String)] = [
        (403, "swarm", ControlServer.phoneModelsAreNotForPeers),
    ]

    /// The default fetched and verified; the fallback for a phone short on memory not
    /// fetched at all, and with no benchmark behind it, so the list shows what an entry
    /// nobody has measured looks like; the larger one stopped partway, so it shows a
    /// failure's `reason`, `failure` and `fraction` populated.
    static let examplePhoneModels = ControlAPI.PhoneModelList(models: [
        PhoneModelService.wire(PhoneModelCatalog.qwen35_2B, state: .ready),
        PhoneModelService.wire(PhoneModelCatalog.qwen35_08B, state: .absent),
        PhoneModelService.wire(PhoneModelCatalog.gemma4E2B, state: .failed(
            PhoneModelStore.failure(
                for: URLError(.networkConnectionLost), entry: PhoneModelCatalog.gemma4E2B,
                partial: 837_379_064
            )
        )),
    ])

    static let examplePhoneModelMismatch = PhoneModelStore.failure(
        for: ModelDownloader.DownloadError.checksumMismatch(
            file: PhoneModelCatalog.gemma4E2B.file,
            expected: PhoneModelCatalog.gemma4E2B.sha256,
            actual: String(repeating: "0", count: 64)
        ),
        entry: PhoneModelCatalog.gemma4E2B, partial: 0
    )

    /// A placeholder drive name, never a real one.
    static let examplePhoneModelDriveMissing = PhoneModelStore.driveMissingSentence("External SSD")

    static let examplePhoneModelNoSpace = PhoneModelStore.failure(
        for: ModelDownloader.DownloadError.insufficientDiskSpace(
            needed: Bytes(PhoneModelCatalog.gemma4E2B.sizeBytes), available: .gib(12)
        ),
        entry: PhoneModelCatalog.gemma4E2B, partial: 0
    )

    // MARK: Images, meshes and video

    static let mediaRoutes: [Route] = [
        Route(
            method: "GET", path: "/image/models", auth: "device",
            summary: "The image models here, and what each would peak at.",
            response: .of([ControlAPI.ImageModel(
                id: "flux2-klein", name: "FLUX.2 klein", author: "Black Forest Labs",
                license: "Apache-2.0", summary: "Fast local text-to-image.",
                parameters: "4B", blocks: 19, defaultSteps: 8, isGated: false,
                recommendation: exampleImagePlan
            )])
        ),
        Route(
            method: "POST", path: "/image/plan", auth: "device",
            summary: "Phase-by-phase memory for a given size, steps and precision.",
            request: .of(exampleImageRequest), response: .of(exampleImagePlan)
        ),
        Route(
            method: "POST", path: "/image/generate", auth: "device",
            summary: "Render an image, locally or on a paired node.",
            request: .of(exampleImageRequest),
            response: .of(ControlAPI.ImageResponse(
                path: "/Users/you/Pictures/Silicon/lisbon-0001.png", elapsedSeconds: 11.4,
                peakMemoryBytes: 13_958_643_712, predictedPeakBytes: 14_200_000_000,
                model: "FLUX.2 klein",
                mediaID: exampleImageMediaID,
                mediaURL: "/media/\(exampleImageMediaID)"
            ))
        ),
        Route(
            method: "GET", path: "/mesh/models", auth: "device",
            summary: "The 3D models here, and what they cost to run.",
            response: .of([ControlAPI.MeshModel(
                id: "hunyuan3d-2", name: "Hunyuan3D 2", author: "Tencent",
                summary: "Image to textured mesh.", outputs: "GLB, OBJ",
                typicalDuration: "5 minutes", peakBytes: 13_958_643_712,
                weightsBytes: 6_442_450_944, isInstalled: true, installDetail: "Installed"
            )])
        ),
        Route(
            method: "POST", path: "/mesh/plan", auth: "device",
            summary: "Will this mesh job fit, here or on the node?",
            request: .of(exampleMeshRequest),
            response: .of(ControlAPI.MeshPlan(
                model: "Hunyuan3D 2", peakBytes: 13_958_643_712, peakPhase: "Texture bake",
                budgetBytes: 29_200_000_000, verdict: "fits", isRemote: false,
                phases: [.init(name: "Texture bake", detail: "2048px", residentBytes: 13_958_643_712)],
                suggestions: [], notes: []
            ))
        ),
        Route(
            method: "POST", path: "/mesh/generate", auth: "device",
            summary: "Turn an image into a mesh.",
            request: .of(exampleMeshRequest),
            response: .of(ControlAPI.MeshResponse(
                glbPath: "/Users/you/Models/kettle.glb",
                objPath: "/Users/you/Models/kettle.obj",
                elapsedSeconds: 323.7, model: "Hunyuan3D 2",
                mediaID: exampleMeshMediaID,
                mediaURL: "/media/\(exampleMeshMediaID)",
                objMediaID: exampleMeshOBJMediaID
            ))
        ),
        Route(
            method: "GET", path: "/video/models", auth: "device",
            summary: "The video models, and which machine can run each.",
            response: .of([ControlAPI.VideoModel(
                id: "hailuo-h3", name: "Hailuo H3", summary: "Text and image to video.",
                typicalDuration: "4 minutes", supportsImageInput: true,
                supportedSeconds: [5, 10], available: true, node: "silicon-node",
                // Present in the fixture on purpose. All three are optional on the wire —
                // an older node advertises none of them — and a generated client that has
                // never seen them populated ends up hard-coding the Mac's defaults, which
                // is exactly what the phone was doing before this export carried them.
                supportedParameters: ["h3_turbo", "h3_steps", "negative_prompt"],
                supportedResolutions: ["480p", "720p", "1080p"],
                supportsNegativePrompt: true
            )])
        ),
        Route(
            method: "GET", path: "/video/queue", auth: "device",
            summary: "The render queue and what is running.",
            response: .of(exampleVideoQueue)
        ),
        Route(
            method: "POST", path: "/video/queue", auth: "device",
            summary: "Add prompts to the queue without holding a connection.",
            request: .of(ControlAPI.VideoQueueRequest(
                prompts: ["A tram climbing Alfama at dawn"], title: "Lisbon", variations: 2
            )),
            response: .of(exampleVideoQueue)
        ),
        Route(
            method: "POST", path: "/video/queue/control", auth: "device",
            summary: "One of six verbs on the queue: pause, resume, retry, remove, "
                + "stop_following, clear_finished. There is no cancel.",
            request: .of(ControlAPI.VideoQueueControl(action: "pause")),
            // Every verb the Mac accepts, with the fields each one needs. A client that
            // has only seen `pause` cannot tell that four of them require an `id`, that
            // `confirmNewRender` exists at all, or that `cancel` is deliberately not here.
            requests: [
                ("pause", .of(ControlAPI.VideoQueueControl(action: "pause"))),
                ("resume", .of(ControlAPI.VideoQueueControl(action: "resume"))),
                // Reconnects to the same node job when it can. `confirmNewRender: true` is
                // the caller saying it has checked the node and accepts a *second* render —
                // which is the only way past an uncertain submission.
                ("retry", .of(ControlAPI.VideoQueueControl(
                    action: "retry", id: "9C2F-0003", confirmNewRender: true
                ))),
                ("remove", .of(ControlAPI.VideoQueueControl(action: "remove", id: "9C2F-0003"))),
                // Stops this Mac following the clip and pauses the queue. The node may
                // still be rendering it, which is why this is not a cancel.
                ("stop_following", .of(ControlAPI.VideoQueueControl(
                    action: "stop_following", id: "9C2F-0001"
                ))),
                ("clear_finished", .of(ControlAPI.VideoQueueControl(action: "clear_finished"))),
            ],
            response: .of(exampleVideoQueue),
            errors: [400: ControlServer.unknownQueueAction]
        ),
        Route(
            method: "POST", path: "/video/generate", auth: "device",
            summary: "Render one clip and wait for it. At most eight of these at once.",
            request: .of(ControlAPI.VideoGenerateRequest(
                prompt: "A tram climbing Alfama at dawn", modelID: "hailuo-h3", seconds: 5,
                negativePrompt: "blurry, watermark, text overlay",
                // A device names its starting still this way and never by path. The Mac
                // resolves it before the render sees the request.
                uploadID: exampleUploadID
            )),
            response: .of(ControlAPI.VideoResponse(
                file: "/Users/you/Movies/Silicon/lisbon-0001.mp4", node: "silicon-node",
                model: "hailuo-h3", elapsedSeconds: 244.1,
                mediaID: exampleClipMediaID,
                mediaURL: "/media/\(exampleClipMediaID)",
                thumbnailMediaID: examplePosterMediaID
            )),
            errors: [
                404: ControlServer.expiredSubject,
                429: "Too many synchronous video requests. No clip was added. Use POST "
                    + "/video/queue to save work without holding a connection, then GET "
                    + "/video/queue to follow it.",
            ]
        ),
        Route(
            method: "GET", path: "/media/{id}", auth: "device",
            summary: "The file itself. Answers bytes, not JSON: the content type of the "
                + "result, `Accept-Ranges: bytes`, an `ETag`, 206 for a `Range` and 304 "
                + "for a matching `If-None-Match`. A chat-only device may fetch preview "
                + "images but not the renders themselves.",
            // No response example, because there is no JSON to give one of. The ids come
            // from `mediaID` and `thumbnailMediaID` on the routes above; a client never
            // constructs one and never parses one.
            errors: [
                403: ControlServer.fullResultsNeedFullControl,
                404: ControlServer.noSuchMedia,
                416: ControlServer.rangeOutsideFile,
            ]
        ),
        Route(
            method: "POST", path: "/uploads", auth: "device",
            summary: "Send a picture or a short clip, and get back the two ids that let a "
                + "render start from it. Raw bytes or multipart; at most 24 MiB; kept for "
                + "seven days.",
            // Deliberately no request example: the body is a file, not a shape. What a
            // client has to get right is the headers and the cap, which the summary and
            // the refusals below carry.
            response: .of(ControlAPI.UploadResponse(
                uploadID: exampleUploadID, mediaID: exampleUploadMediaID,
                bytes: 2_118_404, contentType: "image/jpeg",
                mediaURL: "/media/\(exampleUploadMediaID)",
                expiresAt: "2026-09-25T09:41:00Z"
            )),
            errors: [
                400: "That upload has no body in it.",
                413: "That request body is larger than this device may send "
                    + "(\(BuddyUploads.maximumBytes) bytes).",
                415: ControlServer.unreadableUpload,
                500: ControlServer.uploadNotSaved,
            ]
        ),
        Route(
            method: "GET", path: "/swarm/peers/{name}/status", auth: "device",
            summary: "One peer asked now rather than remembered: its `/v1/node` and "
                + "`/v1/gguf`, fetched with this Mac's credential for it. The credential "
                + "is never in the answer.",
            response: .of(ControlAPI.PeerNodeStatus(
                name: "silicon-node", baseURL: "http://silicon-node:8790", reachable: true,
                platform: "windows-cuda", hardware: "NVIDIA GeForce RTX 3090 Ti",
                totalMemoryGB: 24, usedMemoryGB: 9.4, headroomGB: 14.6,
                gpuUtilization: 0.38, queueDepth: 1,
                capabilities: [
                    .init(id: "text-to-video", kind: "video", ready: true),
                    .init(id: "image-to-mesh", kind: "mesh", ready: true),
                ],
                gguf: .init(
                    running: true, model: "qwen3.8-27b-q4_k_m.gguf",
                    // The one field `GET /swarm` cannot carry.
                    adapter: "bonsai-27b-v3.lora.gguf", engine: "stock",
                    contextLength: 65_536, uptimeSeconds: 4_281,
                    installedModels: [
                        "qwen3.8-27b-q4_k_m.gguf", "qwen3-coder-30b-q4_k_m.gguf",
                    ],
                    adapters: ["bonsai-27b-v3.lora.gguf"]
                )
            )),
            errors: [404: "No peer named silicon-node in this Mac's swarm registry."]
        ),
    ]


    // MARK: - Shared examples

    // MARK: The agent sessions' shapes

    /// Two models, one on each side of the swarm, because `where` is the field a picker on
    /// a phone actually shows and a list with one entry never proves it carries.
    static let exampleAgentModels = [
        ControlAPI.AgentModelChoice(
            id: "local/qwen3-coder-30b",
            label: "Qwen3-Coder 30B A3B — Q4_K_M — serving now", where: "This Mac"
        ),
        ControlAPI.AgentModelChoice(
            id: "node/studio/qwen3.8-27b", label: "Qwen3.8 27B", where: "studio"
        ),
    ]

    /// Placeholders, as every id here is: which transcript a session's rows belong to.
    static let exampleCodexEpoch = "4B1D6C3E-2A9F-4E70-8D51-7C6B5A493827"
    static let exampleFreshEpoch = "9E2F7A10-3C4B-4D58-A6E1-0B2C3D4E5F60"
    static let examplePiEpoch = "1A2B3C4D-5E6F-4071-8293-A4B5C6D7E8F9"

    static let exampleCodexSession = ControlAPI.AgentSessionSummary(
        engine: "codex", state: "running",
        threadID: "0199F2C1-4A7E-4C3B-9D15-6E2A8B0C1D3F", epoch: exampleCodexEpoch,
        model: "local/qwen3-coder-30b", modelChoices: exampleAgentModels,
        cwd: "~/Developer/lisbon", approvals: "screened", sandbox: "workspace-write",
        turnActive: true, pendingApprovals: 1, itemCount: 5,
        updatedAt: "2026-09-19T10:12:44Z"
    )

    /// The same session a moment after `POST /agent/sessions/codex/new`: same engine, same
    /// folder, a new epoch, nothing in it.
    static let exampleFreshCodexSession = ControlAPI.AgentSessionSummary(
        engine: "codex", state: "running", threadID: nil, epoch: exampleFreshEpoch,
        model: "local/qwen3-coder-30b", modelChoices: exampleAgentModels,
        cwd: "~/Developer/lisbon", approvals: "screened", sandbox: "workspace-write",
        turnActive: false, pendingApprovals: 0, itemCount: 0,
        updatedAt: "2026-09-19T10:13:02Z"
    )

    /// And a moment after the approval below was answered: the count is what changed, and
    /// it is what the badge on a phone is drawn from.
    static let exampleAnsweredCodexSession = ControlAPI.AgentSessionSummary(
        engine: "codex", state: "running",
        threadID: "0199F2C1-4A7E-4C3B-9D15-6E2A8B0C1D3F", epoch: exampleCodexEpoch,
        model: "local/qwen3-coder-30b", modelChoices: exampleAgentModels,
        cwd: "~/Developer/lisbon", approvals: "screened", sandbox: "workspace-write",
        turnActive: true, pendingApprovals: 0, itemCount: 5,
        updatedAt: "2026-09-19T10:12:51Z"
    )

    /// A stopped engine is still listed, because a phone that cannot see one cannot offer
    /// to start it — and says what would stand between it and the Mac if it were started:
    /// with the guardrail off, Pi asks nobody anything.
    static let examplePiSession = ControlAPI.AgentSessionSummary(
        engine: "pi", state: "stopped", threadID: nil, epoch: examplePiEpoch,
        model: "local/qwen3-coder-30b", modelChoices: exampleAgentModels,
        cwd: "~/Library/Application Support/SiliconOptimizer/pi/workspace",
        approvals: "unattended", sandbox: "none",
        turnActive: false, pendingApprovals: 0, itemCount: 0,
        updatedAt: "2026-09-19T09:58:10Z"
    )

    /// Codex before the owner has picked a folder: no `cwd` at all, rather than a path
    /// under the home folder that nobody chose.
    static let exampleUnplacedCodexSession = ControlAPI.AgentSessionSummary(
        engine: "codex", state: "stopped", threadID: nil, epoch: exampleCodexEpoch,
        model: "local/qwen3-coder-30b", modelChoices: exampleAgentModels,
        cwd: nil, approvals: "asked", sandbox: "read-only",
        turnActive: false, pendingApprovals: 0, itemCount: 0,
        updatedAt: "2026-09-19T09:58:10Z"
    )

    /// One turn, in the five row kinds a reader actually meets: what was asked, what the
    /// model thought, what it said, what it ran, and what it changed. The command's output
    /// is the tail of a longer log, and says so.
    static let exampleAgentItems = [
        ControlAPI.AgentItem(
            id: "7C3E1A50-6B2D-4F19-8E44-0A1B2C3D4E5F", kind: "user",
            text: "Run the tests and fix whatever the first failure is.",
            model: "local/qwen3-coder-30b", at: "2026-09-19T10:12:31Z"
        ),
        ControlAPI.AgentItem(
            id: "item_reasoning_1", kind: "reasoning",
            text: "Run the suite first, then read the first failure.",
            at: "2026-09-19T10:12:33Z"
        ),
        ControlAPI.AgentItem(
            id: "item_message_1", kind: "assistant",
            text: "Running the suite now.", at: "2026-09-19T10:12:35Z"
        ),
        ControlAPI.AgentItem(
            id: "item_command_1", kind: "command", text: "swift test --filter Lisbon",
            output: "…\nTest Suite 'LisbonTests' failed.\n"
                + "1 test failed: itineraryFitsInThreeDays",
            truncated: true, status: "completed", at: "2026-09-19T10:12:38Z"
        ),
        // No status: Codex's `fileChange` item has none, and the contract does not invent
        // one for it.
        ControlAPI.AgentItem(
            id: "item_patch_1", kind: "fileChange",
            text: "Sources/Lisbon/Itinerary.swift", at: "2026-09-19T10:12:44Z"
        ),
    ]

    /// Held, screened, and left to a person: the only kind of approval a phone is shown.
    static let exampleAgentApproval = ControlAPI.AgentApproval(
        id: "5D8B2F01-9A3C-4E67-8B21-0C4D5E6F7A81", kind: "command",
        summary: "rm -rf .build",
        reason: "Codex asks before running a command in this folder.",
        screening: ControlAPI.AgentScreening(
            verdict: "confirm", summary: "Jev: review: destructive"
        ),
        requestedAt: "2026-09-19T10:12:36Z"
    )

    /// A placeholder code, never a real one: these files are committed, copied between
    /// repositories and read by generators, and a live six-digit code has five minutes in
    /// which it admits whoever types it. Six zeroes is the one value that is obviously not
    /// an answer.
    static let exampleInvitation = ControlAPI.BuddyInvitationResponse(
        code: "000000", host: "100.64.0.9", port: 8788,
        expiresAt: "2026-09-18T09:17:44Z", scope: "chat"
    )

    static let exampleDevice = ControlAPI.BuddyDeviceSummary(
        id: "7A1E0C6E-2C6A-4F4E-9F1E-0B2D3C4A5B6C", name: "Galaxy S24 Ultra",
        platform: "android", scope: "full", pairedAt: "2026-09-18T09:12:44Z",
        lastSeen: "2026-09-18T09:40:02Z"
    )

    /// Built from the real feature list rather than typed out, so a feature added to the
    /// enum reaches the generated clients instead of being forgotten here. Note what is not
    /// in the shape at all: there is no field for the API key, and there never will be.
    static let exampleJevStatus: ControlAPI.JevStatus = {
        var status = ControlAPI.JevStatus.fixture(enabled: true)
        status.keySet = true
        status.monthlyBudgetUSD = 5
        status.budgetRemainingUSD = 4.87
        status.calls = 312
        status.inputTokens = 3_104_882
        status.estimatedUSD = 0.13
        status.models = ["jev-1.13.0": 312]
        status.monthlyUSD = ["2026-08": 0.09, "2026-09": 0.13]
        status.features = status.features.map { feature in
            var copy = feature
            guard copy.id == "decideTool" else { return copy }
            copy.available = true
            copy.calls = 312
            copy.inputTokens = 3_104_882
            copy.estimatedUSD = 0.13
            return copy
        }
        return status
    }()

    /// Two screenings: one an agent was allowed to run, one it was not. The shape is the
    /// point — a phone approving tool calls reads `screening` off an approval object with
    /// exactly these fields — and so is what the shape cannot carry. There is no field here
    /// for the command, the arguments or the request, so a phone reading this learns what
    /// the guardrail decided and never what anyone typed.
    static let exampleGuardrailScreenings = ControlAPI.GuardrailScreenings(
        available: true,
        questions: [
            "outside_working_tree", "destructive", "exfiltrates", "escalates_privileges",
            "spends_money", "contradicts_request", "driven_by_tool_output", "irreversible",
            "harm",
        ],
        screenings: [
            .init(
                at: "2026-09-18T14:02:11Z", engine: "codex",
                screening: .init(verdict: "act", reasons: [], latencyMS: 212),
                bands: [
                    "outside_working_tree": "clear", "destructive": "clear",
                    "exfiltrates": "clear", "escalates_privileges": "clear",
                    "spends_money": "clear", "contradicts_request": "clear",
                    "driven_by_tool_output": "clear", "irreversible": "clear",
                    "harm": "clear",
                ]
            ),
            .init(
                at: "2026-09-18T14:04:38Z", engine: "pi",
                screening: .init(
                    verdict: "block", reasons: ["destructive", "harm"], latencyMS: 240
                ),
                bands: [
                    "outside_working_tree": "plausible", "destructive": "fired",
                    "exfiltrates": "clear", "escalates_privileges": "clear",
                    "spends_money": "clear", "contradicts_request": "plausible",
                    "driven_by_tool_output": "clear", "irreversible": "fired",
                    "harm": "fired",
                ]
            ),
        ]
    )

    /// A run that found a floor for one kind of answer and not the other, which is the
    /// interesting shape for a generated client to have seen: both flags are in the fixture.
    static let exampleJevCalibration = ControlAPI.JevCalibration(
        modelID: "qwen3-coder-30b-q4_k_m",
        modelName: "Qwen3-Coder 30B A3B",
        jevModel: "jev-1.13.0",
        date: "2026-09-18T09:41:00Z",
        cases: 40, builtInCases: 40, userCases: 0, comparisons: 80,
        agreement: [
            .init(kind: "noul", compared: 26, agreed: 22, rate: 0.846),
            .init(kind: "choice", compared: 30, agreed: 27, rate: 0.9),
            .init(kind: "score", compared: 24, agreed: 19, rate: 0.792),
        ],
        overallAgreementRate: 0.85,
        floors: .init(
            choiceConfidence: 0.72, scoreConfidence: 0.81, noulLow: 0.25, noulHigh: 0.75
        ),
        escalationRate: 0.21,
        choiceFloorMeasured: true,
        scoreFloorMeasured: true,
        noulBandMeasured: false,
        bins: [
            .init(lower: 0.4, upper: 0.5, count: 6, agreed: 3, meanConfidence: 0.45, agreementRate: 0.5),
            .init(lower: 0.7, upper: 0.8, count: 18, agreed: 16, meanConfidence: 0.74, agreementRate: 0.889),
            .init(lower: 0.9, upper: 1.0, count: 30, agreed: 29, meanConfidence: 0.96, agreementRate: 0.967),
        ],
        inputTokens: 31_204,
        estimatedUSD: 0.0013,
        notes: [
            "Too few noul disagreements to place a middle band, so the cascade keeps the default one.",
        ]
    )

    static let exampleStatus = ControlAPI.Status(
        state: "running", loadedModelID: "qwen3-coder-30b",
        loadedModelName: "Qwen3-Coder 30B A3B", contextLength: 16_384,
        expertStreaming: false, lastGenerationTokensPerSecond: 89.4
    )

    /// What `POST /load` answers when the load is slower than the request's patience: the
    /// live status, the same shape, and the load still running behind it.
    static let exampleLoadingStatus = ControlAPI.Status(
        state: "Loading weights… 42%", loadedModelID: nil, loadedModelName: nil,
        contextLength: nil, expertStreaming: false, lastGenerationTokensPerSecond: nil
    )

    /// A load that failed, as a phone meets it: one line to show, and the facts behind it
    /// for the screen underneath. This is the shape the whole change exists for — `state`
    /// used to be the last eight lines of a runtime log.
    static let exampleFailedStatus = ControlAPI.Status(
        state: "llama-server was killed (signal 9) after 8 seconds, which usually means "
            + "the system reclaimed its memory.",
        loadedModelID: nil, loadedModelName: nil, contextLength: nil,
        expertStreaming: false, lastGenerationTokensPerSecond: nil,
        failure: ControlAPI.LoadFailure(
            reason: "killed",
            detail: "load_tensors: loading model tensors\n"
                + "loaded multimodal model, 'mmproj-Q8_0.gguf'",
            runtime: "llama.cpp", exitStatus: nil, signal: 9, wasReplaced: false,
            at: "2026-09-19T11:04:38Z"
        )
    )

    /// The other three endings a client has to be able to tell apart. `wasReplaced` is the
    /// one that is not a fault at all — somebody asked for something else.
    static let exampleReplacedStatus = ControlAPI.Status(
        state: "llama-server was replaced by another load (Qwen3-Coder 30B).",
        loadedModelID: nil, loadedModelName: nil, contextLength: nil,
        expertStreaming: false, lastGenerationTokensPerSecond: nil,
        failure: ControlAPI.LoadFailure(
            reason: "replaced", detail: nil, runtime: "llama.cpp",
            exitStatus: nil, signal: 15, wasReplaced: true, at: "2026-09-19T11:04:38Z"
        )
    )

    static let exampleCancelledStatus = ControlAPI.Status(
        state: "llama-server was stopped by an unload before it finished loading.",
        loadedModelID: nil, loadedModelName: nil, contextLength: nil,
        expertStreaming: false, lastGenerationTokensPerSecond: nil,
        failure: ControlAPI.LoadFailure(
            reason: "cancelled", detail: nil, runtime: "llama.cpp",
            exitStatus: nil, signal: 15, wasReplaced: false, at: "2026-09-19T11:04:38Z"
        )
    )

    static let exampleTimedOutStatus = ControlAPI.Status(
        state: "llama-server never answered in 10 minutes.",
        loadedModelID: nil, loadedModelName: nil, contextLength: nil,
        expertStreaming: false, lastGenerationTokensPerSecond: nil,
        failure: ControlAPI.LoadFailure(
            reason: "timedOut", detail: "llama_context: constructing llama_context",
            runtime: "llama.cpp", exitStatus: nil, signal: nil, wasReplaced: false,
            at: "2026-09-19T11:04:38Z"
        )
    )

    /// The same failure as a device paired for chat — or a peer node — is answered: what
    /// happened, without the runtime's own log.
    static let exampleWithheldStatus = exampleFailedStatus.withoutPrivilegedDetail

    static let exampleMetrics = ControlAPI.ChatMetrics(
        promptTokens: 412, generatedTokens: 96, tokensPerSecond: 89.4, timeToFirstToken: 0.31
    )

    /// The frame a stream ends with when answer verification is on.
    ///
    /// `escalatedTo` is null here on purpose, and always is on a stream: by the time the
    /// verdict is known the tokens are on the reader's screen, so the stream says what it
    /// found and suggests the re-run instead of swapping the message out from under them.
    /// `POST /chat`, which has shown the caller nothing, does the re-run itself and reports
    /// the model in its `verification.escalatedTo`.
    /// The same shape on `POST /chat`, where a re-run really happened.
    static let exampleEscalatedVerdict = ControlAPI.ChatVerdict(
        verdict: "escalate",
        reasons: ["The reply does not answer what was asked."],
        escalatedTo: "node/studio/qwen3.8-27b"
    )

    static let exampleVerdict = ControlAPI.ChatVerdict(
        verdict: "escalate",
        reasons: ["The reply stops mid-thought and the token budget ran out."],
        escalatedTo: nil,
        suggestion: "Send this again on cloud/openai/gpt-5.5 for a stronger answer — or use "
            + "POST /chat, which re-runs flagged answers itself."
    )

    static let exampleChatRequest = ControlAPI.ChatRequest(
        messages: [.init(role: "user", content: "Three days in Lisbon — what would you do?")],
        temperature: 0.7, maxTokens: 1024
    )

    static let exampleConversationSummary = ControlAPI.ConversationSummary(
        id: "3F5C1A88-9C1D-4E2B-8A70-1D2E3F405162", title: "Weekend in Lisbon",
        updatedAt: "2026-09-18T09:41:12Z", messageCount: 2
    )

    static let examplePlan = ControlAPI.Plan(
        verdict: "fits", residentBytes: 21_800_000_000, budgetBytes: 29_200_000_000,
        weightsBytes: 20_401_094_656, expertsBytes: 0, kvCacheBytes: 1_073_741_824,
        computeBytes: 325_000_000, streamedFromDiskBytes: 0,
        suggestions: [.init(
            title: "Halve the context",
            detail: "8K instead of 16K frees half a gigabyte.",
            savingBytes: 536_870_912, cost: "Shorter memory in long chats"
        )],
        notes: ["Measured on this Mac's own disk speed."]
    )

    static let exampleCatalogModel = ControlAPI.CatalogModel(
        id: "qwen3-coder-30b", name: "Qwen3-Coder 30B A3B", author: "Qwen",
        license: "Apache-2.0", summary: "A coding model that fits a 36 GB Mac.",
        category: "code", parameters: "30B", activeParameters: "3B", isMoE: true,
        capabilities: ["code", "tools"], rating: 5, maxContext: 262_144,
        quantizations: ["Q4_K_M", "Q5_K_M", "Q8_0"],
        recommendation: .init(
            quantization: "Q4_K_M", contextLength: 16_384, expertSlots: nil,
            estimatedGenerationTokensPerSecond: 89, estimatedPromptTokensPerSecond: 1120,
            downloadBytes: 20_401_094_656, plan: examplePlan,
            rationale: "The strongest coding model inside this Mac's budget."
        )
    )

    /// What `GET /recommend?task=…` adds to the same shape: why this one, and the rest of
    /// the top three. Both are optional and absent without a task, which is why the
    /// `/catalog` fixture above is the plain one — a generated client has to handle both.
    static let exampleRecommendedModel: ControlAPI.CatalogModel = {
        var model = exampleCatalogModel
        model.reason = "needs code and tool calling; fits at Q4_K_M at ~89 tok/s"
        model.note = "Jev preferred Qwen3.8 27B; it is ranked lower because it runs less "
            + "well on this Mac."
        model.followedJev = true
        var runnerUp = exampleCatalogModel
        runnerUp.id = "qwen3.8-27b"
        runnerUp.name = "Qwen3.8 27B"
        runnerUp.reason = "needs code and tool calling; fits at Q6_K at ~24 tok/s"
        model.alternatives = [runnerUp]
        return model
    }()

    static let exampleImageRequest = ControlAPI.ImageRequest(
        prompt: "A tram climbing Alfama at dawn", modelID: "flux2-klein",
        width: 1024, height: 1024, steps: 8
    )

    static let exampleImagePlan = ControlAPI.ImagePlan(
        width: 1024, height: 1024, steps: 8, quantization: "8-bit",
        peakBytes: 13_958_643_712, peakPhase: "Decode", budgetBytes: 29_200_000_000,
        verdict: "fits",
        phases: [.init(name: "Decode", detail: "VAE", residentBytes: 13_958_643_712)],
        suggestions: [], notes: ["The last phase is the one that decides."]
    )

    /// The path form, which is what this Mac's own token and the MCP bridge send.
    /// `uploadID` is in the fixture too, because a phone has no path to send and the
    /// generated client has to know both keys exist and that exactly one is needed.
    static let exampleMeshRequest = ControlAPI.MeshRequest(
        imagePath: "/Users/you/Pictures/kettle.png", modelID: "hunyuan3d-2",
        textureSize: 2048, uploadID: exampleUploadID
    )

    /// Three items, because the optional fields are the whole difficulty of this shape and
    /// one running clip shows none of them.
    ///
    /// A phone reads `file`, `error`, `mediaID` and the queue's `message` and has, until
    /// now, only ever seen them null in the export — so a generated client either declared
    /// them non-optional and crashed on the first failure, or guessed. Here the running
    /// clip has none of them, the finished one has a file and the two ids that make it
    /// fetchable, and the failed one has the sentence the Mac would show. `message` is the
    /// queue's own line, set here to the one a stalled queue really produces.
    static let exampleVideoQueue = ControlAPI.VideoQueueView(
        paused: false, activeID: "9C2F-0001",
        message: "Waiting for silicon-node. The queue is saved; no job has been resubmitted.",
        items: [
            .init(
                id: "9C2F-0001", batchID: "9C2F", title: "Lisbon",
                prompt: "A tram climbing Alfama at dawn", scene: 1, variation: 1,
                seed: 424_242, modelID: "hailuo-h3", seconds: 5, resolution: "720p",
                h3Turbo: false, status: "running", nodeJobID: "job-1187", file: nil,
                outputDirectory: "/Users/you/Movies/Silicon/Lisbon", error: nil,
                uncertainSubmission: false, h3Steps: 30,
                negativePrompt: "blurry, watermark, text overlay"
            ),
            .init(
                id: "9C2F-0002", batchID: "9C2F", title: "Lisbon",
                prompt: "The same tram, from the tracks", scene: 2, variation: 1,
                seed: 424_243, modelID: "hailuo-h3", seconds: 5, resolution: "720p",
                h3Turbo: false, status: "completed", nodeJobID: "job-1188",
                file: "/Users/you/Movies/Silicon/Lisbon/lisbon-0002.mp4",
                outputDirectory: "/Users/you/Movies/Silicon/Lisbon", error: nil,
                uncertainSubmission: false, h3Steps: 30,
                detail: "Hailuo H3 at 5 s — the prompt asks for fast motion.",
                mediaID: exampleClipMediaID,
                mediaURL: "/media/\(exampleClipMediaID)",
                thumbnailMediaID: examplePosterMediaID
            ),
            .init(
                id: "9C2F-0003", batchID: "9C2F", title: "Lisbon",
                prompt: "Alfama rooftops at first light", scene: 3, variation: 1,
                seed: 424_244, modelID: "hailuo-h3", seconds: 5, resolution: "720p",
                h3Turbo: false, status: "failed", nodeJobID: nil, file: nil,
                outputDirectory: "/Users/you/Movies/Silicon/Lisbon",
                error: "silicon-node ran out of VRAM at the decode stage.",
                uncertainSubmission: true, h3Steps: 30
            ),
        ]
    )

    // MARK: Media ids
    //
    // Placeholders, like the pairing code and the tailnet address: these files are
    // committed and copied between repositories, and an id that looked real would invite
    // somebody to try it. They are the right *shape* — base64url, 22 characters — because
    // that is the part a generated client has to handle.

    static let exampleClipMediaID = "bWVkaWEtY2xpcC1leGFt"
    static let examplePosterMediaID = "bWVkaWEtcG9zdGVyLWV4"
    static let exampleImageMediaID = "bWVkaWEtaW1hZ2UtZXhh"
    static let exampleMeshMediaID = "bWVkaWEtbWVzaC1leGFt"
    static let exampleMeshOBJMediaID = "bWVkaWEtbWVzaC1vYmpl"
    static let exampleUploadMediaID = "bWVkaWEtdXBsb2FkLWV4"
    static let exampleUploadID = "0B7D4C2A-5E31-4F08-9A6B-1C2D3E4F5061"
}
