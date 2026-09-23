import Foundation
import SiliconCatalog
import SiliconControl
import SiliconRuntime

/// How one call to `AppModel.loadAsync` ended.
public enum LoadOutcome: Sendable, Equatable {
    /// The model is in memory and serving.
    case loaded
    /// The load failed on its own. The sentence is the one `state` shows.
    case failed(String)
    /// This Mac stopped it before it finished: an unload, or another load.
    case interrupted(InterruptedLoad)
}

/// A load this Mac stopped before it finished, and what stopped it.
///
/// Neither ending is a failure, and until this existed neither said anything at all: an
/// unload part-way through, or a second load started from the Mac's own window, left the
/// load that lost with no ending — and a phone that had asked for it following a load that
/// was no longer happening until its own patience ran out.
public struct InterruptedLoad: Sendable, Equatable {

    public enum Cause: Sendable, Equatable {
        /// An unload: the owner, `POST /unload`, or anything else that frees the model.
        case unload
        /// Another load took the machine.
        case replaced(byID: String, byName: String)
    }

    public var modelID: String
    public var modelName: String
    public var cause: Cause
    public var at: Date

    public init(modelID: String, modelName: String, cause: Cause, at: Date = Date()) {
        self.modelID = modelID
        self.modelName = modelName
        self.cause = cause
        self.at = at
    }

    /// A newer load of the same model took over: the model is still being loaded, by that
    /// load, so this is not an ending anyone is shown.
    public var isReload: Bool {
        guard case .replaced(let otherID, _) = cause else { return false }
        return otherID == modelID
    }

    /// What `POST /load` answers when the load it started was stopped, and the state line
    /// for an unloaded load whose runtime had nothing to say about it.
    public var sentence: String {
        switch cause {
        case .unload:
            "\(modelName) was not loaded: an unload stopped it before it finished loading."
        case .replaced(let otherID, _) where otherID == modelID:
            "\(modelName) is being loaded again, by a newer load with its own settings."
        case .replaced(_, let other):
            "\(modelName) was not loaded: another load (\(other)) replaced it before it "
                + "finished."
        }
    }

    /// The shape a client gets. Reason words are `LoadFailure.Reason`'s, because they name
    /// the same two endings.
    public var wire: ControlAPI.LoadInterruption {
        switch cause {
        case .unload:
            ControlAPI.LoadInterruption(
                modelID: modelID, reason: LoadFailure.Reason.cancelled.rawValue,
                at: ControlAPI.timestamp(at)
            )
        case .replaced(let other, _):
            ControlAPI.LoadInterruption(
                modelID: modelID, reason: LoadFailure.Reason.replaced.rawValue,
                replacedBy: other, at: ControlAPI.timestamp(at)
            )
        }
    }
}

/// One call to `loadAsync`, held by reference so that an unload or a newer load can mark
/// it interrupted while it is still waiting on its runtime.
@MainActor
final class LoadAttempt {
    let model: InstalledModel
    var interruption: InterruptedLoad?

    init(model: InstalledModel) {
        self.model = model
    }
}
