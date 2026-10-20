import Foundation
import AbstractCore

/// "Pause everything": one action that stops every running agent and pauses
/// every automation, and its mirror, which turns back on only the automations
/// the pause itself switched off. The same pair exists per project.
extension AppModel {
    var everythingPaused: Bool { pauseState.everythingPaused }

    /// Projects paused on their own, in sidebar order.
    var pausedProjects: [Project] { projects.filter { pauseState.pausedProjectIds.contains($0.id) } }

    func projectIsPaused(_ id: String) -> Bool { pauseState.isPaused(.project(id)) }

    func pauseEverything() { pause(.all) }

    func resumeEverything() { resume(.all) }

    func pauseProject(_ id: String) { pause(.project(id)) }

    func resumeProject(_ id: String) { resume(.project(id)) }

    /// Stops each agent at work in scope the way Stop does, cancels its
    /// setups, and pauses its active automations. Idle agents are left
    /// alive: chats keep their state and continue when you write to them.
    private func pause(_ scope: PauseState.Scope) {
        var state = pauseState
        let toPause = state.pause(scope, automations: automations, sessions: sessions)
        pauseState = state
        for session in PauseState.sessions(in: scope, from: sessions)
        where setups[session.id]?.active == true || (session.status.isActive && session.status != .idle) {
            stop(session.id)
        }
        setAutomationsPaused(toPause, paused: true)
    }

    /// Turns back on the automations the pause turned off. Agents are not
    /// restarted; you continue chats yourself.
    private func resume(_ scope: PauseState.Scope) {
        var state = pauseState
        let toResume = state.resume(scope, automations: automations, sessions: sessions)
        pauseState = state
        setAutomationsPaused(toResume, paused: false)
    }

    private func setAutomationsPaused(_ ids: [String], paused: Bool) {
        for id in ids {
            guard var a = automations.first(where: { $0.id == id }), a.enabled == paused else { continue }
            a.enabled = !paused
            do {
                try saveAutomation(a)
            } catch {
                flash(error.localizedDescription, isError: true)
            }
        }
    }
}
