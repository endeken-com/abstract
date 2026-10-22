import Foundation

/// The saved choice for an icon. Nil fields mean that its owner supplies the default.
public struct IconValue: Sendable, Hashable, Codable {
    public var symbol: String?
    public var color: String?
    /// A managed path on the host. Remote and plugin payloads must omit this field.
    public var imagePath: String?

    public init(symbol: String? = nil, color: String? = nil, imagePath: String? = nil) {
        self.symbol = symbol
        self.color = color
        self.imagePath = imagePath
    }

    public var isDefault: Bool { symbol == nil && color == nil && imagePath == nil }
}
