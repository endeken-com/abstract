import Foundation

/// Every message a plugin sends, validated before anything acts on it
/// (ABS-84 §4): known type, capability granted, payload within limits, and
/// `openChat` only for a chat in the last snapshot. A bad message is refused
/// and counted; it can never throw into the app.
public struct PluginBridge: Sendable {
    public static let api = 1
    /// One inbound message may not pass this many bytes.
    public static let messageByteLimit = 64 * 1024
    /// More than this in the window is a flood.
    public static let floodCount = 100
    public static let floodWindow: TimeInterval = 10

    public var capabilities: Set<PluginCapability>
    public var knownChatIds: Set<String> = []
    public private(set) var refusalCount = 0
    public private(set) var lastRefusal: String?
    private var recent: [Date] = []

    public init(capabilities: Set<PluginCapability>) {
        self.capabilities = capabilities
    }

    public enum Outcome: Sendable, Equatable {
        /// Answer the plugin's request `id` with this value.
        case reply(id: String?, JSONValue)
        case openChat(id: String?, chatId: String)
        case getSnapshot(id: String?)
        case getUsage(id: String?, view: String, page: PluginPage, chatId: String?)
        case getTurns(id: String?, page: PluginPage, chatId: String?)
        case getTranscript(id: String?, page: PluginPage, chatId: String?)
        case getAutomations(id: String?, page: PluginPage)
        case refused(id: String?, reason: String)
        /// The plugin flooded the bridge; the host tears its view down.
        case flooded
    }

    public mutating func handle(_ data: Data, storage: PluginStorage, now: Date = Date()) -> Outcome {
        if isFlood(now: now) { return .flooded }
        guard data.count <= Self.messageByteLimit,
              let object = try? JSONSerialization.jsonObject(with: data),
              case .object(let message) = JSONValue(any: object) else {
            return refuse(nil, "That message couldn't be read.")
        }
        return handle(message, storage: storage)
    }

    public mutating func handle(_ text: String, storage: PluginStorage, now: Date = Date()) -> Outcome {
        handle(Data(text.utf8), storage: storage, now: now)
    }

    private mutating func handle(_ message: [String: JSONValue], storage: PluginStorage) -> Outcome {
        let id = message["id"]?.string
        guard message["api"]?.int == Self.api else { return refuse(id, "Unsupported bridge version.") }
        guard let type = message["type"]?.string else { return refuse(id, "That message has no type.") }
        let payload = message["payload"]
        switch type {
        case "getSnapshot":
            guard capabilities.contains(.chatsRead) || capabilities.contains(.projectsRead) else {
                return refuse(id, "This plugin hasn't been granted reading your chats or projects.")
            }
            return .getSnapshot(id: id)
        case "openChat":
            guard capabilities.contains(.chatsOpen) else {
                return refuse(id, "This plugin hasn't been granted opening chats.")
            }
            guard let chatId = payload?["chatId"]?.string, knownChatIds.contains(chatId) else {
                return refuse(id, "That chat isn't in the plugin's list.")
            }
            return .openChat(id: id, chatId: chatId)
        case "storage.get":
            guard capabilities.contains(.storageOwn) else {
                return refuse(id, "This plugin hasn't been granted remembering its settings.")
            }
            guard let key = payload?["key"]?.string else { return refuse(id, "That storage request has no key.") }
            let value = (try? storage.value(forKey: key)) ?? nil
            return .reply(id: id, .object(["key": .string(key), "value": value ?? .null]))
        case "storage.set":
            guard capabilities.contains(.storageOwn) else {
                return refuse(id, "This plugin hasn't been granted remembering its settings.")
            }
            guard let key = payload?["key"]?.string else { return refuse(id, "That storage request has no key.") }
            let value = payload?["value"]
            let saved = (try? storage.set(value == .null ? nil : value, forKey: key)) ?? false
            guard saved else { return refuse(id, "That would pass the plugin's storage limit.") }
            return .reply(id: id, .object(["key": .string(key), "saved": .bool(true)]))
        case "getUsage":
            guard capabilities.contains(.usageRead) else {
                return refuse(id, "This plugin hasn't been granted seeing what your chats used and cost.")
            }
            let view = payload?["view"]?.string ?? "chats"
            guard ["chats", "entries", "days"].contains(view) else {
                return refuse(id, "Abstract doesn't know that usage view.")
            }
            return .getUsage(id: id, view: view, page: PluginPage(payload: payload), chatId: payload?["chatId"]?.string)
        case "getTurns":
            guard capabilities.contains(.turnsRead) else {
                return refuse(id, "This plugin hasn't been granted seeing when your agents worked.")
            }
            return .getTurns(id: id, page: PluginPage(payload: payload), chatId: payload?["chatId"]?.string)
        case "getTranscript":
            guard capabilities.contains(.transcriptsRead) else {
                return refuse(id, "This plugin hasn't been granted reading your chats' messages.")
            }
            return .getTranscript(id: id, page: PluginPage(payload: payload), chatId: payload?["chatId"]?.string)
        case "getAutomations":
            guard capabilities.contains(.automationsRead) else {
                return refuse(id, "This plugin hasn't been granted seeing your automations.")
            }
            return .getAutomations(id: id, page: PluginPage(payload: payload))
        case "__error":
            return refuse(id, "The plugin reported an error.")
        default:
            return refuse(id, "Abstract doesn't know that message.")
        }
    }

    private mutating func isFlood(now: Date) -> Bool {
        recent.append(now)
        recent.removeAll { now.timeIntervalSince($0) > Self.floodWindow }
        return recent.count > Self.floodCount
    }

    private mutating func refuse(_ id: String?, _ reason: String) -> Outcome {
        refusalCount += 1
        lastRefusal = reason
        return .refused(id: id, reason: reason)
    }

    /// A host-to-plugin envelope, as JSON text for the web view.
    public static func encode(type: String, id: String? = nil, payload: JSONValue) -> String {
        var object: [String: JSONValue] = ["api": .number(Double(api)), "type": .string(type), "payload": payload]
        if let id { object["id"] = .string(id) }
        return JSONValue.object(object).compact()
    }
}
