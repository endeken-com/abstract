import AppKit
import Foundation

/// Apps a worktree (or the file showing) can open in, after Paseo's editor
/// targets (Apache-2.0, Copyright (c) 2025-present Mohamed Boudra). Found by
/// bundle id; editors with a command line open a file at its line.
struct ExternalEditor: Identifiable, Hashable {
    enum Line: Hashable {
        /// `<cli> <workspace> --goto <file>:<line>` (the VS Code family).
        case goto(cli: String)
        /// `<cli> <workspace> <file>:<line>` (Zed).
        case suffix(cli: String)
        /// `xed --line <line> <file>` (Xcode).
        case xed
        /// Opens the file, without a line.
        case none
    }

    let id: String
    let name: String
    let bundleId: String
    let line: Line
    /// Finder and terminals open the folder; editors open it as a project.
    var isEditor = true

    var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) }
    var icon: NSImage? { appURL.map { NSWorkspace.shared.icon(forFile: $0.path) } }
}

enum ExternalEditors {
    static let known: [ExternalEditor] = [
        ExternalEditor(id: "cursor", name: "Cursor", bundleId: "com.todesktop.230313mzl4w4u92", line: .goto(cli: "Contents/Resources/app/bin/cursor")),
        ExternalEditor(id: "vscode", name: "VS Code", bundleId: "com.microsoft.VSCode", line: .goto(cli: "Contents/Resources/app/bin/code")),
        ExternalEditor(id: "vscode-insiders", name: "VS Code Insiders", bundleId: "com.microsoft.VSCodeInsiders", line: .goto(cli: "Contents/Resources/app/bin/code")),
        ExternalEditor(id: "windsurf", name: "Windsurf", bundleId: "com.exafunction.windsurf", line: .goto(cli: "Contents/Resources/app/bin/windsurf")),
        ExternalEditor(id: "vscodium", name: "VSCodium", bundleId: "com.vscodium", line: .goto(cli: "Contents/Resources/app/bin/codium")),
        ExternalEditor(id: "zed", name: "Zed", bundleId: "dev.zed.Zed", line: .suffix(cli: "Contents/MacOS/cli")),
        ExternalEditor(id: "xcode", name: "Xcode", bundleId: "com.apple.dt.Xcode", line: .xed),
        ExternalEditor(id: "sublime", name: "Sublime Text", bundleId: "com.sublimetext.4", line: .suffix(cli: "Contents/SharedSupport/bin/subl")),
        ExternalEditor(id: "nova", name: "Nova", bundleId: "com.panic.Nova", line: .none),
        ExternalEditor(id: "intellij", name: "IntelliJ IDEA", bundleId: "com.jetbrains.intellij", line: .none),
        ExternalEditor(id: "webstorm", name: "WebStorm", bundleId: "com.jetbrains.WebStorm", line: .none),
        ExternalEditor(id: "pycharm", name: "PyCharm", bundleId: "com.jetbrains.pycharm", line: .none),
        ExternalEditor(id: "goland", name: "GoLand", bundleId: "com.jetbrains.goland", line: .none),
        ExternalEditor(id: "rustrover", name: "RustRover", bundleId: "com.jetbrains.rustrover", line: .none),
        ExternalEditor(id: "android-studio", name: "Android Studio", bundleId: "com.google.android.studio", line: .none),
        ExternalEditor(id: "finder", name: "Finder", bundleId: "com.apple.finder", line: .none, isEditor: false),
        ExternalEditor(id: "terminal", name: "Terminal", bundleId: "com.apple.Terminal", line: .none, isEditor: false),
        ExternalEditor(id: "iterm", name: "iTerm", bundleId: "com.googlecode.iterm2", line: .none, isEditor: false),
        ExternalEditor(id: "ghostty", name: "Ghostty", bundleId: "com.mitchellh.ghostty", line: .none, isEditor: false),
    ]

    /// The ones on this Mac, looked up once.
    static let installed: [ExternalEditor] = known.filter { $0.appURL != nil }

    /// Opens `worktree` in `editor`; with `file`, that file too, at `line` where the editor can.
    static func open(_ editor: ExternalEditor, worktree: String, file: String?, line: Int?) {
        guard let app = editor.appURL else { return }
        let folder = URL(fileURLWithPath: worktree)
        if editor.id == "finder" {
            if let file { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file)]) } else { NSWorkspace.shared.open(folder) }
            return
        }
        guard editor.isEditor else {
            NSWorkspace.shared.open([folder], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            return
        }
        switch editor.line {
        case .goto(let cli) where file != nil:
            if run(app.appendingPathComponent(cli).path, [worktree, "--goto", file! + ":\(line ?? 1)"]) { return }
        case .suffix(let cli) where file != nil:
            if run(app.appendingPathComponent(cli).path, [worktree, file! + ":\(line ?? 1)"]) { return }
        case .xed where file != nil:
            if run("/usr/bin/xed", ["--line", "\(line ?? 1)", file!]) { return }
        default:
            break
        }
        let urls = [folder] + (file.map { [URL(fileURLWithPath: $0)] } ?? [])
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Starts a command line tool and leaves it; false when it isn't there.
    private static func run(_ tool: String, _ args: [String]) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: tool) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return (try? process.run()) != nil
    }
}
