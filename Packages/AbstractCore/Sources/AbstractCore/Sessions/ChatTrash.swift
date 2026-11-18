import Foundation

/// Deleting a chat's worktree or folder however big it is (ABS-206). The
/// chat leaves the app at once; then, in the background, its teardown script
/// runs, its folder is renamed into `~/.abstract/trash` (instant on the same
/// volume, whatever its size), git forgets the worktree with `worktree prune`,
/// and a low-priority `rm -rf` frees the space. What a quit interrupts is
/// finished on the next launch.
///
/// Only a chat's own folder is ever moved or deleted: a linked worktree
/// under Abstract's worktrees folder that git lists for the project, or a
/// standalone chat's folder. Never a symlink, never the project's checkout.
public enum ChatTrash {
    /// One chat's folder to delete, as it was when the chat was deleted.
    /// Kept on disk until it's done, so a quit can't strand it.
    public struct Job: Sendable, Hashable, Codable, Identifiable {
        public var chatId: String
        public var path: String
        /// The repository it's a worktree of; nil for a standalone chat's folder.
        public var projectRoot: String?
        /// Deleted with it only when `deleteBranch`.
        public var branch: String?
        public var deleteBranch: Bool
        /// The project's teardown script, run in the folder first.
        public var teardownScript: String?

        public var id: String { chatId }

        public init(chatId: String, path: String, projectRoot: String?, branch: String? = nil,
                    deleteBranch: Bool = false, teardownScript: String? = nil) {
            self.chatId = chatId; self.path = path; self.projectRoot = projectRoot
            self.branch = branch; self.deleteBranch = deleteBranch; self.teardownScript = teardownScript
        }
    }

    /// How a job's folder went.
    public enum Outcome: Sendable, Hashable {
        /// Out of its place and into the trash, waiting for `purge`.
        case trashed(URL)
        /// Gone already: removed by git (outside Abstract's folders), or never there.
        case removed
        /// Left where it is, and why.
        case left(String)
    }

    /// The teardown script's time limit.
    public static let teardownLimit: Duration = .seconds(120)
    /// Teardown scripts that may run at once in a bulk delete.
    public static let concurrentTeardowns = 3

    // MARK: Where

    /// `~/.abstract/trash`, beside the worktrees; the data directory's own
    /// when one is set (demo, tests).
    public static func root(home: String) -> URL {
        if let dir = dataDirectory { return dir.appendingPathComponent("trash", isDirectory: true) }
        return URL(fileURLWithPath: home).appendingPathComponent(".abstract/trash", isDirectory: true)
    }

    /// The folders chats' worktrees are made in that Abstract owns, the only
    /// ones a worktree is moved to the trash from: `~/.abstract/worktrees`,
    /// and beside the data directory when one is set (the demo's).
    public static func worktreeRoots(home: String) -> [URL] {
        var roots = [URL(fileURLWithPath: home).appendingPathComponent(".abstract/worktrees", isDirectory: true)]
        if let dir = dataDirectory { roots.append(dir.deletingLastPathComponent().appendingPathComponent("worktrees", isDirectory: true)) }
        return roots
    }

    /// Jobs not finished yet, one file each, inside the trash but never purged.
    static let pendingFolder = ".pending"

    private static var dataDirectory: URL? {
        guard let dir = ProcessInfo.processInfo.environment["ABSTRACT_DATA_DIR"], !dir.isEmpty else { return nil }
        return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
    }

    // MARK: What may go

    static let outsideRoots = "Not in Abstract's worktrees folder."

    /// Why `path` mustn't be moved to the trash as a worktree of
    /// `projectRoot`, or nil when it may: a real folder (not a symlink),
    /// strictly inside one of `roots` once links are resolved, holding a
    /// linked worktree's `.git` file (a checkout has a `.git` folder), and
    /// neither the project's checkout nor around or inside it.
    public static func worktreeRefusal(_ path: String, projectRoot: String, roots: [URL]) -> String? {
        guard path.hasPrefix("/") else { return "Not a full path." }
        guard isRealDirectory(path) else { return "Not a folder." }
        let real = resolved(path)
        let inside = roots.contains { root in
            let base = resolved(root.path)
            return real.hasPrefix(base + "/") && real.count > base.count + 1
        }
        guard inside else { return outsideRoots }
        var isDir: ObjCBool = false
        let dotGit = (path as NSString).appendingPathComponent(".git")
        guard !isSymlink(dotGit), FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDir), !isDir.boolValue else {
            return "Not a linked worktree."
        }
        let checkout = resolved(projectRoot)
        if real == checkout || checkout.hasPrefix(real + "/") || real.hasPrefix(checkout + "/") { return "It's the project's checkout." }
        return nil
    }

    /// Why a standalone chat's `path` mustn't go, or nil when it may: a
    /// real folder Abstract made for a chat (`Workspace.isChatFolder`).
    public static func folderRefusal(_ path: String, home: String) -> String? {
        guard path.hasPrefix("/"), isRealDirectory(path) else { return "Not a folder." }
        guard Workspace.isChatFolder(path, home: home) else { return "Not a chat's own folder." }
        return nil
    }

    static func isSymlink(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK
    }

    static func isRealDirectory(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    /// `path` with every symlink in it resolved; itself when it can't be.
    static func resolved(_ path: String) -> String {
        guard let real = realpath(path, nil) else { return URL(fileURLWithPath: path).standardizedFileURL.path }
        defer { free(real) }
        return String(cString: real)
    }

    // MARK: Moving

    public enum MoveError: Error, LocalizedError, Equatable {
        /// The trash is on another volume: a rename would be a copy.
        case otherVolume
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .otherVolume: "The trash is on another volume."
            case .failed(let why): why
            }
        }
    }

    /// Renames `path` to `<trash>/<chatId>`, never over something already
    /// there. Instant on one volume; refuses (`otherVolume`) rather than copy.
    public static func moveToTrash(_ path: String, chatId: String, trash: URL) throws -> URL {
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let name = chatId.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
        var dest = trash.appendingPathComponent(name, isDirectory: true)
        if FileManager.default.fileExists(atPath: dest.path) || isSymlink(dest.path) {
            dest = trash.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        }
        guard renamex_np(path, dest.path, UInt32(RENAME_EXCL)) == 0 else {
            let code = errno
            if code == EXDEV { throw MoveError.otherVolume }
            throw MoveError.failed(String(cString: strerror(code)))
        }
        return dest
    }

    // MARK: Running a job

    /// A job's teardown, rename and prune, without the purge. The teardown
    /// waits its turn in `teardowns` when given. Never throws: what couldn't
    /// be done is in the outcome, with its teardown's complaint if any.
    public static func run(_ job: Job, exec: any Executor, home: String, trash: URL, roots: [URL],
                           teardowns: Throttle? = nil, teardownLimit: Duration = teardownLimit) async -> (outcome: Outcome, teardown: String?) {
        guard FileManager.default.fileExists(atPath: job.path) || isSymlink(job.path) else {
            if let root = job.projectRoot { await prune(exec, root: root, branch: job.deleteBranch ? job.branch : nil) }
            return (.removed, nil)
        }
        var teardown: String?
        if let script = Project.nonBlank(job.teardownScript), job.projectRoot != nil, isRealDirectory(job.path) {
            if let teardowns {
                teardown = await teardowns.run { await runTeardown(exec, script: script, in: job.path, limit: teardownLimit) }
            } else {
                teardown = await runTeardown(exec, script: script, in: job.path, limit: teardownLimit)
            }
        }
        guard let root = job.projectRoot else {
            if let why = folderRefusal(job.path, home: home) { return (.left(why), teardown) }
            do { return (.trashed(try moveToTrash(job.path, chatId: job.chatId, trash: trash)), teardown) }
            catch { return (.left(error.localizedDescription), teardown) }
        }
        // git must know it as one of the project's linked worktrees, not its checkout.
        let listed = (try? await Git.worktrees(exec, root: root)) ?? []
        let key = resolved(job.path)
        guard listed.dropFirst().contains(where: { resolved($0.path) == key }) else {
            return (.left("git doesn't list it as one of the project's worktrees."), teardown)
        }
        let refusal = worktreeRefusal(job.path, projectRoot: root, roots: roots)
        if let refusal, refusal != outsideRoots { return (.left(refusal), teardown) }
        if refusal == nil {
            do {
                let moved = try moveToTrash(job.path, chatId: job.chatId, trash: trash)
                await prune(exec, root: root, branch: job.deleteBranch ? job.branch : nil)
                return (.trashed(moved), teardown)
            } catch MoveError.otherVolume {
                // Falls through to git, which deletes it in place.
            } catch {
                return (.left(error.localizedDescription), teardown)
            }
        }
        // A worktree kept elsewhere (a project's own worktree folder): git
        // removes it, as it only does for one of its linked worktrees.
        let out = try? await Git.git(exec, cwd: root, ["worktree", "remove", "--force", job.path])
        guard out?.ok == true else {
            let why = GitText.trimmed(out?.stderr ?? "")
            return (.left(why.isEmpty ? "git couldn't remove it." : why), teardown)
        }
        await prune(exec, root: root, branch: job.deleteBranch ? job.branch : nil)
        return (.removed, teardown)
    }

    /// git forgets worktrees whose folders are gone; then the branch, when asked.
    static func prune(_ exec: any Executor, root: String, branch: String?) async {
        await Prunes.shared.serially(root) {
            _ = try? await Git.git(exec, cwd: root, ["worktree", "prune"])
            if let branch, !branch.isEmpty { _ = try? await Git.git(exec, cwd: root, ["branch", "-D", branch]) }
        }
    }

    /// Runs a teardown script in `folder`, stopped after `limit`. Why it
    /// failed, or nil when it ran clean.
    public static func runTeardown(_ exec: any Executor, script: String, in folder: String, limit: Duration) async -> String? {
        let spec = LaunchSpec(command: "/bin/zsh", args: ["-lc", script], cwd: folder, keepStdinOpen: false)
        do {
            let result = try await exec.run(spec, timeout: limit)
            if result.timedOut { return "Teardown script stopped after \(limit.components.seconds) seconds" }
            if !result.ok { return "Teardown script failed: \(result.lastLine ?? result.code.map { "exit code \($0)" } ?? "it was stopped")" }
            return nil
        } catch {
            return "Teardown script didn't run: \(error.localizedDescription)"
        }
    }

    // MARK: Freeing the space

    /// Deletes `item`, a folder directly in `trash`, with `rm -rf` at low
    /// priority (it removes symlinks, never what they point to). Whether it's gone.
    ///
    /// Utility, not background, QoS: background throttles disk I/O so hard
    /// that 100k files took 118 s instead of 11 s (7 s at full priority)
    /// with builds running, which on a nearly full disk is space back too late.
    @discardableResult
    public static func purge(_ item: URL, trash: URL) async -> Bool {
        let parent = resolved(item.deletingLastPathComponent().path)
        guard parent == resolved(trash.path), item.lastPathComponent != pendingFolder,
              !item.lastPathComponent.isEmpty, item.lastPathComponent != "..", item.lastPathComponent != "." else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/rm")
        process.arguments = ["-rf", "--", item.path]
        process.qualityOfService = .utility
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in done.resume() }
            do { try process.run() } catch { process.terminationHandler = nil; done.resume() }
        }
        return !FileManager.default.fileExists(atPath: item.path) && !isSymlink(item.path)
    }

    /// What's in the trash besides unfinished jobs: left by a quit or a crash.
    public static func leftovers(trash: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: trash.path)) ?? []
        return names.filter { $0 != pendingFolder }.sorted().map { trash.appendingPathComponent($0) }
    }

    // MARK: Unfinished jobs

    /// Notes `job` as started, so a quit before its folder moves can't strand it.
    public static func record(_ job: Job, trash: URL) {
        let dir = trash.appendingPathComponent(pendingFolder, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let data = try? JSONEncoder().encode(job) { try? data.write(to: pendingFile(job.chatId, dir), options: .atomic) }
    }

    public static func finish(_ chatId: String, trash: URL) {
        try? FileManager.default.removeItem(at: pendingFile(chatId, trash.appendingPathComponent(pendingFolder)))
    }

    /// Jobs started and not finished, oldest first.
    public static func pending(trash: URL) -> [Job] {
        let dir = trash.appendingPathComponent(pendingFolder, isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "json" }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            .compactMap { try? JSONDecoder().decode(Job.self, from: Data(contentsOf: $0)) }
    }

    private static func pendingFile(_ chatId: String, _ dir: URL) -> URL {
        dir.appendingPathComponent(chatId.replacingOccurrences(of: "/", with: "-") + ".json")
    }

    // MARK: Sizes

    /// The bytes under `path`, as `du` counts them (hard links once, symlinks
    /// not followed); nil when it can't be read.
    public static func size(of path: String) async -> Int64? {
        guard isRealDirectory(path) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        process.arguments = ["-sk", path]
        process.qualityOfService = .utility
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let out: Data = await withCheckedContinuation { (done: CheckedContinuation<Data, Never>) in
            process.terminationHandler = { _ in done.resume(returning: pipe.fileHandleForReading.readDataToEndOfFile()) }
            do { try process.run() } catch { process.terminationHandler = nil; done.resume(returning: Data()) }
        }
        let text = String(decoding: out, as: UTF8.self)
        return text.split(whereSeparator: \.isWhitespace).first.flatMap { Int64($0) }.map { $0 * 1024 }
    }
}

/// At most `limit` bodies at once; the rest wait their turn, first come first served.
public actor Throttle {
    private let limit: Int
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    public init(_ limit: Int) { self.limit = max(1, limit) }

    public func run<T: Sendable>(_ body: @Sendable () async -> T) async -> T {
        if running >= limit { await withCheckedContinuation { waiting.append($0) } } else { running += 1 }
        defer {
            if waiting.isEmpty { running -= 1 } else { waiting.removeFirst().resume() }
        }
        return await body()
    }
}

/// One `worktree prune` at a time per repository: two at once race over
/// the same `.git/worktrees` entries.
actor Prunes {
    static let shared = Prunes()
    private var tails: [String: Task<Void, Never>] = [:]

    func serially(_ root: String, _ body: @escaping @Sendable () async -> Void) async {
        let previous = tails[root]
        let task = Task { await previous?.value; await body() }
        tails[root] = task
        await task.value
        if tails[root] == task { tails[root] = nil }
    }
}
