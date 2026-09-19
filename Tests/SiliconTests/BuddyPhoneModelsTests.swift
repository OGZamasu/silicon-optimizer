import CryptoKit
import Foundation
import Network
import Security
import Testing
@testable import SiliconCatalog
@testable import SiliconControl
@testable import SiliconCore
@testable import SiliconRuntime
@testable import SiliconUI

/// The Mac's half of the phone's fallback model: the pinned catalogue, the fetch into
/// `PhoneModels/`, and the four `/ondevice/models` routes a phone uses to get a model
/// without ever leaving the tailnet.
///
/// Nothing here touches the network or the login Keychain. "Hugging Face" is a loopback
/// socket serving a few hundred kilobytes of random bytes under the real pinned paths, the
/// files live in a temporary directory, and the one 3.35 GB file is sparse — it occupies a
/// single block on disk.
@Suite("Silicon Buddy phone models")
struct BuddyPhoneModelsTests {

    static let swarmSecret = "phone-models-swarm-secret"

    // MARK: - The pins

    /// Every byte-identifying field, exactly as the owner chose it. A pin that drifts is a
    /// phone that downloads 3.35 GB and then fails its own checksum.
    @Test func thePinsAreExactlyTheOnesTheOwnerChose() throws {
        #expect(PhoneModelCatalog.all.map(\.id) == ["qwen3.5-2b-q4_0", "gemma-4-e2b-q4_0"])

        let qwen = try #require(PhoneModelCatalog.entry(id: "qwen3.5-2b-q4_0"))
        #expect(qwen.label == "Qwen3.5 2B")
        #expect(qwen.isDefault)
        #expect(qwen.repository == "bartowski/Qwen_Qwen3.5-2B-GGUF")
        #expect(qwen.commit == "7d26695454df6de5fbcce2e58681e62dae06ce43")
        #expect(qwen.file == "Qwen_Qwen3.5-2B-Q4_0.gguf")
        #expect(qwen.sizeBytes == 1_296_764_000)
        #expect(qwen.sha256 == "91c102fc9a86de80e427057ee938e1e34fcaf3bba956b7296e252406e05f36f6")
        #expect(qwen.licence == "Apache-2.0")
        #expect(qwen.recommended == .init(
            threadsPrompt: 6, threadsGenerate: 4, contextLength: 4096,
            minFreeMemoryBytes: 2_500_000_000, thinking: false
        ))
        #expect(!qwen.slowerOnPhone)
        let qwenMeasured = try #require(qwen.measured)
        #expect(qwenMeasured.device == "Galaxy S24 Ultra")
        #expect(qwenMeasured.runtime == "llama.cpp b11053, CPU")
        #expect(qwenMeasured.conditions == "phone hot and charging")
        #expect(qwenMeasured.secondsToFirstWord300 == 2.4)
        #expect(qwenMeasured.tokensPerSecond == 17)
        #expect(qwenMeasured.tokensPerSecondMax == 19)
        #expect(qwenMeasured.sustainedTokensPerSecond == nil)

        let gemma = try #require(PhoneModelCatalog.entry(id: "gemma-4-e2b-q4_0"))
        #expect(gemma.label == "Gemma 4 E2B")
        #expect(!gemma.isDefault)
        #expect(gemma.repository == "google/gemma-4-E2B-it-qat-q4_0-gguf")
        #expect(gemma.commit == "675cff42a74c774d6cb76f76d8eacb49b48c9b93")
        #expect(gemma.file == "gemma-4-E2B_q4_0-it.gguf")
        #expect(gemma.sizeBytes == 3_349_516_256)
        #expect(gemma.sha256 == "fa401b55b07ee70a54c6dae3903c783a6e65064312529ea57175cb5f8dec6634")
        #expect(gemma.licence == "Apache-2.0")
        #expect(gemma.recommended == .init(
            threadsPrompt: 4, threadsGenerate: 6, contextLength: 4096,
            minFreeMemoryBytes: 4_200_000_000, thinking: false
        ))
        #expect(gemma.slowerOnPhone)
        let gemmaMeasured = try #require(gemma.measured)
        #expect(gemmaMeasured.device == "Galaxy S24 Ultra")
        #expect(gemmaMeasured.secondsToFirstWord300 == 3.3)
        #expect(gemmaMeasured.tokensPerSecond == 14)
        #expect(gemmaMeasured.tokensPerSecondMax == 15)
        #expect(gemmaMeasured.sustainedTokensPerSecond == 7.5)

        // Exactly one default, and it is the small one.
        #expect(PhoneModelCatalog.all.filter(\.isDefault).map(\.id) == [qwen.id])
        #expect(PhoneModelCatalog.defaultEntry.id == qwen.id)

        let hex = CharacterSet(charactersIn: "0123456789abcdef")
        for entry in PhoneModelCatalog.all {
            #expect(entry.sha256.count == 64, "\(entry.id)")
            #expect(entry.sha256.unicodeScalars.allSatisfy(hex.contains), "\(entry.id)")
            #expect(entry.commit.count == 40, "\(entry.id)")
            #expect(entry.commit.unicodeScalars.allSatisfy(hex.contains), "\(entry.id)")
            #expect(entry.hasPlainFileName, "\(entry.id)")
            #expect(entry.file.hasSuffix(".gguf"), "\(entry.id)")
        }
        #expect(Set(PhoneModelCatalog.all.map(\.file)).count == PhoneModelCatalog.all.count)
    }

    /// These are fetched for the phone and passed along. They must never become something
    /// the Mac lists, recommends, loads or keeps in its own library.
    @Test func phoneModelsAreNeverMacModels() throws {
        let macIDs = Set(ModelCatalog.all.map(\.id))
        let macFiles = Set(ModelCatalog.all.flatMap { $0.variants.flatMap(\.allFiles) })
        for entry in PhoneModelCatalog.all {
            #expect(!macIDs.contains(entry.id), "\(entry.id)")
            #expect(!macFiles.contains(entry.file), "\(entry.id)")
            #expect(ModelCatalog.entry(id: entry.id) == nil, "\(entry.id)")
        }

        let root = PhoneModelStore.defaultRoot.standardizedFileURL.path
        let library = ModelLibrary.defaultRoot.standardizedFileURL.path
        #expect(root.hasSuffix("/Application Support/SiliconOptimizer/PhoneModels"))
        #expect(root != library)
        #expect(!root.hasPrefix(library + "/"))
        #expect(!library.hasPrefix(root + "/"))

        // A file name that could climb out of the folder is not an entry at all — so an id
        // can never lead anywhere but a catalogue file inside `PhoneModels/`.
        var escaping = PhoneModelCatalog.qwen35_2B
        escaping.id = "escaping"
        escaping.file = "../Models/escaping.gguf"
        var hidden = PhoneModelCatalog.qwen35_2B
        hidden.id = "hidden"
        hidden.file = ".verified"
        let store = PhoneModelStore(
            root: FileManager.default.temporaryDirectory.appendingPathComponent("unused-\(UUID())"),
            catalog: [escaping, hidden, PhoneModelCatalog.qwen35_2B],
            source: URL(string: "http://127.0.0.1:9")!, spaceCheck: { _, _ in }
        )
        #expect(store.entry(id: "escaping") == nil)
        #expect(store.entry(id: "hidden") == nil)
        #expect(store.catalog.map(\.id) == ["qwen3.5-2b-q4_0"])
        #expect(store.entry(id: "../qwen3.5-2b-q4_0") == nil)
    }

    /// What a phone reads, built from the catalogue: every pin, and the four states.
    @Test func theWireCarriesEveryPinAndEachState() throws {
        let qwen = PhoneModelCatalog.qwen35_2B
        let absent = PhoneModelService.wire(qwen, state: .absent)
        #expect(absent.id == qwen.id)
        #expect(absent.label == qwen.label)
        #expect(absent.isDefault)
        #expect(absent.sizeBytes == qwen.sizeBytes)
        #expect(absent.sha256 == qwen.sha256)
        #expect(absent.licence == "Apache-2.0")
        #expect(absent.source == .init(repo: qwen.repository, commit: qwen.commit, file: qwen.file))
        #expect(absent.recommended == .init(
            threadsPrompt: 6, threadsGenerate: 4, contextLength: 4096,
            minFreeMemoryBytes: 2_500_000_000, thinking: false
        ))
        #expect(absent.measured?.secondsToFirstWord300 == 2.4)
        #expect(absent.measured?.tokensPerSecond == 17)
        #expect(absent.measured?.tokensPerSecondMax == 19)
        #expect(absent.onMac == .init(state: "absent"))
        #expect(absent.downloadEventID == "ondevice:qwen3.5-2b-q4_0")

        let half = PhoneModelService.wire(
            qwen, state: .downloading(bytesReceived: qwen.sizeBytes / 2, bytesPerSecond: 1)
        )
        #expect(half.onMac == .init(state: "downloading", fraction: 0.5))
        #expect(PhoneModelService.wire(qwen, state: .ready).onMac == .init(state: "ready"))

        let cut = PhoneModelStore.Failure(
            kind: .network, reason: "Cut off.", bytesOnDisk: qwen.sizeBytes / 4
        )
        #expect(PhoneModelService.wire(qwen, state: .failed(cut)).onMac == .init(
            state: "failed", fraction: 0.25, reason: "Cut off.", failure: "network"
        ))
        // A failure with nothing kept has no fraction to report.
        let wrong = PhoneModelStore.Failure(kind: .checksumMismatch, reason: "Wrong.", bytesOnDisk: 0)
        #expect(PhoneModelService.wire(qwen, state: .failed(wrong)).onMac.fraction == nil)

        // The vocabularies the contract publishes are the ones the store can produce.
        #expect(Set(PhoneModelStore.Failure.Kind.allCases.map(\.rawValue))
            == Set(ControlAPI.phoneModelFailures))
        #expect(ControlAPI.phoneModelStates == ["absent", "downloading", "ready", "failed"])

        // The keys, exactly: a generated client learns these.
        let object = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(absent)
        ) as? [String: Any])
        #expect(Set(object.keys) == [
            "id", "label", "isDefault", "sizeBytes", "sha256", "licence", "source", "onMac",
            "recommended", "measured", "slowerOnPhone",
        ])
        let gemma = PhoneModelService.wire(PhoneModelCatalog.gemma4E2B, state: .absent)
        #expect(gemma.slowerOnPhone)
        #expect(gemma.measured?.sustainedTokensPerSecond == 7.5)
    }

    /// Every failure a phone can be told about has a kind it can act on and a sentence
    /// with no path and no credential in it.
    @Test func failuresSayWhatHappenedAndWhatToDo() {
        let entry = PhoneModelCatalog.gemma4E2B
        func kind(_ error: any Error, partial: Int64 = 0) -> PhoneModelStore.Failure {
            PhoneModelStore.failure(for: error, entry: entry, partial: partial)
        }
        let disk = kind(ModelDownloader.DownloadError.insufficientDiskSpace(
            needed: Bytes(entry.sizeBytes), available: .gib(4)
        ))
        #expect(disk.kind == .diskFull)
        #expect(disk.reason.contains("not enough space on the Mac"))
        #expect(kind(CocoaError(.fileWriteOutOfSpace)).kind == .diskFull)
        #expect(kind(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))).kind == .diskFull)

        let mismatch = kind(ModelDownloader.DownloadError.checksumMismatch(
            file: entry.file, expected: entry.sha256, actual: String(repeating: "0", count: 64)
        ))
        #expect(mismatch.kind == .checksumMismatch)
        #expect(mismatch.reason.contains("checksum"))

        let lost = kind(URLError(.networkConnectionLost), partial: entry.sizeBytes / 2)
        #expect(lost.kind == .network)
        #expect(lost.reason.contains("the connection dropped"))
        #expect(lost.reason.contains("50%"))
        #expect(lost.reason.contains("resume"))
        #expect(!lost.reason.contains("NSURLErrorDomain"))
        #expect(kind(URLError(.notConnectedToInternet)).reason.contains("offline"))
        #expect(kind(ModelDownloader.DownloadError.incompleteTransfer(
            file: entry.file, received: .zero, expected: Bytes(entry.sizeBytes)
        )).kind == .network)

        #expect(kind(HuggingFaceClient.ClientError.badResponse(503)).reason.contains("503"))
        #expect(kind(HuggingFaceClient.ClientError.rateLimited).kind == .server)

        for failure in [disk, mismatch, lost] {
            #expect(!failure.reason.contains("/Users/"))
            #expect(!failure.reason.contains("Application Support"))
        }
    }

    // MARK: - Fetching

    /// The ordinary case, all of it: the pinned commit is what is asked for, no credential
    /// goes out, the bytes are verified, and nothing partial is left behind.
    @Test func aPreparedModelArrivesFromItsPinnedCommitVerifiedAndWithoutAToken() async throws {
        try await PhoneModelFixture.with { f in
            #expect(await f.store.state(of: f.qwen.id) == .absent)
            #expect(try await f.store.prepare(id: f.qwen.id) == .started)
            await f.store.waitUntilSettled(id: f.qwen.id)
            #expect(await f.store.state(of: f.qwen.id) == .ready)

            let verified = try #require(await f.store.verifiedFile(id: f.qwen.id))
            #expect(verified.sha256 == f.qwen.sha256)
            #expect(verified.sizeBytes == Int64(f.qwenBytes.count))
            #expect(PhoneModelFixture.sha256(try Data(contentsOf: verified.url)) == f.qwen.sha256)
            #expect(verified.url.deletingLastPathComponent().standardizedFileURL.path
                == f.root.standardizedFileURL.path)

            let requests = f.huggingFace.requests
            #expect(requests.map(\.path) == [PhoneModelFixture.pinnedPath(f.qwen)])
            #expect(requests.allSatisfy { !$0.path.contains("/resolve/main/") })
            // Public files: no bearer of any kind, and certainly not the owner's.
            #expect(requests.allSatisfy { $0.authorization == nil })
            #expect(!FileManager.default.fileExists(atPath: f.partialURL(f.qwen).path))
            // The other model was not touched.
            #expect(await f.store.state(of: f.gemma.id) == .absent)
        }
    }

    /// A phone's Mac on hotel Wi-Fi: the connection drops partway. What arrived is kept,
    /// the state says so, and the next prepare asks for exactly the rest.
    @Test func aCutConnectionResumesFromWhereItStopped() async throws {
        try await PhoneModelFixture.with { f in
            try await f.interrupt(f.qwen, after: 120_000)

            guard case .failed(let failure) = await f.store.state(of: f.qwen.id) else {
                Issue.record("A cut transfer should read as failed.")
                return
            }
            #expect(failure.kind == .network)
            #expect(failure.bytesOnDisk == 120_000)
            #expect(f.size(of: f.partialURL(f.qwen)) == 120_000)
            #expect(failure.reason.contains("40%"))
            #expect(failure.reason.contains("resume"))
            #expect(await f.store.verifiedFile(id: f.qwen.id) == nil)
            let listed = await f.service.phoneModels().models.first { $0.id == f.qwen.id }
            #expect(listed?.onMac.fraction == 0.4)
            #expect(listed?.onMac.failure == "network")

            #expect(try await f.store.prepare(id: f.qwen.id) == .started)
            await f.store.waitUntilSettled(id: f.qwen.id)
            #expect(await f.store.state(of: f.qwen.id) == .ready)
            #expect(f.huggingFace.requests.count == 2)
            #expect(f.huggingFace.requests.last?.range == "bytes=120000-")
            #expect(f.huggingFace.requests.last?.path == PhoneModelFixture.pinnedPath(f.qwen))
            // Two ranges, one file: it hashes to the pin.
            #expect(PhoneModelFixture.sha256(try Data(contentsOf: f.fileURL(f.qwen)))
                == f.qwen.sha256)
        }
    }

    /// Bytes that are not the pinned ones are thrown away, not kept to be resumed, and the
    /// phone is told why.
    @Test func aChecksumMismatchDeletesTheBytesAndSaysSo() async throws {
        try await PhoneModelFixture.with { f in
            var corrupted = f.qwenBytes
            corrupted[1_000] ^= 0xFF
            f.huggingFace.serve(corrupted, at: PhoneModelFixture.pinnedPath(f.qwen))
            _ = try await f.store.prepare(id: f.qwen.id)
            await f.store.waitUntilSettled(id: f.qwen.id)

            guard case .failed(let failure) = await f.store.state(of: f.qwen.id) else {
                Issue.record("A mismatched digest should read as failed.")
                return
            }
            #expect(failure.kind == .checksumMismatch)
            #expect(failure.bytesOnDisk == 0)
            #expect(failure.reason.contains("checksum"))
            #expect(!FileManager.default.fileExists(atPath: f.fileURL(f.qwen).path))
            #expect(!FileManager.default.fileExists(atPath: f.partialURL(f.qwen).path))
            #expect(await f.store.verifiedFile(id: f.qwen.id) == nil)

            let listed = await f.service.phoneModels().models.first { $0.id == f.qwen.id }
            #expect(listed?.onMac.state == "failed")
            #expect(listed?.onMac.failure == "checksumMismatch")
            #expect(listed?.onMac.fraction == nil)

            // Put right, it starts again from nothing — there is nothing to resume.
            f.huggingFace.serve(f.qwenBytes, at: PhoneModelFixture.pinnedPath(f.qwen))
            _ = try await f.store.prepare(id: f.qwen.id)
            await f.store.waitUntilSettled(id: f.qwen.id)
            #expect(await f.store.state(of: f.qwen.id) == .ready)
            #expect(f.huggingFace.requests.last?.range == nil)
        }
    }

    /// Hugging Face refusing is a failure with its status in it, not a hang or a crash.
    @Test func aRefusalFromHuggingFaceIsAFailureWithItsStatus() async throws {
        try await PhoneModelFixture.with { f in
            f.huggingFace.unserve(PhoneModelFixture.pinnedPath(f.gemma))
            _ = try await f.store.prepare(id: f.gemma.id)
            await f.store.waitUntilSettled(id: f.gemma.id)
            guard case .failed(let failure) = await f.store.state(of: f.gemma.id) else {
                Issue.record("A 404 should read as failed.")
                return
            }
            #expect(failure.kind == .server)
            #expect(failure.reason.contains("404"))
        }
    }

    /// Asking twice is asking once: a model on its way is not restarted or doubled, and a
    /// ready one is not fetched again.
    @Test func prepareIsIdempotentWhileDownloadingAndOnceReady() async throws {
        try await PhoneModelFixture.with { f in
            f.huggingFace.hold()
            #expect(try await f.store.prepare(id: f.qwen.id) == .started)
            try await until { f.huggingFace.requests.count == 1 }
            #expect(try await f.store.prepare(id: f.qwen.id) == .alreadyDownloading)
            #expect(try await f.store.prepare(id: f.qwen.id) == .alreadyDownloading)
            guard case .downloading = await f.store.state(of: f.qwen.id) else {
                Issue.record("A held transfer should read as downloading.")
                return
            }
            #expect(await f.store.verifiedFile(id: f.qwen.id) == nil)
            #expect(f.huggingFace.requests.count == 1)

            f.huggingFace.release()
            await f.store.waitUntilSettled(id: f.qwen.id)
            #expect(await f.store.state(of: f.qwen.id) == .ready)
            #expect(try await f.store.prepare(id: f.qwen.id) == .alreadyReady)
            #expect(f.huggingFace.requests.count == 1)
        }
    }

    /// A Mac without room says so before a byte moves, and the state carries the reason.
    @Test func aFullDiskIsRefusedBeforeAByteMoves() async throws {
        let full: PhoneModelStore.SpaceCheck = { needed, _ in
            throw ModelDownloader.DownloadError.insufficientDiskSpace(
                needed: needed, available: .gib(3)
            )
        }
        try await PhoneModelFixture.with(spaceCheck: full) { f in
            do {
                _ = try await f.store.prepare(id: f.gemma.id)
                Issue.record("A full disk should refuse the prepare.")
            } catch PhoneModelStore.StoreError.noSpace(let failure) {
                #expect(failure.kind == .diskFull)
            }
            guard case .failed(let failure) = await f.store.state(of: f.gemma.id) else {
                Issue.record("A refused prepare should read as failed.")
                return
            }
            #expect(failure.kind == .diskFull)
            #expect(failure.reason.contains("space"))
            #expect(f.huggingFace.requests.isEmpty)

            await #expect(throws: PhoneModelError.self) {
                _ = try await f.service.preparePhoneModel(id: f.gemma.id)
            }
            do {
                _ = try await f.service.preparePhoneModel(id: f.gemma.id)
            } catch let error as PhoneModelError {
                #expect(error.status == 507)
            }
        }
    }

    /// Removing takes the Mac's copy, anything partial, and a fetch still in flight — and
    /// nothing that fetch was doing comes back afterwards.
    @Test func removingTakesTheCopyThePartialAndAFetchInFlight() async throws {
        try await PhoneModelFixture.with { f in
            // Ready.
            _ = try await f.store.prepare(id: f.qwen.id)
            await f.store.waitUntilSettled(id: f.qwen.id)
            try await f.store.remove(id: f.qwen.id)
            #expect(await f.store.state(of: f.qwen.id) == .absent)
            #expect(f.leftovers().isEmpty)
            // Again: nothing to remove is not an error.
            try await f.store.remove(id: f.qwen.id)
            #expect(await f.store.state(of: f.qwen.id) == .absent)

            // Partial.
            try await f.interrupt(f.qwen, after: 50_000)
            #expect(f.size(of: f.partialURL(f.qwen)) == 50_000)
            try await f.store.remove(id: f.qwen.id)
            #expect(await f.store.state(of: f.qwen.id) == .absent)
            #expect(f.leftovers().isEmpty)

            // In flight.
            f.huggingFace.hold()
            let before = f.huggingFace.requests.count
            _ = try await f.store.prepare(id: f.qwen.id)
            try await until { f.huggingFace.requests.count == before + 1 }
            try await f.store.remove(id: f.qwen.id)
            #expect(await f.store.state(of: f.qwen.id) == .absent)
            f.huggingFace.release()
            try await Task.sleep(for: .milliseconds(200))
            #expect(await f.store.state(of: f.qwen.id) == .absent)
            #expect(f.leftovers().isEmpty)

            await #expect(throws: PhoneModelStore.StoreError.unknownModel("nope")) {
                try await f.store.remove(id: "nope")
            }
        }
    }

    /// Ready means the digest matched, not that a file of the right size is sitting there.
    @Test func readyMeansVerifiedNotMerelyTheRightSize() async throws {
        try await PhoneModelFixture.with { f in
            try FileManager.default.createDirectory(at: f.root, withIntermediateDirectories: true)

            // The right name and size, the wrong bytes, never verified.
            var impostor = f.qwenBytes
            impostor[0] ^= 0xFF
            try impostor.write(to: f.fileURL(f.qwen))
            #expect(await f.store.state(of: f.qwen.id) == .absent)
            #expect(await f.store.verifiedFile(id: f.qwen.id) == nil)
            _ = try await f.store.prepare(id: f.qwen.id)
            await f.store.waitUntilSettled(id: f.qwen.id)
            #expect(await f.store.state(of: f.qwen.id) == .ready)
            #expect(PhoneModelFixture.sha256(try Data(contentsOf: f.fileURL(f.qwen)))
                == f.qwen.sha256)
            #expect(f.huggingFace.requests.count == 1)

            // The right bytes, put there by hand: hashed and adopted, no network.
            try await f.store.remove(id: f.qwen.id)
            try f.qwenBytes.write(to: f.fileURL(f.qwen))
            #expect(await f.store.state(of: f.qwen.id) == .absent)
            #expect(try await f.store.prepare(id: f.qwen.id) == .started)
            await f.store.waitUntilSettled(id: f.qwen.id)
            #expect(await f.store.state(of: f.qwen.id) == .ready)
            #expect(f.huggingFace.requests.count == 1)

            // A verified file changed afterwards is no longer the verified file.
            let handle = try FileHandle(forWritingTo: f.fileURL(f.qwen))
            try handle.seek(toOffset: 10)
            try handle.write(contentsOf: Data([0x00]))
            try handle.close()
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_000_000)],
                ofItemAtPath: f.fileURL(f.qwen).path
            )
            #expect(await f.store.state(of: f.qwen.id) != .ready)
            #expect(await f.store.verifiedFile(id: f.qwen.id) == nil)

            // And a link planted where the file was is not the file, whatever it points at.
            try await f.store.remove(id: f.qwen.id)
            _ = try await f.store.prepare(id: f.qwen.id)
            await f.store.waitUntilSettled(id: f.qwen.id)
            let elsewhere = f.directory.appendingPathComponent("elsewhere.gguf")
            try FileManager.default.moveItem(at: f.fileURL(f.qwen), to: elsewhere)
            try FileManager.default.createSymbolicLink(
                at: f.fileURL(f.qwen), withDestinationURL: elsewhere
            )
            #expect(await f.store.verifiedFile(id: f.qwen.id) == nil)
        }
    }

    /// The app quits and comes back: a verified model is still ready, and a half-fetched
    /// one says it was interrupted and resumes from what is there.
    @Test func aRelaunchKeepsWhatWasVerifiedAndResumesWhatWasNot() async throws {
        try await PhoneModelFixture.with { f in
            _ = try await f.store.prepare(id: f.qwen.id)
            await f.store.waitUntilSettled(id: f.qwen.id)
            try await f.interrupt(f.gemma, after: 40_000)
            let partial: Int64 = 40_000
            #expect(f.size(of: f.partialURL(f.gemma)) == partial)

            let relaunched = PhoneModelStore(
                root: f.root, catalog: [f.qwen, f.gemma], source: f.huggingFace.baseURL,
                spaceCheck: { _, _ in }
            )
            #expect(await relaunched.state(of: f.qwen.id) == .ready)
            guard case .failed(let failure) = await relaunched.state(of: f.gemma.id) else {
                Issue.record("A partial with nothing fetching it should read as failed.")
                return
            }
            #expect(failure.kind == .interrupted)
            #expect(failure.bytesOnDisk == partial)
            #expect(failure.reason.contains("%"))

            _ = try await relaunched.prepare(id: f.gemma.id)
            await relaunched.waitUntilSettled(id: f.gemma.id)
            #expect(await relaunched.state(of: f.gemma.id) == .ready)
            #expect(f.huggingFace.requests.last?.range == "bytes=\(partial)-")
            #expect(PhoneModelFixture.sha256(try Data(contentsOf: f.fileURL(f.gemma)))
                == f.gemma.sha256)
        }
    }

    // MARK: - The routes

    static func everyRoute(_ id: String) -> [(String, String)] {
        [
            ("GET", "/ondevice/models"),
            ("POST", "/ondevice/models/\(id)/prepare"),
            ("GET", "/ondevice/models/\(id)/file"),
            ("DELETE", "/ondevice/models/\(id)"),
        ]
    }

    /// Full control only: a chat-only phone gets the chat refusal, the swarm gets its own,
    /// and nobody without a token — or with this Mac's own token out on the tailnet — gets
    /// anything at all.
    @Test func theRoutesAreFullScopeAndNeverThePeers() async throws {
        try await PhoneModelFixture.with { models in
            try await PhoneRouteFixture.with(
                provider: models.service, hub: models.hub, swarmToken: Self.swarmSecret
            ) { f in
                let full = try await f.pair(name: "Studio phone")
                let chat = try await f.pair(name: "Lent out", scope: .chat)

                for (method, path) in Self.everyRoute(models.qwen.id) {
                    let refusedForChat = try await f.phone.call(method, path, token: chat.token)
                    #expect(refusedForChat.0 == 403, "\(method) \(path)")
                    #expect(Self.error(in: refusedForChat.1) == ControlServer.chatOnlyRefusal)

                    let refusedForPeers = try await f.local.call(
                        method, path, token: Self.swarmSecret
                    )
                    #expect(refusedForPeers.0 == 403, "\(method) \(path)")
                    #expect(Self.error(in: refusedForPeers.1)
                        == ControlServer.phoneModelsAreNotForPeers)

                    #expect(try await f.phone.status(method, path, token: nil) == 401)
                    #expect(try await f.phone.status(method, path, token: "guessed") == 401)
                    // This Mac's own token is not a credential out on the tailnet.
                    #expect(try await f.phone.status(
                        method, path, token: f.phone.token
                    ) == 401, "\(method) \(path)")
                    #expect(try await f.local.status(method, path, token: nil) == 401)
                }
                // None of those moved a byte.
                #expect(models.huggingFace.requests.isEmpty)

                // The two credentials that pass: a full-control phone on the tailnet, and this
                // Mac's own token on its own listener.
                #expect(try await f.phone.status(
                    "GET", "/ondevice/models", token: full.token
                ) == 200)
                #expect(try await f.local.status(
                    "GET", "/ondevice/models", token: f.local.token
                ) == 200)
                let file = "/ondevice/models/\(models.qwen.id)/file"
                #expect(try await f.phone.status("GET", file, token: full.token) == 409)
                #expect(try await f.local.status("GET", file, token: f.local.token) == 409)
                let model = "/ondevice/models/\(models.qwen.id)"
                #expect(try await f.phone.status("DELETE", model, token: full.token) == 200)
                #expect(try await f.local.status("DELETE", model, token: f.local.token) == 200)

                let listed = try JSONDecoder().decode(
                    ControlAPI.PhoneModelList.self,
                    from: try await f.phone.call("GET", "/ondevice/models", token: full.token).1
                )
                #expect(listed.models.map(\.id) == [models.qwen.id, models.gemma.id])
                #expect(listed.models.allSatisfy { $0.onMac.state == "absent" })
            }
        }
    }

    /// The loopback listener's second lock: a page that has rebound its own name to
    /// 127.0.0.1 is refused even though the token it cannot read would also stop it.
    @Test func loopbackCallersMustNameALoopbackHost() async throws {
        try await PhoneModelFixture.with { models in
            try await PhoneRouteFixture.with(provider: models.service, hub: models.hub) { f in
                let prepare = "/ondevice/models/\(models.qwen.id)/prepare"
                for (host, origin) in [
                    ("attacker.example:\(f.local.port)", nil),
                    ("127.0.0.1:\(f.local.port)", "http://attacker.example"),
                ] as [(String, String?)] {
                    let raw = try await RawConnection.connect(port: f.local.port)
                    var request = "POST \(prepare) HTTP/1.1\r\nHost: \(host)\r\n"
                        + "Authorization: Bearer \(f.local.token)\r\nContent-Length: 0\r\n"
                    if let origin { request += "Origin: \(origin)\r\n" }
                    try await raw.send(request + "\r\n")
                    let answer = try await Self.readAll(raw)
                    raw.close()
                    #expect(answer.hasPrefix("HTTP/1.1 403"), "\(host) \(origin ?? "")")
                    #expect(answer.contains("loopback"))
                }
                #expect(models.huggingFace.requests.isEmpty)
            }
        }
    }

    /// The whole journey a phone makes: ask, wait, fetch — whole, in ranges, resumed from
    /// the middle, and conditionally — and end up with bytes that hash to the pin.
    @Test func aPhoneFetchesTheVerifiedFileWholeRangedAndResumed() async throws {
        try await PhoneModelFixture.with { models in
            try await PhoneRouteFixture.with(provider: models.service, hub: models.hub) { f in
                let phone = try await f.pair()
                let q = models.qwen
                let bytes = models.qwenBytes
                let count = bytes.count

                let (status, body) = try await f.phone.call(
                    "POST", "/ondevice/models/\(q.id)/prepare", token: phone.token
                )
                #expect(status == 202)
                let accepted = try JSONDecoder().decode(ControlAPI.PhoneModel.self, from: body)
                #expect(accepted.id == q.id)
                #expect(accepted.sha256 == q.sha256)
                #expect(["downloading", "ready"].contains(accepted.onMac.state))
                await models.store.waitUntilSettled(id: q.id)

                let list = try JSONDecoder().decode(
                    ControlAPI.PhoneModelList.self,
                    from: try await f.phone.call("GET", "/ondevice/models", token: phone.token).1
                )
                #expect(list.models.first { $0.id == q.id }?.onMac.state == "ready")

                let path = "/ondevice/models/\(q.id)/file"
                let whole = try await f.phone.fetchFile(path, token: phone.token)
                #expect(whole.status == 200)
                #expect(PhoneModelFixture.sha256(whole.body) == q.sha256)
                #expect(whole["Content-Length"] == "\(count)")
                #expect(whole["Accept-Ranges"] == "bytes")
                #expect(whole["ETag"] == "\"\(q.sha256)\"")
                #expect(whole["X-Content-SHA256"] == q.sha256)
                #expect(whole["Content-Type"] == "application/octet-stream")
                #expect(whole["Content-Disposition"] == "attachment; filename=\"\(q.file)\"")
                #expect(whole["Cache-Control"] == "no-store")
                #expect(whole["X-Content-Type-Options"] == "nosniff")

                let head = try await f.phone.fetchFile(
                    path, token: phone.token, headers: ["Range": "bytes=0-99"]
                )
                #expect(head.status == 206)
                #expect(head.body == bytes.prefix(100))
                #expect(head["Content-Range"] == "bytes 0-99/\(count)")

                // A phone that has the first part asks for the rest, and gets exactly it.
                let middle = 123_457
                let rest = try await f.phone.fetchFile(
                    path, token: phone.token, headers: ["Range": "bytes=\(middle)-"]
                )
                #expect(rest.status == 206)
                #expect(rest.body.count == count - middle)
                #expect(PhoneModelFixture.sha256(rest.body)
                    == PhoneModelFixture.sha256(bytes.subdata(in: middle..<count)))
                #expect(rest["Content-Length"] == "\(count - middle)")
                #expect(rest["Content-Range"] == "bytes \(middle)-\(count - 1)/\(count)")
                #expect(rest["X-Content-SHA256"] == q.sha256)
                var assembled = Data(bytes.prefix(middle))
                assembled.append(rest.body)
                #expect(PhoneModelFixture.sha256(assembled) == q.sha256)

                // Resuming on condition it is still the same file: still a range…
                let guarded = try await f.phone.fetchFile(path, token: phone.token, headers: [
                    "Range": "bytes=\(middle)-", "If-Range": "\"\(q.sha256)\"",
                ])
                #expect(guarded.status == 206)
                #expect(PhoneModelFixture.sha256(guarded.body)
                    == PhoneModelFixture.sha256(rest.body))
                // …and when it is not, the whole file rather than a splice of two.
                let stale = try await f.phone.fetchFile(path, token: phone.token, headers: [
                    "Range": "bytes=\(middle)-",
                    "If-Range": "\"\(String(repeating: "0", count: 64))\"",
                ])
                #expect(stale.status == 200)
                #expect(PhoneModelFixture.sha256(stale.body) == q.sha256)

                let tail = try await f.phone.fetchFile(
                    path, token: phone.token, headers: ["Range": "bytes=-100"]
                )
                #expect(tail.status == 206)
                #expect(tail.body == bytes.suffix(100))

                // Past the end — including exactly at it, which is a phone that already has
                // every byte — is a 416 that says where the end is.
                for asked in ["bytes=\(count)-", "bytes=\(count + 10)-\(count + 20)"] {
                    let refused = try await f.phone.fetchFile(
                        path, token: phone.token, headers: ["Range": asked]
                    )
                    #expect(refused.status == 416, "\(asked)")
                    #expect(refused["Content-Range"] == "bytes */\(count)")
                    #expect(Self.error(in: refused.body) == ControlServer.rangeOutsideFile)
                }

                // The digest is the tag, quoted or bare.
                for tag in ["\"\(q.sha256)\"", q.sha256, "\"other\", \"\(q.sha256)\""] {
                    let unchanged = try await f.phone.fetchFile(
                        path, token: phone.token, headers: ["If-None-Match": tag]
                    )
                    #expect(unchanged.status == 304, "\(tag)")
                    #expect(unchanged.body.isEmpty)
                    #expect(unchanged["Content-Length"] == nil)
                    #expect(unchanged["ETag"] == "\"\(q.sha256)\"")
                }
                let changed = try await f.phone.fetchFile(
                    path, token: phone.token, headers: ["If-None-Match": "\"deadbeef\""]
                )
                #expect(changed.status == 200)

                // The Mac's own tools get the same bytes over loopback.
                let local = try await f.local.fetchFile(
                    path, token: f.local.token, headers: ["Range": "bytes=0-9"]
                )
                #expect(local.status == 206)
                #expect(local.body == bytes.prefix(10))
            }
        }
    }

    /// The file is not there until it is verified: absent, on its way, and failed are all
    /// the same 409 — and prepare says 202 while fetching, unchanged by asking again, and
    /// 200 once the model is ready.
    @Test func theFileWaitsForVerificationAndPrepareSaysWhere() async throws {
        try await PhoneModelFixture.with { models in
            try await PhoneRouteFixture.with(provider: models.service, hub: models.hub) { f in
                let phone = try await f.pair()
                let q = models.qwen
                let file = "/ondevice/models/\(q.id)/file"
                let prepare = "/ondevice/models/\(q.id)/prepare"

                let absent = try await f.phone.call("GET", file, token: phone.token)
                #expect(absent.0 == 409)
                #expect(Self.error(in: absent.1) == ControlServer.phoneModelNotReady)

                models.huggingFace.hold()
                #expect(try await f.phone.status("POST", prepare, token: phone.token) == 202)
                try await until { models.huggingFace.requests.count == 1 }
                #expect(try await f.phone.status("GET", file, token: phone.token) == 409)
                let again = try await f.phone.call("POST", prepare, token: phone.token)
                #expect(again.0 == 202)
                #expect(try JSONDecoder().decode(ControlAPI.PhoneModel.self, from: again.1)
                    .onMac.state == "downloading")
                #expect(models.huggingFace.requests.count == 1)

                models.huggingFace.release()
                await models.store.waitUntilSettled(id: q.id)
                #expect(try await f.phone.status("GET", file, token: phone.token) == 200)
                let ready = try await f.phone.call("POST", prepare, token: phone.token)
                #expect(ready.0 == 200)
                #expect(try JSONDecoder().decode(ControlAPI.PhoneModel.self, from: ready.1)
                    .onMac.state == "ready")
                #expect(models.huggingFace.requests.count == 1)

                // A failed fetch is not servable either, and the list says why.
                var corrupted = models.gemmaBytes
                corrupted[7] ^= 0x01
                models.huggingFace.serve(
                    corrupted, at: PhoneModelFixture.pinnedPath(models.gemma)
                )
                #expect(try await f.phone.status(
                    "POST", "/ondevice/models/\(models.gemma.id)/prepare", token: phone.token
                ) == 202)
                await models.store.waitUntilSettled(id: models.gemma.id)
                #expect(try await f.phone.status(
                    "GET", "/ondevice/models/\(models.gemma.id)/file", token: phone.token
                ) == 409)
                let listed = try JSONDecoder().decode(
                    ControlAPI.PhoneModelList.self,
                    from: try await f.phone.call("GET", "/ondevice/models", token: phone.token).1
                )
                let gemma = try #require(listed.models.first { $0.id == models.gemma.id })
                #expect(gemma.onMac.state == "failed")
                #expect(gemma.onMac.failure == "checksumMismatch")
                #expect(gemma.onMac.reason?.contains("checksum") == true)
            }
        }
    }

    /// `DELETE` takes the Mac's copy back, and says what is left: nothing.
    @Test func deleteTakesTheMacsCopyBack() async throws {
        try await PhoneModelFixture.with { models in
            try await PhoneRouteFixture.with(provider: models.service, hub: models.hub) { f in
                let phone = try await f.pair()
                let q = models.qwen
                _ = try await f.phone.call(
                    "POST", "/ondevice/models/\(q.id)/prepare", token: phone.token
                )
                await models.store.waitUntilSettled(id: q.id)
                #expect(FileManager.default.fileExists(atPath: models.fileURL(q).path))

                for _ in 0..<2 {
                    let (status, body) = try await f.phone.call(
                        "DELETE", "/ondevice/models/\(q.id)", token: phone.token
                    )
                    #expect(status == 200)
                    let entry = try JSONDecoder().decode(ControlAPI.PhoneModel.self, from: body)
                    #expect(entry.onMac == .init(state: "absent"))
                }
                #expect(models.leftovers().isEmpty)
                #expect(try await f.phone.status(
                    "GET", "/ondevice/models/\(q.id)/file", token: phone.token
                ) == 409)
            }
        }
    }

    /// A Mac with no room is a 507 with the reason, before a byte moves.
    @Test func aFullMacAnswers507WithTheReason() async throws {
        let full: PhoneModelStore.SpaceCheck = { needed, _ in
            throw ModelDownloader.DownloadError.insufficientDiskSpace(
                needed: needed, available: .gib(3)
            )
        }
        try await PhoneModelFixture.with(spaceCheck: full) { models in
            try await PhoneRouteFixture.with(provider: models.service, hub: models.hub) { f in
                let phone = try await f.pair()
                let (status, body) = try await f.phone.call(
                    "POST", "/ondevice/models/\(models.gemma.id)/prepare", token: phone.token
                )
                #expect(status == 507)
                let reason = try #require(Self.error(in: body))
                #expect(reason.contains("not enough space on the Mac"))

                let listed = try JSONDecoder().decode(
                    ControlAPI.PhoneModelList.self,
                    from: try await f.phone.call("GET", "/ondevice/models", token: phone.token).1
                )
                let gemma = try #require(listed.models.first { $0.id == models.gemma.id })
                #expect(gemma.onMac.state == "failed")
                #expect(gemma.onMac.failure == "diskFull")
                #expect(gemma.onMac.reason == reason)
                #expect(models.huggingFace.requests.isEmpty)
            }
        }
    }

    /// An id is a catalogue key and nothing else. Whatever else arrives in its place — a
    /// traversal, a file name, a near miss — is the same 404, and nothing is fetched,
    /// served or deleted on its account.
    @Test func idsAreCatalogKeysAndNothingElse() async throws {
        try await PhoneModelFixture.with { models in
            try await PhoneRouteFixture.with(provider: models.service, hub: models.hub) { f in
                let phone = try await f.pair()
                _ = try await models.store.prepare(id: models.qwen.id)
                await models.store.waitUntilSettled(id: models.qwen.id)
                let secret = models.directory.appendingPathComponent("secret.gguf")
                try Data("not a model".utf8).write(to: secret)

                let hostile = [
                    "%2E%2E", "..%2Fsecret.gguf", "..%2F..%2F..%2F..%2Fetc%2Fpasswd",
                    "%2Fetc%2Fpasswd", "~", "*", "secret.gguf",
                    models.qwen.file, "Qwen_Qwen3.5-2B-Q4_0", "QWEN3.5-2B-Q4_0",
                    "qwen3.5-2b-q4_0.", "%20qwen3.5-2b-q4_0", "qwen3.5-2b-q4_0%00",
                    "qwen3.5-2b-q4_0%2F..%2Fgemma-4-e2b-q4_0",
                    "ondevice:qwen3.5-2b-q4_0",
                ]
                for id in hostile {
                    for (method, suffix) in [("GET", "/file"), ("POST", "/prepare"), ("DELETE", "")] {
                        let (status, body) = try await f.phone.call(
                            method, "/ondevice/models/\(id)\(suffix)", token: phone.token
                        )
                        #expect(status == 404, "\(method) \(id)\(suffix)")
                        #expect(Self.error(in: body) != nil, "\(method) \(id)\(suffix)")
                    }
                }
                #expect(models.huggingFace.requests.count == 1)
                #expect(FileManager.default.fileExists(atPath: secret.path))
                #expect(await models.store.state(of: models.qwen.id) == .ready)
                #expect(await models.store.state(of: models.gemma.id) == .absent)
            }
        }
    }

    /// Progress reaches a phone on `/events` as `download` frames it can tie to the model:
    /// the id is `ondevice:` and the model's, and the stream says when it is done — or why
    /// it is not.
    @Test func downloadFramesOnEventsCarryTheModelsID() async throws {
        try await PhoneModelFixture.with(qwenSize: 1_000_000) { models in
            try await PhoneRouteFixture.with(provider: models.service, hub: models.hub) { f in
                let phone = try await f.pair()
                let follower = try await EventFollower.open(f.phone, token: phone.token)
                defer { follower.stop() }
                let qwenFrames = "ondevice:\(models.qwen.id)"

                models.huggingFace.hold()
                #expect(try await f.phone.status(
                    "POST", "/ondevice/models/\(models.qwen.id)/prepare", token: phone.token
                ) == 202)
                try await until {
                    await follower.downloads(qwenFrames).contains {
                        $0.fraction < 1 && $0.error == nil
                    }
                }
                models.huggingFace.release()
                try await until {
                    await follower.downloads(qwenFrames).contains {
                        $0.fraction == 1 && $0.error == nil
                    }
                }
                let frames = await follower.downloads(qwenFrames)
                #expect(frames.allSatisfy {
                    $0.bytesExpected == Int64(models.qwenBytes.count)
                        && $0.name.contains(models.qwen.label)
                })
                #expect(frames.last?.bytesReceived == frames.last?.bytesExpected)

                var corrupted = models.gemmaBytes
                corrupted[3] ^= 0x10
                models.huggingFace.serve(
                    corrupted, at: PhoneModelFixture.pinnedPath(models.gemma)
                )
                #expect(try await f.phone.status(
                    "POST", "/ondevice/models/\(models.gemma.id)/prepare", token: phone.token
                ) == 202)
                try await until {
                    await follower.downloads("ondevice:\(models.gemma.id)").contains {
                        $0.error?.contains("checksum") == true
                    }
                }
            }
        }
    }

    /// 3.35 GB is served from wherever the phone asks without the file ever being read
    /// into memory: the length goes out first, and a range past 2³¹ is exact. The file is
    /// sparse, so it costs one block of disk.
    @Test func aBigFileIsServedFromWhereverThePhoneAsks() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("buddy-phone-big-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let gemma = PhoneModelCatalog.gemma4E2B
        let size = gemma.sizeBytes
        let big = directory.appendingPathComponent(gemma.file)
        let tail = Data("the last bytes of a 3.35 GB model".utf8)
        #expect(FileManager.default.createFile(atPath: big.path, contents: nil))
        let handle = try FileHandle(forWritingTo: big)
        try handle.seek(toOffset: UInt64(size) - UInt64(tail.count))
        try handle.write(contentsOf: tail)
        try handle.close()
        try #require(PhoneModelFixture.size(of: big) == size)

        let provider = OneFile(id: gemma.id, file: .init(
            url: big, sizeBytes: size, sha256: gemma.sha256, fileName: gemma.file
        ))
        try await PhoneRouteFixture.with(provider: provider) { f in
            let phone = try await f.pair()
            let path = "/ondevice/models/\(gemma.id)/file"

            let from = Int(size) - tail.count
            let end = try await f.phone.fetchFile(
                path, token: phone.token, headers: ["Range": "bytes=\(from)-"]
            )
            #expect(end.status == 206)
            #expect(end.body == tail)
            #expect(end["Content-Range"] == "bytes \(from)-\(size - 1)/\(size)")

            let deep = try await f.phone.fetchFile(
                path, token: phone.token, headers: ["Range": "bytes=2147483648-2147483663"]
            )
            #expect(deep.status == 206)
            #expect(deep.body == Data(count: 16))
            #expect(deep["Content-Range"] == "bytes 2147483648-2147483663/\(size)")

            // The whole file: the true length arrives straight away, then the socket is
            // dropped rather than 3.35 GB being pulled through a test.
            let raw = try await RawConnection.connect(port: f.phone.port)
            try await raw.send(
                "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\n"
                    + "Authorization: Bearer \(phone.token)\r\n\r\n"
            )
            var head = ""
            let deadline = ContinuousClock.now + .seconds(10)
            while !head.contains("\r\n\r\n"), ContinuousClock.now < deadline {
                head += try await raw.readSome()
            }
            raw.close()
            #expect(head.hasPrefix("HTTP/1.1 200"))
            #expect(head.contains("Content-Length: \(size)\r\n"))
            #expect(head.contains("ETag: \"\(gemma.sha256)\""))
        }
    }

    /// A phone that walks out of range mid-file stops reading without hanging up. The
    /// slow-reader deadline is what gives its connection slot back.
    @Test func aReaderThatStopsReadingIsGivenUpOn() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("buddy-phone-stall-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("stall.gguf")
        // Bigger than any socket buffer, so the send genuinely stalls.
        try PhoneModelFixture.randomBytes(8 * 1_048_576).write(to: file)
        let provider = OneFile(id: "stall", file: .init(
            url: file, sizeBytes: 8 * 1_048_576,
            sha256: String(repeating: "a", count: 64), fileName: "stall.gguf"
        ))

        try await PhoneRouteFixture.with(
            provider: provider, writeDeadline: .milliseconds(200)
        ) { f in
            let phone = try await f.pair()
            let silent = SilentReader(port: f.phone.port)
            try await silent.connect()
            try await silent.send(
                "GET /ondevice/models/stall/file HTTP/1.1\r\nHost: 127.0.0.1\r\n"
                    + "Authorization: Bearer \(phone.token)\r\n\r\n"
            )
            let deadline = ContinuousClock.now + .seconds(10)
            while await f.server.openConnections > 0 {
                guard ContinuousClock.now < deadline else {
                    Issue.record("The stalled reader kept its connection slot.")
                    break
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(await f.server.openConnections == 0)
            silent.stop()
            #expect(try await f.phone.status("GET", "/health", token: phone.token) == 200)
        }
    }

    // MARK: - The app

    /// What the Settings row says under each name. Pinned because it is the only place the
    /// owner sees these states on the Mac itself.
    @MainActor
    @Test func theSettingsRowSaysWhereEachModelIs() {
        let qwen = PhoneModelCatalog.qwen35_2B
        let gemma = PhoneModelCatalog.gemma4E2B
        #expect(BuddyPhoneModelsRow.describe(PhoneModelService.wire(qwen, state: .ready))
            == "1.3 GB · Apache-2.0 · on this Mac, verified")
        #expect(BuddyPhoneModelsRow.describe(PhoneModelService.wire(qwen, state: .absent))
            == "1.3 GB · Apache-2.0 · not on this Mac")
        #expect(BuddyPhoneModelsRow.describe(PhoneModelService.wire(
            gemma, state: .downloading(bytesReceived: gemma.sizeBytes / 4, bytesPerSecond: 1)
        )) == "3.3 GB · Apache-2.0 · downloading 25% · slower on the phone")
        let failure = PhoneModelStore.Failure(kind: .diskFull, reason: "No room.", bytesOnDisk: 0)
        #expect(BuddyPhoneModelsRow.describe(PhoneModelService.wire(qwen, state: .failed(failure)))
            == "1.3 GB · Apache-2.0 · No room.")
    }

    /// The app's own host answers these routes, and never with the owner's Hugging Face
    /// token — even when one is set. Settings are injected, so nothing here reads or
    /// writes the login Keychain.
    @MainActor
    @Test func theAppFetchesPhoneModelsWithoutTheHuggingFaceToken() async throws {
        try await PhoneModelFixture.with { models in
            var settings = Settings()
            settings.huggingFaceToken = "placeholder-not-a-real-token"
            let app = AppModel(settings: settings)
            try await PhoneModelSeams.$service.withValue(models.service) {
                let provider = try #require(await app.phoneModelProvider())
                let prepared = try await provider.preparePhoneModel(id: models.qwen.id)
                #expect(!prepared.wasReady)
                await models.store.waitUntilSettled(id: models.qwen.id)
                let file = try await provider.phoneModelFile(id: models.qwen.id)
                #expect(file.sha256 == models.qwen.sha256)
                #expect(file.fileName == models.qwen.file)
            }
            #expect(!models.huggingFace.requests.isEmpty)
            #expect(models.huggingFace.requests.allSatisfy { $0.authorization == nil })
        }
    }

    // MARK: - Helpers

    static func error(in body: Data) -> String? {
        try? JSONDecoder().decode(ControlAPI.ErrorResponse.self, from: body).error
    }

    /// Reads a small response to the end: until the server closes, or ten reads.
    static func readAll(_ raw: RawConnection) async throws -> String {
        var answer = ""
        for _ in 0..<10 {
            let more = try await raw.readSome()
            if more.isEmpty { break }
            answer += more
            if answer.contains("\r\n\r\n"), answer.hasSuffix("}") { break }
        }
        return answer
    }
}

// MARK: - Waiting without sleeping blind

func until(
    _ timeout: Duration = .seconds(10), _ condition: @Sendable () async -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { throw BuddyTestError.timeout }
        try await Task.sleep(for: .milliseconds(10))
    }
}

// MARK: - The fixtures

/// A phone-model store and service over a temporary folder, fed by a loopback stand-in for
/// Hugging Face that serves random bytes under the real pinned paths. The catalogue is the
/// real one with each file shrunk to a few hundred kilobytes — same ids, repositories,
/// commits and file names, so every request the store makes is the one it would make for
/// real.
struct PhoneModelFixture {
    var directory = URL(fileURLWithPath: "/nonexistent")
    var root = URL(fileURLWithPath: "/nonexistent")
    var huggingFace: FakeHuggingFace!
    var qwenBytes = Data()
    var gemmaBytes = Data()
    var qwen = PhoneModelCatalog.qwen35_2B
    var gemma = PhoneModelCatalog.gemma4E2B
    var store: PhoneModelStore!
    var service: PhoneModelService!
    var hub = BuddyEventHub()

    static func pinnedPath(_ entry: PhoneModelEntry) -> String {
        "/\(entry.repository)/resolve/\(entry.commit)/\(entry.file)"
    }

    func fileURL(_ entry: PhoneModelEntry) -> URL { root.appendingPathComponent(entry.file) }
    func partialURL(_ entry: PhoneModelEntry) -> URL {
        fileURL(entry).appendingPathExtension("part")
    }

    func size(of url: URL) -> Int64? { Self.size(of: url) }

    static func size(of url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))
            .flatMap { ($0[.size] as? NSNumber)?.int64Value }
    }

    /// Cuts the next transfer of `entry` off after exactly `bytes` — and only once the
    /// store has those bytes on disk, so what a resume starts from is known rather than
    /// raced against how quickly the socket was read before it closed.
    func interrupt(_ entry: PhoneModelEntry, after bytes: Int) async throws {
        huggingFace.hold(after: bytes)
        _ = try await store.prepare(id: entry.id)
        let partial = partialURL(entry)
        try await until { Self.size(of: partial) == Int64(bytes) }
        huggingFace.drop()
        await store.waitUntilSettled(id: entry.id)
    }

    /// Whatever is left in the store's folder, hidden files included.
    func leftovers() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
    }

    static func with(
        spaceCheck: @escaping PhoneModelStore.SpaceCheck = { _, _ in },
        qwenSize: Int = 300_000, gemmaSize: Int = 200_000,
        isolation: isolated (any Actor)? = #isolation,
        _ body: (PhoneModelFixture) async throws -> Void
    ) async throws {
        var fixture = PhoneModelFixture()
        fixture.directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("buddy-phone-models-\(UUID())")
        try FileManager.default.createDirectory(
            at: fixture.directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let huggingFace = try FakeHuggingFace()
        defer { huggingFace.stop() }

        fixture.huggingFace = huggingFace
        fixture.qwenBytes = randomBytes(qwenSize)
        fixture.gemmaBytes = randomBytes(gemmaSize)
        fixture.qwen = shrunk(PhoneModelCatalog.qwen35_2B, to: fixture.qwenBytes)
        fixture.gemma = shrunk(PhoneModelCatalog.gemma4E2B, to: fixture.gemmaBytes)
        huggingFace.serve(fixture.qwenBytes, at: pinnedPath(fixture.qwen))
        huggingFace.serve(fixture.gemmaBytes, at: pinnedPath(fixture.gemma))
        fixture.root = fixture.directory.appendingPathComponent("PhoneModels")
        fixture.store = PhoneModelStore(
            root: fixture.root, catalog: [fixture.qwen, fixture.gemma],
            source: huggingFace.baseURL, spaceCheck: spaceCheck
        )
        fixture.service = PhoneModelService(
            store: fixture.store, hub: fixture.hub, watchInterval: .milliseconds(20)
        )

        // Whatever happened, nothing may still be writing into the folder the defer above
        // is about to delete.
        let store: PhoneModelStore = fixture.store
        let ids = [fixture.qwen.id, fixture.gemma.id]
        do {
            try await body(fixture)
        } catch {
            huggingFace.release()
            for id in ids { try? await store.remove(id: id) }
            throw error
        }
        huggingFace.release()
        for id in ids { try? await store.remove(id: id) }
    }

    /// The real entry, with its size and digest swapped for a small file's.
    static func shrunk(_ real: PhoneModelEntry, to bytes: Data) -> PhoneModelEntry {
        var entry = real
        entry.sizeBytes = Int64(bytes.count)
        entry.sha256 = sha256(bytes)
        return entry
    }

    static func randomBytes(_ count: Int) -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!)
        }
        precondition(status == errSecSuccess)
        return data
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// A control server whose `/ondevice/models` answers from the provider handed in, with a
/// loopback listener for this Mac's own token and a second one standing in for the
/// tailnet, where paired devices and nothing else are honoured.
struct PhoneRouteFixture {
    let server: ControlServer
    let local: TestClient
    let phone: TestClient
    let devices: BuddyRegistry

    func pair(
        name: String = "Galaxy S24 Ultra", scope: BuddyScope = .full
    ) async throws -> ControlAPI.BuddyPairResponse {
        let invitation = await devices.invite(host: "127.0.0.1", port: phone.port, scope: scope)
        let (status, body) = try await phone.call(
            "POST", "/buddy/pair", token: nil,
            body: #"{"code":"\#(invitation.code)","deviceName":"\#(name)","platform":"android"}"#
        )
        #expect(status == 200)
        return try JSONDecoder().decode(ControlAPI.BuddyPairResponse.self, from: body)
    }

    static func with(
        provider: (any PhoneModelProvider)?, hub: BuddyEventHub = BuddyEventHub(),
        swarmToken: String? = nil,
        writeDeadline: Duration = ControlServer.defaultEventWriteDeadline,
        isolation: isolated (any Actor)? = #isolation,
        _ body: (PhoneRouteFixture) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("buddy-phone-routes-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let handshakeURL = directory.appendingPathComponent("control.json")
        let devices = BuddyRegistry(url: directory.appendingPathComponent("buddy.json"))
        let server = ControlServer(
            host: BuddyTestHost(tokens: ["ok"], pace: .milliseconds(1), failing: false),
            handshakeURL: handshakeURL, buddy: devices, events: hub,
            media: MediaRegistry(url: nil),
            uploadsRoot: directory.appendingPathComponent("uploads"),
            postersRoot: directory.appendingPathComponent("posters"),
            eventWriteDeadline: writeDeadline,
            // Never the real CLI: a test must not bind whatever tailnet this machine is on.
            discoverTailnetAddress: { nil },
            phoneModels: provider
        )

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 64
        configuration.timeoutIntervalForRequest = 30
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        try await server.start(swarmToken: swarmToken)
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
        let tailnetPort = try await BuddyControlTests.bindTailnetListener(
            on: server, avoiding: handshake.port
        )

        try await body(PhoneRouteFixture(
            server: server,
            local: TestClient(port: handshake.port, token: handshake.token, session: session),
            phone: TestClient(port: tailnetPort, token: handshake.token, session: session),
            devices: devices
        ))
        await server.stop()
    }
}

/// One file, ready, under one id — for the tests about how bytes go out rather than how
/// they arrived.
struct OneFile: PhoneModelProvider {
    let id: String
    let file: ControlAPI.PhoneModelFile

    func phoneModels() async -> ControlAPI.PhoneModelList { .init(models: []) }

    func preparePhoneModel(id: String) async throws -> ControlAPI.PhoneModelPreparation {
        throw PhoneModelError.unknownModel(id)
    }

    func phoneModelFile(id: String) async throws -> ControlAPI.PhoneModelFile {
        guard id == self.id else { throw PhoneModelError.unknownModel(id) }
        return file
    }

    func removePhoneModel(id: String) async throws -> ControlAPI.PhoneModel {
        throw PhoneModelError.unknownModel(id)
    }
}

extension TestClient {

    /// A GET whose headers matter as much as its body, with whatever conditional and range
    /// headers the test sends. Always to the wire: `URLSession` would otherwise answer a
    /// 304 from its own cache and call it a 200.
    func fetchFile(
        _ path: String, token: String?, headers: [String: String] = [:]
    ) async throws -> MediaAnswer {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (body, response) = try await session.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        var lowered: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            guard let key = key as? String, let value = value as? String else { continue }
            lowered[key.lowercased()] = value
        }
        return MediaAnswer(status: http.statusCode, headers: lowered, body: body)
    }
}

/// Holds an `/events` stream open and keeps every frame it is sent.
final class EventFollower: @unchecked Sendable {
    private let task: Task<Void, any Error>
    private let log: Log

    private actor Log {
        var frames: [TestClient.Frame] = []
        func append(_ frame: TestClient.Frame) { frames.append(frame) }
    }

    private init(task: Task<Void, any Error>, log: Log) {
        self.task = task
        self.log = log
    }

    static func open(_ client: TestClient, token: String) async throws -> EventFollower {
        let log = Log()
        let ready = Ready()
        let task = Task {
            let (bytes, response) = try await client.session.bytes(
                for: client.request("GET", "/events", token: token, body: nil)
            )
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw BuddyTestError.unexpectedRoute
            }
            var name = ""
            for try await line in bytes.lines {
                if line.hasPrefix("event: ") {
                    name = String(line.dropFirst("event: ".count))
                } else if line.hasPrefix("data: ") {
                    await log.append(.init(name: name, data: String(line.dropFirst("data: ".count))))
                    await ready.signal()
                }
            }
        }
        do {
            try await ready.wait()
        } catch {
            task.cancel()
            throw error
        }
        return EventFollower(task: task, log: log)
    }

    /// The `download` frames for one id, in the order they arrived.
    func downloads(_ id: String) async -> [ControlAPI.DownloadEvent] {
        await log.frames.filter { $0.name == "download" }.compactMap {
            try? JSONDecoder().decode(ControlAPI.DownloadEvent.self, from: Data($0.data.utf8))
        }.filter { $0.id == id }
    }

    func stop() { task.cancel() }
}

// MARK: - Hugging Face, over loopback

/// Stands in for huggingface.co: serves a few files at exact paths, honours
/// `Range: bytes=N-`, records what it was asked and with which credential, and can be told
/// to misbehave the ways the real one does — hold a transfer open partway, then either let
/// it finish or drop the connection.
final class FakeHuggingFace: @unchecked Sendable {

    struct Request: Sendable, Equatable {
        var path: String
        var range: String?
        var authorization: String?
    }

    /// What a held transfer sends before it waits, unless told otherwise.
    static let heldPrefix = 16_384

    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake-hugging-face")
    private let lock = NSLock()
    private var files: [String: Data] = [:]
    private var log: [Request] = []
    /// How much of a body goes out before a transfer waits, while transfers are held.
    private var holdingAfter: Int?
    private var held: [(connection: NWConnection, rest: Data)] = []
    private var connections: [NWConnection] = []
    private(set) var port: UInt16 = 0

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        listener = try NWListener(using: parameters, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success else {
            listener.cancel()
            throw BuddyTestError.timeout
        }
        port = listener.port?.rawValue ?? 0
    }

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    var requests: [Request] { lock.withLock { log } }

    func serve(_ data: Data, at path: String) { lock.withLock { files[path] = data } }
    func unserve(_ path: String) { _ = lock.withLock { files.removeValue(forKey: path) } }

    /// Transfers from now on declare their full length, send `bytes` of it, and wait for
    /// `release` or `drop`.
    func hold(after bytes: Int = FakeHuggingFace.heldPrefix) {
        lock.withLock { holdingAfter = bytes }
    }

    /// Lets every held transfer finish.
    func release() {
        for transfer in takeHeld() { send(transfer.connection, "", transfer.rest) }
    }

    /// Hangs up on every held transfer without sending the rest — which is what a dropped
    /// connection looks like from the client's side.
    func drop() {
        for transfer in takeHeld() { transfer.connection.cancel() }
    }

    private func takeHeld() -> [(connection: NWConnection, rest: Data)] {
        lock.withLock {
            holdingAfter = nil
            defer { held = [] }
            return held
        }
    }

    func stop() {
        listener.cancel()
        let open = lock.withLock { () -> [NWConnection] in
            held = []
            defer { connections = [] }
            return connections
        }
        for connection in open { connection.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        lock.withLock { connections.append(connection) }
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
            [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(connection, head: String(
                    decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self
                ))
            } else if error == nil, !complete {
                self.receive(connection, buffer: buffer)
            } else {
                connection.cancel()
            }
        }
    }

    private func respond(_ connection: NWConnection, head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let request = Request(
            path: path, range: headers["range"], authorization: headers["authorization"]
        )
        let (stored, holdAfter) = lock.withLock { (files[path], holdingAfter) }
        guard let stored else {
            send(connection, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            record(request)
            return
        }

        var status = "200 OK"
        var body = stored
        var extra = ""
        if let range = headers["range"], range.hasPrefix("bytes="),
           let from = Int(range.dropFirst("bytes=".count).split(separator: "-").first ?? "") {
            guard from < stored.count else {
                send(connection, "HTTP/1.1 416 Range Not Satisfiable\r\n"
                    + "Content-Range: bytes */\(stored.count)\r\nContent-Length: 0\r\n"
                    + "Connection: close\r\n\r\n")
                record(request)
                return
            }
            status = "206 Partial Content"
            body = stored.subdata(in: from..<stored.count)
            extra = "Content-Range: bytes \(from)-\(stored.count - 1)/\(stored.count)\r\n"
        }
        let header = "HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\n"
            + "Content-Type: application/octet-stream\r\n\(extra)Connection: close\r\n\r\n"

        if let holdAfter {
            send(connection, header, Data(body.prefix(holdAfter)), close: false)
            // Held, then logged, in one step and only after the prefix is queued: a test that
            // can see this request can release or drop it, and the rest of the body can only
            // ever follow the part already sent.
            let rest = Data(body.dropFirst(holdAfter))
            lock.withLock {
                held.append((connection, rest))
                log.append(request)
            }
        } else {
            send(connection, header, body)
            record(request)
        }
    }

    private func record(_ request: Request) { lock.withLock { log.append(request) } }

    private func send(
        _ connection: NWConnection, _ header: String, _ body: Data = Data(), close: Bool = true
    ) {
        var payload = Data(header.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            if close { connection.cancel() }
        })
    }
}
