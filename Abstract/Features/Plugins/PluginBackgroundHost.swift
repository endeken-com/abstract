import AppKit
import Darwin
import Observation
import WebKit
import AbstractCore

/// Runs every enabled plugin's background script (ABS-93), from launch,
/// in a hidden web view with the same sandbox as its screen. It hands
/// each script the events it subscribed to and its scheduled jobs, and
/// stops one that misbehaves. Turning a plugin off stops its script at once.
@MainActor
final class PluginBackgroundHost {
    private unowned let model: AppModel
    private var runners: [String: PluginBackgroundRunner] = [:]
    private var detector = PluginEventDetector()
    private var watching = false
    private var detectScheduled = false

    init(model: AppModel) {
        self.model = model
    }

    /// Starts what should run and stops what shouldn't, after any change
    /// to what's installed, enabled or granted.
    func reconcile() {
        let wanted = Dictionary(uniqueKeysWithValues: model.plugins.installed.compactMap { plugin -> (String, InstalledPlugin)? in
            guard plugin.isUsable, plugin.record.grantedBackground, plugin.manifest?.background != nil,
                  model.plugins.backgroundProblems[plugin.id] == nil else { return nil }
            return (plugin.id, plugin)
        })
        for (id, runner) in runners where wanted[id] == nil || wanted[id]?.record.version != runner.plugin.record.version {
            runner.stop()
            runners[id] = nil
        }
        for (id, plugin) in wanted where runners[id] == nil {
            guard let manifest = plugin.manifest else { continue }
            let runner = PluginBackgroundRunner(model: model, plugin: plugin, manifest: manifest) { [weak self] note in
                self?.stopped(id, note)
            }
            runners[id] = runner
            runner.start()
        }
        if runners.isEmpty {
            detector = PluginEventDetector()
        } else if !watching {
            watching = true
            watchChats()
        }
    }

    /// Stopped for misbehaving: listed in Settings → Plugins with why,
    /// until the person restarts it or turns the plugin off and on.
    private func stopped(_ id: String, _ note: String) {
        runners[id]?.stop()
        runners[id] = nil
        model.plugins.noteBackgroundStopped(id, note)
    }

    /// Hands one event to every script that subscribed to it, cut down to
    /// what each may read.
    func deliver(_ event: PluginEvent) {
        for runner in runners.values { runner.deliver(event) }
    }

    /// Hands a Review command to its plugin's script (ABS-112). False
    /// when that script isn't running to take it.
    func invoke(_ pluginId: String, _ invocation: PluginInvocation) -> Bool {
        runners[pluginId]?.invoke(invocation) ?? false
    }

    /// Runs an agent's call to one of a plugin's tools (ABS-97) in its
    /// script, within the time limit.
    func callTool(_ pluginId: String, name: String, input: JSONValue, chatId: String) async -> PluginToolOutcome {
        guard let runner = runners[pluginId] else {
            let name = model.plugins.plugin(pluginId)?.record.name ?? "That plugin"
            return .failed("\(name) isn't running, so its tool can't answer.")
        }
        return await runner.callTool(name, input: input, chatId: chatId)
    }

    /// Asks a plugin's script how a link in a chat stands (ABS-126).
    func lookUpLink(_ match: PluginLinks.Match) async -> PluginLinkLookup {
        guard let runner = runners[match.pluginId] else { return .failed }
        return await runner.lookUpLink(match)
    }

    /// Asks a plugin's script one of the issue tracker's questions (ABS-141).
    func askTracker(_ pluginId: String, _ request: TrackerRequest) async -> TrackerAnswer {
        guard let runner = runners[pluginId] else {
            let name = model.plugins.plugin(pluginId)?.record.name ?? "That plugin"
            return .failed("\(name) isn't running.")
        }
        return await runner.askTracker(request)
    }

    // MARK: Code hosts (ABS-139)

    /// Whether a plugin's script is running now.
    func isRunning(_ pluginId: String) -> Bool { runners[pluginId] != nil }

    /// Hosts a code host's script said its tool is signed in to.
    func codeHostExtraHosts(_ pluginId: String) -> Set<String> { runners[pluginId]?.codeHostHosts ?? [] }

    /// Asks a code host plugin's script one operation, within its time limit.
    func callCodeHost(_ pluginId: String, op: CodeHostOperation, input: JSONValue,
                      context: CodeHostContext) async -> PluginCodeHostAnswer {
        guard let runner = runners[pluginId] else {
            let name = model.plugins.plugin(pluginId)?.record.name ?? "That plugin"
            return .failed("\(name) isn't running, so it can't answer.")
        }
        return await runner.callCodeHost(op, input: input, context: context)
    }

    // MARK: Status and pull-request changes

    /// Follows the same facts a plugin's screen redraws on, and turns the
    /// changes into events.
    private func watchChats() {
        guard watching else { return }
        guard !runners.isEmpty else { watching = false; return }
        withObservationTracking {
            _ = model.pluginLiveFingerprint
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.detectSoon()
                self?.watchChats()
            }
        }
        detectSoon()
    }

    private func detectSoon() {
        guard !detectScheduled else { return }
        detectScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self else { return }
            detectScheduled = false
            guard !runners.isEmpty else { return }
            let chats = model.pluginSnapshot(capabilities: [.chatsRead], revision: 0).chats ?? []
            for event in detector.events(from: chats) { deliver(event) }
            for event in detector.resolved(pending: model.pluginPendingTargets()) { deliver(event) }
        }
    }
}

/// One plugin's background script: its hidden page, its subscriptions,
/// its jobs and its watchdog.
@MainActor
final class PluginBackgroundRunner: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let plugin: InstalledPlugin
    private let manifest: PluginManifest
    private let model: AppModel
    private let onStopped: (String) -> Void
    private var webView: WKWebView?
    private var connection: PluginConnection!
    private var subscriptions: Set<PluginEventType> = []
    private var jobs = PluginJobs()
    private var watchdog = PluginWatchdog()
    private var ticker: Task<Void, Never>?
    private var stopped = false
    /// Agents' tool calls the script hasn't answered yet (ABS-97).
    private let toolCalls: PluginToolCalls
    /// Link lookups the script hasn't answered yet (ABS-126).
    private let linkLookups = PluginLinkLookups()
    /// Issue tracker questions the script hasn't answered yet (ABS-141).
    private let trackerCalls: PluginTrackerCalls
    /// Core's code host calls the script hasn't answered yet (ABS-139).
    private let codeHostCalls: PluginCodeHostCalls
    /// Hosts the script said its tool is signed in to, while it runs.
    private(set) var codeHostHosts: Set<String> = []

    init(model: AppModel, plugin: InstalledPlugin, manifest: PluginManifest, onStopped: @escaping (String) -> Void) {
        self.model = model
        self.plugin = plugin
        self.manifest = manifest
        self.onStopped = onStopped
        toolCalls = PluginToolCalls(pluginName: manifest.name)
        trackerCalls = PluginTrackerCalls(pluginName: manifest.name)
        codeHostCalls = PluginCodeHostCalls(pluginName: manifest.name)
        super.init()
        connection = PluginConnection(
            model: model, plugin: plugin, manifest: manifest, placement: nil, isBackground: true,
            evaluate: { [weak self] script in self?.webView?.evaluateJavaScript(script) },
            fail: { [weak self] note in self?.fail(note) })
        connection.onScriptError = { [weak self] in
            guard let self else { return }
            if case .stopped(let note) = watchdog.scriptThrew() { fail(note) }
        }
        connection.onBackground = { [weak self] outcome in self?.handle(outcome) }
        connection.authorizesWrite = { [codeHostCalls] callId in await codeHostCalls.authorizesWrite(callId) }
    }

    func start() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(PluginSchemeHandler(packageURL: plugin.packageURL, background: manifest.background),
                                          forURLScheme: "abstract-plugin")
        // Hidden pages are suspended by default; this one is the work. The
        // watchdog keeps it from hogging the Mac.
        configuration.preferences.inactiveSchedulingPolicy = .none
        let content = WKUserContentController()
        content.add(self, name: "abstractPlugin")
        content.addUserScript(WKUserScript(source: PluginShim.source(api: manifest.api, background: true),
                                           injectionTime: .atDocumentStart, forMainFrameOnly: true))
        configuration.userContentController = content
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        self.webView = webView
        if let url = URL(string: "abstract-plugin://plugin/\(PluginSchemeHandler.backgroundPage)") {
            webView.load(URLRequest(url: url))
        }
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.tick()
            }
        }
    }

    /// Ends the script now: its web process is ended, not left to finish.
    func stop() {
        guard !stopped else { return }
        stopped = true
        connection.tearDown()
        Task { [toolCalls, name = manifest.name] in await toolCalls.failAll("\(name) stopped before its tool answered.") }
        Task { [linkLookups] in await linkLookups.failAll() }
        Task { [trackerCalls] in await trackerCalls.failAll() }
        Task { [codeHostCalls, name = manifest.name] in await codeHostCalls.failAll("\(name) stopped before it answered.") }
        ticker?.cancel()
        ticker = nil
        guard let webView else { return }
        self.webView = nil
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "abstractPlugin")
        webView.stopLoading()
        // A script stuck in a loop keeps its process busy even once the
        // view is gone, and WebKit's own kill doesn't reach it. The page
        // has its own data store, so its process is its alone: end it.
        if let pid = Self.webProcess(of: webView) { kill(pid, SIGKILL) }
    }

    private func fail(_ note: String) {
        guard !stopped else { return }
        stop()
        onStopped(note)
    }

    func deliver(_ event: PluginEvent) {
        guard connection.ready, !stopped, subscriptions.contains(event.type),
              let payload = event.payload(capabilities: connection.capabilities) else { return }
        connection.send(type: "event", payload: payload)
    }

    /// The chat it was run on is the person's own pick, so the script may
    /// act on it even before its next snapshot lists it.
    func invoke(_ invocation: PluginInvocation) -> Bool {
        guard connection.ready, !stopped else { return false }
        if let chatId = invocation.chatId { connection.know(chatId: chatId) }
        connection.send(type: "invoke", payload: invocation.jsonValue())
        return true
    }

    /// The call goes to the script as a `tool` message; its `tools.result`
    /// answers it. The chat that called is the agent's own, so the script
    /// may act on it, as on a chat a command was run from.
    func callTool(_ name: String, input: JSONValue, chatId: String) async -> PluginToolOutcome {
        await toolCalls.call { [weak self] callId in
            await MainActor.run {
                guard let self, self.connection.ready, !self.stopped else { return false }
                self.connection.know(chatId: chatId)
                self.connection.send(type: "tool", payload: .object([
                    "callId": .string(callId), "tool": .string(name), "input": input, "chatId": .string(chatId),
                ]))
                return true
            }
        }
    }

    /// Only a link one of its decorators names, cut the way its pattern
    /// cuts it, goes to the script: nothing else from the chat does.
    func lookUpLink(_ match: PluginLinks.Match) async -> PluginLinkLookup {
        let decorators = PluginContributions.resolve([plugin], place: .link)
        guard let url = URL(string: match.url), PluginLinks.match(url, decorators: decorators) == match else { return .failed }
        return await linkLookups.lookUp { [weak self] callId in
            await MainActor.run {
                guard let self, self.connection.ready, !self.stopped else { return false }
                self.connection.send(type: "link", payload: .object([
                    "callId": .string(callId), "contributionId": .string(match.contributionId), "url": .string(match.url),
                ]))
                return true
            }
        }
    }

    /// Only a plugin that declares a tracker is asked; the question carries
    /// what was typed in the composer's search, nothing about the chat.
    func askTracker(_ request: TrackerRequest) async -> TrackerAnswer {
        guard manifest.contributes.issueTracker != nil else { return .failed("\(manifest.name) isn't an issue tracker.") }
        return await trackerCalls.call(request) { [weak self] callId in
            await MainActor.run {
                guard let self, self.connection.ready, !self.stopped else { return false }
                self.connection.send(type: "tracker", payload: .object([
                    "callId": .string(callId), "operation": .string(request.operation), "input": request.input,
                ]))
                return true
            }
        }
    }

    /// The call goes to the script as a `codeHost` message; its
    /// `codeHost.result` answers it. The project and chat it is about are
    /// core's own pick, so the script may run its commands there.
    func callCodeHost(_ op: CodeHostOperation, input: JSONValue, context: CodeHostContext) async -> PluginCodeHostAnswer {
        await codeHostCalls.call(op) { [weak self] callId in
            await MainActor.run {
                guard let self, self.connection.ready, !self.stopped else { return false }
                if let chatId = context.chatId { self.connection.know(chatId: chatId) }
                if let key = context.projectKey { self.connection.know(projectKey: key) }
                var payload: [String: JSONValue] = ["callId": .string(callId), "op": .string(op.rawValue), "input": input]
                if case .object(let fields) = context.jsonValue() { payload.merge(fields) { a, _ in a } }
                self.connection.send(type: "codeHost", payload: .object(payload))
                return true
            }
        }
    }

    private func handle(_ outcome: PluginBridge.Outcome) {
        switch outcome {
        case .trackerResult(let callId, let payload):
            Task { [trackerCalls] in await trackerCalls.finish(callId, payload: payload) }
        case .codeHostResult(let callId, let answer):
            Task { [codeHostCalls] in await codeHostCalls.finish(callId, answer) }
        case .codeHostHosts(let id, let hosts):
            codeHostHosts = hosts
            connection.send(type: "reply", id: id, payload: .object(["hosts": .array(hosts.sorted().map(JSONValue.string))]))
        case .linkResult(let callId, let lookup):
            Task { [linkLookups] in await linkLookups.finish(callId, lookup) }
        case .toolResult(let callId, let result):
            Task { [toolCalls] in await toolCalls.finish(callId, result) }
        case .subscribe(let id, let types):
            subscriptions.formUnion(types)
            connection.send(type: "reply", id: id,
                            payload: .object(["types": .array(subscriptions.map(\.rawValue).sorted().map(JSONValue.string))]))
        case .scheduleJob(let id, let jobId, let rrule, let timezone):
            do {
                try jobs.schedule(id: jobId, rrule: rrule, timezone: timezone ?? TimeZone.current.identifier)
                let next = jobs.jobs[jobId]?.next.map { JSONValue.string(ISO8601DateFormatter().string(from: $0)) } ?? .null
                connection.send(type: "reply", id: id, payload: .object(["id": .string(jobId), "next": next]))
            } catch {
                connection.send(type: "error", id: id, payload: .object(["message": .string(error.localizedDescription)]))
            }
        case .cancelJob(let id, let jobId):
            jobs.cancel(id: jobId)
            connection.send(type: "reply", id: id, payload: .object(["id": .string(jobId), "cancelled": .bool(true)]))
        case .jobDone(let jobId):
            jobs.finished(id: jobId)
        default:
            break
        }
    }

    // MARK: Once a second: jobs and the watchdog

    private func tick() {
        guard !stopped, let webView else { return }
        let now = Date()
        if case .stopped(let note) = watchdog.check(now: now) { fail(note); return }
        if let usage = Self.usage(of: webView), case .stopped(let note) = watchdog.sample(
            cpuSeconds: usage.cpuSeconds, footprint: usage.footprint, now: now) {
            fail(note); return
        }
        // A busy loop never runs this, so the answer never comes.
        if watchdog.shouldSendHeartbeat(now: now) {
            webView.evaluateJavaScript("0") { [weak self] _, _ in
                MainActor.assumeIsolated { self?.watchdog.heartbeatAnswered() }
            }
        }
        guard connection.ready else { return }
        for jobId in jobs.due(now: now) {
            connection.send(type: "job", payload: .object([
                "id": .string(jobId), "at": .string(ISO8601DateFormatter().string(from: now)),
            ]))
        }
    }

    /// CPU time and memory of the script's web process, where WebKit
    /// tells us which process that is.
    private static func usage(of webView: WKWebView) -> (cpuSeconds: Double, footprint: UInt64)? {
        guard let pid = webProcess(of: webView) else { return nil }
        var info = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        guard result == 0 else { return nil }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticks = Double(info.ri_user_time + info.ri_system_time)
        let nanoseconds = ticks * Double(timebase.numer) / Double(timebase.denom)
        return (nanoseconds / 1_000_000_000, info.ri_phys_footprint)
    }

    /// The page's web content process, only when WebKit names one and it
    /// is a WebKit web content process — never anything else.
    private static func webProcess(of webView: WKWebView) -> pid_t? {
        guard webView.responds(to: NSSelectorFromString("_webProcessIdentifier")),
              let pid = (webView.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value,
              pid > 0, pid != getpid() else { return nil }
        var name = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &name, UInt32(name.count)) > 0,
              String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self).contains("WebContent") else { return nil }
        return pid
    }

    // MARK: WebKit

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.request.url?.scheme == "abstract-plugin" ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        connection.ready = true
        connection.pushSnapshot()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        fail("Its background script couldn't be loaded.")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // WebKit ends a page that outgrows its memory, among other things.
        fail("Its background script stopped working.")
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard !stopped, message.name == "abstractPlugin" else { return }
        connection.receive((message.body as? String) ?? "")
    }
}
