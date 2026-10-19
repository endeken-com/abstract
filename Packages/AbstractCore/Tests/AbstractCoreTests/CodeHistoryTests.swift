import Foundation
import Testing
@testable import AbstractCore

/// ABS-61: the history an agent is handed about the code it changes —
/// what it holds, what it never holds, and how each agent is given it.
@Suite struct CodeHistoryTests {
    private func turn(_ session: String, number: Int = 1, project: String? = "p1", ended: TimeInterval,
                      files: [String], decision: String? = nil, request: String? = "Do the thing",
                      corrections: [String] = [], summary: String? = "Did the thing") -> TurnRecord {
        TurnRecord(projectId: project, sessionId: session, chatName: "Chat \(session)", providerId: "claude",
                   number: number, endedAt: Date(timeIntervalSince1970: ended), request: request,
                   corrections: corrections, summary: summary, decision: decision, files: files,
                   ticket: "ABS-11", logStart: 1, logEnd: 2)
    }

    /// A store with one asking chat, two earlier ones (one archived), one
    /// deleted, and one in another project.
    private func seeded() throws -> Store {
        let store = try Store.inMemory()
        try store.save(Project(id: "p1", name: "One", rootPath: "/tmp/one"))
        try store.save(Project(id: "p2", name: "Two", rootPath: "/tmp/two"))
        for (id, archived) in [("s-ask", false), ("s-old", false), ("s-archived", true), ("s-deleted", false), ("s-other", false)] {
            try store.save(Session(id: id, projectId: id == "s-other" ? "p2" : "p1", name: "Chat \(id)",
                                   providerId: "claude", archivedAt: archived ? Date() : nil))
        }
        try store.save(turn("s-ask", ended: 9_000, files: ["Sources/Diff.swift"], decision: "Mine"))
        try store.save(turn("s-old", ended: 1_000, files: ["Sources/Diff.swift"], decision: "Never write the git index on a refresh path."))
        try store.save(turn("s-archived", ended: 2_000, files: ["Sources/Diff.swift", "Sources/Other.swift"], decision: "Archived still counts"))
        try store.save(turn("s-archived", number: 2, ended: 3_000, files: ["Sources/Nearby.swift"], decision: "Same folder"))
        try store.save(turn("s-deleted", ended: 4_000, files: ["Sources/Diff.swift"], decision: "Deleted on purpose"))
        try store.save(turn("s-other", project: "p2", ended: 5_000, files: ["Sources/Diff.swift"], decision: "Another project"))
        try store.deleteSession("s-deleted")
        return store
    }

    private func service(_ store: Store, repo: String = "/tmp/one") -> CodeHistoryService {
        CodeHistoryService(store: store, projectId: "p1", askingSessionId: "s-ask", repo: repo)
    }

    @Test func historyIsFileThenFolderNewestFirstAndStaysInTheProject() async throws {
        let store = try seeded()
        let entries = await service(store).history(path: "Sources/Diff.swift", lines: nil, exec: LocalExecutor.shared)
        #expect(entries.map(\.decision) == ["Archived still counts", "Never write the git index on a refresh path.", "Same folder"])
        #expect(entries.map(\.relevance) == ["file", "file", "folder"])
        #expect(entries.allSatisfy { $0.chatId != "s-ask" && $0.chatId != "s-deleted" && $0.chatId != "s-other" })
    }

    @Test func pathsOutsideTheRepositoryAreRefused() async throws {
        let store = try seeded()
        let service = service(store)
        #expect(service.relativePath("../secret.txt") == nil)
        #expect(service.relativePath("/etc/passwd") == nil)
        #expect(service.relativePath("/tmp/one/Sources/Diff.swift") == "Sources/Diff.swift")
        #expect(service.relativePath("./Sources/Diff.swift") == "Sources/Diff.swift")
        #expect(await service.history(path: "../../etc/passwd", lines: nil, exec: LocalExecutor.shared).isEmpty)
    }

    @Test func lineRangesReadAsTyped() {
        #expect(CodeHistoryService.lineRange("220") == 220...220)
        #expect(CodeHistoryService.lineRange("220-245") == 220...245)
        #expect(CodeHistoryService.lineRange("220:245") == 220...245)
        #expect(CodeHistoryService.lineRange("245-220") == nil)
        #expect(CodeHistoryService.lineRange("soon") == nil)
        #expect(CodeHistoryService.lineRange(nil) == nil)
    }

    @Test func anExcerptIsOneTurnOfAnotherChat() throws {
        let store = try seeded()
        let service = service(store)
        #expect(service.excerpt(chatId: "s-old", turn: 1)?.decision == "Never write the git index on a refresh path.")
        #expect(service.excerpt(chatId: "s-ask", turn: 1) == nil)
        #expect(service.excerpt(chatId: "s-deleted", turn: 1) == nil)
        #expect(service.excerpt(chatId: "s-other", turn: 1) == nil)
        #expect(service.excerpt(chatId: "s-old", turn: 9) == nil)
    }

    @Test func reviewNotesRideAlong() async throws {
        let store = try seeded()
        let record = try #require(try store.turnRecords(sessionId: "s-old").first)
        try store.save(CodeNote(sessionId: "s-old", turnId: record.id, kind: .reviewComment,
                                path: "Sources/Diff.swift", line: 230, commit: nil, body: "This races the agent's own git."))
        let entries = await service(store).history(path: "Sources/Diff.swift", lines: nil, exec: LocalExecutor.shared)
        #expect(entries.first { $0.chatId == "s-old" }?.review == ["This races the agent's own git."])
    }

    @Test func decisionsFallBackToTheSummaryFirstLine() async throws {
        let store = try Store.inMemory()
        try store.save(Project(id: "p1", name: "One", rootPath: "/tmp/one"))
        try store.save(Session(id: "s1", projectId: "p1", name: "One", providerId: "claude"))
        try store.save(turn("s1", ended: 1_000, files: ["a.swift"], summary: "Kept the budget.\nDetails follow."))
        let service = CodeHistoryService(store: store, projectId: "p1", askingSessionId: nil, repo: "/tmp/one")
        let entries = await service.history(path: "a.swift", lines: nil, exec: LocalExecutor.shared)
        #expect(entries.first?.decision == "Kept the budget.")
    }

    @Test func renderingKeepsEveryDecisionAndDropsFieldsBeforeRecords() {
        let entries = (1...6).map { (n: Int) in
            HistoryEntry(chatId: "s\(n)", chatName: "Chat \(n)", turn: 1, date: nil, ticket: "ABS-\(n)",
                         pullRequest: n, decision: "Decision \(n) stands.", request: String(repeating: "asked ", count: 120),
                         corrections: [String(repeating: "no ", count: 120)], summary: String(repeating: "did ", count: 120),
                         review: [], relevance: "file")
        }
        let text = CodeHistoryService.render(entries)
        #expect(text.count <= CodeHistoryService.textBudget)
        for n in 1...6 { #expect(text.contains("Decided: Decision \(n) stands.")) }
        #expect(text.contains("(chat s1, turn 1)"))
        #expect(CodeHistoryService.render([]).contains("No earlier chat"))
    }

    // MARK: Secrets

    @Test func secretsAreMaskedWhenReturned() async throws {
        let store = try Store.inMemory()
        try store.save(Project(id: "p1", name: "One", rootPath: "/tmp/one"))
        try store.save(Session(id: "s1", projectId: "p1", name: "One", providerId: "claude"))
        let token = "Ab3dEf6hIj9kLm2nOp5qRs8tUv1wXy4z"
        try store.save(turn("s1", ended: 1_000, files: ["a.swift"],
                            decision: "Key sk-ant-api03-abcdefghijklmnop stays out",
                            request: "Use AKIAIOSFODNN7EXAMPLE and\nAPI_TOKEN=\(token)\nplease",
                            corrections: ["token ghp_abcdefghijklmnopqrstuvwxyz0123"],
                            summary: "Committed abcdef0123456789abcdef0123456789abcdef01 with \(token)"))
        let service = CodeHistoryService(store: store, projectId: "p1", askingSessionId: nil, repo: "/tmp/one")
        let entry = try #require(await service.history(path: "a.swift", lines: nil, exec: LocalExecutor.shared).first)
        let all = [entry.decision, entry.request, entry.summary].compactMap { $0 } + entry.corrections
        #expect(all.allSatisfy { $0.contains("[masked]") })
        #expect(!all.joined().contains("sk-ant"))
        #expect(!all.joined().contains("AKIA"))
        #expect(!all.joined().contains("ghp_"))
        #expect(!all.joined().contains(token))
        // A commit sha is a hash, not a secret.
        #expect(entry.summary?.contains("abcdef0123456789abcdef0123456789abcdef01") == true)
    }

    @Test func maskingCoversPrivateKeysAndUnlistedShapes() {
        let key = "before\n-----BEGIN OPENSSH PRIVATE KEY-----\nabc123\n-----END OPENSSH PRIVATE KEY-----\nafter"
        #expect(SecretMasking.mask(key) == "before\n[masked]\nafter")
        #expect(SecretMasking.mask("auth xoxb-1234567890-abcdefghij").contains("[masked]"))
        #expect(SecretMasking.mask("nothing to hide here") == "nothing to hide here")
        #expect(SecretMasking.mask("let x = 5") == "let x = 5")
        let link = "See https://linear.app/abstract-ade/issue/ABS-91/some-long-Title9 and Packages/Foo9Bar.swift"
        #expect(SecretMasking.mask(link) == link)
    }

    // MARK: Through blame

    @Test func linesRankTheTurnThatWroteThemFirst() async throws {
        let exec = LocalExecutor.shared
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("code-history-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        func git(_ args: [String]) async throws -> String {
            let out = try await exec.run("git", args, cwd: dir)
            try #require(out.ok, "git \(args) failed: \(out.stderr)")
            return out.stdout
        }
        _ = try await git(["init", "-q", "-b", "main"])
        _ = try await git(["config", "user.email", "test@abstract.local"])
        _ = try await git(["config", "user.name", "Ana"])
        try "one\ntwo\nthree\n".write(toFile: dir + "/code.swift", atomically: true, encoding: .utf8)
        _ = try await git(["add", "-A"])
        _ = try await git(["commit", "-qm", "Add code"])
        let sha = GitText.trimmed(try await git(["rev-parse", "HEAD"]))

        let store = try Store.inMemory()
        try store.save(Project(id: "p1", name: "One", rootPath: dir))
        try store.save(Session(id: "s-lines", projectId: "p1", name: "Lines", providerId: "claude"))
        try store.save(Session(id: "s-file", projectId: "p1", name: "File", providerId: "claude"))
        let wrote = turn("s-lines", ended: 1_000, files: ["code.swift"], decision: "Wrote these lines")
        try store.save(wrote)
        try store.link([TurnCommit(sha: sha, turnId: wrote.id, link: .turn)])
        try store.save(turn("s-file", ended: 9_000, files: ["code.swift"], decision: "Touched the file later"))

        let entries = await service(store, repo: dir).history(path: "code.swift", lines: 2...2, exec: exec)
        #expect(entries.map(\.decision) == ["Wrote these lines", "Touched the file later"])
        #expect(entries.first?.relevance == "lines")
    }

    // MARK: The MCP server

    @Test func mcpAnswersTheHandshakeAndBothTools() async throws {
        let server = HistoryMCPServer(service: service(try seeded()))
        func call(_ line: String) async throws -> JSONValue {
            let reply = try #require(await server.handle(line))
            return try JSONDecoder().decode(JSONValue.self, from: Data(reply.utf8))
        }
        let opened = try await call(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}"#)
        #expect(opened["result"]?["serverInfo"]?["name"]?.string == CodeHistory.serverName)
        #expect(await server.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)

        let tools = try await call(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        let listed = tools["result"]?["tools"]?.array ?? []
        #expect(listed.map { $0["name"]?.string } == [CodeHistory.historyTool, CodeHistory.excerptTool])
        #expect(listed.allSatisfy { $0["annotations"]?["readOnlyHint"] == .bool(true) })

        let history = try await call(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"code_history","arguments":{"path":"Sources/Diff.swift","lines":"220-245"}}}"#)
        let text = history["result"]?["content"]?.array?.first?["text"]?.string ?? ""
        #expect(text.contains("Decided: Never write the git index"))
        #expect(!text.contains("Another project") && !text.contains("Deleted on purpose") && !text.contains("Decided: Mine"))

        let excerpt = try await call(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"chat_excerpt","arguments":{"chat":"s-old","turn":1}}}"#)
        #expect(excerpt["result"]?["content"]?.array?.first?["text"]?.string?.contains("You asked: Do the thing") == true)

        let outside = try await call(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"code_history","arguments":{"path":"/etc/passwd"}}}"#)
        #expect(outside["result"]?["isError"] == .bool(true))
    }

    // MARK: The command line

    @Test func historyTargetsParse() {
        #expect(Commands.historyTarget("Abstract/App/AppModel.swift:1037") == ("Abstract/App/AppModel.swift", "1037"))
        #expect(Commands.historyTarget("a.swift:10-20") == ("a.swift", "10-20"))
        #expect(Commands.historyTarget("a.swift") == ("a.swift", nil))
    }

    @Test func theCommandReturnsTheSameEntriesAsJSON() async throws {
        let store = try seeded()
        let commands = Commands(store: store, storePath: "/tmp/one/store.db",
                                locks: URL(fileURLWithPath: "/tmp/one/locks"), executable: "/bin/abstract")
        let entries = try await commands.history("Sources/Diff.swift", project: "One")
        // From the command line no chat is asking, so every live chat counts.
        #expect(entries.map(\.chatId) == ["s-ask", "s-archived", "s-old", "s-archived"])
        let json = String(decoding: try CLIOutput.encode(entries), as: UTF8.self)
        #expect(json.contains("\"decision\":\"Never write the git index on a refresh path.\""))
        #expect(json.contains("\"request\":\"Do the thing\""))
    }

    // MARK: Launching each agent

    private var tool: HistoryToolLaunch {
        HistoryToolLaunch(command: "/Applications/Abstract.app/Contents/Helpers/abstract", chatId: "chat-1",
                          instructionFile: "/data/code-history/code-history-instruction.md")
    }

    @Test func claudeGetsTheToolAndInstructionOnLaunchAndResume() {
        let provider = ClaudeProvider()
        let on = LaunchContext(cwd: "/w", prompt: "hi", permissionPolicy: .autoEdits, historyTool: tool)
        for spec in [provider.buildLaunch(on), provider.buildResume(on, resumeId: "r1")] {
            #expect(spec.args.contains("--mcp-config"))
            let config = spec.args.first { $0.contains(CodeHistory.serverName) } ?? ""
            #expect(config.contains("\"mcpServers\"") && config.contains("\"mcp\"") && config.contains("\"--chat\"") && config.contains("\"chat-1\""))
            #expect(spec.args.contains("\(CodeHistory.streamName(CodeHistory.historyTool)),\(CodeHistory.streamName(CodeHistory.excerptTool))"))
            #expect(spec.args.contains("--append-system-prompt"))
            #expect(spec.args.contains(CodeHistory.instruction))
            #expect(!spec.args.contains("--strict-mcp-config"))
        }
        let off = provider.buildLaunch(LaunchContext(cwd: "/w", prompt: "hi", permissionPolicy: .autoEdits))
        #expect(!off.args.contains("--mcp-config") && !off.args.contains("--append-system-prompt"))
    }

    @Test func codexGetsTheToolAndJoinedInstructionsOnExecAndResume() {
        let provider = CodexProvider()
        let on = LaunchContext(cwd: "/w", prompt: "hi", permissionPolicy: .autoEdits, outputStyle: .concise, historyTool: tool)
        for spec in [provider.buildLaunch(on), provider.buildResume(on, resumeId: "r1")] {
            #expect(spec.args.contains { $0.hasPrefix("mcp_servers.\(CodeHistory.serverName).command=") })
            #expect(spec.args.contains { $0.hasPrefix("mcp_servers.\(CodeHistory.serverName).args=") && $0.contains("\"--chat\"") && $0.contains("\"chat-1\"") })
            let instructions = spec.args.first { $0.hasPrefix("developer_instructions=") } ?? ""
            #expect(instructions.contains("Be concise"))
            #expect(instructions.contains("Before you change existing code"))
        }
        let off = provider.buildLaunch(LaunchContext(cwd: "/w", prompt: "hi", permissionPolicy: .autoEdits))
        #expect(!off.args.contains { $0.hasPrefix("mcp_servers.") || $0.hasPrefix("developer_instructions=") })
    }

    @Test func codexMCPCallsReadAsTools() throws {
        let parser = CodexProvider().makeParser()
        let url = try #require(Bundle.module.url(forResource: "codex-mcp", withExtension: "jsonl", subdirectory: "Fixtures"))
        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        let events = lines.flatMap { parser.feed($0, stream: .stdout) }
        let uses = events.compactMap { event -> (id: String, name: String, input: JSONValue)? in
            if case let .toolUse(id, name, input, _) = event { return (id, name, input) }
            return nil
        }
        #expect(uses.map(\.name) == [CodeHistory.streamName(CodeHistory.historyTool), CodeHistory.streamName(CodeHistory.excerptTool)])
        #expect(uses.first?.input["path"]?.string == "Sources/Diff.swift")
        #expect(uses.first?.input["lines"]?.string == "220-245")
        let results = events.compactMap { event -> (String, Bool)? in
            if case let .toolResult(_, output, isError, _) = event { return (output, isError) }
            return nil
        }
        #expect(results.count == 2)
        #expect(results[0].0.contains("Decided: Never write the git index") && results[0].1 == false)
        #expect(results[1].0.contains("requires approval") && results[1].1 == true)
    }

    @Test func openCodeGetsTheToolInItsConfig() {
        let provider = OpenCodeProvider()
        let on = LaunchContext(cwd: "/w", prompt: "hi", permissionPolicy: .autoEdits, historyTool: tool)
        for spec in [provider.buildLaunch(on), provider.buildResume(on, resumeId: "r1")] {
            let config = spec.env["OPENCODE_CONFIG_CONTENT"] ?? ""
            #expect(config.contains(CodeHistory.serverName))
            #expect(config.contains("\"type\":\"local\""))
            #expect(config.contains("\"mcp\"") && config.contains("\"--chat\"") && config.contains("\"chat-1\""))
            #expect(config.contains("code-history-instruction.md"))
            #expect(spec.args.last == "hi")
        }
        // No instruction file: the instruction rides on the prompt instead.
        let fileless = LaunchContext(cwd: "/w", prompt: "hi", permissionPolicy: .autoEdits,
                                     historyTool: HistoryToolLaunch(command: "/bin/abstract", chatId: "c"))
        let spec = provider.buildLaunch(fileless)
        #expect(spec.args.last?.hasPrefix("Before you change existing code") == true)
        #expect(spec.args.last?.hasSuffix("hi") == true)
        let off = provider.buildLaunch(LaunchContext(cwd: "/w", prompt: "hi", permissionPolicy: .autoEdits))
        #expect(off.env["OPENCODE_CONFIG_CONTENT"] == nil && off.args.last == "hi")
    }

    @Test func openCodeMCPCallsReadAsTools() throws {
        // Recorded from a real `opencode run` turn against `abstract mcp`
        // (opencode 1.18.18); session ids replaced.
        let parser = OpenCodeProvider().makeParser()
        let url = try #require(Bundle.module.url(forResource: "opencode-mcp", withExtension: "jsonl", subdirectory: "Fixtures"))
        let events = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
            .flatMap { parser.feed($0, stream: .stdout) }
        let use = events.compactMap { event -> (name: String, input: JSONValue)? in
            if case let .toolUse(_, name, input, _) = event { return (name, input) }
            return nil
        }.first
        #expect(use?.name == "abstract-code-history_code_history")
        #expect(use?.input["path"]?.string == "Packages/AbstractCore/Sources/AbstractCore/Git/Diff.swift")
        #expect(CodeHistory.tool(inStreamName: use?.name ?? "") == CodeHistory.historyTool)
        let result = events.compactMap { event -> String? in
            if case let .toolResult(_, output, _, _) = event { return output }
            return nil
        }.first
        #expect(result?.contains("Decided: Background reads") == true)
    }

    @Test func theSettingGatesTheLaunch() {
        let project = Project(name: "One", rootPath: "/tmp/one", agentHistory: false)
        #expect(project.agentHistoryEnabled == false)
        #expect(Project(name: "One", rootPath: "/tmp/one").agentHistoryEnabled == true)
        let session = Session(projectId: "p1", name: "Chat", providerId: "claude", worktreePath: "/w")
        let base = LaunchSettings(providerOverrides: [:], outputStyle: .default, claudeProfile: nil, attachmentsDirectory: "/a")
        let noTool = AgentLaunch.spec(for: session, provider: ClaudeProvider(), prompt: "hi", resumeId: nil,
                                      settings: base, home: "/h")
        #expect(!noTool.args.contains("--mcp-config"))
        var withTool = base
        withTool.codeHistory = CodeHistorySettings(command: "/bin/abstract")
        let spec = AgentLaunch.spec(for: session, provider: ClaudeProvider(), prompt: "hi", resumeId: nil,
                                    settings: withTool, home: "/h")
        #expect(spec.args.contains("--mcp-config"))
    }

    @Test func aTurnRecordKeepsItsDecision() throws {
        let store = try Store.inMemory()
        let record = turn("s1", ended: 1_000, files: ["a.swift"], decision: "Decided once")
        try store.save(record)
        #expect(try store.turnRecord(record.id) == record)
        #expect(try store.turnRecords(projectId: "p1") == [record])
    }
}
