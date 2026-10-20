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
        // A placed showing may act on the chat it sits beside: the
        // person opened it there (ABS-96).
        if let chatId = placement?.chatId { bridge.knownChatIds = [chatId] }
    }

    func tearDown() { dead = true }

    /// A chat the person handed this plugin outside a snapshot (ABS-112).
    func know(chatId: String) { bridge.know(chatId: chatId) }

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
        case .subscribe, .scheduleJob, .cancelJob, .jobDone:
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
        var info = action.detail.map { String($0.prefix(600)) } ?? ""
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

    init(packageURL: URL, background: String? = nil) {
        self.packageURL = packageURL
        self.background = background
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
      window.__abstractHostMessage = (text) => {
        let message;
        try { message = JSON.parse(text); } catch { return; }
        if (message.type === "context") {
          const root = document.documentElement.style;
          const tokens = (message.payload && message.payload.tokens) || {};
          for (const [name, value] of Object.entries(tokens)) root.setProperty("--abstract-" + name, value);
          if (message.payload && message.payload.fontFamily) root.setProperty("--abstract-font", message.payload.fontFamily);
        }
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
