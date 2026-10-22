import Foundation

/// The requesting button's rectangle in its web view's CSS pixels.
public struct PluginIconAnchor: Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init?(_ value: JSONValue?) {
        guard let x = value?["x"]?.double, let y = value?["y"]?.double,
              let width = value?["width"]?.double, let height = value?["height"]?.double,
              [x, y, width, height].allSatisfy(\.isFinite),
              width > 0, height > 0, width <= 10_000, height <= 10_000 else { return nil }
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}
