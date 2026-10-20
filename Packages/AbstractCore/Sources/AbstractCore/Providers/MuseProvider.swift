import Foundation
import Synchronization

/// Muse Code, driven over `muse serve`: the MSP session host is the only
/// surface that carries each tool call's real arguments, status and output
/// as it happens (docs/spikes/ABS-88.md). One host process stays alive for
/// the chat; a relaunch resumes its retained session by id. The naming
/// one-off still uses `exec`, which is all that call needs.
public struct MuseProvider: ProviderDefinition {
    public var id: String { "muse" }
    public var name: String { "Muse Code" }
    public var logoAsset: String { "ProviderMuse" }
    public var binary: String { "muse" }
    public var detectArgs: [String] { ["--version"] }
    public var followUpMode: FollowUpMode { .stdin }

    public init() {}

    public func buildLaunch(_ ctx: LaunchContext) -> LaunchSpec { launch(ctx, resumeId: nil) }
    public func buildResume(_ ctx: LaunchContext, resumeId: String) -> LaunchSpec { launch(ctx, resumeId: resumeId) }

    private func launch(_ ctx: LaunchContext, resumeId: String?) -> LaunchSpec {
        let selectedBinary = ctx.binaryOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
        let mode = switch ctx.permissionPolicy {
        case .plan: Plan.instruction
        case .readOnly: Plan.readOnlyInstruction
        default: nil as String?
        }
        let prompt = (ctx.outputStyle.instructions.map { $0 + "\n\n" } ?? "")
            + (mode.map { $0 + "\n\n" } ?? "") + ctx.prompt
        // The host's sandbox posture is fixed by launch flags; what may run
        // without asking is chosen on the wire. Abstract still cannot answer
        // an approval, so nothing is left waiting for one: unmatched work is
        // denied, never held. Same reach as the old exec mapping.
        let flags: [String] = switch ctx.permissionPolicy {
        case .ask, .plan, .readOnly: ["--disable-write", "--disable-shell"]
        case .autoEdits: []
        case .bypass: ["--disable-sandbox"]
        }
        let approvalMode = ctx.permissionPolicy == .bypass ? "allowAll" : "denyUnmatched"
        // The client mints the session id, so the first turn can be sent by
        // the parser the moment the host confirms the session is loaded.
        let sessionId = resumeId ?? MuseWire.newId()
        MusePendingTurns.register(MuseServeTurn(prompt: prompt, model: ctx.model,
                                                  effort: ctx.effort, images: ctx.images),
                                  for: sessionId)
        let session: String
        if resumeId != nil {
            session = MuseWire.request(id: 2, method: "session/resume", params: .object([
                "commandId": .string(MuseWire.newId()), "sessionId": .string(sessionId),
                // Abstract's own log is the transcript; history would repeat it.
                "excludeItems": .bool(true),
            ]))
        } else {
            var params: [String: JSONValue] = [
                "commandId": .string(MuseWire.newId()), "sessionId": .string(sessionId),
                "workspaceRoot": .string(ctx.cwd), "approvalMode": .string(approvalMode),
            ]
            if let model = ctx.model { params["modelId"] = .string(model) }
            session = MuseWire.request(id: 2, method: "session/start", params: .object(params))
        }
        return LaunchSpec(
            command: selectedBinary.flatMap { $0.isEmpty ? nil : $0 } ?? binary,
            args: ["serve", "--trust-workspace"] + flags + ctx.extraArgs,
            cwd: ctx.cwd,
            stdinInitial: MuseWire.request(id: 1, method: "initialize", params: .object([
                "clientInfo": .object(["name": .string("abstract"), "version": .string("0.0.0")]),
            ])) + MuseWire.notification("initialized") + session,
            keepStdinOpen: true
        )
    }

    public func permissionDetail(_ policy: PermissionPolicy) -> String {
        switch policy {
        case .ask: "Muse Code is read-only here because its file edits do not ask for approval. Abstract cannot answer an approval request; use the Muse Code terminal for that."
        case .autoEdits: "Muse Code may edit the worktree. Abstract cannot answer a command approval here; stop the turn and use the Muse Code terminal."
        case .bypass: "Muse Code runs without approval or a sandbox. Only for trusted tasks."
        case .plan: "Muse Code is read-only and writes a plan. Nothing changes until you approve it."
        case .readOnly: "Muse Code is read-only: it can look and answer, but can't change anything."
        }
    }

    public func makeParser() -> OutputParser { MuseParser() }
    public func buildUserMessage(_ text: String) -> String? { nil }
    public func buildUserMessage(_ text: String, images: [String], sessionId: String?) -> String? {
        // Without the session's own id there is nowhere to send the turn;
        // the caller relaunches instead, which resumes it.
        guard let sessionId, !sessionId.isEmpty else { return nil }
        return MuseWire.turnStart(sessionId: sessionId, turn: MuseServeTurn(prompt: text, images: images))
    }
    public func buildPermissionResponse(requestId: String, allow: Bool, input: JSONValue?) -> String? { nil }

    public var fallbackModels: ModelCatalog {
        ModelCatalog(models: [ModelOption(id: "muse-wonder-1.0", label: "Muse Wonder")])
    }

    public func discoverModels(executor: any Executor, binary: String?) async -> ModelCatalog? {
        await MuseModelDiscovery.lookup(executor: executor, binary: binary ?? self.binary)
    }

    public func configuredDefaultModel(home: String) -> String? {
        guard let data = FileManager.default.contents(atPath: home + "/.config/muse/settings.json"),
              let settings = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        return settings["model"]?.string
    }

    public func namingLaunch(prompt: String, home: String, binary: String?, model: String?) -> LaunchSpec? {
        LaunchSpec(command: binary ?? self.binary,
                   args: ["exec", "--json", "--preset", "empty", "--no-session-log", "--disable-shell",
                          "--disable-write", "--disable-web-tools", "--no-foreign-personal-context",
                          "--disable-reminders", "--max-model-steps", "1", "--workspace", home]
                       + (model.map { ["--model", $0] } ?? [])
                       + (prompt.hasPrefix("-") ? ["--", prompt] : [prompt]),
                   cwd: home, keepStdinOpen: false)
    }

    public func namingAnswer(_ output: String) -> String? {
        output.split(separator: "\n").compactMap { line -> String? in
            guard let event = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)),
                  event["payload_type"]?.string == "run.terminal.completed" else { return nil }
            return event["payload"]?["text"]?.string
        }.last
    }

    public func namingError(_ output: String) -> String? {
        output.split(separator: "\n").compactMap { line -> String? in
            guard let event = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)),
                  event["payload_type"]?.string == "run.terminal.failed" else { return nil }
            return event["payload"]?["reason"]?.string
        }.last
    }

    public func namingCheck(home: String, binary: String?) -> LaunchSpec? {
        LaunchSpec(command: binary ?? self.binary, args: ["exec", "--help"], cwd: home, keepStdinOpen: false)
    }

    public func namingCheckPasses(_ output: String) -> Bool {
        ["--preset", "--no-session-log", "--disable-shell", "--disable-write", "--disable-web-tools"]
            .allSatisfy(output.contains)
    }
}

/// One turn to send once its session is loaded on the host.
struct MuseServeTurn: Sendable {
    var prompt: String
    var model: String?
    var effort: String?
    var images: [String] = []
}

/// First turns waiting for their session: `buildLaunch`/`buildResume` cannot
/// include the turn in the launch payload (the host answers requests
/// concurrently, and a turn for a session that is not loaded yet is refused),
/// so the parser sends it when the host confirms the session. Keyed by the
/// client-minted session id; an entry is only removed once a live parser's
/// queued turn is actually drained, so replaying the log in the same process
/// cannot spend it.
enum MusePendingTurns {
    private static let turns = Mutex<[String: MuseServeTurn]>([:])
    static func register(_ turn: MuseServeTurn, for sessionId: String) {
        turns.withLock { $0[sessionId] = turn }
    }
    static func peek(_ sessionId: String) -> MuseServeTurn? {
        turns.withLock { $0[sessionId] }
    }
    static func remove(_ sessionId: String) {
        turns.withLock { $0[sessionId] = nil }
    }
}

/// The MSP wire lines Muse chats are driven with.
enum MuseWire {
    /// A UUIDv7, as the host requires of its command and session ids.
    static func newId() -> String {
        var ms = UInt64(Date().timeIntervalSince1970 * 1000)
        var bytes = (0..<16).map { _ in UInt8.random(in: .min ... .max) }
        for i in stride(from: 5, through: 0, by: -1) { bytes[i] = UInt8(ms & 0xff); ms >>= 8 }
        bytes[6] = (bytes[6] & 0x0f) | 0x70
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return [hex.prefix(8), hex.dropFirst(8).prefix(4), hex.dropFirst(12).prefix(4),
                hex.dropFirst(16).prefix(4), hex.dropFirst(20)].joined(separator: "-")
    }

    static func request(id: Int, method: String, params: JSONValue) -> String {
        JSONValue.object(["jsonrpc": .string("2.0"), "id": .number(Double(id)),
                          "method": .string(method), "params": params]).compact() + "\n"
    }

    static func notification(_ method: String) -> String {
        JSONValue.object(["jsonrpc": .string("2.0"), "method": .string(method)]).compact() + "\n"
    }

    static func turnStart(sessionId: String, turn: MuseServeTurn) -> String {
        var parts = turn.images.compactMap { path -> JSONValue? in
            guard let media = ImageMedia.type(ofPath: path),
                  let data = FileManager.default.contents(atPath: path) else { return nil }
            return .object(["type": .string("image"), "mediaType": .string(media),
                            "base64Data": .string(data.base64EncodedString())])
        }
        parts.append(.object(["type": .string("text"), "text": .string(turn.prompt)]))
        var params: [String: JSONValue] = [
            "commandId": .string(newId()), "sessionId": .string(sessionId), "input": .array(parts),
        ]
        if let effort = turn.effort,
           ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"].contains(effort) {
            params["reasoningEffort"] = .string(effort)
        }
        return request(id: 3, method: "turn/start", params: .object(params))
    }

    static func setModel(sessionId: String, model: String) -> String {
        request(id: 4, method: "session/setModel", params: .object([
            "commandId": .string(newId()), "sessionId": .string(sessionId),
            "model": .object(["modelId": .string(model)]),
        ]))
    }
}

/// Reads both Muse streams: `muse serve` view items for chats, and the older
/// `muse exec --json` journal still sitting in existing chats' logs (and
/// still produced by the naming one-off's parser checks in tests). Dispatch
/// is per line, so a log that crosses the change folds whole.
final class MuseParser: InputDrivingParser {
    private let exec = MuseExecParser()
    private let serve = MuseServeParser()

    func feed(_ line: String, stream: OutputStreamKind) -> [AgentEvent] {
        if stream == .stdout,
           let value = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)),
           value["payload_type"]?.string == nil,
           value["method"]?.string != nil || value["jsonrpc"]?.string != nil {
            return serve.feed(line, stream: stream)
        }
        if stream == .stderr { serve.noteStderr(line) }
        return exec.feed(line, stream: stream)
    }

    func takePendingInput() -> [String] { serve.takePendingInput() }

    func onExit(code: Int32?) -> [AgentEvent] {
        serve.sawServe ? serve.onExit(code: code) : exec.onExit(code: code)
    }
}

/// The `muse serve` view stream folded into agent events. Items arrive by
/// revision (replace if higher), a completed item may never have been
/// started, and output streams as deltas before the item settles.
final class MuseServeParser: InputDrivingParser {
    private(set) var sawServe = false
    private var sessionId: String?
    private var turnActive = false
    private var turnFinished = false
    private var lastError: String?
    private var pendingInput: [String] = []
    /// The session whose registered first turn is sitting in `pendingInput`.
    private var pendingSession: String?
    private var queuedFirstTurn = false

    private struct Call {
        var revision = 0
        var emittedUse = false
        var emittedResult = false
    }
    private var calls: [String: Call] = [:]
    /// Streamed tool output by item id, until the item's final form lands.
    private var outputText: [String: String] = [:]
    /// Streamed reply text by item id, so a completion with no text of its
    /// own still carries what streamed.
    private var replyText: [String: String] = [:]

    func noteStderr(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { lastError = trimmed }
    }

    func takePendingInput() -> [String] {
        defer { pendingInput = [] }
        if let pendingSession { MusePendingTurns.remove(pendingSession); self.pendingSession = nil }
        return pendingInput
    }

    func feed(_ line: String, stream: OutputStreamKind) -> [AgentEvent] {
        sawServe = true
        guard let msg = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)) else {
            return [.raw(line: line, stream: stream)]
        }
        if let method = msg["method"]?.string {
            return notification(method, msg["params"], line: line)
        }
        if let id = msg["id"]?.int {
            return reply(id: id, msg: msg)
        }
        return [.raw(line: line, stream: stream)]
    }

    private func reply(id: Int, msg: JSONValue) -> [AgentEvent] {
        if let error = msg["error"] {
            let message = error["message"]?.string ?? "Muse Code refused a request."
            switch id {
            case 1: return [.error("Muse Code could not start: \(message)"), .status(.errored, detail: nil)]
            case 2: return [.error(Self.friendly(message)), .status(.errored, detail: nil)]
            case 3: return [.error(Self.friendly(message)), .status(.errored, detail: nil)]
            default: return []
            }
        }
        guard id == 2, let session = msg["result"]?["session"],
              let id2 = session["sessionId"]?.string else { return [] }
        var out: [AgentEvent] = []
        if sessionId != id2 {
            sessionId = id2
            out.append(.sessionId(id2))
        }
        let pending = MusePendingTurns.peek(id2)
        out.append(.system(model: pending?.model ?? session["modelId"]?.string,
                           cwd: session["workspaceRoot"]?.string, permissionMode: nil, sessionId: id2))
        // The session is loaded: the first turn may go now, and only now.
        if let pending, !queuedFirstTurn {
            queuedFirstTurn = true
            pendingSession = id2
            if let model = pending.model, model != session["modelId"]?.string {
                pendingInput.append(MuseWire.setModel(sessionId: id2, model: model))
            }
            pendingInput.append(MuseWire.turnStart(sessionId: id2, turn: pending))
        }
        return out
    }

    private func notification(_ method: String, _ params: JSONValue?, line: String) -> [AgentEvent] {
        switch method {
        case "session/started":
            guard let id = params?["session"]?["sessionId"]?.string, id != sessionId else { return [] }
            sessionId = id
            return [.sessionId(id)]
        case "turn/started":
            turnActive = true
            return [.status(.running, detail: nil)]
        case "turn/completed":
            turnActive = false
            turnFinished = true
            let duration = params?["durationMs"]?.int
            switch params?["terminal"]?.string {
            case "failed":
                let reason = params?["reason"]?.string ?? "Muse Code could not finish this turn."
                return [.error(Self.friendly(reason)), .status(.errored, detail: nil)]
            default:
                return [.turnEnd(durationMs: duration, costUsd: nil, usage: nil, summary: nil),
                        .status(.idle, detail: nil)]
            }
        case "item/started", "item/updated", "item/completed":
            guard let item = params?["item"] else { return [.raw(line: line, stream: .stdout)] }
            return fold(item, completed: method == "item/completed", line: line)
        case "item/delta":
            guard let itemId = params?["itemId"]?.string, let delta = params?["delta"]?.string else { return [] }
            switch params?["field"]?.string {
            case "text":
                replyText[itemId, default: ""] += delta
                return delta.isEmpty ? [] : [.text(role: .assistant, text: delta, blockId: itemId, partial: true)]
            case "output":
                outputText[itemId, default: ""] += delta
                return []
            default:
                return []
            }
        case "session/statusChanged", "session/tokenUsage", "session/contextUsage",
             "session/approvalModeChanged", "session/modelChanged", "session/reasoningEffortChanged",
             "session/listChanged", "session/closed", "turn/foregroundCompleted",
             "approval/request", "approval/resolved", "approval/updated", "approval/reviewing":
            // Bookkeeping the chat does not read. Approvals: the modes
            // Abstract sets never hold a call for one.
            return []
        default:
            return [.raw(line: line, stream: .stdout)]
        }
    }

    private func fold(_ item: JSONValue, completed: Bool, line: String) -> [AgentEvent] {
        switch item["kind"]?.string {
        case "toolCall", "webSearch":
            return foldTool(item)
        case "agentMessage":
            guard completed, let itemId = item["itemId"]?.string else { return [] }
            let text = item["text"]?.string ?? replyText[itemId] ?? ""
            replyText[itemId] = nil
            return text.isEmpty ? [] : [.text(role: .assistant, text: text, blockId: itemId, partial: false)]
        case "userMessage", "hookRun", "reminderChild":
            // Yours is logged by Abstract itself; the rest is the host's own work.
            return []
        default:
            return completed ? [.raw(line: line, stream: .stdout)] : []
        }
    }

    private func foldTool(_ item: JSONValue) -> [AgentEvent] {
        guard let itemId = item["itemId"]?.string else { return [] }
        let callId = item["callId"]?.string ?? itemId
        let revision = item["revision"]?.int ?? 0
        var call = calls[callId] ?? Call()
        if call.emittedUse, revision < call.revision { return [] }
        call.revision = max(call.revision, revision)
        var out: [AgentEvent] = []
        if !call.emittedUse {
            call.emittedUse = true
            let isSearch = item["kind"]?.string == "webSearch"
            let name = item["tool"]?.string ?? (isSearch ? "web_search" : "tool")
            var input = Self.parseArgs(item["args"]?.string)
            if isSearch, input.object?.isEmpty != false, let query = item["query"]?.string {
                input = .object(["query": .string(query)])
            }
            out.append(.toolUse(id: callId, name: name, input: input, edit: nil))
        }
        let status = item["status"]?.string
        if ["completed", "failed", "cancelled", "rejected", "timedOut"].contains(status), !call.emittedResult {
            call.emittedResult = true
            let output = item["visibleOutput"]?.string ?? outputText[itemId]
                ?? item["failureReason"]?.string ?? ""
            outputText[itemId] = nil
            out.append(.toolResult(toolUseId: callId, output: output,
                                   isError: status != "completed", edit: nil))
        }
        calls[callId] = call
        return out
    }

    /// Tool arguments ride as a verbatim string: the model's own JSON when it
    /// parses, an empty object when it does not. A target is never guessed
    /// out of result prose.
    private static func parseArgs(_ args: String?) -> JSONValue {
        guard let args, let value = try? JSONDecoder().decode(JSONValue.self, from: Data(args.utf8))
        else { return .object([:]) }
        return value
    }

    static func friendly(_ message: String) -> String {
        if message.localizedCaseInsensitiveContains("does not exist or you lack access") {
            return "Muse Code cannot use this model. Choose another model in the chat. \(message)"
        }
        if message.localizedCaseInsensitiveContains("credential")
            || message.localizedCaseInsensitiveContains("login")
            || message.localizedCaseInsensitiveContains("not signed in") {
            return "Muse Code needs sign-in. Run muse login on this Mac, then try again."
        }
        return message
    }

    func onExit(code: Int32?) -> [AgentEvent] {
        if turnFinished, !turnActive { return [.status(.finished, detail: nil)] }
        if code == 0, sessionId != nil { return [.status(.finished, detail: nil)] }
        let message: String
        if let lastError, lastError.localizedCaseInsensitiveContains("credential")
            || lastError.localizedCaseInsensitiveContains("login") {
            message = "Muse Code needs sign-in. Run muse login on this Mac, then try again."
        } else if let lastError, lastError.localizedCaseInsensitiveContains("model") {
            message = "Muse Code could not use this model: \(lastError) Choose another model in the chat."
        } else if let lastError {
            message = "Muse Code failed: \(lastError)"
        } else {
            message = "Muse Code exited with code \(code.map(String.init) ?? "unknown"). Check the CLI on this Mac."
        }
        return [.error(message), .status(.errored, detail: nil)]
    }
}

/// `muse exec --json` writes journal envelopes, not MSP frames.
/// Keep unfamiliar records raw so a later CLI version remains inspectable.
final class MuseExecParser: OutputParser {
    private var sessionId: String?
    private var finished = false
    private var lastError: String?
    private var toolNames: [String: String] = [:]

    func feed(_ line: String, stream: OutputStreamKind) -> [AgentEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }
        guard stream == .stdout,
              let event = try? JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8)),
              let type = event["payload_type"]?.string else {
            if stream == .stderr { lastError = trimmed }
            return [.raw(line: line, stream: stream)]
        }
        var out: [AgentEvent] = []
        if let id = event["stream"]?["id"]?.string, event["stream"]?["kind"]?.string == "session", id != sessionId {
            sessionId = id
            out.append(.sessionId(id))
        }
        let payload = event["payload"]
        switch type {
        case "run.model.configured":
            out.append(.system(model: payload?["model_id"]?.string, cwd: nil, permissionMode: nil, sessionId: sessionId))
        case "run.lifecycle.started":
            out.append(.status(.running, detail: nil))
        case "task.lifecycle.proposed":
            if let taskId = payload?["task_id"]?.string,
               let kind = payload?["event"]?["task_kind"]?.string, kind.hasPrefix("tool.") {
                toolNames[taskId] = String(kind.dropFirst("tool.".count))
            }
            out.append(.raw(line: line, stream: stream))
        case "task.lifecycle.scheduled":
            if let taskId = payload?["task_id"]?.string, let name = toolNames[taskId],
               let key = payload?["event"]?["idempotency_key"]?.string, key.hasPrefix("tool:") {
                out.append(.toolUse(id: String(key.dropFirst("tool:".count)), name: name,
                                    input: .object([:]), edit: nil))
            } else { out.append(.raw(line: line, stream: stream)) }
        case "tool.result":
            if let callId = payload?["call_id"]?.string {
                let outcome = payload?["correlation_facts"]?["outcome"]?.string
                out.append(.toolResult(toolUseId: callId, output: payload?["text"]?.string ?? "",
                                       isError: outcome == "failure" || outcome == "error", edit: nil))
            } else { out.append(.raw(line: line, stream: stream)) }
        case "run.output.delta":
            if let text = payload?["text"]?.string, !text.isEmpty {
                out.append(.text(role: .assistant, text: text, blockId: payload?["run_stream"]?["id"]?.string, partial: true))
            }
        case "run.terminal.completed":
            finished = true
            if let text = payload?["text"]?.string, !text.isEmpty {
                out.append(.text(role: .assistant, text: text, blockId: payload?["run_stream"]?["id"]?.string, partial: false))
            }
            out.append(.turnEnd(durationMs: nil, costUsd: nil, usage: nil, summary: nil))
            out.append(.status(.finished, detail: nil))
        case "run.terminal.failed", "run.terminal.cancelled":
            finished = true
            let reason = payload?["reason"]?.string ?? payload?["text"]?.string ?? "Muse Code could not finish this turn."
            if reason.localizedCaseInsensitiveContains("does not exist or you lack access") {
                out.append(.error("Muse Code cannot use this model. Choose another model in the chat. \(reason)"))
            } else {
                out.append(.error(reason))
            }
            out.append(.status(.errored, detail: nil))
        default:
            out.append(.raw(line: line, stream: stream))
        }
        return out
    }

    func onExit(code: Int32?) -> [AgentEvent] {
        if finished { return [] }
        if code == 0 { return [.status(.finished, detail: nil)] }
        let message: String
        if let lastError, lastError.localizedCaseInsensitiveContains("credential")
            || lastError.localizedCaseInsensitiveContains("login") {
            message = "Muse Code needs sign-in. Run muse login on this Mac, then try again."
        } else if let lastError, lastError.localizedCaseInsensitiveContains("model") {
            message = "Muse Code could not use this model: \(lastError) Choose another model in the chat."
        } else if let lastError {
            message = "Muse Code failed: \(lastError)"
        } else {
            message = "Muse Code exited with code \(code.map(String.init) ?? "unknown"). Check the CLI on this Mac."
        }
        return [.error(message), .status(.errored, detail: nil)]
    }
}

/// Query the CLI's own account catalog. In particular, Wonder Full appears
/// only if `model/list` actually includes it for the signed-in account.
enum MuseModelDiscovery {
    static func lookup(executor: any Executor, binary: String) async -> ModelCatalog? {
        let gate = MuseModelProbe()
        let timer = Task {
            try? await Task.sleep(for: .seconds(12))
            gate.finish(nil)
        }
        defer { timer.cancel() }
        return await withCheckedContinuation { continuation in
            gate.arm(continuation)
            do {
                let process = try executor.spawn(
                    LaunchSpec(command: binary, args: ["serve"], cwd: executor.homeDirectory, keepStdinOpen: true),
                    onLine: { line in gate.receive(line) },
                    onExit: { _ in gate.finish(nil) }
                )
                gate.attach(process)
                try process.write(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"abstract","version":"0.0.0"}}}"# + "\n")
            } catch { gate.finish(nil) }
        }
    }

    static func catalog(_ line: String) -> ModelCatalog? {
        guard let reply = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)),
              reply["id"]?.int == 2, let rows = reply["result"]?["models"]?.array else { return nil }
        let models = rows.compactMap { row -> ModelOption? in
            guard let id = row["modelId"]?.string, !id.isEmpty else { return nil }
            let efforts = row["variants"]?.array?.compactMap(\.string) ?? []
            let label = switch id {
            case "muse-wonder-1.0": "Muse Wonder"
            case "muse-wonder-full-1.0": "Muse Wonder Full"
            default: row["displayLabel"]?.string ?? id
            }
            return ModelOption(id: id, label: label,
                               detail: row["description"]?.string, efforts: efforts,
                               defaultEffort: row["defaultReasoningEffort"]?.string)
        }
        guard !models.isEmpty else { return nil }
        let offered = models.contains { $0.id == "muse-wonder-1.0" }
            ? models : [ModelOption(id: "muse-wonder-1.0", label: "Muse Wonder")] + models
        return ModelCatalog(accountDefault: models.first { model in
            rows.contains { $0["modelId"]?.string == model.id && $0["isDefault"]?.bool == true }
        }, models: offered)
    }
}

private final class MuseModelProbe: Sendable {
    private struct State {
        var continuation: CheckedContinuation<ModelCatalog?, Never>?
        var process: (any RunningProcess)?
        var initialized = false
        var done = false
    }
    private let state = Mutex(State())

    func arm(_ continuation: CheckedContinuation<ModelCatalog?, Never>) {
        state.withLock { $0.continuation = continuation }
    }

    func attach(_ process: any RunningProcess) {
        let result = state.withLock { state -> (Bool, Bool) in
            state.process = process
            return (state.done, state.initialized)
        }
        if result.0 { process.terminate() }
        else if result.1 { requestModels(process) }
    }

    func receive(_ line: OutputLine) {
        guard line.stream == .stdout,
              let reply = try? JSONDecoder().decode(JSONValue.self, from: Data(line.line.utf8)) else { return }
        if reply["id"]?.int == 1 {
            guard reply["result"] != nil else { finish(nil); return }
            let process = state.withLock { state -> (any RunningProcess)? in
                state.initialized = true
                return state.process
            }
            if let process { requestModels(process) }
        } else if reply["id"]?.int == 2 {
            finish(MuseModelDiscovery.catalog(line.line))
        }
    }

    private func requestModels(_ process: any RunningProcess) {
        do {
            try process.write(#"{"jsonrpc":"2.0","method":"initialized"}"# + "\n")
            try process.write(#"{"jsonrpc":"2.0","id":2,"method":"model/list","params":{}}"# + "\n")
        } catch { finish(nil) }
    }

    func finish(_ catalog: ModelCatalog?) {
        let pending = state.withLock { state -> (CheckedContinuation<ModelCatalog?, Never>?, (any RunningProcess)?)? in
            if state.done { return nil }
            state.done = true
            defer { state.continuation = nil }
            return (state.continuation, state.process)
        }
        guard let (continuation, process) = pending else { return }
        continuation?.resume(returning: catalog)
        process?.terminate()
    }
}
