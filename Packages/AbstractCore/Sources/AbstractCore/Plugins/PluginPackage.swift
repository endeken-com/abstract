import CryptoKit
import Foundation

/// A plugin package on disk: a folder with `manifest.json` at its root and
/// static web assets below it. No executable files, no symlinks, no paths
/// escaping the folder (ABS-84 §2).
public enum PluginPackage {
    public static let defaultSizeLimit = 25 * 1024 * 1024

    public struct Inspection: Sendable, Hashable {
        public var manifest: PluginManifest
        /// SHA-256 over the manifest and the file list with each file's hash.
        public var hash: String
        public var fileCount: Int
        public var totalBytes: Int
    }

    /// A relative path that stays inside its folder.
    public static func isContained(relativePath: String) -> Bool {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"), !relativePath.contains("\0") else { return false }
        return !relativePath.split(separator: "/").contains("..")
    }

    /// Reads and validates a package folder without running anything in it.
    public static func inspect(folder: URL, sizeLimit: Int = defaultSizeLimit,
                                 fileManager fm: FileManager = .default) throws -> Inspection {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else {
            throw PluginValidationError.missingPackage
        }
        let manifestURL = folder.appendingPathComponent("manifest.json")
        guard let manifestData = try? Data(contentsOf: manifestURL) else {
            throw PluginValidationError.invalidManifest("no manifest.json")
        }
        let manifest = try PluginManifest.decode(manifestData)
        try manifest.validate()

        let files = try relativeFiles(in: folder, fileManager: fm)
        var total = 0
        var hash = SHA256()
        hash.update(data: manifestData)
        for relative in files.sorted() where relative != "signature.json" {
            let url = folder.appendingPathComponent(relative)
            let data = try Data(contentsOf: url)
            total += data.count
            guard total <= sizeLimit else { throw PluginValidationError.tooLarge }
            hash.update(data: Data(relative.utf8))
            hash.update(data: Data(SHA256.hash(data: data)))
        }
        guard files.contains(manifest.entry) else {
            throw PluginValidationError.missingEntry(manifest.entry)
        }
        if let icon = manifest.contributes.issueTracker?.icon, !files.contains(icon) {
            throw PluginValidationError.missingEntry(icon)
        }
        if let background = manifest.background, !files.contains(background) {
            throw PluginValidationError.missingEntry(background)
        }
        let hex = hash.finalize().map { String(format: "%02x", $0) }.joined()
        return Inspection(manifest: manifest, hash: hex, fileCount: files.count, totalBytes: total)
    }

    /// Every regular file in the package, as a path relative to its root.
    /// Symlinks and executable files are refused, wherever they sit.
    static func relativeFiles(in folder: URL, fileManager fm: FileManager) throws -> [String] {
        let root = folder.standardizedFileURL
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                                         options: []) else { return [] }
        var out: [String] = []
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: Set<URLResourceKey>([.isRegularFileKey, .isSymbolicLinkKey]))
            let relative = String(url.standardizedFileURL.path.dropFirst(root.path.count + 1))
            if values.isSymbolicLink == true { throw PluginValidationError.symlink(relative) }
            guard values.isRegularFile == true else { continue }
            guard isContained(relativePath: relative) else { throw PluginValidationError.escapingPath(relative) }
            let perms = (try? fm.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
            if let perms, perms & 0o111 != 0 {
                throw PluginValidationError.executableFile(relative)
            }
            out.append(relative)
        }
        return out
    }

    /// One package file for the host's scheme handler. Nil for anything
    /// outside the package, missing, or not a regular file.
    public static func fileData(in folder: URL, relativePath: String,
                                fileManager fm: FileManager = .default) -> Data? {
        let clean = relativePath.split(separator: "?").first.map(String.init) ?? relativePath
        let decoded = clean.removingPercentEncoding ?? clean
        guard isContained(relativePath: decoded) else { return nil }
        let url = folder.standardizedFileURL.appendingPathComponent(decoded)
        guard url.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/") else { return nil }
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]).isRegularFile) == true,
              (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return nil }
        return try? Data(contentsOf: url)
    }

    public static func mimeType(forPath path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "html", "htm": "text/html; charset=utf-8"
        case "js", "mjs": "text/javascript; charset=utf-8"
        case "css": "text/css; charset=utf-8"
        case "json": "application/json"
        case "svg": "image/svg+xml"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "woff2": "font/woff2"
        case "woff": "font/woff"
        default: "application/octet-stream"
        }
    }

    /// Unpacks a `.zip` of a package folder into `destination` (macOS's
    /// ditto). The result still goes through `inspect`.
    public static func unzip(_ zip: URL, into destination: URL, fileManager fm: FileManager = .default) throws -> URL {
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, destination.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw PluginValidationError.invalidManifest("the zip couldn't be opened")
        }
        // The manifest is at the zip's root, or one folder down.
        if fm.fileExists(atPath: destination.appendingPathComponent("manifest.json").path) { return destination }
        let children = (try? fm.contentsOfDirectory(at: destination, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for child in children where fm.fileExists(atPath: child.appendingPathComponent("manifest.json").path) {
            return child
        }
        throw PluginValidationError.invalidManifest("no manifest.json in the zip")
    }
}
