import Foundation

/// Made-up chats for timing the app on a realistic profile (ABS-159,
/// ABS-184): many projects and chats, long logs, agents streaming. Claude's
/// stream-json shapes, with nothing from a real profile in them.
public enum SyntheticChats {
    /// `projects` projects and `chats` chats spread over them, one in seven
    /// working, as ABS-159's sidebar benchmark profile.
    public static func profile(projects: Int = 50, chats: Int = 1000, root: String = "/tmp/abstract-bench",
                               now: Date = Date()) -> (projects: [Project], sessions: [Session]) {
        let projects = (0..<projects).map { i in
            Project(name: "proj-\(i)", rootPath: "\(root)/proj-\(i)", sortOrder: i)
        }
        let sessions = (0..<chats).map { i in
            var s = Session(id: "bench-\(i)", projectId: projects[i % projects.count].id, name: "Fix oauth callback \(i)",
                            providerId: "claude", branch: "abstract/oauth-\(i)", status: i % 7 == 0 ? .running : .idle,
                            createdAt: now.addingTimeInterval(-86_400), lastEventAt: now.addingTimeInterval(TimeInterval(-i * 60)))
            if i % 97 == 0 { s.pinnedAt = now.addingTimeInterval(TimeInterval(-i)) }
            return s
        }
        return (projects, sessions)
    }

    /// A chat's log of about `lines` lines: whole turns of a message, a reply,
    /// a tool call and its result, a closing reply and the turn's result.
    public static func log(lines: Int, start: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> [OutputLine] {
        var out: [OutputLine] = []
        out.reserveCapacity(lines + 8)
        var turn = 0
        while out.count < lines {
            out += self.turn(turn, at: start.addingTimeInterval(TimeInterval(turn * 30)))
            turn += 1
        }
        return out
    }

    /// One whole turn, numbered `n`.
    public static func turn(_ n: Int, at date: Date) -> [OutputLine] {
        let message = "msg_\(n)"
        let tool = "toolu_\(n)"
        let reply = "Looking at the callback handler for case \(n). The token is refreshed before the state is checked, "
            + "so a stale state can slip through.\n\n- Read `Sources/Auth/Callback.swift`\n- Check the state first\n- Add a test"
        return [
            OutputLine(stream: .user, line: "Fix the oauth callback, case \(n).", at: date),
            stdout(["type": "stream_event", "event": ["type": "message_start", "message": ["id": message]]], at: date),
            stdout(assistant(message, [["type": "text", "text": reply]]), at: date),
            stdout(assistant(message, [["type": "tool_use", "id": tool, "name": "Read",
                                        "input": ["file_path": "Sources/Auth/Callback\(n % 40).swift"]]]), at: date),
            stdout(["type": "user", "message": ["role": "user", "content": [
                ["tool_use_id": tool, "type": "tool_result", "content": String(repeating: "let state = request.state\n", count: 12)],
            ]]], at: date),
            stdout(assistant(message + "b", [["type": "text", "text": "Fixed: the state is checked before the token refresh, with a test for case \(n)."]]),
                   at: date),
            stdout(["type": "result", "subtype": "success", "is_error": false, "duration_ms": 4000, "num_turns": 1,
                    "total_cost_usd": 0.01, "session_id": "bench", "usage": ["input_tokens": 10, "output_tokens": 50]], at: date),
        ]
    }

    /// What a streaming agent prints in one beat: a fresh message on beat 0
    /// of every 40, otherwise a few words of its reply.
    public static func streamingBeat(_ beat: Int, at date: Date = Date()) -> OutputLine {
        if beat % 40 == 0 {
            return stdout(["type": "stream_event", "event": ["type": "message_start", "message": ["id": "live_\(beat / 40)"]]], at: date)
        }
        return stdout(["type": "stream_event", "event": ["type": "content_block_delta", "index": 0,
                                                         "delta": ["type": "text_delta", "text": "word \(beat) "]]], at: date)
    }

    private static func assistant(_ id: String, _ content: [[String: Any]]) -> [String: Any] {
        ["type": "assistant", "message": ["id": id, "type": "message", "role": "assistant", "content": content]]
    }

    private static func stdout(_ object: [String: Any], at date: Date? = nil) -> OutputLine {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return OutputLine(stream: .stdout, line: String(decoding: data, as: UTF8.self), at: date)
    }
}
