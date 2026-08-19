import AppKit
import Foundation
import UserNotifications

/// The system notification that warns a model is about to be released, and the one that says
/// it has been.
///
/// The app lives in the menu bar, so the countdown in its popover only reaches someone who is
/// already looking at it — and the model is being unloaded precisely because nobody is. A
/// notification is what reaches the person who stepped away, and its "Keep it loaded" button
/// is what lets them answer without going back to the Mac's screen and finding the app first.
///
/// Everything here fails quietly. Notification permission is the user's to give, and an app
/// that cannot post one has lost a courtesy, not a feature: the unload still happens, the
/// countdown is still in the popover, and nothing about the model's life depends on this.
enum IdleUnloadNotice {

    static let categoryIdentifier = "idle-unload-warning"
    static let keepLoadedAction = "keep-loaded"
    private static let warningIdentifier = "idle-unload-warning-current"

    /// Whether this process can talk to the notification centre at all.
    ///
    /// `UNUserNotificationCenter.current()` does not fail politely outside a bundled
    /// application: it raises an Objective-C exception, which is not a Swift error and cannot
    /// be caught, so the process dies. A test runner and `swift run` are both that case, and
    /// the app has no business crashing either of them over a courtesy notification.
    static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    /// Registers the "Keep it loaded" button and asks for permission, once, at startup.
    ///
    /// Asked at launch rather than at the moment of the first warning: a permission prompt
    /// arriving five minutes before an unload would be one more thing to read under time
    /// pressure, and answering it would cost the warning it was asked for.
    static func prepare(handler: UNUserNotificationCenterDelegate) {
        guard isAvailable else { return }
        let centre = UNUserNotificationCenter.current()
        centre.delegate = handler
        centre.setNotificationCategories([
            UNNotificationCategory(
                identifier: categoryIdentifier,
                actions: [
                    UNNotificationAction(
                        identifier: keepLoadedAction, title: "Keep it loaded", options: []
                    )
                ],
                intentIdentifiers: []
            )
        ])
        centre.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(modelName: String, minutes: Int) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(modelName) will unload soon"
        content.body = minutes <= 1
            ? "It has been idle, so it is about to be released in under a minute to give the "
                + "memory back. Keep it loaded if you are still using it."
            : "It has been idle, so it is about to be released in about \(minutes) minutes to "
                + "give the memory back. Keep it loaded if you are still using it."
        content.categoryIdentifier = categoryIdentifier
        send(content, identifier: warningIdentifier)
    }

    /// The unload happened. Replaces the warning rather than stacking under it, so the
    /// Notification Centre never shows a countdown that has already run out.
    static func postUnloaded(modelName: String) {
        guard isAvailable else { return }
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: [warningIdentifier])
        let content = UNMutableNotificationContent()
        content.title = "\(modelName) unloaded"
        content.body = "The memory is back. Reload it from the menu bar whenever you need it."
        send(content, identifier: "idle-unload-done")
    }

    /// Takes the warning down when it no longer applies — the model was kept, or unloaded by
    /// hand. A stale "will unload soon" sitting in Notification Centre is worse than none.
    static func withdrawWarning() {
        guard isAvailable else { return }
        let centre = UNUserNotificationCenter.current()
        centre.removeDeliveredNotifications(withIdentifiers: [warningIdentifier])
        centre.removePendingNotificationRequests(withIdentifiers: [warningIdentifier])
    }

    private static func send(_ content: UNMutableNotificationContent, identifier: String) {
        // A nil trigger delivers immediately. Whether the person granted permission is their
        // business, so the completion is ignored rather than treated as an error.
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        )
    }
}

/// Answers the notification's button.
///
/// Its own object because `UNUserNotificationCenterDelegate` is an Objective-C protocol and the
/// app model is a main-actor `@Observable` value; forwarding through a closure keeps that model
/// free of the bridging.
final class IdleUnloadNoticeDelegate: NSObject, UNUserNotificationCenterDelegate {

    private let keepLoaded: @MainActor @Sendable () -> Void

    init(keepLoaded: @escaping @MainActor @Sendable () -> Void) {
        self.keepLoaded = keepLoaded
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let action = response.actionIdentifier
        let keepLoaded = keepLoaded
        // Tapping the notification body counts as answering it too: someone who reaches for it
        // at all is someone still using the model.
        if action == IdleUnloadNotice.keepLoadedAction || action == UNNotificationDefaultActionIdentifier {
            Task { @MainActor in keepLoaded() }
        }
        completionHandler()
    }

    /// Show it even when the app is frontmost. macOS suppresses notifications from the active
    /// app by default, and the Chat window being open is not a reason to hide a warning about
    /// the model that window is talking to.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
