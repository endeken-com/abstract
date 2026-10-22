import Foundation

/// Every message a plugin sends, validated before anything acts on it
/// (ABS-84 §4): known type, capability granted, payload within limits, and
/// `openChat` only for a chat in the last snapshot. A bad message is refused
/// and counted; it can never throw into the app.
public struct PluginBridge: Sendable {
    /// The newest bridge version; API 1 plugins still speak 1 (ABS-92).
    public static let api = 2
    public static let supportedAPIs: Set<Int> = [1, 2]
    /// One inbound message may not pass this many bytes.
    public static let messageByteLimit = 64 * 1024
    /// A `fetch` message may carry a body up to the network limit (ABS-94),
    /// plus its envelope. Every other type stays at `messageByteLimit`.
    public static let fetchMessageByteLimit = PluginFetchService.bodyByteLimit + 64 * 1024
    /// More than this in the window is a flood.
    public static let floodCount = 100
    public static let floodWindow: TimeInterval = 10
    /// Actions are rarer than messages: more than this in a minute
    /// pauses the plugin (ABS-92).
    public static let actionLimit = 10
    public static let actionWindow: TimeInterval = 60
    /// A message or prompt an action may carry.
    public static let actionTextLimit = 20_000
    /// Review comments one message may add, and how long each may be (ABS-112).
    public static let reviewCommentLimit = 50
    public static let reviewCommentTextLimit = 2_000
    /// A notice is one short sentence.
    public static let noticeTextLimit = 200
    /// The most a sidebar badge counts (ABS-111).
    public static let badgeLimit = 9_999

    public var capabilities: Set<PluginCapability>
    /// Action kinds the person always allows for this plugin; every
    /// other granted kind asks first (ABS-92).
    public var alwaysAllowedActions: Set<PluginCapability>
    /// Granted hosts and secret names (ABS-94), from the plugin's record.
    public var allowedHosts: Set<String>
    public var secretNames: Set<String>
    public var knownChatIds: Set<String> = []
    /// Projects from the last snapshot, the ones a new chat may start in.
    public var knownProjectKeys: Set<String> = []
    /// Set for a background script (ABS-93): only it may subscribe to
    /// events and schedule jobs.
    public var isBackground = false
    /// The command-line tool granted with `cli` (ABS-139), from the record.
    public var cli: PluginCLI?
    /// Whether its manifest declares a code host (ABS-139): only then may
    /// its background script answer core's calls.
    public var isCodeHost = false
    /// The project whose settings this page is a section of (ABS-143),
    /// by its snapshot key and its id: only then may it read and save that
    /// project's tracker link, kept under the id.
    public var project: (key: String, id: String)?
    public private(set) var refusalCount = 0
    public private(set) var lastRefusal: String?
    private var recent: [Date] = []
    private var recentActions: [Date] = []

    public init(capabilities: Set<PluginCapability>, allowedHosts: Set<String> = [], secretNames: Set<String> = [],
                alwaysAllowedActions: Set<PluginCapability> = []) {
        self.capabilities = capabilities
        self.allowedHosts = Set(allowedHosts.map { $0.lowercased() })
        self.secretNames = secretNames
        self.alwaysAllowedActions = alwaysAllowedActions
    }

    public enum Outcome: Sendable, Equatable {
        /// Answer the plugin's request `id` with this value.
        case reply(id: String?, JSONValue)
        case openChat(id: String?, chatId: String)
        case getSnapshot(id: String?)
        /// Send this through `PluginFetchService`, then answer by `id`.
        case fetch(id: String?, PluginFetchRequest)
        case getUsage(id: String?, view: String, page: PluginPage, chatId: String?)
        case getTurns(id: String?, page: PluginPage, chatId: String?)
        case getTranscript(id: String?, page: PluginPage, chatId: String?)
        case getAutomations(id: String?, page: PluginPage)
        /// One chat's pull request in full, as the host knows it now (ABS-109).
        case getPullRequest(id: String?, chatId: String)
        /// The permission requests and questions waiting across chats (ABS-111).
        case getPermissions(id: String?)
        /// Show this count on the plugin's sidebar row; 0 hides it.
        case badge(id: String?, count: Int)
        /// Add these comments to the chat's Review, marked with `author` (ABS-112).
        case addReviewComments(id: String?, chatId: String, author: String, [PluginReviewComment])
        /// Show this, with the plugin's name, where Abstract shows its own notices.
        case notice(id: String?, text: String)
        /// Carry this action out: its kind is always allowed (ABS-92).
        case action(id: String?, PluginAction)
        /// Ask the person first; carry it out only if they allow it.
        case askAction(id: String?, PluginAction)
        /// The plugin acted too often; the host pauses it with a notice.
        case actionRateLimited(id: String?)
        /// Deliver these events to the background script from now on.
        case subscribe(id: String?, Set<PluginEventType>)
        /// Add or replace a job; the host checks the schedule (ABS-93).
        case scheduleJob(id: String?, jobId: String, rrule: String, timezone: String?)
        case cancelJob(id: String?, jobId: String)
        /// The script finished one run of this job.
        case jobDone(jobId: String)
        /// The script's answer to an agent's tool call (ABS-97): text or
        /// JSON, or why it failed.
        case toolResult(callId: String, PluginToolOutcome)
        /// The script's answer to a link lookup (ABS-126): a status to
        /// show after the link, nothing, or why it couldn't say.
        case linkResult(callId: String, PluginLinkLookup)
        /// The script's answer to an issue tracker question (ABS-141),
        /// read against the question once it's matched to its call.
        case trackerResult(callId: String, JSONValue?)
        /// Run this declared command (ABS-139); the host picks the folder
        /// and executor, and asks first for a write it may not run unasked.
        case runCLI(id: String?, PluginCLIRequest)
        /// The script's answer to one of core's code host calls (ABS-139).
        case codeHostResult(callId: String, PluginCodeHostAnswer)
        /// Hosts the script's tool is signed in to besides its manifest's
        /// (GitHub Enterprise, say), for as long as it runs.
        case codeHostHosts(id: String?, Set<String>)
        /// A project's tracker link was saved (ABS-143): answer by `id` with
        /// the value, and show the project's new tracker.
        case projectLinkSaved(id: String?, projectKey: String, JSONValue)
        case refused(id: String?, reason: String)
        /// The plugin flooded the bridge; the host tears its view down.
        case flooded
    }

    public mutating func handle(_ data: Data, storage: PluginStorage, now: Date = Date()) -> Outcome {
        if isFlood(now: now) { return .flooded }
        guard data.count <= Self.fetchMessageByteLimit,
              let object = try? JSONSerialization.jsonObject(with: data),
              case .object(let message) = JSONValue(any: object) else {
            return refuse(nil, "That message couldn't be read.")
        }
        // Only fetch, a tool's result (ABS-97), a code host's answer
        // (ABS-139) and a tracker's answer (ABS-141) may use the larger limit.
        if data.count > Self.messageByteLimit,
           !["fetch", "tools.result", "codeHost.result", "tracker.result"].contains(message["type"]?.string ?? "") {
            return refuse(message["id"]?.string, "That message couldn't be read.")
        }
        return handle(message, storage: storage, now: now)
    }

    public mutating func handle(_ text: String, storage: PluginStorage, now: Date = Date()) -> Outcome {
        handle(Data(text.utf8), storage: storage, now: now)
    }

    private mutating func handle(_ message: [String: JSONValue], storage: PluginStorage, now: Date) -> Outcome {
        let id = message["id"]?.string
        guard let api = message["api"]?.int, Self.supportedAPIs.contains(api) else {
            return refuse(id, "Unsupported bridge version.")
        }
        guard let type = message["type"]?.string else { return refuse(id, "That message has no type.") }
        let payload = message["payload"]
        switch type {
        case "getSnapshot":
            guard capabilities.contains(.chatsRead) || capabilities.contains(.projectsRead) else {
                return refuse(id, "This plugin hasn't been granted reading your chats or projects.")
            }
            return .getSnapshot(id: id)
        case "openChat":
            guard capabilities.contains(.chatsOpen) else {
                return refuse(id, "This plugin hasn't been granted opening chats.")
            }
            guard let chatId = payload?["chatId"]?.string, knownChatIds.contains(chatId) else {
                return refuse(id, "That chat isn't in the plugin's list.")
            }
            return .openChat(id: id, chatId: chatId)
        case "storage.get":
            guard capabilities.contains(.storageOwn) else {
                return refuse(id, "This plugin hasn't been granted remembering its settings.")
            }
            guard let key = payload?["key"]?.string else { return refuse(id, "That storage request has no key.") }
            let value = (try? storage.value(forKey: key)) ?? nil
            return .reply(id: id, .object(["key": .string(key), "value": value ?? .null]))
        case "storage.set":
            guard capabilities.contains(.storageOwn) else {
                return refuse(id, "This plugin hasn't been granted remembering its settings.")
            }
            guard let key = payload?["key"]?.string else { return refuse(id, "That storage request has no key.") }
            let value = payload?["value"]
            let saved = (try? storage.set(value == .null ? nil : value, forKey: key)) ?? false
            guard saved else { return refuse(id, "That would pass the plugin's storage limit.") }
            return .reply(id: id, .object(["key": .string(key), "saved": .bool(true)]))
        case "projectLink.get", "projectLink.set":
            // Kept in the plugin's own storage, written only by Abstract,
            // so it needs no storage grant and survives turning it off.
            guard let (projectKey, projectId) = project else {
                return refuse(id, "Only a project's Issue tracker section can link it.")
            }
            if type == "projectLink.get" {
                let link = TrackerProjectLink.read(storage, projectId: projectId)
                return .reply(id: id, .object(["projectKey": .string(projectKey), "link": link?.jsonValue() ?? .null]))
            }
            let raw = payload?["link"]
            let link = TrackerProjectLink(raw)
            guard link != nil || raw == nil || raw == .null else {
                return refuse(id, "A link names a team or a project, each with an id and a name.")
            }
            guard TrackerProjectLink.write(link, to: storage, projectId: projectId) else {
                return refuse(id, "That would pass the plugin's storage limit.")
            }
            return .projectLinkSaved(id: id, projectKey: projectKey,
                                     .object(["projectKey": .string(projectKey), "link": link?.jsonValue() ?? .null]))
        case "fetch":
            guard capabilities.contains(.network) else {
                return refuse(id, "This plugin hasn't been granted reaching the web.")
            }
            guard let fetch = PluginFetchRequest(payload: payload) else {
                return refuse(id, "That web request couldn't be read.")
            }
            // Early host check; the fetch service checks again before sending.
            let host = URLComponents(string: fetch.url)?.host?.lowercased()
            guard let host, allowedHosts.contains(host) else {
                return refuse(id, "This plugin hasn't been granted reaching \(host ?? "that address").")
            }
            // A secret reference needs the secrets grant, for that name.
            for header in fetch.secretHeaders.values {
                guard capabilities.contains(.secrets), secretNames.contains(header.secret) else {
                    return refuse(id, "This plugin hasn't been granted that secret.")
                }
            }
            return .fetch(id: id, fetch)
        case "getUsage":
            guard capabilities.contains(.usageRead) else {
                return refuse(id, "This plugin hasn't been granted seeing what your chats used and cost.")
            }
            let view = payload?["view"]?.string ?? "chats"
            guard ["chats", "entries", "days"].contains(view) else {
                return refuse(id, "Abstract doesn't know that usage view.")
            }
            return .getUsage(id: id, view: view, page: PluginPage(payload: payload), chatId: payload?["chatId"]?.string)
        case "getTurns":
            guard capabilities.contains(.turnsRead) else {
                return refuse(id, "This plugin hasn't been granted seeing when your agents worked.")
            }
            return .getTurns(id: id, page: PluginPage(payload: payload), chatId: payload?["chatId"]?.string)
        case "getTranscript":
            guard capabilities.contains(.transcriptsRead) else {
                return refuse(id, "This plugin hasn't been granted reading your chats' messages.")
            }
            return .getTranscript(id: id, page: PluginPage(payload: payload), chatId: payload?["chatId"]?.string)
        case "getAutomations":
            guard capabilities.contains(.automationsRead) else {
                return refuse(id, "This plugin hasn't been granted seeing your automations.")
            }
            return .getAutomations(id: id, page: PluginPage(payload: payload))
        case "getPullRequest":
            guard capabilities.contains(.pullRequestsRead) else {
                return refuse(id, "This plugin hasn't been granted reading your chats' pull requests.")
            }
            guard let chatId = knownChat(payload) else { return refuse(id, "That chat isn't in the plugin's list.") }
            return .getPullRequest(id: id, chatId: chatId)
        case "addReviewComments":
            guard api >= 2, capabilities.contains(.reviewComment) else {
                return refuse(id, "This plugin hasn't been granted adding comments to your chats' Review.")
            }
            guard let chatId = knownChat(payload) else { return refuse(id, "That chat isn't in the plugin's list.") }
            // Signed by an agent, never as you or as Abstract.
            guard let author = payload?["author"]?.string, ProviderRegistry.all.contains(where: { $0.name == author }) else {
                return refuse(id, "Review comments need the name of the agent that wrote them.")
            }
            let items = payload?["comments"]?.array ?? []
            guard !items.isEmpty, items.count <= Self.reviewCommentLimit else {
                return refuse(id, "Send between 1 and \(Self.reviewCommentLimit) comments at a time.")
            }
            var comments: [PluginReviewComment] = []
            for item in items {
                guard let comment = PluginReviewComment(item) else {
                    return refuse(id, "Each comment needs a file inside the project, a line and some words.")
                }
                comments.append(comment)
            }
            return .addReviewComments(id: id, chatId: chatId, author: author, comments)
        case "getPermissions":
            // What's waiting, and its request ids, are for a plugin that
            // may answer it, as in `permission.requested`, and only in the
            // chats it can already see.
            guard capabilities.contains(.permissionsAnswer), capabilities.contains(.chatsRead) else {
                return refuse(id, "This plugin hasn't been granted answering your agents' questions and permission requests.")
            }
            return .getPermissions(id: id)
        case "setBadge":
            // Only its own sidebar row, so it needs no grant.
            guard let count = payload?["count"]?.int, count >= 0, count <= Self.badgeLimit else {
                return refuse(id, "A badge is a count from 0 to \(Self.badgeLimit).")
            }
            return .badge(id: id, count: count)
        case "showNotice":
            guard let text = nonEmpty(payload?["text"]?.string), text.count <= Self.noticeTextLimit else {
                return refuse(id, "A notice is one short sentence.")
            }
            return .notice(id: id, text: text)
        case "createChat", "sendMessage", "sendReview", "controlChat", "answerPermission", "answerPermissions", "answerQuestion",
             "runAutomation":
            // Actions are API 2: an API 1 plugin was granted reading only.
            guard api >= 2 else { return refuse(id, "This plugin hasn't been granted acting on your chats.") }
            return actionOutcome(type: type, id: id, payload: payload, now: now)
        case "events.subscribe", "jobs.schedule", "jobs.cancel", "jobs.done":
            guard isBackground else {
                return refuse(id, "Only a plugin's background script can listen for events or schedule jobs.")
            }
            return backgroundOutcome(type: type, id: id, payload: payload)
        case "tools.result":
            guard isBackground, capabilities.contains(.agentTools) else {
                return refuse(id, "Only the background script of a plugin granted giving agents tools can answer a tool call.")
            }
            guard let callId = nonEmpty(payload?["callId"]?.string) else {
                return refuse(id, "A tool result needs the call it answers.")
            }
            if let error = payload?["error"], error != .null {
                let text = error.string ?? error.compact()
                return .toolResult(callId: callId, .failed(String(text.prefix(2_000))))
            }
            return .toolResult(callId: callId, .result(PluginTools.resultText(payload?["result"] ?? .null)))
        case "links.result":
            guard isBackground else {
                return refuse(id, "Only a plugin's background script can answer a link lookup.")
            }
            guard let callId = nonEmpty(payload?["callId"]?.string) else {
                return refuse(id, "A link status needs the lookup it answers.")
            }
            if let error = payload?["error"], error != .null { return .linkResult(callId: callId, .failed) }
            guard let status = payload?["status"], status != .null else { return .linkResult(callId: callId, .status(nil)) }
            guard let parsed = PluginLinkStatus(status) else {
                _ = refuse(id, "A link status is a label of up to \(PluginLinkStatus.labelLimit) characters and a known tone.")
                return .linkResult(callId: callId, .failed)
            }
            return .linkResult(callId: callId, .status(parsed))
        case "tracker.result":
            guard isBackground else {
                return refuse(id, "Only a plugin's background script can answer for its issue tracker.")
            }
            guard let callId = nonEmpty(payload?["callId"]?.string) else {
                return refuse(id, "A tracker answer needs the question it answers.")
            }
            return .trackerResult(callId: callId, payload)
        case "cli.run":
            return cliOutcome(api: api, id: id, payload: payload, now: now)
        case "codeHost.result":
            guard isBackground, isCodeHost else {
                return refuse(id, "Only the background script of a code host plugin can answer for it.")
            }
            guard let callId = nonEmpty(payload?["callId"]?.string) else {
                return refuse(id, "A code host answer needs the call it answers.")
            }
            if let error = payload?["error"], error != .null {
                let text = error.string ?? error["message"]?.string ?? error.compact()
                return .codeHostResult(callId: callId, .failed(String(text.prefix(2_000))))
            }
            return .codeHostResult(callId: callId, .result(payload?["result"] ?? .null))
        case "codeHost.hosts":
            guard isBackground, isCodeHost else {
                return refuse(id, "Only the background script of a code host plugin can say which hosts it handles.")
            }
            let hosts = (payload?["hosts"]?.array ?? []).compactMap { $0.string?.lowercased() }
            guard hosts.count <= CodeHosts.extraHostLimit, hosts.allSatisfy(PluginManifest.isExactHost) else {
                return refuse(id, "Hosts are up to \(CodeHosts.extraHostLimit) exact hosts like github.example.com.")
            }
            return .codeHostHosts(id: id, Set(hosts))
        case "__error":
            return refuse(id, "The plugin reported an error.")
        default:
            return refuse(id, "Abstract doesn't know that message.")
        }
    }

    // MARK: Command-line tools (ABS-139)

    /// Checks one `cli.run`: granted, a declared command, sensible
    /// arguments, a folder the plugin can read. A write counts toward the
    /// action rate limit, as an action would.
    private mutating func cliOutcome(api: Int, id: String?, payload: JSONValue?, now: Date) -> Outcome {
        guard api >= 2, capabilities.contains(.cli), let cli else {
            return refuse(id, "This plugin hasn't been granted running a command-line tool.")
        }
        guard let items = payload?["args"]?.array, !items.isEmpty, items.count <= PluginCLI.argumentLimit else {
            return refuse(id, "A command needs its arguments, up to \(PluginCLI.argumentLimit) of them.")
        }
        let args = items.compactMap(\.string)
        guard args.count == items.count, args.reduce(0, { $0 + $1.count }) <= PluginCLI.argumentTextLimit,
              !args.contains(where: { $0.contains("\u{0}") }) else {
            return refuse(id, "That command's arguments couldn't be read.")
        }
        guard let command = cli.command(for: args) else {
            return refuse(id, "This plugin hasn't been granted running \(cli.binary) \(args.prefix(2).joined(separator: " ")).")
        }
        var chatId: String?
        if payload?["chatId"] != nil, payload?["chatId"] != .null {
            guard let known = knownChat(payload) else { return refuse(id, "That chat isn't in the plugin's list.") }
            chatId = known
        }
        var projectKey: String?
        if let key = payload?["projectKey"], key != .null {
            guard let key = key.string, knownProjectKeys.contains(key) else {
                return refuse(id, "That project isn't in the plugin's list.")
            }
            projectKey = key
        }
        // A folder is named by its chat or project, never by a path.
        if payload?["cwd"] != nil { return refuse(id, "Name the chat or project to run in, not a folder.") }
        let callId = payload?["callId"]?.string.flatMap { $0.count <= 100 ? nonEmpty($0) : nil }
        let githubHost = payload?["githubHost"]?.string
        let githubRepository = payload?["githubRepository"]?.string
        if githubHost != nil || githubRepository != nil {
            let repositoryParts = githubRepository?.split(separator: "/", omittingEmptySubsequences: false) ?? []
            guard cli.binary == "gh", let githubHost, PluginManifest.isExactHost(githubHost),
                  githubRepository == nil || (repositoryParts.count == 2 && repositoryParts.allSatisfy {
                      !$0.isEmpty && $0 != "." && $0 != ".." && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }
                  }) else {
                return refuse(id, "That GitHub host or repository couldn't be read.")
            }
        }
        let request = PluginCLIRequest(args: args, command: command, chatId: chatId, projectKey: projectKey,
                                       callId: callId, githubHost: githubHost, githubRepository: githubRepository)
        if request.isWrite {
            recentActions.append(now)
            recentActions.removeAll { now.timeIntervalSince($0) > Self.actionWindow }
            guard recentActions.count <= Self.actionLimit else { return .actionRateLimited(id: id) }
        }
        return .runCLI(id: id, request)
    }

    /// Code host calls the host handed the plugin, so `cli.run` may name a
    /// project or chat it hasn't seen in a snapshot.
    public mutating func know(projectKey: String) { knownProjectKeys.insert(projectKey) }

    // MARK: Background (ABS-93)

    private mutating func backgroundOutcome(type: String, id: String?, payload: JSONValue?) -> Outcome {
        switch type {
        case "events.subscribe":
            let names = payload?["types"]?.array?.compactMap(\.string) ?? []
            guard !names.isEmpty else { return refuse(id, "Say which events to listen for.") }
            var types: Set<PluginEventType> = []
            for name in names {
                guard let type = PluginEventType(rawValue: name) else {
                    return refuse(id, "Abstract doesn't know the event \(name).")
                }
                guard capabilities.contains(type.capability) else {
                    return refuse(id, "This plugin hasn't been granted what \(name) needs: \(type.capability.plainWords.lowercased()).")
                }
                types.insert(type)
            }
            return .subscribe(id: id, types)
        case "jobs.schedule":
            guard let jobId = nonEmpty(payload?["id"]?.string), let rrule = nonEmpty(payload?["rrule"]?.string),
                  jobId.count <= 60, rrule.count <= 500 else {
                return refuse(id, "A job needs an id and a schedule.")
            }
            return .scheduleJob(id: id, jobId: jobId, rrule: rrule, timezone: payload?["timezone"]?.string)
        case "jobs.cancel":
            guard let jobId = nonEmpty(payload?["id"]?.string) else { return refuse(id, "Say which job to cancel.") }
            return .cancelJob(id: id, jobId: jobId)
        default:
            guard let jobId = nonEmpty(payload?["id"]?.string) else { return refuse(id, "Say which job finished.") }
            return .jobDone(jobId: jobId)
        }
    }

    // MARK: Actions (ABS-92)

    /// Builds the action behind one action message, or refuses it. A
    /// well-formed action counts toward the rate limit whether it ends
    /// up asked about or always allowed.
    private mutating func actionOutcome(type: String, id: String?, payload: JSONValue?, now: Date) -> Outcome {
        let built: PluginAction
        switch type {
        case "sendMessage":
            guard capabilities.contains(.chatsMessage) else {
                return refuse(id, "This plugin hasn't been granted sending messages to your chats.")
            }
            guard let chatId = knownChat(payload), let text = actionText(payload, key: "text") else {
                return refuse(id, "That message needs a chat in the plugin's list and some words to send.")
            }
            built = PluginAction(capability: .chatsMessage, chatId: chatId, text: text)
        case "sendReview":
            // Your Review comments go as your own Send would (ABS-112).
            guard capabilities.contains(.chatsMessage) else {
                return refuse(id, "This plugin hasn't been granted sending messages to your chats.")
            }
            guard let chatId = knownChat(payload) else {
                return refuse(id, "That chat isn't in the plugin's list.")
            }
            let text = nonEmpty(payload?["text"]?.string)
            if let text, text.count > Self.actionTextLimit { return refuse(id, "That message is too long.") }
            built = PluginAction(capability: .chatsMessage, chatId: chatId, text: text, sendsReview: true)
        case "createChat":
            guard capabilities.contains(.chatsCreate) else {
                return refuse(id, "This plugin hasn't been granted starting chats.")
            }
            guard let prompt = actionText(payload, key: "prompt") else {
                return refuse(id, "A new chat needs a prompt.")
            }
            if let projectKey = payload?["projectKey"]?.string, !knownProjectKeys.contains(projectKey) {
                return refuse(id, "That project isn't in the plugin's list.")
            }
            // Ask (read-only) can only take power away, so it's allowed
            // alongside the autonomy levels (ABS-112).
            let policies = (PermissionPolicy.autonomyCases + [.readOnly]).map(\.rawValue)
            if let policy = payload?["policy"]?.string, !policies.contains(policy) {
                return refuse(id, "Abstract doesn't know that permission level.")
            }
            if let agentId = payload?["agentId"]?.string, agentId.isEmpty || agentId.count > 60 {
                return refuse(id, "That agent couldn't be read.")
            }
            // A reviewer works read-only in the reviewed chat's worktree,
            // and so in its project.
            var reviewOf: String?
            if payload?["reviewOf"] != nil {
                guard let chatId = knownChat(.object(["chatId": payload?["reviewOf"] ?? .null])) else {
                    return refuse(id, "That chat isn't in the plugin's list.")
                }
                let readOnly = PermissionPolicy.readOnly.rawValue
                guard (payload?["policy"]?.string ?? readOnly) == readOnly, payload?["projectKey"] == nil else {
                    return refuse(id, "A reviewer only reads, in the chat it reviews.")
                }
                reviewOf = chatId
            }
            built = PluginAction(capability: .chatsCreate, projectKey: payload?["projectKey"]?.string,
                                 text: prompt, agentId: payload?["agentId"]?.string,
                                 policy: reviewOf != nil ? PermissionPolicy.readOnly.rawValue : payload?["policy"]?.string,
                                 reviewOf: reviewOf)
        case "controlChat":
            guard capabilities.contains(.chatsControl) else {
                return refuse(id, "This plugin hasn't been granted stopping or resuming your agents.")
            }
            guard let chatId = knownChat(payload),
                  let control = payload?["control"]?.string.flatMap(PluginAction.Control.init(rawValue:)) else {
                return refuse(id, "That needs a chat in the plugin's list, and stop, pause or resume.")
            }
            built = PluginAction(capability: .chatsControl, chatId: chatId, control: control)
        case "answerPermission":
            guard capabilities.contains(.permissionsAnswer) else {
                return refuse(id, "This plugin hasn't been granted answering your agents' questions and permission requests.")
            }
            guard let chatId = knownChat(payload), let requestId = nonEmpty(payload?["requestId"]?.string),
                  let allow = payload?["allow"]?.bool else {
                return refuse(id, "That answer needs the chat and the request it answers.")
            }
            built = PluginAction(capability: .permissionsAnswer, chatId: chatId, requestId: requestId, allow: allow)
        case "answerPermissions":
            // Allow only: declining several at once isn't offered. The host
            // checks they're all exactly the same command (ABS-111).
            guard capabilities.contains(.permissionsAnswer) else {
                return refuse(id, "This plugin hasn't been granted answering your agents' questions and permission requests.")
            }
            let items = payload?["requests"]?.array ?? []
            var targets: [PluginAction.Target] = []
            for item in items {
                guard let chatId = knownChat(item), let requestId = nonEmpty(item["requestId"]?.string) else {
                    return refuse(id, "Each request needs a chat in the plugin's list and the request it answers.")
                }
                targets.append(PluginAction.Target(chatId: chatId, requestId: requestId))
            }
            guard payload?["allow"]?.bool == true else {
                return refuse(id, "Several requests can only be allowed at once, not declined.")
            }
            guard targets.count >= 2, targets.count <= PluginPermissions.batchLimit,
                  Set(targets).count == targets.count else {
                return refuse(id, "Allow several at once takes between 2 and \(PluginPermissions.batchLimit) different requests.")
            }
            built = PluginAction(capability: .permissionsAnswer, allow: true, batch: targets)
        case "answerQuestion":
            guard capabilities.contains(.permissionsAnswer) else {
                return refuse(id, "This plugin hasn't been granted answering your agents' questions and permission requests.")
            }
            var answers: [String: String] = [:]
            for (question, answer) in payload?["answers"]?.object ?? [:] {
                if let answer = answer.string { answers[question] = answer }
            }
            guard let chatId = knownChat(payload), let requestId = nonEmpty(payload?["requestId"]?.string),
                  !answers.isEmpty, answers.count <= 16,
                  answers.allSatisfy({ $0.key.count <= 500 && $0.value.count <= 2_000 }) else {
                return refuse(id, "That answer needs the chat, the question it answers, and the answers.")
            }
            built = PluginAction(capability: .permissionsAnswer, chatId: chatId, requestId: requestId, answers: answers)
        case "runAutomation":
            guard capabilities.contains(.automationsRun) else {
                return refuse(id, "This plugin hasn't been granted running your automations.")
            }
            guard let automationId = nonEmpty(payload?["automationId"]?.string) else {
                return refuse(id, "That needs the automation to run.")
            }
            built = PluginAction(capability: .automationsRun, automationId: automationId)
        default:
            return refuse(id, "Abstract doesn't know that message.")
        }

        recentActions.append(now)
        recentActions.removeAll { now.timeIntervalSince($0) > Self.actionWindow }
        guard recentActions.count <= Self.actionLimit else { return .actionRateLimited(id: id) }
        // A plugin may ask first even for a kind you always allow, when it
        // has reached a limit of its own (ABS-109). It can never skip asking.
        if payload?["ask"]?.bool == true { return .askAction(id: id, built) }
        return alwaysAllowedActions.contains(built.capability)
            ? .action(id: id, built)
            : .askAction(id: id, built)
    }

    /// A chat the host just handed the plugin, beyond its last snapshot:
    /// the one a Review command was run from (ABS-112).
    public mutating func know(chatId: String) { knownChatIds.insert(chatId) }

    private func knownChat(_ payload: JSONValue?) -> String? {
        guard let chatId = payload?["chatId"]?.string, knownChatIds.contains(chatId) else { return nil }
        return chatId
    }

    private func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    private func actionText(_ payload: JSONValue?, key: String) -> String? {
        guard let text = nonEmpty(payload?[key]?.string), text.count <= Self.actionTextLimit else { return nil }
        return text
    }

    private mutating func isFlood(now: Date) -> Bool {
        recent.append(now)
        recent.removeAll { now.timeIntervalSince($0) > Self.floodWindow }
        return recent.count > Self.floodCount
    }

    private mutating func refuse(_ id: String?, _ reason: String) -> Outcome {
        refusalCount += 1
        lastRefusal = reason
        return .refused(id: id, reason: reason)
    }

    /// A host-to-plugin envelope, as JSON text for the web view, in the
    /// version the plugin's manifest speaks.
    public static func encode(type: String, id: String? = nil, payload: JSONValue, api: Int = PluginBridge.api) -> String {
        var object: [String: JSONValue] = ["api": .number(Double(api)), "type": .string(type), "payload": payload]
        if let id { object["id"] = .string(id) }
        return JSONValue.object(object).compact()
    }
}

/// How a code host plugin answered one of core's calls (ABS-139).
public enum PluginCodeHostAnswer: Sendable, Equatable {
    case result(JSONValue)
    case failed(String)
}

/// One finding a plugin adds to a chat's Review (ABS-112): a line of a
/// file in the chat's worktree, and what it says about it.
public struct PluginReviewComment: Sendable, Equatable {
    public var path: String
    public var line: Int
    public var text: String

    public init(path: String, line: Int, text: String) {
        self.path = path; self.line = line; self.text = text
    }

    /// Nil unless the path stays inside the worktree, the line is a
    /// line, and there are words of a sensible length.
    init?(_ value: JSONValue) {
        guard let path = value["path"]?.string, PluginPackage.isContained(relativePath: path),
              let line = value["line"]?.int, line >= 1,
              let text = value["text"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, text.count <= PluginBridge.reviewCommentTextLimit else { return nil }
        self.init(path: path, line: line, text: text)
    }

    /// A file's lines, quoted back with a comment, only when it really is a
    /// file inside the worktree: a symlink out of it, a folder or a huge
    /// file reads as nothing.
    public static func lines(inWorktree root: String, path: String) -> [Substring] {
        let base = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path
        let file = URL(fileURLWithPath: root).appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
        guard file.path.hasPrefix(base.hasSuffix("/") ? base : base + "/"),
              let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, (values.fileSize ?? .max) <= 2_000_000,
              let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
    }
}
