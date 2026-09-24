import Foundation
import CoreServices

/// Calls back when files change in a worktree or its branch moves, so the
/// review refreshes by itself, as Paseo's does. Build output and git's own
/// object store are ignored; bursts arrive as one call.
final class WorktreeWatcher {
    nonisolated(unsafe) private var stream: FSEventStreamRef?
    private let onChange: () -> Void
    private var pending = false

    /// Folders that are build output or dependencies nearly everywhere.
    private static let ignored = ["/.build/", "/node_modules/", "/DerivedData/", "/.next/", "/target/", "/dist/", "/.gradle/", "/Pods/",
                                  "/.git/objects/", "/.git/logs/", "/objects/pack/", ".lock"]

    init(paths: [String], onChange: @escaping () -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<WorktreeWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            guard list.prefix(count).contains(where: { path in !WorktreeWatcher.ignored.contains { path.contains($0) } }) else { return }
            MainActor.assumeIsolated { watcher.changed() }
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                               0.15, FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer))
        else { return }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    private func changed() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.pending = false
            self?.onChange()
        }
    }

    isolated deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
