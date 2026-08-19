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
///
/// The updater is started by hand rather than by `SPUStandardUpdaterController(startingUpdater:)`
/// for one reason: that convenience throws a modal alert when the updater cannot start, and it
/// throws it again every time it is dismissed. The way to hit that is ordinary — replace the app
/// bundle while a copy is running, which every local install does — and a background app has no
/// business interrupting someone's screen because it could not read its own feed. A failure now
/// lands in `startupError` and is shown as a line in Settings.
@MainActor
@Observable
public final class UpdateController {

    public private(set) var canCheckForUpdates = false
    public private(set) var lastCheck: Date?
    /// Why the updater is not running, when it is not. Shown in Settings; never as an alert.
    public private(set) var startupError: String?
    /// An update found by a scheduled check that has not been presented yet. The app is a
    /// menu-bar app, so a found update waits here as a badge rather than seizing focus.
    public private(set) var pendingUpdateVersion: String?

    private let updater: SPUUpdater
    private let driverDelegate = DriverDelegate()
    private var observation: NSKeyValueObservation?

    public init() {
        let driver = SPUStandardUserDriver(hostBundle: .main, delegate: driverDelegate)
        updater = SPUUpdater(
            hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: nil
        )
        driverDelegate.controller = self

        do {
            try updater.start()
        } catch {
            // Sparkle's own words are the useful ones here — they name the missing key or the
            // bundle it could not read.
            startupError = error.localizedDescription
        }

        observation = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) {
            [weak self] updater, _ in
            Task { @MainActor in self?.canCheckForUpdates = updater.canCheckForUpdates }
        }
        lastCheck = updater.lastUpdateCheckDate
    }

    public func checkForUpdates() {
        updater.checkForUpdates()
        lastCheck = Date()
        pendingUpdateVersion = nil
    }

    /// Whether Sparkle is allowed to look on its own. Off means the app never contacts the
    /// update server unless asked.
    public var automaticallyChecks: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { updater.automaticallyChecksForUpdates = newValue }
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

    fileprivate func noteFoundUpdate(_ version: String?) {
        pendingUpdateVersion = version
    }

    /// Sparkle asks the delegate, not the controller, so this exists to forward. It also has to
    /// be an `NSObject`: the protocol is Objective-C.
    private final class DriverDelegate: NSObject, SPUStandardUserDriverDelegate {
        weak var controller: UpdateController?

        /// Without this, Sparkle logs a warning that a background app which schedules checks but
        /// shows no gentle reminder leaves its users never noticing an update.
        var supportsGentleScheduledUpdateReminders: Bool { true }

        /// A scheduled find is ours to show. The app lives in the menu bar, so an update alert
        /// pushed in front of whatever someone is doing is the wrong shape; Settings gets a row
        /// instead, and pressing it brings Sparkle's own flow up in focus.
        func standardUserDriverShouldHandleShowingScheduledUpdate(
            _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
        ) -> Bool {
            immediateFocus
        }

        func standardUserDriverWillHandleShowingUpdate(
            _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
            state: SPUUserUpdateState
        ) {
            guard !handleShowingUpdate else { return }
            let version = update.displayVersionString
            let controller = controller
            Task { @MainActor in controller?.noteFoundUpdate(version) }
        }

        func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
            let controller = controller
            Task { @MainActor in controller?.noteFoundUpdate(nil) }
        }
    }
}
