import Darwin
import Foundation

/// Putting `abstract` on the PATH: a symlink to the copy inside the app, so
/// the app's updates update it too. Only ever makes, changes or removes a
/// link; anything else at that path is left alone.
public enum CommandLineInstall {
    public static let defaultLink = "/usr/local/bin/abstract"

    public enum Status: Equatable, Sendable {
        case notInstalled
        /// A link to this app's copy.
        case installed
        /// A link to another copy (an Abstract since moved or renamed): relinking fixes it.
        case linkedElsewhere(String)
        /// Something that isn't a link is there.
        case blocked
    }

    public static func status(link: String = defaultLink, tool: String) -> Status {
        var info = stat()
        guard lstat(link, &info) == 0 else { return .notInstalled }
        guard info.st_mode & S_IFMT == S_IFLNK, let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link) else {
            return .blocked
        }
        let absolute = target.hasPrefix("/") ? target : ((link as NSString).deletingLastPathComponent as NSString).appendingPathComponent(target)
        return canonical(absolute) == canonical(tool) ? .installed : .linkedElsewhere(absolute)
    }

    /// Makes (or remakes) the link as this user. False when that isn't
    /// allowed (the folder needs an administrator) or something else is there.
    public static func install(link: String = defaultLink, tool: String) -> Bool {
        guard status(link: link, tool: tool) != .blocked else { return false }
        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: (link as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            if status(link: link, tool: tool) != .notInstalled { try fm.removeItem(atPath: link) }
            try fm.createSymbolicLink(atPath: link, withDestinationPath: tool)
            return true
        } catch {
            return false
        }
    }

    /// Removes the link as this user; false when it isn't a link or that isn't allowed.
    public static func uninstall(link: String = defaultLink) -> Bool {
        var info = stat()
        guard lstat(link, &info) == 0, info.st_mode & S_IFMT == S_IFLNK else { return false }
        return unlink(link) == 0
    }

    /// `install` as a shell command, to run as an administrator.
    public static func installCommand(link: String = defaultLink, tool: String) -> String {
        "mkdir -p \(quoted((link as NSString).deletingLastPathComponent)) && ln -sfn \(quoted(tool)) \(quoted(link))"
    }

    /// `uninstall` as a shell command, to run as an administrator; only removes a link.
    public static func uninstallCommand(link: String = defaultLink) -> String {
        "[ -L \(quoted(link)) ] && rm -f \(quoted(link))"
    }

    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}
