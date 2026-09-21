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
            #expect(await registry.entry(id: id, within: [directory.path])?.contentType == "video/mp4")
            try FileManager.default.removeItem(at: clip)
            #expect(await registry.entry(id: id, within: [directory.path]) == nil)
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
            #expect(await second.entry(id: id, within: [directory.path])?.path == clip.path)
            // And the same path still mints the same id rather than a second one.
            #expect(await second.register(path: clip.path, within: [directory.path]) == id)
        }
    }

    // MARK: - What a body is, read off bytes that may not all be there

    /// B1's shape, pinned: the `ftyp` sniff proved eight bytes and then read twelve.
    ///
    /// Eight to eleven bytes starting `....ftyp` is a perfectly ordinary thing for a
    /// truncated upload to be, and it trapped the whole app — every paired device, the MCP
    /// bridge, the gateway and the window the owner was looking at, from one request.
    @Test func aTruncatedHeaderIsRefusedRatherThanTrappingTheApp() {
        let ftyp: [UInt8] = [0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70]
        // Exactly the marker and nothing after it, and every length up to the brand.
        for count in 8...11 {
            let truncated = Data(ftyp.prefix(count))
            #expect(MediaSniffer.kind(of: truncated) == nil, "\(count) bytes")
        }
        // Twelve is the first length at which the brand exists to be read.
        let mp4 = Data(ftyp + Array("isom".utf8))
        #expect(MediaSniffer.kind(of: mp4)?.fileExtension == "mp4")
        let quicktime = Data(ftyp + Array("qt  ".utf8))
        #expect(MediaSniffer.kind(of: quicktime)?.contentType == "video/quicktime")

        // And every other branch, at one byte less than it needs and at exactly enough.
        let shortened: [(String, [UInt8])] = [
            ("png", [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x08]),
            ("jpeg", [0xFF, 0xD8, 0xFF]),
            ("gif", [0x47, 0x49, 0x46, 0x38]),
            ("webm", [0x1A, 0x45, 0xDF, 0xA3]),
            ("webp", Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WEBP".utf8)),
        ]
        for (label, bytes) in shortened {
            for count in 0..<bytes.count {
                // Never a trap, whatever it answers.
                _ = MediaSniffer.kind(of: Data(bytes.prefix(count)))
            }
            _ = label
        }
        #expect(MediaSniffer.kind(of: Data())  == nil)
    }

    // MARK: - GET /media/{id}

    @Test func aFullDeviceFetchesAResultByIdAndNobodyFetchesWithoutAToken() async throws {
        try await withServer { fixture in
            let clip = try fixture.writeOutput(named: "clip.mp4", bytes: Self.mp4Bytes(count: 4096))
            let id = try #require(
                await fixture.registry.register(path: clip.path, within: [fixture.outputs.path])
            )

            let full = try await fixture.pair(name: "Studio phone")
            let chat = try await fixture.pair(name: "Lent out", scope: .chat)

            let (status, body) = try await fixture.phone.call(
                "GET", "/media/\(id)", token: full.token
            )
            #expect(status == 200)
            #expect(body.count == 4096)

            // And the loopback listener serves it too — the MCP bridge and this Mac's own
            // tools reach the same route with the control token.
            #expect(try await fixture.local.status(
                "GET", "/media/\(id)", token: fixture.local.token
            ) == 200)

            // No token, a guessed token, and a token from a device that has been revoked.
            #expect(try await fixture.phone.status("GET", "/media/\(id)", token: nil) == 401)
            #expect(try await fixture.phone.status("GET", "/media/\(id)", token: "guessed") == 401)
            _ = await fixture.devices.revoke(deviceID: chat.deviceID)
            #expect(try await fixture.phone.status("GET", "/media/\(id)", token: chat.token) == 401)
        }
    }

    /// The scope split that is decided per id rather than per route.
    ///
    /// A chat-only device is the one that was lent out, or left at the office. It may see
    /// what the Mac has been making — the queue has told it that since the queue existed,
    /// and a poster is a few kilobytes of that — but pulling the renders themselves down
    /// onto a device the owner does not have in their hand is the permission they withheld.
    @Test func aChatOnlyDeviceGetsThePosterAndNotTheRender() async throws {
        try await withServer { fixture in
            let clip = try fixture.writeOutput(named: "clip.mp4", bytes: Self.mp4Bytes(count: 512))
            await fixture.host.setQueueFile(clip.path)
            let full = try await fixture.pair(name: "Studio phone")
            let chat = try await fixture.pair(name: "Lent out", scope: .chat)

            // The queue view is open to both, and carries both ids to both.
            let view = try JSONDecoder().decode(
                ControlAPI.VideoQueueView.self,
                from: try await fixture.phone.call(
                    "GET", "/video/queue", token: chat.token
                ).1
            )
            let item = try #require(view.items.first)
            let render = try #require(item.mediaID)
            let poster = try #require(item.thumbnailMediaID)

            // The picture of it: yes.
            #expect(try await fixture.phone.status(
                "GET", "/media/\(poster)", token: chat.token
            ) == 200)
            // The thing itself: not on this device.
            let (refused, body) = try await fixture.phone.call(
                "GET", "/media/\(render)", token: chat.token
            )
            #expect(refused == 403)
            let sentence = try JSONDecoder().decode(ControlAPI.ErrorResponse.self, from: body)
            #expect(sentence.error == ControlServer.fullResultsNeedFullControl)
            // Its own sentence, not the general chat-only one: this is a route the device
            // may otherwise use, and being told "pair again" about all of it would be wrong.
            #expect(sentence.error != ControlServer.chatOnlyRefusal)

            // Full control gets both, which is what makes the refusal about scope rather
            // than about the file.
            for id in [poster, render] {
                #expect(try await fixture.phone.status(
                    "GET", "/media/\(id)", token: full.token
                ) == 200)
            }
            // A 3D file is a render too, whatever its type.
            let mesh = try fixture.writeOutput(named: "kettle.obj", bytes: Data("v 0 0 0\n".utf8))
            let meshID = try #require(
                await fixture.registry.register(path: mesh.path, within: [fixture.outputs.path])
            )
            #expect(try await fixture.phone.status(
                "GET", "/media/\(meshID)", token: chat.token
            ) == 403)
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
            #expect(await registry.entry(id: staleID, within: [directory.path]) == nil)
            #expect(await registry.entry(id: freshID, within: [directory.path]) != nil)
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

    private func withServer(_ body: (BuddyMediaFixture) async throws -> Void) async throws {
        try await BuddyMediaFixture.withServer(body)
    }
}

// MARK: - One server, two suites

/// A control server with output folders, an uploads root and a poster cache, all inside a
/// temporary directory. Shared by both suites in this file so there is one answer to "what
/// does a media server look like" rather than two that drift.
struct BuddyMediaFixture {
    let server: ControlServer
    let local: TestClient
    let phone: TestClient
    /// The paired-device store, beside the media one.
    let devices: BuddyRegistry
    let registry: MediaRegistry
    let host: MediaTestHost
    let directory: URL
    let outputs: URL
    let uploads: URL

    /// Kept for the tests written before the rename.
    var registry2: BuddyRegistry { devices }

    func writeOutput(named name: String, bytes: Data) throws -> URL {
        let url = outputs.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    func pair(
        name: String = "Galaxy S24 Ultra", scope: BuddyScope = .full
    ) async throws -> ControlAPI.BuddyPairResponse {
        let invitation = await devices.invite(
            host: "127.0.0.1", port: phone.port, scope: scope
        )
        let (status, body) = try await phone.call(
            "POST", "/buddy/pair", token: nil,
            body: #"{"code":"\#(invitation.code)","deviceName":"\#(name)","platform":"android"}"#
        )
        #expect(status == 200)
        return try JSONDecoder().decode(ControlAPI.BuddyPairResponse.self, from: body)
    }

    static func withServer(
        writeDeadline: Duration = ControlServer.defaultEventWriteDeadline,
        uploadSweepInterval: TimeInterval = ControlServer.defaultUploadSweepInterval,
        swarmToken: String? = nil,
        _ body: (BuddyMediaFixture) async throws -> Void
    ) async throws {
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
            uploadSweepInterval: uploadSweepInterval,
            eventWriteDeadline: writeDeadline,
            discoverTailnetAddress: { nil }
        )

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 64
        configuration.timeoutIntervalForRequest = 30
        // Media is now deliberately cacheable — `private, max-age=3600`, which is the whole
        // point of the ETag beside it. That makes URLSession's own cache a liar in a test:
        // a second request for the same id would be answered locally, and an assertion
        // about a 401 or a 403 would be an assertion about Foundation. The one test that
        // asks about caching on purpose reads the header rather than the cache.
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        try await server.start(exposeToTailnet: swarmToken != nil, swarmToken: swarmToken)
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

        try await body(BuddyMediaFixture(
            server: server,
            local: TestClient(port: handshake.port, token: handshake.token, session: session),
            phone: TestClient(port: tailnetPort, token: handshake.token, session: session),
            devices: devices, registry: media, host: host,
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

    private var roots: [String]
    private var queueFile: String?
    /// What the image routes were handed, after the server resolved whatever was sent.
    private(set) var lastImagePath: String?
    /// What `POST /mesh/generate` was handed, after the server resolved whatever the
    /// caller sent. Nil means the host was never reached, which is what a refusal looks
    /// like from down here.
    private(set) var lastMeshImagePath: String?
    private(set) var installRequests: [ControlAPI.LoadRequest] = []

    init(roots: [String]) { self.roots = roots }

    func setQueueFile(_ path: String?) { queueFile = path }
    func forgetMesh() { lastMeshImagePath = nil }
    /// The owner moving their output folder, from the server's point of view.
    func setRoots(_ roots: [String]) { self.roots = roots }

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
        lastImagePath = request.initImagePath
        return .init(
            path: request.initImagePath ?? "", elapsedSeconds: 1, peakMemoryBytes: nil,
            predictedPeakBytes: 1, model: "fixture"
        )
    }

    /// Answers rather than traps, because `/image/plan` is now gated like the render it
    /// plans and the test that proves it has to get past the gate.
    func planImage(_ request: ControlAPI.ImageRequest) async throws -> ControlAPI.ImagePlan {
        lastImagePath = request.initImagePath
        return .init(
            width: 1024, height: 1024, steps: 8, quantization: "8-bit",
            peakBytes: 1, peakPhase: "Decode", budgetBytes: 2, verdict: "fits",
            phases: [], suggestions: [], notes: []
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
        installRequests.append(request)
        return "fixture download accepted"
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
    func meshModels() async -> [ControlAPI.MeshModel] { [] }
    func planMesh(_ request: ControlAPI.MeshRequest) async throws -> ControlAPI.MeshPlan {
        lastMeshImagePath = request.imagePath
        return .init(
            model: "fixture", peakBytes: 1, peakPhase: "Bake", budgetBytes: 2,
            verdict: "fits", isRemote: false, phases: [], suggestions: [], notes: []
        )
    }
    func videoModels() async -> [ControlAPI.VideoModel] { [] }
    func generateVideo(
        _ request: ControlAPI.VideoGenerateRequest
    ) async throws -> ControlAPI.VideoResponse {
        // Reached only when the subject resolved; the path-from-a-device test asserts it
        // is never reached at all.
        lastImagePath = request.imagePath
        return .init(file: queueFile ?? "", node: "fixture", model: "fixture", elapsedSeconds: 1)
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

    /// Which of a queue item's fields become a frame, and which are withheld.
    ///
    /// Two of the three are rules rather than copies. A clip that failed transiently keeps
    /// its `error` while it waits to be retried — it is how the queue remembers what went
    /// wrong last time — and a phone showing that beside a pending status would be
    /// announcing a failure the Mac has not given up on. A clip waiting its turn has no
    /// stage, because the renderer has not said anything about it.
    @Test func onlyAGivenUpOnClipCarriesAReasonAndOnlyAFollowedOneAStage() {
        func item(_ status: String, error: String?) -> ControlAPI.VideoQueueView.Item {
            .init(
                id: "9C2F-0001", batchID: "9C2F", title: "Opening shot", prompt: "A tram",
                scene: 1, variation: 1, seed: 1, modelID: "hailuo-h3", seconds: 5,
                resolution: "720p", h3Turbo: nil, status: status, nodeJobID: nil, file: nil,
                outputDirectory: "/Users/you/Movies", error: error, uncertainSubmission: false
            )
        }

        // Given up on: the sentence travels.
        let failed = AppModel.jobEvent(
            for: item("failed", error: "silicon-node ran out of VRAM."),
            active: false, fraction: nil, stage: nil, mediaID: nil
        )
        #expect(failed.reason == "silicon-node ran out of VRAM.")

        // Waiting to be retried after a transient failure: the queue still remembers the
        // error, and the phone is not told the render failed.
        for status in ["pending", "submitting", "rendering", "completed"] {
            let frame = AppModel.jobEvent(
                for: item(status, error: "The node stopped answering; it may still be rendering."),
                active: false, fraction: nil, stage: nil, mediaID: nil
            )
            #expect(frame.reason == nil, "\(status) carried a reason")
        }

        // Stage and fraction belong to the clip the Mac is actually following.
        let followed = AppModel.jobEvent(
            for: item("rendering", error: nil), active: true,
            fraction: 0.4, stage: "video-denoise 12/30", mediaID: "an-id"
        )
        #expect(followed.stage == "video-denoise 12/30")
        #expect(followed.fraction == 0.4)
        let queued = AppModel.jobEvent(
            for: item("pending", error: nil), active: false,
            fraction: 0.4, stage: "video-denoise 12/30", mediaID: nil
        )
        #expect(queued.stage == nil)
        #expect(queued.fraction == nil)
    }
}


/// The fixes the critic's review of #45 asked for, each pinned by the thing that would
/// have to break for it to regress.
@Suite("Silicon Buddy media, the hard edges")
struct BuddyMediaEdgeTests {

    // MARK: - B2: the upload ceiling is the upload ceiling

    /// The per-route limit used to be clamped by the general one, so the route advertised
    /// 24 MiB, refused at 16, and quoted 24 in the refusal.
    @Test func theUploadCeilingIsTwentyFourMiBAndSaysSoWhenItIsPassed() async throws {
        try await BuddyMediaFixture.withServer { fixture in
            let paired = try await fixture.pair()

            // Comfortably past the 16 MiB general ceiling, which is where this used to
            // fail, and comfortably inside the one this route advertises.
            let eighteen = BuddyMediaRoutesTests.jpegBytes(count: 18 * 1_048_576)
            #expect(eighteen.count > HTTPRequest.maximumBody)
            let (accepted, body) = try await fixture.phone.call(
                "POST", "/uploads", token: paired.token, data: eighteen,
                contentType: "image/jpeg"
            )
            #expect(accepted == 200)
            let upload = try JSONDecoder().decode(ControlAPI.UploadResponse.self, from: body)
            #expect(upload.bytes == eighteen.count)

            // And one byte past the advertised figure is refused — on the *declared*
            // length, before a byte of it is read, which is the whole point of having a
            // cap rather than receiving the thing and then disapproving of it. Sent as a
            // bare head for exactly that reason: if the server were reading first, this
            // request would hang instead of being answered.
            let over = try await SilentReader.exchange(
                port: fixture.phone.port,
                request: "POST /uploads HTTP/1.1\r\nHost: 127.0.0.1\r\n"
                    + "Authorization: Bearer \(paired.token)\r\n"
                    + "Content-Type: image/jpeg\r\n"
                    + "Content-Length: \(BuddyUploads.maximumBytes + 1)\r\n\r\n"
            )
            #expect(over.contains("413 Payload Too Large"))
            // Quoting the figure this route actually has, and not the general one it used
            // to be silently clamped to.
            #expect(over.contains("\(BuddyUploads.maximumBytes)"))
            #expect(!over.contains("\(HTTPRequest.maximumBody)"))
        }
    }

    // MARK: - S3: the raised ceiling belongs to a caller, not to a path

    /// Pointing 24 MiB at `/uploads` with a token nobody issued buys the ordinary 4 MiB.
    @Test func onlyAnIdentifiedFullDeviceGetsTheRaisedCeiling() async throws {
        try await BuddyMediaFixture.withServer { fixture in
            let full = try await fixture.pair(name: "Studio phone")
            let chat = try await fixture.pair(name: "Lent out", scope: .chat)
            let big = BuddyMediaRoutesTests.jpegBytes(count: 8 * 1_048_576)
            #expect(big.count > BuddyLimits.requestBodyBytes)

            // A bearer that is not a device at all: refused on length, before the body.
            let (guessed, why) = try await fixture.phone.call(
                "POST", "/uploads", token: "guessed", data: big, contentType: "image/jpeg"
            )
            #expect(guessed == 413)
            let sentence = try JSONDecoder().decode(ControlAPI.ErrorResponse.self, from: why)
            #expect(sentence.error.contains("\(BuddyLimits.requestBodyBytes)"))

            // A chat-only device may not use this route at all, so it does not get its
            // ceiling either — refused on length rather than reaching the 403.
            #expect(try await fixture.phone.status(
                "POST", "/uploads", token: chat.token, data: big, contentType: "image/jpeg"
            ) == 413)

            // A revoked device is a bearer nobody issued, from the next request onward.
            #expect(try await fixture.phone.status(
                "POST", "/uploads", token: full.token, data: big, contentType: "image/jpeg"
            ) == 200)
            _ = await fixture.devices.revoke(deviceID: full.deviceID)
            #expect(try await fixture.phone.status(
                "POST", "/uploads", token: full.token, data: big, contentType: "image/jpeg"
            ) == 413)
        }
    }

    // MARK: - B3 + S5: a device may never name a path, on any route that takes one

    /// The mutation this is proof against: dropping any one of these four routes out of the
    /// resolver. `/image/plan` really was dropped, and a planner that answers "no image at
    /// that path" differently from a plan is a yes/no oracle for every path on the Mac.
    @Test func noRouteThatTakesASubjectLetsADeviceNameAPath() async throws {
        try await BuddyMediaFixture.withServer { fixture in
            let paired = try await fixture.pair()
            let body =
                #"{"prompt":"a kettle","imagePath":"/etc/passwd","initImagePath":"/etc/passwd"}"#

            for path in ["/mesh/plan", "/mesh/generate", "/image/plan", "/image/generate",
                         "/video/generate"] {
                let status = try await fixture.phone.status(
                    "POST", path, token: paired.token, body: body
                )
                #expect(status == 400, "\(path) accepted a path from a device")
            }
            // The host is never reached, which is the part that matters: a refusal that
            // happened after the planner had already looked would still be an oracle.
            #expect(await fixture.host.lastMeshImagePath == nil)
            #expect(await fixture.host.lastImagePath == nil)

            // And the same routes take an id perfectly well.
            let (_, answer) = try await fixture.phone.call(
                "POST", "/uploads", token: paired.token,
                data: BuddyMediaRoutesTests.jpegBytes(count: 900), contentType: "image/jpeg"
            )
            let upload = try JSONDecoder().decode(ControlAPI.UploadResponse.self, from: answer)
            #expect(try await fixture.phone.status(
                "POST", "/image/plan", token: paired.token,
                body: #"{"prompt":"a kettle","uploadID":"\#(upload.uploadID)"}"#
            ) == 200)
            #expect(await fixture.host.lastImagePath != nil)
        }
    }

    /// One device's upload is not another's, by either kind of id.
    @Test func oneDevicesUploadIsNotAnothersByEitherId() async throws {
        try await BuddyMediaFixture.withServer { fixture in
            let alice = try await fixture.pair(name: "Alice's phone")
            let bob = try await fixture.pair(name: "Bob's phone")

            let (_, body) = try await fixture.phone.call(
                "POST", "/uploads", token: alice.token,
                data: BuddyMediaRoutesTests.jpegBytes(count: 700), contentType: "image/jpeg"
            )
            let hers = try JSONDecoder().decode(ControlAPI.UploadResponse.self, from: body)

            // Hers works.
            #expect(try await fixture.phone.status(
                "GET", "/media/\(hers.mediaID)", token: alice.token
            ) == 200)
            // His does not — and is told the same thing an id that never existed is told,
            // because "that is not yours" and "that does not exist" must look identical or
            // the route is an oracle for what other phones have sent.
            let (refused, why) = try await fixture.phone.call(
                "GET", "/media/\(hers.mediaID)", token: bob.token
            )
            #expect(refused == 404)
            #expect(
                try JSONDecoder().decode(ControlAPI.ErrorResponse.self, from: why).error
                    == ControlServer.noSuchMedia
            )

            // Nor by naming it as the subject of a render, by either id.
            for field in ["uploadID": hers.uploadID, "mediaID": hers.mediaID] {
                #expect(try await fixture.phone.status(
                    "POST", "/mesh/generate", token: bob.token,
                    body: #"{"\#(field.key)":"\#(field.value)"}"#
                ) == 404, "\(field.key)")
            }
            #expect(await fixture.host.lastMeshImagePath == nil)
            // …while she can.
            #expect(try await fixture.phone.status(
                "POST", "/mesh/generate", token: alice.token,
                body: #"{"mediaID":"\#(hers.mediaID)"}"#
            ) == 200)
        }
    }

    // MARK: - S1: an id is a promise about a file, rechecked rather than remembered

    /// Registered honestly, then swapped for a symlink out of the roots. The check at
    /// registration already happened; this is the one that has to happen again.
    @Test func aFileSwappedForALinkAfterRegistrationStopsBeingServed() async throws {
        try await BuddyMediaFixture.withServer { fixture in
            let secret = fixture.directory.appendingPathComponent("private.png")
            try Data("not yours".utf8).write(to: secret)
            let clip = try fixture.writeOutput(
                named: "clip.mp4", bytes: BuddyMediaRoutesTests.mp4Bytes(count: 256)
            )
            let id = try #require(
                await fixture.registry.register(path: clip.path, within: [fixture.outputs.path])
            )
            let paired = try await fixture.pair()
            #expect(try await fixture.phone.status(
                "GET", "/media/\(id)", token: paired.token
            ) == 200)

            // The swap, after the fact.
            try FileManager.default.removeItem(at: clip)
            try FileManager.default.createSymbolicLink(at: clip, withDestinationURL: secret)
            #expect(FileManager.default.fileExists(atPath: clip.path))

            #expect(try await fixture.phone.status(
                "GET", "/media/\(id)", token: paired.token
            ) == 404)
            // And the entry is dropped rather than left to be tried again.
            #expect(await fixture.registry.entry(
                id: id, within: [fixture.outputs.path]
            ) == nil)
        }
    }

    /// The swap that the roots check alone does not catch, and that the identity check
    /// exists for.
    ///
    /// A link from inside an output folder to *another file inside a root* passes "is this
    /// inside the roots?" perfectly well — and serves bytes the id was never a promise
    /// about. Point it at another device's upload and the id for a render this Mac made
    /// becomes a way to read a photograph that belongs to somebody else's phone, past both
    /// the per-device rule and the chat-scope one, because both of those ask about the
    /// *registered* path and the registered path is still where it always was.
    @Test func aLinkToAnotherFileInsideTheRootsIsStillNotTheFileThatWasPromised() async throws {
        try await BuddyMediaFixture.withServer { fixture in
            let alice = try await fixture.pair(name: "Alice's phone")
            let bob = try await fixture.pair(name: "Bob's phone")
            let secret = BuddyMediaRoutesTests.jpegBytes(count: 321)
            _ = try await fixture.phone.call(
                "POST", "/uploads", token: alice.token, data: secret, contentType: "image/jpeg"
            )
            let hers = try #require(
                try FileManager.default.contentsOfDirectory(
                    at: fixture.uploads.appendingPathComponent(alice.deviceID),
                    includingPropertiesForKeys: nil
                ).first
            )

            // An ordinary render of Bob's own, registered honestly.
            let clip = try fixture.writeOutput(
                named: "clip.mp4", bytes: BuddyMediaRoutesTests.mp4Bytes(count: 256)
            )
            let id = try #require(
                await fixture.registry.register(path: clip.path, within: [fixture.outputs.path])
            )
            #expect(try await fixture.phone.status(
                "GET", "/media/\(id)", token: bob.token
            ) == 200)

            // …swapped for a link to hers. Inside a root, so the roots check is content.
            try FileManager.default.removeItem(at: clip)
            try FileManager.default.createSymbolicLink(at: clip, withDestinationURL: hers)

            let (status, body) = try await fixture.phone.call(
                "GET", "/media/\(id)", token: bob.token
            )
            #expect(status == 404)
            #expect(body != secret)
        }
    }

    /// The owner moves their output folder. Every id minted against the old one stops
    /// working, because the roots are checked now and not at registration.
    @Test func idsStopWorkingWhenTheirRootStopsBeingOne() async throws {
        try await BuddyMediaFixture.withServer { fixture in
            let clip = try fixture.writeOutput(
                named: "clip.mp4", bytes: BuddyMediaRoutesTests.mp4Bytes(count: 256)
            )
            let id = try #require(
                await fixture.registry.register(path: clip.path, within: [fixture.outputs.path])
            )
            let paired = try await fixture.pair()
            #expect(try await fixture.phone.status(
                "GET", "/media/\(id)", token: paired.token
            ) == 200)

            await fixture.host.setRoots([fixture.directory.appendingPathComponent("Other").path])
            #expect(try await fixture.phone.status(
                "GET", "/media/\(id)", token: paired.token
            ) == 404)
        }
    }

    // MARK: - S2: a reader that stops reading does not keep a connection slot

    /// There are sixty-four of them. A phone that walks out of range mid-clip leaves a
    /// `send` that never completes and never errors — `Task.cancel` cannot reach into
    /// Network.framework, so without a deadline that slot is held until the app quits.
    @Test func aReaderThatStopsReadingIsGivenUpOn() async throws {
        try await BuddyMediaFixture.withServer(writeDeadline: .milliseconds(200)) { fixture in
            // Bigger than any socket buffer, so the send genuinely stalls rather than
            // completing into the kernel and looking like success.
            let clip = try fixture.writeOutput(
                named: "big.mp4", bytes: BuddyMediaRoutesTests.mp4Bytes(count: 8 * 1_048_576)
            )
            let id = try #require(
                await fixture.registry.register(path: clip.path, within: [fixture.outputs.path])
            )
            let paired = try await fixture.pair()

            let silent = SilentReader(port: fixture.phone.port)
            try await silent.connect()
            try await silent.send(
                "GET /media/\(id) HTTP/1.1\r\nHost: 127.0.0.1\r\n"
                    + "Authorization: Bearer \(paired.token)\r\n\r\n"
            )
            // It never reads a byte. The server writes until the window closes, then the
            // deadline ends it.
            let deadline = ContinuousClock.now + .seconds(10)
            while await fixture.server.openConnections > 0 {
                guard ContinuousClock.now < deadline else {
                    Issue.record("The stalled reader kept its connection slot.")
                    break
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(await fixture.server.openConnections == 0)
            silent.stop()

            // And the server is still serving, which is the point of having let go.
            #expect(try await fixture.phone.status(
                "GET", "/health", token: paired.token
            ) == 200)
        }
    }

    // MARK: - S4 + S7: the headers a result carries, and the ones everything else does

    @Test func mediaIsCacheableAndEverythingElseIsNot() async throws {
        try await BuddyMediaFixture.withServer { fixture in
            let image = try fixture.writeOutput(
                named: "still.png", bytes: BuddyMediaRoutesTests.pngBytes(count: 200)
            )
            let mesh = try fixture.writeOutput(named: "kettle.glb", bytes: Data("glTF".utf8))
            let imageID = try #require(
                await fixture.registry.register(path: image.path, within: [fixture.outputs.path])
            )
            let meshID = try #require(
                await fixture.registry.register(path: mesh.path, within: [fixture.outputs.path])
            )
            let paired = try await fixture.pair()

            let picture = try await fixture.phone.range("/media/\(imageID)", token: paired.token)
            #expect(picture.status == 200)
            // Cacheable, privately, which is what makes the ETag worth having.
            #expect(picture["Cache-Control"] == ControlServer.mediaCacheControl)
            #expect(picture["Cache-Control"]?.contains("no-store") != true)
            #expect(picture["X-Content-Type-Options"] == "nosniff")
            // A picture is meant to be shown.
            #expect(picture["Content-Disposition"] == nil)

            // A mesh is not. And the filename offered is the id, so nothing about this
            // Mac's folders travels with it.
            let model = try await fixture.phone.range("/media/\(meshID)", token: paired.token)
            let disposition = try #require(model["Content-Disposition"])
            #expect(disposition.hasPrefix("attachment"))
            #expect(disposition.contains(meshID))
            #expect(!disposition.contains(fixture.outputs.lastPathComponent))
            #expect(!disposition.contains("kettle"))

            // Everything this server says about itself stays uncacheable.
            let status = try await fixture.phone.range("/status", token: paired.token)
            #expect(status["Cache-Control"] == "no-store")
        }
    }

    /// A 304 has no body, so it has no business claiming a length for one.
    @Test func anUnchangedFetchIsFramedAsTheBodylessThingItIs() async throws {
        try await BuddyMediaFixture.withServer { fixture in
            let image = try fixture.writeOutput(
                named: "still.png", bytes: BuddyMediaRoutesTests.pngBytes(count: 200)
            )
            let id = try #require(
                await fixture.registry.register(path: image.path, within: [fixture.outputs.path])
            )
            let paired = try await fixture.pair()
            let first = try await fixture.phone.range("/media/\(id)", token: paired.token)
            let tag = try #require(first["ETag"])

            let raw = try await SilentReader.exchange(
                port: fixture.phone.port,
                request: "GET /media/\(id) HTTP/1.1\r\nHost: 127.0.0.1\r\n"
                    + "Authorization: Bearer \(paired.token)\r\n"
                    + "If-None-Match: \(tag)\r\n\r\n"
            )
            #expect(raw.contains("304 Not Modified"))
            #expect(!raw.lowercased().contains("content-length"))
            #expect(raw.contains("ETag: \(tag)"))
        }
    }

    /// A multi-range ask wants `multipart/byteranges`, which this server does not write.
    /// Answering the first range under a 206 would hand a player bytes it did not ask for.
    @Test func aMultiRangeAskGetsTheWholeFileRatherThanTheFirstRange() async throws {
        try await BuddyMediaFixture.withServer { fixture in
            let payload = BuddyMediaRoutesTests.mp4Bytes(count: 1000)
            let clip = try fixture.writeOutput(named: "clip.mp4", bytes: payload)
            let id = try #require(
                await fixture.registry.register(path: clip.path, within: [fixture.outputs.path])
            )
            let paired = try await fixture.pair()

            let answer = try await fixture.phone.range(
                "/media/\(id)", token: paired.token, range: "bytes=0-99,200-299"
            )
            #expect(answer.status == 200)
            #expect(answer.body == payload)
            #expect(answer["Content-Range"] == nil)
        }
    }

    // MARK: - S6: the sweep runs on a poll, not only on an arrival

    /// A device that uploads once and then only ever polls used to leave that upload for
    /// good.
    @Test func pollingTheQueueTakesOutWhatHasExpired() async throws {
        // An hour between sweeps in the app, because what they look for is a week old and
        // a directory walk per poll would be a walk a second for nothing. The test
        // compresses the hour; the default is asserted below.
        #expect(ControlServer.defaultUploadSweepInterval == 3600)
        try await BuddyMediaFixture.withServer(uploadSweepInterval: 0) { fixture in
            let paired = try await fixture.pair()
            let (_, body) = try await fixture.phone.call(
                "POST", "/uploads", token: paired.token,
                data: BuddyMediaRoutesTests.jpegBytes(count: 600), contentType: "image/jpeg"
            )
            let upload = try JSONDecoder().decode(ControlAPI.UploadResponse.self, from: body)
            #expect(try await fixture.phone.status(
                "GET", "/media/\(upload.mediaID)", token: paired.token
            ) == 200)

            // Age it past the seven days, without touching the server.
            let folder = fixture.uploads.appendingPathComponent(paired.deviceID)
            for file in try FileManager.default.contentsOfDirectory(at: folder,
                                                                    includingPropertiesForKeys: nil) {
                try FileManager.default.setAttributes(
                    [.modificationDate: Date().addingTimeInterval(-8 * 24 * 3600)],
                    ofItemAtPath: file.path
                )
            }

            // Nothing new is uploaded. The only thing that happens is a poll.
            #expect(try await fixture.phone.status(
                "GET", "/video/queue", token: paired.token
            ) == 200)

            #expect(!FileManager.default.fileExists(atPath: folder.path))
            #expect(try await fixture.phone.status(
                "GET", "/media/\(upload.mediaID)", token: paired.token
            ) == 404)
        }
    }

    // MARK: - S8: a write failure says nothing about this Mac's disk

    @Test func anUnwritableUploadRootIsRefusedWithoutNamingAPath() async throws {
        try await BuddyMediaFixture.withServer { fixture in
            let paired = try await fixture.pair()
            // The uploads root is a *file*, so creating a folder under it cannot work —
            // the same shape as a full disk or a read-only volume, without needing one.
            try FileManager.default.removeItem(at: fixture.uploads)
            try Data("in the way".utf8).write(to: fixture.uploads)

            let (status, body) = try await fixture.phone.call(
                "POST", "/uploads", token: paired.token,
                data: BuddyMediaRoutesTests.jpegBytes(count: 400), contentType: "image/jpeg"
            )
            #expect(status == 500)
            let sentence = try JSONDecoder().decode(ControlAPI.ErrorResponse.self, from: body)
            #expect(sentence.error == ControlServer.uploadNotSaved)
            // Nothing about where anything is.
            #expect(!sentence.error.contains("/"))
            #expect(!sentence.error.contains(fixture.directory.lastPathComponent))
        }
    }

    // MARK: - The table does not grow for ever

    @Test func theTableEvictsItsOldestIdsRatherThanGrowingWithoutABound() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("buddy-media-bound-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let registry = MediaRegistry(url: nil)
        var first: String?
        // One past the ceiling, oldest first.
        for index in 0...MediaRegistry.maximumEntries {
            let file = directory.appendingPathComponent("clip-\(index).mp4")
            try Data("x".utf8).write(to: file)
            let id = await registry.register(path: file.path, within: [directory.path])
            if index == 0 { first = id }
        }
        #expect(await registry.count == MediaRegistry.maximumEntries)
        // The oldest link is the one that went, and re-polling mints it again.
        let oldest = try #require(first)
        #expect(await registry.entry(id: oldest, within: [directory.path]) == nil)
        let again = await registry.register(
            path: directory.appendingPathComponent("clip-0.mp4").path, within: [directory.path]
        )
        #expect(again != nil)
        #expect(again != oldest)
    }
}

// MARK: - A client that says nothing back

/// A raw socket that sends a request and then does not read the answer — which is what a
/// phone that walks out of range looks like to a server, and what `URLSession` will never
/// do for us because it always drains.
final class SilentReader: @unchecked Sendable {

    private let connection: NWConnection

    init(port: Int) {
        connection = NWConnection(
            host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp
        )
    }

    func connect() async throws {
        connection.start(queue: .global(qos: .userInitiated))
        let deadline = ContinuousClock.now + .seconds(5)
        while true {
            if case .ready = connection.state { return }
            guard ContinuousClock.now < deadline else { throw BuddyTestError.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func send(_ text: String) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: Data(text.utf8), completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    func stop() { connection.cancel() }

    /// One request and whatever comes back, as text. For the assertions that are about the
    /// response *head* — which `URLSession` normalises away.
    static func exchange(port: Int, request: String) async throws -> String {
        let reader = SilentReader(port: port)
        defer { reader.stop() }
        try await reader.connect()
        try await reader.send(request)
        var answer = Data()
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            let chunk: Data? = try? await withCheckedThrowingContinuation { continuation in
                reader.connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
                    data, _, complete, error in
                    if let error { continuation.resume(throwing: error) }
                    else if complete && (data?.isEmpty ?? true) { continuation.resume(returning: nil) }
                    else { continuation.resume(returning: data) }
                }
            }
            guard let chunk else { break }
            answer.append(chunk)
            // Stop once the head *and* whatever short body followed it have arrived: the
            // refusals this is used for carry their sentence in the body.
            if let end = answer.range(of: Data("\r\n\r\n".utf8)),
               answer.count > end.upperBound || answer.count > 512 { break }
        }
        return String(decoding: answer, as: UTF8.self)
    }
}
    // MARK: - What a body is, read off bytes that may not all be there

    /// B1's shape, pinned: the `ftyp` sniff proved eight bytes and then read twelve.
    ///
    /// Eight to eleven bytes starting `....ftyp` is a perfectly ordinary thing for a
    /// truncated upload to be, and it trapped the whole app — every paired device, the MCP
    /// bridge, the gateway and the window the owner was looking at, from one request.
    @Test func aTruncatedHeaderIsRefusedRatherThanTrappingTheApp() {
        let ftyp: [UInt8] = [0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70]
        // Exactly the marker and nothing after it, and every length up to the brand.
        for count in 8...11 {
            let truncated = Data(ftyp.prefix(count))
            #expect(MediaSniffer.kind(of: truncated) == nil, "\(count) bytes")
        }
        // Twelve is the first length at which the brand exists to be read.
        let mp4 = Data(ftyp + Array("isom".utf8))
        #expect(MediaSniffer.kind(of: mp4)?.fileExtension == "mp4")
        let quicktime = Data(ftyp + Array("qt  ".utf8))
        #expect(MediaSniffer.kind(of: quicktime)?.contentType == "video/quicktime")

        // And every other branch, at one byte less than it needs and at exactly enough.
        let shortened: [(String, [UInt8])] = [
            ("png", [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x08]),
            ("jpeg", [0xFF, 0xD8, 0xFF]),
            ("gif", [0x47, 0x49, 0x46, 0x38]),
            ("webm", [0x1A, 0x45, 0xDF, 0xA3]),
            ("webp", Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WEBP".utf8)),
        ]
        for (label, bytes) in shortened {
            for count in 0..<bytes.count {
                // Never a trap, whatever it answers.
                _ = MediaSniffer.kind(of: Data(bytes.prefix(count)))
            }
            _ = label
        }
        #expect(MediaSniffer.kind(of: Data())  == nil)
    }

    // MARK: - GET /media/{id}
