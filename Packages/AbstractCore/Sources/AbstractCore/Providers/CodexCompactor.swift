import Foundation
import Synchronization

/// Compacting one Codex thread over `codex app-server`'s JSON-RPC: initialize,
/// resume the thread, start compacting, and wait for its `contextCompaction`
/// item to complete. Shapes checked against codex-cli 0.156.1
/// (`Tests/AbstractCoreTests/Fixtures/codex-app-server-compact.jsonl`); no
/// summary text is exposed.
struct CodexCompaction: Sendable {
    let threadId: String
    private var before: Int?
    private var after: Int?
    private var window: Int?
    private var compacting = false

    private static let initializeId = 1, resumeId = 2, compactId = 3

    init(threadId: String) { self.threadId = threadId }

    var opening: [String] {
        [Self.message(id: Self.initializeId, method: "initialize",
                      params: ["clientInfo": .object(["name": .string("abstract"), "version": .string("1")])])]
    }

    mutating func receive(_ line: String) -> SideStep<CompactionResult> {
        guard let obj = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)), obj.object != nil else { return .wait }
        if let error = obj["error"], error.object != nil {
            return .fail("Codex: " + (error["message"]?.string ?? "the request failed"))
        }
        let thread: [String: JSONValue] = ["threadId": .string(threadId)]
        switch (obj["id"]?.int, obj["method"]?.string) {
        case (Self.initializeId?, _):
            return .send([Self.message(method: "initialized"),
                          Self.message(id: Self.resumeId, method: "thread/resume", params: thread.merging(["excludeTurns": .bool(true)]) { a, _ in a })])
        case (Self.resumeId?, _):
            return .send([Self.message(id: Self.compactId, method: "thread/compact/start", params: thread)])
        case (_, "thread/tokenUsage/updated"):
            let usage = obj["params"]?["tokenUsage"]
            let tokens = usage?["last"]?["totalTokens"]?.int
            window = usage?["modelContextWindow"]?.int ?? window
            if compacting { after = tokens } else { before = tokens }
            return .wait
        case (_, "item/started") where Self.isCompaction(obj):
            compacting = true
            return .wait
        case (_, "item/completed") where Self.isCompaction(obj):
            return .finish(CompactionResult(tokensBefore: before, tokensAfter: after, contextWindow: window))
        default:
            return .wait
        }
    }

    private static func isCompaction(_ obj: JSONValue) -> Bool {
        obj["params"]?["item"]?["type"]?.string == "contextCompaction"
    }

    /// One JSON-RPC line; no `id` makes it a notification.
    private static func message(id: Int? = nil, method: String, params: [String: JSONValue]? = nil) -> String {
        var body: [String: JSONValue] = ["jsonrpc": .string("2.0"), "method": .string(method)]
        if let id { body["id"] = .number(Double(id)) }
        if let params { body["params"] = .object(params) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(JSONValue.object(body))) ?? Data(), as: UTF8.self) + "\n"
    }
}

/// Runs `CodexCompaction` against a real `codex app-server` on the chat's host.
public struct CodexCompactor: Compactor {
    static let timeout: Duration = .seconds(300)

    public init() {}

    public func compact(_ request: CompactionRequest, executor: any Executor) async throws -> CompactionResult {
        let spec = LaunchSpec(command: request.binaryOverride ?? CodexProvider().binary, args: ["app-server"],
                              cwd: request.cwd, keepStdinOpen: true)
        let conversation = Conversation(threadId: request.sessionId)
        return try await SideProcess.converse(executor, spec, opening: conversation.opening, timeout: Self.timeout) {
            conversation.receive($0)
        }
    }

    /// The state machine behind a lock, for the process's reader queue.
    private final class Conversation: Sendable {
        private let state: Mutex<CodexCompaction>
        init(threadId: String) { state = Mutex(CodexCompaction(threadId: threadId)) }
        var opening: [String] { state.withLock { $0.opening } }
        func receive(_ line: String) -> SideStep<CompactionResult> { state.withLock { $0.receive(line) } }
    }
}
