import Foundation
import GRDB
import Synchronization
import Testing
@testable import AbstractCore

/// ABS-217: the read-only chat feed. Made-up chats only: every secret,
/// patient and path below is planted for the test.
@Suite struct ChatFeedTests {
    static let token = "abs_test-token-0123456789abcdefghijklmnopqrstuv"

    /// Planted in an open chat's messages; must never come back as written.
    static let plantedKey = "sk-ant-api03-PLANTEDfake1234567890abcdefXYZ"
    static let plantedEnv = "OPENAI_API_KEY=sk-proj-PLANTED0987654321zyxw"
    static let plantedURL = "postgres://admin:hunter2planted@db.example.com:5432/app"
    static let plantedJWT = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJwbGFudGVkIn0.c2lnbmF0dXJlLXBsYW50ZWQ"
    static let plantedPassword = "senha: Tr0ub4dorPlanted"
    static let plantedCode = "```swift\nlet plantedCode = 1\nprint(plantedCode)\n```"
    static let plantedPatient = "Paciente Maria da Silva, CPF 123.456.789-09, DN: 03/04/1980, prontuário 778899, CNS 898 0012 3456 7890"
    /// In a tool call's command and output: never a message at all.
    static let plantedTool = "PLANTED-TOOL-OUTPUT"

    /// A data folder with a real (WAL) database and chat logs: three open
    /// chats, one archived and one deleted, each with a log.
    final class Fixture: @unchecked Sendable {
        let root: URL
        let store: Store
        let logs: URL
        let base = Date(timeIntervalSince1970: 1_790_000_000)

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("chat-feed-\(UUID().uuidString)")
            logs = root.appendingPathComponent("sessions")
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            store = try Store(path: root.appendingPathComponent("abstract.sqlite").path)
            try store.save(Project(id: "p1", name: "payments-api", rootPath: "/tmp/made-up/payments-api"))
            try store.save(Project(id: "p2", name: "marketing-site", rootPath: "/tmp/made-up/marketing-site"))
            try chat("open-1", project: "p1", name: "Retry webhooks", status: .running, at: 100, messages: [
                (.user, "Make the webhook retries back off. \(ChatFeedTests.plantedEnv)"),
                (.tool, ""),
                (.agent, "Done. The database is \(ChatFeedTests.plantedURL) and the key was \(ChatFeedTests.plantedKey).\n\n\(ChatFeedTests.plantedCode)\n\nToken \(ChatFeedTests.plantedJWT), \(ChatFeedTests.plantedPassword)."),
            ])
            try chat("open-2", project: "p2", name: "Hero copy", status: .idle, at: 200, messages: [
                (.user, "Tighten the hero copy. \(ChatFeedTests.plantedPatient)"),
                (.agent, "Tightened the hero copy."),
            ])
            try chat("open-3", project: nil, name: "Scratch", status: .finished, at: 300,
                     messages: (1...7).map { ($0 % 2 == 1 ? .user : .agent, "message \($0)") })
            try chat("archived-1", project: "p1", name: "Archived chat", status: .finished, at: 400, archived: true,
                     messages: [(.user, "archived words"), (.agent, "archived reply")])
            try chat("deleted-1", project: "p1", name: "Deleted chat", status: .finished, at: 500,
                     messages: [(.user, "deleted words"), (.agent, "deleted reply")])
            try store.deleteSession("deleted-1")
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        enum Kind { case user, agent, tool }

        func chat(_ id: String, project: String?, name: String, status: SessionStatus, at offset: TimeInterval,
                  archived: Bool = false, messages: [(Kind, String)]) throws {
            try store.save(Session(id: id, projectId: project, name: name, providerId: "claude",
                                   worktreePath: "/tmp/made-up/worktrees/\(id)", status: status,
                                   createdAt: base.addingTimeInterval(offset), lastEventAt: base.addingTimeInterval(offset + 50),
                                   archivedAt: archived ? base : nil))
            var lines: [OutputLine] = []
            for (i, (kind, text)) in messages.enumerated() {
                let at = base.addingTimeInterval(offset + Double(i))
                let json: (JSONValue) -> String = { $0.compact() }
                switch kind {
                case .user:
                    lines.append(OutputLine(stream: .user, line: text, at: at))
                case .agent:
                    lines.append(OutputLine(stream: .stdout, line: json(.object([
                        "type": .string("assistant"),
                        "message": .object(["id": .string("m\(i)"), "role": .string("assistant"),
                                            "content": .array([.object(["type": .string("text"), "text": .string(text)])])]),
                    ])), at: at))
                case .tool:
                    lines.append(OutputLine(stream: .stdout, line: json(.object([
                        "type": .string("assistant"),
                        "message": .object(["id": .string("m\(i)"), "role": .string("assistant"), "content": .array([.object([
                            "type": .string("tool_use"), "id": .string("t\(i)"), "name": .string("Bash"),
                            "input": .object(["command": .string("cat .env # \(ChatFeedTests.plantedTool)")]),
                        ])])]),
                    ])), at: at))
                    lines.append(OutputLine(stream: .stdout, line: json(.object([
                        "type": .string("user"),
                        "message": .object(["role": .string("user"), "content": .array([.object([
                            "type": .string("tool_result"), "tool_use_id": .string("t\(i)"),
                            "content": .string("SECRET=\(ChatFeedTests.plantedTool)"),
                        ])])]),
                    ])), at: at))
                }
            }
            let encoder = JSONEncoder()
            let text = try lines.map { String(decoding: try encoder.encode($0), as: UTF8.self) }.joined(separator: "\n") + "\n"
            try text.write(to: logs.appendingPathComponent("\(id).jsonl"), atomically: true, encoding: .utf8)
        }

        func reader() throws -> ChatFeedStore {
            try ChatFeedStore(databasePath: root.appendingPathComponent("abstract.sqlite").path, logsURL: logs)
        }

        var logURL: URL { root.appendingPathComponent("logs/chat-feed.log") }

        func endpoint(filter: ChatFeedFilter = ChatFeedFilter(), origins: [String] = [],
                      clock: @escaping @Sendable () -> Date = { Date() }) throws -> ChatFeedEndpoint {
            ChatFeedEndpoint(reader: try reader(), configuration: .init(token: ChatFeedTests.token, filter: filter, allowedOrigins: origins),
                             log: ChatFeedLog(url: logURL), clock: clock)
        }
    }

    // MARK: Helpers

    static func post(_ body: JSONValue, token: String? = ChatFeedTests.token, headers: [String: String] = [:]) -> FeedHTTPRequest {
        var all = ["Content-Type": "application/json", "Accept": "application/json, text/event-stream"]
        if let token { all["Authorization"] = "Bearer \(token)" }
        for (k, v) in headers { all[k] = v }
        return FeedHTTPRequest(method: "POST", path: "/mcp", headers: all, body: Data(body.compact().utf8))
    }

    static func call(_ tool: String, _ arguments: [String: JSONValue] = [:], id: Int = 1) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string("tools/call"),
                 "params": .object(["name": .string(tool), "arguments": .object(arguments)])])
    }

    static func rpc(_ method: String, id: Int = 1, params: JSONValue = .object([:])) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string(method), "params": params])
    }

    /// A tool call's structured result, through the whole endpoint.
    static func result(_ endpoint: ChatFeedEndpoint, _ tool: String, _ arguments: [String: JSONValue] = [:]) throws -> (JSONValue, Bool) {
        let response = endpoint.respond(to: post(call(tool, arguments)))
        #expect(response.status == 200)
        let body = try #require(try? JSONDecoder().decode(JSONValue.self, from: response.body))
        let result = try #require(body["result"])
        let isError = result["isError"]?.bool ?? false
        return (result["structuredContent"] ?? result["content"]?.array?.first?["text"] ?? .null, isError)
    }

    static func everyTool(_ endpoint: ChatFeedEndpoint) throws -> [String: String] {
        var out: [String: String] = [:]
        for (tool, args) in [
            (ChatFeedMCPServer.listTool, [String: JSONValue]()),
            (ChatFeedMCPServer.readTool, ["chat_id": .string("open-1")]),
            (ChatFeedMCPServer.searchTool, ["consulta": .string("e")]),
            (ChatFeedMCPServer.recentTool, ["desde": .string("2020-01-01T00:00:00Z")]),
        ] {
            out[tool] = try result(endpoint, tool, args).0.compact()
        }
        return out
    }

    // MARK: No writes

    /// Fails to compile the moment `ChatFeedReader` gains a requirement
    /// beyond its three reads.
    struct ReadsOnly: ChatFeedReader {
        var chats: [FeedChat] = []
        var log: [String: [FeedMessage]] = [:]
        func openChats() throws -> [FeedChat] { chats }
        func openChat(_ id: String) throws -> FeedChat? { chats.first { $0.id == id } }
        func messages(chatId: String) throws -> [FeedMessage] { log[chatId] ?? [] }
    }

    @Test func toolsListIsExactlyTheFourReadTools() throws {
        let fixture = try Fixture()
        let response = try fixture.endpoint().respond(to: Self.post(Self.rpc("tools/list")))
        let body = try #require(try? JSONDecoder().decode(JSONValue.self, from: response.body))
        let tools = try #require(body["result"]?["tools"]?.array)
        #expect(tools.compactMap { $0["name"]?.string } == ["listar_chats_abertos", "ler_chat", "buscar_nos_chats", "atividade_recente"])
        #expect(tools.allSatisfy { $0["annotations"]?["readOnlyHint"]?.bool == true && $0["annotations"]?["destructiveHint"]?.bool == false })
    }

    @Test func theFeedsConnectionRefusesWrites() throws {
        let fixture = try Fixture()
        let reader = try fixture.reader()
        #expect(throws: (any Error).self) {
            try reader.database.writeWithoutTransaction { db in
                try db.execute(sql: "INSERT INTO settings (key, value) VALUES ('planted', '1')")
            }
        }
        #expect(throws: (any Error).self) {
            try reader.database.writeWithoutTransaction { db in try db.execute(sql: "UPDATE sessions SET name = 'x'") }
        }
        #expect(fixture.store.setting("planted", as: String.self) == nil)
    }

    @Test func noMethodOrVerbChangesTheDatabaseOrTheLogs() throws {
        let fixture = try Fixture()
        let endpoint = try fixture.endpoint()
        let watcher = try DatabaseQueue(path: fixture.root.appendingPathComponent("abstract.sqlite").path)
        let version = { try watcher.read { try Int.fetchOne($0, sql: "PRAGMA data_version") } }
        let logs = { try FileManager.default.contentsOfDirectory(atPath: fixture.logs.path).sorted().map {
            try Data(contentsOf: fixture.logs.appendingPathComponent($0))
        } }
        let before = (try version(), try logs())
        _ = try Self.everyTool(endpoint)
        for method in ["initialize", "ping", "tools/list", "resources/list", "prompts/list", "tools/delete", "sessions/archive"] {
            _ = endpoint.respond(to: Self.post(Self.rpc(method)))
        }
        _ = endpoint.respond(to: Self.post(Self.call("apagar_chat", ["chat_id": .string("open-1")])))
        for verb in ["GET", "DELETE", "PUT", "PATCH", "HEAD", "OPTIONS"] {
            _ = endpoint.respond(to: FeedHTTPRequest(method: verb, path: "/mcp", headers: ["Authorization": "Bearer \(Self.token)"]))
        }
        #expect(try version() == before.0)
        #expect(try logs() == before.1)
        #expect(try fixture.store.sessions().map(\.id).sorted() == ["archived-1", "open-1", "open-2", "open-3"])
    }

    // MARK: Closed chats

    @Test func archivedAndDeletedChatsAppearNowhere() throws {
        let fixture = try Fixture()
        let endpoint = try fixture.endpoint()
        let all = try Self.everyTool(endpoint).values.joined(separator: "\n")
            + (try Self.result(endpoint, ChatFeedMCPServer.searchTool, ["consulta": .string("words")]).0.compact())
            + (try Self.result(endpoint, ChatFeedMCPServer.searchTool, ["consulta": .string("reply")]).0.compact())
        for hidden in ["archived-1", "deleted-1", "Archived chat", "Deleted chat", "archived words", "deleted words"] {
            #expect(!all.contains(hidden), "\(hidden) leaked")
        }
        let list = try Self.result(endpoint, ChatFeedMCPServer.listTool).0
        #expect(list["chats"]?.array?.compactMap { $0["chat_id"]?.string } == ["open-3", "open-2", "open-1"])
        for id in ["archived-1", "deleted-1", "never-existed"] {
            let (value, isError) = try Self.result(endpoint, ChatFeedMCPServer.readTool, ["chat_id": .string(id)])
            #expect(isError)
            #expect(value.string == "Chat não encontrado.")
        }
    }

    // MARK: What a message is

    @Test func messagesAreOnlyWhatYouTypedAndTheAgentsReplies() throws {
        let fixture = try Fixture()
        let messages = try fixture.reader().messages(chatId: "open-1")
        #expect(messages.map(\.author) == [.user, .agent])
        #expect(messages.allSatisfy { !$0.text.contains(Self.plantedTool) })
        #expect(messages[0].at == fixture.base.addingTimeInterval(100))
        let all = try Self.everyTool(try fixture.endpoint()).values.joined()
        #expect(!all.contains(Self.plantedTool))
        #expect(!all.contains("/tmp/made-up"))
    }

    @Test func listShowsProjectNameStatusAndCount() throws {
        let fixture = try Fixture()
        let endpoint = try fixture.endpoint()
        let chats = try #require(try Self.result(endpoint, ChatFeedMCPServer.listTool).0["chats"]?.array)
        let first = try #require(chats.first { $0["chat_id"]?.string == "open-1" })
        #expect(first["projeto"]?.string == "payments-api")
        #expect(first["status"]?.string == "ativo")
        #expect(first["quantidade_mensagens"]?.int == 2)
        #expect(first["criado_em"]?.string == "2026-09-21T14:15:00Z")
        #expect(chats.first { $0["chat_id"]?.string == "open-2" }?["status"]?.string == "ocioso")
        let filtered = try Self.result(endpoint, ChatFeedMCPServer.listTool, ["projeto": .string("Marketing-Site")]).0
        #expect(filtered["chats"]?.array?.compactMap { $0["chat_id"]?.string } == ["open-2"])
        let since = try Self.result(endpoint, ChatFeedMCPServer.listTool, ["atualizado_desde": .string("2026-09-21T14:16:40Z")]).0
        #expect(since["chats"]?.array?.compactMap { $0["chat_id"]?.string } == ["open-3", "open-2"])
    }

    @Test func readChatPagesOldestFirst() throws {
        let fixture = try Fixture()
        let endpoint = try fixture.endpoint()
        let first = try Self.result(endpoint, ChatFeedMCPServer.readTool, ["chat_id": .string("open-3"), "limite": .number(3)]).0
        #expect(first["mensagens"]?.array?.compactMap { $0["texto"]?.string } == ["message 1", "message 2", "message 3"])
        #expect(first["mensagens"]?.array?.first?["autor"]?.string == "usuario")
        let cursor = try #require(first["proximo_cursor"]?.string)
        let second = try Self.result(endpoint, ChatFeedMCPServer.readTool,
                                     ["chat_id": .string("open-3"), "limite": .number(10), "cursor": .string(cursor)]).0
        #expect(second["mensagens"]?.array?.compactMap { $0["texto"]?.string } == ["message 4", "message 5", "message 6", "message 7"])
        #expect(second["proximo_cursor"] == .null)
        let since = try Self.result(endpoint, ChatFeedMCPServer.readTool,
                                    ["chat_id": .string("open-3"), "desde": .string("2026-09-21T14:18:25Z")]).0
        #expect(since["mensagens"]?.array?.compactMap { $0["texto"]?.string } == ["message 6", "message 7"])
        let (bad, isError) = try Self.result(endpoint, ChatFeedMCPServer.readTool, ["chat_id": .string("open-3"), "desde": .string("ontem")])
        #expect(isError && bad.string?.contains("ISO 8601") == true)
    }

    @Test func recentActivityHasTheLastThreeMessages() throws {
        let fixture = try Fixture()
        let endpoint = try fixture.endpoint(clock: { Date(timeIntervalSince1970: 1_790_000_000 + 3_600) })
        let value = try Self.result(endpoint, ChatFeedMCPServer.recentTool).0
        let chats = try #require(value["chats"]?.array)
        #expect(chats.compactMap { $0["chat_id"]?.string } == ["open-3", "open-2", "open-1"])
        #expect(chats[0]["ultimas_mensagens"]?.array?.compactMap { $0["texto"]?.string } == ["message 5", "message 6", "message 7"])
        #expect(chats[0]["ultima_mensagem_em"]?.string == "2026-09-21T14:18:26Z")
        let later = try fixture.endpoint(clock: { Date(timeIntervalSince1970: 1_790_000_000 + 30 * 3_600) })
        #expect(try Self.result(later, ChatFeedMCPServer.recentTool).0["chats"]?.array?.isEmpty == true)
    }

    @Test func searchFindsExcerptsButNeverWhatTheFilterHides() throws {
        let fixture = try Fixture()
        let endpoint = try fixture.endpoint()
        let hits = try #require(try Self.result(endpoint, ChatFeedMCPServer.searchTool, ["consulta": .string("hero")]).0["resultados"]?.array)
        #expect(hits.count == 2)
        #expect(hits.allSatisfy { $0["chat_id"]?.string == "open-2" && $0["titulo"]?.string == "Hero copy" })
        #expect(hits.first?["trecho"]?.string?.localizedCaseInsensitiveContains("hero") == true)
        for probe in ["hunter2planted", "PLANTEDfake", "plantedCode", "Tr0ub4dor"] {
            let found = try Self.result(endpoint, ChatFeedMCPServer.searchTool, ["consulta": .string(probe)]).0
            #expect(found["resultados"]?.array?.isEmpty == true, "\(probe) was findable")
        }
    }

    // MARK: Redaction

    @Test(arguments: [
        ("key \(plantedKey) end", "key [REDACTED] end"),
        (plantedEnv, "OPENAI_API_KEY=[REDACTED]"),
        ("DB_PASSWORD=Tr0ub4dor", "DB_PASSWORD=[REDACTED]"),
        ("url \(plantedURL)", "url postgres://[REDACTED]@db.example.com:5432/app"),
        ("mongodb+srv://user:pw123@cluster0.example.net/db", "mongodb+srv://[REDACTED]@cluster0.example.net/db"),
        ("jwt \(plantedJWT)", "jwt [REDACTED]"),
        ("Authorization: Bearer abcDEF1234567890ghiJKL", "Authorization: [REDACTED]"),
        (plantedPassword, "senha: [REDACTED]"),
        (#"{"password": "hunter2", "user": "ana"}"#, #"{"password": [REDACTED], "user": "ana"}"#),
        ("--api-key=abc123 --verbose", "--api-key=[REDACTED] --verbose"),
        (#"rotated the password: "password": "demo-only-123"."#, #"rotated the password: "password": [REDACTED]."#),
        ("ghp_PLANTED0123456789abcdefghijKLMN", "[REDACTED]"),
        ("AKIAPLANTED000000000", "[REDACTED]"),
        ("blob Zm9vYmFyPLANTEDbase64Zm9vYmFy0123456789 end", "blob [REDACTED] end"),
        ("commit 3f2a9c1e5b7d4a6f8e0c2b4d6f8a0c2e4b6d8f0a stays", "commit 3f2a9c1e5b7d4a6f8e0c2b4d6f8a0c2e4b6d8f0a stays"),
        ("max_tokens: 4096 stays", "max_tokens: 4096 stays"),
        ("Plain words about a password reset page stay.", "Plain words about a password reset page stay."),
    ])
    func secretsAreRedacted(_ planted: String, _ expected: String) {
        #expect(ChatFeedFilter().apply(planted) == expected)
    }

    @Test func codeBlocksBecomeAMarkerWhenOn() {
        let text = "Before\n\(Self.plantedCode)\nAfter\n~~~\nraw\n~~~"
        #expect(ChatFeedFilter().apply(text) == "Before\n[bloco de código: swift, 2 linhas]\nAfter\n[bloco de código: texto, 1 linha]")
        let off = ChatFeedFilter(hidesCodeBlocks: false).apply(text)
        #expect(off.contains("let plantedCode = 1"))
        // An unclosed fence hides the rest.
        #expect(ChatFeedFilter().apply("Look:\n```py\nsecret_stuff()\n") == "Look:\n[bloco de código: py, 2 linhas]")
        // Secrets inside code are still redacted when code is shown.
        #expect(ChatFeedFilter(hidesCodeBlocks: false).apply("```\nAPI_TOKEN=abc\n```") == "```\nAPI_TOKEN=[REDACTED]\n```")
    }

    @Test(arguments: [
        ("CPF 123.456.789-09", "CPF [REDACTED]"),
        ("cpf 12345678909", "cpf [REDACTED]"),
        ("CNS 898 0012 3456 7890.", "CNS [REDACTED]."),
        ("DN: 03/04/1980", "DN: [REDACTED]"),
        ("data de nascimento 1980-04-03", "data de nascimento [REDACTED]"),
        ("DOB 4/3/80", "DOB [REDACTED]"),
        ("prontuário 778899", "prontuário [REDACTED]"),
        ("prontuário 778899. Fim", "prontuário [REDACTED]. Fim"),
        ("MRN: A-55102", "MRN: [REDACTED]"),
        ("registro nº 4471", "registro nº [REDACTED]"),
        ("Paciente Maria da Silva chegou", "Paciente [REDACTED] chegou"),
        ("pac. João Pereira, 54 anos", "pac. [REDACTED], 54 anos"),
        ("Sra. Ana Souza e Sr. Paulo", "Sra. [REDACTED] e Sr. [REDACTED]"),
        ("o paciente melhorou", "o paciente melhorou"),
    ])
    func healthDataIsRedactedWhenOn(_ planted: String, _ expected: String) {
        #expect(ChatFeedFilter(redactsHealthData: true).apply(planted) == expected)
    }

    @Test func healthDataIsLeftAloneWhenOff() {
        #expect(ChatFeedFilter().apply("Paciente Maria da Silva") == "Paciente Maria da Silva")
    }

    @Test func plantedChatComesBackRedactedThroughTheEndpoint() throws {
        let fixture = try Fixture()
        let endpoint = try fixture.endpoint(filter: ChatFeedFilter(hidesCodeBlocks: true, redactsHealthData: true))
        let all = try Self.everyTool(endpoint).values.joined(separator: "\n")
            + (try Self.result(endpoint, ChatFeedMCPServer.readTool, ["chat_id": .string("open-2")]).0.compact())
        for planted in ["PLANTEDfake", "PLANTED0987", "hunter2planted", Self.plantedJWT, "Tr0ub4dorPlanted", "let plantedCode",
                        "Maria da Silva", "123.456.789-09", "03/04/1980", "778899", "898 0012"] {
            #expect(!all.contains(planted), "\(planted) leaked")
        }
        #expect(all.contains("[bloco de código: swift, 2 linhas]"))
        #expect(all.contains("[REDACTED]"))
    }

    // MARK: HTTP

    @Test func everyRequestWithoutTheRightTokenGets401AndNoBody() throws {
        let fixture = try Fixture()
        let endpoint = try fixture.endpoint()
        let requests = [
            Self.post(Self.rpc("tools/list"), token: nil),
            Self.post(Self.rpc("tools/list"), token: "abs_wrong"),
            Self.post(Self.rpc("tools/list"), token: String(Self.token.dropLast())),
            Self.post(Self.call(ChatFeedMCPServer.listTool), token: Self.token + "x"),
            Self.post(Self.rpc("initialize"), token: nil, headers: ["Authorization": Self.token]),
            Self.post(Self.rpc("initialize"), token: nil, headers: ["Authorization": "Basic \(Self.token)"]),
            FeedHTTPRequest(method: "GET", path: "/mcp"),
            FeedHTTPRequest(method: "GET", path: "/anything"),
        ]
        for request in requests {
            let response = endpoint.respond(to: request)
            #expect(response.status == 401)
            #expect(response.body.isEmpty)
        }
        // No token set at all: nothing answers, whatever is sent.
        endpoint.configuration.token = nil
        #expect(endpoint.respond(to: Self.post(Self.rpc("tools/list"))).status == 401)
    }

    @Test func rotatingOrRevokingTakesEffectOnTheNextRequest() throws {
        let fixture = try Fixture()
        let endpoint = try fixture.endpoint()
        #expect(endpoint.respond(to: Self.post(Self.rpc("ping"))).status == 200)
        endpoint.configuration.token = "abs_rotated"
        #expect(endpoint.respond(to: Self.post(Self.rpc("ping"))).status == 401)
        #expect(endpoint.respond(to: Self.post(Self.rpc("ping"), token: "abs_rotated")).status == 200)
        endpoint.configuration.token = nil
        #expect(endpoint.respond(to: Self.post(Self.rpc("ping"), token: "abs_rotated")).status == 401)
    }

    @Test func the61stRequestInAMinuteGets429() throws {
        let fixture = try Fixture()
        let now = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
        let endpoint = try fixture.endpoint(clock: { now.withLock { $0 } })
        for i in 1...60 {
            #expect(endpoint.respond(to: Self.post(Self.rpc("ping", id: i))).status == 200)
            now.withLock { $0 += 0.5 }
        }
        let limited = endpoint.respond(to: Self.post(Self.rpc("ping", id: 61)))
        #expect(limited.status == 429)
        #expect(limited.headers["Retry-After"] == "30")
        // Wrong tokens don't use up the right one's allowance, and get 401, not 429.
        #expect(endpoint.respond(to: Self.post(Self.rpc("ping"), token: "abs_wrong")).status == 401)
        now.withLock { $0 += 31 }
        #expect(endpoint.respond(to: Self.post(Self.rpc("ping", id: 62))).status == 200)
    }

    @Test func originsMustBeAllowListed() throws {
        let fixture = try Fixture()
        let endpoint = try fixture.endpoint(origins: ["https://grok.example"])
        #expect(endpoint.respond(to: Self.post(Self.rpc("ping"), headers: ["Origin": "https://evil.example"])).status == 403)
        #expect(endpoint.respond(to: Self.post(Self.rpc("ping"), headers: ["Origin": "http://127.0.0.1:4319"])).status == 403)
        #expect(endpoint.respond(to: Self.post(Self.rpc("ping"), headers: ["Origin": "https://grok.example"])).status == 200)
        #expect(endpoint.respond(to: Self.post(Self.rpc("ping"))).status == 200)
    }

    @Test func onlyPostToMcpAnswers() throws {
        let fixture = try Fixture()
        let endpoint = try fixture.endpoint()
        let auth = ["Authorization": "Bearer \(Self.token)"]
        #expect(endpoint.respond(to: FeedHTTPRequest(method: "GET", path: "/mcp", headers: auth)).status == 405)
        #expect(endpoint.respond(to: FeedHTTPRequest(method: "DELETE", path: "/mcp", headers: auth)).status == 405)
        #expect(endpoint.respond(to: FeedHTTPRequest(method: "POST", path: "/other", headers: auth)).status == 404)
        var big = Self.post(Self.rpc("ping"))
        big.bodyTooLarge = true
        #expect(endpoint.respond(to: big).status == 413)
        var text = Self.post(Self.rpc("ping"))
        text.headers["content-type"] = "text/plain"
        #expect(endpoint.respond(to: text).status == 415)
        let batch = Self.post(.array([Self.rpc("ping"), Self.rpc("ping", id: 2)]))
        #expect(endpoint.respond(to: batch).status == 400)
        #expect(endpoint.respond(to: Self.post(Self.rpc("ping"), headers: ["MCP-Protocol-Version": "1999-01-01"])).status == 400)
        let note = JSONValue.object(["jsonrpc": .string("2.0"), "method": .string("notifications/initialized")])
        let accepted = endpoint.respond(to: Self.post(note))
        #expect(accepted.status == 202 && accepted.body.isEmpty)
    }

    @Test func responsesAreCappedAt1MB() throws {
        let fixture = try Fixture()
        let long = String(repeating: "palavra ", count: 1_000)
        let reader = ReadsOnly(chats: [FeedChat(id: "big", title: "Big", projectName: nil, createdAt: Date(), updatedAt: Date(), isActive: false)],
                               log: ["big": Array(repeating: FeedMessage(author: .agent, at: Date(), text: long), count: 200)])
        let endpoint = ChatFeedEndpoint(reader: reader, configuration: .init(token: Self.token), log: ChatFeedLog(url: fixture.logURL))
        let response = endpoint.respond(to: Self.post(Self.call(ChatFeedMCPServer.readTool, ["chat_id": .string("big"), "limite": .number(200)])))
        #expect(response.status == 200)
        #expect(response.body.count < ChatFeedEndpoint.maxResponse)
        #expect(String(decoding: response.body, as: UTF8.self).contains("1 MB"))
        let fits = endpoint.respond(to: Self.post(Self.call(ChatFeedMCPServer.readTool, ["chat_id": .string("big"), "limite": .number(50)])))
        #expect(!String(decoding: fits.body, as: UTF8.self).contains("1 MB"))
    }

    @Test func theLogHasOneLinePerCallAndNoContentOrToken() throws {
        let fixture = try Fixture()
        let endpoint = try fixture.endpoint(filter: ChatFeedFilter(redactsHealthData: true))
        _ = try Self.everyTool(endpoint)
        _ = endpoint.respond(to: Self.post(Self.call(ChatFeedMCPServer.searchTool, ["consulta": .string("hunter2planted")])))
        _ = endpoint.respond(to: Self.post(Self.call(ChatFeedMCPServer.readTool, ["chat_id": .string("<script>planted query</script>")])))
        _ = endpoint.respond(to: Self.post(Self.rpc("tools/list"), token: "abs_wrong-planted-token"))
        _ = endpoint.respond(to: FeedHTTPRequest(method: "GET", path: "/mcp?token=\(Self.token)"))
        _ = endpoint.respond(to: Self.post(.object(["jsonrpc": .string("2.0"), "method": .string("notifications/planted query")])))
        let text = try String(contentsOf: fixture.logURL, encoding: .utf8)
        let lines = text.split(separator: "\n")
        #expect(lines.count == 9)
        for planted in [Self.token, "abs_wrong-planted-token", "hunter2planted", "planted query", "Retry webhooks", "webhook",
                        "PLANTED", "Maria", "consulta", "texto", "/tmp/made-up"] {
            #expect(!text.contains(planted), "\(planted) is in the log")
        }
        let entries = ChatFeedLog(url: fixture.logURL).recent(20)
        #expect(entries.count == 9)
        #expect(entries.map(\.code) == [202, 401, 401, 200, 200, 200, 200, 200, 200])
        #expect(entries.first?.method == "notification")
        #expect(entries.last?.tool == ChatFeedMCPServer.listTool)
        #expect(entries.contains { $0.tool == ChatFeedMCPServer.readTool && $0.chatId == "open-1" })
        #expect(entries.first { $0.tool == ChatFeedMCPServer.readTool && $0.toolError == true }?.chatId == nil)
    }

    @Test func theLogRotatesAt5MB() throws {
        let fixture = try Fixture()
        let log = ChatFeedLog(url: fixture.logURL, maxBytes: 600)
        for i in 0..<20 { log.append(.init(time: Date(), tool: "ler_chat", chatId: "chat-\(i)", code: 200, ms: i)) }
        let size = try #require(try FileManager.default.attributesOfItem(atPath: fixture.logURL.path)[.size] as? Int)
        #expect(size <= 600)
        #expect(FileManager.default.fileExists(atPath: log.rotatedURL.path))
        #expect(log.recent(3).map(\.ms) == [19, 18, 17])
        #expect(ChatFeedLog(url: fixture.logURL).maxBytes == 5 << 20)
    }

    // MARK: Parsing and the socket

    @Test func parsesRequestsAsTheyArrive() {
        let body = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
        let raw = "POST /mcp?x=1 HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        guard case .incomplete = FeedHTTPParser.parse(Data(raw.utf8.dropLast(3))) else { Issue.record("not incomplete"); return }
        guard case .request(let request) = FeedHTTPParser.parse(Data(raw.utf8)) else { Issue.record("no request"); return }
        #expect(request.method == "POST" && request.path == "/mcp" && request.headers["content-type"] == "application/json")
        #expect(String(decoding: request.body, as: UTF8.self) == body)
        let chunked = "POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n"
        guard case .request(let c) = FeedHTTPParser.parse(Data(chunked.utf8)) else { Issue.record("no chunked"); return }
        #expect(String(decoding: c.body, as: UTF8.self) == "hello world")
        guard case .request(let big) = FeedHTTPParser.parse(Data("POST /mcp HTTP/1.1\r\nContent-Length: 999999\r\n\r\n".utf8)) else {
            Issue.record("no big"); return
        }
        #expect(big.bodyTooLarge)
        guard case .invalid(let status) = FeedHTTPParser.parse(Data("garbage\r\n\r\n".utf8)) else { Issue.record("not invalid"); return }
        #expect(status == 400)
    }

    @Test func itIsOffByDefaultOnLoopback() throws {
        let settings = ChatFeedSettings()
        #expect(!settings.enabled)
        #expect(settings.endpointURL == "http://127.0.0.1:4319/mcp")
        #expect(settings.filter == ChatFeedFilter(hidesCodeBlocks: true, redactsHealthData: false))
        #expect(settings.allowedOrigins.isEmpty)
        let store = try Store.inMemory()
        #expect(store.setting(ChatFeedSettings.storeKey, as: ChatFeedSettings.self) == nil)
        #expect(ChatFeedSettings.origins(typed: " https://a.example/ ,https://b.example\n\nhttps://a.example") == ["https://a.example", "https://b.example"])
    }

    @Test func tokensAreLongRandomAndDistinct() {
        let a = ChatFeedEndpoint.makeToken(), b = ChatFeedEndpoint.makeToken()
        #expect(a != b && a.hasPrefix("abs_") && a.count == 47)
        #expect(ChatFeedEndpoint.constantTimeEqual(a, a) && !ChatFeedEndpoint.constantTimeEqual(a, b))
    }

    /// A whole MCP session over real HTTP: initialize, tools/list, tools/call.
    @Test func anMCPClientCompletesASessionOverLoopbackHTTP() async throws {
        let fixture = try Fixture()
        let endpoint = try fixture.endpoint()
        let ready = AsyncStream<ChatFeedListener.State>.makeStream()
        let listener = ChatFeedListener(endpoint: endpoint, port: 0) { ready.continuation.yield($0) }
        try listener.start()
        defer { listener.stop() }
        var port: UInt16 = 0
        for await state in ready.stream {
            if case .ready(let p) = state { port = p; break }
            if case .failed(let message) = state { Issue.record("listener failed: \(message)"); return }
        }
        let url = try #require(URL(string: "http://127.0.0.1:\(port)/mcp"))
        func send(_ body: JSONValue, token: String? = Self.token, method: String = "POST") async throws -> (Int, JSONValue?) {
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            if method == "POST" { request.httpBody = Data(body.compact().utf8) }
            let (data, response) = try await URLSession.shared.data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, try? JSONDecoder().decode(JSONValue.self, from: data))
        }
        let initialize = Self.rpc("initialize", params: .object([
            "protocolVersion": .string("2025-06-18"), "capabilities": .object([:]),
            "clientInfo": .object(["name": .string("test"), "version": .string("1")]),
        ]))
        let (status, info) = try await send(initialize)
        #expect(status == 200 && info?["result"]?["protocolVersion"]?.string == "2025-06-18")
        #expect(try await send(.object(["jsonrpc": .string("2.0"), "method": .string("notifications/initialized")])).0 == 202)
        let (_, list) = try await send(Self.rpc("tools/list", id: 2))
        #expect(list?["result"]?["tools"]?.array?.count == 4)
        let (_, call) = try await send(Self.call(ChatFeedMCPServer.listTool, id: 3))
        #expect(call?["result"]?["structuredContent"]?["chats"]?.array?.count == 3)
        #expect(try await send(Self.rpc("tools/list"), token: nil).0 == 401)
        #expect(try await send(Self.rpc("tools/list"), token: "abs_wrong").0 == 401)
        #expect(try await send(.null, method: "GET").0 == 405)
    }

    @Test func listensOnLoopbackOnly() async throws {
        let fixture = try Fixture()
        let ready = AsyncStream<ChatFeedListener.State>.makeStream()
        let listener = ChatFeedListener(endpoint: try fixture.endpoint(), port: 0) { ready.continuation.yield($0) }
        try listener.start()
        defer { listener.stop() }
        var port: UInt16 = 0
        for await state in ready.stream { if case .ready(let p) = state { port = p; break } }
        // Bound to 127.0.0.1: the port isn't open on the Mac's other addresses.
        let bound = try #require(Self.boundAddresses(port: port))
        #expect(bound == ["127.0.0.1"])
    }

    /// The local addresses listening on `port`, as `lsof` sees them.
    static func boundAddresses(port: UInt16) -> Set<String>? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-a", "-p", String(getpid()), "-iTCP:\(port)", "-sTCP:LISTEN", "-Fn"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let names = String(decoding: data, as: UTF8.self).split(separator: "\n").filter { $0.hasPrefix("n") }
        return Set(names.compactMap { $0.dropFirst().split(separator: ":").first.map(String.init) })
    }
}
