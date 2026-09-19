import Foundation
import SiliconControl
import SiliconRuntime

/// The Mac half of the phone's fallback model: `/ondevice/models` is answered from the
/// app's phone-model service, which fetches the pinned files into `PhoneModels/` and serves
/// them to a paired phone over the tailnet.
///
/// Nothing here touches `settings`, so nothing here can reach the Hugging Face token or the
/// login Keychain behind it: the files are public, and the store that fetches them is built
/// without any credential at all.
extension AppModel {

    public func phoneModelProvider() async -> (any PhoneModelProvider)? {
        PhoneModelSeams.service ?? PhoneModelService.shared
    }
}

/// The one thing the phone-model routes reach that a unit test must not: the app's own
/// `PhoneModels/` folder, and huggingface.co behind it. Task-local, like
/// `AgentSessionSeams`, so a test binds it for exactly the work it runs. Nil — the app's
/// own service — everywhere else.
enum PhoneModelSeams {
    @TaskLocal static var service: PhoneModelService?
}
