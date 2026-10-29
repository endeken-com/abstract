/// Keeps the chat's reading column inside its viewport, including when a
/// side panel leaves less room than the usual minimum transcript width.
public enum ChatColumnLayout {
    public static func width(viewport: Double, sideInset: Double = 32, maximum: Double = 720) -> Double {
        max(1, min(maximum, viewport - 2 * sideInset))
    }
}
