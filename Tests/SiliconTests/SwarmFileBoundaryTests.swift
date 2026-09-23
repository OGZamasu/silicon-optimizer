import Foundation
import Testing
@testable import SiliconControl

@Suite("Swarm filesystem authority")
struct SwarmFileBoundaryTests {
    private let swarmToken = "fixture-swarm-token"
    private let subjectRoutes = [
        "/mesh/plan", "/mesh/generate", "/image/plan", "/image/generate", "/video/generate",
    ]

    @Test func swarmCannotNameMacFilesOnEitherListener() async throws {
        try await BuddyMediaFixture.withServer(swarmToken: swarmToken) { fixture in
            let body = #"{"prompt":"a shot","imagePath":"/private/fixture-secret","initImagePath":"/private/fixture-secret"}"#
            for client in [fixture.local, fixture.phone] {
                for route in subjectRoutes {
                    let status = try await client.status(
                        "POST", route, token: swarmToken, body: body
                    )
                    #expect(status == 400, "\(route) accepted a swarm-supplied Mac path")
                }
            }
            #expect(await fixture.host.lastMeshImagePath == nil)
            #expect(await fixture.host.lastImagePath == nil)

            // The local per-launch bearer is still allowed to pass paths to every route.
            for route in subjectRoutes {
                let status = try await fixture.local.status(
                    "POST", route, token: fixture.local.token, body: body
                )
                #expect(status == 200)
            }
            #expect(await fixture.host.lastMeshImagePath == "/private/fixture-secret")
            #expect(await fixture.host.lastImagePath == "/private/fixture-secret")
        }
    }

    @Test func swarmCanRenderUploadedAndRegisteredMedia() async throws {
        try await BuddyMediaFixture.withServer(swarmToken: swarmToken) { fixture in
            let (status, response) = try await fixture.phone.call(
                "POST", "/uploads", token: swarmToken,
                data: BuddyMediaRoutesTests.jpegBytes(count: 128), contentType: "image/jpeg"
            )
            #expect(status == 200)
            let upload = try JSONDecoder().decode(ControlAPI.UploadResponse.self, from: response)
            for (key, value) in [("uploadID", upload.uploadID), ("mediaID", upload.mediaID)] {
                let body = #"{"prompt":"a shot","\#(key)":"\#(value)"}"#
                for route in subjectRoutes {
                    #expect(try await fixture.phone.status(
                        "POST", route, token: swarmToken, body: body
                    ) == 200, "\(route) rejected a swarm-owned \(key)")
                }
            }
            let path = try #require(await fixture.host.lastImagePath)
            #expect(path.hasPrefix(fixture.uploads.resolvingSymlinksInPath().path + "/swarm/"))

            // A peer must not use a paired phone's upload through either identifier.
            let phone = try await fixture.pair()
            let (_, phoneResponse) = try await fixture.phone.call(
                "POST", "/uploads", token: phone.token,
                data: BuddyMediaRoutesTests.jpegBytes(count: 128), contentType: "image/jpeg"
            )
            let privateUpload = try JSONDecoder().decode(ControlAPI.UploadResponse.self, from: phoneResponse)
            for (key, value) in [("uploadID", privateUpload.uploadID), ("mediaID", privateUpload.mediaID)] {
                #expect(try await fixture.phone.status(
                    "POST", "/video/generate", token: swarmToken,
                    body: #"{"prompt":"a shot","\#(key)":"\#(value)"}"#
                ) == 404)
            }
        }
    }

    @Test func onlyLocalControlCanChooseADownloadDirectory() async throws {
        try await BuddyMediaFixture.withServer(swarmToken: swarmToken) { fixture in
            let body = #"{"modelID":"fixture","directory":"/private/fixture-destination"}"#
            for client in [fixture.local, fixture.phone] {
                #expect(try await client.status(
                    "POST", "/install", token: swarmToken, body: body
                ) == 403)
            }
            let phone = try await fixture.pair()
            #expect(try await fixture.phone.status(
                "POST", "/install", token: phone.token, body: body
            ) == 403)
            #expect(await fixture.host.installRequests.isEmpty)

            #expect(try await fixture.local.status(
                "POST", "/install", token: fixture.local.token, body: body
            ) == 200)
            #expect(await fixture.host.installRequests.last?.directory == "/private/fixture-destination")
            for token in [swarmToken, phone.token] {
                #expect(try await fixture.phone.status(
                    "POST", "/install", token: token, body: #"{"modelID":"fixture"}"#
                ) == 200)
            }
            #expect(await fixture.host.installRequests.count == 3)
            #expect(await fixture.host.installRequests.last?.directory == nil)
        }
    }
}
