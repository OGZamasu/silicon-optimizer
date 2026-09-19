import CryptoKit
import Darwin
import Foundation
import Network
import Testing
@testable import SiliconCatalog
@testable import SiliconControl
@testable import SiliconCore
@testable import SiliconRuntime
@testable import SiliconUI

/// The Mac's half of the phone's fallback model: the pinned catalogue, the fetch into
/// `Phone Models/` beside the model library, and the four `/ondevice/models` routes a phone
/// uses to get a model without ever leaving the tailnet.
///
/// Nothing here touches the network or the login Keychain. "Hugging Face" is a loopback
/// socket serving a few hundred kilobytes of random bytes under the real pinned paths, the
/// model library is a temporary folder, and the one 3.35 GB file is sparse — it occupies a
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
        #expect(qwen.recommended.threadsPrompt == 6)
        #expect(qwen.recommended.threadsGenerate == 4)
        #expect(qwen.recommended.contextLength == 4096)
        #expect(!qwen.recommended.thinking)
        #expect(!qwen.slowerOnPhone)

        let gemma = try #require(PhoneModelCatalog.entry(id: "gemma-4-e2b-q4_0"))
        #expect(gemma.label == "Gemma 4 E2B")
        #expect(!gemma.isDefault)
        #expect(gemma.repository == "google/gemma-4-E2B-it-qat-q4_0-gguf")
        #expect(gemma.commit == "675cff42a74c774d6cb76f76d8eacb49b48c9b93")
        #expect(gemma.file == "gemma-4-E2B_q4_0-it.gguf")
        #expect(gemma.sizeBytes == 3_349_516_256)
        #expect(gemma.sha256 == "fa401b55b07ee70a54c6dae3903c783a6e65064312529ea57175cb5f8dec6634")
        #expect(gemma.licence == "Apache-2.0")
        #expect(gemma.recommended.threadsPrompt == 4)
        #expect(gemma.recommended.threadsGenerate == 6)
        #expect(gemma.recommended.contextLength == 4096)
        #expect(!gemma.recommended.thinking)
        #expect(gemma.slowerOnPhone)

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

    /// The numbers the owner's S24 Ultra measured, reported the way they were measured:
    /// writing speed at the thread count the phone is told to use, the sweep it came from,
    /// the first word as an estimate from prompt speed rounded the same way for both, and
    /// "not measured" said rather than implied.
    @Test func theMeasuredNumbersAreTheBenchmarksOwn() throws {
        let qwen = try #require(PhoneModelCatalog.qwen35_2B.measured)
        #expect(qwen.device == "Galaxy S24 Ultra")
        #expect(qwen.runtime == "llama.cpp b11053, CPU")
        #expect(qwen.conditions == "phone hot and charging")
        #expect(qwen.tokensPerSecond == 19.2)
        #expect(qwen.threadSweep == [.init(threads: 4, tokensPerSecond: 19.2),
                                     .init(threads: 6, tokensPerSecond: 17.2)])
        #expect(qwen.promptTokensPerSecond == 122.9)
        #expect(qwen.secondsToFirstWord300 == 2.5)
        #expect(qwen.sustainedTokensPerSecond == nil)
        #expect(qwen.peakMemoryBytes == 2_467 * 1_048_576)

        let gemma = try #require(PhoneModelCatalog.gemma4E2B.measured)
        #expect(gemma.tokensPerSecond == 15.1)
        #expect(gemma.threadSweep == [.init(threads: 4, tokensPerSecond: 14.1),
                                      .init(threads: 6, tokensPerSecond: 15.1)])
        #expect(gemma.promptTokensPerSecond == 92.6)
        #expect(gemma.secondsToFirstWord300 == 3.3)
        #expect(gemma.sustainedTokensPerSecond == 7.5)
        #expect(gemma.peakMemoryBytes == 4_136 * 1_048_576)

        for entry in PhoneModelCatalog.all {
            let measured = try #require(entry.measured)
            // The headline speed is the one at the threads the phone is told to write with.
            let atRecommended = measured.threadSweep.first {
                $0.threads == entry.recommended.threadsGenerate
            }
            #expect(atRecommended?.tokensPerSecond == measured.tokensPerSecond, "\(entry.id)")
            // Rounded up, never to nearest: 300 ÷ prompt speed, in tenths.
            let exact = 300 / measured.promptTokensPerSecond
            #expect(measured.secondsToFirstWord300 >= exact, "\(entry.id)")
            #expect(measured.secondsToFirstWord300 - exact < 0.1, "\(entry.id)")
            // The peak was taken at a context far short of the one recommended.
            #expect(measured.peakMemoryContextTokens < entry.recommended.contextLength)
            // Free memory asked for: more than the peak, by at least a quarter.
            #expect(Double(entry.recommended.minFreeMemoryBytes)
                >= Double(measured.peakMemoryBytes) * 1.25, "\(entry.id)")
        }
        #expect(PhoneModelCatalog.qwen35_2B.recommended.minFreeMemoryBytes == 3_400_000_000)
        #expect(PhoneModelCatalog.gemma4E2B.recommended.minFreeMemoryBytes == 5_600_000_000)
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

        // A file name that could climb out of the folder is not an entry at all — so an id
        // can never lead anywhere but a catalogue file inside `Phone Models/`.
        var escaping = PhoneModelCatalog.qwen35_2B
        escaping.id = "escaping"
        escaping.file = "../Models/escaping.gguf"
        var hidden = PhoneModelCatalog.qwen35_2B
        hidden.id = "hidden"
        hidden.file = ".verified"
        let store = PhoneModelStore(
            catalog: [escaping, hidden, PhoneModelCatalog.qwen35_2B],
            stateFile: { URL(fileURLWithPath: "/nonexistent/phone-models.json") },
            source: { URL(string: "http://127.0.0.1:9")! }, spaceCheck: { _, _ in }
        )
        #expect(store.entry(id: "escaping") == nil)
        #expect(store.entry(id: "hidden") == nil)
        #expect(store.catalog.map(\.id) == ["qwen3.5-2b-q4_0"])
        #expect(store.entry(id: "../qwen3.5-2b-q4_0") == nil)
    }

    /// `<library>/Phone Models`, whatever the library is; the app's support folder only
    /// when there is no library; and a drive that is not connected is a missing drive, never
    /// a reason to use the startup disk.
    @Test func phoneModelsLiveBesideTheModelLibrary() throws {
        let fallback = URL(fileURLWithPath: "/tmp/fallback/Phone Models")
        let library = FileManager.default.temporaryDirectory
            .appendingPathComponent("library-\(UUID())")
        func folder(_ place: PhoneModelPlace) -> String? {
            guard case .folder(let url) = place else { return nil }
            return url.path
        }
        #expect(folder(PhoneModelStore.place(forLibrary: library, fallback: fallback))
            == library.standardizedFileURL.appendingPathComponent("Phone Models").path)
        #expect(folder(PhoneModelStore.place(forLibrary: nil, fallback: fallback))
            == fallback.path)
        #expect(PhoneModelStore.fallbackRoot.path
            .hasSuffix("/Application Support/SiliconOptimizer/Phone Models"))

        // An external library whose drive is not there. Nothing about this path exists.
        let drive = "SiliconTestNoSuchDrive-\(UUID().uuidString.prefix(8))"
        let unplugged = URL(fileURLWithPath: "/Volumes/\(drive)/Local Models")
        #expect(PhoneModelStore.place(forLibrary: unplugged, fallback: fallback)
            == .driveMissing(drive: drive))
        #expect(PhoneModelStore.missingDrive(for: unplugged) == drive)
        // A folder on the startup disk is never "missing", and neither is a path that goes
        // through a link back to it.
        #expect(PhoneModelStore.missingDrive(for: library) == nil)
        #expect(PhoneModelStore.missingDrive(for: URL(fileURLWithPath: NSHomeDirectory())) == nil)
        #expect(PhoneModelStore.missingDrive(for: URL(fileURLWithPath: "/Volumes")) == nil)
        let startupAlias = URL(fileURLWithPath: "/Volumes/Macintosh HD")
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: startupAlias.path)) != nil {
            #expect(PhoneModelStore.missingDrive(
                for: startupAlias.appendingPathComponent("Users")
            ) == nil)
        }
        // And the sentence names the drive.
        #expect(PhoneModelStore.driveMissingSentence(drive).contains("“\(drive)”"))
        #expect(PhoneModelStore.driveMissingSentence(drive).contains("startup disk"))
    }

    /// What a phone reads, built from the catalogue: every pin, and each state.
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
            minFreeMemoryBytes: 3_400_000_000, thinking: false
        ))
        let measured = try #require(absent.measured)
        #expect(measured.tokensPerSecond == 19.2)
        #expect(measured.secondsToFirstWord300 == 2.5)
        #expect(measured.firstWordEstimated)
        #expect(measured.sustainedTokensPerSecond == nil)
        #expect(!measured.sustainedMeasured)
        #expect(absent.onMac == .init(state: "absent"))
        #expect(absent.downloadEventID == "ondevice:qwen3.5-2b-q4_0")

        let half = PhoneModelService.wire(
            qwen, state: .downloading(
                bytesReceived: qwen.sizeBytes / 2, bytesPerSecond: 1, stage: .fetching
            )
        )
        #expect(half.onMac == .init(state: "downloading", stage: "fetching", fraction: 0.5))
        let checking = PhoneModelService.wire(
            qwen, state: .downloading(bytesReceived: 0, bytesPerSecond: 0, stage: .checking)
        )
        #expect(checking.onMac.stage == "checking")
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
        #expect(Set(PhoneModelStore.Stage.allCases.map(\.rawValue))
            == Set(ControlAPI.phoneModelStages))
        #expect(ControlAPI.phoneModelStates == ["absent", "downloading", "ready", "failed"])

        // The keys, exactly: a generated client learns these.
        let object = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(absent)
        ) as? [String: Any])
        #expect(Set(object.keys) == [
            "id", "label", "isDefault", "sizeBytes", "sha256", "licence", "source", "onMac",
            "recommended", "measured", "slowerOnPhone",
        ])
        let measuredKeys = try #require(object["measured"] as? [String: Any])
        #expect(Set(measuredKeys.keys) == [
            "device", "runtime", "conditions", "tokensPerSecond", "threadSweep",
            "promptTokensPerSecond", "secondsToFirstWord300", "firstWordEstimated",
            "sustainedMeasured", "peakMemoryBytes", "peakMemoryContextTokens",
        ])
        let gemma = PhoneModelService.wire(PhoneModelCatalog.gemma4E2B, state: .absent)
        #expect(gemma.slowerOnPhone)
        #expect(gemma.measured?.sustainedTokensPerSecond == 7.5)
        #expect(gemma.measured?.sustainedMeasured == true)
    }

    /// Every failure a phone can be told about has a kind it can act on and a fixed
    /// sentence — never a system error's own text, which can name folders and drives.
    @Test func failuresSayWhatHappenedAndWhatToDo() {
        let entry = PhoneModelCatalog.gemma4E2B
        func kind(_ error: any Error, partial: Int64 = 0) -> PhoneModelStore.Failure {
            PhoneModelStore.failure(for: error, entry: entry, partial: partial)
        }
        let disk = kind(ModelDownloader.DownloadError.insufficientDiskSpace(
            needed: Bytes(entry.sizeBytes), available: .gib(4)
        ))
        #expect(disk.kind == .diskFull)
        #expect(disk.reason.contains("not enough space"))
        #expect(disk.reason.contains("drive the phone models are kept on"))
        #expect(!disk.reason.contains("startup"))
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
        #expect(kind(RedirectRefused(host: "attacker.example")).kind == .server)
        #expect(!kind(RedirectRefused(host: "attacker.example")).reason.contains("attacker"))

        // An error whose own words carry a folder and a drive name: none of it gets out.
        let leaky = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError, userInfo: [
            NSLocalizedDescriptionKey: "You don’t have permission to save “x” in “/Volumes/Secret Drive/Private”.",
        ])
        let other = kind(leaky)
        #expect(other.kind == .other)
        #expect(!other.reason.contains("Secret"))
        #expect(!other.reason.contains("/Volumes"))

        for failure in [disk, mismatch, lost, other] {
            #expect(!failure.reason.contains("/Users/"))
            #expect(!failure.reason.contains("Application Support"))
        }
    }

    /// One builder for the Hub's download URL and for the stand-in the tests use, and the
    /// Hub's is exactly this for both pins.
    @Test func theHubURLIsTheCommitPinnedOne() throws {
        #expect(HuggingFaceClient.downloadURL(
            repository: PhoneModelCatalog.qwen35_2B.repository,
            file: PhoneModelCatalog.qwen35_2B.file,
            revision: PhoneModelCatalog.qwen35_2B.commit
        ).absoluteString == "https://huggingface.co/bartowski/Qwen_Qwen3.5-2B-GGUF/resolve/"
            + "7d26695454df6de5fbcce2e58681e62dae06ce43/Qwen_Qwen3.5-2B-Q4_0.gguf?download=true")
        #expect(HuggingFaceClient.downloadURL(
            repository: PhoneModelCatalog.gemma4E2B.repository,
            file: PhoneModelCatalog.gemma4E2B.file,
            revision: PhoneModelCatalog.gemma4E2B.commit
        ).absoluteString == "https://huggingface.co/google/gemma-4-E2B-it-qat-q4_0-gguf/resolve/"
            + "675cff42a74c774d6cb76f76d8eacb49b48c9b93/gemma-4-E2B_q4_0-it.gguf?download=true")
        // The stand-in gets the same path, so what the fetch tests see is what the Hub is
        // asked for.
        let local = HuggingFaceClient.downloadURL(
            repository: "a/b", file: "c.gguf", revision: "0123",
            base: URL(string: "http://127.0.0.1:9/")!
        )
        #expect(local.absoluteString == "http://127.0.0.1:9/a/b/resolve/0123/c.gguf?download=true")
    }

    /// The session a phone model is fetched on keeps nothing, and does not sit waiting for
    /// a network that is not there.
    @Test func thePublicFileSessionKeepsNothingAndDoesNotWait() {
        let downloader = ModelDownloader(publicFilesFrom: nil, redirects: { _ in false })
        #expect(downloader.waitsForConnectivity == false)
        let configuration = ModelDownloader.publicFileConfiguration()
        #expect(configuration.waitsForConnectivity == false)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.httpShouldSetCookies == false)
        #expect(configuration.httpCookieAcceptPolicy == .never)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.urlCache == nil)
        #expect(configuration.timeoutIntervalForResource <= 60 * 60 * 12)
        // The catalogue's own downloads keep their old behaviour.
        #expect(ModelDownloader().waitsForConnectivity)
    }

    /// Redirects are followed only to Hugging Face, over HTTPS.
    @Test func redirectsGoOnlyToTheHubOverHTTPS() {
        for allowed in [
            "https://huggingface.co/x", "https://cdn-lfs.huggingface.co/repos/a/b",
            "https://cas-bridge.xethub.hf.co/xet-bridge-us/abc?X-Amz-Signature=1",
            "https://hf.co/x", "https://HuggingFace.co./x", "https://cdn-lfs-us-1.hf.co:443/x",
        ] {
            #expect(HuggingFaceClient.isHubRedirect(URL(string: allowed)!), "\(allowed)")
        }
        for refused in [
            "http://huggingface.co/x", "http://cdn-lfs.huggingface.co/x",
            "https://huggingface.co.attacker.example/x", "https://evilhuggingface.co/x",
            "https://hf.co.example/x", "https://127.0.0.1/x", "https://localhost/x",
            "https://user:pass@huggingface.co/x", "https://huggingface.co:8443/x",
            "ftp://huggingface.co/x", "file:///etc/passwd",
        ] {
            #expect(!HuggingFaceClient.isHubRedirect(URL(string: refused)!), "\(refused)")
        }
    }

    // MARK: - Fetching

    /// The ordinary case, all of it: the pinned commit is what is asked for, no credential
    /// or cookie goes out, the bytes are verified, and they land beside the model library.
    @Test func aPreparedModelArrivesFromItsPinnedCommitVerifiedAndWithoutAToken() async throws {
        try await PhoneModelFixture.with { f in
            #expect(await f.state(f.qwen) == .absent)
            #expect(try await f.prepare(f.qwen) == .started)
            await f.settle(f.qwen)
            #expect(await f.state(f.qwen) == .ready)

            let verified = try #require(await f.verified(f.qwen))
            #expect(verified.sha256 == f.qwen.sha256)
            #expect(verified.sizeBytes == Int64(f.qwenBytes.count))
            #expect(PhoneModelFixture.sha256(try Data(contentsOf: verified.url)) == f.qwen.sha256)
            // `<library>/Phone Models`, and the room check was asked about that folder.
            #expect(verified.url.deletingLastPathComponent().standardizedFileURL.path
                == f.root.standardizedFileURL.path)
            #expect(f.root.path.hasSuffix("/Local Models/Phone Models"))
            #expect(f.roomAsked.value.map(\.standardizedFileURL.path)
                == [f.root.standardizedFileURL.path])

            let requests = f.huggingFace.requests
            #expect(requests.map(\.target) == [PhoneModelFixture.pinnedTarget(f.qwen)])
            #expect(requests.allSatisfy { !$0.path.contains("/resolve/main/") })
            // Public files: no bearer of any kind, and certainly not the owner's.
            #expect(requests.allSatisfy { $0.authorization == nil && $0.cookie == nil })
            #expect(!FileManager.default.fileExists(atPath: f.partialURL(f.qwen).path))
            // The other model was not touched.
            #expect(await f.state(f.gemma) == .absent)
        }
    }

    /// A phone's Mac on hotel Wi-Fi: the connection drops partway. What arrived is kept,
    /// the state says so, and the next prepare asks for exactly the rest.
    @Test func aCutConnectionResumesFromWhereItStopped() async throws {
        try await PhoneModelFixture.with { f in
            try await f.interrupt(f.qwen, after: 120_000)

            guard case .failed(let failure) = await f.state(f.qwen) else {
                Issue.record("A cut transfer should read as failed.")
                return
            }
            #expect(failure.kind == .network)
            #expect(failure.bytesOnDisk == 120_000)
            #expect(f.size(of: f.partialURL(f.qwen)) == 120_000)
            #expect(failure.reason.contains("40%"))
            #expect(failure.reason.contains("resume"))
            #expect(await f.verified(f.qwen) == nil)
            let listed = await f.provider.phoneModels().models.first { $0.id == f.qwen.id }
            #expect(listed?.onMac.fraction == 0.4)
            #expect(listed?.onMac.failure == "network")

            #expect(try await f.prepare(f.qwen) == .started)
            await f.settle(f.qwen)
            #expect(await f.state(f.qwen) == .ready)
            #expect(f.huggingFace.requests.count == 2)
            #expect(f.huggingFace.requests.last?.range == "bytes=120000-")
            #expect(f.huggingFace.requests.last?.target == PhoneModelFixture.pinnedTarget(f.qwen))
            // Two ranges, one file: it hashes to the pin.
            #expect(PhoneModelFixture.sha256(try Data(contentsOf: f.fileURL(f.qwen)))
                == f.qwen.sha256)
        }
    }

    /// Bytes that are not the pinned ones are thrown away, not kept to be resumed, and the
    /// phone is told why. The downloader is not asked to check them: the store does, once.
    @Test func aChecksumMismatchDeletesTheBytesAndSaysSo() async throws {
        try await PhoneModelFixture.with { f in
            var corrupted = f.qwenBytes
            corrupted[1_000] ^= 0xFF
            f.huggingFace.serve(corrupted, at: PhoneModelFixture.pinnedPath(f.qwen))
            try await f.fetch(f.qwen)

            guard case .failed(let failure) = await f.state(f.qwen) else {
                Issue.record("A mismatched digest should read as failed.")
                return
            }
            #expect(failure.kind == .checksumMismatch)
            #expect(failure.bytesOnDisk == 0)
            #expect(failure.reason.contains("checksum"))
            #expect(!FileManager.default.fileExists(atPath: f.fileURL(f.qwen).path))
            #expect(!FileManager.default.fileExists(atPath: f.partialURL(f.qwen).path))
            #expect(f.leftovers().isEmpty)
            #expect(await f.verified(f.qwen) == nil)

            let listed = await f.provider.phoneModels().models.first { $0.id == f.qwen.id }
            #expect(listed?.onMac.state == "failed")
            #expect(listed?.onMac.failure == "checksumMismatch")
            #expect(listed?.onMac.fraction == nil)

            // Put right, it starts again from nothing — there is nothing to resume.
            f.huggingFace.serve(f.qwenBytes, at: PhoneModelFixture.pinnedPath(f.qwen))
            try await f.fetch(f.qwen)
            #expect(await f.state(f.qwen) == .ready)
            #expect(f.huggingFace.requests.last?.range == nil)
        }
    }

    /// Hugging Face refusing is a failure with its status in it, not a hang or a crash.
    @Test func aRefusalFromHuggingFaceIsAFailureWithItsStatus() async throws {
        try await PhoneModelFixture.with { f in
            f.huggingFace.unserve(PhoneModelFixture.pinnedPath(f.gemma))
            try await f.fetch(f.gemma)
            guard case .failed(let failure) = await f.state(f.gemma) else {
                Issue.record("A 404 should read as failed.")
                return
            }
            #expect(failure.kind == .server)
            #expect(failure.reason.contains("404"))
        }
    }

    /// Hugging Face sends a file's bytes from a CDN. A redirect anywhere that is not the
    /// Hub over HTTPS ends the fetch before the other host is asked for anything.
    @Test func aRedirectAwayFromTheHubIsNotFollowed() async throws {
        try await PhoneModelFixture.with { f in
            let elsewhere = try FakeHuggingFace()
            defer { elsewhere.stop() }
            elsewhere.serve(f.qwenBytes, at: "/blob")
            f.huggingFace.redirect(
                PhoneModelFixture.pinnedPath(f.qwen), to: "http://127.0.0.1:\(elsewhere.port)/blob"
            )
            try await f.fetch(f.qwen)
            guard case .failed(let failure) = await f.state(f.qwen) else {
                Issue.record("A refused redirect should read as failed.")
                return
            }
            #expect(failure.kind == .server)
            #expect(failure.reason.contains("does not fetch from"))
            #expect(elsewhere.requests.isEmpty)
            #expect(await f.verified(f.qwen) == nil)
        }
    }

    /// A Mac with no network fails at once, and says so, rather than sitting at "0%".
    @Test func anUnreachableHubFailsAtOnceAsAResumableNetworkFailure() async throws {
        let closed = try await BuddyControlTests.freeLoopbackPort()
        try await PhoneModelFixture.with { f in
            let directory = f.directory
            let store = PhoneModelStore(
                catalog: [f.qwen],
                stateFile: { directory.appendingPathComponent("offline.json") },
                source: { URL(string: "http://127.0.0.1:\(closed)")! },
                spaceCheck: { _, _ in }
            )
            let library = f.library
            _ = try await store.prepare(id: f.qwen.id, library: library)
            // Bounded, so a session that waits for connectivity is a failure here rather
            // than a test that hangs: waiting is exactly what it must not do.
            try await until(.seconds(30)) {
                if case .failed = await store.state(of: f.qwen.id, library: library) { return true }
                return false
            }
            guard case .failed(let failure) = await store.state(of: f.qwen.id, library: f.library)
            else {
                Issue.record("An unreachable Hub should read as failed.")
                return
            }
            #expect(failure.kind == .network)
            #expect(failure.reason.contains("refused"))
        }
    }

    /// Asking twice is asking once: a model on its way is not restarted or doubled, and a
    /// ready one is not fetched again.
    @Test func prepareIsIdempotentWhileDownloadingAndOnceReady() async throws {
        try await PhoneModelFixture.with { f in
            f.huggingFace.hold()
            #expect(try await f.prepare(f.qwen) == .started)
            try await until { f.huggingFace.requests.count == 1 }
            #expect(try await f.prepare(f.qwen) == .alreadyDownloading)
            #expect(try await f.prepare(f.qwen) == .alreadyDownloading)
            guard case .downloading(_, _, let stage) = await f.state(f.qwen) else {
                Issue.record("A held transfer should read as downloading.")
                return
            }
            #expect(stage == .fetching)
            #expect(await f.verified(f.qwen) == nil)
            #expect(f.huggingFace.requests.count == 1)

            f.huggingFace.release()
            await f.settle(f.qwen)
            #expect(await f.state(f.qwen) == .ready)
            #expect(try await f.prepare(f.qwen) == .alreadyReady)
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
                _ = try await f.prepare(f.gemma)
                Issue.record("A full disk should refuse the prepare.")
            } catch PhoneModelStore.StoreError.noSpace(let failure) {
                #expect(failure.kind == .diskFull)
            }
            guard case .failed(let failure) = await f.state(f.gemma) else {
                Issue.record("A refused prepare should read as failed.")
                return
            }
            #expect(failure.kind == .diskFull)
            #expect(failure.reason.contains("space"))
            #expect(f.huggingFace.requests.isEmpty)

            do {
                _ = try await f.provider.preparePhoneModel(id: f.gemma.id, verify: false)
                Issue.record("A full disk should refuse the prepare.")
            } catch let error as PhoneModelError {
                #expect(error.status == 507)
            }
        }
    }

    /// The room check is the library drive's, with the same reserve as the Mac's own
    /// downloads — measured where the folder is, not wherever a walk up the path ends.
    @Test func theRoomCheckMeasuresTheLibrarysDrive() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("room-\(UUID())/Local Models/Phone Models")
        // A few bytes always fit.
        try PhoneModelStore.checkRoom(needed: Bytes(1), at: folder)
        // A petabyte never does, and the refusal reports the drive this folder is on.
        do {
            try PhoneModelStore.checkRoom(needed: Bytes(Int64(1) << 50), at: folder)
            Issue.record("A petabyte should not fit.")
        } catch ModelDownloader.DownloadError.insufficientDiskSpace(let needed, let available) {
            #expect(needed == Bytes(Int64(1) << 50))
            let values = try FileManager.default.temporaryDirectory.resourceValues(forKeys: [
                .volumeAvailableCapacityKey, .volumeTotalCapacityKey,
            ])
            let total = Int64(try #require(values.volumeTotalCapacity))
            #expect(available.rawValue > 0 && available.rawValue <= total)
        }
        #expect(ModelDownloader.diskReserve == .gib(10))
    }

    /// Removing takes the Mac's copy, anything partial, and a fetch still in flight — and
    /// nothing that fetch was doing comes back afterwards.
    @Test func removingTakesTheCopyThePartialAndAFetchInFlight() async throws {
        try await PhoneModelFixture.with { f in
            // Ready.
            try await f.fetch(f.qwen)
            try await f.remove(f.qwen)
            #expect(await f.state(f.qwen) == .absent)
            #expect(f.leftovers().isEmpty)
            // Again: nothing to remove is not an error.
            try await f.remove(f.qwen)
            #expect(await f.state(f.qwen) == .absent)

            // Partial.
            try await f.interrupt(f.qwen, after: 50_000)
            #expect(f.size(of: f.partialURL(f.qwen)) == 50_000)
            try await f.remove(f.qwen)
            #expect(await f.state(f.qwen) == .absent)
            #expect(f.leftovers().isEmpty)

            // In flight.
            f.huggingFace.hold()
            let before = f.huggingFace.requests.count
            try await f.prepare(f.qwen)
            try await until { f.huggingFace.requests.count == before + 1 }
            try await f.remove(f.qwen)
            #expect(await f.state(f.qwen) == .absent)
            f.huggingFace.release()
            try await Task.sleep(for: .milliseconds(200))
            #expect(await f.state(f.qwen) == .absent)
            #expect(f.leftovers().isEmpty)

            await #expect(throws: PhoneModelStore.StoreError.unknownModel("nope")) {
                try await f.store.remove(id: "nope", library: f.library)
            }
        }
    }

    /// Remove waits for the fetch it stops — even one caught between its bytes arriving and
    /// their check — and a prepare that arrives meanwhile waits for the remove, then starts
    /// clean. Nothing the stopped fetch was doing lands after the remove has answered.
    @Test func removeWaitsForTheFetchItStopsAndPrepareWaitsForTheRemove() async throws {
        let gate = PauseGate()
        try await PhoneModelFixture.with { f in
            f.checkGate.value = gate
            try await f.prepare(f.qwen)
            // Every byte is here, renamed into place, and the check has not started.
            try await until { await gate.arrivals == 1 }
            #expect(FileManager.default.fileExists(atPath: f.fileURL(f.qwen).path))

            let removed = SharedBox(false)
            let removing = Task {
                try await f.remove(f.qwen)
                removed.value = true
            }
            let prepared = SharedBox<PhoneModelStore.PrepareOutcome?>(nil)
            let preparing = Task {
                try await Task.sleep(for: .milliseconds(50))
                prepared.value = try await f.prepare(f.qwen)
            }
            // Held at the gate, the fetch has not ended, so neither may the remove — nor the
            // prepare queued behind it.
            try await Task.sleep(for: .milliseconds(300))
            #expect(!removed.value)
            #expect(prepared.value == nil)
            #expect(f.huggingFace.requests.count == 1)

            await gate.release()
            try await removing.value
            try await preparing.value
            #expect(removed.value)
            #expect(prepared.value == .started)
            // The stopped fetch wrote nothing after it was stopped: the second one fetched
            // from zero, and it is the one that finished.
            await f.settle(f.qwen)
            #expect(await f.state(f.qwen) == .ready)
            #expect(f.huggingFace.requests.count == 2)
            #expect(f.huggingFace.requests.last?.range == nil)
        }
    }

    /// Stop keeps what arrived, so Download resumes it.
    @Test func stoppingKeepsWhatArrived() async throws {
        try await PhoneModelFixture.with { f in
            f.huggingFace.hold(after: 60_000)
            try await f.prepare(f.qwen)
            try await until { f.size(of: f.partialURL(f.qwen)) == 60_000 }
            let stopped = try #require(await f.provider.cancel(id: f.qwen.id))
            #expect(stopped.onMac.state == "failed")
            #expect(stopped.onMac.failure == "interrupted")
            #expect(stopped.onMac.fraction == 0.2)
            #expect(stopped.onMac.reason?.contains("resume") == true)
            #expect(f.size(of: f.partialURL(f.qwen)) == 60_000)

            f.huggingFace.release()
            try await f.fetch(f.qwen)
            #expect(await f.state(f.qwen) == .ready)
            #expect(f.huggingFace.requests.last?.range == "bytes=60000-")
        }
    }

    /// Ready means verified, not that a file of the right size is sitting there.
    @Test func readyMeansVerifiedNotMerelyTheRightSize() async throws {
        try await PhoneModelFixture.with { f in
            try FileManager.default.createDirectory(at: f.root, withIntermediateDirectories: true)

            // The right name and size, the wrong bytes, never verified.
            var impostor = f.qwenBytes
            impostor[0] ^= 0xFF
            try impostor.write(to: f.fileURL(f.qwen))
            #expect(await f.verified(f.qwen) == nil)
            guard case .failed(let unchecked) = await f.state(f.qwen) else {
                Issue.record("An unchecked file should say it is unchecked.")
                return
            }
            #expect(unchecked.kind == .interrupted)
            #expect(unchecked.reason.contains("has not checked"))
            try await f.fetch(f.qwen)
            #expect(await f.state(f.qwen) == .ready)
            #expect(PhoneModelFixture.sha256(try Data(contentsOf: f.fileURL(f.qwen)))
                == f.qwen.sha256)
            #expect(f.huggingFace.requests.count == 1)

            // The right bytes, put there by hand: hashed and adopted, no network.
            try await f.remove(f.qwen)
            try f.qwenBytes.write(to: f.fileURL(f.qwen))
            #expect(try await f.prepare(f.qwen) == .started)
            await f.settle(f.qwen)
            #expect(await f.state(f.qwen) == .ready)
            #expect(f.huggingFace.requests.count == 1)

            // And a link planted where the file was is not the file, whatever it points at.
            let elsewhere = f.directory.appendingPathComponent("elsewhere.gguf")
            try FileManager.default.moveItem(at: f.fileURL(f.qwen), to: elsewhere)
            try FileManager.default.createSymbolicLink(
                at: f.fileURL(f.qwen), withDestinationURL: elsewhere
            )
            #expect(await f.verified(f.qwen) == nil)
        }
    }

    /// A byte changed in place with the modification time put back exactly: the change
    /// time still moved, so the file is no longer "verified" and is not served as the pin.
    @Test func anInPlaceEditIsCaughtEvenWithItsTimeRestored() async throws {
        try await PhoneModelFixture.with { f in
            try await f.fetch(f.qwen)
            #expect(await f.verified(f.qwen) != nil)
            let url = f.fileURL(f.qwen)
            var before = stat()
            try #require(stat(url.path, &before) == 0)
            let handle = try FileHandle(forWritingTo: url)
            try handle.seek(toOffset: 10)
            try handle.write(contentsOf: Data([f.qwenBytes[10] ^ 0xFF]))
            try handle.close()
            var times = [before.st_atimespec, before.st_mtimespec]
            try #require(utimensat(AT_FDCWD, url.path, &times, 0) == 0)
            var after = stat()
            try #require(stat(url.path, &after) == 0)
            try #require(after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec
                && after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec)
            try #require(after.st_size == before.st_size && after.st_ino == before.st_ino)

            #expect(await f.verified(f.qwen) == nil)
            #expect(await f.state(f.qwen) != .ready)
            // A prepare checks it, finds it wrong, and fetches the pin again.
            try await f.fetch(f.qwen)
            #expect(await f.state(f.qwen) == .ready)
            #expect(PhoneModelFixture.sha256(try Data(contentsOf: url)) == f.qwen.sha256)
            #expect(f.huggingFace.requests.count == 2)
        }
    }

    /// `verify` hashes a ready copy again — what a phone asks for once when its download
    /// did not hash to the pin — and says it is checking while it does.
    @Test func verifyChecksAReadyCopyAgain() async throws {
        try await PhoneModelFixture.with { f in
            try await f.fetch(f.qwen)
            #expect(try await f.prepare(f.qwen) == .alreadyReady)

            let gate = PauseGate()
            f.checkGate.value = gate
            #expect(try await f.prepare(f.qwen, verify: true) == .started)
            try await until { await gate.arrivals == 1 }
            // Being hashed: said so, and not served meanwhile.
            guard case .downloading(_, _, let stage) = await f.state(f.qwen) else {
                Issue.record("A copy being checked should say so.")
                return
            }
            #expect(stage == .checking)
            #expect(await f.verified(f.qwen) == nil)
            #expect(try await f.prepare(f.qwen, verify: true) == .alreadyDownloading)

            await gate.release()
            await f.settle(f.qwen)
            #expect(await f.state(f.qwen) == .ready)
            // Checked, not fetched.
            #expect(f.huggingFace.requests.count == 1)
        }
    }

    /// A finished download nobody checked is checked now and kept if it is right; one that
    /// is wrong, or longer than the file could be, is thrown away and fetched from zero.
    @Test func aCompletePartialIsCheckedAndALongOneIsThrownAway() async throws {
        try await PhoneModelFixture.with { f in
            try FileManager.default.createDirectory(at: f.root, withIntermediateDirectories: true)

            // All of it, never renamed: kept, with no network.
            try f.qwenBytes.write(to: f.partialURL(f.qwen))
            guard case .failed(let before) = await f.state(f.qwen) else {
                Issue.record("A complete, unchecked partial should say so.")
                return
            }
            #expect(before.kind == .interrupted)
            #expect(before.reason.contains("nothing needs downloading"))
            try await f.fetch(f.qwen)
            #expect(await f.state(f.qwen) == .ready)
            #expect(f.huggingFace.requests.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: f.partialURL(f.qwen).path))

            // All of it, but the wrong bytes: fetched afresh.
            var wrong = f.gemmaBytes
            wrong[99] ^= 0x01
            try wrong.write(to: f.partialURL(f.gemma))
            try await f.fetch(f.gemma)
            #expect(await f.state(f.gemma) == .ready)
            #expect(f.huggingFace.requests.map(\.range) == [nil])

            // Longer than the file: a prefix of nothing, so gone before anything is asked.
            try await f.remove(f.gemma)
            try (f.gemmaBytes + Data(count: 10)).write(to: f.partialURL(f.gemma))
            try await f.fetch(f.gemma)
            #expect(await f.state(f.gemma) == .ready)
            #expect(f.huggingFace.requests.map(\.range) == [nil, nil])
            #expect(PhoneModelFixture.sha256(try Data(contentsOf: f.fileURL(f.gemma)))
                == f.gemma.sha256)
        }
    }

    /// The app quits and comes back: a verified model is still ready, and a half-fetched
    /// one says it was interrupted and resumes from what is there.
    @Test func aRelaunchKeepsWhatWasVerifiedAndResumesWhatWasNot() async throws {
        try await PhoneModelFixture.with { f in
            try await f.fetch(f.qwen)
            try await f.interrupt(f.gemma, after: 40_000)
            let partial: Int64 = 40_000
            #expect(f.size(of: f.partialURL(f.gemma)) == partial)

            let stateFile = f.stateFile
            let base = f.huggingFace.baseURL
            let relaunched = PhoneModelStore(
                catalog: [f.qwen, f.gemma], stateFile: { stateFile }, source: { base },
                spaceCheck: { _, _ in }
            )
            #expect(await relaunched.state(of: f.qwen.id, library: f.library) == .ready)
            guard case .failed(let failure) = await relaunched.state(
                of: f.gemma.id, library: f.library
            ) else {
                Issue.record("A partial with nothing fetching it should read as failed.")
                return
            }
            #expect(failure.kind == .interrupted)
            #expect(failure.bytesOnDisk == partial)
            #expect(failure.reason.contains("%"))

            _ = try await relaunched.prepare(id: f.gemma.id, library: f.library)
            await relaunched.waitUntilSettled(id: f.gemma.id)
            #expect(await relaunched.state(of: f.gemma.id, library: f.library) == .ready)
            #expect(f.huggingFace.requests.last?.range == "bytes=\(partial)-")
            #expect(PhoneModelFixture.sha256(try Data(contentsOf: f.fileURL(f.gemma)))
                == f.gemma.sha256)
        }
    }

    // MARK: - The library moves, or its drive goes

    /// The library moves in Settings: the next thing that asks finds the models in the new
    /// place — moved, checked again, and served from there — and the old folder is gone.
    @Test func aLibraryMoveTakesThePhoneModelsAlong() async throws {
        try await PhoneModelFixture.with { f in
            try await f.fetch(f.qwen)
            let oldRoot = f.root
            #expect(await f.state(f.qwen) == .ready)

            let moved = f.directory.appendingPathComponent("New Library")
            try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
            f.library = moved
            // Asking starts the move; it is visible as a stage, then done.
            _ = await f.state(f.qwen)
            await f.settle(f.qwen)
            #expect(await f.state(f.qwen) == .ready)
            let verified = try #require(await f.verified(f.qwen))
            #expect(verified.url.deletingLastPathComponent().standardizedFileURL.path
                == moved.appendingPathComponent("Phone Models").standardizedFileURL.path)
            #expect(PhoneModelFixture.sha256(try Data(contentsOf: verified.url)) == f.qwen.sha256)
            #expect(!FileManager.default.fileExists(atPath: oldRoot.path))
            #expect(f.huggingFace.requests.count == 1)
            #expect(await f.store.notices(library: f.library).isEmpty)
        }
    }

    /// A download in flight when the library moves stops, follows the library with what it
    /// has, and finishes there from where it left off.
    @Test func aFetchInFlightFollowsTheLibrary() async throws {
        try await PhoneModelFixture.with { f in
            f.huggingFace.hold(after: 120_000)
            try await f.prepare(f.qwen)
            try await until { f.size(of: f.partialURL(f.qwen)) == 120_000 }
            let oldRoot = f.root

            let moved = f.directory.appendingPathComponent("New Library")
            f.library = moved
            _ = await f.state(f.qwen)
            // The move restarts the fetch in the new folder, from the moved partial.
            try await until { f.huggingFace.requests.count == 2 }
            #expect(f.huggingFace.requests.last?.range == "bytes=120000-")
            f.huggingFace.release()
            await f.settle(f.qwen)
            #expect(await f.state(f.qwen) == .ready)
            #expect(PhoneModelFixture.sha256(try Data(contentsOf: f.fileURL(f.qwen)))
                == f.qwen.sha256)
            #expect(f.root.path.hasPrefix(moved.path))
            #expect(!FileManager.default.fileExists(atPath: oldRoot.path))
        }
    }

    /// A former folder on a drive that is not connected is not forgotten: the owner is
    /// told where the files are, and they move the next time the drive is there.
    @Test func aFormerFolderOnAnUnpluggedDriveIsReportedAndMovedLater() async throws {
        try await PhoneModelFixture.with { f in
            try await f.fetch(f.gemma)
            let oldRoot = f.root
            f.unplugged.value = [oldRoot.path]
            f.library = f.directory.appendingPathComponent("New Library")

            #expect(await f.state(f.gemma) == .absent)
            let notices = await f.store.notices(library: f.library)
            #expect(notices.map(\.folder.standardizedFileURL.path)
                == [oldRoot.standardizedFileURL.path])
            #expect(notices.first?.reason.contains("“Old Drive”") == true)
            #expect(notices.first?.reason.contains("not connected") == true)
            #expect(FileManager.default.fileExists(atPath: oldRoot.path))

            // The drive is back.
            f.unplugged.value = []
            _ = await f.state(f.gemma)
            await f.settle(f.gemma)
            #expect(await f.state(f.gemma) == .ready)
            #expect(!FileManager.default.fileExists(atPath: oldRoot.path))
            #expect(await f.store.notices(library: f.library).isEmpty)
            #expect(f.huggingFace.requests.count == 1)
        }
    }

    /// A copy already in the new folder — the owner moved the library by hand — is checked
    /// and kept, and the old one goes.
    @Test func aCopyAlreadyInTheNewFolderIsCheckedAndKept() async throws {
        try await PhoneModelFixture.with { f in
            try await f.fetch(f.qwen)
            let oldRoot = f.root
            let moved = f.directory.appendingPathComponent("Copied Library")
            let newRoot = moved.appendingPathComponent("Phone Models")
            try FileManager.default.createDirectory(at: newRoot, withIntermediateDirectories: true)
            try FileManager.default.copyItem(
                at: f.fileURL(f.qwen), to: newRoot.appendingPathComponent(f.qwen.file)
            )
            f.library = moved
            _ = await f.state(f.qwen)
            await f.settle(f.qwen)
            #expect(await f.state(f.qwen) == .ready)
            #expect(!FileManager.default.fileExists(atPath: oldRoot.path))
            #expect(f.huggingFace.requests.count == 1)
        }
    }

    /// A library on a drive that is not connected: every model says so, naming the drive,
    /// and nothing is fetched or created anywhere — least of all on the startup disk.
    @Test func aMissingDriveIsNeverTheStartupDisk() async throws {
        try await PhoneModelFixture.with { f in
            let drive = "SiliconTestNoSuchDrive-\(UUID().uuidString.prefix(8))"
            f.library = URL(fileURLWithPath: "/Volumes/\(drive)/Local Models")

            for entry in [f.qwen, f.gemma] {
                guard case .failed(let failure) = await f.state(entry) else {
                    Issue.record("A missing drive should read as failed.")
                    return
                }
                #expect(failure.kind == .driveMissing)
                #expect(failure.reason.contains("“\(drive)”"))
            }
            await #expect(throws: PhoneModelStore.StoreError.self) { try await f.prepare(f.qwen) }
            await #expect(throws: PhoneModelStore.StoreError.self) { try await f.remove(f.qwen) }
            #expect(await f.verified(f.qwen) == nil)
            #expect(f.huggingFace.requests.isEmpty)
            #expect(f.roomAsked.value.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: "/Volumes/\(drive)"))
            #expect(!FileManager.default.fileExists(
                atPath: f.directory.appendingPathComponent("Fallback").path
            ))
        }
    }

    // MARK: - The Mac's own library

    /// A folder scan of the model library — or importing one file by hand — must never
    /// register a phone model as a Mac model.
    @Test func theMacsLibraryRefusesPhoneModels() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("phone-library-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let phoneFolder = directory.appendingPathComponent("Local Models/Phone Models")
        let otherFolder = directory.appendingPathComponent("Local Models/Elsewhere")
        for folder in [phoneFolder, otherFolder] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let header = GGUFBuilder(architecture: "qwen35")
        let phoneFile = phoneFolder.appendingPathComponent(PhoneModelCatalog.qwen35_2B.file)
        let sameBytesElsewhere = otherFolder.appendingPathComponent(PhoneModelCatalog.qwen35_2B.file)
        try header.write(to: phoneFile)
        try header.write(to: sameBytesElsewhere)

        let library = ModelLibrary(root: directory.appendingPathComponent("index"))
        await #expect(throws: PhoneModelFileRefused.self) {
            _ = try await library.importExternal(file: phoneFile)
        }
        // Any spelling of the folder.
        let lower = directory.appendingPathComponent("Local Models/phone models")
        try? FileManager.default.createDirectory(at: lower, withIntermediateDirectories: true)
        #expect(PhoneModelStore.isInPhoneModelsFolder(lower.appendingPathComponent("x.gguf")))
        // The same header anywhere else is a model like any other — so it was the folder
        // that refused it, not the reader.
        let imported = try await library.importExternal(file: sameBytesElsewhere)
        #expect(imported.primaryFile == sameBytesElsewhere)
        #expect(await library.installed.map(\.primaryFile) == [sameBytesElsewhere])
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

    /// Full control only: a chat-only phone gets the chat refusal, the swarm gets its own —
    /// on loopback and out on the tailnet — and nobody without a token, or with this Mac's
    /// own token out on the tailnet, gets anything at all.
    @Test func theRoutesAreFullScopeAndNeverThePeers() async throws {
        try await PhoneModelFixture.with { models in
            try await PhoneRouteFixture.with(
                provider: models.provider, hub: models.hub, swarmToken: Self.swarmSecret,
                swarmOnTailnet: true
            ) { f in
                let full = try await f.pair(name: "Studio phone")
                let chat = try await f.pair(name: "Lent out", scope: .chat)

                for (method, path) in Self.everyRoute(models.qwen.id) {
                    let refusedForChat = try await f.phone.call(method, path, token: chat.token)
                    #expect(refusedForChat.0 == 403, "\(method) \(path)")
                    #expect(Self.error(in: refusedForChat.1) == ControlServer.chatOnlyRefusal)

                    // The swarm secret, where a node would use it: on the tailnet listener…
                    let refusedForPeers = try await f.phone.call(
                        method, path, token: Self.swarmSecret
                    )
                    #expect(refusedForPeers.0 == 403, "\(method) \(path)")
                    #expect(Self.error(in: refusedForPeers.1)
                        == ControlServer.phoneModelsAreNotForPeers)
                    // …and on loopback.
                    let refusedLocally = try await f.local.call(
                        method, path, token: Self.swarmSecret
                    )
                    #expect(refusedLocally.0 == 403, "\(method) \(path)")
                    #expect(Self.error(in: refusedLocally.1)
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
            try await PhoneRouteFixture.with(provider: models.provider, hub: models.hub) { f in
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
            try await PhoneRouteFixture.with(provider: models.provider, hub: models.hub) { f in
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
                await models.settle(q)

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
                // …and when it is not, or the tag is weak, the whole file rather than a
                // splice of two. A 200 to a ranged request means: throw the partial away.
                for condition in ["\"\(String(repeating: "0", count: 64))\"", "W/\"\(q.sha256)\""] {
                    let stale = try await f.phone.fetchFile(path, token: phone.token, headers: [
                        "Range": "bytes=\(middle)-", "If-Range": condition,
                    ])
                    #expect(stale.status == 200, "\(condition)")
                    #expect(PhoneModelFixture.sha256(stale.body) == q.sha256)
                }

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
                // A unit this server does not know is ignored, not refused.
                let items = try await f.phone.fetchFile(
                    path, token: phone.token, headers: ["Range": "items=0-5"]
                )
                #expect(items.status == 200)
                #expect(items.body.count == count)

                // The digest is the tag, quoted or bare, weak or in a list.
                for tag in [
                    "\"\(q.sha256)\"", q.sha256, "\"other\", \"\(q.sha256)\"",
                    "W/\"\(q.sha256)\"", "*",
                ] {
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
    /// 200 once the model is ready. `?verify=1` checks a ready copy again.
    @Test func theFileWaitsForVerificationAndPrepareSaysWhere() async throws {
        try await PhoneModelFixture.with { models in
            try await PhoneRouteFixture.with(provider: models.provider, hub: models.hub) { f in
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
                let downloading = try JSONDecoder().decode(ControlAPI.PhoneModel.self, from: again.1)
                #expect(downloading.onMac.state == "downloading")
                #expect(downloading.onMac.stage == "fetching")
                #expect(models.huggingFace.requests.count == 1)

                models.huggingFace.release()
                await models.settle(q)
                #expect(try await f.phone.status("GET", file, token: phone.token) == 200)
                let ready = try await f.phone.call("POST", prepare, token: phone.token)
                #expect(ready.0 == 200)
                #expect(try JSONDecoder().decode(ControlAPI.PhoneModel.self, from: ready.1)
                    .onMac.state == "ready")
                #expect(models.huggingFace.requests.count == 1)

                // A phone whose download did not hash asks the Mac to check its copy.
                let verify = try await f.phone.call(
                    "POST", prepare + "?verify=1", token: phone.token
                )
                #expect(verify.0 == 202)
                await models.settle(q)
                #expect(try await f.phone.status("GET", file, token: phone.token) == 200)
                #expect(models.huggingFace.requests.count == 1)
                let unclear = try await f.phone.call(
                    "POST", prepare + "?verify=maybe", token: phone.token
                )
                #expect(unclear.0 == 400)
                #expect(Self.error(in: unclear.1) == ControlServer.phoneModelVerifyValues)

                // A failed fetch is not servable either, and the list says why.
                var corrupted = models.gemmaBytes
                corrupted[7] ^= 0x01
                models.huggingFace.serve(
                    corrupted, at: PhoneModelFixture.pinnedPath(models.gemma)
                )
                #expect(try await f.phone.status(
                    "POST", "/ondevice/models/\(models.gemma.id)/prepare", token: phone.token
                ) == 202)
                await models.settle(models.gemma)
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
            try await PhoneRouteFixture.with(provider: models.provider, hub: models.hub) { f in
                let phone = try await f.pair()
                let q = models.qwen
                _ = try await f.phone.call(
                    "POST", "/ondevice/models/\(q.id)/prepare", token: phone.token
                )
                await models.settle(q)
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
            try await PhoneRouteFixture.with(provider: models.provider, hub: models.hub) { f in
                let phone = try await f.pair()
                let (status, body) = try await f.phone.call(
                    "POST", "/ondevice/models/\(models.gemma.id)/prepare", token: phone.token
                )
                #expect(status == 507)
                let reason = try #require(Self.error(in: body))
                #expect(reason.contains("not enough space"))

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

    /// The library's drive is not connected: prepare, file and delete are a 503 naming it,
    /// and the list says the same for every model.
    @Test func aMissingDriveAnswers503NamingIt() async throws {
        try await PhoneModelFixture.with { models in
            let drive = "SiliconTestNoSuchDrive-\(UUID().uuidString.prefix(8))"
            models.library = URL(fileURLWithPath: "/Volumes/\(drive)/Local Models")
            try await PhoneRouteFixture.with(provider: models.provider, hub: models.hub) { f in
                let phone = try await f.pair()
                let q = models.qwen
                for (method, path) in [
                    ("POST", "/ondevice/models/\(q.id)/prepare"),
                    ("GET", "/ondevice/models/\(q.id)/file"),
                    ("DELETE", "/ondevice/models/\(q.id)"),
                ] {
                    let (status, body) = try await f.phone.call(method, path, token: phone.token)
                    #expect(status == 503, "\(method) \(path)")
                    #expect(Self.error(in: body) == PhoneModelStore.driveMissingSentence(drive))
                }
                let listed = try JSONDecoder().decode(
                    ControlAPI.PhoneModelList.self,
                    from: try await f.phone.call("GET", "/ondevice/models", token: phone.token).1
                )
                #expect(listed.models.allSatisfy {
                    $0.onMac.state == "failed" && $0.onMac.failure == "driveMissing"
                })
                #expect(models.huggingFace.requests.isEmpty)
            }
        }
    }

    /// An id is a catalogue key and nothing else. Whatever else arrives in its place — a
    /// traversal, a file name, a near miss — is the same 404, and nothing is fetched,
    /// served or deleted on its account.
    @Test func idsAreCatalogKeysAndNothingElse() async throws {
        try await PhoneModelFixture.with { models in
            try await PhoneRouteFixture.with(provider: models.provider, hub: models.hub) { f in
                let phone = try await f.pair()
                try await models.fetch(models.qwen)
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
                #expect(await models.state(models.qwen) == .ready)
                #expect(await models.state(models.gemma) == .absent)
            }
        }
    }

    /// Progress reaches a phone on `/events` as `download` frames it can tie to the model:
    /// the id is `ondevice:` and the model's, the stage says what is happening, and the
    /// stream says when it is done — or why it is not, or that it was removed.
    @Test func downloadFramesOnEventsCarryTheModelsIDAndStage() async throws {
        try await PhoneModelFixture.with(qwenSize: 1_000_000) { models in
            try await PhoneRouteFixture.with(provider: models.provider, hub: models.hub) { f in
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
                        $0.fraction < 1 && $0.error == nil && $0.stage == "fetching"
                    }
                }
                models.huggingFace.release()
                try await until {
                    await follower.downloads(qwenFrames).contains {
                        $0.fraction == 1 && $0.error == nil && $0.stage == nil
                    }
                }
                let frames = await follower.downloads(qwenFrames)
                #expect(frames.allSatisfy {
                    $0.bytesExpected == Int64(models.qwenBytes.count)
                        && $0.name.contains(models.qwen.label)
                })
                // Done is the last frame, and only the last frame has no stage.
                #expect(frames.last?.stage == nil)
                #expect(frames.dropLast().allSatisfy { $0.stage != nil })

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

                // Removed while it was still arriving.
                try await models.remove(models.gemma)
                models.huggingFace.serve(
                    models.gemmaBytes, at: PhoneModelFixture.pinnedPath(models.gemma)
                )
                models.huggingFace.hold()
                #expect(try await f.phone.status(
                    "POST", "/ondevice/models/\(models.gemma.id)/prepare", token: phone.token
                ) == 202)
                try await until { models.huggingFace.requests.count == 3 }
                #expect(try await f.phone.status(
                    "DELETE", "/ondevice/models/\(models.gemma.id)", token: phone.token
                ) == 200)
                try await until {
                    await follower.downloads("ondevice:\(models.gemma.id)").contains {
                        $0.error == PhoneModelService.removedWhileDownloading
                    }
                }
            }
        }
    }

    /// What the Mac fetches for the owner's phone is the owner's business: frames about it
    /// go to this Mac's own token and full-control devices, never to a chat-only phone or
    /// the swarm. The Mac's own downloads still go to everyone.
    @Test func phoneModelFramesGoOnlyToFullControl() async throws {
        let hub = BuddyEventHub()
        let full = await hub.subscribe(as: .device(id: "full", scope: .full))
        let chat = await hub.subscribe(as: .device(id: "chat", scope: .chat))
        let peer = await hub.subscribe(as: .peer)
        let mac = await hub.subscribe(as: .thisMac)
        let phoneFrame = PhoneModelService.downloadEvent(
            PhoneModelCatalog.qwen35_2B,
            state: .downloading(bytesReceived: 1, bytesPerSecond: 1, stage: .fetching)
        )
        let macFrame = ControlAPI.DownloadEvent(
            id: "qwen3-coder-30b", name: "Qwen3-Coder", fraction: 0.5, bytesReceived: 1,
            bytesExpected: 2, bytesPerSecond: 1
        )
        await hub.post(.download(phoneFrame))
        await hub.post(.download(macFrame))
        for subscriber in [full, chat, peer, mac] { await hub.cancel(subscriber.id) }

        func ids(_ stream: AsyncStream<BuddyEvent.Frame>) async -> [String] {
            var seen: [String] = []
            for await frame in stream {
                if let event = try? JSONDecoder().decode(
                    ControlAPI.DownloadEvent.self, from: frame.data
                ) { seen.append(event.id) }
            }
            return seen
        }
        #expect(await ids(full.stream) == [phoneFrame.id, macFrame.id])
        #expect(await ids(mac.stream) == [phoneFrame.id, macFrame.id])
        #expect(await ids(chat.stream) == [macFrame.id])
        #expect(await ids(peer.stream) == [macFrame.id])
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

    // MARK: - GET /media, which answers files the same way

    /// The conditionals `GET /media/{id}` shares with the phone-model file: `If-None-Match`
    /// weak, in a list and `*`; `If-Range` strong only; and a range unit it does not know
    /// ignored rather than refused.
    @Test func mediaHonoursEveryConditionalTheFileRouteDoes() async throws {
        try await BuddyMediaFixture.withServer { fixture in
            let image = try fixture.writeOutput(
                named: "still.png", bytes: BuddyMediaRoutesTests.pngBytes(count: 1_000)
            )
            let id = try #require(
                await fixture.registry.register(path: image.path, within: [fixture.outputs.path])
            )
            let paired = try await fixture.pair()
            let path = "/media/\(id)"
            let first = try await fixture.phone.fetchFile(path, token: paired.token)
            let tag = try #require(first["ETag"])

            for asked in ["W/\(tag)", "\"nope\", \(tag)", "*", tag] {
                let answer = try await fixture.phone.fetchFile(
                    path, token: paired.token, headers: ["If-None-Match": asked]
                )
                #expect(answer.status == 304, "\(asked)")
            }
            #expect(try await fixture.phone.fetchFile(
                path, token: paired.token, headers: ["If-None-Match": "\"nope\""]
            ).status == 200)

            let ranged = try await fixture.phone.fetchFile(
                path, token: paired.token, headers: ["Range": "bytes=10-", "If-Range": tag]
            )
            #expect(ranged.status == 206)
            #expect(ranged.body.count == 990)
            for condition in ["W/\(tag)", "\"nope\"", "Sat, 19 Sep 2026 10:00:00 GMT"] {
                let whole = try await fixture.phone.fetchFile(
                    path, token: paired.token, headers: ["Range": "bytes=10-", "If-Range": condition]
                )
                #expect(whole.status == 200, "\(condition)")
                #expect(whole.body.count == 1_000)
            }
            let unknownUnit = try await fixture.phone.fetchFile(
                path, token: paired.token, headers: ["Range": "items=0-5"]
            )
            #expect(unknownUnit.status == 200)
            #expect(unknownUnit.body.count == 1_000)
            let mixedCase = try await fixture.phone.fetchFile(
                path, token: paired.token, headers: ["Range": "Bytes=0-9"]
            )
            #expect(mixedCase.status == 206)
            #expect(mixedCase.body.count == 10)
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
            gemma, state: .downloading(
                bytesReceived: gemma.sizeBytes / 4, bytesPerSecond: 1, stage: .fetching
            )
        )) == "3.3 GB · Apache-2.0 · downloading 25% · slower on the phone")
        // Hashing is not downloading, and never reads as "downloading 100%".
        #expect(BuddyPhoneModelsRow.describe(PhoneModelService.wire(
            qwen, state: .downloading(
                bytesReceived: qwen.sizeBytes / 2, bytesPerSecond: 0, stage: .checking
            )
        )) == "1.3 GB · Apache-2.0 · Checking… 50%")
        #expect(BuddyPhoneModelsRow.describe(PhoneModelService.wire(
            qwen, state: .downloading(bytesReceived: 0, bytesPerSecond: 0, stage: .moving)
        )) == "1.3 GB · Apache-2.0 · Moving with the model library…")
        let failure = PhoneModelStore.Failure(kind: .diskFull, reason: "No room.", bytesOnDisk: 0)
        #expect(BuddyPhoneModelsRow.describe(PhoneModelService.wire(qwen, state: .failed(failure)))
            == "1.3 GB · Apache-2.0 · No room.")
        #expect(BuddyPhoneModelsRow.explain(.folder(URL(fileURLWithPath: "/Volumes/T9/Local Models/Phone Models")))
            .contains("Kept in /Volumes/T9/Local Models/Phone Models."))
        #expect(BuddyPhoneModelsRow.explain(.driveMissing(drive: "External SSD"))
            .contains("“External SSD”, which is not connected"))
    }

    /// The app's own service, as the app builds it — the real catalogue, store and
    /// downloader — with only the network endpoint, the state file and the room check
    /// swapped. It puts the models where the app's settings say the library is, and it
    /// never sends the Hugging Face token, even with one set. Settings are injected, so
    /// nothing here reads or writes the login Keychain.
    @MainActor
    @Test func theAppFetchesPhoneModelsWithoutTheHuggingFaceToken() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("buddy-phone-app-\(UUID())")
        let library = directory.appendingPathComponent("Local Models")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let huggingFace = try FakeHuggingFace()
        defer { huggingFace.stop() }

        // The real pin. Its 1.3 GB cannot be served from a test, so the fetch ends short —
        // which is still a fetch: the request is what is being checked.
        let qwen = PhoneModelCatalog.qwen35_2B
        huggingFace.serve(PhoneModelFixture.randomBytes(64 * 1024), at: PhoneModelFixture.pinnedPath(qwen))

        var settings = Settings()
        settings.huggingFaceToken = "placeholder-not-a-real-token"
        settings.modelLibraryDirectory = library.path
        let app = AppModel(settings: settings)
        let environment = PhoneModelSeams.Environment(
            huggingFace: huggingFace.baseURL,
            stateFile: directory.appendingPathComponent("phone-models.json"),
            spaceCheck: { _, _ in }
        )
        try await PhoneModelSeams.$environment.withValue(environment) {
            let provider = try #require(await app.phoneModelProvider())
            let prepared = try await provider.preparePhoneModel(id: qwen.id, verify: false)
            #expect(!prepared.wasReady)
            await AppPhoneModels.service.store.waitUntilSettled(id: qwen.id)

            let listed = await provider.phoneModels().models.first { $0.id == qwen.id }
            #expect(listed?.onMac.state == "failed")
            #expect(listed?.onMac.failure == "network")
            // Beside the library the settings name, and nowhere else.
            let partial = library.appendingPathComponent("Phone Models")
                .appendingPathComponent(qwen.file + ".part")
            #expect(PhoneModelFixture.size(of: partial) == 65_536)
            _ = try await provider.removePhoneModel(id: qwen.id)
            #expect(!FileManager.default.fileExists(atPath: partial.path))
            // Nothing keeps polling this test's library once it is gone.
            await AppPhoneModels.service.waitForWatchers()
        }
        #expect(huggingFace.requests.map(\.target) == [PhoneModelFixture.pinnedTarget(qwen)])
        #expect(huggingFace.requests.allSatisfy { $0.authorization == nil && $0.cookie == nil })
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
