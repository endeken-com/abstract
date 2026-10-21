import Foundation

/// One permission request or question waiting in a chat, the way the
/// host holds it, before it's cut down for a plugin (ABS-111).
public struct PluginPendingRequest: Sendable, Equatable {
    public var chatId: String
    public var requestId: String
    public var toolName: String
    public var input: JSONValue
    public var requestedAt: Date
    /// The chat's worktree, so a path reads relative to it.
    public var root: String?

    public init(chatId: String, requestId: String, toolName: String, input: JSONValue,
                requestedAt: Date, root: String? = nil) {
        self.chatId = chatId; self.requestId = requestId; self.toolName = toolName
        self.input = input; self.requestedAt = requestedAt; self.root = root
    }

    /// `question`, `plan` or `permission`, as `permission.requested` says.
    public var kind: String {
        if AgentQuestion.isQuestion(toolName) { return "question" }
        if Plan.isExitPlanMode(toolName) { return "plan" }
        return "permission"
    }

    /// The command a shell request runs, without the `zsh -lc "…"` some
    /// agents wrap it in; nil for anything that isn't a command.
    public var command: String? {
        guard PluginPermissions.commandTools.contains(toolName.lowercased()),
              let raw = input["command"]?.string ?? input["command"]?.array?.compactMap(\.string).joined(separator: " "),
              !raw.isEmpty else { return nil }
        return PermissionRule.unwrapShell(raw)
    }
}

/// What a plugin with `permissions.answer` sees of what's waiting, and
/// the rule for answering several at once (ABS-111).
public enum PluginPermissions {
    /// No more than this many requests in one list.
    public static let listLimit = 200
    /// Requests one batch may allow.
    public static let batchLimit = 50
    static let commandTools: Set<String> = ["bash", "shell", "command_execution"]
    /// The longest command a plugin may allow: the ask shows all of it.
    /// A longer one is allowed from its chat's own card.
    public static let commandTextLimit = 2_000

    /// Whether a plugin may allow this request: everything it would run
    /// fits in the ask.
    public static func mayAllowFromPlugin(_ request: PluginPendingRequest) -> Bool {
        (request.command?.count ?? 0) <= commandTextLimit
    }

    /// Only the requests in chats the plugin can see in its snapshot.
    public static func visible(_ requests: [PluginPendingRequest], chatIds: Set<String>) -> [PluginPendingRequest] {
        requests.filter { chatIds.contains($0.chatId) }
    }

    /// Every waiting request, oldest first: the chat, the tool and a short
    /// summary of its input (command, file and diff size), or a
    /// question's text and options.
    public static func list(_ requests: [PluginPendingRequest]) -> JSONValue {
        let sorted = requests.sorted {
            $0.requestedAt != $1.requestedAt ? $0.requestedAt < $1.requestedAt : $0.requestId < $1.requestId
        }
        return .object(["requests": .array(sorted.prefix(listLimit).map(item)),
                        "total": .number(Double(sorted.count))])
    }

    static func item(_ request: PluginPendingRequest) -> JSONValue {
        var object: [String: JSONValue] = [
            "chatId": .string(request.chatId), "requestId": .string(request.requestId),
            "kind": .string(request.kind), "toolName": .string(request.toolName),
            "requestedAt": .string(PluginData.iso(request.requestedAt)),
        ]
        switch request.kind {
        case "question":
            object["questions"] = .array(AgentQuestion.parse(request.input).map { question in
                var q: [String: JSONValue] = [
                    "question": .string(question.question), "multiSelect": .bool(question.multiSelect),
                    "options": .array(question.options.map { option in
                        var o: [String: JSONValue] = ["label": .string(option.label)]
                        if let description = option.description { o["description"] = .string(description) }
                        return .object(o)
                    }),
                ]
                if let header = question.header { q["header"] = .string(header) }
                return .object(q)
            })
        case "plan":
            break
        default:
            if let command = request.command {
                object["command"] = .string(command.count > commandTextLimit
                    ? String(command.prefix(commandTextLimit)) + "…" : command)
            }
            if let path = path(request) { object["path"] = .string(path) }
            if let edit = EditPreview.fromToolInput(name: request.toolName, input: request.input) {
                object["added"] = .number(Double(edit.additions))
                object["removed"] = .number(Double(edit.deletions))
            }
            for key in ["description", "url", "pattern", "query"] {
                if let text = request.input[key]?.string, !text.isEmpty {
                    object[key] = .string(String(text.prefix(300)))
                }
            }
        }
        return .object(object)
    }

    /// The file a request touches, relative to the chat's worktree.
    public static func path(_ request: PluginPendingRequest) -> String? {
        for key in ["file_path", "filePath", "notebook_path", "path"] {
            guard let path = request.input[key]?.string, !path.isEmpty else { continue }
            if let root = request.root, !root.isEmpty {
                let base = root.hasSuffix("/") ? root : root + "/"
                if path.hasPrefix(base) { return String(path.dropFirst(base.count)) }
            }
            return path
        }
        return nil
    }

    /// The requests one batch Allow answers, or why it can't: every one
    /// must still be waiting, be a command, and run exactly the same
    /// command as the rest. Anything else is answered one at a time.
    public static func batch(_ targets: [PluginAction.Target],
                             pending: [PluginPendingRequest]) throws -> [PluginPendingRequest] {
        guard targets.count >= 2, targets.count <= batchLimit, Set(targets).count == targets.count else {
            throw AbstractError.message("Allow several at once takes between 2 and \(batchLimit) requests.")
        }
        var found: [PluginPendingRequest] = []
        for target in targets {
            guard let request = pending.first(where: { $0.chatId == target.chatId && $0.requestId == target.requestId }) else {
                throw AbstractError.message("One of those requests isn't waiting any more.")
            }
            found.append(request)
        }
        guard let command = found[0].command,
              found.allSatisfy({ $0.command == command && $0.toolName == found[0].toolName }) else {
            throw AbstractError.message("Only exactly the same command can be allowed several at once.")
        }
        return found
    }
}
