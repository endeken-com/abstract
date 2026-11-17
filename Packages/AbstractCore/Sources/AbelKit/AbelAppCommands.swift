import AbstractCore
import Foundation

/// ABEL acting on other Mac apps (ABS-205), by voice and for its chat's
/// tools. Every action passes the permission matrix first: its kind must
/// be on, its app not Off; Ask first is read back and waits for "yes", and
/// anything that sends, buys, deletes or posts needs "yes" even in an
/// Allowed app. Nothing happens while the screen is locked or shared.
extension AbelEngine {
    var appSettings: AbelAppControl { settings.appControl }

    static let shortcutsApp = (name: "Shortcuts", bundleId: "com.apple.shortcuts")
    static let finder = (name: "Finder", bundleId: "com.apple.finder")
    static let browser = (name: "your browser", bundleId: "browser")

    /// Whether ABEL may act, asking first when the matrix says so; the
    /// sentence ABEL says when it may not.
    /// `alwaysAsk`: read back even in an Allowed app, for what can't be
    /// judged safe from its words (a script, typing).
    func mayAct(_ kind: AbelAppControl.Kind, app bundleId: String?, name: String, action: String, alwaysAsk: Bool = false,
                question: @autoclosure () -> String) async -> (ok: Bool, why: String?) {
        if let reason = machine.pauseReason { return (false, reason.sentence) }
        // Only ABEL's chat's tools come through here: it asked, not you.
        switch AbelAppPolicy.decide(kind, app: bundleId, appName: name, action: action, settings: appSettings, language: lastLanguage,
                                    byAgent: true) {
        case let .refused(sentence):
            record(.refused, sentence)
            return (false, sentence)
        case .askFirst:
            return await confirm(question()) ? (true, nil) : (false, "The person said no.")
        case .allowed where alwaysAsk:
            return await confirm(question()) ? (true, nil) : (false, "The person said no.")
        case .allowed:
            return (true, nil)
        }
    }

    func app(named heard: String) -> AbelAppInfo? {
        let apps = appControl?.installedApps() ?? []
        if let exact = apps.first(where: { $0.name.lowercased() == heard.lowercased() || $0.bundleId == heard }) { return exact }
        guard case let .one(index, _) = AbelNames.match(heard, among: apps.enumerated().map { (id: $0.offset, name: $0.element.name) })
        else { return nil }
        return apps[index]
    }

    // MARK: By voice

    /// Asks first when the matrix says so, then acts; says why not otherwise.
    /// Never waits inside the call the "yes" will come through.
    func act(_ kind: AbelAppControl.Kind, app bundleId: String?, name: String, action: String, question: String,
             language: String, run: @escaping @MainActor () async -> Void) async {
        if let reason = machine.pauseReason { say(reason.sentence); return }
        switch AbelAppPolicy.decide(kind, app: bundleId, appName: name, action: action, settings: appSettings, language: language) {
        case let .refused(sentence):
            record(.refused, sentence)
            say(sentence)
        case .askFirst:
            ask(question, language: language) { yes in
                if yes { await run() } else { self.cancelled(language) }
            }
        case .allowed:
            await run()
        }
    }

    func openApp(_ app: AbelAppInfo, language: String) async {
        let say = AbelPhrases(language: language)
        guard let control = appControl else { return }
        await act(.open, app: app.bundleId, name: app.name, action: "open", question: say.openAsk(app.name), language: language) {
            do {
                try await control.open(app: app)
                self.record(.did, "Opened \(app.name), asked by you")
                self.say(say.opening(app.name))
            } catch {
                self.refused(error)
            }
        }
    }

    func openLocation(_ url: URL, label: String, appName: String, bundleId: String, language: String) async {
        let say = AbelPhrases(language: language)
        guard let control = appControl else { return }
        await act(.open, app: bundleId, name: appName, action: "open", question: say.openAsk(label), language: language) {
            do {
                try await control.open(url: url)
                self.record(.did, "Opened \(label), asked by you")
                self.say(say.opening(label))
            } catch {
                self.refused(error)
            }
        }
    }

    func runShortcut(_ name: String, input: String? = nil, language: String) async {
        let say = AbelPhrases(language: language)
        guard let control = appControl else { return }
        await act(.shortcuts, app: Self.shortcutsApp.bundleId, name: Self.shortcutsApp.name, action: name,
                  question: say.shortcutAsk(name), language: language) {
            do {
                let output = try await control.runShortcut(name, input: input)
                self.record(.did, "Ran the shortcut “\(name)”, asked by you")
                self.say(say.shortcutRan(name, output: SpeakableText(markdown: output).first))
            } catch {
                self.refused(error)
            }
        }
    }

    func refused(_ error: any Error) {
        record(.refused, error.localizedDescription)
        say(error.localizedDescription)
    }

    // MARK: Tools

    func appTool(_ name: String, _ arguments: JSONValue) async -> (text: String, isError: Bool) {
        guard let control = appControl else { return ("ABEL can't control other apps here.", true) }
        let say = AbelPhrases(language: lastLanguage)
        func appArgument() -> AbelAppInfo? { arguments["app"]?.string.flatMap { app(named: $0) } }
        func done(_ did: String, _ text: String) -> (text: String, isError: Bool) {
            record(.did, did + ", asked by ABEL's chat")
            return (text, false)
        }
        do {
            switch name {
            case "open_app":
                guard let app = appArgument() else { return ("No app on this Mac is called “\(arguments["app"]?.string ?? "")”.", true) }
                let gate = await mayAct(.open, app: app.bundleId, name: app.name, action: "open", question: say.openAsk(app.name))
                guard gate.ok else { return (gate.why ?? "Not done.", true) }
                try await control.open(app: app)
                return done("Opened \(app.name)", "Opened \(app.name).")
            case "open_url":
                guard let text = arguments["url"]?.string, let url = URL(string: text), url.scheme == "https" || url.scheme == "http"
                else { return ("Only web links (https) can be opened.", true) }
                let gate = await mayAct(.open, app: Self.browser.bundleId, name: Self.browser.name, action: "open",
                                        question: say.openAsk(url.host() ?? text))
                guard gate.ok else { return (gate.why ?? "Not done.", true) }
                try await control.open(url: url)
                return done("Opened \(url.host() ?? text)", "Opened \(text).")
            case "open_file":
                guard let raw = arguments["path"]?.string else { return ("Give a path.", true) }
                let checked = AbelAppChecks.openable(raw, home: NSHomeDirectory())
                guard let url = checked.url else {
                    let problem = checked.problem ?? "That can't be opened."
                    record(.refused, problem)
                    return (problem, true)
                }
                // Exactly the path checked is what's read back and opened.
                let gate = await mayAct(.open, app: Self.finder.bundleId, name: Self.finder.name, action: "open",
                                        question: say.openAsk(url.lastPathComponent))
                guard gate.ok else { return (gate.why ?? "Not done.", true) }
                try await control.open(url: url)
                return done("Opened \(url.lastPathComponent)", "Opened \(url.path).")
            case "run_shortcut":
                guard let heard = arguments["name"]?.string else { return ("Name the shortcut.", true) }
                let names = await control.shortcuts()
                guard case let .one(index, _) = AbelNames.match(heard, among: names.enumerated().map { (id: $0.offset, name: $0.element) })
                else { return ("No shortcut is called “\(heard)”.", true) }
                let shortcut = names[index]
                let gate = await mayAct(.shortcuts, app: Self.shortcutsApp.bundleId, name: Self.shortcutsApp.name,
                                        action: shortcut + " " + (arguments["input"]?.string ?? ""), question: say.shortcutAsk(shortcut))
                guard gate.ok else { return (gate.why ?? "Not done.", true) }
                let output = try await control.runShortcut(shortcut, input: arguments["input"]?.string)
                return done("Ran the shortcut “\(shortcut)”", output.isEmpty ? "The shortcut ran." : output)
            case "run_applescript":
                guard let app = appArgument() else { return ("No app on this Mac is called “\(arguments["app"]?.string ?? "")”.", true) }
                guard let script = arguments["script"]?.string, !script.isEmpty else { return ("There's no script to run.", true) }
                if let problem = AbelAppChecks.scriptProblem(script, app: app.name) {
                    record(.refused, problem)
                    return (problem, true)
                }
                // The script is always shown whole, and read back, before it runs;
                // never over another question, and gone once answered.
                guard !isWaitingForYes else { return ("ABEL is waiting on another answer. Try again in a moment.", true) }
                display = AbelDisplay(mode: .answering, words: app.name, detail: script)
                defer { display.detail = "" }
                let lines = script.split(separator: "\n", omittingEmptySubsequences: false).count
                let gate = await mayAct(.appleScript, app: app.bundleId, name: app.name, action: script, alwaysAsk: true,
                                        question: say.scriptAsk(app.name, lines: lines))
                guard gate.ok else { return (gate.why ?? "Not done.", true) }
                let result = try await control.runAppleScript(script)
                return done("Ran an AppleScript in \(app.name)", result.isEmpty ? "The script ran." : result)
            case "ui_read":
                guard let app = appArgument() else { return ("No app on this Mac is called “\(arguments["app"]?.string ?? "")”.", true) }
                let gate = await mayAct(.accessibility, app: app.bundleId, name: app.name, action: "read",
                                        question: say.readUIAsk(app.name))
                guard gate.ok else { return (gate.why ?? "Not done.", true) }
                let elements = try control.uiRead(app: app)
                let lines = elements.prefix(150).map { "\($0.role): \($0.isSecure ? "(password field)" : $0.title)" }
                return done("Read \(app.name)'s window", lines.isEmpty ? "Nothing to read." : lines.joined(separator: "\n"))
            case "ui_press":
                guard let app = appArgument() else { return ("No app on this Mac is called “\(arguments["app"]?.string ?? "")”.", true) }
                guard let heard = arguments["element"]?.string else { return ("Name what to press.", true) }
                // What will really be pressed is found first, and judged by its own title.
                let elements = try control.uiRead(app: app)
                guard case let .one(index, score) = AbelNames.match(heard, among: elements.enumerated().map { (id: $0.offset, name: $0.element.title) })
                else { return ("\(app.name) has no “\(heard)” to press.", true) }
                let element = elements[index].title
                let gate = await mayAct(.accessibility, app: app.bundleId, name: app.name, action: element, alwaysAsk: score < 1,
                                        question: say.pressAsk(element, app.name))
                guard gate.ok else { return (gate.why ?? "Not done.", true) }
                try control.uiPress(app: app, element: element)
                return done("Pressed “\(element)” in \(app.name)", "Pressed \(element).")
            case "ui_type":
                guard let app = appArgument() else { return ("No app on this Mac is called “\(arguments["app"]?.string ?? "")”.", true) }
                guard let text = arguments["text"]?.string else { return ("There's nothing to type.", true) }
                // Typing is always read back: a new line can send or run what's typed.
                let gate = await mayAct(.accessibility, app: app.bundleId, name: app.name, action: text, alwaysAsk: true,
                                        question: say.typeAsk(text, app.name))
                guard gate.ok else { return (gate.why ?? "Not done.", true) }
                try control.uiType(app: app, text: text)
                return done("Typed into \(app.name)", "Typed it.")
            default:
                return ("ABEL has no tool “\(name)”.", true)
            }
        } catch {
            record(.refused, error.localizedDescription)
            return (error.localizedDescription, true)
        }
    }
}
