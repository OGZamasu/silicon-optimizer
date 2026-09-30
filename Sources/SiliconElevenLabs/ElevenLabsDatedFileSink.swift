import Foundation

/// The app's file sink: every body goes under `<root>/<yyyy-MM-dd>/`, named after the
/// operation, never over an existing file. `onWrite` hears about each finished file — where
/// the app registers it with its media table and its recent-outputs list.
public struct ElevenLabsDatedFileSink: ElevenLabsFileSink {
    public let root: URL
    private let onWrite: @Sendable (URL, String, ElevenLabsOperation) async -> Void
    private let now: @Sendable () -> Date

    public init(
        root: URL, now: @escaping @Sendable () -> Date = { Date() },
        onWrite: @escaping @Sendable (URL, String, ElevenLabsOperation) async -> Void = { _, _, _ in }
    ) {
        self.root = root
        self.now = now
        self.onWrite = onWrite
    }

    /// Today's folder under `root`.
    public func folder(for date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return root.appendingPathComponent(formatter.string(from: date), isDirectory: true)
    }

    public func destination(
        for operation: ElevenLabsOperation, suggestedName: String, contentType: String
    ) throws -> URL {
        let folder = folder(for: now())
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return ElevenLabsFileNames.unique(suggestedName, in: folder)
    }

    public func didWrite(_ file: URL, contentType: String, operation: ElevenLabsOperation) async {
        await onWrite(file, contentType, operation)
    }
}
