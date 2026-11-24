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

    /// Patterns whose first group is kept and the rest masked: a connection
    /// string's scheme (`postgres://[masked]@host`), a `password:`/`senha=`/
    /// `api_key:` key and what separates it from its value (ABS-217).
    private static let keptPrefixPatterns: [NSRegularExpression] = [
        // user:password in a URL or connection string.
        #"(?i)\b([a-z][a-z0-9+.-]*://)[^\s/:@]+:[^\s/@]+(?=@)"#,
        // A secret-sounding key and its value, anywhere in a line: `password: x`,
        // `"api_key": "x"`, `DB_PASSWORD=x`, `--token=x`. A quoted "value" that is
        // itself a key (`the password: "password": "x"`) is passed over for the real one.
        #"(?i)\b([A-Za-z0-9_.-]*(?:password|passwd|senha|secret|token|api[_-]?key|access[_-]?key|private[_-]?key)["']?\s*[:=]\s*)(?:"[^"\n]*"(?!\s*:)|'[^'\n]*'(?!\s*:)|[^\s,;"'\[\]]+)"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    private static let envLine = try! NSRegularExpression(
        pattern: #"(?m)^(\s*(?:export\s+)?[A-Za-z_][A-Za-z0-9_]*=)(\S.*)$"#)
    private static let tokenRun = try! NSRegularExpression(pattern: #"[A-Za-z0-9+/=_-]{32,}"#)

    /// `text` with known secret shapes replaced by `[masked]`.
    public static func mask(_ text: String) -> String {
        mask(text, envLines: true, replacement: replacement)
    }

    /// The same, with the shapes replaced by `replacement` (the chat feed
    /// says `[REDACTED]`).
    public static func mask(_ text: String, replacement: String) -> String {
        mask(text, envLines: true, replacement: replacement)
    }

    /// Known token shapes without treating an argument such as `option=value`
    /// as a whole environment assignment.
    public static func maskTokens(_ text: String) -> String {
        mask(text, envLines: false, replacement: replacement)
    }

    private static func mask(_ text: String, envLines: Bool, replacement: String) -> String {
        var out = text
        let template = NSRegularExpression.escapedTemplate(for: replacement)
        for pattern in patterns {
            out = pattern.stringByReplacingMatches(
                in: out, range: NSRange(out.startIndex..., in: out), withTemplate: template)
        }
        for pattern in keptPrefixPatterns {
            out = pattern.stringByReplacingMatches(
                in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "$1\(template)")
        }
        // An env line's value (FOO_SECRET=…), whatever it holds.
        if envLines {
            out = envLine.stringByReplacingMatches(
                in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "$1\(template)")
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
