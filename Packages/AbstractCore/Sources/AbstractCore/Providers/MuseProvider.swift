import Foundation
import Synchronization

/// Muse Code's headless JSONL stream. Each `exec` is one turn; `--session-id`
/// continues the CLI's retained session on the next turn.
public struct MuseProvider: ProviderDefinition {
    public var id: String { "muse" }
    public var name: String { "Muse Code" }
    public var logoAsset: String { "ProviderMuse" }
    public var binary: String { "muse" }
    public var detectArgs: [String] { ["--version"] }
    public var followUpMode: FollowUpMode { .respawn }

    public init() {}

    public func buildLaunch(_ ctx: LaunchContext) -> LaunchSpec { launch(ctx, resumeId: nil) }
    public func buildResume(_ ctx: LaunchContext, resumeId: String) -> LaunchSpec { launch(ctx, resumeId: resumeId) }

    private func launch(_ ctx: LaunchContext, resumeId: String?) -> LaunchSpec {
        let selectedBinary = ctx.binaryOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = (ctx.outputStyle.instructions.map { $0 + "\n\n" } ?? "") + ctx.prompt
        let policy: [String] = switch ctx.permissionPolicy {
        // Headless exec cannot relay approval prompts to Abstract. Leave the
        // sandbox on and never turn a held request into an implicit approval.
        case .ask: ["--approval-mode", "on-request", "--approval-judge", "off",
                    "--disable-write", "--disable-shell"]
        case .autoEdits: ["--approval-mode", "untrusted", "--approval-judge", "off"]
        case .bypass: ["--yolo"]
        }
        return LaunchSpec(
            command: selectedBinary.flatMap { $0.isEmpty ? nil : $0 } ?? binary,
            args: ["exec", "--json", "--workspace", ctx.cwd] + policy
                + (resumeId.map { ["--session-id", $0] } ?? [])
                + (ctx.model.map { ["--model", $0] } ?? [])
                + (ctx.effort.map { ["--reasoning-effort", $0] } ?? [])
                + ctx.images.flatMap { ["--image", $0] }
                + ctx.extraArgs
                + (prompt.hasPrefix("-") ? ["--", prompt] : [prompt]),
            cwd: ctx.cwd,
            keepStdinOpen: false
        )
    }

    public func permissionDetail(_ policy: PermissionPolicy) -> String {
        switch policy {
        case .ask: "Muse Code is read-only here because its file edits do not ask for approval. Abstract cannot answer an approval request; use the Muse Code terminal for that."
        case .autoEdits: "Muse Code may edit the worktree. Abstract cannot answer a command approval here; stop the turn and use the Muse Code terminal."
        case .bypass: "Muse Code runs without approval or a sandbox. Only for trusted tasks."
        }
    }

    public func makeParser() -> OutputParser { MuseParser() }
    public func buildUserMessage(_ text: String) -> String? { nil }
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

/// `muse exec --json` writes journal envelopes, not the interactive MSP frames.
/// Keep unfamiliar records raw so a later CLI version remains inspectable.
final class MuseParser: OutputParser {
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
