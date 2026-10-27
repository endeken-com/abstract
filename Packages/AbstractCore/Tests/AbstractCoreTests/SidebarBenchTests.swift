import Foundation
import Testing
import AbstractCore

// Throwaway profile for ABS-159: 50 projects, 1000 chats, 200 with PRs.
// Run: swift test -c release --filter SidebarBench
@Suite struct SidebarBench {
    let projects: [Project] = (0..<50).map { Project(name: "proj-\($0)", rootPath: "/tmp/p\($0)", iconImagePath: "/tmp/icon-\($0).png") }
    var sessions: [Session] {
        (0..<1000).map { i in
            var s = Session(id: "s\(i)", projectId: projects[i % 50].id, name: "Fix oauth callback \(i)", providerId: "claude",
                            branch: "abstract/oauth-\(i)", status: i % 7 == 0 ? .running : .idle,
                            createdAt: Date(timeIntervalSince1970: 1_000_000), lastEventAt: Date(timeIntervalSince1970: TimeInterval(1_000_000 + i)))
            if i % 97 == 0 { s.pinnedAt = Date(timeIntervalSince1970: TimeInterval(i)) }
            return s
        }
    }
    var chats: [SidebarChats.Chat] {
        sessions.enumerated().map { i, s in
            SidebarChats.Chat(session: s, pullRequest: i % 5 == 0 ? .init(number: 1000 + i, state: .open, checks: .passed) : nil,
                              hasChanges: i % 3 == 0, projectName: "proj-\(i % 50)", mac: "Studio")
        }
    }

    func time(_ label: String, _ n: Int = 20, _ body: () -> Int) {
        _ = body()
        let t0 = ContinuousClock.now
        var acc = 0
        for _ in 0..<n { acc &+= body() }
        let elapsed = ContinuousClock.now - t0
        let totalMs = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        let ms: Double = totalMs / Double(n)
        let rounded = (ms * 1000).rounded() / 1000
        let line = "BENCH \(label): \(rounded) ms/op (acc \(acc))\n"
        FileHandle.standardError.write(Data(line.utf8))
        if let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: "/tmp/sidebar-bench.txt")) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
    }

    @Test func bench() {
        let chats = self.chats
        let sessions = self.sessions
        let projects = self.projects
        let filter = SidebarChats.Filter()

        // Current per-render: sections()
        time("sections(1000)") { SidebarChats.sections(chats).reduce(0) { $0 + $1.chats.count } }
        // Current per-render: visibleChats, no query
        time("visibleChats empty query") { chats.filter { $0.session.archivedAt == nil && filter.matches($0) && SidebarChats.matches($0, query: "") }.count }
        // Current per-render: visibleChats, query "oauth"
        time("visibleChats query=oauth") { chats.filter { $0.session.archivedAt == nil && filter.matches($0) && SidebarChats.matches($0, query: "oauth") }.count }
        time("NEW visibleChats query=oauth") { SidebarChats.visible(chats, filter: filter, query: "oauth", showArchived: false).count }
        // Current project arrangement: sessions(in:) per project
        time("projectGroups sessions(in:) x50") {
            projects.reduce(0) { acc, p in acc + Ordering.pinnedFirst(sessions.filter { $0.projectId == p.id && $0.archivedAt == nil }).count }
        }
        time("NEW projectGroups one pass") {
            let groups = SidebarChats.groupedByProject(chats)
            return projects.reduce(0) { $0 + (groups[$1.id]?.count ?? 0) }
        }
        // Current sidebarChats(): project() linear lookup x2 + icon fileExists per chat
        time("project lookup x2 + icon fileExists per chat") {
            sessions.reduce(0) { acc, s in
                let p1 = projects.first { $0.id == s.projectId }
                let p2 = projects.first { $0.id == s.projectId }
                _ = SidebarChats.icon(project: p2, isRemote: false, remoteImage: nil)
                return acc + (p1 == nil ? 0 : 1)
            }
        }
        // Current: filter JSON decoded ~4x per body
        let json = "{\"projects\":[\"proj-1\"],\"agents\":[\"claude\"],\"macs\":[]}"
        time("Filter JSON decode x4") {
            var n = 0
            for _ in 0..<4 { n += (try? JSONDecoder().decode(SidebarChats.Filter.self, from: Data(json.utf8)))?.projects.count ?? 0 }
            return n
        }
        // Current: equatable() row diff — hash+compare every Chat (no image data)
        let copy = chats
        time("Chat == x1000 (no imageData)") { zip(chats, copy).count { $0 == $1 } }
        // Remote chats carry icon PNG bytes in the Chat value (256px PNG ~ 60KB here)
        let png = Data((0..<60_000).map { UInt8($0 % 251) })
        let remote = chats.map { c -> SidebarChats.Chat in var c = c; c.icon = .project(.init(name: "p", imageData: png)); return c }
        var remote2 = remote
        remote2[0].icon = .project(.init(name: "p", imageData: Data(png))) // distinct storage, same bytes
        time("Chat == x1000 (60KB imageData each)") { zip(remote, remote2).count { $0 == $1 } }
        // Breakdown of the 20.7 ms: lookup only vs fileExists only
        time("project lookup x2 only (linear)") {
            sessions.reduce(0) { acc, s in
                let a = projects.first { $0.id == s.projectId }; let b = projects.first { $0.id == s.projectId }
                return acc + ((a == nil || b == nil) ? 0 : 1)
            }
        }
        time("icon fileExists only per chat") {
            sessions.reduce(0) { acc, _ in acc + (FileManager.default.fileExists(atPath: "/tmp/icon-7.png") ? 1 : 0) }
        }
        time("NEW dict lookup + icon once per project") {
            let byId = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            var icons: [String: SidebarChats.Icon] = [:]
            return sessions.reduce(0) { acc, s in
                guard let pid = s.projectId, let p = byId[pid] else { return acc }
                if icons[pid] == nil { icons[pid] = SidebarChats.icon(project: p, isRemote: false, remoteImage: nil) }
                return acc + 1
            }
        }
        // Search candidates, query "oauth"
        time("search range(caseInsensitive)") {
            chats.count { $0.session.name.range(of: "oauth", options: .caseInsensitive) != nil || ($0.session.branch?.range(of: "oauth", options: .caseInsensitive) != nil) }
        }
        time("search lowercased contains") {
            let needle = "oauth"
            return chats.count { $0.session.name.lowercased().contains(needle) || ($0.session.branch?.lowercased().contains(needle) ?? false) }
        }
        // FilterMenu body: project/mac name sets
        time("filter menu name sets") {
            let p = Set(projects.map(\.name) + chats.map { $0.projectName ?? "Standalone" }).sorted()
            let m = Set(chats.map(\.mac) + ["Studio"]).sorted()
            return p.count + m.count
        }
    }
}
