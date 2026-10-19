import Foundation

/// `abstract mcp --chat <id>`: the stdio MCP server that gives one chat's
/// agent the `code_history` and `chat_excerpt` tools (ABS-61). It finds
/// the chat's project itself, so the agent can never name another one.
/// One JSON-RPC message per line, in and out.
public struct HistoryMCPServer: Sendable {
    let service: CodeHistoryService
    var executor: any Executor { LocalExecutor.shared }

    public init(service: CodeHistoryService) { self.service = service }

    /// The server for a chat, against the app's own database; nil when
    /// the chat (or the database) isn't there.
    public static func open(chatId: String) -> HistoryMCPServer? {
        guard let commands = try? Commands.open(), let session = try? commands.store.session(chatId) else { return nil }
        let project = session.projectId.flatMap { try? commands.store.project($0) }
        guard let repo = session.worktreePath ?? project?.rootPath else { return nil }
        return HistoryMCPServer(service: CodeHistoryService(
            store: commands.store, projectId: session.projectId, askingSessionId: session.id, repo: repo))
    }

    /// Answers MCP requests from stdin until it closes.
    public func run() async {
        while let line = readLine() {
            if let reply = await handle(line) {
                print(reply)
                fflush(stdout)
            }
        }
    }

    /// One request line → its reply line; nil for a notification, or for
    /// input that isn't a request at all.
    public func handle(_ line: String) async -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let request = try? JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8)),
              let method = request["method"]?.string else { return nil }
        guard let id = request["id"], id != .null else { return nil }
        let params = request["params"] ?? .object([:])
        switch method {
        case "initialize":
            return reply(id, result: .object([
                "protocolVersion": params["protocolVersion"] ?? .string("2024-11-05"),
                "capabilities": .object(["tools": .object([:])]),
                "serverInfo": .object(["name": .string(CodeHistory.serverName), "version": .string("1")]),
            ]))
        case "ping":
            return reply(id, result: .object([:]))
        case "tools/list":
            return reply(id, result: .object(["tools": .array(Self.tools)]))
        case "tools/call":
            return reply(id, result: await call(params))
        default:
            return JSONValue.object([
                "jsonrpc": .string("2.0"), "id": id,
                "error": .object(["code": .number(-32601), "message": .string("Unknown method “\(method)”.")]),
            ]).compact()
        }
    }

    private func reply(_ id: JSONValue, result: JSONValue) -> String {
        JSONValue.object(["jsonrpc": .string("2.0"), "id": id, "result": result]).compact()
    }

    private func text(_ body: String, isError: Bool = false) -> JSONValue {
        .object(["content": .array([.object(["type": .string("text"), "text": .string(body)])]),
                 "isError": .bool(isError)])
    }

    private func call(_ params: JSONValue) async -> JSONValue {
        let arguments = params["arguments"] ?? .object([:])
        switch params["name"]?.string {
        case CodeHistory.historyTool:
            guard let path = arguments["path"]?.string, !path.isEmpty else {
                return text("code_history needs a path.", isError: true)
            }
            guard service.relativePath(path) != nil else {
                return text("“\(path)” is outside this repository.", isError: true)
            }
            let lines = CodeHistoryService.lineRange(arguments["lines"]?.string)
            let entries = await service.history(path: path, lines: lines, exec: executor)
            return text(CodeHistoryService.render(entries))
        case CodeHistory.excerptTool:
            guard let chat = arguments["chat"]?.string, let turn = arguments["turn"]?.int else {
                return text("chat_excerpt needs a chat and a turn number, as a code_history heading gives them.", isError: true)
            }
            guard let entry = service.excerpt(chatId: chat, turn: turn) else {
                return text("No such turn in this project's earlier chats.", isError: true)
            }
            return text(CodeHistoryService.render([entry], budget: CodeHistoryService.excerptBudget))
        default:
            return text("Unknown tool “\(params["name"]?.string ?? "")”.", isError: true)
        }
    }

    /// Both tools are read-only, and say so: `codex exec` refuses an MCP
    /// call that would need approval.
    static let tools: [JSONValue] = [
        .object([
            "name": .string(CodeHistory.historyTool),
            "description": .string("""
                The history of a file, or of lines in it, in this project: what earlier chats were asked, \
                what the person corrected, and what was decided and why. Call it before changing existing \
                code, for each file you're about to change, with the lines when you know them.
                """),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object(["type": .string("string"),
                                     "description": .string("The file, relative to the repository or absolute inside it.")]),
                    "lines": .object(["type": .string("string"),
                                      "description": .string("Optional: one line or a range, like \"220\" or \"220-245\".")]),
                ]),
                "required": .array([.string("path")]),
            ]),
            "annotations": .object(["readOnlyHint": .bool(true)]),
        ]),
        .object([
            "name": .string(CodeHistory.excerptTool),
            "description": .string("""
                More of one earlier conversation: the fuller request, corrections, summary and review \
                comments of a single turn that code_history named.
                """),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([
                    "chat": .object(["type": .string("string"),
                                     "description": .string("The chat id from a code_history heading.")]),
                    "turn": .object(["type": .string("integer"),
                                     "description": .string("The turn number from the same heading.")]),
                ]),
                "required": .array([.string("chat"), .string("turn")]),
            ]),
            "annotations": .object(["readOnlyHint": .bool(true)]),
        ]),
    ]
}
