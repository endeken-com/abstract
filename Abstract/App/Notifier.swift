import Foundation
import UserNotifications

/// System notifications for chats that finish or need the developer.
/// `nonisolated`: UserNotifications calls its delegate off the main actor.
nonisolated final class Notifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = Notifier()
    private let lock = NSLock()
    private var openHandler: (@MainActor @Sendable (String) -> Void)?

    /// Called on the main actor when the user clicks a notification.
    func onOpenSession(_ handler: @escaping @MainActor @Sendable (String) -> Void) {
        lock.withLock { openHandler = handler }
    }

    private var center: UNUserNotificationCenter? {
        // Notifications need a real app bundle; `swift test` has none.
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func requestAuthorization() {
        guard let center else { return }
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func post(title: String, body: String, sessionId: String) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["sessionId": sessionId]
        content.threadIdentifier = sessionId
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let id = response.notification.request.content.userInfo["sessionId"] as? String, !id.isEmpty else { return }
        let handler = lock.withLock { openHandler }
        guard let handler else { return }
        await MainActor.run { handler(id) }
    }
}
