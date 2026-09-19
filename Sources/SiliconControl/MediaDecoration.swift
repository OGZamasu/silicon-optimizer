import Foundation

/// Turns the paths in a media answer into ids a device can actually fetch.
///
/// Every route that hands back a rendered file goes through here on its way out, rather
/// than each host filling the fields in for itself. One place decides what is servable, one
/// registry mints the ids, and a host that knows nothing about Silicon Buddy — the MCP
/// bridge's, a test's — keeps answering exactly what it always did, with the new fields
/// absent rather than wrong.
///
/// Nothing here fails loudly. A file outside the output roots, a poster that could not be
/// made, a host with no roots at all: each of those is a missing `mediaID`, which is the
/// truthful answer to "can this phone play it?" and the one a client can act on.
struct MediaDecoration: Sendable {

    let registry: MediaRegistry
    let host: any ControlHost
    /// Injected so a test can decorate without an uploads folder appearing under the
    /// tester's own Application Support.
    let uploadsRoot: URL
    let postersRoot: URL

    init(
        registry: MediaRegistry, host: any ControlHost,
        uploadsRoot: URL = BuddyUploads.root, postersRoot: URL = BuddyPosters.root
    ) {
        self.registry = registry
        self.host = host
        self.uploadsRoot = uploadsRoot
        self.postersRoot = postersRoot
    }

    /// Everything a path may live under and still be servable: the app's own output
    /// folders, plus the two the server itself writes into.
    func roots() async -> [String] {
        await host.controlMediaRoots() + [uploadsRoot.path, postersRoot.path]
    }

    /// The relative link a client appends to whatever address it dialled. Never absolute:
    /// this Mac does not know which of its addresses the phone used to get here.
    static func url(for id: String) -> String { "/media/\(id)" }

    func register(_ path: String?, roots: [String]) async -> String? {
        guard let path, !path.isEmpty else { return nil }
        return await registry.register(path: path, within: roots)
    }

    /// The id of a clip's poster frame, making one first if it is not already cached.
    ///
    /// Best-effort by design: a host with no AVFoundation, an audio-only file, a folder
    /// that will not be written — each ends as nil, and a client shows the clip without a
    /// thumbnail rather than being told the render failed.
    func poster(forVideo path: String, roots: [String]) async -> String? {
        guard let destination = BuddyPosters.destination(forVideo: path, at: postersRoot)
        else { return nil }
        if !FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.createDirectory(
                at: postersRoot, withIntermediateDirectories: true
            )
            guard await host.controlMakeVideoPoster(
                from: URL(fileURLWithPath: path), to: destination
            ) else { return nil }
        }
        return await registry.register(path: destination.path, within: roots)
    }

    /// Whether a path is a video, decided the way the rest of this server decides types:
    /// by extension, against the one table of what it serves.
    static func isVideo(_ path: String) -> Bool {
        GatewayAPI.mediaContentTypes[URL(fileURLWithPath: path).pathExtension.lowercased()]?
            .hasPrefix("video/") ?? false
    }

    // MARK: - One per shape

    func decorated(_ view: ControlAPI.VideoQueueView) async -> ControlAPI.VideoQueueView {
        let roots = await roots()
        var copy = view
        for index in copy.items.indices {
            guard let file = copy.items[index].file else { continue }
            guard let id = await register(file, roots: roots) else { continue }
            copy.items[index].mediaID = id
            copy.items[index].mediaURL = Self.url(for: id)
            if Self.isVideo(file) {
                copy.items[index].thumbnailMediaID = await poster(forVideo: file, roots: roots)
            }
        }
        await registry.persist()
        return copy
    }

    func decorated(_ response: ControlAPI.VideoResponse) async -> ControlAPI.VideoResponse {
        let roots = await roots()
        var copy = response
        if let id = await register(copy.file, roots: roots) {
            copy.mediaID = id
            copy.mediaURL = Self.url(for: id)
            if Self.isVideo(copy.file) {
                copy.thumbnailMediaID = await poster(forVideo: copy.file, roots: roots)
            }
        }
        await registry.persist()
        return copy
    }

    func decorated(_ response: ControlAPI.ImageResponse) async -> ControlAPI.ImageResponse {
        let roots = await roots()
        var copy = response
        if let id = await register(copy.path, roots: roots) {
            copy.mediaID = id
            copy.mediaURL = Self.url(for: id)
        }
        await registry.persist()
        return copy
    }

    func decorated(_ response: ControlAPI.MeshResponse) async -> ControlAPI.MeshResponse {
        let roots = await roots()
        var copy = response
        let glb = await register(copy.glbPath, roots: roots)
        let obj = await register(copy.objPath, roots: roots)
        if let primary = glb ?? obj {
            copy.mediaID = primary
            copy.mediaURL = Self.url(for: primary)
        }
        // Only when it is the *other* file: a run that produced an OBJ alone has it as the
        // primary already, and saying it twice would read like two meshes.
        copy.objMediaID = glb == nil ? nil : obj
        await registry.persist()
        return copy
    }

    // MARK: - The other direction

    /// The path a `mediaID` stands for, or nil.
    ///
    /// An `uploadID` is resolved elsewhere, inside the sending device's own folder — the
    /// two ids are deliberately not the same lookup, because one is scoped to a device and
    /// the other is not. There is no third form: a device cannot name a path, and a
    /// request from one that tries is refused by the caller rather than resolved here.
    func path(forID id: String) async -> String? {
        await registry.entry(id: id)?.path
    }
}
