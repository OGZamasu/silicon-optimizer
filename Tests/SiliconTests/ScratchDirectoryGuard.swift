import Foundation
import Testing

/// Stops the calling test unless `url` is inside the temporary directory.
///
/// Called before anything is written to, or removed from, a directory the code under test
/// chose: a path that is scratch today only because of a default somewhere else — an
/// injected-settings `AppModel`'s fallback hub, say — must not become a real cache the day
/// that default changes. `~/.cache/huggingface` can be a link into a real model library.
func requireTemporaryDirectory(_ url: URL, sourceLocation: SourceLocation = #_sourceLocation) throws {
    let scratch = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path + "/"
    try #require(
        url.resolvingSymlinksInPath().path.hasPrefix(scratch),
        "\(url.path) is not a scratch directory; refusing to write to or remove it",
        sourceLocation: sourceLocation
    )
}

/// Removes `url` only when it is inside the temporary directory; anything else is recorded
/// as a test failure and left alone. For `defer`, where a throwing guard cannot run.
func removeTemporaryDirectory(_ url: URL, sourceLocation: SourceLocation = #_sourceLocation) {
    let scratch = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path + "/"
    guard url.resolvingSymlinksInPath().path.hasPrefix(scratch) else {
        Issue.record("\(url.path) is not a scratch directory; not removed", sourceLocation: sourceLocation)
        return
    }
    try? FileManager.default.removeItem(at: url)
}
