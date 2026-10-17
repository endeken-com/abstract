import Foundation

/// A plugin's own saved settings: one JSON file per plugin, written only
/// through the bridge, capped at 512 KB in total (ABS-84 §4–§5).
public struct PluginStorage: Sendable {
    public static let byteLimit = 512 * 1024

    public var fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    public init(directory: URL, pluginId: String) {
        self.init(fileURL: directory.appendingPathComponent("\(pluginId).json"))
    }

    public func values() throws -> [String: JSONValue] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: JSONValue].self, from: data) else {
            throw PluginValidationError.corruptStorage
        }
        return decoded
    }

    public func value(forKey key: String) throws -> JSONValue? {
        try values()[key]
    }

    /// A nil value removes the key. Refused (false) when the result would
    /// pass the size limit.
    @discardableResult
    public func set(_ value: JSONValue?, forKey key: String) throws -> Bool {
        var all = try values()
        if let value { all[key] = value } else { all.removeValue(forKey: key) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(all)
        guard data.count <= Self.byteLimit else { return false }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: [.atomic])
        return true
    }

    public func removeAll() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
