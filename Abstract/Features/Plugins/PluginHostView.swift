import SwiftUI
import WebKit
import AbstractCore

/// One plugin's screen: its package in a locked-down web view (ABS-84 §4,
/// §7), or a plain sentence saying why it isn't showing. No plugin failure
/// reaches the rest of the app.
struct PluginHostView: View {
    @Environment(AppModel.self) private var model
    let pluginId: String
    let viewId: String
    /// Where this showing sits (ABS-96); nil is the sidebar screen.
    var placement: PluginPlacement? = nil
    @State private var failed = false
    @State private var reloadToken = 0
    @AppStorage("theme") private var themeChoice: ThemeChoice = .graphite

    /// Reading these in `body` is what makes a fresh snapshot get pushed
    /// when a chat moves, without the host polling.
    private var liveFingerprint: Int {
        var hasher = Hasher()
        for session in model.sessions {
            hasher.combine(session.id); hasher.combine(session.status); hasher.combine(session.name)
            hasher.combine(session.archivedAt); hasher.combine(session.pinnedAt); hasher.combine(session.lastEventAt)
            hasher.combine(session.branch); hasher.combine(session.projectId)
        }
        hasher.combine(model.projects.map(\.id))
        hasher.combine(model.pullRequests.count)
        hasher.combine(model.branchStates.count)
        hasher.combine(model.remote.paired.map(\.id))
        for (id, link) in model.remote.links { hasher.combine(id); hasher.combine(link.snapshot?.sessions.count ?? -1) }
        return hasher.finalize()
    }

    var body: some View {
        let fingerprint = liveFingerprint
        return Group {
            if let plugin = model.plugins.plugin(pluginId), plugin.isUsable, let manifest = plugin.manifest {
                if failed {
                    stoppedWorking(name: manifest.name)
                } else {
                    PluginWebView(plugin: plugin, manifest: manifest, theme: model.pluginTheme(),
                                  placement: placement ?? PluginPlacement(place: .main, contributionId: viewId),
                                  fingerprint: fingerprint) {
                        failed = true
                    }
                    .id(reloadToken)
                }
            } else if let plugin = model.plugins.plugin(pluginId), let problem = plugin.problem {
                EmptyStateView(symbol: "puzzlepiece.extension",
                               title: "\(plugin.record.name) is off", message: problem)
            } else {
                EmptyStateView(symbol: "puzzlepiece.extension", title: "This plugin is off",
                               message: "Turn it on in Settings → Plugins to see its screen.")
            }
        }
        // Reading the choice here redraws this view when it changes; the
        // coordinator then sends the plugin a fresh context (no reload).
        .onChange(of: themeChoice) { }
    }

    private func stoppedWorking(name: String) -> some View {
        VStack(spacing: Space.md) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Color.btTextTertiary)
            Text("\(name) stopped working.").font(.btHeadline).foregroundStyle(Color.btText)
            Text("Nothing else in Abstract was affected.")
                .font(.btBody).foregroundStyle(Color.btTextSecondary)
            HStack(spacing: Space.sm) {
                Button("Reload") { failed = false; reloadToken += 1 }.buttonStyle(.btPrimary)
                Button("Turn Off") { model.setPluginEnabled(pluginId, false) }
            }
            .padding(.top, Space.xs)
        }
        .padding(Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The web view and its bridge. Package files are served through
/// `abstract-plugin://` only; every other navigation is refused, the data
/// store doesn't persist, and every inbound message goes through
/// `PluginBridge` in the core before anything acts on it.
private struct PluginWebView: NSViewRepresentable {
    @Environment(AppModel.self) private var model
    let plugin: InstalledPlugin
    let manifest: PluginManifest
    let theme: Theme
    let placement: PluginPlacement
    let fingerprint: Int
    let onFailure: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, plugin: plugin, manifest: manifest, theme: theme,
                    placement: placement, onFailure: onFailure)
    }

    func makeNSView(context: Context) -> WKWebView {
        let coordinator = context.coordinator
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(coordinator, forURLScheme: "abstract-plugin")
        configuration.preferences.isElementFullscreenEnabled = false
        let content = WKUserContentController()
        content.add(coordinator, name: "abstractPlugin")
        content.addUserScript(WKUserScript(source: Self.shim, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        configuration.userContentController = content

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = coordinator
        webView.setValue(false, forKey: "drawsBackground")
        coordinator.webView = webView
        let entry = manifest.entry.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? manifest.entry
        if let url = URL(string: "abstract-plugin://plugin/\(entry)") {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Live chats move: push a fresh snapshot whenever the model redraws
        // this screen, coalesced by the coordinator.
        if context.coordinator.theme != theme {
            context.coordinator.theme = theme
            context.coordinator.sendContext(changed: true)
        }
        context.coordinator.deliverInvocation()
        context.coordinator.pushSnapshotSoon()
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.tearDown()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "abstractPlugin")
    }

    /// `window.AbstractPlugin`: the plugin's whole API. Requests are answered
    /// by id; the host pushes `context` and `snapshot` messages.
    static let shim = """
    (() => {
      const pending = new Map();
      const listeners = new Map();
      let next = 1;
      const api = {
        send(type, payload) {
          const id = String(next++);
          return new Promise((resolve) => {
            pending.set(id, resolve);
            window.webkit.messageHandlers.abstractPlugin.postMessage(
              JSON.stringify({ api: 1, type, id, payload: payload || {} }));
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
        for (const fn of listeners.get(message.type) || []) {
          try { fn(message.payload); } catch (error) { report(error); }
        }
      };
      function report(error) {
        try {
          window.webkit.messageHandlers.abstractPlugin.postMessage(
            JSON.stringify({ api: 1, type: "__error", payload: { message: String(error) } }));
        } catch {}
      }
      window.addEventListener("error", (event) => report(event.message || "error"));
    })();
    """

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKURLSchemeHandler, WKNavigationDelegate {
        private let model: AppModel
        private let plugin: InstalledPlugin
        private let manifest: PluginManifest
        private let placement: PluginPlacement
        private let onFailure: () -> Void
        private var bridge: PluginBridge
        private var loaded = false
        private var pushScheduled = false
        private var dead = false
        var theme: Theme
        weak var webView: WKWebView?

        init(model: AppModel, plugin: InstalledPlugin, manifest: PluginManifest, theme: Theme,
             placement: PluginPlacement, onFailure: @escaping () -> Void) {
            self.model = model
            self.plugin = plugin
            self.manifest = manifest
            self.theme = theme
            self.placement = placement
            self.onFailure = onFailure
            bridge = PluginBridge(capabilities: plugin.record.grantedCapabilities,
                                  allowedHosts: Set(plugin.record.grantedNetworkHosts),
                                  secretNames: Set(plugin.record.grantedSecretNames))
        }

        func tearDown() { dead = true }

        // MARK: Serving the package

        func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
            guard let url = urlSchemeTask.request.url, url.host == "plugin" else {
                urlSchemeTask.didFailWithError(PluginHostError.refused); return
            }
            let path = String(url.path.dropFirst())
            guard let data = PluginPackage.fileData(in: plugin.packageURL, relativePath: path) else {
                urlSchemeTask.didFailWithError(PluginHostError.refused); return
            }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                "Content-Type": PluginPackage.mimeType(forPath: path),
                "Content-Security-Policy": "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:",
                "Content-Length": "\(data.count)",
            ])!
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        }

        func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}

        // MARK: Navigation stays inside the package

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(navigationAction.request.url?.scheme == "abstract-plugin" ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            sendContext()
            pushSnapshot()
            deliverInvocation()
        }

        /// A menu item or ⌘K command that opened this screen, handed over
        /// once the plugin can hear it.
        func deliverInvocation() {
            guard loaded, !dead, placement.place == .main,
                  let invocation = model.pluginInvocations[plugin.id] else { return }
            model.pluginInvocations[plugin.id] = nil
            send(type: "invoke", payload: invocation.jsonValue())
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            fail("It couldn't be loaded.")
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            fail("It stopped working.")
        }

        // MARK: The bridge

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard !dead, message.name == "abstractPlugin" else { return }
            guard plugin.record.enabled, model.plugins.plugin(plugin.id)?.isUsable == true else { return }
            let text = (message.body as? String) ?? ""
            // A script error is a stopped plugin, not a message to answer.
            if text.contains("\"__error\"") { fail("It stopped working."); return }
            let storage = model.plugins.manager.storage(for: plugin.id)
            switch bridge.handle(text, storage: storage) {
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
                // The grant as it stands now, not as it was when the screen opened.
                let keys = model.plugins.plugin(plugin.id)?.record.transcriptProjectKeys ?? []
                send(type: "reply", id: id,
                     payload: model.pluginTranscript(page: page, chatId: chatId, allowedProjectKeys: keys))
            case .getAutomations(let id, let page):
                send(type: "reply", id: id, payload: model.pluginAutomations(page: page))
            case .refused(let id, let reason):
                model.plugins.noteError(plugin.id, reason)
                send(type: "error", id: id, payload: .object(["message": .string(reason)]))
            case .flooded:
                fail("It sent too many messages, so it was stopped.")
            }
        }

        func pushSnapshotSoon() {
            guard loaded, !pushScheduled, !dead else { return }
            pushScheduled = true
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !dead else { return }
                pushScheduled = false
                pushSnapshot()
            }
        }

        private func pushSnapshot() {
            guard loaded, !dead, model.plugins.plugin(plugin.id)?.isUsable == true else { return }
            let snapshot = model.pluginSnapshot(capabilities: plugin.record.grantedCapabilities,
                                                revision: model.plugins.nextRevision())
            bridge.knownChatIds = Set(snapshot.chats?.map(\.id) ?? [])
            send(type: "snapshot", payload: snapshot.jsonValue())
            // A placed showing's chat moves with the snapshot.
            if placement.chatId != nil { sendContext() }
        }

        func sendContext(changed: Bool = false) {
            let chat = placement.chatId.flatMap {
                model.pluginChatRow(chatId: $0, capabilities: plugin.record.grantedCapabilities)
            }
            let context = PluginContext.jsonValue(
                theme: theme, locale: Locale.current.identifier,
                pluginId: manifest.id, pluginVersion: manifest.version,
                capabilities: plugin.record.grantedCapabilities,
                placement: placement, chat: chat)
            send(type: "context", payload: context)
            if changed { send(type: "themeChanged", payload: context) }
        }

        private func send(type: String, id: String? = nil, payload: JSONValue) {
            guard let webView, !dead else { return }
            let envelope = PluginBridge.encode(type: type, id: id, payload: payload)
            let literal = (try? JSONSerialization.data(withJSONObject: [envelope]))
                .map { String(decoding: $0, as: UTF8.self) } ?? "[\"\"]"
            webView.evaluateJavaScript("window.__abstractHostMessage(\(literal)[0])")
        }

        private func fail(_ note: String) {
            guard !dead else { return }
            dead = true
            model.plugins.noteError(plugin.id, note)
            webView?.stopLoading()
            onFailure()
        }
    }
}

private enum PluginHostError: Error { case refused }
