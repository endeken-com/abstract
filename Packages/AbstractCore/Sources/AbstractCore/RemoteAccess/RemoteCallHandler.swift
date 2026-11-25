import Foundation

/// The chat feed's reader narrowed to a grant's projects (ABS-219): chats
/// in other projects don't exist for it, in any of the four tools, and
/// `ler_chat` answers "not found" for them.
public struct ProjectScopedReader: ChatFeedReader {
    let base: any ChatFeedReader
    let projects: RemoteProjects

    public init(base: any ChatFeedReader, projects: RemoteProjects) {
        self.base = base
        self.projects = projects
    }

    public func openChats() throws -> [FeedChat] {
        try base.openChats().filter { projects.allows($0.projectId) }
    }

    public func openChat(_ id: String) throws -> FeedChat? {
        try base.openChat(id).flatMap { projects.allows($0.projectId) ? $0 : nil }
    }

    public func messages(chatId: String) throws -> [FeedMessage] {
        try openChat(chatId) == nil ? [] : base.messages(chatId: chatId)
    }
}

extension RemoteProjects {
    /// Only what both allow: the Mac's own grant is the source of truth, and
    /// the copy the gateway sent can narrow it but never widen it.
    func intersection(_ other: RemoteProjects) -> RemoteProjects {
        switch (self, other) {
        case (.all, let x), (let x, .all): x
        case let (.only(a), .only(b)): .only(a.intersection(b))
        }
    }
}

/// Answers one call forwarded by the gateway, on this Mac: the grant must be
/// one this Mac made and hasn't revoked; then the same `ChatFeedEndpoint` as
/// `127.0.0.1:4319` answers it in process, with a token that never leaves
/// this process, the grant's projects, and redaction (code blocks and
/// secrets always; health data when the grant asks).
public struct RemoteCallHandler: Sendable {
    let reader: any ChatFeedReader
    let log: ChatFeedLog?
    /// Made per handler, kept in memory: the in-process endpoint's own token.
    private let token = ChatFeedEndpoint.makeToken()

    public init(reader: any ChatFeedReader, log: ChatFeedLog?) {
        self.reader = reader
        self.log = log
    }

    public struct Answer: Sendable, Hashable {
        public var status: Int
        public var body: String
    }

    /// `grant`: this Mac's record for the call's grant id, if it has one.
    /// `projects`: the copy the gateway sent with the call.
    public func answer(_ body: String, grant: RemoteGrant?, projects: RemoteProjects) -> Answer {
        guard let grant, grant.isActive else {
            return Answer(status: 403, body: JSONValue.object([
                "jsonrpc": .string("2.0"), "id": .null,
                "error": .object(["code": .number(-32001), "message": .string("This Mac doesn't recognise that grant.")]),
            ]).compact())
        }
        let endpoint = ChatFeedEndpoint(
            reader: ProjectScopedReader(base: reader, projects: grant.projects.intersection(projects)),
            configuration: .init(token: token, filter: ChatFeedFilter(hidesCodeBlocks: true, redactsHealthData: grant.redactsHealthData)),
            log: log)
        let response = endpoint.respond(to: FeedHTTPRequest(
            method: "POST", path: ChatFeedEndpoint.path,
            headers: ["Authorization": "Bearer \(token)", "Content-Type": "application/json"],
            body: Data(body.utf8)))
        return Answer(status: response.status, body: String(decoding: response.body, as: UTF8.self))
    }
}
