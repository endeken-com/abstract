import Foundation
import UniformTypeIdentifiers

/// ABEL acting on other Mac apps (ABS-205): which kinds of control are on,
/// and for each app whether ABEL may act (Allowed), must ask first, or
/// mustn't touch it (Off). Kept in Settings › ABEL › Other apps.
public struct AbelAppControl: Codable, Sendable, Equatable {
    /// The ways ABEL acts on another app, each with its own macOS permission.
    public enum Kind: String, Codable, Sendable, CaseIterable, Comparable {
        /// Open apps, files and links: no permission.
        case open
        /// Run your Shortcuts: no permission for ABEL; a shortcut may ask for its own.
        case shortcuts
        /// AppleScript: Automation, asked by macOS per app.
        case appleScript
        /// Read, press and type in an app's window: Accessibility.
        case accessibility

        public var title: String {
            switch self {
            case .open: "Open apps, files and links"
            case .shortcuts: "Run your shortcuts"
            case .appleScript: "Control apps with AppleScript"
            case .accessibility: "Read, press and type in apps"
            }
        }

        public var detail: String {
            switch self {
            case .open: "Needs no permission."
            case .shortcuts: "Runs shortcuts from your Shortcuts library; a shortcut may ask for its own permissions."
            case .appleScript: "macOS asks before ABEL first controls each app."
            case .accessibility: "Needs Accessibility for ABEL in System Settings › Privacy & Security."
            }
        }

        public static func < (a: Self, b: Self) -> Bool { allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)! }
    }

    public enum Mode: String, Codable, Sendable, CaseIterable {
        case allowed, askFirst, off

        public var title: String {
            switch self {
            case .allowed: "Allowed"
            case .askFirst: "Ask first"
            case .off: "Off"
            }
        }
    }

    /// The kinds turned on. Each is off until you turn it on.
    public var kinds: Set<Kind>
    /// Each app's mode, by bundle id; an app not listed is Ask first.
    public var apps: [String: Mode]
    /// The names apps were listed under, by bundle id, for Settings.
    public var names: [String: String]

    public init(kinds: Set<Kind> = [], apps: [String: Mode] = [:], names: [String: String] = [:]) {
        self.kinds = kinds; self.apps = apps; self.names = names
    }

    public func mode(for bundleId: String?) -> Mode {
        bundleId.flatMap { apps[$0] } ?? .askFirst
    }
}

/// What ABEL may do to another app, decided before it does anything.
public enum AbelAppPolicy {
    public enum Decision: Sendable, Equatable {
        case allowed
        /// Read back first, and done only on "yes".
        case askFirst
        /// Not done; ABEL says why.
        case refused(String)
    }

    /// Words that send, buy, delete or post: an action with one of these
    /// needs "yes" even in an Allowed app.
    static let consequential: [String] = [
        "send", "sent", "buy", "purchase", "pay", "order", "checkout", "delete", "remove", "trash", "erase", "empty",
        "post", "publish", "tweet", "reply", "submit", "transfer", "share", "invite", "sign", "approve", "merge", "push",
        "enviar", "envia", "comprar", "pagar", "apagar", "excluir", "deletar", "publicar", "postar", "responder",
        "transferir", "compartilhar",
    ]

    /// Whether `text` (a script, a button's title, what's typed) sends,
    /// buys, deletes or posts.
    public static func isConsequential(_ text: String) -> Bool {
        let words = Set(AbelText.words(text))
        return consequential.contains { words.contains($0) }
    }

    /// The matrix: kind on or off, then the app's mode, then whether the
    /// action itself is consequential. Opening is never consequential.
    /// `byAgent`: ABEL's chat asked, not you. Its opening is Ask first too.
    public static func decide(_ kind: AbelAppControl.Kind, app bundleId: String?, appName: String?,
                              action: String, settings: AbelAppControl, language: String = "en-US",
                              byAgent: Bool = false) -> Decision {
        let pt = language.lowercased().hasPrefix("pt")
        guard settings.kinds.contains(kind) else {
            return .refused(pt ? "\(kind.title) está desligado. Ligue em Ajustes › ABEL › Outros apps."
                : "\(kind.title) is off. Turn it on in Settings › ABEL › Other apps.")
        }
        let name = appName ?? bundleId ?? (pt ? "esse app" : "that app")
        switch settings.mode(for: bundleId) {
        case .off:
            return .refused(pt ? "\(name) está desligado para o ABEL em Ajustes › ABEL › Outros apps."
                : "\(name) is set to Off for ABEL in Settings › ABEL › Other apps.")
        case .askFirst:
            // Opening an app you named yourself isn't controlling it; ABEL's
            // chat opening one still asks.
            return kind == .open && !byAgent ? .allowed : .askFirst
        case .allowed:
            return kind != .open && isConsequential(action) ? .askFirst : .allowed
        }
    }
}

/// An app on this Mac, as ABEL can name and open it.
public struct AbelAppInfo: Codable, Sendable, Equatable {
    public var name: String
    public var bundleId: String?
    public var path: String

    public init(name: String, bundleId: String?, path: String) {
        self.name = name; self.bundleId = bundleId; self.path = path
    }
}

/// What ABEL checks before running an AppleScript or opening a file for
/// its chat (ABS-205). These are a second line: every script is shown on
/// the panel and read back, and runs only on your "yes".
public enum AbelAppChecks {
    /// The most of a script the panel shows whole: lines, characters per
    /// line, and characters in all.
    public static let longestScript = (lines: 14, lineLength: 80, characters: 1_120)

    /// Apps ABEL never scripts: each can run anything, or reach every file.
    static let unscriptable: Set<String> = ["terminal", "iterm", "iterm2", "script editor", "finder", "system events",
                                            "automator", "shortcuts", "shortcuts events", "osascript", "warp", "ghostty",
                                            "alacritty", "kitty", "hyper", "wezterm", "installer", "system settings",
                                            "system preferences", "keychain access", "activity monitor"]

    /// Words a script may not hold, inside its one `tell` block or out.
    static let forbidden = ["do shell script", "do script", "write text", "run script", "load script", "store script",
                            "system events", "system attribute", "osascript", "call method", "current application",
                            "use framework", "use scripting additions", "path to", "do javascript", "open location",
                            "open for access", "close access", "set eof", "posix file", "posix path", "alias ", "file \"",
                            "read ", "write ", "info for", "list folder", "mount volume", "delete", "move ", "duplicate",
                            "quit", "restart", "shut down", "log out", "keystroke", "key code", "beep", "«", "»"]

    /// Why `script` won't be run for `app`; nil when it may be shown and
    /// read back. Allowed: exactly one block, `tell application "‹app›"`
    /// … `end tell` (or one line, `tell application "‹app›" to …`), with
    /// nothing outside it, no comments and no line too long to see.
    public static func scriptProblem(_ script: String, app: String) -> String? {
        let target = AbelText.normalized(app)
        if unscriptable.contains(target) { return "ABEL never scripts \(app): it can reach far beyond itself. Do it yourself." }
        let lines = script.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        if lines.count > longestScript.lines || script.count > longestScript.characters
            || lines.contains(where: { $0.count > longestScript.lineLength }) {
            return "That script is too long to show whole before it runs. Ask for a shorter one."
        }
        if script.contains("¬") || script.contains("--") || script.contains("#") || script.contains("(*") {
            return "ABEL runs AppleScripts without comments or continued lines, so all of it can be read."
        }
        let folded = AbelText.fold(script).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        if let word = forbidden.first(where: { folded.contains($0) }) {
            return "ABEL doesn't run AppleScripts that use “\(word.trimmingCharacters(in: .whitespaces))”."
        }
        let quoted = NSRegularExpression.escapedPattern(for: app)
        let body = lines.filter { !$0.isEmpty }
        guard let first = body.first else { return "There's no script to run." }
        let oneLine = try? NSRegularExpression(pattern: #"^tell (?:application|app) ""# + quoted + #"" to \S"#, options: [.caseInsensitive])
        let opens = try? NSRegularExpression(pattern: #"^tell (?:application|app) ""# + quoted + #""$"#, options: [.caseInsensitive])
        func matches(_ regex: NSRegularExpression?, _ line: String) -> Bool {
            regex?.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
        }
        let tells = body.filter { $0.lowercased().hasPrefix("tell ") || $0.lowercased().contains(" tell ") }.count
        if body.count == 1, matches(oneLine, first) { return nil }
        guard matches(opens, first), body.last?.lowercased() == "end tell", tells == 1,
              !body.dropFirst().dropLast().contains(where: { $0.lowercased().hasPrefix("end tell") }),
              !folded.contains("application \"") || folded.components(separatedBy: "application \"").count == 2,
              !folded.contains("app \"") || folded.components(separatedBy: "app \"").count <= 2 else {
            return "ABEL runs one block, tell application \"\(app)\" … end tell, with nothing outside it."
        }
        return nil
    }

    static let documentTypes: [UTType] = [.plainText, .utf8PlainText, .rtf, .pdf, .image, .audiovisualContent, .audio, .movie,
                                          .spreadsheet, .presentation, .commaSeparatedText, .json, .xml, .html, .log,
                                          UTType("org.openxmlformats.wordprocessingml.document"), UTType("com.microsoft.word.doc"),
                                          UTType("com.apple.iwork.pages.sffpages"), UTType("net.daringfireball.markdown")]
        .compactMap { $0 }

    /// The file or folder `path` names in `home`, when ABEL may open it: a
    /// plain path (no `.` or `..`, no link on the way) to a folder or a
    /// document, never a program, bundle or installer. Otherwise why not.
    public static func openable(_ path: String, home: String) -> (url: URL?, problem: String?) {
        let expanded = (path as NSString).expandingTildeInPath
        let parts = expanded.split(separator: "/")
        guard !parts.contains(where: { $0 == "." || $0 == ".." }) else { return (nil, "Say the path without dots in it.") }
        let base = URL(fileURLWithPath: home).standardizedFileURL.path
        guard expanded == base || expanded.hasPrefix(base + "/") else { return (nil, "ABEL opens only files and folders in your home folder.") }
        let relative = expanded == base ? "" : String(expanded.dropFirst(base.count + 1))
        if !relative.isEmpty, AbelReadBack.passesThroughLink(relative, below: base) {
            return (nil, "That path goes through a link. Open it yourself.")
        }
        let url = URL(fileURLWithPath: expanded)
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .contentTypeKey, .isExecutableKey]) else {
            return (nil, "There's nothing at \(path).")
        }
        if values.isDirectory == true, values.isPackage != true { return (url, nil) }
        let type = values.contentType
        let program = values.isExecutable == true || values.isPackage == true
            || type.map { $0.conforms(to: .executable) || $0.conforms(to: .bundle) || $0.conforms(to: .package)
                || $0.conforms(to: .application) || $0.conforms(to: .script) || $0.conforms(to: .shellScript) } ?? true
        // Documents only: what's opened to be read, never to be run.
        let document = type.map { type in documentTypes.contains { type.conforms(to: $0) } } ?? false
        guard !program, document else {
            return (nil, "ABEL opens documents and folders, not programs, installers or links.")
        }
        return (url, nil)
    }
}
