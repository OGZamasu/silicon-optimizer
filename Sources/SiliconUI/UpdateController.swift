import Foundation
import Observation
import Sparkle
import SwiftUI

/// Automatic updates, via Sparkle.
///
/// Builds are signed locally rather than notarized, so Gatekeeper cannot vouch for an update.
/// Sparkle can: the appcast feed and every download are signed with an EdDSA key whose public
/// half is compiled into the app, and an update that does not verify is refused. That is the
/// whole reason this is here rather than a "new version available" link.
@MainActor
@Observable
public final class UpdateController {

    public private(set) var canCheckForUpdates = false
    public private(set) var lastCheck: Date?

    private let controller: SPUStandardUpdaterController
    private var observation: NSKeyValueObservation?

    public init() {
        // `startingUpdater: true` begins the scheduled background check. The user-driven check
        // is separate and always available.
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
        )
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) {
            [weak self] updater, _ in
            Task { @MainActor in self?.canCheckForUpdates = updater.canCheckForUpdates }
        }
        lastCheck = controller.updater.lastUpdateCheckDate
    }

    public func checkForUpdates() {
        controller.updater.checkForUpdates()
        lastCheck = Date()
    }

    /// Whether Sparkle is allowed to look on its own. Off means the app never contacts the
    /// update server unless asked.
    public var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    public var currentVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return build == "1" ? short : "\(short) (\(build))"
    }

    /// Nil when the app was built without a feed configured, which is the case for a local
    /// `swift build`. The UI hides the controls rather than offering a check that cannot work.
    public var feedURL: String? {
        Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
    }
}
