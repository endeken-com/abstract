import Foundation

/// `AgentEvent` as JSON (ABS-185): what an agent plugin's script returns from
/// `feed`, one object per event with a `type`, decoded 1:1 into the enum the
/// rest of Abstract reads. Encoding is the same shape, so a fixture's events
/// can be written down and compared.
///
/// ```js
/// { type: "text", role: "assistant", text: "Hi", blockId: "b1", partial: false }
/// { type: "toolUse", id: "t1", name: "edit", input: {…}, edit: <EditPreview>|null }
/// ```
public enum AgentEventJSON {
    public static func decode(_ value: JSONValue) -> AgentEvent? {
        guard let type = value["type"]?.string else { return nil }
        func string(_ key: String) -> String? { value[key]?.string }
        func int(_ key: String) -> Int? { value[key]?.int }
        func bool(_ key: String) -> Bool? { value[key]?.bool }
        switch type {
        case "status":
            guard let status = string("status").flatMap(SessionStatus.init(rawValue:)) else { return nil }
            return .status(status, detail: string("detail"))
        case "sessionId":
            return string("id").map(AgentEvent.sessionId)
        case "launch":
            return value["record"].flatMap { decodeCodable(LaunchRecord.self, $0) }.map(AgentEvent.launch)
        case "system":
            return .system(model: string("model"), cwd: string("cwd"), permissionMode: string("permissionMode"),
                           sessionId: string("sessionId"))
        case "text":
            guard let text = string("text") else { return nil }
            return .text(role: string("role").flatMap(TextRole.init(rawValue:)) ?? .assistant, text: text,
                         blockId: string("blockId"), partial: bool("partial") ?? false)
        case "thinking":
            guard let text = string("text") else { return nil }
            return .thinking(text: text, blockId: string("blockId"), partial: bool("partial") ?? false)
        case "toolUse":
            guard let id = string("id"), let name = string("name") else { return nil }
            return .toolUse(id: id, name: name, input: value["input"] ?? .object([:]), edit: edit(value["edit"]))
        case "toolResult":
            guard let id = string("toolUseId") else { return nil }
            return .toolResult(toolUseId: id, output: string("output") ?? "", isError: bool("isError") ?? false,
                               edit: edit(value["edit"]))
        case "toolFileChanges":
            guard let id = string("toolUseId"), let changes = value["changes"] else { return nil }
            return .toolFileChanges(toolUseId: id, changes: ToolFileChanges(
                previews: (changes["previews"]?.array ?? []).compactMap(edit),
                remainingPaths: (changes["remainingPaths"]?.array ?? []).compactMap(\.string),
                moreFiles: changes["moreFiles"]?.int ?? 0, incomplete: changes["incomplete"]?.bool ?? false))
        case "toolImages":
            guard let id = string("toolUseId") else { return nil }
            let images = (value["images"]?.array ?? []).compactMap { image -> ToolImage? in
                guard let type = image["mediaType"]?.string, let data = image["data"]?.string.flatMap({ Data(base64Encoded: $0) })
                else { return nil }
                return ToolImage(mediaType: type, data: data)
            }
            return .toolImages(toolUseId: id, images: images)
        case "gitOperation":
            return gitOperation(value["operation"] ?? .null).map(AgentEvent.gitOperation)
        case "permissionRequest":
            guard let id = string("requestId"), let name = string("toolName") else { return nil }
            return .permissionRequest(requestId: id, toolName: name, input: value["input"] ?? .object([:]))
        case "turnEnd":
            return .turnEnd(durationMs: int("durationMs"), costUsd: value["costUsd"]?.double,
                            usage: value["usage"].flatMap(usage), summary: string("summary"))
        case "usage":
            return .usage(value["usage"].flatMap(usage) ?? .zero, costUsd: value["costUsd"]?.double,
                          durationMs: int("durationMs"), turns: int("turns"))
        case "error":
            return string("message").map(AgentEvent.error)
        case "notice":
            return notice(value["notice"] ?? .null).map(AgentEvent.notice)
        case "raw":
            guard let line = string("line") else { return nil }
            return .raw(line: line, stream: string("stream").flatMap(OutputStreamKind.init(rawValue:)) ?? .stdout)
        case "promptSuggestion":
            return string("text").map(AgentEvent.promptSuggestion)
        case "commands":
            guard let provider = string("providerId") else { return nil }
            let commands = (value["commands"]?.array ?? []).compactMap { command -> AgentCommand? in
                guard let name = command["name"]?.string else { return nil }
                return AgentCommand(name: name, detail: command["detail"]?.string, argumentHint: command["argumentHint"]?.string,
                                    kind: command["kind"]?.string == "skill" ? .skill : .command)
            }
            return .commands(AgentCommandList(providerId: provider, commands: commands))
        case "task":
            return task(value["task"] ?? .null).map(AgentEvent.task)
        case "subagent":
            guard let parent = string("parentToolUseId"), let inner = value["event"].flatMap(decode) else { return nil }
            return .subagent(parentToolUseId: parent, inner)
        case "handoff":
            guard let from = string("from"), let to = string("to") else { return nil }
            return .handoff(from: from, to: to, summary: string("summary"), source: string("source").flatMap(HandoffSource.init(rawValue:)))
        case "compaction":
            return compaction(value["compaction"] ?? .null).map(AgentEvent.compaction)
        default:
            return nil
        }
    }

    public static func encode(_ event: AgentEvent) -> JSONValue {
        var o: [String: JSONValue] = [:]
        func set(_ key: String, _ value: String?) { if let value { o[key] = .string(value) } }
        func setInt(_ key: String, _ value: Int?) { if let value { o[key] = .number(Double(value)) } }
        switch event {
        case let .status(status, detail):
            o["type"] = .string("status"); set("status", status.rawValue); set("detail", detail)
        case let .sessionId(id):
            o["type"] = .string("sessionId"); set("id", id)
        case let .launch(record):
            o["type"] = .string("launch"); o["record"] = encodeCodable(record)
        case let .system(model, cwd, mode, sessionId):
            o["type"] = .string("system"); set("model", model); set("cwd", cwd); set("permissionMode", mode); set("sessionId", sessionId)
        case let .text(role, text, blockId, partial):
            o["type"] = .string("text"); set("role", role.rawValue); set("text", text); set("blockId", blockId); o["partial"] = .bool(partial)
        case let .thinking(text, blockId, partial):
            o["type"] = .string("thinking"); set("text", text); set("blockId", blockId); o["partial"] = .bool(partial)
        case let .toolUse(id, name, input, edit):
            o["type"] = .string("toolUse"); set("id", id); set("name", name); o["input"] = input
            if let edit { o["edit"] = encodeCodable(edit) }
        case let .toolResult(id, output, isError, edit):
            o["type"] = .string("toolResult"); set("toolUseId", id); set("output", output); o["isError"] = .bool(isError)
            if let edit { o["edit"] = encodeCodable(edit) }
        case let .toolFileChanges(id, changes):
            o["type"] = .string("toolFileChanges"); set("toolUseId", id)
            o["changes"] = .object(["previews": .array(changes.previews.map(encodeCodable)),
                                    "remainingPaths": .array(changes.remainingPaths.map(JSONValue.string)),
                                    "moreFiles": .number(Double(changes.moreFiles)), "incomplete": .bool(changes.incomplete)])
        case let .toolImages(id, images):
            o["type"] = .string("toolImages"); set("toolUseId", id)
            o["images"] = .array(images.map { .object(["mediaType": .string($0.mediaType), "data": .string($0.data.base64EncodedString())]) })
        case let .gitOperation(operation):
            o["type"] = .string("gitOperation"); o["operation"] = encodeGit(operation)
        case let .permissionRequest(id, name, input):
            o["type"] = .string("permissionRequest"); set("requestId", id); set("toolName", name); o["input"] = input
        case let .turnEnd(durationMs, costUsd, usage, summary):
            o["type"] = .string("turnEnd"); setInt("durationMs", durationMs); if let costUsd { o["costUsd"] = .number(costUsd) }
            if let usage { o["usage"] = encodeCodable(usage) }; set("summary", summary)
        case let .usage(usage, costUsd, durationMs, turns):
            o["type"] = .string("usage"); o["usage"] = encodeCodable(usage); if let costUsd { o["costUsd"] = .number(costUsd) }
            setInt("durationMs", durationMs); setInt("turns", turns)
        case let .error(message):
            o["type"] = .string("error"); set("message", message)
        case let .notice(notice):
            o["type"] = .string("notice"); o["notice"] = encodeNotice(notice)
        case let .raw(line, stream):
            o["type"] = .string("raw"); set("line", line); set("stream", stream.rawValue)
        case let .promptSuggestion(text):
            o["type"] = .string("promptSuggestion"); set("text", text)
        case let .commands(list):
            o["type"] = .string("commands"); set("providerId", list.providerId)
            o["commands"] = .array(list.commands.map { command in
                var c: [String: JSONValue] = ["name": .string(command.name), "kind": .string(command.kind == .skill ? "skill" : "command")]
                if let detail = command.detail { c["detail"] = .string(detail) }
                if let hint = command.argumentHint { c["argumentHint"] = .string(hint) }
                return .object(c)
            })
        case let .task(task):
            o["type"] = .string("task"); o["task"] = encodeTask(task)
        case let .subagent(parent, inner):
            o["type"] = .string("subagent"); set("parentToolUseId", parent); o["event"] = encode(inner)
        case let .handoff(from, to, summary, source):
            o["type"] = .string("handoff"); set("from", from); set("to", to); set("summary", summary); set("source", source?.rawValue)
        case let .compaction(event):
            o["type"] = .string("compaction"); o["compaction"] = encodeCompaction(event)
        }
        return .object(o)
    }

    // MARK: Pieces

    static func decodeCodable<T: Decodable>(_ type: T.Type, _ value: JSONValue) -> T? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func encodeCodable<T: Encodable>(_ value: T) -> JSONValue {
        guard let data = try? JSONEncoder().encode(value),
              let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) else { return .null }
        return decoded
    }

    static func edit(_ value: JSONValue?) -> EditPreview? {
        guard let value, value.object != nil else { return nil }
        return decodeCodable(EditPreview.self, value)
    }

    static func usage(_ value: JSONValue) -> UsageTotals? {
        guard value.object != nil else { return nil }
        return UsageTotals(inputTokens: value["inputTokens"]?.int ?? 0, outputTokens: value["outputTokens"]?.int ?? 0,
                           cacheRead: value["cacheRead"]?.int ?? 0, cacheWrite: value["cacheWrite"]?.int ?? 0)
    }

    static func date(_ value: JSONValue?) -> Date? {
        value?.double.map { Date(timeIntervalSince1970: $0) }
    }

    static func notice(_ value: JSONValue) -> AgentNotice? {
        switch value["kind"]?.string {
        case "retrying":
            return .retrying(attempt: value["attempt"]?.int ?? 1, maxAttempts: value["maxAttempts"]?.int, httpStatus: value["httpStatus"]?.int)
        case "nearLimit": return .nearLimit(resetsAt: date(value["resetsAt"]))
        case "limitReached": return .limitReached(resetsAt: date(value["resetsAt"]))
        case "warning": return value["message"]?.string.map(AgentNotice.warning)
        case "info": return value["message"]?.string.map(AgentNotice.info)
        default: return nil
        }
    }

    static func encodeNotice(_ notice: AgentNotice) -> JSONValue {
        func at(_ date: Date?) -> JSONValue { date.map { .number($0.timeIntervalSince1970) } ?? .null }
        switch notice {
        case let .retrying(attempt, max, status):
            var o: [String: JSONValue] = ["kind": .string("retrying"), "attempt": .number(Double(attempt))]
            if let max { o["maxAttempts"] = .number(Double(max)) }
            if let status { o["httpStatus"] = .number(Double(status)) }
            return .object(o)
        case let .nearLimit(resetsAt): return .object(["kind": .string("nearLimit"), "resetsAt": at(resetsAt)])
        case let .limitReached(resetsAt): return .object(["kind": .string("limitReached"), "resetsAt": at(resetsAt)])
        case let .warning(message): return .object(["kind": .string("warning"), "message": .string(message)])
        case let .info(message): return .object(["kind": .string("info"), "message": .string(message)])
        }
    }

    static func gitOperation(_ value: JSONValue) -> GitOperation? {
        switch value["kind"]?.string {
        case "commit":
            guard let sha = value["sha"]?.string else { return nil }
            return .commit(sha: sha, kind: value["commitKind"]?.string ?? "committed", branch: value["branch"]?.string)
        case "push": return .push(branch: value["branch"]?.string)
        case "pullRequest":
            guard let number = value["number"]?.int, let action = value["action"]?.string else { return nil }
            return .pullRequest(number: number, url: value["url"]?.string.flatMap(URL.init(string:)), action: action)
        default: return nil
        }
    }

    static func encodeGit(_ operation: GitOperation) -> JSONValue {
        switch operation {
        case let .commit(sha, kind, branch):
            var o: [String: JSONValue] = ["kind": .string("commit"), "sha": .string(sha), "commitKind": .string(kind)]
            if let branch { o["branch"] = .string(branch) }
            return .object(o)
        case let .push(branch):
            return .object(["kind": .string("push")].merging(branch.map { ["branch": .string($0)] } ?? [:]) { $1 })
        case let .pullRequest(number, url, action):
            var o: [String: JSONValue] = ["kind": .string("pullRequest"), "number": .number(Double(number)), "action": .string(action)]
            if let url { o["url"] = .string(url.absoluteString) }
            return .object(o)
        }
    }

    static func taskUsage(_ value: JSONValue?) -> TaskUsage? {
        guard let value, value.object != nil else { return nil }
        return TaskUsage(tokens: value["tokens"]?.int, toolUses: value["toolUses"]?.int, durationMs: value["durationMs"]?.int)
    }

    static func encodeTaskUsage(_ usage: TaskUsage?) -> JSONValue? {
        guard let usage else { return nil }
        var o: [String: JSONValue] = [:]
        if let tokens = usage.tokens { o["tokens"] = .number(Double(tokens)) }
        if let uses = usage.toolUses { o["toolUses"] = .number(Double(uses)) }
        if let ms = usage.durationMs { o["durationMs"] = .number(Double(ms)) }
        return .object(o)
    }

    static func task(_ value: JSONValue) -> TaskEvent? {
        let id = value["taskId"]?.string
        switch value["kind"]?.string {
        case "started":
            let t = value["task"] ?? .null
            guard let taskId = t["id"]?.string, let description = t["description"]?.string else { return nil }
            return .started(AgentTask(
                id: taskId, kind: t["kind"]?.string.flatMap(AgentTask.Kind.init(rawValue:)) ?? .other, description: description,
                toolUseId: t["toolUseId"]?.string, subagentType: t["subagentType"]?.string, prompt: t["prompt"]?.string,
                isBackgrounded: t["isBackgrounded"]?.bool ?? false, ownedBySubagent: t["ownedBySubagent"]?.bool ?? false,
                status: t["status"]?.string.flatMap(AgentTask.Status.init(rawValue:)) ?? .running,
                activity: t["activity"]?.string, lastToolName: t["lastToolName"]?.string, usage: taskUsage(t["usage"]),
                summary: t["summary"]?.string, outputFile: t["outputFile"]?.string, error: t["error"]?.string))
        case "progress":
            guard let id else { return nil }
            return .progress(taskId: id, activity: value["activity"]?.string, lastToolName: value["lastToolName"]?.string,
                             usage: taskUsage(value["usage"]))
        case "updated":
            guard let id else { return nil }
            return .updated(taskId: id, status: value["status"]?.string.flatMap(AgentTask.Status.init(rawValue:)),
                            isBackgrounded: value["isBackgrounded"]?.bool, error: value["error"]?.string)
        case "finished":
            guard let id, let status = value["status"]?.string.flatMap(AgentTask.Status.init(rawValue:)) else { return nil }
            return .finished(taskId: id, status: status, summary: value["summary"]?.string,
                             outputFile: value["outputFile"]?.string, usage: taskUsage(value["usage"]))
        default:
            return nil
        }
    }

    static func encodeTask(_ event: TaskEvent) -> JSONValue {
        var o: [String: JSONValue] = [:]
        func set(_ key: String, _ value: String?) { if let value { o[key] = .string(value) } }
        switch event {
        case let .started(task):
            o["kind"] = .string("started")
            var t: [String: JSONValue] = ["id": .string(task.id), "kind": .string(task.kind.rawValue),
                                          "description": .string(task.description), "isBackgrounded": .bool(task.isBackgrounded),
                                          "ownedBySubagent": .bool(task.ownedBySubagent), "status": .string(task.status.rawValue)]
            for (key, value) in [("toolUseId", task.toolUseId), ("subagentType", task.subagentType), ("prompt", task.prompt),
                                 ("activity", task.activity), ("lastToolName", task.lastToolName), ("summary", task.summary),
                                 ("outputFile", task.outputFile), ("error", task.error)] {
                if let value { t[key] = .string(value) }
            }
            if let usage = encodeTaskUsage(task.usage) { t["usage"] = usage }
            o["task"] = .object(t)
        case let .progress(id, activity, lastToolName, usage):
            o["kind"] = .string("progress"); set("taskId", id); set("activity", activity); set("lastToolName", lastToolName)
            if let usage = encodeTaskUsage(usage) { o["usage"] = usage }
        case let .updated(id, status, backgrounded, error):
            o["kind"] = .string("updated"); set("taskId", id); set("status", status?.rawValue); set("error", error)
            if let backgrounded { o["isBackgrounded"] = .bool(backgrounded) }
        case let .finished(id, status, summary, outputFile, usage):
            o["kind"] = .string("finished"); set("taskId", id); set("status", status.rawValue); set("summary", summary)
            set("outputFile", outputFile)
            if let usage = encodeTaskUsage(usage) { o["usage"] = usage }
        }
        return .object(o)
    }

    static func compaction(_ value: JSONValue) -> CompactionEvent? {
        let trigger = value["trigger"]?.string.flatMap(CompactionTrigger.init(rawValue:))
        switch value["kind"]?.string {
        case "started": return .started(trigger)
        case "finished":
            let r = value["result"] ?? .null
            return .finished(CompactionResult(tokensBefore: r["tokensBefore"]?.int, tokensAfter: r["tokensAfter"]?.int,
                                              contextWindow: r["contextWindow"]?.int, summary: r["summary"]?.string),
                             trigger: trigger, durationMs: value["durationMs"]?.int)
        case "failed": return value["message"]?.string.map(CompactionEvent.failed)
        default: return nil
        }
    }

    static func encodeCompaction(_ event: CompactionEvent) -> JSONValue {
        switch event {
        case let .started(trigger):
            return .object(["kind": .string("started")].merging(trigger.map { ["trigger": .string($0.rawValue)] } ?? [:]) { $1 })
        case let .finished(result, trigger, durationMs):
            var o: [String: JSONValue] = ["kind": .string("finished"), "result": encodeCodable(result)]
            if let trigger { o["trigger"] = .string(trigger.rawValue) }
            if let durationMs { o["durationMs"] = .number(Double(durationMs)) }
            return .object(o)
        case let .failed(message):
            return .object(["kind": .string("failed"), "message": .string(message)])
        }
    }
}
