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
    /// Under Match System, the Mac switching appearance redraws this too.
    @Environment(\.colorScheme) private var colorScheme

    /// Reading this in `body` is what makes a fresh snapshot get pushed
    /// when a chat moves, without the host polling.
    private var liveFingerprint: Int { model.pluginLiveFingerprint }

    var body: some View {
        let fingerprint = liveFingerprint
        return Group {
            if let plugin = model.plugins.plugin(pluginId), plugin.isUsable, let manifest = plugin.manifest {
                if failed {
                    stoppedWorking(name: manifest.name)
                } else {
                    PluginWebView(plugin: plugin, manifest: manifest, appearance: model.pluginAppearance(),
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
        // Reading the choice and the scheme here redraws this view when
        // either changes; the coordinator then recolours the page and sends
        // the plugin a fresh context (no reload).
        .onChange(of: themeChoice) { }
        .onChange(of: colorScheme) { }
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
    let appearance: PluginAppearance
    let placement: PluginPlacement
    let fingerprint: Int
    let onFailure: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, plugin: plugin, manifest: manifest, appearance: appearance,
                    placement: placement, onFailure: onFailure)
    }

    func makeNSView(context: Context) -> WKWebView {
        let coordinator = context.coordinator
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(coordinator.schemeHandler, forURLScheme: "abstract-plugin")
        configuration.preferences.isElementFullscreenEnabled = false
        let content = WKUserContentController()
        content.add(coordinator, name: "abstractPlugin")
        configuration.userContentController = content

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = coordinator
        webView.setValue(false, forKey: "drawsBackground")
        coordinator.webView = webView
        coordinator.applyAppearance()
        let entry = manifest.entry.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? manifest.entry
        if let url = URL(string: "abstract-plugin://plugin/\(entry)") {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Live chats move: push a fresh snapshot whenever the model redraws
        // this screen, coalesced by the connection.
        if context.coordinator.appearance != appearance {
            context.coordinator.appearance = appearance
            context.coordinator.applyAppearance()
            context.coordinator.sendContext(changed: true)
        }
        context.coordinator.deliverInvocation()
        context.coordinator.connection.pushSnapshotSoon()
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.tearDown()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "abstractPlugin")
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        private let model: AppModel
        private let plugin: InstalledPlugin
        private let manifest: PluginManifest
        private let placement: PluginPlacement
        private let onFailure: () -> Void
        let schemeHandler: PluginSchemeHandler
        private(set) var connection: PluginConnection!
        private var loaded = false
        private var dead = false
        var appearance: PluginAppearance
        weak var webView: WKWebView?

        init(model: AppModel, plugin: InstalledPlugin, manifest: PluginManifest, appearance: PluginAppearance,
             placement: PluginPlacement, onFailure: @escaping () -> Void) {
            self.model = model
            self.plugin = plugin
            self.manifest = manifest
            self.appearance = appearance
            self.placement = placement
            self.onFailure = onFailure
            schemeHandler = PluginSchemeHandler(packageURL: plugin.packageURL)
            super.init()
            connection = PluginConnection(
                model: model, plugin: plugin, manifest: manifest, placement: placement,
                evaluate: { [weak self] script in self?.webView?.evaluateJavaScript(script) },
                fail: { [weak self] note in self?.fail(note) })
            // A script error stops a screen at once.
            connection.onScriptError = { [weak self] in self?.fail("It stopped working.") }
            // A placed showing's chat moves with the snapshot.
            connection.onSnapshot = { [weak self] in
                if self?.placement.chatId != nil { self?.sendContext() }
            }
        }

        func tearDown() {
            dead = true
            connection.tearDown()
        }

        /// The theme picked in Abstract, on the web view and in the page
        /// from its first frame (ABS-134): the colours are a user script
        /// that runs before the page's own CSS, ahead of the bridge. Kept
        /// current, so a reload starts in the theme showing now.
        func applyAppearance() {
            guard let webView else { return }
            webView.appearance = NSAppearance(named: appearance.isDark ? .darkAqua : .aqua)
            webView.underPageBackgroundColor = NSColor(appearance.canvas)
            let content = webView.configuration.userContentController
            content.removeAllUserScripts()
            for source in [PluginTheming.documentStartScript(appearance), PluginShim.source(api: manifest.api)] {
                content.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
            }
        }

        // MARK: Navigation stays inside the package

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            decisionHandler(navigationAction.request.url?.scheme == "abstract-plugin" ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            connection.ready = true
            sendContext()
            connection.pushSnapshot()
            deliverInvocation()
        }

        /// A menu item or ⌘K command that opened this screen, handed over
        /// once the plugin can hear it.
        func deliverInvocation() {
            guard loaded, !dead, placement.place == .main,
                  let invocation = model.pluginInvocations[plugin.id] else { return }
            model.pluginInvocations[plugin.id] = nil
            connection.send(type: "invoke", payload: invocation.jsonValue())
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            fail("It couldn't be loaded.")
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            fail("It stopped working.")
        }

        // MARK: The bridge

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard !dead, message.name == "abstractPlugin", plugin.record.enabled else { return }
            connection.receive((message.body as? String) ?? "")
        }

        func sendContext(changed: Bool = false) {
            let capabilities = connection.capabilities
            let chat = placement.chatId.flatMap {
                model.pluginChatRow(chatId: $0, capabilities: capabilities)
            }
            let context = PluginContext.jsonValue(
                appearance: appearance, locale: Locale.current.identifier,
                pluginId: manifest.id, pluginVersion: manifest.version,
                capabilities: capabilities,
                placement: placement, chat: chat)
            connection.send(type: "context", payload: context)
            if changed { connection.send(type: "themeChanged", payload: context) }
        }

        private func fail(_ note: String) {
            guard !dead else { return }
            tearDown()
            model.plugins.noteError(plugin.id, note)
            webView?.stopLoading()
            onFailure()
        }
    }
}
