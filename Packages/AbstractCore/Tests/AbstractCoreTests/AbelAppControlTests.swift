import Foundation
import Testing
@testable import AbstractCore

/// ABEL and other apps (ABS-205): the permission matrix, the grammar, and
/// the checks before a script runs or a file opens.
@Suite struct AbelAppControlTests {
    typealias Kind = AbelAppControl.Kind
    typealias Mode = AbelAppControl.Mode

    @Test func onlyOpeningIsOnFromTheStart() {
        let settings = AbelSettings()
        #expect(settings.appControl.kinds == [.open])
        #expect(settings.appControl.mode(for: "com.apple.Notes") == .askFirst)
        let old = try? JSONDecoder().decode(AbelSettings.self, from: Data(#"{"wakePhrase":true}"#.utf8))
        #expect(old?.appControl.kinds == [.open])
    }

    @Test(arguments: Kind.allCases)
    func aKindThatIsOffRefuses(_ kind: Kind) {
        let decision = AbelAppPolicy.decide(kind, app: "com.apple.Notes", appName: "Notes", action: "make a note",
                                            settings: AbelAppControl(kinds: Set(Kind.allCases).subtracting([kind])))
        guard case let .refused(sentence) = decision else { Issue.record("got \(decision)"); return }
        #expect(sentence.contains("is off"))
    }

    /// Kind on; then the app's mode, then whether the action is consequential.
    @Test(arguments: [
        (Mode.allowed, "make a note", AbelAppPolicy.Decision.allowed),
        (Mode.allowed, "send the message", .askFirst),
        (Mode.allowed, "delete the draft", .askFirst),
        (Mode.allowed, "buy it now", .askFirst),
        (Mode.allowed, "post this", .askFirst),
        (Mode.askFirst, "make a note", .askFirst),
        (Mode.askFirst, "send the message", .askFirst),
    ])
    func theMatrix(_ mode: Mode, _ action: String, _ expected: AbelAppPolicy.Decision) {
        for kind in [Kind.shortcuts, .appleScript, .accessibility] {
            let settings = AbelAppControl(kinds: Set(Kind.allCases), apps: ["com.apple.Notes": mode])
            #expect(AbelAppPolicy.decide(kind, app: "com.apple.Notes", appName: "Notes", action: action, settings: settings) == expected)
        }
    }

    @Test func offRefusesEveryKindWithASentence() {
        let settings = AbelAppControl(kinds: Set(Kind.allCases), apps: ["com.apple.Notes": .off])
        for kind in Kind.allCases {
            #expect(AbelAppPolicy.decide(kind, app: "com.apple.Notes", appName: "Notes", action: "open", settings: settings)
                == .refused("Notes is set to Off for ABEL in Settings › ABEL › Other apps."))
        }
    }

    @Test func openingIsInstantUnlessOff() {
        let settings = AbelAppControl(kinds: [.open], apps: ["com.apple.Safari": .askFirst, "com.apple.Mail": .off])
        #expect(AbelAppPolicy.decide(.open, app: "com.apple.Safari", appName: "Safari", action: "open", settings: settings) == .allowed)
        #expect(AbelAppPolicy.decide(.open, app: "org.example.Unlisted", appName: "Unlisted", action: "open", settings: settings) == .allowed)
        #expect(AbelAppPolicy.decide(.open, app: "com.apple.Mail", appName: "Mail", action: "open", settings: settings)
            == .refused("Mail is set to Off for ABEL in Settings › ABEL › Other apps."))
    }

    @Test func openingIsNeverConsequential() {
        let settings = AbelAppControl(kinds: [.open], apps: ["com.apple.Mail": .allowed])
        #expect(AbelAppPolicy.decide(.open, app: "com.apple.Mail", appName: "Mail", action: "send", settings: settings) == .allowed)
    }

    // MARK: The grammar

    static let apps = [AbelAppInfo(name: "Safari", bundleId: "com.apple.Safari", path: "/Applications/Safari.app"),
                       AbelAppInfo(name: "Notes", bundleId: "com.apple.Notes", path: "/System/Applications/Notes.app"),
                       AbelAppInfo(name: "Terminal", bundleId: "com.apple.Terminal", path: "/System/Applications/Utilities/Terminal.app")]
    static let chats = [AbelChatInfo(id: "c1", title: "Palette overlay", pullRequest: 43,
                                     pullRequestURL: "https://github.com/example/app/pull/43"),
                        AbelChatInfo(id: "c2", title: "Sidebar fix")]

    func resolve(_ text: String) -> AbelIntent {
        AbelResolver.resolve(text, chats: Self.chats, projects: [], apps: Self.apps, shortcuts: ["Standup", "Morning routine"],
                             home: "/Users/someone")
    }

    @Test func opensAppsAfterChats() {
        #expect(resolve("Open Safari.") == .openApp(Self.apps[0]))
        #expect(resolve("open sidebar fix") == .open(chatId: "c2"))
        #expect(resolve("open the weather") == .notFound(command: "open", heard: "weather"))
    }

    @Test func opensYourFolders() {
        #expect(resolve("Open tilde slash Downloads") == .openFile("/Users/someone/Downloads"))
        #expect(resolve("Open film slash download.") == .openFile("/Users/someone/Downloads"))
        #expect(resolve("open the documents folder") == .openFile("/Users/someone/Documents"))
    }

    @Test func opensAChatsPullRequest() {
        #expect(resolve("Open the PR for the palette chat.") == .openURL("https://github.com/example/app/pull/43", chatId: "c1"))
        #expect(resolve("open the PR for sidebar fix") == .notFound(command: "pullRequest", heard: "sidebar fix"))
    }

    @Test func runsShortcutsByTheirNames() {
        #expect(resolve("Run shortcut stand up.") == .runShortcut("Standup"))
        #expect(resolve("run my morning routine shortcut") == .runShortcut("Morning routine"))
        #expect(resolve("rodar o atalho standup") == .runShortcut("Standup"))
        #expect(resolve("run shortcut launch the rockets") == .notFound(command: "shortcut", heard: "launch the rockets"))
    }

    // MARK: Scripts and files

    @Test func aScriptForTheAppItNames() {
        #expect(AbelAppChecks.scriptProblem(#"tell application "Notes" to make new note with properties {body:"Build log"}"#, app: "Notes") == nil)
        #expect(AbelAppChecks.scriptProblem("tell application \"Notes\"\n    make new note with properties {body:\"Build log\"}\nend tell", app: "Notes") == nil)
    }

    @Test(arguments: [
        #"do shell script "rm -rf ~""#,
        #"tell application "Notes" to do shell script "id""#,
        "tell application \"Notes\" to do shell ¬\nscript \"id\"",
        #"tell application "System Events" to keystroke "x""#,
        #"tell application "Mail" to send"#,
        #"set target to "Mail"\ntell application target to activate"#,
        #"«event sysoexec» "id""#,
        #"run script "x""#,
        "tell application \"Notes\" to activate\nset x to 1",
        "set x to 1\ntell application \"Notes\"\nactivate\nend tell",
        "tell application \"Notes\"\nactivate\nend tell\ntell application \"Notes\"\nactivate\nend tell",
        #"tell application "Notes" to activate -- comment"#,
        #"tell application "Notes" to set x to (read POSIX file "/etc/hosts")"#,
        #"tell application "Notes" to open for access "x""#,
        "tell application \"Notes\" to make new note with properties {body:\"" + String(repeating: "x", count: 90) + "\"}",
    ])
    func scriptsThatReachFurtherAreRefused(_ script: String) {
        #expect(AbelAppChecks.scriptProblem(script, app: "Notes") != nil)
    }

    @Test(arguments: ["Terminal", "Finder", "System Events", "Script Editor", "iTerm"])
    func someAppsAreNeverScripted(_ app: String) {
        #expect(AbelAppChecks.scriptProblem(#"tell application "\#(app)" to activate"#, app: app) != nil)
    }

    @Test func opensOnlyPlainDocumentsAndFoldersAtHome() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("abel-home-\(UUID().uuidString)")
        try fm.createDirectory(at: home.appendingPathComponent("Downloads"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        try "notes".write(to: home.appendingPathComponent("Downloads/readme.txt"), atomically: true, encoding: .utf8)
        try "#!/bin/sh\necho hi".write(to: home.appendingPathComponent("Downloads/run.command"), atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.appendingPathComponent("Downloads/run.command").path)
        try "x".write(to: home.appendingPathComponent("Downloads/tool"), atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.appendingPathComponent("Downloads/tool").path)
        try fm.createDirectory(at: home.appendingPathComponent("Downloads/Thing.app/Contents"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: home.appendingPathComponent("Linked").path, withDestinationPath: "/etc")

        #expect(AbelAppChecks.openable(home.appendingPathComponent("Downloads").path, home: home.path).url != nil)
        #expect(AbelAppChecks.openable(home.appendingPathComponent("Downloads/readme.txt").path, home: home.path).url != nil)
        #expect(AbelAppChecks.openable(home.appendingPathComponent("Downloads/run.command").path, home: home.path).url == nil)
        #expect(AbelAppChecks.openable(home.appendingPathComponent("Downloads/tool").path, home: home.path).url == nil)
        #expect(AbelAppChecks.openable(home.appendingPathComponent("Downloads/Thing.app").path, home: home.path).url == nil)
        #expect(AbelAppChecks.openable(home.appendingPathComponent("Linked/hosts").path, home: home.path).url == nil)
        #expect(AbelAppChecks.openable(home.appendingPathComponent("Downloads/../Downloads").path, home: home.path).url == nil)
        #expect(AbelAppChecks.openable("/etc/hosts", home: home.path).url == nil)
        #expect(AbelAppChecks.openable(home.appendingPathComponent("missing.txt").path, home: home.path).url == nil)
        try "[InternetShortcut]".write(to: home.appendingPathComponent("Downloads/link.webloc"), atomically: true, encoding: .utf8)
        #expect(AbelAppChecks.openable(home.appendingPathComponent("Downloads/link.webloc").path, home: home.path).url == nil)
        try "x".write(to: home.appendingPathComponent("Downloads/data.bin"), atomically: true, encoding: .utf8)
        #expect(AbelAppChecks.openable(home.appendingPathComponent("Downloads/data.bin").path, home: home.path).url == nil)
    }

    @Test func consequentialWords() {
        #expect(AbelAppPolicy.isConsequential("Send"))
        #expect(AbelAppPolicy.isConsequential("Move to Trash"))
        #expect(AbelAppPolicy.isConsequential("Publicar agora"))
        #expect(!AbelAppPolicy.isConsequential("New Note"))
        #expect(!AbelAppPolicy.isConsequential("Open the sender's profile"))
    }
}
