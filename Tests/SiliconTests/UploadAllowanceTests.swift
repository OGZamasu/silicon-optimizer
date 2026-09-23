import Foundation
import Testing
@testable import SiliconControl

/// `POST /uploads` keeps what it is sent for a week. Per request it was always capped; per
/// sender it was not, so the swarm secret — or a phone — could post small pictures until
/// the owner's disk was full. Each sender now has an allowance of files and bytes waiting
/// here at once, and the Mac's own token keeps none.
///
/// The folders are filled directly rather than through the route, so reaching an allowance
/// costs a directory of empty files instead of a thousand requests — and the byte limit is
/// reached with one sparse file that occupies nothing on disk.
@Suite("Upload allowances")
struct UploadAllowanceTests {

    private static let swarmToken = "test-shared-swarm-secret"

    /// The swarm secret's allowance by count: the last free slot is taken, the next upload
    /// is a 429 that says why and when, and nothing is written for it.
    @Test func theSwarmSecretCannotKeepMoreUploadsHereThanItsAllowance() async throws {
        try await BuddyMediaFixture.withServer(swarmToken: Self.swarmToken) { fixture in
            let allowance = BuddyUploads.Allowance.swarm
            let folder = BuddyUploads.deviceRoot("swarm", at: fixture.uploads)
            try Self.fill(folder, files: allowance.files - 1)

            #expect(try await fixture.phone.status(
                "POST", "/uploads", token: Self.swarmToken,
                data: BuddyMediaRoutesTests.jpegBytes(count: 2048), contentType: "image/jpeg"
            ) == 200)
            let before = try Self.count(folder)
            #expect(before == allowance.files)

            let refused = try await fixture.phone.upload(
                token: Self.swarmToken, data: BuddyMediaRoutesTests.jpegBytes(count: 2048)
            )
            #expect(refused.status == 429)
            #expect(Self.message(refused.body) == ControlServer.uploadAllowanceSpent(allowance))
            // Room comes free when the oldest upload's week is up, and not before.
            let wait = try #require(refused["Retry-After"].flatMap(Int.init))
            #expect(wait > 0 && wait <= Int(BuddyUploads.lifetime) + 1)
            #expect(try Self.count(folder) == before)

            // The same secret on the loopback listener is the same sender.
            #expect(try await fixture.local.status(
                "POST", "/uploads", token: Self.swarmToken,
                data: BuddyMediaRoutesTests.jpegBytes(count: 2048), contentType: "image/jpeg"
            ) == 429)

            // Nobody else is refused for the swarm's spend: a paired phone has its own
            // allowance, and the Mac's own token has none.
            let phone = try await fixture.pair()
            #expect(try await fixture.phone.status(
                "POST", "/uploads", token: phone.token,
                data: BuddyMediaRoutesTests.jpegBytes(count: 2048), contentType: "image/jpeg"
            ) == 200)
            #expect(try await fixture.local.status(
                "POST", "/uploads", token: fixture.local.token,
                data: BuddyMediaRoutesTests.jpegBytes(count: 2048), contentType: "image/jpeg"
            ) == 200)
        }
    }

    /// And by bytes: a few small files are enough to be refused once they add up.
    @Test func theSwarmSecretsUploadsCannotAddUpToMoreThanItsBytes() async throws {
        try await BuddyMediaFixture.withServer(swarmToken: Self.swarmToken) { fixture in
            let allowance = BuddyUploads.Allowance.swarm
            let folder = BuddyUploads.deviceRoot("swarm", at: fixture.uploads)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Self.sparse(folder.appendingPathComponent("held.jpg"), bytes: allowance.bytes - 4096)

            // Fits.
            #expect(try await fixture.phone.status(
                "POST", "/uploads", token: Self.swarmToken,
                data: BuddyMediaRoutesTests.jpegBytes(count: 2048), contentType: "image/jpeg"
            ) == 200)
            // Would not.
            let refused = try await fixture.phone.upload(
                token: Self.swarmToken, data: BuddyMediaRoutesTests.jpegBytes(count: 4096)
            )
            #expect(refused.status == 429)
            #expect(Self.message(refused.body) == ControlServer.uploadAllowanceSpent(allowance))
            #expect(try Self.count(folder) == 2)
        }
    }

    /// A phone has an allowance too — a generous one, because uploading is what its Create
    /// screen does — and an upload past its week stops counting before the sweep reaches it.
    @Test func aPhonesAllowanceCountsOnlyUploadsStillInTheirWeek() async throws {
        try await BuddyMediaFixture.withServer { fixture in
            let allowance = BuddyUploads.Allowance.device
            let phone = try await fixture.pair()
            let folder = BuddyUploads.deviceRoot(phone.deviceID, at: fixture.uploads)
            try Self.fill(folder, files: allowance.files - 1)
            let expired = folder.appendingPathComponent("expired.jpg")
            try Data("old".utf8).write(to: expired)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-8 * 24 * 3600)],
                ofItemAtPath: expired.path
            )

            // One slot left, whatever the expired file says.
            #expect(try await fixture.phone.status(
                "POST", "/uploads", token: phone.token,
                data: BuddyMediaRoutesTests.jpegBytes(count: 1024), contentType: "image/jpeg"
            ) == 200)
            let refused = try await fixture.phone.upload(
                token: phone.token, data: BuddyMediaRoutesTests.jpegBytes(count: 1024)
            )
            #expect(refused.status == 429)
            #expect(Self.message(refused.body) == ControlServer.uploadAllowanceSpent(allowance))

            // Another phone is a different sender.
            let other = try await fixture.pair(name: "Tablet")
            #expect(try await fixture.phone.status(
                "POST", "/uploads", token: other.token,
                data: BuddyMediaRoutesTests.jpegBytes(count: 1024), contentType: "image/jpeg"
            ) == 200)
        }
    }

    /// What the refusal is measured against: live files, their sizes, and when the oldest
    /// was written.
    @Test func usageIsTheLiveFilesInOneSendersFolder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-usage-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let mine = BuddyUploads.deviceRoot("device-a", at: root)
        let theirs = BuddyUploads.deviceRoot("device-b", at: root)
        for folder in [mine, theirs] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let now = Date()
        try Data(count: 100).write(to: mine.appendingPathComponent("a.jpg"))
        try Data(count: 250).write(to: mine.appendingPathComponent("b.png"))
        let old = mine.appendingPathComponent("old.jpg")
        try Data(count: 999).write(to: old)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-8 * 24 * 3600)], ofItemAtPath: old.path
        )
        try FileManager.default.createDirectory(
            at: mine.appendingPathComponent("not-a-file"), withIntermediateDirectories: true
        )
        try Data(count: 5000).write(to: theirs.appendingPathComponent("c.jpg"))

        let usage = BuddyUploads.usage(ofBucket: "device-a", at: root, now: now)
        #expect(usage.files == 2)
        #expect(usage.bytes == 350)
        #expect(usage.oldest != nil)
        #expect(BuddyUploads.usage(ofBucket: "nobody", at: root, now: now).files == 0)
    }

    // MARK: - Helpers

    private static func fill(_ folder: URL, files: Int) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0..<files {
            try Data("x".utf8).write(to: folder.appendingPathComponent("seed-\(index).jpg"))
        }
    }

    /// A file that says it is `bytes` long and occupies nothing.
    private static func sparse(_ url: URL, bytes: Int) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(bytes))
    }

    private static func count(_ folder: URL) throws -> Int {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).count
    }

    private static func message(_ body: Data) -> String? {
        (try? JSONDecoder().decode(ControlAPI.ErrorResponse.self, from: body))?.error
    }
}

extension TestClient {

    /// `POST /uploads` with the response's headers kept, for the refusal whose
    /// `Retry-After` matters.
    func upload(token: String?, data: Data) async throws -> MediaAnswer {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/uploads")!)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
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
