import Darwin
import Foundation

/// How ABEL (`Abel.app`) and Abstract talk, both ways, on this Mac only.
///
/// ABEL asks Abstract over Abstract's own `AppLink` socket (what's on
/// screen, put this text in the reply box, send it). Abstract and the
/// `abstract` command ask ABEL over ABEL's socket (speak this reply, are
/// you listening). Each request is one line of JSON and gets one line
/// back. Both sockets are per data folder, so a demo never reaches the
/// real app, and neither ever leaves the Mac.
public enum AbelLink {
    /// ABEL's helper app, inside Abstract.app at `Contents/Library/LoginItems`.
    public static let bundleIdentifier = "sh.abstract.abel"
    public static let appName = "Abel.app"
    /// Where Abel.app sits inside Abstract.app.
    public static let bundledPath = "Contents/Library/LoginItems/Abel.app"

    /// Runs blocking socket work on a GCD thread, never on Swift's
    /// cooperative pool: a pool thread waiting on a reply could be the one
    /// the reply needs, and on a small machine every thread is.
    public static func offThePool<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
        }
    }

    // MARK: ABEL asking Abstract

    /// What ABEL asks Abstract.
    public struct Request: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable {
            /// What's on screen, the names ABEL listens for, and its settings.
            case context
            /// Put `text` in the reply box of the chat on screen (or `chatId`).
            case dictate
            /// Send the reply box of the chat on screen (or `chatId`), as Send would.
            case sendDraft
            /// Show `chatId` in Abstract's window (ABS-204).
            case open
            /// `chatId`'s last reply, as Markdown, in `text`.
            case reply
            /// The first request waiting for an answer in `chatId` (or any chat), in `pending`.
            case pending
            /// Answer `requestId` in `chatId`: `allow` or decline.
            case answer
            /// Stop `chatId`'s agent.
            case stop
            /// Pause every agent.
            case pauseAll
            /// Start a chat in `projectId` (or one of its own) with `text` as its prompt.
            case startChat
            /// Send `text` to `chatId` as a follow-up.
            case tell
            /// Open the screen where you do what ABEL won't: `screen` is `pullRequest` or `chat`.
            case showScreen
            /// Ask ABEL's own chat `text`; its answer is read aloud when it's done.
            case ask
            /// Bring Abstract forward on its new chat screen (the widget's pencil).
            case newChat
        }

        public var kind: Kind
        public var chatId: String?
        public var text: String?
        public var requestId: String?
        public var allow: Bool?
        public var projectId: String?
        public var screen: String?

        public init(kind: Kind, chatId: String? = nil, text: String? = nil, requestId: String? = nil, allow: Bool? = nil,
                    projectId: String? = nil, screen: String? = nil) {
            self.kind = kind; self.chatId = chatId; self.text = text; self.requestId = requestId; self.allow = allow
            self.projectId = projectId; self.screen = screen
        }
    }

    /// A request waiting in a chat, as ABEL reads it back.
    public struct Pending: Codable, Sendable, Equatable {
        public var chatId: String
        public var chatTitle: String
        public var requestId: String
        /// What answering yes lets through, in words: "run `swift test`".
        public var summary: String
        /// A question to answer in the chat, not a yes or no.
        public var isQuestion: Bool
        /// Too long or tangled to read back whole: only answered on screen.
        public var onScreenOnly: Bool

        public init(chatId: String, chatTitle: String, requestId: String, summary: String, isQuestion: Bool = false,
                    onScreenOnly: Bool = false) {
            self.chatId = chatId; self.chatTitle = chatTitle; self.requestId = requestId; self.summary = summary
            self.isQuestion = isQuestion; self.onScreenOnly = onScreenOnly
        }
    }

    /// Abstract's answer. `message` is a sentence ABEL can say when something
    /// didn't happen.
    public struct Reply: Codable, Sendable, Equatable {
        public var ok: Bool
        public var message: String?
        public var context: Context?
        /// The chat the request acted on.
        public var chatTitle: String?
        public var chatId: String?
        /// A reply's Markdown, for `reply`.
        public var text: String?
        public var pending: Pending?

        public init(ok: Bool, message: String? = nil, context: Context? = nil, chatTitle: String? = nil,
                    chatId: String? = nil, text: String? = nil, pending: Pending? = nil) {
            self.ok = ok; self.message = message; self.context = context; self.chatTitle = chatTitle
            self.chatId = chatId; self.text = text; self.pending = pending
        }

        public static func failed(_ message: String) -> Reply { Reply(ok: false, message: message) }
    }

    /// What ABEL needs to know about Abstract right now.
    public struct Context: Codable, Sendable, Equatable {
        /// The chat showing in Abstract's window, if any.
        public var shownChatId: String?
        public var shownChatTitle: String?
        /// Whether Abstract is the app in front.
        public var isFrontmost: Bool
        /// This Mac's project, chat and agent names, for matching what was heard.
        public var vocabulary: AbelVocabulary
        public var settings: AbelSettings
        /// The theme Abstract is drawn in, so the orb matches it.
        public var themeId: String?
        /// This Mac's chats (needing you first) and projects (ABS-204).
        public var chats: [AbelChatInfo]
        public var projects: [AbelProjectInfo]

        public init(shownChatId: String? = nil, shownChatTitle: String? = nil, isFrontmost: Bool = false,
                    vocabulary: AbelVocabulary = AbelVocabulary(), settings: AbelSettings = AbelSettings(),
                    themeId: String? = nil, chats: [AbelChatInfo] = [], projects: [AbelProjectInfo] = []) {
            self.shownChatId = shownChatId; self.shownChatTitle = shownChatTitle; self.isFrontmost = isFrontmost
            self.vocabulary = vocabulary; self.settings = settings; self.themeId = themeId
            self.chats = chats; self.projects = projects
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            shownChatId = try c.decodeIfPresent(String.self, forKey: .shownChatId)
            shownChatTitle = try c.decodeIfPresent(String.self, forKey: .shownChatTitle)
            isFrontmost = try c.decodeIfPresent(Bool.self, forKey: .isFrontmost) ?? false
            vocabulary = try c.decodeIfPresent(AbelVocabulary.self, forKey: .vocabulary) ?? AbelVocabulary()
            settings = try c.decodeIfPresent(AbelSettings.self, forKey: .settings) ?? AbelSettings()
            themeId = try c.decodeIfPresent(String.self, forKey: .themeId)
            chats = try c.decodeIfPresent([AbelChatInfo].self, forKey: .chats) ?? []
            projects = try c.decodeIfPresent([AbelProjectInfo].self, forKey: .projects) ?? []
        }
    }

    /// One line on `AppLink`'s socket: ABEL's requests carry this key, which
    /// tells them from `abstract`'s start requests.
    public struct Envelope: Codable, Sendable {
        public var abel: Request
        public init(_ request: Request) { abel = request }
    }

    /// Asks the Abstract that owns `storePath`; nil when it isn't open.
    public static func ask(_ request: Request, storePath: String = Store.defaultPath(),
                           timeoutMs: Int32 = 5_000) -> Reply? {
        guard let fd = HostSocket.connect(path: AppLink.socketPath(storePath: storePath)) else { return nil }
        defer { close(fd) }
        guard let line = try? JSONEncoder().encode(Envelope(request)), HostSocket.writeLine(fd, line),
              let answer = HostSocket.readLine(fd, timeoutMs: timeoutMs) else { return nil }
        return try? JSONDecoder().decode(Reply.self, from: answer)
    }

    // MARK: Abstract (or `abstract`) asking ABEL

    public struct HelperRequest: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable {
            /// Read `text` (a reply's Markdown) aloud, saying it's from `chatTitle`.
            case speak
            /// Whether ABEL is listening, and why not.
            case status
            /// Settings changed: ask Abstract for them again.
            case reload
            /// What ABEL heard, did and said lately, newest last, as JSON in `message`.
            case history
            /// A tool call from ABEL's chat (ABS-204): `name`, with `text` its arguments as JSON.
            case tool
            /// `text`, acted on as if ABEL heard it (debug builds only: demos and checks).
            case hear
        }

        public var kind: Kind
        public var text: String?
        public var chatId: String?
        public var chatTitle: String?
        /// The tool, for `tool`.
        public var name: String?

        public init(kind: Kind, text: String? = nil, chatId: String? = nil, chatTitle: String? = nil, name: String? = nil) {
            self.kind = kind; self.text = text; self.chatId = chatId; self.chatTitle = chatTitle; self.name = name
        }
    }

    public struct HelperReply: Codable, Sendable, Equatable {
        public var ok: Bool
        public var message: String?
        /// ABEL's state in words, for `status`: "Listening for “Hey Abel”", "Paused while the screen is shared".
        public var state: String?

        public init(ok: Bool, message: String? = nil, state: String? = nil) {
            self.ok = ok; self.message = message; self.state = state
        }
    }

    /// ABEL's own socket for this data folder.
    public static func helperSocketPath(storePath: String = Store.defaultPath()) -> String {
        (NSTemporaryDirectory() as NSString).appendingPathComponent("abel-\(WorktreeNaming.shortHash(storePath)).sock")
    }

    /// Asks the running ABEL; nil when it isn't running.
    public static func tell(_ request: HelperRequest, storePath: String = Store.defaultPath(),
                            timeoutMs: Int32 = 5_000) -> HelperReply? {
        guard let fd = HostSocket.connect(path: helperSocketPath(storePath: storePath)) else { return nil }
        defer { close(fd) }
        guard let line = try? JSONEncoder().encode(request), HostSocket.writeLine(fd, line),
              let answer = HostSocket.readLine(fd, timeoutMs: timeoutMs) else { return nil }
        return try? JSONDecoder().decode(HelperReply.self, from: answer)
    }

    /// A one-line JSON server on a Unix socket: ABEL's, or a test's.
    public final class LineServer<In: Decodable & Sendable, Out: Encodable & Sendable>: @unchecked Sendable {
        private let fd: Int32
        private let path: String
        private let source: any DispatchSourceRead

        /// Listens at `path`; nil when another process already does, or the
        /// socket can't be made.
        public init?(path: String, handler: @escaping @Sendable (In) async -> Out) {
            if let other = HostSocket.connect(path: path) {
                close(other)
                return nil
            }
            unlink(path)
            guard let fd = try? HostSocket.listen(path: path) else { return nil }
            self.fd = fd
            self.path = path
            source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "sh.abstract.abel-link"))
            source.setEventHandler {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                var on: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                guard let line = HostSocket.readLine(client, timeoutMs: 5_000),
                      let request = try? JSONDecoder().decode(In.self, from: line) else {
                    close(client)
                    return
                }
                Task {
                    let reply = await handler(request)
                    HostSocket.writeLine(client, (try? JSONEncoder().encode(reply)) ?? Data())
                    close(client)
                }
            }
            source.resume()
        }

        public func stop() {
            source.cancel()
            close(fd)
            unlink(path)
        }
    }
}
