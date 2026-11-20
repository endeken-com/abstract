/// Keeps the chat's reading column inside its viewport, including when a
/// side panel leaves less room than the usual minimum transcript width.
public enum ChatColumnLayout {
    public static func width(viewport: Double, sideInset: Double = 32, maximum: Double = 720) -> Double {
        max(1, min(maximum, viewport - 2 * sideInset))
    }

    /// Narrower than the column ever gets in a laid-out chat (about 215 pt: a
    /// 560 pt chat screen beside the narrowest side panel). A transcript this
    /// narrow isn't sized yet, as when its view is between two chat screens.
    public static let minimumWidth: Double = 120

    /// The width to build a transcript's rows at, or nil while its viewport
    /// has no real width: a row built then would wrap a letter to a line.
    public static func buildWidth(viewport: Double, sideInset: Double = 32, maximum: Double = 720) -> Double? {
        let column = width(viewport: viewport, sideInset: sideInset, maximum: maximum)
        return column >= minimumWidth ? column : nil
    }

    /// Whether a row built `built` wide must be built again for the column:
    /// when the column has a real width (`column`) and it isn't the row's.
    public static func needsRebuild(built: Double, column: Double?) -> Bool {
        column.map { $0 != built } ?? false
    }

    /// A row's height measured `measuredAt` wide, if it holds for the column.
    public static func cachedHeight(_ height: Double, measuredAt: Double, column: Double) -> Double? {
        measuredAt == column ? height : nil
    }
}
