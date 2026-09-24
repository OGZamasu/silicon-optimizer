import Darwin
import Foundation
import Testing
@testable import SiliconUI

/// Where the 3D engines are looked for when Settings names no trellis2 folder. The default
/// used to be one particular Mac's external disk, written into the source.
@Suite("The trellis2 folder", .redirectedConversationStore)
@MainActor
struct TrellisBaseDirectoryTests {

    /// A scratch tree standing in for a home folder and two disks.
    private final class Tree {
        let root: URL
        var home: URL { root.appendingPathComponent("home", isDirectory: true) }
        var work: URL { root.appendingPathComponent("Work", isDirectory: true) }
        var spare: URL { root.appendingPathComponent("Spare", isDirectory: true) }

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("trellis-base-\(UUID().uuidString)", isDirectory: true)
            for folder in [home, work, spare] {
                try FileManager.default.createDirectory(
                    at: folder, withIntermediateDirectories: true
                )
            }
        }

        /// Sets up `engine` in `disk`'s trellis2 folder and returns that folder.
        @discardableResult
        func install(_ engine: String, on disk: URL) throws -> URL {
            let base = disk.appendingPathComponent("trellis2", isDirectory: true)
            try FileManager.default.createDirectory(
                at: base.appendingPathComponent(engine), withIntermediateDirectories: true
            )
            return base
        }

        func clean() { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: - What counts as the engines' folder

    /// A bare trellis2 folder is not the engines: the one that has them is.
    @Test func onlyAFolderWithAnEngineInItCounts() throws {
        let tree = try Tree()
        defer { tree.clean() }
        try FileManager.default.createDirectory(
            at: tree.work.appendingPathComponent("trellis2"), withIntermediateDirectories: true
        )
        #expect(Settings.trellisBaseDirectory(home: tree.home, disks: [tree.work]) == nil)

        let engines = try tree.install("hunyuan3d-swift", on: tree.spare)
        let found = Settings.trellisBaseDirectory(home: tree.home, disks: [tree.work, tree.spare])
        #expect(found?.path == engines.path)
    }

    @Test func theHomeFolderIsLookedInFirst() throws {
        let tree = try Tree()
        defer { tree.clean() }
        let home = try tree.install("trellis-mac", on: tree.home)
        try tree.install("trellis-mac", on: tree.work)
        let found = Settings.trellisBaseDirectory(home: tree.home, disks: [tree.work])
        #expect(found?.path == home.path)
    }

    /// Two disks with engines is a choice for the owner, not a guess that then sticks.
    @Test func twoDisksWithEnginesChooseNeither() throws {
        let tree = try Tree()
        defer { tree.clean() }
        try tree.install("trellis-mac", on: tree.work)
        try tree.install("hunyuan3d-swift", on: tree.spare)
        #expect(Settings.trellisBaseDirectory(home: tree.home, disks: [tree.work, tree.spare])
                == nil)
    }

    // MARK: - Which disks are looked on

    /// A disk image carries programs the app would run; a read-only or hidden volume cannot
    /// hold a working engine tree; a network share is not asked at all.
    @Test func onlyWritableLocalVisibleDisksAreLookedOn() {
        let local = UInt32(MNT_LOCAL)
        let mounts: [Settings.Mount] = [
            .init(path: "/Volumes/Work", flags: local | UInt32(MNT_NOSUID | MNT_JOURNALED)),
            .init(path: "/Volumes/Installer", flags: local | UInt32(MNT_RDONLY)),
            .init(path: "/Volumes/Download", flags: local | UInt32(MNT_QUARANTINE)),
            .init(path: "/Volumes/Backups", flags: local | UInt32(MNT_DONTBROWSE)),
            .init(path: "/Volumes/Share", flags: UInt32(MNT_NOSUID)),
            .init(path: "/System/Volumes/Data", flags: local),
            .init(path: "/Volumes/Archive", flags: local),
        ]
        #expect(Settings.diskRoots(in: mounts).map(\.path) == ["/Volumes/Archive", "/Volumes/Work"])
        // And this Mac's own table reads without trouble, whatever is mounted.
        #expect(Settings.localDiskRoots().allSatisfy { $0.path.hasPrefix("/Volumes/") })
    }

    // MARK: - When it is looked for, and what is kept

    /// Counts the searches an app model makes.
    private final class Searches { var count = 0 }

    private func appModel(searching tree: Tree, disks: [URL]) -> (AppModel, Searches) {
        let model = AppModel(settings: .init())
        let searches = Searches()
        model.trellisSearchRoots = {
            searches.count += 1
            return (tree.home, disks)
        }
        return (model, searches)
    }

    /// Found once, it is the setting from then on: visible in Settings, and not searched for
    /// again — even when that disk is away for a while.
    @Test func aFolderFoundIsWrittenIntoSettingsAndKept() async throws {
        let tree = try Tree()
        defer { tree.clean() }
        let engines = try tree.install("trellis-mac", on: tree.work)
        let (model, searches) = appModel(searching: tree, disks: [tree.work])

        #expect(model.trellisBaseDirectory.path == engines.path)
        try await until { model.settings.trellisBaseDirectory == engines.path }

        try FileManager.default.removeItem(at: engines)
        #expect(model.trellisBaseDirectory.path == engines.path)
        #expect(searches.count == 1)
    }

    /// Nothing is fixed at launch: a disk plugged in after the first look is found.
    @Test func aDiskPluggedInLaterIsFound() async throws {
        let tree = try Tree()
        defer { tree.clean() }
        let (model, _) = appModel(searching: tree, disks: [tree.work])
        model.trellisSearchInterval = .zero

        let fallback = tree.home.appendingPathComponent("trellis2")
        #expect(model.trellisBaseDirectory.path == fallback.path)
        await Task.yield()
        #expect(model.settings.trellisBaseDirectory.isEmpty)

        let engines = try tree.install("hunyuan3d-swift", on: tree.work)
        #expect(model.trellisBaseDirectory.path == engines.path)
        try await until { model.settings.trellisBaseDirectory == engines.path }
    }

    /// A Mac without the engines is not searched on every redraw of the 3D tab.
    @Test func aSearchThatFoundNothingStandsForAWhile() throws {
        let tree = try Tree()
        defer { tree.clean() }
        let (model, searches) = appModel(searching: tree, disks: [tree.work])
        _ = model.trellisBaseDirectory
        _ = model.trellisBaseDirectory
        #expect(searches.count == 1)
    }

    @Test func aFolderSetInSettingsIsUsedAsIsAndNeverSearchedFor() throws {
        let tree = try Tree()
        defer { tree.clean() }
        try tree.install("trellis-mac", on: tree.work)
        let (model, searches) = appModel(searching: tree, disks: [tree.work])
        model.settings.trellisBaseDirectory = "  /opt/engines/trellis2 "
        #expect(model.trellisBaseDirectory.path == "/opt/engines/trellis2")
        #expect(searches.count == 0)
    }

    private func until(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw TrellisTestError.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private enum TrellisTestError: Error { case timeout }
