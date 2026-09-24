import AppKit
import Foundation
import AbstractCore

// MARK: - Settings

extension AppModel {
    /// Change one project and store it at once, the way macOS settings save.
    func updateProject(_ id: String, _ change: (inout Project) -> Void) {
        guard var p = project(id) else { return }
        let before = p
        change(&p)
        guard p != before else { return }
        do {
            try store.save(p)
        } catch {
            flash(error.localizedDescription, isError: true)
        }
        reload()
    }

    func renameProject(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        updateProject(id) { $0.name = trimmed }
    }

    /// A symbol and/or colour; either clears a custom image.
    func setProjectIcon(_ id: String, symbol: String?, color: String?) {
        let old = project(id)?.iconImagePath
        updateProject(id) { p in
            p.iconSymbol = symbol
            p.iconColor = color
            p.iconImagePath = nil
        }
        ProjectIconStore.discard(old)
    }

    func resetProjectIcon(_ id: String) {
        let old = project(id)?.iconImagePath
        updateProject(id) { p in
            p.iconSymbol = nil
            p.iconColor = nil
            p.iconImagePath = nil
        }
        ProjectIconStore.discard(old)
    }

    /// Copies the image (squared and scaled down) into Application Support.
    func importProjectIcon(_ id: String, from url: URL) {
        do {
            let path = try ProjectIconStore.save(url, projectId: id)
            let old = project(id)?.iconImagePath
            updateProject(id) { $0.iconImagePath = path }
            if old != path { ProjectIconStore.discard(old) }
        } catch {
            flash(error.localizedDescription, isError: true)
        }
    }

    /// Re-point a project at its repository's new folder. The folder must be
    /// a git repository, and the same one: its origin (when both have one)
    /// and its first commits (when the old folder can still be read) match.
    func relocateProject(_ id: String, to directory: String) async throws {
        guard let p = project(id) else { return }
        let probe = try await probe(directory: directory)
        let newRoot = probe.rootPath
        guard Self.canonical(newRoot) != Self.canonical(p.rootPath) else { return }
        if let other = projects.first(where: { $0.id != id && Self.canonical($0.rootPath) == Self.canonical(newRoot) }) {
            throw AbstractError.message("That folder is already the project “\(other.name)”.")
        }
        let oldReadable = FileManager.default.fileExists(atPath: p.rootPath)
        if oldReadable {
            if let a = await Git.originURL(executor, root: p.rootPath), let b = await Git.originURL(executor, root: newRoot),
               !GitRemote.sameRepository(a, b) {
                throw AbstractError.message("That's a different repository: its origin is \(b).")
            }
            let a = await Git.rootCommits(executor, root: p.rootPath)
            let b = await Git.rootCommits(executor, root: newRoot)
            if !a.isEmpty, !b.isEmpty, a.isDisjoint(with: b) {
                throw AbstractError.message("That's a different repository: its history shares no commits with this one.")
            }
        }
        updateProject(id) { p in
            p.rootPath = newRoot
            p.nestedRepos = probe.nestedRepos
        }
        // Chats' worktrees still point at the old folder's git directory.
        let worktrees = sessions.filter { $0.projectId == id }.compactMap(\.worktreePath)
            .filter { FileManager.default.fileExists(atPath: $0) }
        if !worktrees.isEmpty { await Git.repairWorktrees(executor, root: newRoot, paths: worktrees) }
        flash("\(p.name) now points at \(Self.abbreviated(newRoot, home: executor.homeDirectory))")
    }

    static func abbreviated(_ path: String, home: String) -> String {
        path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

// MARK: - Naming and lifecycle scripts

extension AppModel {
    static let setupLabel = "Setup"
    static let runLabel = "Run"

    /// Title and branch from the project's naming instructions, or nil to
    /// name the chat the usual way (no instructions, demo mode, any failure).
    func suggestedNaming(_ project: Project, prompt: String) async -> ChatNaming.Suggestion? {
        guard !isDemo, let instructions = Project.nonBlank(project.namingInstructions) else { return nil }
        let binary = providerOverrides["claude"]?.path.flatMap { $0.isEmpty ? nil : $0 }
        return await ChatNaming.suggest(executor: executor, binary: binary, instructions: instructions, task: prompt)
    }

    /// A new chat's worktree exists: run the project's setup script in a
    /// terminal tab under the chat, so its output is there to read.
    func runSetupScript(_ project: Project, in session: Session) {
        guard let script = Project.nonBlank(project.setupScript), let dir = session.worktreePath else { return }
        let paneId = UUID().uuidString
        updateLayout(session.id) { _ = $0.add(.terminal, to: .bottom, id: paneId) }
        TerminalRegistry.shared.host(for: paneId, directory: dir)
            .run(ProjectScript.command(script, kind: "setup", project: project, home: executor.homeDirectory), label: Self.setupLabel)
    }

    /// The chat toolbar's Run: the project's run script in the chat's Run
    /// terminal, reusing it (stopping what it ran before) when it is open.
    func runProjectScript(in sessionId: String) {
        guard let session = session(sessionId), let project = project(session.projectId),
              let script = Project.nonBlank(project.runScript), let dir = session.worktreePath else { return }
        let command = ProjectScript.command(script, kind: "run", project: project, home: executor(for: sessionId).homeDirectory)
        let registry = TerminalRegistry.shared
        if let item = layout(for: sessionId).items(of: .terminal).first(where: { registry.existingHost(for: $0.id)?.label == Self.runLabel }),
           let host = registry.existingHost(for: item.id) {
            updateLayout(sessionId) { $0.activate(item.id) }
            host.restart() // only if its shell has ended
            host.run(command, label: Self.runLabel, interrupt: true)
        } else {
            let paneId = UUID().uuidString
            updateLayout(sessionId) { _ = $0.add(.terminal, to: .bottom, id: paneId) }
            registry.host(for: paneId, directory: dir, remote: remoteLink(for: sessionId)).run(command, label: Self.runLabel)
        }
    }

    /// Before a worktree is removed: the teardown script, in the worktree,
    /// through a login shell, for at most a minute. Its failure is reported
    /// and removal goes ahead.
    func runTeardownScript(_ project: Project, worktree path: String) async {
        guard let script = Project.nonBlank(project.teardownScript), FileManager.default.fileExists(atPath: path) else { return }
        let spec = LaunchSpec(command: "/bin/zsh", args: ["-lc", script], cwd: path, keepStdinOpen: false)
        do {
            let result = try await executor.run(spec, timeout: .seconds(60))
            if result.timedOut {
                flash("Teardown script stopped after 60 seconds", isError: true)
            } else if !result.ok {
                let why = result.lastLine ?? result.code.map { "exit code \($0)" } ?? "it was stopped"
                flash("Teardown script failed: \(why)", isError: true)
            }
        } catch {
            flash("Teardown script didn't run: \(error.localizedDescription)", isError: true)
        }
    }
}

/// How a script is typed into a terminal: a one-line script as itself, so
/// the command reads plainly; a longer one saved to a file and sourced, so
/// a command that reads the terminal can't swallow the lines after it.
enum ProjectScript {
    static func command(_ script: String, kind: String, project: Project, home: String) -> String {
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("\n") else { return trimmed }
        let dir = directory(home: home)
        let name = "\(WorktreeNaming.slugify(project.name))-\(project.id.prefix(6).lowercased())-\(kind).sh"
        let file = dir.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try (trimmed + "\n").write(to: file, atomically: true, encoding: .utf8)
        } catch {
            return trimmed
        }
        // Under the home folder the path has only safe characters: say it as ~/….
        if file.path.hasPrefix(home + "/") { return "source ~" + file.path.dropFirst(home.count) }
        return "source " + quoted(file.path)
    }

    /// `~/.abstract/scripts`, beside the default worktrees; the data
    /// directory's own when one is set (demo, tests).
    static func directory(home: String) -> URL {
        if let dir = ProcessInfo.processInfo.environment["ABSTRACT_DATA_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath).appendingPathComponent("scripts")
        }
        return URL(fileURLWithPath: home).appendingPathComponent(".abstract/scripts")
    }

    /// Single-quoted for any POSIX shell (and fish).
    static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - Icon images

/// Custom project icons, kept beside the database.
enum ProjectIconStore {
    static var directory: URL {
        URL(fileURLWithPath: Store.defaultPath()).deletingLastPathComponent().appendingPathComponent("ProjectIcons", isDirectory: true)
    }

    /// A 256 pt square PNG of the image's centre; returns its path.
    static func save(_ source: URL, projectId: String) throws -> String {
        guard let image = NSImage(contentsOf: source), image.size.width > 0, image.size.height > 0 else {
            throw AbstractError.message("That file isn't an image Abstract can read.")
        }
        let side: CGFloat = 256
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(side), pixelsHigh: Int(side), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else {
            throw AbstractError.message("Couldn't prepare the icon.")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        let scale = max(side / image.size.width, side / image.size.height)
        let drawn = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: NSRect(x: (side - drawn.width) / 2, y: (side - drawn.height) / 2, width: drawn.width, height: drawn.height),
                   from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw AbstractError.message("Couldn't save the icon.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("\(projectId)-\(UUID().uuidString.prefix(8)).png")
        try png.write(to: file)
        cache.removeAllObjects()
        return file.path
    }

    /// Delete an icon Abstract copied in; never a file elsewhere.
    static func discard(_ path: String?) {
        guard let path, path.hasPrefix(directory.path + "/") else { return }
        try? FileManager.default.removeItem(atPath: path)
        cache.removeObject(forKey: path as NSString)
    }

    private static let cache = NSCache<NSString, NSImage>()

    static func image(_ path: String) -> NSImage? {
        if let hit = cache.object(forKey: path as NSString) { return hit }
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        cache.setObject(image, forKey: path as NSString)
        return image
    }
}
