import Foundation
import AbstractCore

/// A chat's background tasks list on screen, open at one task or at all of them.
struct TasksFocus: Equatable {
    let sessionId: String
    var taskId: String?
}

/// What a chat's agent runs in the background, subagents and shell commands,
/// as Claude Code's `/tasks` lists them; and Ctrl+B for work still in the
/// foreground. The list is read from the chat's log, so it survives a
/// relaunch and reaches chats on other Macs; only the agent's live process
/// can stop or move them.
extension AppModel {
    /// Tasks in the background, oldest first.
    func backgroundTasks(_ sessionId: String) -> [AgentTask] {
        feed(sessionId).tasks.filter(\.isBackgrounded)
    }

    /// Background tasks still at work. None outlive the agent's process.
    func runningBackgroundTasks(_ sessionId: String) -> Int {
        guard isAlive(sessionId) else { return 0 }
        return feed(sessionId).tasks.count { $0.isBackgrounded && $0.status == .running }
    }

    /// The chat's own commands and subagents at work in the foreground, long
    /// enough to have become tasks: what Ctrl+B moves.
    func foregroundTasks(_ sessionId: String) -> [AgentTask] {
        guard isAlive(sessionId), canControlTasks(sessionId) else { return [] }
        return feed(sessionId).tasks.filter { !$0.isBackgrounded && !$0.ownedBySubagent && $0.status == .running && $0.kind != .other }
    }

    /// Whether the chat's agent takes task commands at all.
    func canControlTasks(_ sessionId: String) -> Bool {
        guard let s = session(sessionId), let provider = ProviderRegistry.provider(s.providerId) else { return false }
        return provider.buildStopTask("", requestId: "") != nil
    }

    func stopTask(_ sessionId: String, taskId: String) {
        if let (_, host) = RemoteService.split(sessionId) {
            remote.onlineLink(for: sessionId)?.fire(.stopTask(sessionId: host, taskId: taskId))
            return
        }
        control(sessionId) { $0.buildStopTask(taskId, requestId: "stop-\(UUID().uuidString.prefix(8))") }
    }

    /// Ctrl+B: one call's work (`toolUseId`), or everything in the foreground.
    func moveToBackground(_ sessionId: String, toolUseId: String? = nil) {
        if let (_, host) = RemoteService.split(sessionId) {
            remote.onlineLink(for: sessionId)?.fire(.moveToBackground(sessionId: host, toolUseId: toolUseId))
            return
        }
        control(sessionId) { $0.buildBackground(toolUseId: toolUseId, requestId: "bg-\(UUID().uuidString.prefix(8))") }
    }

    private func control(_ sessionId: String, _ build: (any ProviderDefinition) -> String?) {
        guard isAlive(sessionId), let s = session(sessionId), let provider = ProviderRegistry.provider(s.providerId),
              let line = build(provider) else { return }
        do { try engine.write(sessionId: sessionId, line) } catch { flash(error.localizedDescription, isError: true) }
    }
}
