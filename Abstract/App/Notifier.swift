import Foundation
import UserNotifications

/// System notifications for chats that finish or need the developer.
/// `nonisolated`: UserNotifications calls its delegate off the main actor.
/// What you chose on a stalled chat's notification.
enum StallAction: String, Sendable {
    case keepWaiting, stop, stopAndRetry
}

nonisolated final class Notifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = Notifier()
    private static let stallCategory = "abstract.stalled"
    private let lock = NSLock()
    private var openHandler: (@MainActor @Sendable (String) -> Void)?
    private var stallHandler: (@MainActor @Sendable (String, StallAction) -> Void)?

    /// Called on the main actor when the user clicks a notification.
    func onOpenSession(_ handler: @escaping @MainActor @Sendable (String) -> Void) {
        lock.withLock { openHandler = handler }
    }

    /// Called on the main actor when the user acts on a stalled chat's notification.
    func onStallAction(_ handler: @escaping @MainActor @Sendable (String, StallAction) -> Void) {
        lock.withLock { stallHandler = handler }
    }

    private var center: UNUserNotificationCenter? {
        // Notifications need a real app bundle; `swift test` has none.
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func requestAuthorization() {
        guard let center else { return }
        center.delegate = self
        let stall = UNNotificationCategory(identifier: Self.stallCategory, actions: [
            UNNotificationAction(identifier: StallAction.keepWaiting.rawValue, title: "Keep waiting"),
            UNNotificationAction(identifier: StallAction.stop.rawValue, title: "Stop"),
            UNNotificationAction(identifier: StallAction.stopAndRetry.rawValue, title: "Stop and retry"),
        ], intentIdentifiers: [])
        center.setNotificationCategories([stall])
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func post(title: String, body: String, sessionId: String) {
        post(title: title, body: body, sessionId: sessionId, category: nil)
    }

    /// A chat gone quiet, with Keep waiting, Stop and Stop and retry on it.
    func postStalled(title: String, body: String, sessionId: String) {
        post(title: title, body: body, sessionId: sessionId, category: Self.stallCategory)
    }

    private func post(title: String, body: String, sessionId: String, category: String?) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["sessionId": sessionId]
        content.threadIdentifier = sessionId
        if let category { content.categoryIdentifier = category }
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let id = response.notification.request.content.userInfo["sessionId"] as? String, !id.isEmpty else { return }
        if let action = StallAction(rawValue: response.actionIdentifier) {
            let handler = lock.withLock { stallHandler }
            guard let handler else { return }
            await MainActor.run { handler(id, action) }
            return
        }
        let handler = lock.withLock { openHandler }
        guard let handler else { return }
        await MainActor.run { handler(id) }
    }
}
