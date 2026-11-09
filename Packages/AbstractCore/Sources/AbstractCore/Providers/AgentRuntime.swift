import Foundation
import JavaScriptCore

// The agent runtime (ABS-185): an agent plugin's script, loaded into a
// JavaScriptCore context of its own inside AbstractCore, behind a
// `ProviderDefinition` the rest of Abstract already knows. The script has no
// DOM, no network, no timers and no file access; it sees only `AbstractAgent`.
// It never spawns anything: it returns launch arguments and stdin lines, and
// folds the lines the host hands it into `AgentEvent`s (AgentEventJSON).
//
// ```js
// AbstractAgent.register({
//   id: "opencode",
//   launch(ctx, resumeId) { return { args: [...], env: {...}, stdin: "...", keepStdinOpen: false }; },
//   parser() { return { feed(lines) { return lines.map(...) }, exit(code) { return [...] }, input() { return [] } }; },
//   message({ text, images, sessionId }) { return "…" },   // prompt.steer
//   permission({ requestId, allow, input }) { … },        // permission
//   catalog() { return { models: [...] } },
//   defaultModel(config) { … },                            // config: the manifest's `config` files by path
//   permissionDetail(policy) { … },
//   naming: { launch({ prompt, home, model, config }), answer(output), error(output), check({ home }), checkPasses(output) },
//   *discoverModels({ binary }) { const r = yield { run: { args: ["models"] } }; … },
//   *compact(request) { … },
// });
// ```
//
// Jobs (`discoverModels`, `compact`) are generators: each `yield` is one
// thing the host does for the script and hands back — run the agent's own
// program (`run`), hold a conversation with it (`converse`), start it and wait
// for a line (`start`, `stop`), or call a server it started on this Mac's
// loopback (`http`).

/// An agent plugin's script, loaded once and shared by all its chats. Every
/// call into it holds one lock: a plugin's chats parse one line at a time
/// between them, another plugin's not at all.
public final class AgentScript: @unchecked Sendable {
    public let pluginId: String
    let folder: URL
    /// What it was loaded from, to load a context of its own for work that
    /// may wait (a line enricher reading the worktree).
    let source: String
    private let lock = NSRecursiveLock()
    private let context: JSContext
    /// Where the launch being built writes its files, while it's built.
    private var configDirectory: String?
    /// The pictures the launch or message being built sends: the only files
    /// the script may read, and only while it's built.
    private var readableImages: Set<String> = []
    public private(set) var loadError: String?

    public init(pluginId: String, folder: URL, source: String) {
        self.pluginId = pluginId
        self.folder = folder
        self.source = source
        context = JSContext()!
        context.name = pluginId
        context.exceptionHandler = { context, exception in context?.exception = exception }
        installHost()
        context.evaluateScript(source, withSourceURL: folder.appendingPathComponent("agent.js"))
        if let exception = context.exception {
            loadError = exception.toString()
            context.exception = nil
        }
    }

    /// `AbstractAgent`: `register`, and pure helpers from the host so every
    /// agent folds the same things the same way.
    private func installHost() {
        context.evaluateScript("""
        var AbstractAgent = { _agents: {}, register: function (agent) { this._agents[agent.id] = agent; } };
        var console = { log: function () {}, warn: function () {}, error: function () {} };
        """)
        let host = context.objectForKeyedSubscript("AbstractAgent")!
        let editPreview: @convention(block) (String, JSValue) -> Any = { name, input in
            let preview = EditPreview.fromToolInput(name: name, input: JSONValue(any: input.toObject()))
            return preview.map { AgentEventJSON.encodeCodable($0).anyObject } ?? NSNull()
        }
        host.setObject(editPreview, forKeyedSubscript: "editPreview" as NSString)
        let unifiedDiff: @convention(block) (String, String) -> String = { EditPreview.unifiedDiff($0, $1) }
        host.setObject(unifiedDiff, forKeyedSubscript: "unifiedDiff" as NSString)
        // JSON as Abstract writes it: sorted keys, slashes as they are.
        let compactJSON: @convention(block) (JSValue) -> String = { JSONValue(any: $0.toObject()).compact() }
        host.setObject(compactJSON, forKeyedSubscript: "compactJSON" as NSString)
        let firstObject: @convention(block) (String) -> Any = { ChatNaming.firstObject(in: $0) ?? NSNull() }
        host.setObject(firstObject, forKeyedSubscript: "firstObject" as NSString)
        // How Abstract reads git and pull request work out of a command's
        // output, and which tool calls are questions for you.
        let gitFromClaude: @convention(block) (JSValue) -> Any = { value in
            GitOperation.claude(JSONValue(any: value.toObject())).map { AgentEventJSON.encodeGit($0).anyObject }
        }
        host.setObject(gitFromClaude, forKeyedSubscript: "gitOperationsFromReport" as NSString)
        let gitFallback: @convention(block) (String, String, Bool) -> Any = { command, output, succeeded in
            GitOperation.fallback(command: command, output: output, succeeded: succeeded).map { AgentEventJSON.encodeGit($0).anyObject }
        }
        host.setObject(gitFallback, forKeyedSubscript: "gitOperationsFromCommand" as NSString)
        let isQuestion: @convention(block) (String) -> Bool = { AgentQuestion.isQuestion($0) }
        host.setObject(isQuestion, forKeyedSubscript: "isQuestion" as NSString)
        let lineDiff: @convention(block) (String, String) -> Any = { old, new in
            EditPreview.lineDiff(old, new).map { AgentEventJSON.encodeCodable($0).anyObject }
        }
        host.setObject(lineDiff, forKeyedSubscript: "lineDiff" as NSString)
        let splitLines: @convention(block) (String) -> [String] = { EditPreview.splitLines($0) }
        host.setObject(splitLines, forKeyedSubscript: "splitLines" as NSString)
        // Abstract's own names and limits an agent's launch refers to.
        let constants: [String: Any] = [
            "codeHistory": ["server": CodeHistory.serverName, "historyTool": CodeHistory.historyTool,
                            "excerptTool": CodeHistory.excerptTool, "instruction": CodeHistory.instruction],
            "pluginTools": ["server": PluginTools.serverName, "timeout": PluginTools.timeout, "askTimeout": PluginTools.askTimeout],
            "branch": ["server": BranchMCPServer.serverName],
            "plan": ["instruction": Plan.instruction, "readOnlyInstruction": Plan.readOnlyInstruction],
        ]
        host.setObject(constants, forKeyedSubscript: "constants" as NSString)
        let uuid: @convention(block) () -> String = { UUID().uuidString.lowercased() }
        host.setObject(uuid, forKeyedSubscript: "uuid" as NSString)
        let random: @convention(block) (Int) -> [Int] = { count in (0..<max(0, min(count, 64))).map { _ in Int.random(in: 0...255) } }
        host.setObject(random, forKeyedSubscript: "randomBytes" as NSString)
        let write: @convention(block) (String, String) -> Any = { [weak self] name, contents in
            guard let directory = self?.configDirectory,
                  let path = ChatConfigFiles.write(contents, named: name, in: directory) else { return NSNull() }
            return path
        }
        host.setObject(write, forKeyedSubscript: "writeConfigFile" as NSString)
        let readImage: @convention(block) (String) -> Any = { [weak self] path in
            guard self?.readableImages.contains(path) == true, let media = ImageMedia.type(ofPath: path),
                  let data = FileManager.default.contents(atPath: path) else { return NSNull() }
            return ["mediaType": media, "base64Data": data.base64EncodedString()]
        }
        host.setObject(readImage, forKeyedSubscript: "readImage" as NSString)
    }

    func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func registration(_ agentId: String) -> JSValue? {
        let value = context.objectForKeyedSubscript("AbstractAgent")?.objectForKeyedSubscript("_agents")?
            .objectForKeyedSubscript(agentId)
        return value.flatMap { $0.isUndefined || $0.isNull ? nil : $0 }
    }

    /// The function at `path` on the agent's registration, if it has one.
    func function(_ agentId: String, _ path: [String]) -> (owner: JSValue, function: JSValue)? {
        guard var owner = registration(agentId) else { return nil }
        for key in path.dropLast() {
            guard let next = owner.objectForKeyedSubscript(key), next.isObject else { return nil }
            owner = next
        }
        guard let last = path.last, let function = owner.objectForKeyedSubscript(last),
              !function.isUndefined, !function.isNull else { return nil }
        return (owner, function)
    }

    public func has(_ agentId: String, _ path: String...) -> Bool {
        locked { function(agentId, path) != nil }
    }

    /// Calls a hook with JSON arguments; its JSON answer, or nil when it has
    /// none, returns nothing, or throws.
    func call(_ agentId: String, _ path: [String], _ args: [JSONValue], configDirectory: String? = nil,
              images: [String] = []) -> JSONValue? {
        locked {
            guard let (owner, function) = function(agentId, path) else { return nil }
            self.configDirectory = configDirectory
            readableImages = Set(images)
            defer { self.configDirectory = nil; readableImages = [] }
            _ = function
            return take(owner.invokeMethod(path.last!, withArguments: args.map(\.anyObject)))
        }
    }

    func take(_ value: JSValue?) -> JSONValue? {
        if context.exception != nil {
            context.exception = nil
            return nil
        }
        guard let value, !value.isUndefined, !value.isNull else { return nil }
        return JSONValue(any: value.toObject())
    }

    /// A fresh object from a hook (a parser), kept to call again.
    func make(_ agentId: String, _ path: [String], _ args: [JSONValue] = []) -> JSValue? {
        locked {
            // Called on its owner, so `this` inside it is the registration.
            guard let (owner, _) = function(agentId, path) else { return nil }
            let value = owner.invokeMethod(path.last!, withArguments: args.map(\.anyObject))
            if context.exception != nil { context.exception = nil; return nil }
            return value.flatMap { $0.isObject ? $0 : nil }
        }
    }

    /// Calls a method on an object the script made.
    func call(_ object: JSValue, _ method: String, _ args: [Any]) -> (value: JSONValue?, failed: Bool) {
        locked {
            guard let function = object.objectForKeyedSubscript(method), function.isObject else { return (nil, false) }
            let value = object.invokeMethod(method, withArguments: args)
            if context.exception != nil {
                context.exception = nil
                return (nil, true)
            }
            guard let value, !value.isUndefined, !value.isNull else { return (nil, false) }
            return (JSONValue(any: value.toObject()), false)
        }
    }

    /// Evaluates source in the script's context: for tests of its helpers.
    public func evaluate(_ source: String) -> JSONValue? {
        locked { take(context.evaluateScript(source)) }
    }
}

extension JSONValue {
    /// The Foundation value JavaScriptCore turns into the same JSON.
    var anyObject: Any {
        switch self {
        case .null: NSNull()
        case .bool(let b): NSNumber(value: b)
        case .number(let n): NSNumber(value: n)
        case .string(let s): s
        case .array(let a): a.map(\.anyObject)
        case .object(let o): o.mapValues(\.anyObject)
        }
    }
}

/// An agent from a plugin: the declaration in its manifest and its script.
public struct ScriptedProvider: ProviderDefinition {
    public let declaration: PluginAgentDeclaration
    public let script: AgentScript
    public let bundled: Bool
    let capabilities: Set<String>

    public init(declaration: PluginAgentDeclaration, script: AgentScript, bundled: Bool = false) {
        self.declaration = declaration
        self.script = script
        self.bundled = bundled
        capabilities = declaration.negotiatedCapabilities
    }

    public var pluginId: String { script.pluginId }
    public var id: String { declaration.id }
    public var name: String { declaration.label }
    public var logoAsset: String { bundled ? declaration.asset ?? "" : "" }
    /// The package's SVG logo, for agents without an app asset.
    public var iconURL: URL? { declaration.icon.map { script.folder.appendingPathComponent($0) } }
    public var binary: String { declaration.binary }
    public var install: String? { declaration.install }
    public var detectArgs: [String] { declaration.detect ?? ["--version"] }
    public var followUpMode: FollowUpMode { can("prompt.steer") ? .stdin : .respawn }

    public func can(_ capability: String) -> Bool { capabilities.contains(capability) }

    // MARK: Launching

    private func command(_ override: String?) -> String {
        override.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 } ?? binary
    }

    private var prefix: [String] { Array(declaration.command.dropFirst()) }

    public func buildLaunch(_ ctx: LaunchContext) -> LaunchSpec { launch(ctx, resumeId: nil) }
    public func buildResume(_ ctx: LaunchContext, resumeId: String) -> LaunchSpec { launch(ctx, resumeId: resumeId) }

    private func launch(_ ctx: LaunchContext, resumeId: String?) -> LaunchSpec {
        let answer = script.call(id, ["launch"], [LaunchContextJSON.encode(ctx), resumeId.map(JSONValue.string) ?? .null],
                                 configDirectory: ctx.configDirectory, images: ctx.images) ?? .null
        return LaunchSpec(command: command(ctx.binaryOverride), args: prefix + Self.strings(answer["args"]), cwd: ctx.cwd,
                          env: Self.env(answer["env"]), stdinInitial: answer["stdin"]?.string,
                          keepStdinOpen: answer["keepStdinOpen"]?.bool ?? (followUpMode == .stdin))
    }

    static func strings(_ value: JSONValue?) -> [String] { (value?.array ?? []).compactMap(\.string) }
    static func env(_ value: JSONValue?) -> [String: String] { (value?.object ?? [:]).compactMapValues(\.string) }

    public func makeParser() -> OutputParser { ScriptedParser(script: script, agentId: id) }

    /// The enricher runs in a context of its own: it waits on the worktree
    /// while it reads a line, and nothing else of the plugin's may wait
    /// behind it (with the plugin's lock held, a chat's git read could wait
    /// on a thread its other chats' parsing holds).
    public func makeLineEnricher(executor: any Executor, cwd: String) -> (any LineEnricher)? {
        guard can("lines.enrich") else { return nil }
        let own = AgentScript(pluginId: script.pluginId, folder: script.folder, source: script.source)
        return ScriptedEnricher(script: own, agentId: id, worktree: AgentWorktree(executor: executor, cwd: cwd))
    }

    // MARK: Stdin lines

    public func buildUserMessage(_ text: String) -> String? { buildUserMessage(text, images: [], sessionId: nil) }
    public func buildUserMessage(_ text: String, images: [String]) -> String? { buildUserMessage(text, images: images, sessionId: nil) }
    public func buildUserMessage(_ text: String, images: [String], sessionId: String?) -> String? {
        guard can("prompt.steer") else { return nil }
        return script.call(id, ["message"], [.object(["text": .string(text), "images": .array(images.map(JSONValue.string)),
                                                      "sessionId": sessionId.map(JSONValue.string) ?? .null])],
                           images: images)?.string
    }

    public func buildPermissionResponse(requestId: String, allow: Bool, input: JSONValue?) -> String? {
        guard can("permission") else { return nil }
        return line("permission", ["requestId": .string(requestId), "allow": .bool(allow), "input": input ?? .null])
    }

    public func buildPermissionModeChange(_ policy: PermissionPolicy, requestId: String) -> String? {
        guard can("permission.mode") else { return nil }
        return line("permissionMode", ["policy": .string(policy.rawValue), "requestId": .string(requestId)])
    }

    public func buildStopTask(_ taskId: String, requestId: String) -> String? {
        guard can("task.stop") else { return nil }
        return line("stopTask", ["taskId": .string(taskId), "requestId": .string(requestId)])
    }

    public func buildInterrupt(requestId: String) -> String? {
        guard can("interrupt") else { return nil }
        return line("interrupt", ["requestId": .string(requestId)])
    }

    public func buildBackground(toolUseId: String?, requestId: String) -> String? {
        guard can("task.background") else { return nil }
        return line("background", ["toolUseId": toolUseId.map(JSONValue.string) ?? .null, "requestId": .string(requestId)])
    }

    private func line(_ hook: String, _ input: [String: JSONValue]) -> String? {
        script.call(id, [hook], [.object(input)])?.string
    }

    // MARK: Models and settings

    public var fallbackModels: ModelCatalog {
        script.call(id, ["catalog"], []).flatMap { AgentEventJSON.decodeCodable(ModelCatalog.self, $0) } ?? .empty
    }

    public func discoverModels(executor: any Executor, binary: String?) async -> ModelCatalog? {
        await discoverModels(executor: executor, binary: binary, timeout: nil)
    }

    /// The same, giving up after `timeout` at most, whatever the script asks.
    public func discoverModels(executor: any Executor, binary: String?, timeout: Duration?) async -> ModelCatalog? {
        guard can("models.discover"),
              let answer = try? await AgentJobs(provider: self, executor: executor, binaryOverride: binary, limit: timeout)
                .run("discoverModels", input: .object(["binary": .string(command(binary)), "config": config(executor: executor)]))
        else { return nil }
        return AgentEventJSON.decodeCodable(ModelCatalog.self, answer)
    }

    /// The manifest's `config` files under `home`, by their path there.
    func config(home: String) -> JSONValue {
        var files: [String: JSONValue] = [:]
        for path in declaration.config ?? [] {
            if let data = FileManager.default.contents(atPath: (home as NSString).appendingPathComponent(path)),
               let text = String(data: data, encoding: .utf8) {
                files[path] = .string(text)
            }
        }
        return .object(files)
    }

    /// The same files read on the executor's own Mac, for jobs that run there.
    func config(executor: any Executor) -> JSONValue {
        var files: [String: JSONValue] = [:]
        for path in declaration.config ?? [] {
            if let text = try? executor.readFile((executor.homeDirectory as NSString).appendingPathComponent(path)) {
                files[path] = .string(text)
            }
        }
        return .object(files)
    }

    public func configuredDefaultModel(home: String) -> String? {
        script.call(id, ["defaultModel"], [config(home: home)])?.string
    }

    public func configuredDefaultEffort(home: String) -> String? {
        script.call(id, ["defaultEffort"], [config(home: home)])?.string
    }

    public func permissionDetail(_ policy: PermissionPolicy) -> String {
        script.call(id, ["permissionDetail"], [.string(policy.rawValue)])?.string ?? policy.detail
    }

    public var skillDelivery: SkillDelivery? {
        switch declaration.skills {
        case "addedDirectory": .addedDirectory
        case "codexHome": .codexHome
        case "skillsPath": .skillsPath
        default: nil
        }
    }

    public var commands: ProviderCommands {
        ProviderCommands(extra: (declaration.commands ?? []).compactMap(AppCommand.init(rawValue:)),
                         replaces: (declaration.replaces ?? [:]).compactMapValues(AppCommand.init(rawValue:)))
    }

    public var toolServerSupport: ToolServerSupport {
        switch declaration.toolServers {
        case "allowOrOff": .allowOrOff
        case "askFirst": .askFirst
        default: .none
        }
    }

    // MARK: Naming

    public func namingLaunch(prompt: String, home: String, binary: String?, model: String?) -> LaunchSpec? {
        guard can("naming"), let answer = script.call(id, ["naming", "launch"], [.object([
            "prompt": .string(prompt), "home": .string(home), "model": model.map(JSONValue.string) ?? .null,
            "config": config(home: home),
        ])]) else { return nil }
        // The prompt may go in on stdin (Claude reads it there).
        return LaunchSpec(command: binary ?? self.binary, args: prefix + Self.strings(answer["args"]),
                          cwd: answer["cwd"]?.string ?? home, env: Self.env(answer["env"]),
                          stdinInitial: answer["stdin"]?.string, keepStdinOpen: false)
    }

    public func namingAnswer(_ output: String) -> String? {
        script.call(id, ["naming", "answer"], [.string(output)])?.string
    }

    public func namingError(_ output: String) -> String? {
        script.call(id, ["naming", "error"], [.string(output)])?.string
    }

    public func namingCheck(home: String, binary: String?) -> LaunchSpec? {
        guard can("naming"), let answer = script.call(id, ["naming", "check"], [.object(["home": .string(home)])]) else { return nil }
        return LaunchSpec(command: binary ?? self.binary, args: prefix + Self.strings(answer["args"]),
                          cwd: answer["cwd"]?.string ?? home, env: Self.env(answer["env"]), keepStdinOpen: false)
    }

    public func namingCheckPasses(_ output: String) -> Bool {
        guard script.has(id, "naming", "checkPasses") else { return true }
        return script.call(id, ["naming", "checkPasses"], [.string(output)])?.bool ?? false
    }

    // MARK: Compaction

    public var compaction: Compaction? {
        if let prompt = declaration.compactPrompt { return .inStream(prompt: prompt) }
        return can("compaction") ? .sideChannel(ScriptedCompactor(provider: self)) : nil
    }
}

/// A chat's parser: one object the script made, fed a batch of lines at a
/// time. A script that throws leaves the line raw, as a parser must never fail.
public final class ScriptedParser: InputDrivingParser {
    private let script: AgentScript
    private let object: JSValue?

    init(script: AgentScript, agentId: String) {
        self.script = script
        object = script.make(agentId, ["parser"])
    }

    public func feed(_ line: String, stream: OutputStreamKind) -> [AgentEvent] {
        feed(lines: [OutputLine(stream: stream, line: line)]).first ?? []
    }

    public func feed(lines: [OutputLine]) -> [[AgentEvent]] {
        let raw = lines.map { [AgentEvent.raw(line: $0.line, stream: $0.stream)] }
        guard let object, !lines.isEmpty else { return raw }
        let batch: [Any] = [lines.map { ["line": $0.line, "stream": $0.stream.rawValue] }]
        let (value, failed) = script.call(object, "feed", batch)
        guard !failed, let groups = value?.array, groups.count == lines.count else { return raw }
        return groups.map { ($0.array ?? []).compactMap(AgentEventJSON.decode) }
    }

    public func onExit(code: Int32?) -> [AgentEvent] {
        guard let object else { return [] }
        let (value, _) = script.call(object, "exit", [code.map { NSNumber(value: $0) } ?? NSNull()])
        return (value?.array ?? []).compactMap(AgentEventJSON.decode)
    }

    public func takePendingInput() -> [String] {
        guard let object else { return [] }
        return (script.call(object, "input", []).value?.array ?? []).compactMap(\.string)
    }
}

/// What a line enricher may read: the chat's own worktree, nothing else.
struct AgentWorktree: Sendable {
    let executor: any Executor
    let cwd: String

    func contains(_ path: String) -> Bool {
        let root = URL(fileURLWithPath: cwd).standardizedFileURL.path
        let full = URL(fileURLWithPath: path.hasPrefix("/") ? path : (cwd as NSString).appendingPathComponent(path)).standardizedFileURL.path
        return full == root || full.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    func absolute(_ path: String) -> String {
        path.hasPrefix("/") ? path : (cwd.hasSuffix("/") ? cwd : cwd + "/") + path
    }
}

/// Fills a line in before it's logged, through the script's `enrich(line,
/// worktree)`; the worktree offers `read(path)` and `committed(path)`.
final class ScriptedEnricher: LineEnricher, @unchecked Sendable {
    private let script: AgentScript
    private let object: JSValue?

    init(script: AgentScript, agentId: String, worktree: AgentWorktree) {
        self.script = script
        object = script.makeEnricher(agentId, worktree: worktree)
    }

    func enrich(_ line: OutputLine) -> OutputLine {
        guard let object else { return line }
        let (value, failed) = script.call(object, "enrich", [line.line, line.stream.rawValue])
        guard !failed, let text = value?.string, text != line.line else { return line }
        var out = line
        out.line = text
        return out
    }
}

extension AgentScript {
    /// The enricher object, with the worktree's two reads bound in.
    func makeEnricher(_ agentId: String, worktree: AgentWorktree) -> JSValue? {
        locked {
            guard let (owner, _) = function(agentId, ["enricher"]) else { return nil }
            let read: @convention(block) (String) -> Any = { path in
                guard worktree.contains(path) else { return NSNull() }
                return (try? worktree.executor.readFile(worktree.absolute(path))) ?? NSNull()
            }
            let committed: @convention(block) (String) -> String = { path in
                worktree.contains(path) ? AgentWorktreeGit.committed(worktree.absolute(path), executor: worktree.executor) : ""
            }
            let host = JSValue(newObjectIn: owner.context)!
            host.setObject(read, forKeyedSubscript: "read" as NSString)
            host.setObject(committed, forKeyedSubscript: "committed" as NSString)
            host.setObject(worktree.cwd, forKeyedSubscript: "cwd" as NSString)
            let value = owner.invokeMethod("enricher", withArguments: [host])
            if owner.context.exception != nil { owner.context.exception = nil; return nil }
            return value.flatMap { $0.isObject ? $0 : nil }
        }
    }
}

/// A file as committed at HEAD, read on the executor's host; empty when it
/// wasn't, or when git takes more than five seconds. Lines arrive on the
/// process's own reader queue, so waiting here holds up only this chat's
/// next line.
enum AgentWorktreeGit {
    static let timeout: TimeInterval = 5

    static func committed(_ path: String, executor: any Executor) -> String {
        let dir = (path as NSString).deletingLastPathComponent, name = (path as NSString).lastPathComponent
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        Task {
            if let result = try? await executor.run("git", ["show", "HEAD:./" + name], cwd: dir, stdin: nil), result.ok {
                box.set(result.stdout)
            }
            done.signal()
        }
        _ = done.wait(timeout: .now() + timeout)
        return box.value
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""
        func set(_ value: String) { lock.lock(); text = value; lock.unlock() }
        var value: String { lock.lock(); defer { lock.unlock() }; return text }
    }
}

/// `/compact` through the script's `compact` job.
struct ScriptedCompactor: Compactor {
    let provider: ScriptedProvider

    func compact(_ request: CompactionRequest, executor: any Executor) async throws -> CompactionResult {
        let input: JSONValue = .object([
            "sessionId": .string(request.sessionId), "cwd": .string(request.cwd),
            "model": request.model.map(JSONValue.string) ?? .null,
            "defaultModel": provider.configuredDefaultModel(home: executor.homeDirectory).map(JSONValue.string) ?? .null,
        ])
        let answer = try await AgentJobs(provider: provider, executor: executor, binaryOverride: request.binaryOverride)
            .run("compact", input: input)
        return CompactionResult(tokensBefore: answer["tokensBefore"]?.int, tokensAfter: answer["tokensAfter"]?.int,
                                contextWindow: answer["contextWindow"]?.int, summary: answer["summary"]?.string)
    }
}

/// Runs a generator job: each value it yields is one thing the host does,
/// whose answer goes back in with `next`. Anything it started is stopped
/// when it ends, however it ends.
struct AgentJobs: Sendable {
    let provider: ScriptedProvider
    let executor: any Executor
    let binaryOverride: String?
    /// The longest any one step may take, below what the script asks.
    var limit: Duration? = nil

    private var script: AgentScript { provider.script }

    private final class Started: @unchecked Sendable {
        private let lock = NSLock()
        private var processes: [Int: any RunningProcess] = [:]
        private var next = 1
        func add(_ process: any RunningProcess) -> Int {
            lock.lock(); defer { lock.unlock() }
            let id = next; next += 1; processes[id] = process; return id
        }
        func stop(_ id: Int) { lock.lock(); let process = processes.removeValue(forKey: id); lock.unlock(); process?.terminate() }
        func stopAll() { lock.lock(); let all = processes.values; processes = [:]; lock.unlock(); all.forEach { $0.terminate() } }
    }

    private struct Box: @unchecked Sendable { let value: JSValue }

    func run(_ job: String, input: JSONValue) async throws -> JSONValue {
        guard let generator = script.make(provider.id, [job], [input]) else {
            throw AbstractError.message("\(provider.name) can't do that.")
        }
        let started = Started()
        defer { started.stopAll() }
        var answer: JSONValue = .null
        let iterator = Box(value: generator)
        while true {
            try Task.checkCancellation()
            let step = script.step(iterator.value, answer)
            if let error = step.error { throw AbstractError.message(error) }
            if step.done { return step.value }
            answer = try await perform(step.value, receive: step.receive.map(Box.init), started: started)
        }
    }

    private func spec(_ value: JSONValue, cwd fallback: String) -> LaunchSpec {
        let command = binaryOverride.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 } ?? provider.binary
        return LaunchSpec(command: command, args: Array(provider.declaration.command.dropFirst()) + ScriptedProvider.strings(value["args"]),
                          cwd: value["cwd"]?.string ?? fallback, env: ScriptedProvider.env(value["env"]),
                          stdinInitial: value["stdin"]?.string, keepStdinOpen: value["keepStdinOpen"]?.bool ?? false)
    }

    private func seconds(_ value: JSONValue?, default fallback: Int) -> Duration {
        let asked = Duration.seconds(max(1, min(value?.int ?? fallback, 600)))
        return limit.map { min($0, asked) } ?? asked
    }

    private func perform(_ effect: JSONValue, receive: Box?, started: Started) async throws -> JSONValue {
        let home = executor.homeDirectory
        if let run = effect["run"] {
            let result = try await executor.run(spec(run, cwd: home), timeout: seconds(run["timeout"], default: 30))
            return .object(["code": result.code.map { .number(Double($0)) } ?? .null, "ok": .bool(result.ok),
                            "stdout": .string(result.stdout), "stderr": .string(result.stderr), "timedOut": .bool(result.timedOut)])
        }
        if let converse = effect["converse"] {
            guard let receive else { throw AbstractError.message("\(provider.name) didn't say how to read the answer.") }
            let script = self.script
            let value = try await SideProcess.converse(executor, spec(converse, cwd: home),
                                                       opening: ScriptedProvider.strings(converse["opening"]),
                                                       timeout: seconds(converse["timeout"], default: 30)) { line -> SideStep<JSONValue> in
                // The `receive(line)` the yielded effect carries.
                let (step, failed) = script.callReceive(receive.value, line)
                if failed { return .fail("The agent's script failed.") }
                if let send = step?["send"]?.array { return .send(send.compactMap(\.string)) }
                if let done = step?["done"] { return .finish(done) }
                if let fail = step?["fail"]?.string { return .fail(fail) }
                return .wait
            }
            return value
        }
        if let start = effect["start"] {
            let pattern = start["until"]?.string ?? ""
            let (line, process) = try await SideProcess.start(executor, spec(start, cwd: home),
                                                              timeout: seconds(start["timeout"], default: 30)) { line in
                pattern.isEmpty || line.range(of: pattern, options: .regularExpression) != nil
            }
            return .object(["line": .string(line), "handle": .number(Double(started.add(process)))])
        }
        if let handle = effect["stop"]?.int {
            started.stop(handle)
            return .null
        }
        if let http = effect["http"] {
            return try await AgentHTTP.call(http, executor: executor)
        }
        throw AbstractError.message("\(provider.name) asked for something Abstract doesn't do: \(effect.compact().prefix(200))")
    }
}

extension AgentScript {
    struct Step {
        var done: Bool
        var value: JSONValue
        /// A `converse` effect's `receive(line)`, kept as a function.
        var receive: JSValue?
        var error: String?
    }

    /// `next(answer)` on a job's generator. A job that returns a plain
    /// value instead of a generator is done with it.
    func step(_ iterator: JSValue, _ answer: JSONValue) -> Step {
        locked {
            guard let next = iterator.objectForKeyedSubscript("next"), next.isObject else {
                return Step(done: true, value: take(iterator) ?? .null)
            }
            let result = iterator.invokeMethod("next", withArguments: [answer.anyObject])
            if let exception = context.exception {
                context.exception = nil
                let message = exception.objectForKeyedSubscript("message")?.toString() ?? exception.toString() ?? ""
                return Step(done: true, value: .null, error: message.isEmpty ? "The agent's script failed." : message)
            }
            guard let result, result.isObject else { return Step(done: true, value: .null) }
            let done = result.objectForKeyedSubscript("done")?.toBool() ?? true
            let value = result.objectForKeyedSubscript("value")
            let json = take(value) ?? .null
            // Read only through objects: a property of `undefined` throws.
            let converse = value.flatMap { $0.isObject ? $0.objectForKeyedSubscript("converse") : nil }
            let receive = converse.flatMap { $0.isObject ? $0.objectForKeyedSubscript("receive") : nil }
            context.exception = nil
            return Step(done: done, value: json, receive: receive.flatMap { $0.isObject ? $0 : nil })
        }
    }

    /// A `converse` effect's `receive(line)`.
    func callReceive(_ receive: JSValue, _ line: String) -> (JSONValue?, Bool) {
        locked {
            let value = receive.call(withArguments: [line])
            if context.exception != nil { context.exception = nil; return (nil, true) }
            guard let value, !value.isUndefined, !value.isNull else { return (nil, false) }
            return (JSONValue(any: value.toObject()), false)
        }
    }
}

/// A call to a server the agent started on the executor's own loopback,
/// through curl there, so a paired Mac works. Nothing else is reachable.
enum AgentHTTP {
    static func isLoopback(_ url: String) -> Bool {
        guard let components = URLComponents(string: url), components.scheme == "http",
              let host = components.host else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "[::1]" || host == "::1"
    }

    static func call(_ request: JSONValue, executor: any Executor) async throws -> JSONValue {
        guard let url = request["url"]?.string, isLoopback(url) else {
            throw AbstractError.message("An agent may only call a server on this Mac.")
        }
        let maxTime = max(1, min(request["maxTime"]?.int ?? 30, 600))
        var args = ["-sS", "--max-time", String(maxTime), "-w", "\n%{http_code}"]
        if let user = request["user"]?.string { args += ["-u", user] }
        if let method = request["method"]?.string { args += ["-X", method] }
        for (name, value) in (request["headers"]?.object ?? [:]).sorted(by: { $0.key < $1.key }) {
            if let value = value.string { args += ["-H", "\(name): \(value)"] }
        }
        if let body = request["body"]?.string { args += ["--data-binary", body] }
        let spec = LaunchSpec(command: "curl", args: args + [url], cwd: request["cwd"]?.string ?? executor.homeDirectory,
                              keepStdinOpen: false)
        let result = try await executor.run(spec, timeout: .seconds(maxTime + 5))
        try Task.checkCancellation()
        guard result.ok else {
            return .object(["ok": .bool(false), "timedOut": .bool(result.timedOut),
                            "error": .string(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))])
        }
        let output = result.stdout
        let newline = output.lastIndex(of: "\n")
        let body = newline.map { String(output[..<$0]) } ?? output
        let status = newline.flatMap { Int(output[output.index(after: $0)...].trimmingCharacters(in: .whitespaces)) } ?? 0
        return .object(["ok": .bool((200..<300).contains(status)), "status": .number(Double(status)), "body": .string(body)])
    }
}

/// `LaunchContext` as the script sees it: everything Abstract decided for
/// this launch, and the host's own words for the instructions it adds.
enum LaunchContextJSON {
    static func encode(_ ctx: LaunchContext) -> JSONValue {
        func opt(_ value: String?) -> JSONValue { value.map(JSONValue.string) ?? .null }
        func strings(_ values: [String]) -> JSONValue { .array(values.map(JSONValue.string)) }
        func server(_ launch: MCPServerLaunch) -> JSONValue {
            let connection: JSONValue = switch launch.connection {
            case let .url(url, headers):
                .object(["type": .string("url"), "url": .string(url), "headers": .object(headers.mapValues(JSONValue.string))])
            case let .command(argv, env):
                .object(["type": .string("command"), "argv": strings(argv), "env": .object(env.mapValues(JSONValue.string))])
            }
            return .object(["name": .string(launch.name), "connection": connection, "allowsEverything": .bool(launch.allowsEverything),
                            "allowed": strings(launch.allowed), "askFirst": strings(launch.askFirst), "off": strings(launch.off),
                            "withheld": strings(launch.withheld), "notes": .string(launch.notes)])
        }
        return .object([
            "cwd": .string(ctx.cwd), "prompt": .string(ctx.prompt), "resumeId": opt(ctx.resumeId),
            "permissionPolicy": .string(ctx.permissionPolicy.rawValue), "readOnly": .bool(ctx.permissionPolicy.isReadOnly),
            "extraArgs": strings(ctx.extraArgs), "binaryOverride": opt(ctx.binaryOverride),
            "model": opt(ctx.model), "effort": opt(ctx.effort),
            "outputStyle": .object(["id": .string(ctx.outputStyle.rawValue), "instructions": opt(ctx.outputStyle.instructions)]),
            "images": strings(ctx.images), "readableDirs": strings(ctx.readableDirs),
            "historyTool": ctx.historyTool.map { .object(["serverCommand": strings($0.serverCommand), "chatId": .string($0.chatId),
                                                         "instructionFile": opt($0.instructionFile)]) } ?? .null,
            "branchTool": ctx.branchTool.map { .object(["serverCommand": strings($0.serverCommand)]) } ?? .null,
            "pluginTools": ctx.pluginTools.map { .object(["serverCommand": strings($0.serverCommand)]) } ?? .null,
            "instructions": opt(ctx.instructions),
            "toolServers": .array(ctx.toolServers.map(server)),
            "mcpServers": .array(ctx.mcpServers.map(server)),
            "toolNotes": opt(MCPServerLaunch.instructions(ctx.toolServers)),
            "configDirectory": opt(ctx.configDirectory),
            "skills": ctx.skills.map { .object(["folder": .string($0.folder)]) } ?? .null,
            "text": .object([
                "plan": .string(Plan.instruction), "readOnly": .string(Plan.readOnlyInstruction),
                "codeHistory": .string(CodeHistory.instruction),
            ]),
            "serverNames": .object([
                "history": .string(CodeHistory.serverName), "plugins": .string(PluginTools.serverName),
                "branch": .string(BranchMCPServer.serverName),
            ]),
        ])
    }
}
