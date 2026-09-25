import Foundation

/// OpenCode's non-interactive CLI. Each `run` is one turn; `--session` resumes
/// the same conversation on the next turn. The JSON stream shape was checked
/// against OpenCode 1.18.18.
public struct OpenCodeProvider: ProviderDefinition {
    public var id: String { "opencode" }
    public var name: String { "OpenCode" }
    public var logoAsset: String { "ProviderOpenCode" }
    public var binary: String { "opencode" }
    public var detectArgs: [String] { ["--version"] }
    public var followUpMode: FollowUpMode { .respawn }

    public init() {}

    public func buildLaunch(_ ctx: LaunchContext) -> LaunchSpec {
        launchSpec(ctx, resumeId: nil)
    }

    public func buildResume(_ ctx: LaunchContext, resumeId: String) -> LaunchSpec {
        launchSpec(ctx, resumeId: resumeId)
    }

    private func launchSpec(_ ctx: LaunchContext, resumeId: String?) -> LaunchSpec {
        let override = ctx.binaryOverride?.trimmingCharacters(in: .whitespaces)
        // `run` has no approval channel. Without --auto, OpenCode applies its
        // configured permission rules, rejecting requests that need a prompt.
        // Only Full autonomy opts into automatically approving those requests.
        let auto = ctx.permissionPolicy == .bypass ? ["--auto"] : []
        let prompt = (ctx.outputStyle.instructions.map { $0 + "\n\n" } ?? "") + ctx.prompt
        return LaunchSpec(
            command: override.flatMap { $0.isEmpty ? nil : $0 } ?? binary,
            // OpenCode finds its project from the inherited PWD, not the
            // process's working directory, so the worktree is named outright.
            args: ["run", "--format", "json", "--thinking", "--dir", ctx.cwd] + auto
                + (resumeId.map { ["--session", $0] } ?? [])
                + (ctx.model.map { ["--model", $0] } ?? [])
                + (ctx.effort.map { ["--variant", $0] } ?? [])
                + ctx.images.flatMap { ["--file", $0] }
                + ctx.extraArgs
                + (prompt.hasPrefix("-") ? ["--", prompt] : [prompt]),
            cwd: ctx.cwd,
            keepStdinOpen: false
        )
    }

    /// `run` can't ask Abstract, so a request OpenCode's own rules would ask
    /// about is declined, unless Full autonomy approves it.
    public func permissionDetail(_ policy: PermissionPolicy) -> String {
        policy == .bypass ? "OpenCode approves anything its own rules don't deny. Only for trusted tasks."
            : "OpenCode's own permission rules apply; anything they would ask about is declined."
    }

    public func makeParser() -> OutputParser { OpenCodeParser() }
    public func buildUserMessage(_ text: String) -> String? { nil }
    public func buildPermissionResponse(requestId: String, allow: Bool, input: JSONValue?) -> String? { nil }
    public func configuredDefaultModel(home: String) -> String? {
        guard let data = FileManager.default.contents(atPath: home + "/.config/opencode/opencode.json"),
              let json = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        return json["model"]?.string
    }

    public var fallbackModels: ModelCatalog { .empty }

    public func discoverModels(executor: any Executor, binary: String?) async -> ModelCatalog? {
        let command = binary.flatMap { $0.isEmpty ? nil : $0 } ?? self.binary
        guard let result = try? await executor.run(command, ["models", "--verbose"], cwd: nil), result.ok else { return nil }
        return Self.modelCatalog(from: result.stdout)
    }

    /// `opencode models --verbose` prints an ID line followed by a pretty JSON
    /// object for each model. Variants become the effort choices shown by the UI.
    static func modelCatalog(from output: String) -> ModelCatalog? {
        var models: [ModelOption] = []
        var id: String?
        var jsonLines: [String] = []
        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if id == nil {
                let candidate = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if candidate.contains("/"), !candidate.contains(" "), !candidate.hasPrefix("{") { id = candidate }
                continue
            }
            jsonLines.append(line)
            guard let object = try? JSONDecoder().decode(JSONValue.self, from: Data(jsonLines.joined(separator: "\n").utf8)),
                  object.object != nil, let modelId = id else { continue }
            let variants = object["variants"]?.object ?? [:]
            let efforts = variants.compactMap { key, value in
                value["reasoningEffort"]?.string != nil ? key : nil
            }.sorted { (effortOrder($0), $0) < (effortOrder($1), $1) }
            models.append(ModelOption(id: modelId, label: object["name"]?.string ?? modelId,
                                      efforts: efforts))
            id = nil
            jsonLines = []
        }
        return models.isEmpty ? nil : ModelCatalog(models: models)
    }

    private static func effortOrder(_ value: String) -> Int {
        ["none", "minimal", "low", "medium", "high", "xhigh", "max"].firstIndex(of: value) ?? 100
    }
}

/// OpenCode `run --format json` events contain complete parts. Unknown lines
/// remain in the log so a newer CLI can still be inspected after a relaunch.
final class OpenCodeParser: OutputParser {
    private var sessionId: String?
    private var seenTools: Set<String> = []
    private var finishedTools: Set<String> = []

    func feed(_ line: String, stream: OutputStreamKind) -> [AgentEvent] {
        guard stream == .stdout,
              let object = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)),
              let type = object["type"]?.string else { return [.raw(line: line, stream: stream)] }
        var events: [AgentEvent] = []
        if let id = object["sessionID"]?.string, id != sessionId {
            sessionId = id
            events.append(.sessionId(id))
        }
        let part = object["part"]
        switch type {
        case "step_start":
            events.append(.status(.running, detail: nil))
        case "text":
            if let text = part?["text"]?.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                events.append(.text(role: .assistant, text: text, blockId: part?["id"]?.string, partial: false))
            }
        case "reasoning":
            if let text = part?["text"]?.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                events.append(.thinking(text: text, blockId: part?["id"]?.string, partial: false))
            }
        case "tool_use":
            guard let tool = part?["tool"]?.string, let id = part?["callID"]?.string else {
                return events + [.raw(line: line, stream: stream)]
            }
            let state = part?["state"]
            if seenTools.insert(id).inserted {
                events.append(.toolUse(id: id, name: tool, input: state?["input"] ?? .object([:]), edit: nil))
            }
            if let status = state?["status"]?.string,
               (status == "completed" || status == "error"), finishedTools.insert(id).inserted {
                events.append(.toolResult(toolUseId: id, output: state?["output"]?.string
                                          ?? state?["error"]?.string ?? "", isError: status == "error", edit: nil))
            }
        case "step_finish":
            let tokens = part?["tokens"]
            events.append(.usage(UsageTotals(inputTokens: tokens?["input"]?.int ?? 0,
                                             outputTokens: tokens?["output"]?.int ?? 0,
                                             cacheRead: tokens?["cache"]?["read"]?.int ?? 0,
                                             cacheWrite: tokens?["cache"]?["write"]?.int ?? 0),
                                 costUsd: part?["cost"]?.double, durationMs: nil, turns: nil))
        case "error":
            events.append(.error(object["error"]?["message"]?.string ?? object["message"]?.string ?? "OpenCode reported an error"))
            events.append(.status(.errored, detail: nil))
        default:
            events.append(.raw(line: line, stream: stream))
        }
        return events
    }

    func onExit(code: Int32?) -> [AgentEvent] {
        if code == 0 { return [.status(.finished, detail: nil)] }
        return [.error("opencode exited with code \(code.map(String.init) ?? "null")"), .status(.errored, detail: nil)]
    }
}
