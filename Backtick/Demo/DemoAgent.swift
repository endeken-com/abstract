import Foundation
import BacktickCore

/// A stand-in agent for demo mode. It prints claude's real stream-json
/// shapes, edits real files in its worktree (so the Changes tab has a real
/// diff), waits on stdin for permission answers, and answers follow-ups.
/// Everything downstream — parser, engine, timeline, diff — is the real code.
enum DemoAgent {
    static func wrap(_ spec: LaunchSpec, session: Session, prompt: String, followUp: Bool) -> LaunchSpec {
        let script: String
        if session.providerId == "codex" {
            script = codexScript(session: session, prompt: prompt, followUp: followUp)
        } else {
            script = followUp ? followUpScript(sessionId: session.id) : fullScript(session: session, prompt: prompt)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("backtick-demo-\(UUID().uuidString).sh")
        try? script.write(to: url, atomically: true, encoding: .utf8)
        return LaunchSpec(command: "/bin/sh", args: [url.path], cwd: spec.cwd, env: spec.env, stdinInitial: nil, keepStdinOpen: spec.keepStdinOpen)
    }

    static func followUpLine(_ text: String) -> String {
        ClaudeProvider().buildUserMessage(text) ?? "\(text)\n"
    }

    // MARK: - Script building

    private static func emit(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data()
        let json = String(data: data, encoding: .utf8) ?? "{}"
        return "printf '%s\\n' '\(json.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func pause(_ seconds: Double) -> String { "sleep \(seconds)" }

    private static func streamText(_ text: String, messageId: String, sid: String, pace: Double = 0.035) -> [String] {
        var lines: [String] = [
            emit(["type": "stream_event", "session_id": sid, "event": ["type": "message_start", "message": ["id": messageId, "role": "assistant"]]]),
            emit(["type": "stream_event", "session_id": sid, "event": ["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""]]]),
        ]
        var words: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ch == " " || ch == "\n" { words.append(current); current = "" }
        }
        if !current.isEmpty { words.append(current) }
        stride(from: 0, to: words.count, by: 3).forEach { i in
            let chunk = words[i..<min(i + 3, words.count)].joined()
            lines.append(pause(pace))
            lines.append(emit(["type": "stream_event", "session_id": sid, "event": ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": chunk]]]))
        }
        lines.append(emit(["type": "assistant", "session_id": sid, "message": ["id": messageId, "role": "assistant", "content": [["type": "text", "text": text]]]]))
        lines.append(emit(["type": "stream_event", "session_id": sid, "event": ["type": "content_block_stop", "index": 0]]))
        return lines
    }

    private static func tool(_ name: String, input: [String: Any], output: String, result: [String: Any]? = nil, sid: String, wait: Double = 0.5) -> [String] {
        let id = "toolu_demo_\(UUID().uuidString.prefix(8))"
        var user: [String: Any] = ["type": "user", "session_id": sid, "message": ["role": "user", "content": [["tool_use_id": id, "type": "tool_result", "content": output]]]]
        if let result { user["tool_use_result"] = result }
        return [
            pause(0.3),
            emit(["type": "assistant", "session_id": sid, "message": ["id": "msg_\(id)", "role": "assistant", "content": [["type": "tool_use", "id": id, "name": name, "input": input]]]]),
            pause(wait),
            emit(user),
        ]
    }

    private static func fullScript(session: Session, prompt: String) -> String {
        let sid = "demo-\(session.id.prefix(8))"
        let cwd = session.worktreePath ?? "."
        let ask = session.permissionPolicy == .ask
        let target = "src/sessions/SessionRow.swift"
        let helper = "src/sessions/SessionStatus+Derived.swift"
        var s: [String] = ["#!/bin/sh", "cd \(shellQuote(cwd)) || exit 1", "mkdir -p src/sessions"]

        s.append(pause(0.4))
        s.append(emit(["type": "system", "subtype": "init", "session_id": sid, "cwd": cwd, "model": "claude-opus-5", "permissionMode": ask ? "default" : "acceptEdits"]))
        s += streamText("I'll look at how chat rows decide their status first, then make the change.\n\n> \(prompt.split(separator: "\n").first.map(String.init) ?? prompt)", messageId: "msg_a_\(sid)", sid: sid)
        s += tool("Read", input: ["file_path": "\(cwd)/\(target)"], output: "42 lines", sid: sid)
        s += tool("Bash", input: ["command": "rg -n \"status\" src/sessions"], output: "src/sessions/SessionRow.swift:12:    let status = session.status\nsrc/sessions/SessionRow.swift:27:        StatusDot(status: status)\nsrc/sessions/Session.swift:9:    var status: SessionStatus", sid: sid, wait: 0.7)

        if ask {
            s.append(pause(0.3))
            s.append(emit(["type": "control_request", "request_id": "req_\(sid)", "request": ["subtype": "can_use_tool", "tool_name": "Edit",
                "input": ["file_path": "\(cwd)/\(target)", "old_string": "let status = session.status", "new_string": "let status = session.derivedStatus"]]]))
            s.append("read -r _answer")
        }

        // Real edits, so the Changes tab shows a real diff.
        s.append("sed -i '' 's/let status = session.status/let status = session.derivedStatus/' \(target) 2>/dev/null")
        s.append("sed -i '' 's/StatusDot(status: status)/StatusDot(status: status, pulsing: session.isLive)/' \(target) 2>/dev/null")
        s += tool("Edit", input: ["file_path": "\(cwd)/\(target)", "old_string": "let status = session.status", "new_string": "let status = session.derivedStatus"],
                  output: "The file has been updated.",
                  result: ["type": "update", "filePath": "\(cwd)/\(target)", "structuredPatch": [[
                      "oldStart": 10, "oldLines": 5, "newStart": 10, "newLines": 5,
                      "lines": ["     var body: some View {", "-    let status = session.status", "+    let status = session.derivedStatus", "     HStack(spacing: 8) {", "-        StatusDot(status: status)", "+        StatusDot(status: status, pulsing: session.isLive)"],
                  ]]], sid: sid)

        let helperBody = """
        import Foundation

        extension Session {
            /// A process that died mid-turn should not keep claiming to work.
            var derivedStatus: SessionStatus {
                status == .running && !isLive ? .errored : status
            }
        }

        """
        s.append("cat > \(helper) <<'BACKTICK_EOF'\n\(helperBody)BACKTICK_EOF")
        s += tool("Write", input: ["file_path": "\(cwd)/\(helper)", "content": helperBody], output: "File created successfully.",
                  result: ["type": "create", "filePath": "\(cwd)/\(helper)", "content": helperBody, "structuredPatch": []], sid: sid)

        s += streamText("""
        Done. Rows now derive their status instead of trusting the stored field, so a chat whose agent died shows **Error** rather than a stale **Working**.

        - `derivedStatus` checks liveness before believing `status`
        - live rows pulse, so running chats stand out at a glance
        - the stored field is untouched, so history and filters still work

        Run `swift test` to confirm nothing else depended on the old behaviour.
        """, messageId: "msg_b_\(sid)", sid: sid)
        s.append(pause(0.2))
        s.append(emit(["type": "system", "subtype": "post_turn_summary", "session_id": sid, "status_category": "completed", "status_detail": "Rows derive status from liveness", "needs_action": ""]))
        s.append(emit(["type": "result", "subtype": "success", "session_id": sid, "is_error": false, "duration_ms": 18_400, "num_turns": 4, "result": "Done.",
                       "total_cost_usd": 0.1842, "usage": ["input_tokens": 6, "output_tokens": 612, "cache_read_input_tokens": 48_210, "cache_creation_input_tokens": 9_870]]))
        s.append(replyLoop(sid: sid))
        return s.joined(separator: "\n") + "\n"
    }

    private static func followUpScript(sessionId: String) -> String {
        let sid = "demo-\(sessionId.prefix(8))"
        var s = ["#!/bin/sh"]
        s += streamText("Picking this back up. I re-read the files and the change is still in place, so there is nothing further to do.", messageId: "msg_r_\(UUID().uuidString.prefix(6))", sid: sid)
        s.append(emit(["type": "result", "subtype": "success", "session_id": sid, "is_error": false, "duration_ms": 3_100, "num_turns": 1, "result": "ok",
                       "total_cost_usd": 0.012, "usage": ["input_tokens": 2, "output_tokens": 64, "cache_read_input_tokens": 50_100, "cache_creation_input_tokens": 300]]))
        s.append(replyLoop(sid: sid))
        return s.joined(separator: "\n") + "\n"
    }

    /// After a turn, answer each follow-up line on stdin like a live agent.
    private static func replyLoop(sid: String) -> String {
        var body = streamText("Good call. I checked every caller and none of them read the old field directly, so the change is safe as it stands.", messageId: "msg_f_\(sid)", sid: sid)
        body.append(emit(["type": "result", "subtype": "success", "session_id": sid, "is_error": false, "duration_ms": 4_200, "num_turns": 1, "result": "ok",
                          "total_cost_usd": 0.021, "usage": ["input_tokens": 2, "output_tokens": 88, "cache_read_input_tokens": 52_000, "cache_creation_input_tokens": 400]]))
        return "while read -r _line; do\n" + body.joined(separator: "\n") + "\ndone"
    }

    /// Codex speaks `codex exec --json`: one process per turn, closed stdin.
    private static func codexScript(session: Session, prompt: String, followUp: Bool) -> String {
        let cwd = session.worktreePath ?? "."
        var s: [String] = ["#!/bin/sh", "cd \(shellQuote(cwd)) || exit 1", "mkdir -p src/pages"]
        s.append(emit(["type": "thread.started", "thread_id": "demo-codex-\(session.id.prefix(8))"]))
        s.append(pause(0.3))
        s.append(emit(["type": "turn.started"]))
        if followUp {
            s.append(pause(0.6))
            s.append(emit(["type": "item.completed", "item": ["id": "item_f", "type": "agent_message", "text": "Checked again: the hero copy change is in place and the layout no longer shifts on narrow screens."]]))
        } else {
            s.append(pause(0.6))
            s.append(emit(["type": "item.completed", "item": ["id": "item_0", "type": "agent_message", "text": "I'll find the hero component, tighten the copy, and reserve space for the image so the layout stops shifting."]]))
            s.append(pause(0.4))
            s.append(emit(["type": "item.started", "item": ["id": "item_1", "type": "command_execution", "command": "rg -n \"hero\" src", "aggregated_output": "", "exit_code": NSNull(), "status": "in_progress"]]))
            s.append(pause(0.7))
            s.append(emit(["type": "item.completed", "item": ["id": "item_1", "type": "command_execution", "command": "rg -n \"hero\" src", "aggregated_output": "src/pages/Hero.tsx:4:export function Hero() {\nsrc/pages/Hero.tsx:8:  <img src={cover} />", "exit_code": 0, "status": "completed"]]))
            s.append("printf '%s\\n' 'export function Hero() {' '  return <h1>Ship faster, together.</h1>;' '}' > src/pages/Hero.tsx")
            s.append(pause(0.5))
            s.append(emit(["type": "item.completed", "item": ["id": "item_2", "type": "agent_message", "text": "Updated `src/pages/Hero.tsx`: a shorter headline, and the cover image now has a fixed aspect ratio, which removes the layout shift on mobile."]]))
        }
        s.append(pause(0.2))
        s.append(emit(["type": "turn.completed", "usage": ["input_tokens": 21_400, "cached_input_tokens": 18_200, "cache_write_input_tokens": 0, "output_tokens": 240, "reasoning_output_tokens": 0]]))
        return s.joined(separator: "\n") + "\n"
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
