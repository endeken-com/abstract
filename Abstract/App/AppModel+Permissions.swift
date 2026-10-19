import Foundation
import AbstractCore

/// Permission answers remembered for a project: a request a rule matches
/// is answered for you in every chat of the project, and its tool row
/// names the rule. Managed in Project Settings → Permissions.
extension AppModel {
    func permissionRules(for projectId: String) -> [PermissionRule] {
        permissionRules[projectId] ?? []
    }

    func savePermissionRule(_ rule: PermissionRule) {
        do {
            try store.save(rule)
            var rules = permissionRules(for: rule.projectId)
            if let i = rules.firstIndex(where: { $0.id == rule.id }) { rules[i] = rule } else { rules.append(rule) }
            permissionRules[rule.projectId] = rules
        } catch {
            flash(error.localizedDescription, isError: true)
        }
    }

    func deletePermissionRule(_ rule: PermissionRule) {
        do {
            try store.deletePermissionRule(rule.id)
            permissionRules[rule.projectId]?.removeAll { $0.id == rule.id }
        } catch {
            flash(error.localizedDescription, isError: true)
        }
    }

    /// The rule that answers this request, if one does. Rules never apply
    /// under Full autonomy (nothing asks there), to a standalone chat (it
    /// has no project), or to a chat on a paired Mac.
    func permissionRuleAnswer(_ sessionId: String, toolName: String, input: JSONValue) -> PermissionRule? {
        guard !sessionId.hasPrefix(RemoteService.mirrorPrefix),
              let session = session(sessionId), let projectId = session.projectId,
              session.permissionPolicy != .bypass else { return nil }
        let root = session.worktreePath ?? project(projectId)?.rootPath
        return PermissionRule.answer(permissionRules(for: projectId), toolName: toolName, input: input, root: root)
    }

    /// Remember that a rule answered, so the request's tool row can say so:
    /// by the call's id when its row is already there, and by tool and
    /// input for a row still on its way.
    func recordRuleAnswer(_ rule: PermissionRule, requestId: String, toolName: String, input: JSONValue, in sessionId: String) {
        ruleNotes[sessionId, default: [:]][requestId] = rule.note
        if let call = feed(sessionId).calls.last(where: { $0.result == nil && $0.name == toolName && $0.input == input })
            ?? feed(sessionId).calls.last(where: { $0.result == nil && $0.name == toolName }) {
            ruleNotes[sessionId, default: [:]][call.id] = rule.note
        }
        ruleAnswers[sessionId, default: []].append(RuleAnswer(toolName: toolName, input: input, note: rule.note))
    }

    /// The rule note for a tool row, if a rule answered its request.
    func ruleNote(for call: ToolCall, in sessionId: String) -> String? {
        if let note = ruleNotes[sessionId]?[call.id] { return note }
        return ruleAnswers[sessionId]?.last { $0.toolName == call.name && $0.input == call.input }?.note
    }
}
