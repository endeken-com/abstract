import Foundation

/// The one filter every text the chat feed sends goes through (ABS-217), in
/// this order: fenced code blocks become a marker, then secrets are
/// redacted, then (when on) health data. Nothing leaves the feed unfiltered.
public struct ChatFeedFilter: Sendable, Hashable, Codable {
    public static let redacted = "[REDACTED]"

    /// Fenced code blocks become `[bloco de código: <language>, <n> linhas]`.
    public var hidesCodeBlocks: Bool
    /// Best-effort patient data: CPF, CNS, birth dates, record numbers, names.
    public var redactsHealthData: Bool

    public init(hidesCodeBlocks: Bool = true, redactsHealthData: Bool = false) {
        self.hidesCodeBlocks = hidesCodeBlocks
        self.redactsHealthData = redactsHealthData
    }

    public func apply(_ text: String) -> String {
        var out = hidesCodeBlocks ? Self.replacingCodeBlocks(text) : text
        out = SecretMasking.mask(out, replacement: Self.redacted)
        if redactsHealthData { out = Self.redactingHealthData(out) }
        return out
    }

    // MARK: Code blocks

    /// A fence: three or more backticks or tildes, indented at most three
    /// spaces, with an optional language after it.
    private static let fence = try! NSRegularExpression(pattern: #"^ {0,3}(`{3,}|~{3,})\s*([^\s`]*)"#)

    /// Each fenced block, fences and all, as one marker line. A block left
    /// open runs to the end of the text, so an unclosed fence hides the rest.
    static func replacingCodeBlocks(_ text: String) -> String {
        var out: [String] = []
        var open: (marker: Character, length: Int, language: String, lines: Int)?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(line)
            let match = fence.firstMatch(in: s, range: NSRange(s.startIndex..., in: s))
            if var block = open {
                if let match, let r = Range(match.range(at: 1), in: s), s[r].first == block.marker, s[r].count >= block.length,
                   s[r.upperBound...].trimmingCharacters(in: .whitespaces).isEmpty {
                    out.append(marker(block.language, block.lines))
                    open = nil
                } else {
                    block.lines += 1
                    open = block
                }
                continue
            }
            if let match, let r = Range(match.range(at: 1), in: s), let lang = Range(match.range(at: 2), in: s) {
                open = (s[r].first!, s[r].count, String(s[lang]), 0)
            } else {
                out.append(s)
            }
        }
        if let block = open { out.append(marker(block.language, block.lines)) }
        return out.joined(separator: "\n")
    }

    private static func marker(_ language: String, _ lines: Int) -> String {
        let lang = language.isEmpty ? "texto" : language.filter { $0.isLetter || $0.isNumber || "+#-_.".contains($0) }
        return "[bloco de código: \(lang.isEmpty ? "texto" : lang), \(lines) \(lines == 1 ? "linha" : "linhas")]"
    }

    // MARK: Health data

    /// Whole matches redacted.
    private static let healthWhole: [NSRegularExpression] = [
        // CPF: 000.000.000-00 or 11 digits.
        #"\b\d{3}\.\d{3}\.\d{3}-\d{2}\b"#,
        #"\b\d{11}\b"#,
        // CNS: 15 digits starting 1, 2, 7, 8 or 9, often in groups.
        #"\b[1-2789]\d{2}[ .]?\d{4}[ .]?\d{4}[ .]?\d{4}\b"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    /// The label (group 1) kept, what follows it redacted.
    private static let healthLabelled: [NSRegularExpression] = [
        // A date beside "nascimento", "DN" or "DOB".
        #"(?i)(\b(?:data de nascimento|nascimento|nascid[oa] em|nasc\.|DN|DOB|date of birth)\b\.?\s*(?:[:\-=]|em)?\s*)(?:\d{1,2}[/.\-]\d{1,2}[/.\-]\d{2,4}|\d{4}-\d{2}-\d{2})"#,
        // A number beside "prontuário", "MRN" or "registro".
        #"(?i)(\b(?:prontu[aá]rio|MRN|registro)\b\.?\s*(?:n[º°o]\.?\s*)?[:#\-=]?\s*)(?=[A-Za-z0-9.\-/]*\d)[A-Za-z0-9](?:[A-Za-z0-9.\-/]*[A-Za-z0-9])?"#,
        // A name after "paciente", "pac.", "Sr." or "Sra.": capitalised words, with "da", "de", "dos" between.
        #"((?:\b[Pp]aciente|\b[Pp]ac\.|\bSra?\.)\s*:?\s+)\p{Lu}[\p{L}'’\-]+(?:\s+(?:d[aeo]s?\s+)?\p{Lu}[\p{L}'’\-]+){0,5}"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    static func redactingHealthData(_ text: String) -> String {
        var out = text
        for pattern in healthLabelled {
            out = pattern.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "$1\(redacted)")
        }
        for pattern in healthWhole {
            out = pattern.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: redacted)
        }
        return out
    }
}
