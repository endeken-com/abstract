import Foundation
import Synchronization

/// Codex says which files a patch touched but not how (codex-cli 0.153.4:
/// `changes: [{path, kind}]`). Once a patch is applied this reads each file
/// and writes a unified `diff` into its change before the line is logged, so
/// the edit shows its counts and lines like Claude's do.
///
/// Each edit is diffed against the file as the chat's previous edit left it,
/// or as committed at HEAD the first time, so an edit shows only its own
/// change. After the app restarts, a file's first edit diffs against HEAD again.
final class CodexEditDiffs: LineEnricher {
    private let executor: any Executor
    private let cwd: String
    /// Each file as the chat's latest edit left it, by absolute path.
    private let snapshots = Mutex<[String: String]>([:])

    init(executor: any Executor, cwd: String) {
        self.executor = executor
        self.cwd = cwd
    }

    func enrich(_ line: OutputLine) -> OutputLine {
        guard line.stream == .stdout, line.line.contains("file_change") || line.line.contains("patch_apply"),
              let obj = try? JSONDecoder().decode(JSONValue.self, from: Data(line.line.utf8)), var top = obj.object,
              top["type"]?.string == "item.completed", var item = top["item"]?.object,
              item["type"]?.string == "file_change" || item["type"]?.string == "patch_apply",
              let changes = item["changes"]?.array
        else { return line }
        var filled = false
        let enriched = changes.map { change -> JSONValue in
            guard var c = change.object, c["diff"] == nil, let path = c["path"]?.string else { return change }
            let full = path.hasPrefix("/") ? path : (cwd.hasSuffix("/") ? cwd : cwd + "/") + path
            let kind = c["kind"]?.string
            let after = kind == "delete" ? "" : (try? executor.readFile(full)) ?? ""
            let before = snapshots.withLock { $0[full] } ?? (kind == "add" ? "" : committed(full))
            snapshots.withLock { $0[full] = after }
            c["diff"] = .string(EditPreview.unifiedDiff(before, after))
            filled = true
            return .object(c)
        }
        guard filled else { return line }
        item["changes"] = .array(enriched)
        top["item"] = .object(item)
        return OutputLine(stream: line.stream, line: JSONValue.object(top).compact())
    }

    /// The file as committed at HEAD; empty when it wasn't. Lines arrive on
    /// the process's own reader queue, so waiting here holds up only this
    /// chat's next line, never the cooperative pool the git call runs on.
    private func committed(_ path: String) -> String {
        let dir = (path as NSString).deletingLastPathComponent, name = (path as NSString).lastPathComponent
        let text = Mutex(""), done = DispatchSemaphore(value: 0)
        Task { [executor] in
            if let out = try? await executor.run("git", ["--no-pager", "show", "HEAD:./\(name)"], cwd: dir), out.ok {
                text.withLock { $0 = out.stdout }
            }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 5)
        return text.withLock { $0 }
    }
}
