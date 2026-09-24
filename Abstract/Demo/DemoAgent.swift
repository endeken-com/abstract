import Foundation
import AbstractCore

/// A stand-in agent for demo mode. It prints claude's real stream-json
/// shapes, edits real files in its worktree (so the Changes tab has a real
/// diff), waits on stdin for permission answers, and answers follow-ups.
/// Everything downstream — parser, engine, timeline, diff — is the real code.
enum DemoAgent {
    static func wrap(_ spec: LaunchSpec, session: Session, prompt: String, followUp: Bool) -> LaunchSpec {
        let script: String
        if session.providerId == "codex" {
            script = codexScript(session: session, prompt: prompt, followUp: followUp)
        } else if !followUp, let log = ProcessInfo.processInfo.environment["ABSTRACT_DEMO_REPLAY"] {
            script = replayScript(log)
        } else {
            script = followUp ? followUpScript(sessionId: session.id) : fullScript(session: session, prompt: prompt)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("abstract-demo-\(UUID().uuidString).sh")
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

    /// Plays a recorded session log (`sessions/<id>.jsonl`) back, for
    /// reproducing real streaming: at a steady pace, or with each row's
    /// recorded `at` (seconds) when it has one.
    private static func replayScript(_ path: String) -> String {
        var last: Double?
        let lines = ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").split(separator: "\n").flatMap { row -> [String] in
            guard let object = try? JSONSerialization.jsonObject(with: Data(row.utf8)) as? [String: Any],
                  object["stream"] as? String == "stdout", let line = object["line"] as? String else { return [] }
            let at = object["at"] as? Double
            let wait = at.map { at in defer { last = at }; return max(0, at - (last ?? at)) } ?? 0.01
            return [pause(wait), "printf '%s\\n' '\(line.replacingOccurrences(of: "'", with: "'\\''"))'"]
        }
        return (["#!/bin/sh"] + lines + ["cat >/dev/null"]).joined(separator: "\n")
    }

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

    /// A thinking block, streamed the way `--thinking-display summarized` does.
    private static func streamThinking(_ text: String, messageId: String, sid: String) -> [String] {
        var lines = [
            emit(["type": "stream_event", "session_id": sid, "event": ["type": "message_start", "message": ["id": messageId, "role": "assistant"]]]),
            emit(["type": "stream_event", "session_id": sid, "event": ["type": "content_block_start", "index": 0, "content_block": ["type": "thinking", "thinking": ""]]]),
        ]
        for sentence in text.split(separator: ".", omittingEmptySubsequences: true) {
            lines.append(pause(0.12))
            lines.append(emit(["type": "stream_event", "session_id": sid, "event": ["type": "content_block_delta", "index": 0,
                                                                                    "delta": ["type": "thinking_delta", "thinking": sentence + "."]]]))
        }
        lines.append(emit(["type": "stream_event", "session_id": sid, "event": ["type": "content_block_stop", "index": 0]]))
        return lines
    }

    private static func tool(_ name: String, input: [String: Any], output: String, result: [String: Any]? = nil, sid: String, wait: Double = 0.5) -> [String] {
        let id = "toolu_demo_\(UUID().uuidString.prefix(8))"
        return [pause(0.3), toolUse(id, name, input, sid: sid), pause(wait), toolResult(id, output, result, sid: sid)]
    }

    private static func toolUse(_ id: String, _ name: String, _ input: [String: Any], sid: String) -> String {
        emit(["type": "assistant", "session_id": sid, "message": ["id": "msg_\(id)", "role": "assistant", "content": [["type": "tool_use", "id": id, "name": name, "input": input]]]])
    }

    private static func toolResult(_ id: String, _ output: String, _ result: [String: Any]?, sid: String) -> String {
        var user: [String: Any] = ["type": "user", "session_id": sid, "message": ["role": "user", "content": [["tool_use_id": id, "type": "tool_result", "content": output]]]]
        if let result { user["tool_use_result"] = result }
        return emit(user)
    }

    private static func todos(_ states: [String], sid: String) -> [String] {
        let items = [("Read how rows pick their status", "Reading how rows pick their status"),
                     ("Derive status from the live process", "Deriving status from the live process"),
                     ("Pulse rows that are working", "Pulsing rows that are working")]
        let todos = zip(items, states).map { item, state in ["content": item.0, "activeForm": item.1, "status": state] }
        return tool("TodoWrite", input: ["todos": todos], output: "Todos have been modified successfully.", sid: sid, wait: 0.2)
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
        s += streamThinking("Rows read session.status as stored, so a chat whose agent died still says Working. The process registry already knows which agents are alive. Deriving the status there fixes every row at once, without touching what's saved.",
                            messageId: "msg_t_\(sid)", sid: sid)
        s += streamText("I'll look at how chat rows decide their status first, then make the change.\n\n> \(prompt.split(separator: "\n").first.map(String.init) ?? prompt)", messageId: "msg_a_\(sid)", sid: sid)
        s += todos(["in_progress", "pending", "pending"], sid: sid)
        s += tool("Read", input: ["file_path": "\(cwd)/\(target)"], output: "42 lines", sid: sid, wait: 0.3)
        s += tool("Grep", input: ["pattern": "status", "path": "\(cwd)/src/sessions"], output: "src/sessions/SessionRow.swift\nsrc/sessions/Session.swift", sid: sid, wait: 0.3)
        s += tool("Read", input: ["file_path": "\(cwd)/src/sessions/Session.swift"], output: "18 lines", sid: sid, wait: 0.3)
        s += tool("Bash", input: ["command": "swift build --target Sessions", "description": "Build the sessions target"], output: "Building for debugging...\nBuild complete! (3.21s)", sid: sid, wait: 0.7)
        let background = BackgroundDemo(sid: sid)
        s += background.start()
        s += todos(["completed", "in_progress", "pending"], sid: sid)

        // Real edits, so the Changes tab shows a real diff.
        let editId = "toolu_demo_edit_\(sid)"
        let editInput: [String: Any] = ["file_path": "\(cwd)/\(target)",
                                        "old_string": "    let status = session.status\n    HStack(spacing: 8) {\n        StatusDot(status: status)",
                                        "new_string": "    let status = session.derivedStatus\n    HStack(spacing: 8) {\n        StatusDot(status: status, pulsing: session.isLive)"]
        s.append(pause(0.3))
        s.append(toolUse(editId, "Edit", editInput, sid: sid))
        if ask {
            s.append(pause(0.3))
            s.append(emit(["type": "control_request", "request_id": "req_\(sid)", "request": ["subtype": "can_use_tool", "tool_name": "Edit",
                "input": editInput, "tool_use_id": editId]]))
            s.append("read -r _answer")
        }
        s.append("sed -i '' 's/let status = session.status/let status = session.derivedStatus/' \(target) 2>/dev/null")
        s.append("sed -i '' 's/StatusDot(status: status)/StatusDot(status: status, pulsing: session.isLive)/' \(target) 2>/dev/null")
        s.append(pause(0.4))
        s.append(toolResult(editId, "The file has been updated.",
                            ["type": "update", "filePath": "\(cwd)/\(target)", "structuredPatch": [[
                                "oldStart": 10, "oldLines": 5, "newStart": 10, "newLines": 5,
                                "lines": ["     var body: some View {", "-    let status = session.status", "+    let status = session.derivedStatus", "     HStack(spacing: 8) {", "-        StatusDot(status: status)", "+        StatusDot(status: status, pulsing: session.isLive)"],
                            ]]], sid: sid))

        let helperBody = """
        import Foundation

        extension Session {
            /// A process that died mid-turn should not keep claiming to work.
            var derivedStatus: SessionStatus {
                status == .running && !isLive ? .errored : status
            }
        }

        """
        s.append("cat > \(helper) <<'ABSTRACT_EOF'\n\(helperBody)ABSTRACT_EOF")
        s += tool("Write", input: ["file_path": "\(cwd)/\(helper)", "content": helperBody], output: "File created successfully.",
                  result: ["type": "create", "filePath": "\(cwd)/\(helper)", "content": helperBody, "structuredPatch": []], sid: sid)
        s += background.midway()
        s += todos(["completed", "completed", "completed"], sid: sid)

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
        s.append(emit(["type": "prompt_suggestion", "suggestion": "Add a test for derivedStatus", "session_id": sid]))
        s += background.finish()
        s.append(replyLoop(sid: sid))
        return s.joined(separator: "\n") + "\n"
    }

    /// Work the demo agent sends to the background, as claude 2.1.280 reports
    /// it: a subagent and a test run, each ending with a turn of its own after
    /// the main one, and a preview server that runs until you stop it.
    private struct BackgroundDemo {
        let sid: String
        var agentCall: String { "toolu_demo_agent_\(sid)" }
        var agentTask: String { "a_demo_\(sid)" }
        var testsCall: String { "toolu_demo_tests_\(sid)" }
        var testsTask: String { "b_demo_tests_\(sid)" }
        var serverCall: String { "toolu_demo_server_\(sid)" }
        var serverTask: String { "b_demo_server_\(sid)" }
        var folder: String { FileManager.default.temporaryDirectory.appendingPathComponent("abstract-demo-\(sid)").path }
        func output(_ task: String) -> String { "\(folder)/\(task).output" }

        private func system(_ subtype: String, _ fields: [String: Any]) -> String {
            emit(["type": "system", "subtype": subtype, "session_id": sid].merging(fields) { a, _ in a })
        }

        /// Lines appended to a task's output file over time, in the background.
        private func writes(_ task: String, _ lines: [String], every seconds: Double, forever: Bool = false) -> String {
            let body = lines.map { "echo \(shellQuote($0)) >> \(shellQuote(output(task))); sleep \(seconds)" }.joined(separator: "; ")
            // Bounded, and ended with the agent, so a quit demo leaves nothing writing.
            let pid = shellQuote(folder + "/server.pid")
            return forever
                ? "( for _i in $(seq 1 200); do \(body); done ) & echo $! > \(pid); trap 'kill $(cat \(pid)) 2>/dev/null' EXIT; trap 'exit 143' TERM INT HUP"
                : "( \(body) ) &"
        }

        private func sub(_ line: [String: Any]) -> String {
            emit(line.merging(["parent_tool_use_id": agentCall, "session_id": sid]) { a, _ in a })
        }

        func start() -> [String] {
            var s = ["mkdir -p \(shellQuote(folder))", pause(0.3)]
            s.append(toolUse(agentCall, "Agent", ["description": "Find other readers of session.status", "subagent_type": "Explore", "run_in_background": true,
                                                  "prompt": "List every place outside SessionRow that reads session.status directly, with file and line."], sid: sid))
            s.append(system("task_started", ["task_id": agentTask, "tool_use_id": agentCall, "description": "Find other readers of session.status",
                                             "subagent_type": "Explore", "is_backgrounded": true, "task_type": "local_agent",
                                             "prompt": "List every place outside SessionRow that reads session.status directly, with file and line."]))
            s.append(toolResult(agentCall, "Async agent launched successfully.\nThe agent is working in the background. You will be notified automatically when it completes.", nil, sid: sid))
            for (call, task, command, description, lines, forever) in [
                (testsCall, testsTask, "swift test --parallel", "Run the test suite",
                 ["Building for debugging...", "Build complete! (4.02s)", "Test Suite 'All tests' started", "Test Suite 'SessionTests' passed (61 tests)",
                  "Test Suite 'RowTests' passed (38 tests)", "Test Suite 'All tests' passed: 214 tests, 0 failures"], false),
                (serverCall, serverTask, "swift run Preview --port 8080", "Serve the preview",
                 ["[preview] listening on http://localhost:8080", "[preview] GET / 200 3ms", "[preview] rebuilt SessionRow in 0.4s"], true),
            ] {
                s.append(pause(0.3))
                s.append(toolUse(call, "Bash", ["command": command, "description": description, "run_in_background": true], sid: sid))
                s.append(system("task_started", ["task_id": task, "tool_use_id": call, "description": description, "is_backgrounded": true, "task_type": "local_bash"]))
                s.append(writes(task, lines, every: forever ? 2.5 : 1.2, forever: forever))
                s.append(toolResult(call, "Command running in background with ID: \(task). Output is being written to: \(output(task)). You will be notified when it completes.", nil, sid: sid))
            }
            s += [pause(0.4),
                  sub(["type": "assistant", "message": ["id": "msg_sub1_\(sid)", "role": "assistant", "content": [["type": "tool_use", "id": "toolu_sub1_\(sid)", "name": "Grep", "input": ["pattern": "session\\.status", "path": "src"]]]]]),
                  system("task_progress", ["task_id": agentTask, "tool_use_id": agentCall, "description": "Searching for session.status",
                                           "usage": ["total_tokens": 8_420, "tool_uses": 1, "duration_ms": 1_900], "last_tool_name": "Grep"]),
                  sub(["type": "user", "message": ["role": "user", "content": [["tool_use_id": "toolu_sub1_\(sid)", "type": "tool_result", "content": "src/sessions/SessionRow.swift:11\nsrc/sidebar/RailRow.swift:24\nsrc/home/RecentList.swift:40"]]]])]
            return s
        }

        func midway() -> [String] {
            [pause(0.3),
             sub(["type": "assistant", "message": ["id": "msg_sub2_\(sid)", "role": "assistant", "content": [["type": "tool_use", "id": "toolu_sub2_\(sid)", "name": "Read", "input": ["file_path": "src/sidebar/RailRow.swift"]]]]]),
             system("task_progress", ["task_id": agentTask, "tool_use_id": agentCall, "description": "Reading RailRow.swift",
                                      "usage": ["total_tokens": 11_870, "tool_uses": 2, "duration_ms": 4_300], "last_tool_name": "Read"]),
             sub(["type": "user", "message": ["role": "user", "content": [["tool_use_id": "toolu_sub2_\(sid)", "type": "tool_result", "content": "58 lines"]]]])]
        }

        /// After the main turn: each task's end, and the turn the agent takes for it.
        func finish() -> [String] {
            let report = "Two other places read `session.status` directly:\n\n- `src/sidebar/RailRow.swift:24`\n- `src/home/RecentList.swift:40`\n\nBoth should switch to `derivedStatus`."
            var s = [pause(3.5),
                     system("task_updated", ["task_id": testsTask, "patch": ["status": "completed"]]),
                     system("task_notification", ["task_id": testsTask, "tool_use_id": testsCall, "status": "completed", "output_file": output(testsTask),
                                                  "summary": "Background command \"Run the test suite\" completed (exit code 0)"])]
            s += turn("The test suite passed in the background: 214 tests, no failures.", id: "msg_bg1_\(sid)")
            s += [pause(1.5),
                  sub(["type": "assistant", "message": ["id": "msg_sub3_\(sid)", "role": "assistant", "content": [["type": "text", "text": report]]]]),
                  system("task_updated", ["task_id": agentTask, "patch": ["status": "completed"]]),
                  system("task_notification", ["task_id": agentTask, "tool_use_id": agentCall, "status": "completed", "summary": report,
                                               "usage": ["total_tokens": 13_900, "tool_uses": 2, "duration_ms": 9_800]])]
            s += turn("The search found two more places reading `session.status` directly, in `RailRow` and `RecentList`. Want me to switch them to `derivedStatus` too?", id: "msg_bg2_\(sid)")
            return s
        }

        private func turn(_ text: String, id: String) -> [String] {
            [system("init", ["cwd": ".", "model": "claude-opus-5", "permissionMode": "acceptEdits"])]
                + streamText(text, messageId: id, sid: sid)
                + [emit(["type": "result", "subtype": "success", "session_id": sid, "is_error": false, "duration_ms": 2_400, "num_turns": 1, "result": "ok",
                         "total_cost_usd": 0.014, "usage": ["input_tokens": 2, "output_tokens": 70, "cache_read_input_tokens": 51_000, "cache_creation_input_tokens": 300]])]
        }
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
    /// Stopping a task ends it (and the preview server's writes); other
    /// control requests get no reply.
    private static func replyLoop(sid: String) -> String {
        var body = streamText("Good call. I checked every caller and none of them read the old field directly, so the change is safe as it stands.", messageId: "msg_f_\(sid)", sid: sid)
        body.append(emit(["type": "result", "subtype": "success", "session_id": sid, "is_error": false, "duration_ms": 4_200, "num_turns": 1, "result": "ok",
                          "total_cost_usd": 0.021, "usage": ["input_tokens": 2, "output_tokens": 88, "cache_read_input_tokens": 52_000, "cache_creation_input_tokens": 400]]))
        let folder = shellQuote(BackgroundDemo(sid: sid).folder)
        let stop = #"""
              _tid=$(printf '%s' "$_line" | sed -n 's/.*"task_id":"\([^"]*\)".*/\1/p')
              case "$_tid" in b_demo_server_*) kill "$(cat \#(folder)/server.pid 2>/dev/null)" 2>/dev/null ;; esac
              printf '%s\n' "{\"type\":\"system\",\"subtype\":\"task_updated\",\"task_id\":\"$_tid\",\"patch\":{\"status\":\"killed\"}}"
              printf '%s\n' "{\"type\":\"system\",\"subtype\":\"task_notification\",\"task_id\":\"$_tid\",\"status\":\"stopped\",\"summary\":\"Stopped from Abstract\"}"
        """#
        return "while read -r _line; do\n  case \"$_line\" in\n    *'\"subtype\":\"stop_task\"'*)\n" + stop + "\n      ;;\n    *'\"control_request\"'*) ;;\n    *)\n"
            + body.joined(separator: "\n") + "\n      ;;\n  esac\ndone"
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
            let search = "/bin/zsh -lc \"rg -n \\\"hero\\\" src\""
            s.append(emit(["type": "item.started", "item": ["id": "item_1", "type": "command_execution", "command": search, "aggregated_output": "", "exit_code": NSNull(), "status": "in_progress"]]))
            s.append(pause(0.7))
            s.append(emit(["type": "item.completed", "item": ["id": "item_1", "type": "command_execution", "command": search, "aggregated_output": "src/pages/Hero.tsx:4:export function Hero() {\nsrc/pages/Hero.tsx:8:  <img src={cover} />", "exit_code": 0, "status": "completed"]]))
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
