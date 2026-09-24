import SwiftUI
import AbstractCore

/// The agent's own mark, wherever an agent is named.
struct ProviderLogo: View {
    /// Marks drawn in the text colour: single-colour logos.
    private static let templates: Set<String> = ["ProviderOpenAI", "ProviderOllama", "ProviderLMStudio"]
    let providerId: String
    var size: CGFloat = 16
    /// Tint the mark instead of using its brand colour, for dense lists.
    var monochrome = false

    var body: some View {
        if let asset = ProviderRegistry.provider(providerId)?.logoAsset {
            Image(asset)
                .resizable()
                .renderingMode(Self.templates.contains(asset) || monochrome ? .template : .original)
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(monochrome ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.btText))
                .frame(width: size, height: size)
                .accessibilityLabel(ProviderRegistry.provider(providerId)?.name ?? providerId)
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

extension ProviderRegistry {
    static func name(_ id: String) -> String { provider(id)?.name ?? id }
}
