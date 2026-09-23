import Foundation
import SiliconCatalog
import SiliconControl
import SiliconRuntime

/// The Mac half of the phone's fallback model: `/ondevice/models` is answered from the
/// app's phone-model service, which fetches the pinned files into `Phone Models/` inside
/// the model library folder and serves them to a paired phone over the tailnet.
///
/// Where that folder is comes from `settings.resolvedModelLibraryDirectory`, read on every
/// call — reading a path, which never touches the Keychain. Nothing here reads the Hugging
/// Face token either: the files are public, and the store that fetches them is built with
/// no credential at all.
extension AppModel {

    public func phoneModelProvider() async -> (any PhoneModelProvider)? {
        phoneModels
    }

    /// The service, and where this app's settings put the model library right now.
    var phoneModels: PhoneModelsAtLibrary {
        PhoneModelsAtLibrary(service: AppPhoneModels.service) { [weak self] in
            await self?.phoneModelLibrary()
        }
    }

    /// The model library folder as Settings has it now; nil when none is set, which puts
    /// the phone models in the app's support directory.
    func phoneModelLibrary() -> URL? {
        settings.resolvedModelLibraryDirectory
    }
}

/// The app's one phone-model service.
///
/// Its configuration is the app's own and is the thing the tests exercise: a token-free
/// store, the real catalogue, the real room check and drive rule. `PhoneModelSeams` can
/// swap only the network endpoint, the state file and the room check with the free space it
/// reads — never the service — so a test of "the app sends no token" is a test of this.
enum AppPhoneModels {
    static let service = PhoneModelService(
        store: PhoneModelStore(
            stateFile: { PhoneModelSeams.environment?.stateFile ?? PhoneModelStore.defaultStateFile },
            source: { PhoneModelSeams.environment?.huggingFace },
            spaceCheck: { needed, folder in
                if let check = PhoneModelSeams.environment?.spaceCheck {
                    try check(needed, folder)
                } else {
                    try PhoneModelStore.checkRoom(needed: needed, at: folder)
                }
            },
            // The downloader reads free space again as it starts; through here, so a test
            // that swaps the reading swaps that one too.
            volumes: .init(
                missingDrive: { PhoneModelStore.missingDrive(for: $0) },
                availableCapacity: { folder in
                    PhoneModelSeams.environment?.availableCapacity?(folder)
                        ?? PhoneModelStore.availableCapacity(at: folder)
                },
                volumeID: { PhoneModelStore.volumeID(of: $0) }
            )
        ),
        hub: .shared
    )
}

/// What the app's phone-model service reaches that a unit test must not: huggingface.co,
/// the state file in the app's support directory, and this Mac's real free space.
/// Task-local, like `AgentSessionSeams`, so a test binds them for exactly the work it runs —
/// the fetch it starts inherits them. Nil — the app's own behaviour — everywhere else.
enum PhoneModelSeams {
    struct Environment: Sendable {
        var huggingFace: URL?
        var stateFile: URL?
        var spaceCheck: PhoneModelStore.SpaceCheck?
        var availableCapacity: (@Sendable (URL) -> Int64?)? = nil
    }

    @TaskLocal static var environment: Environment?
}
