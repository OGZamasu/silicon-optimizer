import Foundation
import Testing
@testable import SiliconControl
@testable import SiliconUI

/// A render's answer names the file it made, and on a Mac that name is a path through the
/// owner's folders — the account name included. This Mac's own token keeps the path, because
/// its scripts and MCP tools open it; a paired phone and the swarm secret are told the file's
/// name beside the media id they fetch it by, and nothing about the folders above it.
@Suite("Mac paths in answers")
struct MacPathRedactionTests {

    private static let swarmToken = "test-shared-swarm-secret"

    /// Every render route, for a phone and for the swarm secret on both listeners, then for
    /// the Mac's own token.
    @Test func aRenderTellsAPhoneOrAPeerTheFilesNameAndTheMacItsPath() async throws {
        try await BuddyMediaFixture.withServer(swarmToken: Self.swarmToken) { fixture in
            let image = try fixture.writeOutput(
                named: "render-0001.png", bytes: BuddyMediaRoutesTests.pngBytes(count: 256)
            )
            let glb = try fixture.writeOutput(named: "kettle.glb", bytes: Data("glTF".utf8))
            let obj = try fixture.writeOutput(named: "kettle.obj", bytes: Data("v 0 0 0".utf8))
            let clip = try fixture.writeOutput(
                named: "clip.mp4", bytes: BuddyMediaRoutesTests.mp4Bytes(count: 128)
            )
            await fixture.host.setImageOutput(image.path)
            await fixture.host.setMeshOutput(glb: glb.path, obj: obj.path)
            await fixture.host.setQueueFile(clip.path)
            let phone = try await fixture.pair()

            for (label, client, token) in [
                ("phone", fixture.phone, phone.token),
                ("swarm on the tailnet", fixture.phone, Self.swarmToken),
                ("swarm on loopback", fixture.local, Self.swarmToken),
            ] {
                let rendered = try await Self.answer(
                    ControlAPI.ImageResponse.self, client, "/image/generate", token,
                    #"{"prompt":"a fox"}"#, hiding: fixture.directory
                )
                #expect(rendered.path == "render-0001.png", "\(label)")
                // The id is what fetches it, and it is still there.
                let mediaID = try #require(rendered.mediaID, "\(label)")

                let mesh = try await Self.answer(
                    ControlAPI.MeshResponse.self, client, "/mesh/generate", token,
                    #"{"mediaID":"\#(mediaID)"}"#, hiding: fixture.directory
                )
                #expect(mesh.glbPath == "kettle.glb", "\(label)")
                #expect(mesh.objPath == "kettle.obj", "\(label)")
                #expect(mesh.mediaID != nil, "\(label)")

                let video = try await Self.answer(
                    ControlAPI.VideoResponse.self, client, "/video/generate", token,
                    #"{"prompt":"a tram"}"#, hiding: fixture.directory
                )
                #expect(video.file == "clip.mp4", "\(label)")
                #expect(video.mediaID != nil, "\(label)")
            }

            // The queue: a phone's view of it (the swarm secret may not read it at all).
            let queue = try await Self.answer(
                ControlAPI.VideoQueueView.self, fixture.phone, "/video/queue", phone.token,
                nil, hiding: fixture.directory
            )
            let item = try #require(queue.items.first)
            #expect(item.file == "clip.mp4")
            #expect(item.outputDirectory == "Movies")
            #expect(item.mediaID != nil)

            // And the Mac's own token, unchanged: the absolute paths its tools open.
            let local = fixture.local
            let own = try await Self.decode(
                ControlAPI.ImageResponse.self,
                local.call("POST", "/image/generate", token: local.token,
                           body: #"{"prompt":"a fox"}"#)
            )
            #expect(own.path == image.path)
            let ownMesh = try await Self.decode(
                ControlAPI.MeshResponse.self,
                local.call("POST", "/mesh/generate", token: local.token,
                           body: #"{"mediaID":"\#(own.mediaID ?? "")"}"#)
            )
            #expect(ownMesh.glbPath == glb.path)
            #expect(ownMesh.objPath == obj.path)
            let ownVideo = try await Self.decode(
                ControlAPI.VideoResponse.self,
                local.call("POST", "/video/generate", token: local.token,
                           body: #"{"prompt":"a tram"}"#)
            )
            #expect(ownVideo.file == clip.path)
            let ownQueue = try await Self.decode(
                ControlAPI.VideoQueueView.self,
                local.call("GET", "/video/queue", token: local.token)
            )
            #expect(ownQueue.items.first?.file == clip.path)
            #expect(ownQueue.items.first?.outputDirectory == fixture.outputs.path)
        }
    }

    /// The host writes its refusals for the owner, and they quote folders. Somebody else
    /// reads the folder's own name, and `~` for the home folder.
    @Test func aRefusalQuotesNoFolderOfThisMacToAnyoneButTheMac() async throws {
        try await BuddyMediaFixture.withServer(swarmToken: Self.swarmToken) { fixture in
            let image = try fixture.writeOutput(
                named: "kettle.png", bytes: BuddyMediaRoutesTests.pngBytes(count: 64)
            )
            let mediaID = try #require(
                await fixture.registry.register(path: image.path, within: [fixture.outputs.path])
            )
            let home = NSHomeDirectory()
            let sentence = "Could not read \(fixture.outputs.path)/kettle.png, "
                + "nor \(home)/Desktop/kettle.png."
            await fixture.host.setMeshFailure(sentence)
            let phone = try await fixture.pair()

            for token in [phone.token, Self.swarmToken] {
                let (status, body) = try await fixture.phone.call(
                    "POST", "/mesh/generate", token: token, body: #"{"mediaID":"\#(mediaID)"}"#
                )
                #expect(status == 400)
                #expect(Self.message(body)
                    == "Could not read Movies/kettle.png, nor ~/Desktop/kettle.png.")
            }
            let (status, body) = try await fixture.local.call(
                "POST", "/mesh/generate", token: fixture.local.token,
                body: #"{"mediaID":"\#(mediaID)"}"#
            )
            #expect(status == 400)
            #expect(Self.message(body) == sentence)
        }
    }

    /// Whole folders, in every spelling, and nothing that merely starts the same way.
    @Test func onlyWholeFoldersAreReplacedAndNamesKeepTheirExtension() {
        let redaction = MacPathRedaction(
            roots: ["/Volumes/External/Silicon Videos", "/Users/you/Movies/Silicon/"],
            home: "/Users/you"
        )
        #expect(redaction.scrub("Wrote /Volumes/External/Silicon Videos/Lisbon/clip.mp4.")
            == "Wrote Silicon Videos/Lisbon/clip.mp4.")
        // The longest folder wins, so a root inside the home folder keeps its own name.
        #expect(redaction.scrub("/Users/you/Movies/Silicon/a.mp4 and /Users/you/Desktop/b.png")
            == "Silicon/a.mp4 and ~/Desktop/b.png")
        #expect(redaction.scrub("\"/Users/you\"") == "\"~\"")
        // Not the home folder, so not `~` — but still a path on this Mac, so its name only.
        #expect(redaction.scrub("/Users/youngest/a.png") == "a.png")
        #expect(redaction.scrub("/private/Users/you/a.png") == "~/a.png")
        #expect(redaction.scrub("/mnt/Users/you/a.png") == "/mnt/Users/you/a.png")
        #expect(redaction.scrub("No path here.") == "No path here.")

        #expect(redaction.name("/Users/you/Movies/Silicon/clip.mp4") == "clip.mp4")
        #expect(redaction.name("/Users/you/Movies/Silicon/Lisbon/") == "Lisbon")
        #expect(redaction.name("clip.mp4") == "clip.mp4")
        #expect(redaction.name("") == "")
    }

    /// A tool that fails hands back the tail of its own log, and a traceback names every
    /// folder on the way down — none of them an output root or the home folder.
    @Test func aPathOutsideEveryKnownFolderIsCutToItsName() {
        let redaction = MacPathRedaction(
            roots: ["/Volumes/External/Silicon Videos"], home: "/Users/you"
        )
        let traceback = #"File "/Volumes/External/trellis2/trellis/pipelines/base.py", line 12"#
        #expect(redaction.scrub(traceback) == #"File "base.py", line 12"#)
        #expect(redaction.scrub(
            "OSError: [Errno 2] No such file or directory: '/Volumes/External/models/ckpt.bin'"
        ) == "OSError: [Errno 2] No such file or directory: 'ckpt.bin'")
        // Folder names with spaces, and two paths in one sentence.
        #expect(redaction.scrub("copy /Volumes/External/Local Models/x.png to /private/tmp/y.png")
            == "copy x.png to y.png")
        #expect(redaction.scrub("--output=/opt/homebrew/var/mesh.glb failed")
            == "--output=mesh.glb failed")
        #expect(redaction.scrub("/usr/bin/python3: can't open file") == "python3: can't open file")
        // However the path is put: a file URL, a search path's later entries, straight
        // after a colon, in curly quotes, in backticks, in guillemets.
        #expect(redaction.scrub(
            "NSURL=file:///Volumes/External/trellis2/out/mesh.glb, NSUnderlyingError"
        ) == "NSURL=file://mesh.glb, NSUnderlyingError")
        #expect(redaction.scrub("PYTHONPATH=/opt/lib:/Volumes/External/trellis2/src")
            == "PYTHONPATH=lib:src")
        #expect(redaction.scrub("error:/Volumes/External/models/ckpt.bin")
            == "error:ckpt.bin")
        #expect(redaction.scrub("Couldn’t open “/Volumes/External/Local Models/x.png”.")
            == "Couldn’t open “x.png”.")
        #expect(redaction.scrub("run `/Volumes/External/trellis2/run.sh` again")
            == "run `run.sh` again")
        #expect(redaction.scrub("« /Volumes/External/a/b.png »") == "« b.png »")
        // A file name with the sentence after it is where the path ends, so a slash later
        // in the sentence is not taken for one of its folders.
        #expect(redaction.scrub("/Volumes/External/Local Models/m.gguf needs 12 GB/s here")
            == "m.gguf needs 12 GB/s here")
        #expect(redaction.scrub("/private/tmp/x.png and/or /Volumes/External/y.png")
            == "x.png and/or y.png")
        // Whatever the labels already made safe stays as they left it.
        #expect(redaction.scrub("/Volumes/External/Silicon Videos/a.mp4, /Users/you/b/c.png")
            == "Silicon Videos/a.mp4, ~/b/c.png")

        // Not paths on this disk: a node's API, a URL, arithmetic, a name that only starts
        // like a folder.
        for untouched in [
            "POST /v1/jobs answered 500.",
            "Could not reach http://100.64.0.9:8000/v1/jobs/Users/x.",
            "and/or 16/9", "/Volumesque/a/b", "./run.sh failed",
            // A Windows node's paths, native and through WSL, are not this Mac's.
            "C:\\Users\\bob\\x.gguf", "/mnt/c/Users/bob/x.gguf",
        ] {
            #expect(redaction.scrub(untouched) == untouched, "\(untouched)")
        }
    }

    /// The same, as a phone and the swarm meet it: a mesh tool's failure, quoted back.
    @Test func aToolsTracebackReachesAPhoneOrAPeerWithoutItsFolders() async throws {
        try await BuddyMediaFixture.withServer(swarmToken: Self.swarmToken) { fixture in
            let image = try fixture.writeOutput(
                named: "kettle.png", bytes: BuddyMediaRoutesTests.pngBytes(count: 64)
            )
            let mediaID = try #require(
                await fixture.registry.register(path: image.path, within: [fixture.outputs.path])
            )
            let sentence = "The mesh tool stopped: Traceback (most recent call last):\n"
                + #"  File "/Volumes/External/trellis2/trellis/pipelines/base.py", line 12"#
                + "\nRuntimeError: out of memory"
            await fixture.host.setMeshFailure(sentence)
            let phone = try await fixture.pair()

            for token in [phone.token, Self.swarmToken] {
                let (status, body) = try await fixture.phone.call(
                    "POST", "/mesh/generate", token: token, body: #"{"mediaID":"\#(mediaID)"}"#
                )
                #expect(status == 400)
                let told = try #require(Self.message(body))
                #expect(!told.contains("/Volumes"), "\(told)")
                #expect(!told.contains("trellis2"), "\(told)")
                #expect(told.contains(#"File "base.py", line 12"#), "\(told)")
            }
            // The Mac's own tools still read the whole thing.
            let (status, body) = try await fixture.local.call(
                "POST", "/mesh/generate", token: fixture.local.token,
                body: #"{"mediaID":"\#(mediaID)"}"#
            )
            #expect(status == 400)
            #expect(Self.message(body) == sentence)
        }
    }

    // MARK: - Helpers

    /// One route's answer, after checking that no spelling of `folder` is anywhere in it.
    private static func answer<Answer: Decodable>(
        _ type: Answer.Type, _ client: TestClient, _ path: String, _ token: String,
        _ body: String?, hiding folder: URL
    ) async throws -> Answer {
        let (status, data) = try await client.call(
            body == nil ? "GET" : "POST", path, token: token, body: body
        )
        #expect(status == 200, "\(path)")
        // JSON escapes a slash, so the text is read with them put back.
        let text = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\\/", with: "/")
        for spelling in [folder.path, folder.resolvingSymlinksInPath().path,
                         "/private" + folder.path] {
            #expect(!text.contains(spelling), "\(path) named \(spelling)")
        }
        return try JSONDecoder().decode(type, from: data)
    }

    private static func decode<Answer: Decodable>(
        _ type: Answer.Type, _ reply: (Int, Data)
    ) throws -> Answer {
        #expect(reply.0 == 200)
        return try JSONDecoder().decode(type, from: reply.1)
    }

    private static func message(_ body: Data) -> String? {
        (try? JSONDecoder().decode(ControlAPI.ErrorResponse.self, from: body))?.error
    }
}

/// `/chat/stream` answers a failure with the host's own sentence — as a plain refusal before
/// the stream opens, or as a final `error` frame after it has — and the swarm can reach it.
@Suite("Mac paths in chat stream refusals")
struct ChatStreamRefusalPathTests {

    private static let swarmToken = "test-shared-swarm-secret"

    @Test(arguments: [false, true])
    func aChatStreamFailureQuotesNoFolderOfThisMacToAnyoneButTheMac(
        afterAToken: Bool
    ) async throws {
        try await BuddyMediaFixture.withServer(swarmToken: Self.swarmToken) { fixture in
            let home = NSHomeDirectory()
            let sentence = "The model could not read \(fixture.outputs.path)/prompt.txt "
                + "or \(home)/Documents/notes.txt."
            let scrubbed = "The model could not read Movies/prompt.txt or ~/Documents/notes.txt."
            await fixture.host.setChatFailure(sentence, afterAToken: afterAToken)
            let phone = try await fixture.pair()
            let body = #"{"messages":[{"role":"user","content":"hi","images":[]}]}"#

            for (label, client, token, expected) in [
                ("swarm on the tailnet", fixture.phone, Self.swarmToken, scrubbed),
                ("swarm on loopback", fixture.local, Self.swarmToken, scrubbed),
                ("phone", fixture.phone, phone.token, scrubbed),
                ("this Mac", fixture.local, fixture.local.token, sentence),
            ] {
                let message = try await Self.refusal(
                    client, token: token, body: body, afterAToken: afterAToken
                )
                #expect(message == expected, "\(label)")
            }
        }
    }

    /// Before the first frame the refusal is an HTTP error; after it, an `error` frame.
    private static func refusal(
        _ client: TestClient, token: String, body: String, afterAToken: Bool
    ) async throws -> String? {
        guard afterAToken else {
            let (status, data) = try await client.call(
                "POST", "/chat/stream", token: token, body: body
            )
            #expect(status == 400)
            return (try? JSONDecoder().decode(ControlAPI.ErrorResponse.self, from: data))?.error
        }
        let frames = try await client.events(
            "POST", "/chat/stream", token: token, body: body
        ) { $0.contains { $0.name == "error" } }
        #expect(frames.first?.name == "token")
        let error = try #require(frames.first { $0.name == "error" })
        return (try? JSONDecoder().decode(
            ControlAPI.ErrorResponse.self, from: Data(error.data.utf8)
        ))?.error
    }
}
