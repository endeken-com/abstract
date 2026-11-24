import Foundation

/// Settings › Devices › Chat feed (ABS-217), kept in the store. The token
/// is not here: it lives in the Keychain.
public struct ChatFeedSettings: Sendable, Hashable, Codable {
    public static let storeKey = "chatFeed"
    public static let defaultPort: UInt16 = 4319

    /// Off until you turn it on.
    public var enabled = false
    /// On 127.0.0.1 only, whatever the port.
    public var port: UInt16 = defaultPort
    public var filter = ChatFeedFilter()
    /// Exact `Origin` values allowed; requests with any other Origin are refused.
    public var allowedOrigins: [String] = []

    public init() {}

    public var endpointURL: String { "http://127.0.0.1:\(port)\(ChatFeedEndpoint.path)" }

    /// One origin per line or comma, as typed: trimmed, without a trailing
    /// slash, empty ones dropped, each once.
    public static func origins(typed text: String) -> [String] {
        var seen: Set<String> = []
        return text.split(whereSeparator: { $0 == "\n" || $0 == "," }).compactMap { part in
            var origin = part.trimmingCharacters(in: .whitespaces)
            while origin.hasSuffix("/") { origin.removeLast() }
            guard !origin.isEmpty, seen.insert(origin).inserted else { return nil }
            return origin
        }
    }
}
