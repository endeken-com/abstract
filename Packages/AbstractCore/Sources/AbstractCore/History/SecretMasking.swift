import Foundation

/// Known secret shapes in text Abstract keeps or hands to an agent (your
/// request, a correction, a summary, a review comment), masked. Anything
/// that plausibly is a credential is masked rather than passed through:
/// this is the last line between a secret pasted into a prompt and every
/// later chat in the project.
public enum SecretMasking {
    public static let replacement = "[masked]"

    private static let patterns: [NSRegularExpression] = [
        // A private key block, whole.
        #"(?s)-----BEGIN [^-]*PRIVATE KEY-----.*?-----END [^-]*PRIVATE KEY-----"#,
        // Provider keys: sk-…, sk-ant-…, sk-proj-…, and their kin.
        #"\bsk-[A-Za-z0-9_-]{10,}"#,
        // GitHub tokens, old and fine-grained.
        #"\bgh[pousr]_[A-Za-z0-9]{20,}"#,
        #"\bgithub_pat_[A-Za-z0-9_]{20,}"#,
        // AWS access key ids.
        #"\bAKIA[0-9A-Z]{16}\b"#,
        // Slack tokens.
        #"\bxox[baprs]-[A-Za-z0-9-]{10,}"#,
        // Google API keys.
        #"\bAIza[A-Za-z0-9_-]{20,}"#,
        // JWTs.
        #"\beyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#,
        // Bearer credentials.
        #"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{16,}"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    private static let envLine = try! NSRegularExpression(
        pattern: #"(?m)^(\s*(?:export\s+)?[A-Za-z_][A-Za-z0-9_]*=)(\S.*)$"#)
    private static let tokenRun = try! NSRegularExpression(pattern: #"[A-Za-z0-9+/=_-]{32,}"#)

    /// `text` with known secret shapes replaced by `[masked]`.
    public static func mask(_ text: String) -> String {
        mask(text, envLines: true)
    }

    /// Known token shapes without treating an argument such as `option=value`
    /// as a whole environment assignment.
    public static func maskTokens(_ text: String) -> String {
        mask(text, envLines: false)
    }

    private static func mask(_ text: String, envLines: Bool) -> String {
        var out = text
        for pattern in patterns {
            out = pattern.stringByReplacingMatches(
                in: out, range: NSRange(out.startIndex..., in: out), withTemplate: replacement)
        }
        // An env line's value (FOO_SECRET=…), whatever it holds.
        if envLines {
            out = envLine.stringByReplacingMatches(
                in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "$1\(replacement)")
        }
        // Long mixed tokens that read as keys, not words or hashes.
        var result = ""
        var cursor = out.startIndex
        for match in tokenRun.matches(in: out, range: NSRange(out.startIndex..., in: out)) {
            guard let range = Range(match.range, in: out) else { continue }
            result += out[cursor..<range.lowerBound]
            result += looksSecret(String(out[range])) ? replacement : String(out[range])
            cursor = range.upperBound
        }
        result += out[cursor...]
        return result
    }

    public static func mask(_ text: String?) -> String? { text.map(mask) }

    /// A long token is treated as a secret when it mixes cases with digits
    /// (base64-ish keys). A pure hex run is a hash — a commit sha, say —
    /// and a single-case run is a word or identifier; both pass. So does
    /// anything path- or URL-shaped (slashes, no base64 `+`/`=` marks):
    /// links and file paths in a summary stay readable.
    static func looksSecret(_ token: String) -> Bool {
        if token.allSatisfy(\.isHexDigit) { return false }
        if token.contains("/"), !token.contains("+"), !token.contains("=") { return false }
        let upper = token.contains(where: \.isUppercase)
        let lower = token.contains(where: \.isLowercase)
        let digit = token.contains(where: \.isNumber)
        return upper && lower && digit
    }
}
