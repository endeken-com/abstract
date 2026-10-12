import Foundation
import Synchronization

/// Searching what's inside a worktree's files with `git grep`: tracked and
/// new files, not ignored or binary ones. It runs through the chat's
/// executor, so a chat on a paired Mac searches there.
public enum WorktreeSearch {
    public struct Options: Sendable, Hashable {
        public var matchCase: Bool
        public var wholeWord: Bool
        public var regex: Bool

        public init(matchCase: Bool = false, wholeWord: Bool = false, regex: Bool = false) {
            self.matchCase = matchCase; self.wholeWord = wholeWord; self.regex = regex
        }
    }

    /// A line that matched.
    public struct Match: Sendable, Hashable, Identifiable {
        public let path: String
        /// 1-based.
        public let line: Int
        /// Where the first match starts in the whole line, and how long it is,
        /// in UTF-16 units: what the editor selects.
        public let column: Int
        public let length: Int
        /// The line as listed: leading spaces dropped, and a long line cut
        /// down around the first match.
        public let preview: String
        /// Each match in `preview`, in UTF-16 units.
        public let highlights: [Range<Int>]

        public var id: String { "\(path):\(line)" }

        public init(path: String, line: Int, column: Int, length: Int, preview: String, highlights: [Range<Int>]) {
            self.path = path; self.line = line; self.column = column; self.length = length
            self.preview = preview; self.highlights = highlights
        }
    }

    public struct Results: Sendable, Equatable {
        public var matches: [Match]
        /// More lines matched than the limit; only the first ones are here.
        public var truncated: Bool
        /// The time limit stopped the search; what it found by then is here.
        public var timedOut: Bool

        public init(matches: [Match] = [], truncated: Bool = false, timedOut: Bool = false) {
            self.matches = matches; self.truncated = truncated; self.timedOut = timedOut
        }

        /// How many files the matches are in.
        public var fileCount: Int { Set(matches.map(\.path)).count }
    }

    public static let limit = 2_000
    public static let timeout: Duration = .seconds(10)
    /// The longest preview, in characters.
    static let previewLength = 240

    /// `git grep`'s arguments. `isGit` false searches a folder that isn't a
    /// repository (an automation's scratch folder).
    public static func arguments(_ query: String, _ options: Options, isGit: Bool = true) -> [String] {
        var args = ["grep", "-z", "-n", "--column", "-I", "--color=never"]
        args += isGit ? ["--untracked"] : ["--no-index", "--exclude-standard"]
        args.append(options.regex ? "--extended-regexp" : "--fixed-strings")
        if !options.matchCase { args.append("--ignore-case") }
        if options.wholeWord { args.append("--word-regexp") }
        return args + ["-e", query, "--"]
    }

    /// Search `root` for `query`, stopping at `limit` lines, at `timeout`, or
    /// when the calling task is cancelled.
    public static func run(_ exec: any Executor, root: String, query: String, options: Options, isGit: Bool = true,
                           limit: Int = limit, timeout: Duration = timeout) async throws -> Results {
        let parser = Parser(query: query, options: options)
        let search = SearchState(limit: limit, parser: parser)
        let spec = LaunchSpec(command: "git", args: arguments(query, options, isGit: isGit), cwd: root, keepStdinOpen: false)
        let outcome = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SearchState.Outcome, any Error>) in
                search.begin(continuation)
                do {
                    let process = try exec.spawn(spec, onLine: { search.append($0) }, onExit: { search.exited($0) })
                    search.attach(process)
                } catch {
                    search.fail(error)
                    return
                }
                let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { search.stop(.timedOut) }
            }
        } onCancel: {
            search.stop(.cancelled)
        }
        switch outcome.reason {
        case .cancelled?: throw CancellationError()
        case .timedOut?: return Results(matches: outcome.matches, timedOut: true)
        case .full?: return Results(matches: outcome.matches, truncated: true)
        case nil:
            // 1 is git grep's "nothing matched".
            guard outcome.code == 0 || outcome.code == 1 else { throw failure(outcome.stderr, code: outcome.code) }
            return Results(matches: outcome.matches)
        }
    }

    /// git's complaint without its "fatal:" or "error:" prefix: a regex
    /// that doesn't compile, usually.
    static func failure(_ stderr: [String], code: Int32?) -> AbstractError {
        let line = stderr.last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        var text = line.trimmingCharacters(in: .whitespaces)
        for prefix in ["fatal: ", "error: "] where text.hasPrefix(prefix) { text.removeFirst(prefix.count) }
        return text.isEmpty ? .command(code: code ?? -1, stderr: "") : .message(text.prefix(1).uppercased() + text.dropFirst())
    }

    /// Every match in `output` (`git grep -z -n --column`), for tests.
    static func parse(_ output: String, query: String, options: Options) -> [Match] {
        let parser = Parser(query: query, options: options)
        return output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { parser.match(String($0)) }
    }
}

// MARK: - Parsing

extension WorktreeSearch {
    /// Reads `path\0line\0column\0text` and finds where the query matched in
    /// the text, to highlight it.
    struct Parser: Sendable {
        let pattern: NSRegularExpression?

        init(query: String, options: Options) {
            var source = options.regex ? query : NSRegularExpression.escapedPattern(for: query)
            // git's words: letters, digits and underscores.
            if options.wholeWord { source = "(?<![\\p{L}\\p{N}_])(?:\(source))(?![\\p{L}\\p{N}_])" }
            pattern = try? NSRegularExpression(pattern: source, options: options.matchCase ? [] : [.caseInsensitive])
        }

        func match(_ record: String) -> Match? {
            let fields = record.split(separator: "\0", maxSplits: 3, omittingEmptySubsequences: false)
            guard fields.count == 4, !fields[0].isEmpty, let line = Int(fields[1]), let byteColumn = Int(fields[2]) else { return nil }
            let text = String(fields[3])
            let whole = text as NSString
            var found = pattern?.matches(in: text, range: NSRange(location: 0, length: whole.length))
                .map(\.range).filter { $0.length > 0 } ?? []
            if found.isEmpty {
                // A regex ICU reads differently from git: the start git gave, unmarked.
                let start = String(decoding: text.utf8.prefix(max(byteColumn - 1, 0)), as: UTF8.self).utf16.count
                found = [NSRange(location: min(start, whole.length), length: 0)]
            }
            let first = found[0]

            // Leading spaces go; a long line keeps a little before the first match.
            let indent = leadingSpace(whole)
            var start = indent
            if first.location - start > WorktreeSearch.previewLength / 2 { start = first.location - 24 }
            let end = min(whole.length, start + WorktreeSearch.previewLength)
            let cut = start < end ? whole.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: end - start))
                : NSRange(location: start, length: 0)
            let lead = cut.location > indent ? "…" : ""
            let tail = NSMaxRange(cut) < whole.length ? "…" : ""
            let preview = lead + whole.substring(with: cut) + tail
            let shift = (lead as NSString).length - cut.location
            let highlights = found.compactMap { range -> Range<Int>? in
                let lower = max(range.location, cut.location), upper = min(NSMaxRange(range), NSMaxRange(cut))
                return lower < upper ? (lower + shift)..<(upper + shift) : nil
            }
            return Match(path: String(fields[0]), line: line, column: first.location, length: first.length,
                         preview: preview, highlights: highlights)
        }

        private func leadingSpace(_ text: NSString) -> Int {
            var count = 0
            while count < text.length, text.character(at: count) == 0x20 || text.character(at: count) == 0x09 { count += 1 }
            return count
        }
    }
}

// MARK: - Running

private final class SearchState: Sendable {
    enum Reason { case full, timedOut, cancelled }

    struct Outcome {
        var matches: [WorktreeSearch.Match] = []
        var stderr: [String] = []
        var code: Int32?
        /// Why it was stopped early, if it was.
        var reason: Reason?
    }

    private struct State {
        var continuation: CheckedContinuation<Outcome, any Error>?
        var process: (any RunningProcess)?
        var outcome = Outcome()
        var finished = false
    }

    private let limit: Int
    private let parser: WorktreeSearch.Parser
    private let state = Mutex(State())

    init(limit: Int, parser: WorktreeSearch.Parser) {
        self.limit = limit
        self.parser = parser
    }

    func begin(_ continuation: CheckedContinuation<Outcome, any Error>) {
        state.withLock { $0.continuation = continuation }
    }

    /// A search stopped before its process started (cancelled at once) stops it now.
    func attach(_ process: any RunningProcess) {
        let stopNow = state.withLock { s -> Bool in
            s.process = process
            return s.outcome.reason != nil && !s.finished
        }
        if stopNow { process.terminate() }
    }

    func append(_ line: OutputLine) {
        guard line.stream == .stdout else {
            state.withLock { s in if s.outcome.stderr.count < 50 { s.outcome.stderr.append(line.line) } }
            return
        }
        let match = parser.match(line.line)
        let full = state.withLock { s -> Bool in
            guard s.outcome.reason == nil, let match else { return false }
            guard s.outcome.matches.count < limit else {
                s.outcome.reason = .full
                return true
            }
            s.outcome.matches.append(match)
            return false
        }
        if full { stop(nil) }
    }

    /// Stop the process for `reason` (nil: the reason is already set). Its
    /// exit then reports what was found.
    func stop(_ reason: Reason?) {
        let process = state.withLock { s -> (any RunningProcess)? in
            guard !s.finished else { return nil }
            if let reason, s.outcome.reason == nil { s.outcome.reason = reason }
            return s.process
        }
        process?.terminate()
    }

    func exited(_ code: Int32?) {
        let done = state.withLock { s -> (CheckedContinuation<Outcome, any Error>, Outcome)? in
            guard let continuation = s.continuation else { return nil }
            s.continuation = nil
            s.process = nil
            s.finished = true
            s.outcome.code = code
            return (continuation, s.outcome)
        }
        if let (continuation, outcome) = done { continuation.resume(returning: outcome) }
    }

    func fail(_ error: any Error) {
        let continuation = state.withLock { s -> CheckedContinuation<Outcome, any Error>? in
            defer { s.continuation = nil; s.finished = true }
            return s.continuation
        }
        continuation?.resume(throwing: error)
    }
}
