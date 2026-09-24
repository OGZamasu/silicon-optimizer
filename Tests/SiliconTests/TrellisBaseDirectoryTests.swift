import Foundation
import Testing
@testable import SiliconUI

/// Where the 3D engines are looked for when Settings names no trellis2 folder. The default
/// used to be one particular Mac's external disk, written into the source.
@Suite("The trellis2 folder")
struct TrellisBaseDirectoryTests {

    private func scratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("trellis-base-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func folder(_ path: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The engines are big, so they are often set up on an external disk.
    @Test func oneOnADiskIsFoundWhenTheHomeFolderHasNone() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = try folder("home", in: root)
        let empty = try folder("Empty", in: root)
        let disk = try folder("Disk", in: root)
        let engines = try folder("Disk/trellis2", in: root)

        let found = Settings.trellisBaseDirectory(home: home, disks: [empty, disk])
        #expect(found.standardizedFileURL.path == engines.standardizedFileURL.path)
    }

    @Test func theHomeFolderIsLookedInFirst() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = try folder("home", in: root)
        let engines = try folder("home/trellis2", in: root)
        _ = try folder("Disk/trellis2", in: root)

        let found = Settings.trellisBaseDirectory(
            home: home, disks: [root.appendingPathComponent("Disk")]
        )
        #expect(found.standardizedFileURL.path == engines.standardizedFileURL.path)
    }

    /// With none anywhere, the home folder's: the Mesh tab then says what is missing there.
    @Test func withNoneAnywhereItIsTheHomeFolders() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = try folder("home", in: root)

        let found = Settings.trellisBaseDirectory(home: home, disks: [try folder("Disk", in: root)])
        #expect(found.standardizedFileURL.path
                == home.appendingPathComponent("trellis2").standardizedFileURL.path)
    }

    @Test func aFolderSetInSettingsIsUsedAsIs() {
        var settings = Settings()
        #expect(settings.resolvedTrellisBaseDirectory == Settings.defaultTrellisBaseDirectory)
        settings.trellisBaseDirectory = "  /opt/engines/trellis2 "
        #expect(settings.resolvedTrellisBaseDirectory.path == "/opt/engines/trellis2")
    }
}
