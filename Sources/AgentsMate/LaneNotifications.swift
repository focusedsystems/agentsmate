import AppKit
import UserNotifications

/// Tells the person when a lane wants them while they are looking elsewhere:
/// a macOS notification (clicking it shows the lane), and a Dock badge with
/// the number of lanes waiting. Only for an app that turns it on; it asks
/// for permission the first time it is needed.
@MainActor
final class LaneNotifier: NSObject, UNUserNotificationCenterDelegate {
    weak var store: AgentLaneStore?
    private var authorized: Bool?

    /// UserNotifications needs a real app bundle; a test runner has none.
    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    init(store: AgentLaneStore) {
        self.store = store
        super.init()
        guard Self.isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        // An app with its own notification delegate keeps it and forwards
        // AgentsMate's responses through AgentLaneStore.handleNotification(_:).
        if center.delegate == nil { center.delegate = self }
    }

    func post(for session: AgentLaneSession) {
        guard Self.isAvailable else { return }
        let title = session.title
        let body = session.record?.message ?? session.status.title
        let id = session.id
        let send: @Sendable () -> Void = {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.threadIdentifier = "agentsmate.lane"
            content.userInfo = ["agentsmate.lane": id]
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "agentsmate.\(id)", content: content, trigger: nil))
        }
        if authorized == true { send(); return }
        if authorized == false { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            if granted { send() }
            Task { @MainActor [weak self] in self?.authorized = granted }
        }
    }

    func clear(_ id: AgentLane.ID) {
        guard Self.isAvailable else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["agentsmate.\(id)"])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["agentsmate.lane"] as? String
        completionHandler()
        guard let id else { return }
        Task { @MainActor in self.store?.showFromNotification(id) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }
}
