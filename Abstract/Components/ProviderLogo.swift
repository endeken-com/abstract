import SwiftUI
import AbstractCore

/// The agent's own mark, wherever an agent is named.
struct ProviderLogo: View {
    /// Marks drawn in the text colour: single-colour logos.
    private static let templates: Set<String> = ["ProviderOpenAI"]
    let providerId: String
    var size: CGFloat = 16
    /// Tint the mark instead of using its brand colour, for dense lists.
    var monochrome = false

    var body: some View {
        let provider = ProviderRegistry.provider(providerId)
        if let asset = provider?.logoAsset, !asset.isEmpty {
            Image(asset)
                .resizable()
                .renderingMode(Self.templates.contains(asset) || monochrome ? .template : .original)
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(monochrome ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.btText))
                .frame(width: size, height: size)
                .accessibilityLabel(ProviderRegistry.provider(providerId)?.name ?? providerId)
        } else if let url = (provider as? ScriptedProvider)?.iconURL, let image = NSImage(contentsOf: url) {
            // An installed agent's own SVG (ABS-185), drawn in the text colour.
            Image(nsImage: image)
                .resizable()
                .renderingMode(.template)
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(monochrome ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.btText))
                .frame(width: size, height: size)
                .accessibilityLabel(provider?.name ?? providerId)
        } else {
            Image(systemName: "sparkles")
                .font(.system(size: size * 0.8, weight: .regular))
                .frame(width: size, height: size)
                .foregroundStyle(Color.btTextSecondary)
        }
    }
}

/// The agent's mark at avatar size. Just the mark: no tile behind it.
struct ProviderAvatar: View {
    let providerId: String
    var size: CGFloat = 24

    var body: some View {
        ProviderLogo(providerId: providerId, size: size * 0.72)
            .frame(width: size, height: size)
    }
}
