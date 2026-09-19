import Foundation
import Network
import Testing
@testable import SiliconCatalog
@testable import SiliconControl
@testable import SiliconRuntime
@testable import SiliconUI

/// What a phone needs to finish a media job: fetch the result, send a picture, and ask a
/// node what it is actually running.
///
/// Everything here is loopback, temporary directories and fixtures. Nothing loads a model,
/// renders anything, or talks to a real node — the "node" is an `NWListener` answering two
/// canned JSON bodies, and the "clip" is a few hundred bytes with an MP4 header on it.
@Suite("Silicon Buddy media routes")
struct BuddyMediaRoutesTests {

    // MARK: - The registry's two rules

    /// The rule the whole feature rests on: an id exists only for a file inside one of the
    /// app's own output folders. Everything else is unregistrable, so there is no id for
    /// `GET /media` to serve and nothing for a caller to guess at.
    @Test func nothingOutsideTheOutputRootsCanEverBeRegistered() async throws {
        try await withTemporaryDirectory { directory in
            let outputs = directory.appendingPathComponent("Movies")
            let elsewhere = directory.appendingPathComponent("Secrets")
            try FileManager.default.createDirectory(at: outputs, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
            let secret = elsewhere.appendingPathComponent("private.png")
            try Data("not yours".utf8).write(to: secret)
            let clip = outputs.appendingPathComponent("clip.mp4")
            try Data("a clip".utf8).write(to: clip)

            let registry = MediaRegistry(url: nil)
            let roots = [outputs.path]

            // The ordinary case.
            let id = await registry.register(path: clip.path, within: roots)
            #expect(id != nil)

            // A path outside the roots.
            #expect(await registry.register(path: secret.path, within: roots) == nil)

            // Traversal out of a root, in the two spellings that actually get sent.
            let traversals = [
                outputs.path + "/../Secrets/private.png",
                outputs.path + "/./../Secrets/private.png",
                outputs.path + "/subdir/../../Secrets/private.png",
            ]
            for attempt in traversals {
                #expect(
                    await registry.register(path: attempt, within: roots) == nil,
                    "\(attempt) should not be registrable"
                )
            }

            // A symlink planted inside a root pointing out of it. Resolving before
            // comparing is what makes this a miss rather than a way through.
            let link = outputs.appendingPathComponent("shortcut.png")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)
            #expect(await registry.register(path: link.path, within: roots) == nil)

            // A relative path is not a path on a server.
            #expect(await registry.register(path: "clip.mp4", within: roots) == nil)

            // A sibling folder whose name merely starts the same way.
            let lookalike = directory.appendingPathComponent("MoviesPrivate")
            try FileManager.default.createDirectory(
                at: lookalike, withIntermediateDirectories: true
            )
            let nearby = lookalike.appendingPathComponent("clip.mp4")
            try Data("nope".utf8).write(to: nearby)
            #expect(await registry.register(path: nearby.path, within: roots) == nil)

            // A type this server does not serve back, inside a root.
            let weights = outputs.appendingPathComponent("model.gguf")
            try Data("weights".utf8).write(to: weights)
            #expect(await registry.register(path: weights.path, within: roots) == nil)
        }
    }

    /// The queue view is rebuilt on every poll, so registration has to be idempotent — and
    /// a file that has since been deleted has to stop resolving rather than 500 on read.
    @Test func anIdIsStableForAPathAndDiesWithTheFile() async throws {
        try await withTemporaryDirectory { directory in
            let clip = directory.appendingPathComponent("clip.mp4")
            try Data("a clip".utf8).write(to: clip)
            let registry = MediaRegistry(url: nil)

            let first = await registry.register(path: clip.path, within: [directory.path])
            let again = await registry.register(path: clip.path, within: [directory.path])
            #expect(first != nil)
            #expect(first == again)
            #expect(await registry.count == 1)

            let id = try #require(first)
            #expect(await registry.entry(id: id)?.contentType == "video/mp4")
            try FileManager.default.removeItem(at: clip)
            #expect(await registry.entry(id: id) == nil)
            // …and forgotten, not merely hidden.
            #expect(await registry.count == 0)
        }
    }

    /// The table outlives a relaunch, because a phone that fetched a poster this morning
    /// should not find the link dead this afternoon.
    @Test func theTableSurvivesARestart() async throws {
        try await withTemporaryDirectory { directory in
            let clip = directory.appendingPathComponent("clip.mp4")
            try Data("a clip".utf8).write(to: clip)
            let file = directory.appendingPathComponent("media.json")

            let first = MediaRegistry(url: file)
            let id = try #require(
                await first.register(path: clip.path, within: [directory.path])
            )
            await first.persist()

            let second = MediaRegistry(url: file)
            #expect(await second.entry(id: id)?.path == clip.path)
            // And the same path still mints the same id rather than a second one.
            #expect(await second.register(path: clip.path, within: [directory.path]) == id)
        }
    }

    // MARK: - GET /media/{id}

    @Test func aDeviceFetchesAResultByIdAtEitherScopeAndNeverWithoutAToken() async throws {
        try await withServer { fixture in
            let clip = try fixture.writeOutput(named: "clip.mp4", bytes: Self.mp4Bytes(count: 4096))
            let id = try #require(
                await fixture.registry.register(path: clip.path, within: [fixture.outputs.path])
            )

            let full = try await fixture.pair(name: "Studio phone")
            let chat = try await fixture.pair(name: "Lent out", scope: .chat)

            // Full control and chat-only alike: looking at something the Mac already made
            // spends nothing, which is the same reason a chat device may read the queue.
            for token in [full.token, chat.token] {
                let (status, body) = try await fixture.phone.call(
                    "GET", "/media/\(id)", token: token
                )
                #expect(status == 200)
                #expect(body.count == 4096)
            }

            // And the loopback listener serves it too — the MCP bridge and this Mac's own
            // tools reach the same route with the control token.
            #expect(try await fixture.local.status(
                "GET", "/media/\(id)", token: fixture.local.token
            ) == 200)

            // No token, a guessed token, and a token from a device that has been revoked.
            #expect(try await fixture.phone.status("GET", "/media/\(id)", token: nil) == 401)
            #expect(try await fixture.phone.status("GET", "/media/\(id)", token: "guessed") == 401)
            _ = await fixture.registry2.revoke(deviceID: chat.deviceID)
            #expect(try await fixture.phone.status("GET", "/media/\(id)", token: chat.token) == 401)
        }
    }

    /// An id that is not in the table is a 404 — and so is one that looks like a path,
    /// which is the whole reason the route takes an id in the first place.
    @Test func anUnknownIdIsA404AndAPathIsNotAnId() async throws {
        try await withServer { fixture in
            let clip = try fixture.writeOutput(named: "clip.mp4", bytes: Self.mp4Bytes(count: 64))
            _ = await fixture.registry.register(path: clip.path, within: [fixture.outputs.path])
            let paired = try await fixture.pair()

            for id in [
                "not-an-id",
                clip.path,
                clip.lastPathComponent,
                "..%2F..%2Fetc%2Fpasswd",
                "%2Fetc%2Fpasswd",
            ] {
                let encoded = id.addingPercentEncoding(
                    withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_"))
                ) ?? id
                let status = try await fixture.phone.status(
                    "GET", "/media/\(encoded)", token: paired.token
                )
                #expect(status == 404, "\(id) should be a 404")
            }
        }
    }

    /// Players probe with `bytes=0-1` before they will play anything, and seeking is ranges
    /// all the way down.
    @Test func rangeRequestsAreAnsweredWithTheBytesAsked() async throws {
        try await withServer { fixture in
            let payload = Self.mp4Bytes(count: 1000)
            let clip = try fixture.writeOutput(named: "clip.mp4", bytes: payload)
            let id = try #require(
                await fixture.registry.register(path: clip.path, within: [fixture.outputs.path])
            )
            let paired = try await fixture.pair()

            // A player's opening probe.
            let probe = try await fixture.phone.range(
                "/media/\(id)", token: paired.token, range: "bytes=0-1"
            )
            #expect(probe.status == 206)
            #expect(probe.body == payload.prefix(2))
            #expect(probe["Content-Range"] == "bytes 0-1/1000")
            #expect(probe["Accept-Ranges"] == "bytes")

            // A seek into the middle.
            let middle = try await fixture.phone.range(
                "/media/\(id)", token: paired.token, range: "bytes=500-599"
            )
            #expect(middle.status == 206)
            #expect(middle.body == payload[500..<600])
            #expect(middle["Content-Range"] == "bytes 500-599/1000")

            // An open-ended range runs to the end of the file.
            let tail = try await fixture.phone.range(
                "/media/\(id)", token: paired.token, range: "bytes=900-"
            )
            #expect(tail.status == 206)
            #expect(tail.body.count == 100)

            // The suffix form.
            let last = try await fixture.phone.range(
                "/media/\(id)", token: paired.token, range: "bytes=-10"
            )
            #expect(last.status == 206)
            #expect(last.body == payload.suffix(10))

            // Past the end is refused with where the end is, rather than with an empty 200.
            let beyond = try await fixture.phone.range(
                "/media/\(id)", token: paired.token, range: "bytes=4000-5000"
            )
            #expect(beyond.status == 416)
            #expect(beyond["Content-Range"] == "bytes */1000")

            // No range at all is the whole file.
            let whole = try await fixture.phone.call("GET", "/media/\(id)", token: paired.token)
            #expect(whole.0 == 200)
            #expect(whole.1 == payload)
        }
    }

    /// A poster is fetched once per list and again on every scroll. The second fetch should
    /// cost a header.
    @Test func anUnchangedFileIsAnswered304() async throws {
        try await withServer { fixture in
            let image = try fixture.writeOutput(named: "still.png", bytes: Self.pngBytes(count: 300))
            let id = try #require(
                await fixture.registry.register(path: image.path, within: [fixture.outputs.path])
            )
            let paired = try await fixture.pair()

            let first = try await fixture.phone.range("/media/\(id)", token: paired.token)
            #expect(first.status == 200)
            #expect(first["Content-Type"] == "image/png")
            let tag = try #require(first["ETag"])

            let second = try await fixture.phone.range(
                "/media/\(id)", token: paired.token, ifNoneMatch: tag
            )
            #expect(second.status == 304)
            #expect(second.body.isEmpty)

            // A different tag is not a match, whatever it says.
            let stale = try await fixture.phone.range(
                "/media/\(id)", token: paired.token, ifNoneMatch: "\"0-0\""
            )
            #expect(stale.status == 200)
        }
    }

    // MARK: - POST /uploads

    @Test func aFullDeviceUploadsAPictureAndAChatOnlyOneMayNot() async throws {
        try await withServer { fixture in
            let full = try await fixture.pair(name: "Studio phone")
            let chat = try await fixture.pair(name: "Lent out", scope: .chat)
            let photograph = Self.jpegBytes(count: 2048)

            let refused = try await fixture.phone.status(
                "POST", "/uploads", token: chat.token, data: photograph,
                contentType: "image/jpeg"
            )
            #expect(refused == 403)

            let (status, body) = try await fixture.phone.call(
                "POST", "/uploads", token: full.token, data: photograph,
                contentType: "image/jpeg", filename: "holiday.jpg"
            )
            #expect(status == 200)
            let upload = try JSONDecoder().decode(ControlAPI.UploadResponse.self, from: body)
            #expect(upload.bytes == photograph.count)
            #expect(upload.contentType == "image/jpeg")
            #expect(upload.mediaURL == "/media/\(upload.mediaID)")

            // It landed in this device's own folder, and nowhere else.
            let folder = fixture.uploads.appendingPathComponent(full.deviceID)
            let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            #expect(files == ["\(upload.uploadID).jpg"])
            // The chat device, refused, has no folder at all.
            #expect(!FileManager.default.fileExists(
                atPath: fixture.uploads.appendingPathComponent(chat.deviceID).path
            ))

            // And it comes straight back down the media route.
            let fetched = try await fixture.phone.call(
                "GET", "/media/\(upload.mediaID)", token: full.token
            )
            #expect(fetched.0 == 200)
            #expect(fetched.1 == photograph)
        }
    }

    /// The type is decided by the bytes, never by what the request called them.
    @Test func whatAnUploadIsGetsReadOffItsOwnFirstBytes() async throws {
        try await withServer { fixture in
            let paired = try await fixture.pair()

            // A PNG announced as a JPEG is stored, correctly, as a PNG.
            let (status, body) = try await fixture.phone.call(
                "POST", "/uploads", token: paired.token, data: Self.pngBytes(count: 500),
                contentType: "image/jpeg", filename: "liar.jpg"
            )
            #expect(status == 200)
            let upload = try JSONDecoder().decode(ControlAPI.UploadResponse.self, from: body)
            #expect(upload.contentType == "image/png")
            let folder = fixture.uploads.appendingPathComponent(paired.deviceID)
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path)
                == ["\(upload.uploadID).png"])

            // Things that are not pictures or short clips, however they are announced.
            for (label, bytes) in [
                ("a script", Data("#!/bin/sh\nrm -rf /\n".utf8)),
                ("a GGUF", Data([0x47, 0x47, 0x55, 0x46, 0x03, 0, 0, 0] + [UInt8](repeating: 0, count: 64))),
                ("an ELF", Data([0x7F, 0x45, 0x4C, 0x46] + [UInt8](repeating: 0, count: 64))),
                ("a zip", Data([0x50, 0x4B, 0x03, 0x04] + [UInt8](repeating: 0, count: 64))),
            ] {
                let refused = try await fixture.phone.status(
                    "POST", "/uploads", token: paired.token, data: bytes,
                    contentType: "image/png", filename: "innocent.png"
                )
                #expect(refused == 415, "\(label) should be refused")
            }

            // An empty body is a 400 rather than a zero-byte file.
            #expect(try await fixture.phone.status(
                "POST", "/uploads", token: paired.token, data: Data(), contentType: "image/png"
            ) == 400)
        }
    }

    /// A phone's HTTP stack usually posts a file as multipart. The bytes that come out are
    /// the file's, not the framing's.
    @Test func aMultipartBodyIsReadAsTheFileInsideIt() async throws {
        try await withServer { fixture in
            let paired = try await fixture.pair()
            let photograph = Self.jpegBytes(count: 900)
            let boundary = "----SiliconBuddyBoundary7Zx"
            var body = Data("--\(boundary)\r\n".utf8)
            body.append(Data(
                "Content-Disposition: form-data; name=\"file\"; filename=\"holiday.jpg\"\r\n".utf8
            ))
            body.append(Data("Content-Type: image/jpeg\r\n\r\n".utf8))
            body.append(photograph)
            body.append(Data("\r\n--\(boundary)--\r\n".utf8))

            let (status, answer) = try await fixture.phone.call(
                "POST", "/uploads", token: paired.token, data: body,
                contentType: "multipart/form-data; boundary=\(boundary)"
            )
            #expect(status == 200)
            let upload = try JSONDecoder().decode(ControlAPI.UploadResponse.self, from: answer)
            #expect(upload.bytes == photograph.count)

            let fetched = try await fixture.phone.call(
                "GET", "/media/\(upload.mediaID)", token: paired.token
            )
            #expect(fetched.1 == photograph)
        }
    }

    /// The cap is raised for this one route and no other, and it is refused on the declared
    /// length — before a byte of it is read.
    @Test func theUploadCeilingIsHigherThanEveryOtherRoutesAndStillACeiling() async throws {
        try await withServer { fixture in
            let paired = try await fixture.pair()

            // Comfortably over the ordinary 4 MiB device body, and accepted here.
            let big = Self.jpegBytes(count: BuddyLimits.requestBodyBytes + 512_000)
            #expect(try await fixture.phone.status(
                "POST", "/uploads", token: paired.token, data: big, contentType: "image/jpeg"
            ) == 200)

            // The same body on any other route is refused, which is what "for this one
            // route" means.
            #expect(try await fixture.phone.status(
                "POST", "/image/generate", token: paired.token, data: big,
                contentType: "application/json"
            ) == 413)

            // And past 24 MiB, even here.
            let enormous = Self.jpegBytes(count: BuddyUploads.maximumBytes + 1024)
            #expect(try await fixture.phone.status(
                "POST", "/uploads", token: paired.token, data: enormous,
                contentType: "image/jpeg"
            ) == 413)
        }
    }

    /// An upload is working material for one render, not a library.
    @Test func uploadsOlderThanAWeekAreSweptAndTheirIdsStopResolving() async throws {
        try await withTemporaryDirectory { directory in
            let manager = FileManager.default
            let phone = directory.appendingPathComponent("device-a")
            let other = directory.appendingPathComponent("device-b")
            try manager.createDirectory(at: phone, withIntermediateDirectories: true)
            try manager.createDirectory(at: other, withIntermediateDirectories: true)

            let fresh = phone.appendingPathComponent("fresh.jpg")
            let stale = phone.appendingPathComponent("stale.jpg")
            let ancient = other.appendingPathComponent("ancient.jpg")
            for file in [fresh, stale, ancient] {
                try Data("x".utf8).write(to: file)
            }
            let now = Date()
            try manager.setAttributes(
                [.modificationDate: now.addingTimeInterval(-6 * 24 * 3600)],
                ofItemAtPath: fresh.path
            )
            for file in [stale, ancient] {
                try manager.setAttributes(
                    [.modificationDate: now.addingTimeInterval(-8 * 24 * 3600)],
                    ofItemAtPath: file.path
                )
            }

            let registry = MediaRegistry(url: nil)
            let staleID = try #require(
                await registry.register(path: stale.path, within: [directory.path])
            )
            let freshID = try #require(
                await registry.register(path: fresh.path, within: [directory.path])
            )

            let removed = BuddyUploads.sweep(at: directory, now: now)
            #expect(removed == 2)
            #expect(manager.fileExists(atPath: fresh.path))
            #expect(!manager.fileExists(atPath: stale.path))
            // A folder emptied by the sweep goes with it; one still holding something does
            // not.
            #expect(!manager.fileExists(atPath: other.path))
            #expect(manager.fileExists(atPath: phone.path))

            await registry.forgetMissingFiles()
            #expect(await registry.entry(id: staleID) == nil)
            #expect(await registry.entry(id: freshID) != nil)
        }
    }

    /// One device's id is not a key to another's photographs.
    @Test func anUploadIdOnlyResolvesInsideTheDeviceThatSentIt() async throws {
        try await withTemporaryDirectory { directory in
            let destination = try BuddyUploads.destination(
                forBucket: "device-a", uploadID: "ABCD-1234", fileExtension: "jpg",
                at: directory
            )
            try Data("a picture".utf8).write(to: destination)

            // Compared through `resolvingSymlinksInPath`, because a temporary directory on
            // macOS is /var/… and /private/var/… at once and which one FileManager hands
            // back is not this test's business.
            #expect(BuddyUploads.resolve(
                uploadID: "ABCD-1234", bucket: "device-a", at: directory
            )?.resolvingSymlinksInPath() == destination.resolvingSymlinksInPath())
            #expect(BuddyUploads.resolve(
                uploadID: "ABCD-1234", bucket: "device-b", at: directory
            ) == nil)
            // An id that is not a plain token resolves to nothing rather than being
            // sanitised into somebody else's file.
            for attempt in ["../device-a/ABCD-1234", "ABCD-1234.jpg", "", "a/b"] {
                #expect(BuddyUploads.resolve(
                    uploadID: attempt, bucket: "device-a", at: directory
                ) == nil, "\(attempt) should not resolve")
            }
            // And a bucket name cannot climb either.
            #expect(BuddyUploads.resolve(
                uploadID: "ABCD-1234", bucket: "../device-a", at: directory
            ) == nil)
        }
    }

    /// The point of the whole upload half: a phone can make a mesh out of a photograph
    /// without ever naming a path, and cannot name one even if it tries.
    @Test func aRenderStartsFromAnUploadIdAndNeverFromADevicesPath() async throws {
        try await withServer { fixture in
            let paired = try await fixture.pair()
            let (status, body) = try await fixture.phone.call(
                "POST", "/uploads", token: paired.token, data: Self.jpegBytes(count: 1200),
                contentType: "image/jpeg", filename: "kettle.jpg"
            )
            #expect(status == 200)
            let upload = try JSONDecoder().decode(ControlAPI.UploadResponse.self, from: body)

            // The id resolves to the file on this Mac, and the host sees a path it can use.
            #expect(try await fixture.phone.status(
                "POST", "/mesh/generate", token: paired.token,
                body: #"{"uploadID":"\#(upload.uploadID)"}"#
            ) == 200)
            let seen = try #require(await fixture.host.lastMeshImagePath)
            #expect(seen.hasPrefix(fixture.uploads.resolvingSymlinksInPath().path))
            // The media id resolves to the same file.
            #expect(try await fixture.phone.status(
                "POST", "/mesh/generate", token: paired.token,
                body: #"{"mediaID":"\#(upload.mediaID)"}"#
            ) == 200)
            #expect(await fixture.host.lastMeshImagePath == seen)

            // A path from a device is refused, and the host is never asked.
            await fixture.host.forgetMesh()
            #expect(try await fixture.phone.status(
                "POST", "/mesh/generate", token: paired.token,
                body: #"{"imagePath":"/etc/passwd"}"#
            ) == 400)
            #expect(await fixture.host.lastMeshImagePath == nil)

            // An id that names nothing says so, rather than reading as "you forgot one".
            #expect(try await fixture.phone.status(
                "POST", "/mesh/generate", token: paired.token,
                body: #"{"uploadID":"0000-0000"}"#
            ) == 404)

            // The Mac's own token may still send a path: that is what every script and
            // MCP tool written against this route does.
            #expect(try await fixture.local.status(
                "POST", "/mesh/generate", token: fixture.local.token,
                body: #"{"imagePath":"/Users/you/Pictures/kettle.png"}"#
            ) == 200)
            #expect(await fixture.host.lastMeshImagePath == "/Users/you/Pictures/kettle.png")
        }
    }

    // MARK: - The decoration on the way out

    /// Every path a result carries comes back with an id beside it, and a poster where one
    /// could be made.
    @Test func aFinishedClipIsPublishedWithItsIdAndItsPoster() async throws {
        try await withServer { fixture in
            let clip = try fixture.writeOutput(named: "clip.mp4", bytes: Self.mp4Bytes(count: 128))
            await fixture.host.setQueueFile(clip.path)
            let paired = try await fixture.pair()

            let (status, body) = try await fixture.phone.call(
                "GET", "/video/queue", token: paired.token
            )
            #expect(status == 200)
            let view = try JSONDecoder().decode(ControlAPI.VideoQueueView.self, from: body)
            let item = try #require(view.items.first)
            let mediaID = try #require(item.mediaID)
            #expect(item.mediaURL == "/media/\(mediaID)")
            // The fixture host writes a stub poster, which is what a Mac with AVFoundation
            // would do with a real clip.
            let posterID = try #require(item.thumbnailMediaID)
            #expect(posterID != mediaID)

            for id in [mediaID, posterID] {
                #expect(try await fixture.phone.status(
                    "GET", "/media/\(id)", token: paired.token
                ) == 200)
            }

            // Polling again does not mint a second pair of ids.
            let again = try JSONDecoder().decode(
                ControlAPI.VideoQueueView.self,
                from: try await fixture.phone.call(
                    "GET", "/video/queue", token: paired.token
                ).1
            )
            #expect(again.items.first?.mediaID == mediaID)
            #expect(again.items.first?.thumbnailMediaID == posterID)

            // A clip that landed outside the output roots has no id, which is the honest
            // answer to "can this phone play it?".
            let elsewhere = fixture.directory.appendingPathComponent("stray.mp4")
            try Self.mp4Bytes(count: 32).write(to: elsewhere)
            await fixture.host.setQueueFile(elsewhere.path)
            let stray = try JSONDecoder().decode(
                ControlAPI.VideoQueueView.self,
                from: try await fixture.phone.call(
                    "GET", "/video/queue", token: paired.token
                ).1
            )
            #expect(stray.items.first?.file == elsewhere.path)
            #expect(stray.items.first?.mediaID == nil)
            #expect(stray.items.first?.mediaURL == nil)
        }
    }

    // MARK: - GET /swarm/peers/{name}/status

    /// The proxy forwards what the node says and nothing this Mac holds.
    @Test func thePeerProxyForwardsTheNodeAndKeepsTheToken() async throws {
        let node = try await FakeNode()
        defer { node.stop() }

        let status = await SwarmPeerProbe.status(
            name: "silicon-node", base: node.baseURL, token: "swarm-secret-nobody-should-see"
        )
        #expect(status.reachable)
        #expect(status.hardware == "NVIDIA GeForce RTX 3090 Ti")
        #expect(status.platform == "windows-cuda")
        #expect(status.totalMemoryGB == 24)
        #expect(status.usedMemoryGB == 9)
        #expect(status.queueDepth == 1)
        #expect(status.capabilities.map(\.id).sorted() == ["image-to-mesh", "text-to-video"])
        // The two things `GET /swarm` cannot carry.
        let gguf = try #require(status.gguf)
        #expect(gguf.running)
        #expect(gguf.model == "qwen3.8-27b-q4_k_m.gguf")
        #expect(gguf.adapter == "bonsai-27b-v3.lora.gguf")
        #expect(gguf.engine == "stock")
        #expect(gguf.contextLength == 65_536)
        #expect(gguf.installedModels.count == 2)

        // The node was asked with the credential…
        #expect(await node.authorizations.allSatisfy {
            $0 == "Bearer swarm-secret-nobody-should-see"
        })
        #expect(await node.paths.sorted() == ["/v1/gguf", "/v1/node"])
        // …and the credential is nowhere in what comes back.
        let encoded = String(decoding: try JSONEncoder().encode(status), as: UTF8.self)
        #expect(!encoded.contains("swarm-secret-nobody-should-see"))
        #expect(!encoded.lowercased().contains("bearer"))
    }

    /// A node with no llama.cpp lane answers 404 there, which is an answer about the lane
    /// and not about the node.
    @Test func aNodeWithoutAGGUFLaneIsStillAnswered() async throws {
        let node = try await FakeNode(serveGGUF: false)
        defer { node.stop() }

        let status = await SwarmPeerProbe.status(
            name: "silicon-node", base: node.baseURL, token: nil
        )
        #expect(status.reachable)
        #expect(status.gguf == nil)
        #expect(status.error == nil)
        #expect(!status.capabilities.isEmpty)
    }

    /// A node that is not there is said to be not there, rather than throwing.
    @Test func anUnreachableNodeIsReportedRatherThanThrown() async throws {
        let port = try await BuddyControlTests.freeLoopbackPort()
        let status = await SwarmPeerProbe.status(
            name: "silicon-node",
            base: try #require(URL(string: "http://127.0.0.1:\(port)")), token: nil
        )
        #expect(!status.reachable)
        #expect(status.error == "Unreachable.")
        #expect(status.gguf == nil)
    }

    /// The route itself: full control only, and a name this Mac does not know is a 404.
    @Test func onlyAFullDeviceMayAskAPeerAboutItself() async throws {
        try await withServer { fixture in
            let full = try await fixture.pair(name: "Studio phone")
            let chat = try await fixture.pair(name: "Lent out", scope: .chat)

            #expect(try await fixture.phone.status(
                "GET", "/swarm/peers/silicon-node/status", token: chat.token
            ) == 403)
            // The fixture host has no swarm, so a full device gets the 404 rather than the
            // 403 — which is the distinction being pinned: the scope gate ran and passed.
            #expect(try await fixture.phone.status(
                "GET", "/swarm/peers/silicon-node/status", token: full.token
            ) == 404)
            #expect(try await fixture.phone.status(
                "GET", "/swarm/peers/silicon-node/status", token: nil
            ) == 401)
        }
    }

    // MARK: - Fixtures

    /// Enough bytes to look like what they claim, and then filler. The sniffer reads the
    /// first twelve; the tests care about the length.
    static func mp4Bytes(count: Int) -> Data {
        var data = Data([0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6F, 0x6D])
        data.append(Data((0..<max(0, count - data.count)).map { UInt8($0 % 251) }))
        return data
    }

    static func pngBytes(count: Int) -> Data {
        var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        data.append(Data((0..<max(0, count - data.count)).map { UInt8($0 % 251) }))
        return data
    }

    static func jpegBytes(count: Int) -> Data {
        var data = Data([0xFF, 0xD8, 0xFF, 0xE0])
        data.append(Data(repeating: 0x41, count: max(0, count - data.count)))
        return data
    }

    private func withTemporaryDirectory(_ body: (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("buddy-media-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }

    struct Fixture {
        let server: ControlServer
        let local: TestClient
        let phone: TestClient
        /// The paired-device store. Named `registry2` beside the media one so neither
        /// reads as "the registry".
        let registry2: BuddyRegistry
        let registry: MediaRegistry
        let host: MediaTestHost
        let directory: URL
        let outputs: URL
        let uploads: URL

        func writeOutput(named name: String, bytes: Data) throws -> URL {
            let url = outputs.appendingPathComponent(name)
            try bytes.write(to: url)
            return url
        }

        func pair(
            name: String = "Galaxy S24 Ultra", scope: BuddyScope = .full
        ) async throws -> ControlAPI.BuddyPairResponse {
            let invitation = await registry2.invite(
                host: "127.0.0.1", port: phone.port, scope: scope
            )
            let (status, body) = try await phone.call(
                "POST", "/buddy/pair", token: nil,
                body: #"{"code":"\#(invitation.code)","deviceName":"\#(name)","platform":"android"}"#
            )
            #expect(status == 200)
            return try JSONDecoder().decode(ControlAPI.BuddyPairResponse.self, from: body)
        }
    }

    private func withServer(_ body: (Fixture) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("buddy-media-server-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputs = directory.appendingPathComponent("Movies")
        let uploads = directory.appendingPathComponent("uploads")
        let posters = directory.appendingPathComponent("posters")
        for folder in [directory, outputs, uploads, posters] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        let handshakeURL = directory.appendingPathComponent("control.json")
        let devices = BuddyRegistry(url: directory.appendingPathComponent("buddy.json"))
        let media = MediaRegistry(url: directory.appendingPathComponent("media.json"))
        let host = MediaTestHost(roots: [outputs.path])
        let server = ControlServer(
            host: host, handshakeURL: handshakeURL, buddy: devices,
            events: BuddyEventHub(), media: media,
            uploadsRoot: uploads, postersRoot: posters,
            discoverTailnetAddress: { nil }
        )

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 64
        configuration.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        try await server.start()
        defer { Task { await server.stop() } }
        let deadline = ContinuousClock.now + .seconds(5)
        while !FileManager.default.fileExists(atPath: handshakeURL.path) {
            guard ContinuousClock.now < deadline else { throw BuddyTestError.timeout }
            try await Task.sleep(for: .milliseconds(20))
        }
        let handshake = try JSONDecoder().decode(
            ControlAPI.Handshake.self, from: try Data(contentsOf: handshakeURL)
        )
        await devices.setAllowsTailnetDevices(true)
        let tailnetPort = try await BuddyControlTests.bindTailnetListener(on: server)

        try await body(Fixture(
            server: server,
            local: TestClient(port: handshake.port, token: handshake.token, session: session),
            phone: TestClient(port: tailnetPort, token: handshake.token, session: session),
            registry2: devices, registry: media, host: host,
            directory: directory, outputs: outputs, uploads: uploads
        ))
        await server.stop()
    }
}

// MARK: - A host with output folders

/// A `ControlHost` that has somewhere to put things and can be asked what it was told.
///
/// Only the handful of methods the media routes touch do anything; everything else is the
/// protocol's own default or a trap, because a media test that reached `/load` would be
/// testing the wrong thing.
actor MediaTestHost: ControlHost {

    private let roots: [String]
    private var queueFile: String?
    /// What `POST /mesh/generate` was handed, after the server resolved whatever the
    /// caller sent. Nil means the host was never reached, which is what a refusal looks
    /// like from down here.
    private(set) var lastMeshImagePath: String?

    init(roots: [String]) { self.roots = roots }

    func setQueueFile(_ path: String?) { queueFile = path }
    func forgetMesh() { lastMeshImagePath = nil }

    func controlMediaRoots() async -> [String] { roots }

    /// A stub rather than a real frame grab: this suite must not decode video, and what is
    /// being tested is that a poster gets made, registered and served — not AVFoundation.
    func controlMakeVideoPoster(from source: URL, to destination: URL) async -> Bool {
        guard FileManager.default.fileExists(atPath: source.path) else { return false }
        try? FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        return (try? BuddyMediaRoutesTests.jpegBytes(count: 64).write(to: destination)) != nil
    }

    func videoQueue() async -> ControlAPI.VideoQueueView {
        .init(paused: false, activeID: nil, message: nil, items: [
            .init(
                id: "9C2F-0001", batchID: "9C2F", title: "Fixture",
                prompt: "A tram", scene: 1, variation: 1, seed: 1,
                modelID: "hailuo-h3", seconds: 5, resolution: "720p", h3Turbo: nil,
                status: queueFile == nil ? "running" : "completed", nodeJobID: nil,
                file: queueFile, outputDirectory: roots.first ?? "/", error: nil,
                uncertainSubmission: false
            ),
        ])
    }

    func generateMesh(_ request: ControlAPI.MeshRequest) async throws -> ControlAPI.MeshResponse {
        lastMeshImagePath = request.imagePath
        return .init(glbPath: nil, objPath: nil, elapsedSeconds: 1, model: "fixture")
    }

    func generateImage(
        _ request: ControlAPI.ImageRequest
    ) async throws -> ControlAPI.ImageResponse {
        .init(
            path: request.initImagePath ?? "", elapsedSeconds: 1, peakMemoryBytes: nil,
            predictedPeakBytes: 1, model: "fixture"
        )
    }

    // The rest of the protocol. Present because it must be, answering because a scope test
    // really calls some of them.
    func swarm() async -> ControlAPI.SwarmView { .init(peers: [], polledSecondsAgo: nil) }
    func profile() async -> ControlAPI.Profile { fatalError("Unexpected test route") }
    func metrics() async -> ControlAPI.Metrics { fatalError("Unexpected test route") }
    func status() async -> ControlAPI.Status {
        .init(state: "idle", loadedModelID: nil, loadedModelName: nil, contextLength: nil,
              expertStreaming: false, lastGenerationTokensPerSecond: nil)
    }
    func catalog(category: String?, onlyRunnable: Bool) async -> [ControlAPI.CatalogModel] { [] }
    func installed() async -> [ControlAPI.InstalledModel] { [] }
    func recommend(category: String?, task: String?) async -> ControlAPI.CatalogModel? { nil }
    func plan(_ request: ControlAPI.PlanRequest) async throws -> ControlAPI.Plan {
        throw BuddyTestError.unexpectedRoute
    }
    func install(_ request: ControlAPI.LoadRequest) async throws -> String {
        throw BuddyTestError.unexpectedRoute
    }
    func load(_ request: ControlAPI.LoadRequest) async throws -> ControlAPI.Status {
        throw BuddyTestError.unexpectedRoute
    }
    func unload() async {}
    func chat(_ request: ControlAPI.ChatRequest) async throws -> ControlAPI.ChatResponse {
        throw BuddyTestError.unexpectedRoute
    }
    func decide(_ request: ControlAPI.DecideRequest) async throws -> ControlAPI.DecideResponse {
        throw BuddyTestError.unexpectedRoute
    }
    func jevStatus() async -> ControlAPI.JevStatus { .fixture() }
    func updateJev(_ update: ControlAPI.JevUpdate) async throws -> ControlAPI.JevStatus {
        throw BuddyTestError.unexpectedRoute
    }
    func recentGuardrailScreenings() async -> ControlAPI.GuardrailScreenings {
        .init(available: false, questions: [], screenings: [])
    }
    func jevCalibration() async -> ControlAPI.JevCalibration? { nil }
    func calibrateJev() async throws -> ControlAPI.JevCalibration {
        throw BuddyTestError.unexpectedRoute
    }
    func benchmark() async throws -> ControlAPI.BenchmarkResult {
        throw BuddyTestError.unexpectedRoute
    }
    func imageModels() async -> [ControlAPI.ImageModel] { [] }
    func planImage(_ request: ControlAPI.ImageRequest) async throws -> ControlAPI.ImagePlan {
        throw BuddyTestError.unexpectedRoute
    }
    func meshModels() async -> [ControlAPI.MeshModel] { [] }
    func planMesh(_ request: ControlAPI.MeshRequest) async throws -> ControlAPI.MeshPlan {
        throw BuddyTestError.unexpectedRoute
    }
    func videoModels() async -> [ControlAPI.VideoModel] { [] }
    func generateVideo(
        _ request: ControlAPI.VideoGenerateRequest
    ) async throws -> ControlAPI.VideoResponse {
        throw BuddyTestError.unexpectedRoute
    }
    func nodeAdvertisement() async -> ControlAPI.NodeAdvertisement {
        .init(
            name: "Fixture", platform: "macos-apple-silicon",
            profile: .init(chip: "Apple M3 Max", memoryGB: 38.7, bandwidthGBps: 300, gpuCores: 40),
            capabilities: [],
            metrics: .init(queueDepth: 0, headroomGB: 8.9, gpuUtilPct: 0, memoryUsedPct: 0)
        )
    }
    func chatStream(
        _ request: ControlAPI.ChatRequest
    ) async throws -> AsyncThrowingStream<ControlAPI.ChatStreamEvent, any Error> {
        throw BuddyTestError.unexpectedRoute
    }
    func conversationList() async -> [ControlAPI.ConversationSummary] { [] }
    func createConversation(title: String?) async -> ControlAPI.ConversationSummary {
        .init(id: UUID().uuidString, title: title ?? "", updatedAt: "", messageCount: 0)
    }
    func conversation(id: String) async throws -> ControlAPI.ConversationDetail {
        throw BuddyHostError.noSuchConversation(id)
    }
    func replyInConversation(
        id: String, to message: ControlAPI.NewMessageRequest
    ) async throws -> AsyncThrowingStream<ControlAPI.ChatStreamEvent, any Error> {
        throw BuddyHostError.noSuchConversation(id)
    }
    func beginEventUpdates(postingTo hub: BuddyEventHub) async {}
}


// MARK: - A client that can send bytes and ask for a range

extension TestClient {

    /// A body that is not JSON: what `POST /uploads` actually takes.
    func call(
        _ method: String, _ path: String, token: String?, data: Data,
        contentType: String, filename: String? = nil
    ) async throws -> (Int, Data) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = method
        request.httpBody = data
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        if let filename { request.setValue(filename, forHTTPHeaderField: "X-Filename") }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (body, response) = try await session.data(for: request)
        return (try #require((response as? HTTPURLResponse)?.statusCode), body)
    }

    func status(
        _ method: String, _ path: String, token: String?, data: Data,
        contentType: String, filename: String? = nil
    ) async throws -> Int {
        try await call(
            method, path, token: token, data: data, contentType: contentType,
            filename: filename
        ).0
    }

    struct MediaAnswer {
        var status: Int
        /// Lower-cased keys. `URLSession` does not promise the spelling a server used —
        /// "ETag" comes back as "Etag" on some releases — and a test that asserts on the
        /// capitalisation is asserting about Foundation rather than about this server.
        var headers: [String: String]
        var body: Data

        subscript(header: String) -> String? { headers[header.lowercased()] }
    }

    /// A GET whose response headers matter as much as its body — which is every request to
    /// `GET /media`.
    ///
    /// `URLSession` transparently satisfies a 304 from its own cache and hands back a 200,
    /// so this one uses a reload policy that always goes to the wire. Otherwise the test
    /// for "the second fetch costs a header" would be testing URLSession.
    func range(
        _ path: String, token: String?, range: String? = nil, ifNoneMatch: String? = nil
    ) async throws -> MediaAnswer {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }
        if let ifNoneMatch {
            request.setValue(ifNoneMatch, forHTTPHeaderField: "If-None-Match")
        }
        let (body, response) = try await session.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            guard let key = key as? String, let value = value as? String else { continue }
            headers[key.lowercased()] = value
        }
        return MediaAnswer(status: http.statusCode, headers: headers, body: body)
    }
}

// MARK: - A node that is not really there

/// The two routes `GET /swarm/peers/{name}/status` forwards, answered by a loopback socket.
///
/// A real node is a Windows machine with a CUDA card. What this suite has to prove is what
/// the Mac sends and what it publishes, and for that a listener with two canned bodies is
/// not only sufficient but better: it can be asked afterwards what it was sent.
actor FakeNode {

    let baseURL: URL
    private let listener: NWListener
    /// What the connection handler saw. Its own actor because the handler runs on
    /// Network.framework's queue, long before — and long after — anything here awaits it.
    private let log: PathLog

    var paths: [String] { get async { await log.paths } }
    /// Every `Authorization` header the node was sent, so a test can assert the credential
    /// went out — and, separately, that it did not come back.
    var authorizations: [String] { get async { await log.authorizations } }

    actor PathLog {
        private(set) var paths: [String] = []
        private(set) var authorizations: [String] = []
        func note(path: String, authorization: String?) {
            paths.append(path)
            if let authorization { authorizations.append(authorization) }
        }
    }

    init(serveGGUF: Bool = true) async throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener

        let node = """
        {"name":"silicon-node","platform":"windows-cuda",
         "profile":{"gpu":"NVIDIA GeForce RTX 3090 Ti","vram_mb":24576},
         "metrics":{"queue_depth":1,"gpu_util_pct":38,"vram_used_mb":9216,
                    "gpu_consumer":"job:text-to-video"},
         "capabilities":[
           {"id":"text-to-video","kind":"video","ready":true},
           {"id":"image-to-mesh","kind":"mesh","ready":true}]}
        """
        let gguf = """
        {"running":true,"model":"qwen3.8-27b-q4_k_m.gguf",
         "lora":"bonsai-27b-v3.lora.gguf","engine_flavor":"stock",
         "context_length":65536,"uptime_s":4281,
         "models":["qwen3.8-27b-q4_k_m.gguf","qwen3-coder-30b-q4_k_m.gguf"],
         "adapters":["bonsai-27b-v3.lora.gguf"]}
        """

        let paths = PathLog()
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global(qos: .userInitiated))
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
                data, _, _, _ in
                let text = String(decoding: data ?? Data(), as: UTF8.self)
                let path = text.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                let authorization = text
                    .components(separatedBy: "\r\n")
                    .first { $0.lowercased().hasPrefix("authorization:") }
                    .map { $0.dropFirst("authorization:".count).trimmingCharacters(in: .whitespaces) }
                Task { await paths.note(path: path, authorization: authorization) }

                let body: String?
                switch path {
                case "/v1/node": body = node
                case "/v1/gguf": body = serveGGUF ? gguf : nil
                default: body = nil
                }
                let head: String
                if let body {
                    head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                        + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
                } else {
                    head = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n"
                        + "Connection: close\r\n\r\n"
                }
                var payload = Data(head.utf8)
                if let body { payload.append(Data(body.utf8)) }
                connection.send(content: payload, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
        listener.start(queue: .global(qos: .userInitiated))

        let deadline = ContinuousClock.now + .seconds(5)
        var bound: Int?
        while bound == nil {
            if case .ready = listener.state, let port = listener.port {
                bound = Int(port.rawValue)
                break
            }
            guard ContinuousClock.now < deadline else { throw BuddyTestError.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
        baseURL = URL(string: "http://127.0.0.1:\(bound ?? 0)")!
        log = paths
    }

    nonisolated func stop() { listener.cancel() }
}


/// The Mac-side half of the same milestone: what `GET /swarm` now says about a peer, what
/// a negative prompt turns into on the wire, and what a `job` frame carries.
@Suite("Silicon Buddy media, on the Mac")
struct BuddyMediaAppTests {

    // MARK: - The richer swarm view

    /// A lane is "ready" by kind, not by capability id, because a node advertising
    /// `wan22-ti2v-5b` and one advertising the generic `text-to-video` are both a video
    /// lane and a phone should not have to know the difference.
    @Test func lanesAreFoldedOutOfWhateverTheNodeCallsItsCapabilities() {
        var peer = AppModel.PeerStatus(
            name: "silicon-node", baseURL: "http://node:8790", reachable: true
        )
        AppModel.parseNode([
            "capabilities": [
                ["id": "wan22-ti2v-5b", "kind": "video", "ready": true],
                ["id": "text-to-image", "kind": "image", "ready": false],
                ["id": "image-to-mesh", "kind": "mesh", "ready": true],
            ],
        ], into: &peer)

        var lanes = AppModel.lanes(of: peer)
        #expect(lanes.video)
        #expect(!lanes.image)
        #expect(lanes.mesh)
        // No chat lane reported at all is not a running one.
        #expect(!lanes.gguf)

        // Installed but stopped is still not something that can answer a question.
        peer.llm = AppModel.PeerLLM(
            installed: true, running: false, healthy: false, model: "qwen3.8-27b.gguf"
        )
        #expect(!AppModel.lanes(of: peer).gguf)

        peer.llm = AppModel.PeerLLM(
            installed: true, running: true, healthy: true, model: "qwen3.8-27b.gguf"
        )
        lanes = AppModel.lanes(of: peer)
        #expect(lanes.gguf)

        // And a node whose only video-ish lane is the portrait animator still counts as
        // one that can make a clip.
        var portraitOnly = AppModel.PeerStatus(
            name: "other", baseURL: "http://other:8790", reachable: true
        )
        AppModel.parseNode([
            "capabilities": [["id": "portrait-animate", "kind": "portrait-animate", "ready": true]],
        ], into: &portraitOnly)
        #expect(AppModel.lanes(of: portraitOnly).video)
    }

    /// The proxy's parser, against the node's real `/v1/gguf` shape. The adapter is the
    /// field the whole route exists for, and the node calls it something else.
    @Test func theNodesGGUFStatusIsReadIncludingItsAdapter() {
        let parsed = SwarmPeerProbe.parseGGUF([
            "running": true,
            "model": "qwen3.8-27b-q4_k_m.gguf",
            // The node's own name for it.
            "lora": "bonsai-27b-v3.lora.gguf",
            "engine_flavor": "prism",
            "context_length": 65_536,
            "uptime_s": 4_281,
            "models": ["qwen3.8-27b-q4_k_m.gguf", "qwen3-coder-30b-q4_k_m.gguf"],
            "adapters": ["bonsai-27b-v3.lora.gguf"],
            // Fields this shape does not carry are ignored rather than fatal.
            "picks": ["something": "else"],
        ])
        #expect(parsed.running)
        #expect(parsed.adapter == "bonsai-27b-v3.lora.gguf")
        #expect(parsed.engine == "prism")
        #expect(parsed.contextLength == 65_536)
        #expect(parsed.installedModels.count == 2)

        // A stopped lane: the node nulls the model and the adapter, and this must not
        // invent either.
        let stopped = SwarmPeerProbe.parseGGUF([
            "running": false, "model": NSNull(), "lora": NSNull(),
            "models": ["qwen3.8-27b-q4_k_m.gguf"],
        ])
        #expect(!stopped.running)
        #expect(stopped.model == nil)
        #expect(stopped.adapter == nil)
        #expect(stopped.installedModels.count == 1)

        // An empty body is "not reported", not a crash.
        let nothing = SwarmPeerProbe.parseGGUF([:])
        #expect(!nothing.running)
        #expect(nothing.adapters.isEmpty)
    }

    // MARK: - Negative prompts

    @Test func aNegativePromptTravelsToTheNodeAndAnAbsentOneLeavesNoField() throws {
        let outputs = FileManager.default.temporaryDirectory
        let base = VideoRequest(
            entryID: "wan22-ti2v-5b", prompt: "A tram climbing Alfama at dawn",
            seconds: 5, resolution: "720p", outputDirectory: outputs
        )
        let plainBody = try base.nodeBody()
        let plain = try JSONSerialization.jsonObject(with: plainBody) as? [String: Any] ?? [:]
        // Absent, not empty: an empty `negative_prompt` is not the same request as no
        // field at all on every pipeline, and this one never has to find out which.
        #expect(plain["negative_prompt"] == nil)

        var withNegative = base
        withNegative.negativePrompt = "blurry, watermark, text overlay"
        let sentBody = try withNegative.nodeBody()
        let sent = try JSONSerialization.jsonObject(with: sentBody) as? [String: Any] ?? [:]
        #expect(sent["negative_prompt"] as? String == "blurry, watermark, text overlay")

        // An empty string is treated as nothing said.
        var empty = base
        empty.negativePrompt = ""
        let blankBody = try empty.nodeBody()
        let blank = try JSONSerialization.jsonObject(with: blankBody) as? [String: Any] ?? [:]
        #expect(blank["negative_prompt"] == nil)
    }

    /// Every lane advertises sizes it can actually be asked for. A catalogue entry naming a
    /// size the queue refuses would put an option in a phone's picker that fails on submit.
    @Test func everyLaneAdvertisesSizesTheQueueWouldAccept() {
        // The set `VideoBatchQueue.append` validates against.
        let accepted: Set<String> = ["480p", "720p", "1080p"]
        for entry in VideoCatalog.all {
            #expect(!entry.supportedResolutions.isEmpty, "\(entry.id) advertises no size")
            #expect(
                Set(entry.supportedResolutions).isSubset(of: accepted),
                "\(entry.id) advertises a size the queue refuses"
            )
            #expect(!entry.supportedSeconds.isEmpty, "\(entry.id) advertises no length")
        }
        // Every lane today is a silicon-node lane, and silicon-node passes
        // `negative_prompt` straight into the pipeline for all of them.
        let everyLaneReadsOne = VideoCatalog.all.allSatisfy { $0.supportsNegativePrompt }
        #expect(everyLaneReadsOne)
    }

    // MARK: - The job frame

    /// `stage`, `reason` and `mediaID` are what a phone otherwise had to poll
    /// `GET /video/queue` beside the stream to learn. Each one has to be a change the pump
    /// notices, or the frame carrying it is never sent.
    @MainActor
    @Test func aJobFrameIsResentWhenItsStageReasonOrResultChanges() {
        func snapshot(_ job: ControlAPI.JobEvent) -> BuddyEventPump.Snapshot {
            .init(
                status: .init(
                    state: "idle", loadedModelID: nil, loadedModelName: nil,
                    contextLength: nil, expertStreaming: false,
                    lastGenerationTokensPerSecond: nil
                ),
                downloads: [:], jobs: [job.id: job]
            )
        }
        let running = ControlAPI.JobEvent(
            id: "9C2F-0001", kind: "video", status: "running", title: "Opening shot",
            fraction: 0.33, stage: "video-denoise 10/30"
        )

        func jobs(_ events: [BuddyEvent]) -> [ControlAPI.JobEvent] {
            events.compactMap { event in
                guard case .job(let job) = event else { return nil }
                return job
            }
        }

        // The stage moving is news on its own: the fraction can sit still for a minute
        // while the renderer changes what it is doing.
        var later = running
        later.stage = "video-denoise 20/30"
        #expect(jobs(BuddyEventPump.changes(from: snapshot(running), to: snapshot(later)))
            .first?.stage == "video-denoise 20/30")

        // Finishing carries the id to fetch, which is the frame a notification is written
        // from.
        var finished = running
        finished.status = "completed"
        finished.stage = nil
        finished.fraction = nil
        finished.mediaID = "bWVkaWEtY2xpcC1leGFt"
        let done = jobs(BuddyEventPump.changes(from: snapshot(running), to: snapshot(finished)))
        #expect(done.first?.mediaID == "bWVkaWEtY2xpcC1leGFt")
        #expect(done.first?.status == "completed")

        // Failing carries the sentence, and nothing to fetch.
        var failed = running
        failed.status = "failed"
        failed.stage = nil
        failed.reason = "silicon-node ran out of VRAM at the decode stage."
        let broke = jobs(BuddyEventPump.changes(from: snapshot(running), to: snapshot(failed)))
        #expect(broke.first?.reason == "silicon-node ran out of VRAM at the decode stage.")
        #expect(broke.first?.mediaID == nil)

        // And an unchanged job is not resent.
        #expect(jobs(BuddyEventPump.changes(from: snapshot(running), to: snapshot(running)))
            .isEmpty)
    }
}
