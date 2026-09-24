import Foundation
import notify

/// Tells a running app that another process (`abstract`) changed the store
/// or a chat's lock, so it reloads rather than show stale chats. Darwin
/// notifications carry no data and cost nothing when nobody listens.
public enum StoreChanges {
    /// One name per data folder, so a demo or a test never wakes the real app.
    public static func name(storePath: String = Store.defaultPath()) -> String {
        "sh.abstract.store-changed." + WorktreeNaming.shortHash(storePath)
    }

    public static func post(storePath: String = Store.defaultPath()) {
        notify_post(name(storePath: storePath))
    }

    /// Calls `handler` on `queue` after every post. Returns a token for `stop`, or nil.
    public static func observe(storePath: String = Store.defaultPath(), queue: DispatchQueue = .main,
                               _ handler: @escaping @Sendable () -> Void) -> Int32? {
        var token: Int32 = 0
        let status = notify_register_dispatch(name(storePath: storePath), &token, queue) { _ in handler() }
        return status == NOTIFY_STATUS_OK ? token : nil
    }

    public static func stop(_ token: Int32) {
        notify_cancel(token)
    }
}
