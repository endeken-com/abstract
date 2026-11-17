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
        }

        public var kind: Kind
        public var chatId: String?
        public var text: String?

        public init(kind: Kind, chatId: String? = nil, text: String? = nil) {
            self.kind = kind; self.chatId = chatId; self.text = text
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

        public init(ok: Bool, message: String? = nil, context: Context? = nil, chatTitle: String? = nil) {
            self.ok = ok; self.message = message; self.context = context; self.chatTitle = chatTitle
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

        public init(shownChatId: String? = nil, shownChatTitle: String? = nil, isFrontmost: Bool = false,
                    vocabulary: AbelVocabulary = AbelVocabulary(), settings: AbelSettings = AbelSettings(),
                    themeId: String? = nil) {
            self.shownChatId = shownChatId; self.shownChatTitle = shownChatTitle; self.isFrontmost = isFrontmost
            self.vocabulary = vocabulary; self.settings = settings; self.themeId = themeId
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
        }

        public var kind: Kind
        public var text: String?
        public var chatId: String?
        public var chatTitle: String?

        public init(kind: Kind, text: String? = nil, chatId: String? = nil, chatTitle: String? = nil) {
            self.kind = kind; self.text = text; self.chatId = chatId; self.chatTitle = chatTitle
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
