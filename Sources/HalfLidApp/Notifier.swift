import Foundation
import HalfLidCore
import UserNotifications

/// Posts the notifications the user asked for in the settings. The notification framework is not touched at all until an
/// event passes the user's choices, or until the settings window asks about the permission, so with notifications off (the
/// default) and the window closed this costs nothing.
///
/// Notifications belong to this app: the permission is asked and checked here, on behalf of the settings window, which is an
/// app of its own with another identity (see `ControlCommand`).
final class Notifier: NSObject, NoticeSink, UNUserNotificationCenterDelegate {
    private let preferences: () -> NotificationPreferences
    private let catalog: () -> Catalog
    private let active: Bool
    private var center: UNUserNotificationCenter?

    /// Called when the user clicks a notification.
    var onActivate: (() -> Void)?

    /// - Parameter active: `false` in tests and in `--print-menu`, so nothing is ever posted from them.
    init(active: Bool, preferences: @escaping () -> NotificationPreferences, catalog: @escaping () -> Catalog) {
        self.active = active
        self.preferences = preferences
        self.catalog = catalog
        super.init()
    }

    /// A bare executable (development, tests) has no bundle, and asking for the notification center would crash.
    private var canNotify: Bool { active && Bundle.main.bundleURL.pathExtension == "app" }

    func post(_ notice: Notice) {
        post(NotificationEvent(notice))
    }

    func post(_ event: NotificationEvent) {
        guard canNotify, NotificationPresenter.isWanted(event, by: preferences()) else { return }
        let text = NotificationPresenter.text(for: event, catalog: catalog())
        show(title: text.title, body: text.body, identifier: NotificationPresenter.identifier(for: event))
    }

    // MARK: permission, for the settings window

    /// What macOS allows, answered on the main thread.
    func accessState(completion: @escaping (NotificationAccessState) -> Void) {
        guard canNotify else {
            completion(.unavailable)
            return
        }
        notificationCenter().getNotificationSettings { settings in
            let state: NotificationAccessState
            switch settings.authorizationStatus {
            case .notDetermined: state = .notDetermined
            case .denied: state = .denied
            case .authorized, .provisional, .ephemeral: state = .allowed
            @unknown default: state = .unknown
            }
            DispatchQueue.main.async { completion(state) }
        }
    }

    /// Shows the system's permission prompt when it has not been answered yet, then reports the permission.
    func requestAccess(completion: @escaping (NotificationAccessState) -> Void) {
        guard canNotify else {
            completion(.unavailable)
            return
        }
        notificationCenter().requestAuthorization(options: [.alert]) { [weak self] _, _ in
            self?.accessState(completion: completion)
        }
    }

    /// A notification that proves the permission works. It does not depend on which events the user chose to hear about.
    func postTest() {
        guard canNotify else { return }
        let text = catalog()
        show(title: text.text("settings.notifications.test.title"), body: text.text("settings.notifications.test.body"), identifier: "halflid.test")
    }

    // MARK: private

    private func show(title: String, body: String, identifier: String) {
        let center = notificationCenter()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        }
    }

    private func notificationCenter() -> UNUserNotificationCenter {
        if let center { return center }
        let created = UNUserNotificationCenter.current()
        created.delegate = self
        center = created
        return created
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Without this, a notification is not shown while the app counts as frontmost.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        DispatchQueue.main.async { self.onActivate?() }
        completionHandler()
    }
}
