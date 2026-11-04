import Foundation
@testable import AbstractCore

/// Abstract's own agents as the app runs them: bundled agent plugins
/// (ABS-185), read from the repository.
enum Agents {
    static var claude: ScriptedProvider { AgentPlugins.shared.anyAgent("claude")! }
    static var codex: ScriptedProvider { AgentPlugins.shared.anyAgent("codex")! }
    static var opencode: ScriptedProvider { AgentPlugins.shared.anyAgent("opencode")! }
    static var muse: ScriptedProvider { AgentPlugins.shared.anyAgent("muse")! }

    /// Calls a helper an agent script exposes for tests, with JSON arguments.
    static func call(_ agent: ScriptedProvider, _ function: String, _ args: JSONValue...) -> JSONValue? {
        agent.script.evaluate("\(function)(\(args.map { $0.compact() }.joined(separator: ", ")))")
    }

    static var openCodeCompactor: any Compactor {
        guard case .sideChannel(let compactor)? = opencode.compaction else { fatalError("OpenCode compacts through its script") }
        return compactor
    }
}

/// OpenCode's server helpers, now in its plugin's script.
enum OpenCodeServer {
    static func call(_ name: String, _ args: JSONValue...) -> JSONValue? {
        Agents.opencode.script.evaluate("OpenCodeAgent.Server.\(name)(\(args.map { $0.compact() }.joined(separator: ", ")))")
    }
    static func port(fromLine line: String) -> Int? { call("port", .string(line))?.int }
    static func model(_ id: String) -> (provider: String, model: String)? {
        guard let value = call("model", .string(id)), let provider = value["provider"]?.string,
              let model = value["model"]?.string else { return nil }
        return (provider, model)
    }
    static func contextTokens(messages: JSONValue) -> Int? { call("contextTokens", messages)?.int }
    static func summary(messages: JSONValue) -> String? { call("summary", messages)?.string }
    static func errorMessage(_ body: String) -> String? { call("errorMessage", .string(body))?.string }
    static func split(_ output: String) -> (body: String, status: Int) {
        // curl's output is split by the host now; the script sees body and status.
        guard let newline = output.lastIndex(of: "\n") else { return (output, 0) }
        return (String(output[..<newline]), Int(output[output.index(after: newline)...].trimmingCharacters(in: .whitespaces)) ?? 0)
    }
    static func url(base: String, path: String, directory: String) -> String? {
        call("url", .string(base), .string(path), .string(directory))?.string
    }
    static func maxTime(until deadline: Date, from now: Date) -> String? {
        call("maxTime", .number(deadline.timeIntervalSince1970 * 1000), .number(now.timeIntervalSince1970 * 1000))?.int.map(String.init)
    }
}

/// Muse's helpers, now in its plugin's script.
enum MusePlugin {
    static func catalog(_ line: String) -> ModelCatalog? {
        Agents.call(Agents.muse, "MuseAgent.modelCatalog", .string(line)).flatMap { AgentEventJSON.decodeCodable(ModelCatalog.self, $0) }
    }
    static func pendingPrompt(_ sessionId: String) -> String? {
        Agents.call(Agents.muse, "MuseAgent.pendingTurns.peek", .string(sessionId))?["prompt"]?.string
    }
    static func removePending(_ sessionId: String) {
        _ = Agents.call(Agents.muse, "MuseAgent.pendingTurns.remove", .string(sessionId))
    }
}

// Claude's and Codex's helpers the tests reach into, under the names they had
// as Swift types, now in their plugins' scripts (ABS-185).

enum ClaudeProvider {
    static func modelCatalog(initializeResponse line: String, requestId: String? = nil) -> ModelCatalog? {
        Agents.call(Agents.claude, "ClaudeAgent.modelCatalog", .string(line), requestId.map(JSONValue.string) ?? .null)
            .flatMap { AgentEventJSON.decodeCodable(ModelCatalog.self, $0) }
    }
    static func displayName(_ id: String) -> String { Agents.call(Agents.claude, "ClaudeAgent.displayName", .string(id))?.string ?? id }
    static var pinnedVersions: [String] { (Agents.claude.script.evaluate("ClaudeAgent.pinnedVersions")?.array ?? []).compactMap(\.string) }
    static var effortLevels: [String] { (Agents.claude.script.evaluate("ClaudeAgent.effortLevels")?.array ?? []).compactMap(\.string) }
}

enum ClaudeParser {
    static func compactSummary(_ text: String) -> String? {
        Agents.call(Agents.claude, "ClaudeAgent.compactSummary", .string(text))?.string
    }
}

enum CodexProvider {
    static func modelCatalog(modelsCache text: String, now: Date = Date(), timeZone: TimeZone = .current) -> ModelCatalog? {
        Agents.call(Agents.codex, "CodexAgent.modelCatalog", .string(text), .number(now.timeIntervalSince1970 * 1000),
                    .string(timeZone.identifier)).flatMap { AgentEventJSON.decodeCodable(ModelCatalog.self, $0) }
    }
    static func branchArgs(_ branch: BranchToolLaunch) -> [String] {
        (Agents.call(Agents.codex, "CodexAgent.branchArgs", .object(["serverCommand": .array(branch.serverCommand.map(JSONValue.string))]))?
            .array ?? []).compactMap(\.string)
    }
}

/// Codex's compaction conversation, driven as the host drives it.
struct CodexCompaction {
    private let name: String

    init(threadId: String) {
        name = "__compaction_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        _ = Agents.codex.script.evaluate("globalThis.\(name) = CodexAgent.compaction(\(JSONValue.string(threadId).compact())); null")
    }

    var opening: [String] { (Agents.codex.script.evaluate("\(name).opening")?.array ?? []).compactMap(\.string) }

    mutating func receive(_ line: String) -> SideStep<CompactionResult> {
        guard let step = Agents.codex.script.evaluate("\(name).receive(\(JSONValue.string(line).compact()))") else { return .wait }
        if let send = step["send"]?.array { return .send(send.compactMap(\.string)) }
        if let fail = step["fail"]?.string { return .fail(fail) }
        if let done = step["done"] {
            return .finish(CompactionResult(tokensBefore: done["tokensBefore"]?.int, tokensAfter: done["tokensAfter"]?.int,
                                            contextWindow: done["contextWindow"]?.int, summary: done["summary"]?.string))
        }
        return .wait
    }
}
