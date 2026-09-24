import AppKit
import Security
import UniformTypeIdentifiers
import AbstractCore

/// Files and images attached to messages, copied where agents can read them:
/// one folder per attachment in the app's data folder, so each keeps its
/// name. Claude may read this folder without asking; Codex reads anywhere.
enum AttachmentStore {
    static var root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Abstract/attachments")

    /// Bigger files are left where they are rather than copied.
    static let maxCopy = 50 << 20
    /// Agents take images up to about 5 MB once encoded; bigger ones are scaled down.
    static let maxImage = 3_500_000
    static let maxImageEdge = 2048

    static func importFile(_ url: URL) throws -> PromptAttachment {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentTypeKey])
        let name = url.lastPathComponent
        if values?.isDirectory == true || (values?.fileSize ?? 0) > maxCopy {
            return PromptAttachment(kind: .file, title: name, path: url.path)
        }
        if values?.contentType?.conforms(to: .image) == true, let data = try? Data(contentsOf: url) {
            return try importImage(data, named: name)
        }
        let folder = try newFolder()
        let dest = folder.appendingPathComponent(name)
        try FileManager.default.copyItem(at: url, to: dest)
        return PromptAttachment(kind: .file, title: name, path: dest.path)
    }

    /// An image as agents take it: PNG, JPEG, GIF or WebP, small enough to
    /// send; anything else is redrawn as PNG (or JPEG, when that's smaller).
    static func importImage(_ data: Data, named name: String) throws -> PromptAttachment {
        let folder = try newFolder()
        if ImageMedia.type(ofPath: name) != nil, data.count <= maxImage, let size = pixelSize(data), max(size.width, size.height) <= 8000 {
            let dest = folder.appendingPathComponent(name)
            try data.write(to: dest)
            return PromptAttachment(kind: .image, title: name, path: dest.path)
        }
        guard let image = scaled(data) else {
            // Not an image after all: still worth attaching as a file.
            let dest = folder.appendingPathComponent(name)
            try data.write(to: dest)
            return PromptAttachment(kind: .file, title: name, path: dest.path)
        }
        let base = (name as NSString).deletingPathExtension
        var (encoded, ext) = (encode(image, .png), "png")
        if (encoded?.count ?? .max) > maxImage { (encoded, ext) = (encode(image, .jpeg), "jpg") }
        guard let encoded else { throw AbstractError.message("Couldn't read “\(name)” as an image.") }
        let dest = folder.appendingPathComponent(base + "." + ext)
        try encoded.write(to: dest)
        return PromptAttachment(kind: .image, title: dest.lastPathComponent, path: dest.path)
    }

    /// An image or files on the pasteboard, or nil when it holds text to paste as usual.
    static func importPasteboard(_ pasteboard: NSPasteboard) -> [PromptAttachment]? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return urls.compactMap { try? importFile($0) }
        }
        guard pasteboard.string(forType: .string) == nil,
              let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) else { return nil }
        let stamp = Date().formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
            .replacingOccurrences(of: ":", with: ".")
        return (try? importImage(data, named: "Pasted image \(stamp).png")).map { [$0] } ?? []
    }

    /// A file that came from another Mac, kept here for this Mac's agent.
    static func keep(_ data: Data, for attachment: PromptAttachment) throws -> PromptAttachment {
        let dest = try newFolder().appendingPathComponent((attachment.title as NSString).lastPathComponent)
        try data.write(to: dest)
        var kept = attachment
        kept.path = dest.path
        return kept
    }

    /// Attachments older than a month go; the chats that sent them keep their text.
    static func prune(olderThan days: Int = 30) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for folder in folders where ((try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantFuture) < cutoff {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private static func newFolder() throws -> URL {
        let folder = root.appendingPathComponent(String(UUID().uuidString.prefix(8)).lowercased())
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func pixelSize(_ data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return CGSize(width: w, height: h)
    }

    private static func scaled(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxImageEdge,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func encode(_ image: CGImage, _ type: UTType) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}

/// Secrets in the login keychain.
enum Keychain {
    private static let service = "Abstract"

    static func read(_ account: String) -> String? {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
                                      kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// nil removes it.
    static func write(_ account: String, _ value: String?) {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        SecItemDelete(query as CFDictionary)
        guard let value else { return }
        var item = query
        item[kSecValueData] = Data(value.utf8)
        item[kSecAttrLabel] = "Abstract — \(account)"
        SecItemAdd(item as CFDictionary, nil)
    }
}

/// Your Linear API key, read from the keychain once per launch.
@Observable
final class LinearAccount {
    static let shared = LinearAccount()
    private static let account = "linear-api-key"
    /// Whether a key is kept, so the composer can show Linear without reading the keychain.
    static let connectedKey = "integrations.linear"

    private(set) var key: String?
    /// Whose key it is, once checked.
    private(set) var viewer: String?
    @ObservationIgnored private var loaded = false

    var isConnected: Bool { load(); return key != nil }

    func apiKey() -> String? { load(); return key }

    private func load() {
        guard !loaded else { return }
        loaded = true
        key = Keychain.read(Self.account)
    }

    /// Checks the key with Linear before keeping it.
    func connect(_ key: String) async throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        viewer = try await Linear.viewer(apiKey: key)
        Keychain.write(Self.account, key)
        self.key = key
        loaded = true
        UserDefaults.standard.set(true, forKey: Self.connectedKey)
    }

    func disconnect() {
        Keychain.write(Self.account, nil)
        key = nil
        viewer = nil
        loaded = true
        UserDefaults.standard.set(false, forKey: Self.connectedKey)
    }

    func checkViewer() async {
        guard let key = apiKey(), viewer == nil else { return }
        viewer = try? await Linear.viewer(apiKey: key)
    }
}
