import Foundation

/// ABEL's own chat (ABS-204): an ordinary chat named ABEL, run by the
/// agent you choose, that answers what the grammar doesn't. Its agent gets
/// Abstract-control tools from `abstract mcp --chat <id> --abel`, which
/// passes each call to Abel.app. Abel reads every acting call back and
/// waits for your "yes" before it acts, so the agent never acts unheard.
public enum AbelTools {
    public static let serverName = "abel"
    public static let chatName = "ABEL"

    /// What ABEL's chat's agent is told, ahead of any profile's instructions.
    public static let instructions = """
        You are ABEL, Abstract's Built-in Expert Listener: the voice assistant of Abstract, the app that runs \
        coding agents in chats. The person talks to you by voice, and your replies are read aloud.

        - Answer in one to three short sentences of plain language. No code, tables or lists unless asked.
        - Use the `abel` tools to see and act on the person's chats: list_chats, chat_status, read_reply, \
        start_chat, send_to_chat, stop_chat and answer_permission. Name chats by their titles.
        - Each acting tool is read back to the person, who must say yes. If they decline, say so and stop.
        - Never merge, push, delete anything or turn on full autonomy, and don't ask to: tell the person to \
        do that on screen.
        """

    /// The tools' `tools/list` entries.
    public static let definitions: [JSONValue] = [
        tool("list_chats", "The person's chats on this Mac: title, project, agent, state (needs you, working, "
             + "ready to review, done), what it waits for, and its pull request.",
             ["state": .object(["type": .string("string"), "enum": .array(["needs_you", "working", "all"].map(JSONValue.string)),
                                "description": .string("Only chats in this state; all by default.")])]),
        tool("chat_status", "One chat's state in a sentence: working, waiting and on what, done; its pull request and checks.",
             ["chat": chatParameter], required: ["chat"]),
        tool("read_reply", "A chat's last reply, as Markdown.", ["chat": chatParameter], required: ["chat"]),
        tool("start_chat", "Start a new chat that works on `prompt`, in a project (or on its own). "
             + "The person must say yes first.",
             ["project": .object(["type": .string("string"), "description": .string("The project's name; omit for a chat of its own.")]),
              "prompt": .object(["type": .string("string"), "description": .string("What the new chat's agent should do.")])],
             required: ["prompt"]),
        tool("send_to_chat", "Send a follow-up message to a chat's agent. The person must say yes first.",
             ["chat": chatParameter, "text": .object(["type": .string("string"), "description": .string("The message.")])],
             required: ["chat", "text"]),
        tool("stop_chat", "Stop a chat's agent. The person must say yes first.", ["chat": chatParameter], required: ["chat"]),
        tool("answer_permission", "Allow or decline the request a chat's agent is waiting on. It's read back to the "
             + "person, who must say yes.",
             ["chat": chatParameter, "allow": .object(["type": .string("boolean"), "description": .string("true to allow, false to decline.")])],
             required: ["chat", "allow"]),
    ]

    /// The tools that change something, and so are read back first.
    public static let acting: Set<String> = ["start_chat", "send_to_chat", "stop_chat", "answer_permission"]

    static let chatParameter: JSONValue = .object([
        "type": .string("string"), "description": .string("The chat's title, as the person said it, or its id."),
    ])

    static func tool(_ name: String, _ description: String, _ properties: [String: JSONValue],
                     required: [String] = []) -> JSONValue {
        .object([
            "name": .string(name),
            "description": .string(description),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object(properties),
                "required": .array(required.map(JSONValue.string)),
            ]),
        ])
    }

    /// The server ABEL's chat's agent gets.
    public static func server(command: String, chatId: String) -> MCPServerLaunch {
        MCPServerLaunch(name: serverName, connection: .command([command, "mcp", "--chat", chatId, "--abel"], env: [:]),
                        allowsEverything: true)
    }

    /// How long a call may take: long enough to read it back and hear yes.
    public static let callTimeoutMs: Int32 = 90_000
}

/// `abstract mcp --chat <id> --abel`'s tools: listed here, run by Abel.app.
public struct AbelToolSource: PluginToolSource {
    public let chatId: String
    public let storePath: String

    public init(chatId: String, storePath: String = Store.defaultPath()) {
        self.chatId = chatId; self.storePath = storePath
    }

    public func list() async -> [JSONValue]? { AbelTools.definitions }

    public func call(_ name: String, arguments: JSONValue) async -> (text: String, isError: Bool) {
        let storePath = storePath, chatId = chatId
        let request = AbelLink.HelperRequest(kind: .tool, text: arguments.compact(), chatId: chatId, name: name)
        let reply = await AbelLink.offThePool {
            AbelLink.tell(request, storePath: storePath, timeoutMs: AbelTools.callTimeoutMs)
        }
        guard let reply else { return ("ABEL isn't running, so its tools can't be used. Ask the person to start ABEL.", true) }
        return (reply.message ?? "", !reply.ok)
    }
}

/// What can be approved by voice: only what's read back whole, in plain
/// words (ABS-204). A command of letters, digits, spaces and `._/=:,@+-`
/// alone, short enough to hear; anything with a quote, `$`, `;`, `&`, `|`,
/// a redirect, a glob or a new line is approved on screen, where all of it
/// can be seen. So is a file outside the chat's own folder.
public enum AbelReadBack {
    public static let longest = 120
    static let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 ._/=:,@+-")

    public static func canReadBack(command: String) -> Bool {
        !command.isEmpty && command.count <= longest && command.unicodeScalars.allSatisfy(plain.contains)
    }

    /// Whether `relative`, below `root`, passes through a link in any part
    /// that exists. Links aren't followed or guessed at: any one, even a
    /// broken one, means the path isn't read back. The root itself (the
    /// chat's folder) is trusted.
    public static func passesThroughLink(_ relative: String, below root: String) -> Bool {
        var current = root
        for part in relative.split(separator: "/") {
            current = (current as NSString).appendingPathComponent(String(part))
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: current)) != nil { return true }
            guard FileManager.default.fileExists(atPath: current) else { return false }
        }
        return false
    }

    /// `path` relative to `root`, when it's plainly inside it: no `.` or
    /// `..`, no link on the way, and words that read back whole. nil sends
    /// the approval to the screen.
    public static func readablePath(_ path: String, in root: String?) -> String? {
        guard let root, !root.isEmpty else { return nil }
        let parts = path.split(separator: "/")
        guard !parts.contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        // The chat's own folder under either of its names (/var is /private/var).
        let base = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path
        let given = path.hasPrefix("/") ? path : (root as NSString).appendingPathComponent(path)
        // Written under the root's name as given, or as resolved.
        let relative: String
        if given.hasPrefix(base + "/") {
            relative = String(given.dropFirst(base.count + 1))
        } else {
            let plainRoot = URL(fileURLWithPath: root).standardizedFileURL.path
            guard given.hasPrefix(plainRoot + "/") else { return nil }
            relative = String(given.dropFirst(plainRoot.count + 1))
        }
        guard !relative.isEmpty, !passesThroughLink(relative, below: root) else { return nil }
        return canReadBack(command: relative) ? relative : nil
    }
}
