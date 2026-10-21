import AppKit
import WebKit
import AbstractCore

/// One running copy of a plugin — a screen, or its background script
/// (ABS-93) — and its side of the bridge. Every inbound message goes
/// through `PluginBridge` in the core before anything acts on it; what
/// differs between a screen and a background script is handed in.
@MainActor
final class PluginConnection {
    let model: AppModel
    let plugin: InstalledPlugin
    let manifest: PluginManifest
    let placement: PluginPlacement?
    private var bridge: PluginBridge
    /// Set once the page loaded; nothing is pushed before.
    var ready = false
    private(set) var dead = false
    private var pushScheduled = false
    /// Runs one line of JavaScript in the page.
    private let evaluate: (String) -> Void
    /// Stop this copy, with the note Settings shows.
    private let fail: (String) -> Void
    /// The page threw. A screen stops at once; a background script is
    /// stopped by its watchdog only when it keeps throwing.
    var onScriptError: () -> Void = {}
    /// Events and jobs, for a background script.
    var onBackground: (PluginBridge.Outcome) -> Void = { _ in }
    /// After each snapshot, for a screen placed beside a chat.
    var onSnapshot: () -> Void = {}
    /// Whether a write command serving this code host call may run
    /// unasked: the person started the call (ABS-139). Only a background
    /// script answers calls.
    var authorizesWrite: (String?) async -> Bool = { _ in false }

    init(model: AppModel, plugin: InstalledPlugin, manifest: PluginManifest, placement: PluginPlacement?,
         isBackground: Bool = false, evaluate: @escaping (String) -> Void, fail: @escaping (String) -> Void) {
        self.model = model
        self.plugin = plugin
        self.manifest = manifest
        self.placement = placement
        self.evaluate = evaluate
        self.fail = fail
        bridge = PluginBridge(capabilities: plugin.record.grantedCapabilities,
                              allowedHosts: Set(plugin.record.grantedNetworkHosts),
                              secretNames: Set(plugin.record.grantedSecretNames),
                              alwaysAllowedActions: plugin.record.alwaysAllowedActions)
        bridge.isBackground = isBackground
        bridge.cli = plugin.record.grantedCLI
        bridge.isCodeHost = manifest.contributes.codeHost != nil
        // A placed showing may act on the chat it sits beside: the
        // person opened it there (ABS-96).
        if let chatId = placement?.chatId { bridge.knownChatIds = [chatId] }
    }

    func tearDown() { dead = true }

    /// A chat the person handed this plugin outside a snapshot (ABS-112).
    func know(chatId: String) { bridge.know(chatId: chatId) }

    /// A project core handed the plugin with a code host call (ABS-139).
    func know(projectKey: String) { bridge.know(projectKey: projectKey) }

    /// The grants as they stand now, not as they were when this copy
    /// started: revoking one in Settings stops the next call.
    var capabilities: Set<PluginCapability> {
        model.plugins.plugin(plugin.id)?.record.grantedCapabilities ?? plugin.record.grantedCapabilities
    }

    func receive(_ text: String) {
        guard !dead else { return }
        guard model.plugins.plugin(plugin.id)?.isUsable == true else { return }
        // A script error is a misbehaving plugin, not a message to answer.
        if text.contains("\"__error\"") { onScriptError(); return }
        if let record = model.plugins.plugin(plugin.id)?.record {
            bridge.capabilities = record.grantedCapabilities
            bridge.alwaysAllowedActions = record.alwaysAllowedActions
            bridge.allowedHosts = Set(record.grantedNetworkHosts.map { $0.lowercased() })
            bridge.secretNames = Set(record.grantedSecretNames)
            bridge.cli = record.grantedCapabilities.contains(.cli) ? record.grantedCLI : nil
        }
        let storage = model.plugins.manager.storage(for: plugin.id)
        let outcome = bridge.handle(text, storage: storage)
        switch outcome {
        case .reply(let id, let value):
            send(type: "reply", id: id, payload: value)
        case .getSnapshot:
            pushSnapshot()
        case .openChat(let id, let chatId):
            send(type: "reply", id: id, payload: .object(["opened": .bool(true)]))
            model.open(chatId)
        case .fetch(let id, let fetch):
            // The host sends it (ABS-94): hosts and secrets were
            // checked at the bridge and are checked again in the
            // service, against this plugin's record.
            guard let current = model.plugins.plugin(plugin.id) else { return }
            let service = model.plugins.fetchService(for: current)
            Task { @MainActor [weak self] in
                do {
                    let response = try await service.perform(fetch)
                    self?.model.plugins.noteNetworkActivity()
                    self?.send(type: "reply", id: id, payload: response.jsonValue())
                } catch {
                    self?.model.plugins.noteNetworkActivity()
                    self?.send(type: "error", id: id,
                               payload: .object(["message": .string(String(describing: error))]))
                }
            }
        case .getUsage(let id, let view, let page, let chatId):
            Task { @MainActor [weak self] in
                guard let self, !dead else { return }
                let payload = await model.pluginUsage(view: view, page: page, chatId: chatId)
                send(type: "reply", id: id, payload: payload)
            }
        case .getTurns(let id, let page, let chatId):
            send(type: "reply", id: id, payload: model.pluginTurns(page: page, chatId: chatId))
        case .getTranscript(let id, let page, let chatId):
            // The grant as it stands now, not as it was when this started.
            let keys = model.plugins.plugin(plugin.id)?.record.transcriptProjectKeys ?? []
            send(type: "reply", id: id,
                 payload: model.pluginTranscript(page: page, chatId: chatId, allowedProjectKeys: keys))
        case .getAutomations(let id, let page):
            send(type: "reply", id: id, payload: model.pluginAutomations(page: page))
        case .getPullRequest(let id, let chatId):
            send(type: "reply", id: id, payload: model.pluginPullRequest(chatId: chatId))
        case .getPermissions(let id):
            // Only chats its snapshot shows it, the ones it may already act on.
            let visible = Set(model.pluginSnapshot(capabilities: capabilities, revision: 0).chats?.map(\.id) ?? [])
            let pending = PluginPermissions.visible(model.pluginPendingRequests(), chatIds: visible)
            for chatId in Set(pending.map(\.chatId)) { bridge.know(chatId: chatId) }
            send(type: "reply", id: id, payload: PluginPermissions.list(pending))
        case .badge(let id, let count):
            model.plugins.setBadge(plugin.id, count)
            send(type: "reply", id: id, payload: .object(["count": .number(Double(count))]))
        case .addReviewComments(let id, let chatId, let author, let comments):
            let added = model.addPluginReviewComments(chatId, author: author, comments)
            send(type: "reply", id: id, payload: .object(["added": .number(Double(added))]))
        case .notice(let id, let text):
            model.flash("\(manifest.name): \(text)")
            send(type: "reply", id: id, payload: .object(["shown": .bool(true)]))
        case .action(let id, let action):
            perform(action, id: id)
        case .askAction(let id, let action):
            ask(action, id: id)
        case .actionRateLimited(let id):
            // Paused, with the reason waiting in Settings (ABS-92).
            send(type: "error", id: id,
                 payload: .object(["message": .string("It acted too many times in a minute, so Abstract paused it.")]))
            model.plugins.noteError(plugin.id, "It acted too many times in a minute, so it was paused. Turn it on again here when you're ready.")
            model.setPluginEnabled(plugin.id, false)
        case .runCLI(let id, let request):
            runCLI(request, id: id)
        case .subscribe, .scheduleJob, .cancelJob, .jobDone, .toolResult, .linkResult, .codeHostResult, .codeHostHosts, .trackerResult:
            onBackground(outcome)
        case .refused(let id, let reason):
            model.plugins.noteError(plugin.id, reason)
            send(type: "error", id: id, payload: .object(["message": .string(reason)]))
        case .flooded:
            fail("It sent too many messages, so it was stopped.")
        }
    }

    /// Ask first (ABS-92): who is asking and what it will do, with the
    /// message or answers themselves to read before deciding.
    private func ask(_ action: PluginAction, id: String?) {
        let alert = NSAlert()
        alert.messageText = model.pluginActionDescription(action, pluginName: manifest.name)
        // Sending Review shows what goes, comment by comment (ABS-112).
        var info = action.sendsReview
            ? model.reviewSendPreview(action.chatId ?? "", text: action.text)
            : action.detail.map { String($0.prefix(600)) } ?? ""
        // Allowing shows all of what it lets through (ABS-111): a command
        // too long to show whole can't be allowed from a plugin.
        if action.capability == .permissionsAnswer, action.answers.isEmpty,
           let preview = model.pluginAnswerPreview(action) {
            info = action.batch.isEmpty ? preview : "Each one runs exactly this command:\n\(preview)"
        }
        if !info.isEmpty { info += "\n\n" }
        info += "Always allow lets \(manifest.name) do this kind of thing without asking. You can change your mind in Settings → Plugins."
        alert.informativeText = info
        alert.addButton(withTitle: "Allow Once")
        alert.addButton(withTitle: "Always Allow")
        alert.addButton(withTitle: "Decline")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            perform(action, id: id)
        case .alertSecondButtonReturn:
            model.plugins.setAlwaysAllowed(plugin.id, action.capability, true)
            bridge.alwaysAllowedActions.insert(action.capability)
            perform(action, id: id)
        default:
            send(type: "error", id: id, payload: .object(["message": .string("You declined that.")]))
        }
    }

    /// Runs a declared command (ABS-139). A read goes straight to the
    /// budget; a write asks first unless the person started the code host
    /// call it serves, or always allows this plugin's writes.
    private func runCLI(_ request: PluginCLIRequest, id: String?) {
        guard let current = model.plugins.plugin(plugin.id), let cli = current.record.grantedCLI else { return }
        let chats = bridge.knownChatIds, projectKeys = bridge.knownProjectKeys
        Task { @MainActor [weak self] in
            guard let self, !dead else { return }
            let personStarted = request.isWrite ? await authorizesWrite(request.callId) : false
            let alwaysAllowed = model.plugins.plugin(plugin.id)?.record.alwaysAllowedActions.contains(.cli) ?? false
            if PluginCLIRoute.of(request, alwaysAllowed: alwaysAllowed, personStarted: personStarted) == .ask,
               !askCLI(request, cli: cli) {
                send(type: "error", id: id, payload: .object(["message": .string("You declined that.")]))
                return
            }
            do {
                let result = try await model.runPluginCLI(request, cli: cli, chats: chats, projectKeys: projectKeys)
                send(type: "reply", id: id, payload: result.jsonValue())
            } catch let error as PluginCLIError {
                send(type: "error", id: id, payload: error.jsonValue())
            } catch {
                send(type: "error", id: id, payload: .object(["message": .string(error.localizedDescription)]))
            }
        }
    }

    /// Ask first (ABS-92) for a write command: the whole command line, and
    /// where it runs.
    private func askCLI(_ request: PluginCLIRequest, cli: PluginCLI) -> Bool {
        guard !dead else { return false }
        let alert = NSAlert()
        let place = model.pluginCLIPlace(request).map { " \($0)" } ?? ""
        alert.messageText = "\(manifest.name) wants to run \(cli.binary) \(request.command.words)\(place)."
        let line = ([cli.binary] + request.args.map { $0.contains(" ") || $0.isEmpty ? "\"\($0)\"" : $0 }).joined(separator: " ")
        alert.informativeText = String(line.prefix(600))
            + "\n\nAlways allow lets \(manifest.name) run its \(cli.binary) commands that change things without asking. You can change your mind in Settings → Plugins."
        alert.addButton(withTitle: "Allow Once")
        alert.addButton(withTitle: "Always Allow")
        alert.addButton(withTitle: "Decline")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return true
        case .alertSecondButtonReturn:
            model.plugins.setAlwaysAllowed(plugin.id, .cli, true)
            return true
        default:
            return false
        }
    }

    private func perform(_ action: PluginAction, id: String?) {
        Task { @MainActor [weak self] in
            guard let self, !dead else { return }
            do {
                let result = try await model.performPluginAction(action, pluginName: manifest.name)
                send(type: "reply", id: id, payload: result)
                pushSnapshotSoon()
            } catch {
                send(type: "error", id: id,
                     payload: .object(["message": .string(error.localizedDescription)]))
            }
        }
    }

    func pushSnapshotSoon() {
        guard ready, !pushScheduled, !dead else { return }
        pushScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !dead else { return }
            pushScheduled = false
            pushSnapshot()
        }
    }

    func pushSnapshot() {
        guard ready, !dead, let current = model.plugins.plugin(plugin.id), current.isUsable else { return }
        let snapshot = model.pluginSnapshot(capabilities: current.record.grantedCapabilities,
                                            revision: model.plugins.nextRevision())
        bridge.knownChatIds = Set(snapshot.chats?.map(\.id) ?? [])
        if let chatId = placement?.chatId { bridge.knownChatIds.insert(chatId) }
        bridge.knownProjectKeys = Set(snapshot.projects?.map(\.key) ?? [])
        send(type: "snapshot", payload: snapshot.jsonValue())
        onSnapshot()
    }

    func send(type: String, id: String? = nil, payload: JSONValue) {
        guard !dead else { return }
        let envelope = PluginBridge.encode(type: type, id: id, payload: payload, api: manifest.api)
        let literal = (try? JSONSerialization.data(withJSONObject: [envelope]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "[\"\"]"
        evaluate("window.__abstractHostMessage(\(literal)[0])")
    }
}

/// Serves a plugin's package files through `abstract-plugin://` only, with
/// a CSP that keeps the page to its own files.
final class PluginSchemeHandler: NSObject, WKURLSchemeHandler {
    /// The page a background script runs in: nothing but its script.
    static let backgroundPage = "__abstract-background__.html"

    let packageURL: URL
    let background: String?
    /// The shared design kit (ABS-134), served under `/_abstract/`.
    let kitURL: URL?

    init(packageURL: URL, background: String? = nil,
         kitURL: URL? = Bundle.main.url(forResource: "PluginKit", withExtension: nil)) {
        self.packageURL = packageURL
        self.background = background
        self.kitURL = kitURL
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, url.host == "plugin" else {
            urlSchemeTask.didFailWithError(PluginHostError.refused); return
        }
        let path = String(url.path.dropFirst())
        let data: Data?
        if path == Self.backgroundPage, let background {
            let src = background.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? background
            data = Data("<!doctype html><meta charset=\"utf-8\"><script src=\"/\(src)\"></script>".utf8)
        } else if PluginKit.isKitPath(path) {
            data = PluginKit.file(forRequestPath: path).flatMap { name in
                kitURL.flatMap { try? Data(contentsOf: $0.appendingPathComponent(name)) }
            }
        } else {
            data = PluginPackage.fileData(in: packageURL, relativePath: path)
        }
        guard let data else { urlSchemeTask.didFailWithError(PluginHostError.refused); return }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": path == Self.backgroundPage ? "text/html" : PluginPackage.mimeType(forPath: path),
            "Content-Security-Policy": "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:",
            "Content-Length": "\(data.count)",
        ])!
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}

enum PluginHostError: Error { case refused }

/// `window.AbstractPlugin`: the plugin's whole API. Requests are answered
/// by id; the host pushes `context` and `snapshot` messages, and to a
/// background script, `event` and `job` (ABS-93). It speaks the version
/// its manifest declares.
enum PluginShim {
    static func source(api: Int, background: Bool = false) -> String { """
    (() => {
      const background = \(background);
      const pending = new Map();
      const listeners = new Map();
      const jobs = new Map();
      const toolHandlers = new Map();
      const linkHandlers = new Map();
      let trackerHandler = null;
      const codeHostHandlers = new Map();
      let next = 1;
      const post = (message) => window.webkit.messageHandlers.abstractPlugin.postMessage(JSON.stringify(message));
      const api = {
        send(type, payload) {
          const id = String(next++);
          return new Promise((resolve) => {
            pending.set(id, resolve);
            post({ api: \(api), type, id, payload: payload || {} });
          });
        },
        on(type, fn) {
          if (!listeners.has(type)) listeners.set(type, []);
          listeners.get(type).push(fn);
        },
        fetch(url, options) {
          const o = options || {};
          return api.send("fetch", { url, method: o.method || "GET", headers: o.headers || {},
                                     secretHeaders: o.secretHeaders || {}, body: o.body || null });
        },
        events: {
          subscribe(types, fn) {
            if (fn) api.on("event", (event) => { if (types.includes(event.type)) return fn(event); });
            return api.send("events.subscribe", { types });
          }
        },
        tools: {
          // Answers agents' calls to a tool its manifest lists (ABS-97):
          // fn(input, { chatId }) returns text or JSON, or throws.
          handle(name, fn) { toolHandlers.set(name, fn); }
        },
        cli: {
          // Runs one of the commands its manifest lists (ABS-139), in a
          // chat's or project's folder: { chatId } or { projectKey }, and
          // { callId } when it serves a code host call. Resolves with
          // { code, ok, stdout, stderr, truncated }; throws when it can't
          // run, with error.missing and error.install when the tool isn't there.
          run(args, options) {
            const o = options || {};
            return api.send("cli.run", { args, chatId: o.chatId, projectKey: o.projectKey, callId: o.callId })
              .then((reply) => {
                if (reply && typeof reply.code === "number") return reply;
                const error = new Error((reply && reply.message) || "That command couldn't run.");
                if (reply && reply.missing) { error.missing = reply.missing; error.install = reply.install; }
                throw error;
              });
          }
        },
        codeHost: {
          // Answers core's calls for the code host its manifest declares
          // (ABS-139): fn(input, { projectKey, chatId, remote, callId })
          // returns the operation's result, or throws.
          handle(op, fn) { codeHostHandlers.set(op, fn); },
          // Hosts its tool is signed in to besides the manifest's.
          setHosts(hosts) { return api.send("codeHost.hosts", { hosts }); }
        },
        links: {
          // Says how a link stands (ABS-126), for the link decorator its
          // manifest lists: fn(url) returns { label, tone }, or null.
          decorate(id, fn) { linkHandlers.set(id, fn); }
        },
        issueTracker: {
          // Answers the composer's issue search (ABS-141), for the tracker
          // its manifest declares: fn(operation, input) returns the result
          // of access, searchIssues, issue or listProjects, or throws.
          handle(fn) { trackerHandler = fn; }
        },
        jobs: {
          schedule(id, rrule, fn, timezone) {
            jobs.set(id, fn);
            return api.send("jobs.schedule", { id, rrule, timezone });
          },
          cancel(id) {
            jobs.delete(id);
            return api.send("jobs.cancel", { id });
          }
        }
      };
      window.AbstractPlugin = api;
      const applyTheme = \(PluginTheming.applySource);
      window.__abstractHostMessage = (text) => {
        let message;
        try { message = JSON.parse(text); } catch { return; }
        if (message.type === "context") applyTheme(message.payload);
        if (message.id && pending.has(message.id)) {
          pending.get(message.id)(message.payload);
          pending.delete(message.id);
          return;
        }
        if (message.type === "job") {
          // The run ends when its handler settles; until then the host
          // won't start it again.
          const id = message.payload && message.payload.id;
          const fn = jobs.get(id);
          Promise.resolve()
            .then(() => fn && fn(message.payload))
            .catch(report)
            .finally(() => { try { post({ api: \(api), type: "jobs.done", payload: { id } }); } catch {} });
          return;
        }
        if (message.type === "tool") {
          const call = message.payload || {};
          const done = (body) => {
            try { post({ api: \(api), type: "tools.result", payload: Object.assign({ callId: call.callId }, body) }); } catch {}
          };
          const fn = toolHandlers.get(call.tool);
          if (!fn) { done({ error: "This plugin has no tool called " + call.tool + "." }); return; }
          Promise.resolve()
            .then(() => fn(call.input || {}, { chatId: call.chatId }))
            .then((result) => {
              let value = result === undefined ? null : result;
              if (typeof value === "string" && value.length > \(PluginTools.resultLimit)) value = value.slice(0, \(PluginTools.resultLimit));
              else if (value !== null && typeof value !== "string") {
                const text = JSON.stringify(value);
                if (text && text.length > \(PluginTools.resultLimit)) value = text.slice(0, \(PluginTools.resultLimit));
              }
              done({ result: value });
            }, (error) => done({ error: String((error && error.message) || error) }));
          return;
        }
        if (message.type === "codeHost") {
          const call = message.payload || {};
          const done = (body) => {
            try { post({ api: \(api), type: "codeHost.result", payload: Object.assign({ callId: call.callId }, body) }); } catch {}
          };
          const fn = codeHostHandlers.get(call.op);
          if (!fn) { done({ error: "This plugin doesn't answer " + call.op + "." }); return; }
          const context = { projectKey: call.projectKey, chatId: call.chatId, remote: call.remote, callId: call.callId };
          Promise.resolve()
            .then(() => fn(call.input || {}, context))
            .then((result) => done({ result: result === undefined ? null : result }),
                  (error) => done({ error: String((error && error.message) || error) }));
          return;
        }
        if (message.type === "link") {
          const lookup = message.payload || {};
          const done = (body) => {
            try { post({ api: \(api), type: "links.result", payload: Object.assign({ callId: lookup.callId }, body) }); } catch {}
          };
          const fn = linkHandlers.get(lookup.contributionId);
          if (!fn) { done({ status: null }); return; }
          Promise.resolve()
            .then(() => fn(lookup.url))
            .then((status) => done({ status: status || null }),
                  (error) => done({ error: String((error && error.message) || error) }));
          return;
        }
        if (message.type === "tracker") {
          const call = message.payload || {};
          const done = (body) => {
            try { post({ api: \(api), type: "tracker.result", payload: Object.assign({ callId: call.callId }, body) }); } catch {}
          };
          if (!trackerHandler) { done({ error: "This plugin doesn't answer for an issue tracker." }); return; }
          Promise.resolve()
            .then(() => trackerHandler(call.operation, call.input || {}))
            .then((result) => done({ result: result === undefined ? null : result }),
                  (error) => done({ error: String((error && error.message) || error) }));
          return;
        }
        for (const fn of listeners.get(message.type) || []) {
          try {
            const result = fn(message.payload);
            if (background && result && typeof result.catch === "function") result.catch(report);
          } catch (error) { report(error); }
        }
      };
      function report(error) {
        try { post({ api: \(api), type: "__error", payload: { message: String(error) } }); } catch {}
      }
      window.addEventListener("error", (event) => report(event.message || "error"));
      if (background) window.addEventListener("unhandledrejection", (event) => report(event.reason || "error"));
    })();
    """ }
}
