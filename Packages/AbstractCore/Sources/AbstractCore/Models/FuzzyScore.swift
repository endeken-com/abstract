/// How well typed letters match a name, for pickers that filter as you type.
public enum FuzzyScore {
    /// Subsequence match, rewarding contiguous runs and word starts. 0: no match.
    public static func score(_ text: String, _ query: String) -> Int {
        var score = 0, run = 0
        var ti = text.startIndex
        for qc in query {
            guard let found = text[ti...].firstIndex(of: qc) else { return 0 }
            run = found == ti ? run + 1 : 1
            let wordStart = found == text.startIndex || text[text.index(before: found)] == " "
            score += run * 2 + (wordStart ? 3 : 0)
            ti = text.index(after: found)
        }
        return score
    }
}
