import Foundation

/// The chat feed (ABS-217): a read-only MCP server that lets another
/// assistant follow your open chats. Four tools, named and shaped as the
/// owner asked, over a `ChatFeedReader` that can only read. Every text it
/// returns goes through `ChatFeedFilter` first. The HTTP side, with the
/// token, the rate limit and the log, is `ChatFeedHTTP`.
public struct ChatFeedMCPServer: Sendable {
    public static let serverName = "abstract-chat-feed"
    public static let listTool = "listar_chats_abertos"
    public static let readTool = "ler_chat"
    public static let searchTool = "buscar_nos_chats"
    public static let recentTool = "atividade_recente"
    public static let toolNames = [listTool, readTool, searchTool, recentTool]

    static let knownNotifications: Set<String> = ["notifications/initialized", "notifications/cancelled",
                                                   "notifications/progress", "notifications/roots/list_changed"]

    /// Newest first; `initialize` answers with the client's when it's one of these.
    public static let protocolVersions = ["2026-07-28", "2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    static let readDefault = 50, readMax = 200
    static let searchDefault = 20, searchMax = 50
    /// A message longer than this is cut, so one pasted log can't fill a reply.
    static let messageMax = 8_000
    static let excerptRadius = 80
    static let recentCount = 3, recentLength = 280

    let reader: any ChatFeedReader
    let filter: ChatFeedFilter
    let now: @Sendable () -> Date

    public init(reader: any ChatFeedReader, filter: ChatFeedFilter, now: @escaping @Sendable () -> Date = { Date() }) {
        self.reader = reader
        self.filter = filter
        self.now = now
    }

    /// What one JSON-RPC message came to, with what the log may keep about it.
    public struct Reply: Sendable {
        /// nil for a notification: the HTTP side answers 202 with no body.
        public var body: JSONValue?
        public var method: String?
        public var tool: String?
        public var chatId: String?
        public var isError: Bool
    }

    public func handle(_ request: JSONValue) -> Reply {
        guard case .object = request, request["jsonrpc"]?.string == "2.0", let method = request["method"]?.string else {
            return Reply(body: error(.null, -32600, "Invalid request."), method: nil, tool: nil, chatId: nil, isError: true)
        }
        // A notification (`notifications/initialized` and the like) changes nothing here.
        // Its name reaches the log only when it's a known one: the rest is the client's text.
        guard let id = request["id"], id != .null else {
            let known = Self.knownNotifications.contains(method) ? method : "notification"
            return Reply(body: nil, method: known, tool: nil, chatId: nil, isError: false)
        }
        let params = request["params"] ?? .object([:])
        switch method {
        case "initialize":
            let asked = params["protocolVersion"]?.string ?? ""
            let version = Self.protocolVersions.contains(asked) ? asked : Self.protocolVersions[0]
            return Reply(body: result(id, .object([
                "protocolVersion": .string(version),
                "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
                "serverInfo": .object(["name": .string(Self.serverName), "title": .string("Abstract chat feed"),
                                       "version": .string("1")]),
                "instructions": .string("""
                    Somente leitura: os chats abertos no Abstract deste Mac. Segredos e, se configurado, blocos de \
                    código e dados de saúde chegam substituídos por marcadores.
                    """),
            ])), method: method, tool: nil, chatId: nil, isError: false)
        case "ping":
            return Reply(body: result(id, .object([:])), method: method, tool: nil, chatId: nil, isError: false)
        case "tools/list":
            return Reply(body: result(id, .object(["tools": .array(Self.tools)])), method: method, tool: nil, chatId: nil, isError: false)
        case "tools/call":
            let name = params["name"]?.string
            let arguments = params["arguments"] ?? .object([:])
            let tool = name.flatMap { Self.toolNames.contains($0) ? $0 : nil }
            let chatId = tool == Self.readTool ? arguments["chat_id"]?.string : nil
            let outcome = call(name ?? "", arguments)
            return Reply(body: result(id, outcome.value), method: method, tool: tool, chatId: chatId, isError: outcome.isError)
        default:
            return Reply(body: error(id, -32601, "Unknown method."), method: nil, tool: nil, chatId: nil, isError: true)
        }
    }

    private func result(_ id: JSONValue, _ value: JSONValue) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "result": value])
    }

    private func error(_ id: JSONValue, _ code: Int, _ message: String) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id,
                 "error": .object(["code": .number(Double(code)), "message": .string(message)])])
    }

    // MARK: Tools

    private struct Failure: Error { let message: String }

    private func call(_ name: String, _ arguments: JSONValue) -> (value: JSONValue, isError: Bool) {
        do {
            let value: JSONValue = switch name {
            case Self.listTool: try listOpenChats(arguments)
            case Self.readTool: try readChat(arguments)
            case Self.searchTool: try search(arguments)
            case Self.recentTool: try recentActivity(arguments)
            default: throw Failure(message: "Ferramenta desconhecida.")
            }
            return (.object(["content": .array([.object(["type": .string("text"), "text": .string(value.compact())])]),
                             "structuredContent": value, "isError": .bool(false)]), false)
        } catch let failure as Failure {
            return (errorContent(failure.message), true)
        } catch {
            // Never the database's own message: it could name a path.
            return (errorContent("Não foi possível ler os chats agora."), true)
        }
    }

    private func errorContent(_ message: String) -> JSONValue {
        .object(["content": .array([.object(["type": .string("text"), "text": .string(message)])]), "isError": .bool(true)])
    }

    private func listOpenChats(_ a: JSONValue) throws -> JSONValue {
        let project = try optionalString(a, "projeto")
        let since = try optionalDate(a, "atualizado_desde")
        let chats = try reader.openChats().filter { chat in
            if let project, chat.projectName?.compare(project, options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame {
                return false
            }
            if let since, chat.updatedAt < since { return false }
            return true
        }
        return .object(["chats": .array(try chats.map { chat in
            .object([
                "chat_id": .string(chat.id),
                "titulo": .string(filter.apply(chat.title)),
                "projeto": chat.projectName.map { .string(filter.apply($0)) } ?? .null,
                "criado_em": .string(Self.format(chat.createdAt)),
                "atualizado_em": .string(Self.format(chat.updatedAt)),
                "quantidade_mensagens": .number(Double(try reader.messages(chatId: chat.id).count)),
                "status": .string(chat.isActive ? "ativo" : "ocioso"),
            ])
        })])
    }

    private func readChat(_ a: JSONValue) throws -> JSONValue {
        guard let id = a["chat_id"]?.string, !id.isEmpty else { throw Failure(message: "ler_chat precisa de chat_id.") }
        let limit = try optionalInt(a, "limite").map { min(max($0, 1), Self.readMax) } ?? Self.readDefault
        let since = try optionalDate(a, "desde")
        var start = 0
        if let cursor = try optionalString(a, "cursor") {
            guard let n = Int(cursor), n >= 0 else { throw Failure(message: "cursor inválido.") }
            start = n
        }
        // Archived, deleted and unknown chats all read the same: not found.
        guard try reader.openChat(id) != nil else { throw Failure(message: "Chat não encontrado.") }
        let all = try reader.messages(chatId: id).enumerated().filter { _, m in
            guard let since else { return true }
            return m.at.map { $0 >= since } ?? false
        }
        let page = all.drop { $0.offset < start }.prefix(limit)
        let next = page.count == limit ? all.drop { $0.offset <= page.last!.offset }.first?.offset : nil
        return .object([
            "chat_id": .string(id),
            "mensagens": .array(page.map { message($0.element, cut: Self.messageMax) }),
            "proximo_cursor": next.map { .string(String($0)) } ?? .null,
        ])
    }

    private func search(_ a: JSONValue) throws -> JSONValue {
        guard let query = a["consulta"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty,
              query.count <= 200 else {
            throw Failure(message: "buscar_nos_chats precisa de uma consulta de até 200 caracteres.")
        }
        let limit = try optionalInt(a, "limite").map { min(max($0, 1), Self.searchMax) } ?? Self.searchDefault
        var hits: [(chat: FeedChat, at: Date?, excerpt: String)] = []
        for chat in try reader.openChats() {
            for message in try reader.messages(chatId: chat.id) {
                // Searched after filtering, so a query can't find what the feed hides.
                let text = filter.apply(message.text)
                guard let range = TranscriptSearch.ranges(of: query, in: text).first else { continue }
                hits.append((chat, message.at, Self.excerpt(text, around: range)))
            }
        }
        hits.sort { ($0.at ?? .distantPast) > ($1.at ?? .distantPast) }
        return .object(["resultados": .array(hits.prefix(limit).map { hit in
            .object([
                "chat_id": .string(hit.chat.id),
                "titulo": .string(filter.apply(hit.chat.title)),
                "timestamp": hit.at.map { .string(Self.format($0)) } ?? .null,
                "trecho": .string(hit.excerpt),
            ])
        })])
    }

    private func recentActivity(_ a: JSONValue) throws -> JSONValue {
        let since = try optionalDate(a, "desde") ?? now().addingTimeInterval(-24 * 3600)
        var out: [(Date, JSONValue)] = []
        for chat in try reader.openChats() {
            let messages = try reader.messages(chatId: chat.id)
            let last = messages.last?.at ?? (messages.isEmpty ? nil : chat.updatedAt)
            guard let last, last >= since else { continue }
            out.append((last, .object([
                "chat_id": .string(chat.id),
                "titulo": .string(filter.apply(chat.title)),
                "ultima_mensagem_em": .string(Self.format(last)),
                "ultimas_mensagens": .array(messages.suffix(Self.recentCount).map { message($0, cut: Self.recentLength) }),
            ])))
        }
        return .object(["chats": .array(out.sorted { $0.0 > $1.0 }.map(\.1))])
    }

    private func message(_ m: FeedMessage, cut: Int) -> JSONValue {
        .object([
            "autor": .string(m.author.rawValue),
            "timestamp": m.at.map { .string(Self.format($0)) } ?? .null,
            "texto": .string(Self.shortened(filter.apply(m.text), to: cut)),
        ])
    }

    // MARK: Arguments

    private func optionalString(_ a: JSONValue, _ key: String) throws -> String? {
        guard let value = a[key], value != .null else { return nil }
        guard let s = value.string else { throw Failure(message: "\(key) precisa ser texto.") }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func optionalInt(_ a: JSONValue, _ key: String) throws -> Int? {
        guard let value = a[key], value != .null else { return nil }
        if let n = value.double, n.isFinite, n.rounded() == n, abs(n) < 1e9 { return Int(n) }
        if let s = value.string, let n = Int(s) { return n }
        throw Failure(message: "\(key) precisa ser um número inteiro.")
    }

    private func optionalDate(_ a: JSONValue, _ key: String) throws -> Date? {
        guard let s = try optionalString(a, key) else { return nil }
        guard let date = Self.parse(s) else { throw Failure(message: "\(key) precisa ser uma data ISO 8601.") }
        return date
    }

    // MARK: Text and dates

    static func format(_ date: Date) -> String {
        date.formatted(.iso8601)
    }

    static func parse(_ text: String) -> Date? {
        if let d = try? Date(text, strategy: .iso8601) { return d }
        if let d = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return d }
        if let d = try? Date(text, strategy: Date.ISO8601FormatStyle().year().month().day()) { return d }
        return nil
    }

    static func shortened(_ text: String, to limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    static func excerpt(_ text: String, around range: Range<String.Index>) -> String {
        let start = text.index(range.lowerBound, offsetBy: -excerptRadius, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: excerptRadius, limitedBy: text.endIndex) ?? text.endIndex
        let body = text[start..<end].split(whereSeparator: \.isNewline).joined(separator: " ")
        return (start > text.startIndex ? "…" : "") + body + (end < text.endIndex ? "…" : "")
    }

    // MARK: Tool list

    private static func property(_ type: String, _ description: String) -> JSONValue {
        .object(["type": .string(type), "description": .string(description)])
    }

    private static func tool(_ name: String, _ title: String, _ description: String,
                             _ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        .object([
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object(properties),
                "required": .array(required.map(JSONValue.string)),
                "additionalProperties": .bool(false),
            ]),
            "annotations": .object(["readOnlyHint": .bool(true), "destructiveHint": .bool(false),
                                    "idempotentHint": .bool(true), "openWorldHint": .bool(false)]),
        ])
    }

    /// Exactly four tools, all read-only.
    public static let tools: [JSONValue] = [
        tool(listTool, "Chats abertos", """
            Lista os chats abertos no Abstract (não arquivados), do mais recente ao mais antigo: título, projeto, \
            datas, quantidade de mensagens e se o agente está trabalhando agora (ativo) ou não (ocioso).
            """, [
                "projeto": property("string", "Opcional: só os chats deste projeto, pelo nome."),
                "atualizado_desde": property("string", "Opcional: só os atualizados desde esta data (ISO 8601)."),
            ]),
        tool(readTool, "Ler um chat", """
            As mensagens de um chat aberto, da mais antiga para a mais nova: o que a pessoa escreveu (usuario) e as \
            respostas do agente (agente). Sem chamadas de ferramentas, saídas de comandos, diffs ou arquivos. \
            Use proximo_cursor para a próxima página.
            """, [
                "chat_id": property("string", "O chat_id de listar_chats_abertos."),
                "limite": property("integer", "Opcional: quantas mensagens, de 1 a 200 (padrão 50)."),
                "cursor": property("string", "Opcional: o proximo_cursor da resposta anterior."),
                "desde": property("string", "Opcional: só as mensagens desde esta data (ISO 8601)."),
            ], required: ["chat_id"]),
        tool(searchTool, "Buscar nos chats", """
            Busca um texto nas mensagens dos chats abertos, sem diferenciar maiúsculas nem acentos. Devolve trechos \
            curtos, dos mais recentes aos mais antigos.
            """, [
                "consulta": property("string", "O texto a buscar."),
                "limite": property("integer", "Opcional: quantos trechos, de 1 a 50 (padrão 20)."),
            ], required: ["consulta"]),
        tool(recentTool, "Atividade recente", """
            Os chats abertos com mensagens desde uma data (padrão: as últimas 24 horas), cada um com as suas três \
            últimas mensagens, encurtadas.
            """, [
                "desde": property("string", "Opcional: desde quando (ISO 8601). Padrão: 24 horas atrás."),
            ]),
    ]
}
