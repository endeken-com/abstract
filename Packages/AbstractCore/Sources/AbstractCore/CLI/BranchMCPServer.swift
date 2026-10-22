import Foundation

/// The per-chat counterpart of `abstract branch name <exact-name>`.
public struct BranchMCPServer: Sendable {
    public static let serverName = "abstract-branch"
    public static let instruction = """
        For a fresh-worktree automation run, keep its provisional branch until you know the work. \
        Then choose the exact git branch name and run `abstract branch name <exact-name>` from this chat's worktree, \
        or call the `name_branch` tool. Include the project's required branch prefix. \
        A rejected request explains why; do not assume the branch changed.
        """

    let chatId: String
    public init(chatId: String) { self.chatId = chatId }

    public func run() async {
        while let line = readLine() {
            if let reply = await handle(line) { print(reply); fflush(stdout) }
        }
    }

    public func handle(_ line: String) async -> String? {
        guard let request = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)),
              let id = request["id"], id != .null, let method = request["method"]?.string else { return nil }
        let result: JSONValue
        switch method {
        case "initialize":
            result = .object([
                "protocolVersion": request["params"]?["protocolVersion"] ?? .string("2024-11-05"),
                "capabilities": .object(["tools": .object([:])]),
                "serverInfo": .object(["name": .string(Self.serverName), "version": .string("1")]),
            ])
        case "ping": result = .object([:])
        case "tools/list": result = .object(["tools": .array([.object([
            "name": .string("name_branch"),
            "description": .string("Give this automation chat's provisional branch the exact git name you choose."),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object(["name": .object(["type": .string("string")])]),
                "required": .array([.string("name")]),
            ]),
        ])])])
        case "tools/call":
            let params = request["params"]
            guard params?["name"]?.string == "name_branch",
                  let name = params?["arguments"]?["name"]?.string else {
                result = Self.text("name_branch needs a name.", error: true)
                break
            }
            do {
                let named = try await Commands.open().nameRunBranch(name, in: FileManager.default.currentDirectoryPath, chatId: chatId)
                result = Self.text("Branch renamed to `\(named.branch)`.")
            } catch {
                result = Self.text(error.localizedDescription, error: true)
            }
        default:
            return JSONValue.object(["jsonrpc": .string("2.0"), "id": id,
                                     "error": .object(["code": .number(-32601), "message": .string("Unknown method.")])]).compact()
        }
        return JSONValue.object(["jsonrpc": .string("2.0"), "id": id, "result": result]).compact()
    }

    private static func text(_ body: String, error: Bool = false) -> JSONValue {
        .object(["content": .array([.object(["type": .string("text"), "text": .string(body)])]),
                 "isError": .bool(error)])
    }
}
