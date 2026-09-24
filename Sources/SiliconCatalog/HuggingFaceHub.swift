import Foundation

/// Where a Hugging Face client keeps its hub cache — the directory the `models--org--name`
/// folders live in.
///
/// One answer for everyone who asks: the installers that download into it, the checks that
/// look in it and the removals that delete from it all have to name the same directory the
/// engine reading the weights will use, or a model is fetched twice, reads as missing, or is
/// removed from a copy nothing reads.
public enum HuggingFaceHub {

    /// `hub` inside `home` when the app sets `HF_HOME` for the child. Otherwise what the child
    /// inherits decides, by `huggingface_hub`'s own precedence: `HF_HUB_CACHE`, then
    /// `HF_HOME/hub`, then `XDG_CACHE_HOME/huggingface/hub`, then `~/.cache/huggingface/hub`.
    public static func directory(
        home: URL?, environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let home { return home.appendingPathComponent("hub", isDirectory: true) }
        if let hub = environment["HF_HUB_CACHE"], !hub.isEmpty {
            return URL(fileURLWithPath: hub, isDirectory: true)
        }
        if let hfHome = environment["HF_HOME"], !hfHome.isEmpty {
            return URL(fileURLWithPath: hfHome, isDirectory: true).appendingPathComponent("hub")
        }
        let cache = environment["XDG_CACHE_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache")
        return cache.appendingPathComponent("huggingface/hub", isDirectory: true)
    }
}
