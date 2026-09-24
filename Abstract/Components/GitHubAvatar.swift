import SwiftUI
import AppKit

/// A GitHub account's picture, round, loaded once per account and kept for
/// the session. Until it arrives (or if it can't), the login's initial.
struct GitHubAvatar: View {
    let login: String
    /// The account's own avatar URL, when GitHub gave one; else its `.png` URL.
    var url: URL? = nil
    var size: CGFloat = 20
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Circle().fill(Color.btHover)
                Text(login.prefix(1).uppercased())
                    .font(BTFont.ui(size * 0.46, .medium))
                    .foregroundStyle(Color.btTextSecondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.btBorder, lineWidth: 0.5))
        .help(login)
        .task(id: login) { image = await AvatarStore.shared.image(login: login, url: url, pixels: Int(size * 2)) }
    }
}

/// Avatars already fetched, by login, so lists and threads don't flicker.
final class AvatarStore {
    static let shared = AvatarStore()
    private var images: [String: NSImage] = [:]
    private var loading: [String: Task<NSImage?, Never>] = [:]

    func image(login: String, url: URL?, pixels: Int) async -> NSImage? {
        // Demo accounts are made up; their names may belong to real people.
        if DemoBootstrap.current != nil { return nil }
        if let image = images[login] { return image }
        if let task = loading[login] { return await task.value }
        guard let source = url.map({ Self.sized($0, pixels) }) ?? URL(string: "https://github.com/\(login).png?size=\(pixels)") else { return nil }
        let task = Task { () -> NSImage? in
            guard let (data, response) = try? await URLSession.shared.data(from: source),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return NSImage(data: data)
        }
        loading[login] = task
        let image = await task.value
        loading[login] = nil
        if let image { images[login] = image }
        return image
    }

    /// GitHub's avatar URLs take `s` for the size.
    private static func sized(_ url: URL, _ pixels: Int) -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        parts.queryItems = (parts.queryItems ?? []).filter { $0.name != "s" } + [URLQueryItem(name: "s", value: String(pixels))]
        return parts.url ?? url
    }
}
