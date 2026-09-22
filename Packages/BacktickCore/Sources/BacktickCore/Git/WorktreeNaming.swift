import CryptoKit
import Foundation

/// Where session worktrees live and what their branches are called.
public enum WorktreeNaming {
    /// Tokens: `{home} {repo} {hash} {slug} {branch} {prefix}`.
    public static let defaultTemplate = "{home}/.backtick/worktrees/{repo}-{hash}/{slug}"
    public static let defaultBranchPrefix = "backtick/"

    /// Lowercase ASCII letters and digits joined by single dashes, at most 40
    /// characters, never empty ("session" when nothing usable is left).
    public static func slugify(_ input: String) -> String {
        var out: [UInt8] = []
        var lastDash = true
        for scalar in input.unicodeScalars {
            if scalar.isASCII, let byte = UInt8(exactly: scalar.value), isAlphanumeric(byte) {
                out.append(lowercased(byte))
                lastDash = false
            } else if !lastDash && out.count < 40 {
                out.append(UInt8(ascii: "-"))
                lastDash = true
            }
            if out.count >= 40 { break }
        }
        while out.first == UInt8(ascii: "-") { out.removeFirst() }
        while out.last == UInt8(ascii: "-") { out.removeLast() }
        return out.isEmpty ? "session" : String(decoding: out, as: UTF8.self)
    }

    /// First 8 hex characters of the SHA-256 of `input`. Keeps worktree
    /// directories of same-named repositories apart.
    public static func shortHash(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).prefix(4).map { byte in
            let hex = String(byte, radix: 16)
            return hex.count == 1 ? "0" + hex : hex
        }.joined()
    }

    /// Expand every token in a path or branch template.
    public static func render(
        template: String, home: String, repo: String, hash: String, slug: String, branch: String, prefix: String
    ) -> String {
        template
            .replacingOccurrences(of: "{home}", with: home)
            .replacingOccurrences(of: "{repo}", with: repo)
            .replacingOccurrences(of: "{hash}", with: hash)
            .replacingOccurrences(of: "{slug}", with: slug)
            .replacingOccurrences(of: "{branch}", with: branch)
            .replacingOccurrences(of: "{prefix}", with: prefix)
    }

    private static func isAlphanumeric(_ b: UInt8) -> Bool {
        (0x30...0x39).contains(b) || (0x41...0x5A).contains(b) || (0x61...0x7A).contains(b)
    }

    private static func lowercased(_ b: UInt8) -> UInt8 {
        (0x41...0x5A).contains(b) ? b + 0x20 : b
    }
}
