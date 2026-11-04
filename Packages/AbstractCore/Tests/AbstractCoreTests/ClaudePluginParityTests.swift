import Foundation
import Testing
@testable import AbstractCore

/// Claude Code's agent plugin (ABS-185) against the Swift `ClaudeProvider`
/// it replaces: every fixture line folds to the same events, and every
/// launch, stdin line, model catalogue, setting and naming call matches.
/// Serialized: launches with a chat folder write the same file on both sides.
@Suite(.serialized) struct ClaudePluginParityTests {
    let swift = ClaudeProvider()

    static func plugin() throws -> ScriptedProvider {
        try #require(AgentPlugins.shared.anyAgent("claude"))
    }

    /// A real picture on disk, which both sides send as base64.
    static let picture: String = {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("abstract-claude-parity-\(getpid()).png").path
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!
        FileManager.default.createFile(atPath: path, contents: png)
        return path
    }()

    static let fixtures = ["claude-background", "claude-bash-edit-diff", "claude-compact", "claude-git-operations",
                           "claude-limits", "claude-plan", "claude-stream"]

    static func lines(_ name: String) throws -> [String] {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    static func json(_ text: String) -> String { JSONValue.string(text).compact() }

    /// Lines no parser should trip on, and the corners of every frame.
    static let oddLines: [String] = [
        "", "   ", " \t\u{85}", "not json", "[]", "42", "null", "\"text\"", "{}", #"{"type":7}"#, #"{"type":"mystery"}"#,
        #"{"type":"tool_progress"}"#, #"{"type":"tool_progress","elapsed":3}"#,
        // System frames.
        #"{"type":"system"}"#, #"{"type":"system","subtype":"hook_started"}"#, #"{"type":"system","subtype":7}"#,
        #"{"type":"system","subtype":"init"}"#,
        #"{"type":"system","subtype":"init","session_id":"s1","model":"opus","cwd":"/w","permissionMode":"default","skills":["sk","x",1],"terminal_slash_commands":["term","t́"],"slash_commands":["a","term","sk","a","é","é",7,"t́"]}"#,
        #"{"type":"system","subtype":"init","session_id":7,"model":null,"slash_commands":"nope"}"#,
        #"{"type":"system","subtype":"init","session_id":"s2","slash_commands":["term"],"terminal_slash_commands":["term"]}"#,
        #"{"type":"system","subtype":"commands_changed","commands":[{"name":"x","description":"","argumentHint":""},{"name":"y","description":"Does y","argumentHint":"<n>"},{"description":"no name"},7,{"name":"sk"},{"name":"x"}]}"#,
        #"{"type":"system","subtype":"commands_changed","commands":[]}"#,
        #"{"type":"system","subtype":"commands_changed"}"#,
        #"{"type":"system","subtype":"post_turn_summary"}"#,
        #"{"type":"system","subtype":"post_turn_summary","status_detail":"Done","needs_action":""}"#,
        #"{"type":"system","subtype":"post_turn_summary","status_detail":7,"needs_action":"Review the diff"}"#,
        #"{"type":"system","subtype":"task_started","task_id":"t1","task_type":"local_agent","description":"Look","tool_use_id":"tu1","subagent_type":"general","prompt":"p","is_backgrounded":true,"owned_by_subagent":1}"#,
        #"{"type":"system","subtype":"task_started","task_id":"t2","task_type":"remote_agent"}"#,
        #"{"type":"system","subtype":"task_started","task_id":"t3","task_type":"local_bash","description":7}"#,
        #"{"type":"system","subtype":"task_started","task_id":"t4","task_type":"other","is_backgrounded":"yes"}"#,
        #"{"type":"system","subtype":"task_started","task_id":""}"#, #"{"type":"system","subtype":"task_started"}"#,
        #"{"type":"system","subtype":"task_progress","task_id":"t1","summary":"","description":"Reading","last_tool_name":"","usage":{}}"#,
        #"{"type":"system","subtype":"task_progress","task_id":"t1","summary":"Sum","usage":{"total_tokens":1900.7,"tool_uses":"3","duration_ms":-2.5}}"#,
        #"{"type":"system","subtype":"task_progress","task_id":"t1","usage":null,"last_tool_name":"Bash"}"#,
        #"{"type":"system","subtype":"task_updated","task_id":"t1","patch":null}"#,
        #"{"type":"system","subtype":"task_updated","task_id":"t1","patch":{"status":"killed","is_backgrounded":false,"error":""}}"#,
        #"{"type":"system","subtype":"task_updated","task_id":"t1","patch":{"status":"pending","error":"boom","is_backgrounded":1}}"#,
        #"{"type":"system","subtype":"task_updated","task_id":"t1","patch":{"status":"weird"}}"#,
        #"{"type":"system","subtype":"task_notification","task_id":"t1","status":"odd","summary":"","output_file":"/tmp/o"}"#,
        #"{"type":"system","subtype":"task_notification","task_id":"t2","status":"failed","usage":{"tool_uses":2}}"#,
        #"{"type":"system","subtype":"task_notification","task_id":"t3","status":"stopped"}"#,
        #"{"type":"system","subtype":"task_notification","task_id":"t4"}"#,
        #"{"type":"system","subtype":"status","status":"compacting"}"#, #"{"type":"system","subtype":"status","status":7}"#,
        #"{"type":"system","subtype":"status"}"#,
        #"{"type":"system","subtype":"compact_boundary","compact_metadata":{"trigger":"auto","pre_tokens":1000.9,"post_tokens":"12","duration_ms":1e300}}"#,
        #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"This session is being continued.\n\nSummary:\n  Kept.  "}]},"isSynthetic":true}"#,
        #"{"type":"system","subtype":"compact_boundary","compact_metadata":{"trigger":"other"}}"#,
        #"{"type":"user","message":{"role":"user","content":"   "},"isSynthetic":true}"#,
        #"{"type":"system","subtype":"compact_boundary"}"#,
        #"{"type":"user","message":{"role":"user","content":"Not synthetic"},"isSynthetic":1}"#,
        #"{"type":"result","subtype":"success","usage":null}"#,
        #"{"type":"system","subtype":"compact_boundary","compact_metadata":{"trigger":"manual","pre_tokens":5}}"#,
        #"{"type":"user","parent_tool_use_id":"agent-1","message":{"role":"user","content":"This session is being continued with no summary"},"isSynthetic":true}"#,
        #"{"type":"system","subtype":"api_retry","attempt":"1"}"#,
        #"{"type":"system","subtype":"api_retry","attempt":2.7,"max_retries":null,"error_status":529}"#,
        #"{"type":"system","subtype":"api_retry","attempt":-1,"max_retries":10,"error_status":null}"#,
        #"{"type":"system","subtype":"api_retry","attempt":1e19}"#,
        // Rate limits.
        #"{"type":"rate_limit_event"}"#, #"{"type":"rate_limit_event","rate_limit_info":null}"#,
        #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1790000000}}"#,
        #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed_warning","resetsAt":1790000000,"rateLimitType":"five_hour"}}"#,
        #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed_warning","resetsAt":1790000000,"rateLimitType":"five_hour"}}"#,
        #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed_warning","resetsAt":1790000000.25,"rateLimitType":"five_hour"}}"#,
        #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed_warning","resetsAt":"soon"}}"#,
        #"{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":-0}}"#,
        #"{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":0}}"#,
        #"{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","rateLimitType":"é"}}"#,
        #"{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","rateLimitType":"é"}}"#,
        #"{"type":"rate_limit_event","rate_limit_info":{"status":7}}"#,
        // Streaming.
        #"{"type":"stream_event","event":{"type":"message_start","message":{"id":"m9"}}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":"0","delta":{"type":"text_delta"}}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_start","index":1.9,"content_block":{"type":"thinking"}}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"thinking_delta","thinking":"hmm"}}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"tu-s","name":"Read"}}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"file_path\":"}}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"\"/a\",\"limit\":5,}"}}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":7,"delta":{"type":"input_json_delta","partial_json":"lost"}}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_start","index":3,"content_block":{"type":"tool_use","id":"tu-bad"}}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":3,"delta":{"type":"input_json_delta","partial_json":"{nope"}}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_start","index":4,"content_block":{"type":"text"}}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_start","index":5,"content_block":{"type":"server_tool_use"}}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":-0.5,"delta":{"type":"text_delta","text":"neg"}}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":1e20,"delta":{"type":"text_delta","text":"huge"}}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":1234567890123456789,"delta":{"type":"text_delta","text":"big"}}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":null}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta"}}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_stop","index":0}}"#,
        #"{"type":"stream_event","event":{"type":"message_delta"}}"#, #"{"type":"stream_event","event":{"type":"message_stop"}}"#,
        #"{"type":"stream_event","event":{"type":"ping"}}"#, #"{"type":"stream_event","event":{}}"#,
        #"{"type":"stream_event","event":null}"#, #"{"type":"stream_event"}"#,
        #"{"type":"stream_event","parent_tool_use_id":"agent-1","event":{"type":"message_start","message":{"id":"sub"}}}"#,
        #"{"type":"stream_event","parent_tool_use_id":"","event":{"type":"ping"}}"#,
        // Whole messages.
        #"{"type":"assistant","message":{"id":"m9","content":[{"type":"text","text":"Hello"},{"type":"tool_use","id":"tu-s","name":"Read","input":null},{"type":"tool_use","id":"tu-bad","name":"X"},{"type":"thinking","thinking":"t"},{"type":"text","text":"Second"},{"type":"text"},7]}}"#,
        #"{"type":"assistant","message":{"id":"m9","content":[{"type":"text","text":"Split frame"},{"type":"tool_use","id":"tu-none","input":{"a":[1,2.5,true,null]}}]}}"#,
        #"{"type":"assistant","message":{"content":[{"type":"text","text":"No id"},{"type":"tool_use","id":"tu-s","input":null}]}}"#,
        #"{"type":"assistant","message":{"id":"other","content":[{"type":"text","text":"Other"},{"type":"tool_use","id":"tu-s"}]}}"#,
        #"{"type":"assistant","parent_tool_use_id":"agent-1","message":{"id":"m9","content":[{"type":"text","text":"Sub"},{"type":"tool_use","id":"tu-s","input":null}]}}"#,
        #"{"type":"assistant","message":null}"#, #"{"type":"assistant","message":{"content":"text"}}"#, #"{"type":"assistant"}"#,
        #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu-s","content":[{"type":"text","text":"a"},{"type":"image","source":{"type":"base64","media_type":"image/jpeg","data":"QUJD"}},{"type":"text","text":"b"},{"text":"c"},{"type":"image","source":{"type":"base64","data":"QQ=="}},{"type":"image","source":{"type":"url","data":"QQ=="}},{"type":"image","source":{"type":"base64","data":"Q"}},{"type":"image","source":null},{"type":"image","source":{"type":"base64","data":" Q U\nJD "}}]}]}}"#,
        #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"no id","is_error":1}]}}"#,
        #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"e1","content":"Edited","is_error":false}]},"tool_use_result":{"filePath":"/w/a.swift","structuredPatch":[{"oldStart":3,"newStart":3,"lines":[" keep","-old","+new","+more","\\ No newline",7,""," tail"]},{"oldStart":"x","newStart":20.5,"lines":["-gone"," ctx","+added"]},{"lines":[]},{"oldStart":1,"lines":["+late"]}],"gitOperation":{"commit":{"sha":"abc"}}}}"#,
        #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"e2","content":"x"},{"type":"tool_result","tool_use_id":"e3","content":"y","is_error":true}]},"tool_use_result":{"file_path":"/w/b.txt","structuredPatch":[{"oldStart":1,"newStart":1,"lines":[7]}],"type":"create","content":"ignored"}}"#,
        #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"c1","content":"Created"}]},"tool_use_result":{"type":"create","filePath":"/w/new.txt","content":"one\ntwo\r\nthree\n\n"}}"#,
        #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"c2","content":"Created"}]},"tool_use_result":{"type":"create","content":""}}"#,
        #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"c3","content":"Created"}]},"tool_use_result":{"type":"create","content":7,"structuredPatch":[]}}"#,
        #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"b1","content":""}]},"tool_use_result":{"bashEditDiff":{"files":[{"filePath":"/w/é.txt","hunks":[{"oldStart":1,"newStart":1,"lines":[" a","-b","+c"]}]},{"filePath":"","hunks":[]},{"filePath":"/w/empty.txt","hunks":[{"lines":[]}]},{"hunks":[]}],"changedFiles":["/w/é.txt","/w/empty.txt","/w/other.txt",7],"moreFiles":-3}}}"#,
        #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"b2","content":""}]},"tool_use_result":{"bashEditDiff":{"skipped":true,"changedFiles":["/w/x"]}}}"#,
        #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"b3","content":""}]},"tool_use_result":{"bashEditDiff":{"unavailable":true}}}"#,
        #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"b4","content":""}]},"tool_use_result":{"bashEditDiff":{"moreFiles":2.9}}}"#,
        #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"b5","content":""}]},"tool_use_result":{"bashEditDiff":{}}}"#,
        #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"b6","content":""}]},"tool_use_result":{"bashEditDiff":{"shared":true,"files":7}}}"#,
        #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"g1","content":"ok"}]},"tool_use_result":{"gitOperation":{"commit":{"sha":"","kind":"amended"},"push":{},"pr":{"number":12,"action":"created","url":"https://github.com/a/b/pull/12"}}}}"#,
        #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"g2","content":"ok","is_error":true}]},"tool_use_result":{"gitOperation":{"push":{"branch":"main"}}}}"#,
        #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"g3","content":"ok"}]},"tool_use_result":{"gitOperation":null}}"#,
        #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"g4","content":"ok"}]},"tool_use_result":"text result"}"#,
        #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Mine"},{"type":"text"},{"type":"text","text":"[Request interrupted by user]"}]}}"#,
        #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Reminder"}]},"isMeta":true}"#,
        #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Skill text"}]},"isSynthetic":true}"#,
        #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by useŕ oops"}]}}"#,
        #"{"type":"user","parent_tool_use_id":"agent-1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"sub-1","content":"sub out"},{"type":"text","text":"sub text"}]}}"#,
        #"{"type":"user","message":null}"#, #"{"type":"user","message":{"content":"plain"}}"#,
        // Results.
        #"{"type":"result","subtype":"success","is_error":false,"duration_ms":1200.8,"num_turns":3,"total_cost_usd":0.25,"usage":{"input_tokens":10,"output_tokens":"5","cache_read_input_tokens":1e400,"cache_creation_input_tokens":-7.9}}"#,
        #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}"#,
        #"{"type":"result","subtype":"error_during_execution","is_error":true}"#,
        #"{"type":"result","subtype":"error_during_execution","is_error":true}"#,
        #"{"type":"result","is_error":true,"result":"Prompt is too long"}"#,
        #"{"type":"result","is_error":true}"#,
        #"{"type":"result","is_error":true,"terminal_reason":"aborted_streaming","total_cost_usd":"1"}"#,
        #"{"type":"result","is_error":1,"terminal_reason":"completed"}"#,
        #"{"type":"result"}"#,
        // Control.
        #"{"type":"control_request","request_id":"p1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"ls"}}}"#,
        #"{"type":"control_request","request_id":"p2","request":{"subtype":"can_use_tool","tool_name":"AskUserQuestion","input":null}}"#,
        #"{"type":"control_request","request_id":"p3","request":{"subtype":"can_use_tool"}}"#,
        #"{"type":"control_request","request_id":"p4","request":{"subtype":"hook_callback"}}"#,
        #"{"type":"control_request","request":{"subtype":"can_use_tool","tool_name":"Bash"}}"#,
        #"{"type":"control_request","request_id":"p5","request":null}"#,
        #"{"type":"control_response","response":{"subtype":"success","request_id":"r"}}"#,
        #"{"type":"control_response","response":{"subtype":"error","error":"No such task"}}"#,
        #"{"type":"control_response","response":{"subtype":"error"}}"#, #"{"type":"control_response"}"#,
        #"{"type":"prompt_suggestion","suggestion":"Run the tests"}"#, #"{"type":"prompt_suggestion","suggestion":""}"#,
        #"{"type":"prompt_suggestion","suggestion":7}"#,
        // How the line itself is read.
        #"{"type":"tool_progress",}"#, #"{"type":"prompt_suggestion","suggestion":"first","suggestion":"second"}"#,
        #"{"type":"prompt_suggestion","suggestion":"a","n":1e999}"#, #"{"type":"prompt_suggestion","suggestion":"a","n":1e-400}"#,
        #"{"type":"prompt_suggestion","suggestion":"a","n":-1e999}"#, #"{"type":"prompt_suggestion","suggestion":"a","n":4.9e-324}"#,
        #"{"type":"prompt_suggestion","suggestion":"a","n":0e-999}"#, #"{"type":"prompt_suggestion","suggestion":"\ud800"}"#,
        #"{"type":"prompt_suggestion","suggestion":"😀 é \/"}"#, #"{"type":"prompt_suggestion","suggestion":"\uD83D"}"#,
        #"{"type":"prompt_suggestion","suggestion":"x",,}"#, #"{,}"#, #"{"type":"tool_progress"}x"#, #"{"type":"tool_progress"} {}"#,
        "\u{FEFF}{\"type\":\"prompt_suggestion\",\"suggestion\":\"bom\"}", " \u{FEFF}{\"type\":\"tool_progress\"}",
        "{\"type\":\"tool_progress\"}\u{FEFF}", "\u{A0}{\"type\":\"prompt_suggestion\",\"suggestion\":\"nbsp\"}\u{2028}",
        "{\"type\":\"prompt_suggestion\",\"suggestion\":\"tab\tinside\"}", "{\"type\":\"prompt_suggestion\",\"suggestion\":\"del\u{7F}\"}",
        #"{"type":"prompt_suggestion","suggestion":"\x"}"#, #"{"type":"prompt_suggestion","suggestion":"\u00"}"#,
        #"{"type":"prompt_suggestion","suggestion":"esc \b\f\n\r\t\"\\ \u0000"}"#,
        #"{"type":"tool_progress","n":01}"#, #"{"type":"tool_progress","n":.5}"#, #"{"type":"tool_progress","n":1.}"#,
        #"{"type":"tool_progress","n":+1}"#, #"{"type":"tool_progress","n":-0}"#, #"{"type":"tool_progress","n":1E+2}"#,
        #"{"type":"tool_progress","n":tru}"#, #"{"type":"tool_progress","n":[1,]}"#, #"{"type":"tool_progress","n":[,]}"#,
        #"{'type':'tool_progress'}"#, #"{"type":"tool_progress","n":NaN}"#,
        #"{"type":"control_request","request_id":"dup","request":{"subtype":"can_use_tool","tool_name":"Edit","input":{"é":1,"é":2,"a":1,"a":2,"__proto__":{"x":1}}}}"#,
        // A stream that runs into its next message.
        #"{"type":"stream_event","event":{"type":"message_start","message":{"id":"m10"}}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"text"}}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text"}}}"#,
        #"{"type":"assistant","message":{"id":"m10","content":[{"type":"text","text":"first claimed"}]}}"#,
        #"{"type":"assistant","message":{"id":"m10","content":[{"type":"text","text":"second claimed"}]}}"#,
        #"{"type":"assistant","message":{"id":"m10","content":[{"type":"text","text":"none left"}]}}"#,
    ]

    func expectSameFold(_ lines: [String], plugin: ScriptedProvider, sourceLocation: SourceLocation = #_sourceLocation) {
        for stream in [OutputStreamKind.stdout, .stderr] {
            let a = ClaudeParser(), b = plugin.makeParser()
            for (index, line) in lines.enumerated() {
                let expected = a.feed(line, stream: stream), actual = b.feed(line, stream: stream)
                #expect(actual == expected, "line \(index + 1) on \(stream): \(line.prefix(300))", sourceLocation: sourceLocation)
            }
            for code in [Int32(0), 1, -9, nil] as [Int32?] {
                #expect(b.onExit(code: code) == a.onExit(code: code), "exit \(String(describing: code)) on \(stream)",
                        sourceLocation: sourceLocation)
            }
        }
        // A batch reads the same as line by line, and as the Swift parser.
        let one = plugin.makeParser(), many = plugin.makeParser(), reference = ClaudeParser()
        let batched = many.feed(lines: lines.map { OutputLine(stream: .stdout, line: $0) })
        #expect(batched == lines.map { one.feed($0, stream: .stdout) }, sourceLocation: sourceLocation)
        #expect(batched == lines.map { reference.feed($0, stream: .stdout) }, sourceLocation: sourceLocation)
        #expect(many.onExit(code: nil) == reference.onExit(code: nil), sourceLocation: sourceLocation)
    }

    // MARK: Folding

    @Test(arguments: fixtures)
    func fixturesFoldTheSame(_ fixture: String) throws {
        let plugin = try Self.plugin()
        let lines = try Self.lines(fixture)
        expectSameFold(lines, plugin: plugin)
        expectSameFold(lines + Self.oddLines, plugin: plugin)
        expectSameFold(Self.oddLines + lines, plugin: plugin)
    }

    @Test func oddLinesFoldTheSame() throws {
        let plugin = try Self.plugin()
        expectSameFold(Self.oddLines, plugin: plugin)
        expectSameFold(Array(Self.oddLines.reversed()), plugin: plugin)
        // Each one alone, for the state and exit it leaves.
        for line in Self.oddLines { expectSameFold([line], plugin: plugin) }
        expectSameFold([], plugin: plugin)
    }

    /// Nesting at JSONDecoder's limit, on a thread with room for it.
    @Test func deepLinesFoldTheSame() throws {
        let plugin = try Self.plugin()
        let lines = [509, 510, 511, 512].map { depth in
            #"{"type":"control_request","request_id":"deep","request":{"subtype":"can_use_tool","tool_name":"Edit","input":"#
                + String(repeating: "[", count: depth) + String(repeating: "]", count: depth) + "}}"
        }
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            for line in lines { expectSameFold([line], plugin: plugin) }
            done.signal()
        }
        thread.stackSize = 64 << 20
        thread.start()
        done.wait()
    }

    @Test func everyFixtureLineAloneFoldsTheSame() throws {
        let plugin = try Self.plugin()
        for fixture in Self.fixtures {
            for line in try Self.lines(fixture) { expectSameFold([line], plugin: plugin) }
        }
    }

    /// Image data as Foundation reads it, ignoring what isn't base64: every
    /// string of up to five of these characters.
    @Test func toolImagesDecodeTheSame() throws {
        let plugin = try Self.plugin()
        let alphabet = ["Q", "R", "=", "!", "\u{e9}", "\n"]
        var strings = [""]
        var level = [""]
        for _ in 1...5 {
            level = level.flatMap { prefix in alphabet.map { prefix + $0 } }
            strings += level
        }
        strings += ["aGVsbG8=", "aGVsbG8", "aGVsbG8==", "aGVsbG9=", "QUJD====", "QUJD====QUJD", "QQ==QQ==", "-_", "\u{1F600}",
                    "\u{20AC}!", "\u{0}\u{0}\u{0}\u{0}", "QUJ\u{0}D", "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="]
        let lines = strings.map { data in
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"img","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"#
                + Self.json(data) + "}}]}]}}"
        }
        let a = ClaudeParser(), b = plugin.makeParser()
        let actual = b.feed(lines: lines.map { OutputLine(stream: .stdout, line: $0) })
        var mismatches = 0
        for (index, line) in lines.enumerated() {
            let expected = a.feed(line, stream: .stdout)
            if actual[index] != expected {
                mismatches += 1
                if mismatches <= 10 { Issue.record("image data \(strings[index].debugDescription)") }
            }
        }
        #expect(mismatches == 0)
    }

    // MARK: Launching

    static let configDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("abstract-claude-parity-config-\(getpid())").path

    static let toolServers: [MCPServerLaunch] = [
        MCPServerLaunch(name: "linear", connection: .url("https://mcp.linear.app/mcp", headers: ["Authorization": "Bearer x", "X-Other": "\"q\""]),
                        allowed: ["list_issues", "get issue"], askFirst: ["create_issue", "x,Bash"], off: ["delete_issue"],
                        notes: "  Use the team key ABS.  "),
        MCPServerLaunch(name: "files server", connection: .command(["npx", "-y", "@mcp/files", "/tmp/a b"], env: ["TOKEN": "t", "PATH": "/bin"]),
                        allowsEverything: true, notes: "   "),
        MCPServerLaunch(name: "bare", connection: .command([], env: [:]), allowed: ["e\u{301}t\u{e9}"], off: ["\u{1F600}", "a-b_c"]),
        MCPServerLaunch(name: "abstract-code-history", connection: .url("http://127.0.0.1:1/x", headers: [:]), allowsEverything: true),
    ]

    static func contexts(_ policy: PermissionPolicy) -> [LaunchContext] {
        [
            LaunchContext(cwd: "/tmp/clean-worktree", prompt: "Say hello.", permissionPolicy: policy),
            LaunchContext(cwd: "/tmp/w t", prompt: "-starts with a dash \"quoted\" / \u{1}\u{1F}\u{7F} \u{2028} \u{1F600}\n",
                          permissionPolicy: policy, extraArgs: ["--verbose", "x y"], binaryOverride: "  /opt/claude  ",
                          model: " opus[1m] ", effort: "high", outputStyle: .concise,
                          images: [Self.picture, "/nonexistent/abstract-claude-parity.png", "/tmp/not-an-image.txt"],
                          readableDirs: ["/tmp/attachments", "/tmp/a b"],
                          historyTool: HistoryToolLaunch(command: "/Applications/Abstract.app/abstract", chatId: "chat-1", instructionFile: "/tmp/i.md"),
                          branchTool: BranchToolLaunch(command: "/usr/local/bin/abstract", chatId: "chat-1"),
                          instructions: "Be a pirate.\nAlways.", pluginTools: PluginToolsLaunch(command: "/usr/local/bin/abstract", chatId: "chat-1"),
                          toolServers: Self.toolServers, configDirectory: Self.configDirectory, skills: SkillsLaunch(folder: "/tmp/skills home")),
            LaunchContext(cwd: "/tmp/clean-worktree", prompt: "Plan this", permissionPolicy: policy, binaryOverride: "   ",
                          model: "  ", effort: "  ", outputStyle: .explanatory, instructions: "  \n ",
                          toolServers: [Self.toolServers[0].withoutAskFirst, Self.toolServers[1]]),
            LaunchContext(cwd: "/tmp/clean-worktree", prompt: "", permissionPolicy: policy, outputStyle: .default,
                          historyTool: HistoryToolLaunch(command: "abstract", chatId: "c2"), toolServers: [Self.toolServers[0]],
                          configDirectory: "/nonexistent/abstract-claude-parity/config"),
            LaunchContext(cwd: "/tmp/clean-worktree", prompt: "Styles", permissionPolicy: policy, outputStyle: .learning,
                          toolServers: [Self.toolServers[2]]),
            LaunchContext(cwd: "/tmp/clean-worktree", prompt: "Proactive", permissionPolicy: policy, outputStyle: .proactive,
                          images: [Self.picture, Self.picture], pluginTools: PluginToolsLaunch(command: "abstract", chatId: "c3")),
        ]
    }

    func expectSameSpec(_ a: LaunchSpec, _ b: LaunchSpec, _ note: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(b.command == a.command, "\(note) command", sourceLocation: sourceLocation)
        #expect(b.args == a.args, "\(note) args", sourceLocation: sourceLocation)
        #expect(b.cwd == a.cwd, "\(note) cwd", sourceLocation: sourceLocation)
        #expect(b.env == a.env, "\(note) env", sourceLocation: sourceLocation)
        #expect(b.keepStdinOpen == a.keepStdinOpen, "\(note) keepStdinOpen", sourceLocation: sourceLocation)
        #expect(b.stdinInitial == a.stdinInitial, "\(note) stdin", sourceLocation: sourceLocation)
    }

    /// The MCP config each side wrote to the chat's folder, removed after.
    func takeConfigFile() -> String? {
        let path = Self.configDirectory + "/claude-mcp.json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    @Test(arguments: PermissionPolicy.allCases)
    func launchesTheSame(_ policy: PermissionPolicy) throws {
        let plugin = try Self.plugin()
        for (index, ctx) in Self.contexts(policy).enumerated() {
            let a = swift.buildLaunch(ctx)
            let fileA = takeConfigFile()
            let b = plugin.buildLaunch(ctx)
            let fileB = takeConfigFile()
            expectSameSpec(a, b, "launch \(index) \(policy)")
            #expect(fileB == fileA, "launch \(index) \(policy) config file")
            #expect((fileA != nil) == (ctx.configDirectory == Self.configDirectory && !ctx.mcpServers.isEmpty))

            let resumeA = swift.buildResume(ctx, resumeId: "session-\(index)")
            _ = takeConfigFile()
            let resumeB = plugin.buildResume(ctx, resumeId: "session-\(index)")
            _ = takeConfigFile()
            expectSameSpec(resumeA, resumeB, "resume \(index) \(policy)")
        }
        #expect(plugin.permissionDetail(policy) == swift.permissionDetail(policy))
        for requestId in ["r", "mode-1", "q\"uote\\d\n\u{1F600}"] {
            #expect(plugin.buildPermissionModeChange(policy, requestId: requestId) == swift.buildPermissionModeChange(policy, requestId: requestId))
        }
    }

    @Test func describesTheSameAgent() throws {
        let plugin = try Self.plugin()
        #expect(plugin.id == swift.id)
        #expect(plugin.name == swift.name)
        #expect(plugin.logoAsset == swift.logoAsset)
        #expect(plugin.binary == swift.binary)
        #expect(plugin.detectArgs == swift.detectArgs)
        #expect(plugin.followUpMode == swift.followUpMode)
        #expect(plugin.skillDelivery == swift.skillDelivery)
        #expect(plugin.toolServerSupport == swift.toolServerSupport)
        #expect(plugin.commands == swift.commands)
        guard case .inStream(let a) = swift.compaction, case .inStream(let b) = plugin.compaction else {
            Issue.record("both compact in the stream")
            return
        }
        #expect(a == b)
        #expect(plugin.fallbackModels == swift.fallbackModels)
        #expect(plugin.configuredDefaultEffort(home: "/nonexistent") == swift.configuredDefaultEffort(home: "/nonexistent"))
        for capability in ["prompt.message", "prompt.image", "prompt.steer", "permission", "permission.mode", "task.stop",
                           "interrupt", "task.background", "session.persistence", "naming", "models.discover"] {
            #expect(plugin.can(capability), "\(capability)")
        }
        #expect(!plugin.can("compaction") && !plugin.can("lines.enrich"))
        #expect(plugin.makeLineEnricher(executor: LocalExecutor.shared, cwd: "/tmp") == nil)
    }

    // MARK: Answers on stdin

    @Test func stdinLinesAreTheSame() throws {
        let plugin = try Self.plugin()
        let texts = ["Again.", "", "-dash \"quoted\" / \u{e9} \u{1}\u{8}\u{C}\u{1B}\u{1F} \u{7F} \u{2028}\u{2029} \u{1F600}\n\r\t\\"]
        let imageSets: [[String]] = [[], [Self.picture], ["/nonexistent/a.png", "/tmp/x.txt", Self.picture, "/tmp/missing.JPG"]]
        for text in texts {
            #expect(plugin.buildUserMessage(text) == swift.buildUserMessage(text))
            for images in imageSets {
                #expect(plugin.buildUserMessage(text, images: images) == swift.buildUserMessage(text, images: images), "\(text) \(images)")
                #expect(plugin.buildUserMessage(text, images: images, sessionId: "s") == swift.buildUserMessage(text, images: images, sessionId: "s"))
            }
        }
        for requestId in ["r", "", "q\"uote\\d\n\u{1}\u{1F600}"] {
            #expect(plugin.buildStopTask("t1", requestId: requestId) == swift.buildStopTask("t1", requestId: requestId))
            #expect(plugin.buildStopTask("t\"2\n", requestId: requestId) == swift.buildStopTask("t\"2\n", requestId: requestId))
            #expect(plugin.buildInterrupt(requestId: requestId) == swift.buildInterrupt(requestId: requestId))
            for toolUseId in [nil, "toolu_9", "", "q\"\u{1}"] as [String?] {
                #expect(plugin.buildBackground(toolUseId: toolUseId, requestId: requestId)
                        == swift.buildBackground(toolUseId: toolUseId, requestId: requestId))
            }
        }
    }

    @Test func permissionAnswersAreTheSame() throws {
        let plugin = try Self.plugin()
        let question = try #require(JSONValue.parse(#"{"questions":[{"question":"Which?","header":"H","options":[{"label":"A"},{"label":"B"}],"multiSelect":false}]}"#))
        let inputs: [JSONValue?] = [
            nil, .null, .object([:]), .array([]), .string("x"), .number(1.5), .bool(true),
            JSONValue.parse(#"{"command":"ls -la","n":1.5,"big":1e300,"neg":-3,"nested":{"b":[true,null,"é/"]},"z":{},"a":[]}"#),
            AgentQuestion.answeredInput(question, answers: ["Which?": "A"]),
            .object(["e\u{301}": .string("x"), "\u{1F600}": .number(0), "slash/key": .string("a/b")]),
        ]
        for (index, input) in inputs.enumerated() {
            for allow in [true, false] {
                for requestId in ["q-1", "q\"\n\u{1}"] {
                    #expect(plugin.buildPermissionResponse(requestId: requestId, allow: allow, input: input)
                            == swift.buildPermissionResponse(requestId: requestId, allow: allow, input: input), "input \(index) \(allow)")
                }
            }
        }
    }

    // MARK: Models and settings

    static let models = #"[{"value":"default","resolvedModel":"claude-opus-5-5[1m]","displayName":"Default (recommended)","description":"Opus 5.5 with 1M context","supportsEffort":true,"supportedEffortLevels":["low","medium","high","xhigh","max"]},{"value":"opus[1m]","resolvedModel":"claude-opus-5-5[1m]","displayName":"Opus (1M context)","supportsEffort":true,"supportedEffortLevels":["low","medium","high","xhigh","max"]},{"value":"claude-fable-5-1[1m]","resolvedModel":"claude-fable-5-1","displayName":"Fable","supportsEffort":true,"supportedEffortLevels":["low","medium","high"]},{"value":"sonnet","resolvedModel":"claude-sonnet-5","displayName":"Sonnet","description":"Sonnet 5","supportsEffort":true,"supportedEffortLevels":["low","medium","high","xhigh","max"]},{"value":"haiku","resolvedModel":"claude-haiku-4-5-20251001","displayName":"Haiku"}]"#

    static func initializeResponse(requestId: String, subtype: String = "success", models: String = models) -> String {
        #"{"type":"control_response","response":{"subtype":""# + subtype + #"","request_id":""# + requestId
            + #"","response":{"commands":[],"models":"# + models + #","pid":1}}}"#
    }

    @Test func modelCataloguesAreTheSame() throws {
        let plugin = try Self.plugin()
        let oddModels = [
            "[]", "{}", "7", "null",
            #"[{"value":""},{"value":7},{"value":"x","supportsEffort":1,"supportedEffortLevels":["a"]},{"value":"y","supportsEffort":true,"supportedEffortLevels":["a",1,null]},{"value":"z","supportsEffort":true}]"#,
            #"[{"value":"default"},{"value":"default","resolvedModel":"claude-sonnet-5"}]"#,
            #"[{"value":"claude-opus-5-5","resolvedModel":"claude-opus-5-5[1m]","supportsEffort":true,"supportedEffortLevels":["max"]},{"value":"claude-sonnet-5","displayName":null}]"#,
            #"[{"value":"custom","resolvedModel":"custom-model-9","supportsEffort":true,"supportedEffortLevels":["low"]},{"value":"other","resolvedModel":"claude-haiku-4-5-20251001"},{"value":"third","resolvedModel":"claude-mystery-1"}]"#,
            #"[{"value":"opus","resolvedModel":"claude-opus-5-5","supportsEffort":true,"supportedEffortLevels":["high"]},{"value":"opus","resolvedModel":"claude-opus-5-5"},{"value":"claude-é-1","resolvedModel":"claude-é-1"}]"#,
            #"[{"value":"99","resolvedModel":"5-6"},{"value":"claude-1-2","supportsEffort":true,"supportedEffortLevels":["low"]}]"#,
            #"[7,null,"x",{"value":"haiku"}]"#,
        ]
        var lines = [Self.initializeResponse(requestId: "r1"), Self.initializeResponse(requestId: "r1", subtype: "error"),
                     Self.initializeResponse(requestId: "other"), Self.initializeResponse(requestId: "r1", models: "[]"),
                     #"{"type":"control_response","response":{"subtype":"error","request_id":"r1","error":"nope"}}"#,
                     #"{"type":"control_response","response":null}"#, #"{"type":"control_response"}"#,
                     #"{"type":"control_response","response":{"request_id":7,"response":{"models":[{"value":"x"}]}}}"#,
                     #"{"type":"system","subtype":"hook_started"}"#, "not json", "", "[]",
                     Self.initializeResponse(requestId: "r1").replacingOccurrences(of: #""pid":1"#, with: #""pid":1e999"#),
                     Self.initializeResponse(requestId: "r1").replacingOccurrences(of: #""pid":1}"#, with: #""pid":1,}"#)]
        lines += oddModels.map { Self.initializeResponse(requestId: "r1", models: $0) }
        for line in lines {
            for requestId in ["r1", nil] as [String?] {
                let expected = ClaudeProvider.modelCatalog(initializeResponse: line, requestId: requestId)
                let answer = plugin.script.evaluate("ClaudeAgent.modelCatalog(\(Self.json(line)), \(requestId.map(Self.json) ?? "null"))")
                let actual = answer.flatMap { AgentEventJSON.decodeCodable(ModelCatalog.self, $0) }
                #expect(actual == expected, "\(line) \(String(describing: requestId))")
                #expect((answer == nil) == (expected == nil), "\(line)")
            }
        }
        #expect(plugin.script.evaluate("ClaudeAgent.pinnedVersions")?.array?.compactMap(\.string) == ClaudeProvider.pinnedVersions)
        #expect(plugin.script.evaluate("ClaudeAgent.effortLevels")?.array?.compactMap(\.string) == ClaudeProvider.effortLevels)
        #expect(plugin.script.evaluate("ClaudeAgent.initializeRequest('abc')")?.string == ClaudeProvider.initializeRequest(id: "abc"))
    }

    @Test func displayNamesAreTheSame() throws {
        let plugin = try Self.plugin()
        let ids = ["claude-opus-5-5[1m]", "claude-haiku-4-5-20251001", "claude-sonnet-5", "claude-fable-5-1", "claude-3-5-sonnet-20241022",
                   "opus[1m]", "sonnet", "my-custom-model", "", "-", "--", "claude", "claude-", "claude--opus--5", "claude-5", "claude-5-6",
                   "opus-5", "claude-x-+5-007-123", "claude-opus-+05", "claude-opus-99999999999999999999", "claude-\u{e9}-5",
                   "claude-e\u{301}-1", "\u{df}eta", "\u{1F600}", "claude-\u{1F468}\u{200D}\u{1F469}-2", "[1m]", "claude-opus[1m][1m]",
                   "claude-opus-5[1m]\u{301}", "claude\u{301}-opus", "-\u{301}opus", "claude-\u{1E9E}x", "claude-\u{149}x", "claude-\u{1F0}-1",
                   "CLAUDE-opus", "claude-opus-5-5[1M]", "claude-opus-5\r\n-x", "1-2-3", "claude-1-2", "x"]
        for id in ids {
            #expect(plugin.script.evaluate("ClaudeAgent.displayName(\(Self.json(id)))")?.string == ClaudeProvider.displayName(id), "\(id.debugDescription)")
        }
        for text in ["This session is being continued from a previous conversation.\n\nSummary:\nDid X.\n", "Plain summary  ", "   ",
                     "This session is being continued", "This session is being continued\u{301} Summary:\nx", "Summary:\nnot continued",
                     "This session is being continued.\nSummary:\r\nCRLF", "This session is being continued Summary:\n\u{85}  \n"] {
            let expected = ClaudeParser.compactSummary(text)
            #expect(plugin.script.evaluate("ClaudeAgent.compactSummary(\(Self.json(text)))")?.string == expected, "\(text.debugDescription)")
        }
    }

    @Test func readsTheSameConfiguredModel() throws {
        let plugin = try Self.plugin()
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("claude-parity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent(".claude/settings.json")
        for contents in [#"{"model":"opus[1m]"}"#, #"{"model":7}"#, #"{"model":null}"#, "{}", "not json", "", "[]", "\"model\"",
                         #"{"model":"a","model":"b"}"#, #"{"model":"x",}"#, #"{"model":"x","n":1e999}"#, #"{"model":"x","n":1e-400}"#,
                         "\u{FEFF}{\"model\":\"bom\"}", #"{"model":"\ud800"}"#, #"{"model":"sonnet","effortLevel":"high","permissions":{"allow":[]}}"#,
                         " \n{\"model\" : \"spaced\"}\n\n", "{\"model\":\"x\"}\u{A0}"] {
            try contents.write(to: file, atomically: true, encoding: .utf8)
            #expect(plugin.configuredDefaultModel(home: home.path) == swift.configuredDefaultModel(home: home.path), "\(contents)")
            #expect(plugin.configuredDefaultEffort(home: home.path) == swift.configuredDefaultEffort(home: home.path))
        }
        #expect(plugin.configuredDefaultModel(home: home.path + "/missing") == swift.configuredDefaultModel(home: home.path + "/missing"))
    }

    @Test func discoversTheSameModels() async throws {
        let plugin = try Self.plugin()
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("claude-parity-models-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        let script = home + "/claude"
        // Reads the request, echoes the id back after some unrelated frames.
        let body = """
            #!/bin/sh
            read -r line
            id=$(printf '%s' "$line" | sed -E 's/.*"request_id":"([^"]+)".*/\\1/')
            echo '{"type":"system","subtype":"hook_started"}'
            echo 'plain noise'
            printf '%s\\n' '\(Self.initializeResponse(requestId: "ID"))' | sed "s/\\"request_id\\":\\"ID\\"/\\"request_id\\":\\"$id\\"/"
            sleep 60
            """
        try body.write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        let executor = ClaudeParityHomeExecutor(homeDirectory: home)
        _ = await LocalExecutor.shared.searchPath
        let expected = await swift.discoverModels(executor: executor, binary: script)
        #expect(expected != nil)
        #expect(await plugin.discoverModels(executor: executor, binary: script) == expected)
        for binary in ["/usr/bin/false", home + "/missing"] {
            #expect(await plugin.discoverModels(executor: executor, binary: binary) == nil)
            #expect(await swift.discoverModels(executor: executor, binary: binary) == nil)
        }
    }

    // MARK: Naming

    @Test func namingIsTheSame() throws {
        let plugin = try Self.plugin()
        let namings: [(String, String, String?, String?)] = [("Name this chat", "/tmp/clean-worktree", "/opt/claude", "opus"),
                                                             ("-starts with a dash\n\"q\"", "/tmp/h", nil, nil), ("", "/tmp/h", nil, "")]
        for (prompt, home, binary, model) in namings {
            let a = try #require(swift.namingLaunch(prompt: prompt, home: home, binary: binary, model: model))
            let b = try #require(plugin.namingLaunch(prompt: prompt, home: home, binary: binary, model: model))
            // Everything, the prompt on stdin included.
            #expect(b == a)
            #expect(plugin.namingCheck(home: home, binary: binary) == swift.namingCheck(home: home, binary: binary))
        }
        let outputs = [
            #"{"type":"result","subtype":"success","is_error":false,"result":"Fix the login bug","session_id":"s"}"#,
            #"{"type":"result","subtype":"error","is_error":true,"result":"Credit balance is too low"}"#,
            #"{"is_error":1,"result":"one"}"#, #"{"is_error":0,"result":"zero"}"#, #"{"is_error":1.0,"result":"float"}"#,
            #"{"is_error":2,"result":"two"}"#, #"{"is_error":"true","result":"text"}"#, #"{"is_error":null,"result":"null"}"#,
            #"{"result":7}"#, #"{"is_error":true}"#, #"{}"#, "", "no json here", "{", "{\"result\":\"unbalanced\"",
            "Warning: something\n" + #"{"result":"after noise","is_error":false}"# + "\n" + #"{"result":"second"}"#,
            #"{"result":"a } b { c","is_error":false}"#, #"{"result":"x",}"#, #"{"result":"first","result":"second"}"#,
            #"{"result":"\ud800"}"#, #"{"result":"big","n":1e999}"#, #"{"result":"negbig","n":-1e999}"#, #"{"result":"tiny","n":1e-400}"#,
            #"{"result":"esc \"q\" é \/ \n"}"#, #"{"result":"nested","x":{"y":[1,{"z":"}"}]}}"#, #"{"result":"x"} trailing"#,
            #"{"result":["array"]}"#, #"{'result':'single'}"#,
        ]
        for output in outputs {
            #expect(plugin.namingAnswer(output) == swift.namingAnswer(output), "\(output)")
            #expect(plugin.namingError(output) == swift.namingError(output), "\(output)")
            #expect(plugin.namingCheckPasses(output) == swift.namingCheckPasses(output))
        }
    }
}

private extension MCPServerLaunch {
    var withoutAskFirst: MCPServerLaunch {
        var server = self
        server.askFirst = []
        return server
    }
}

/// The real executor with another home directory.
private struct ClaudeParityHomeExecutor: Executor {
    let homeDirectory: String
    let base = LocalExecutor.shared
    func run(_ command: String, _ args: [String], cwd: String?, stdin: Data?) async throws -> ExecResult {
        try await base.run(command, args, cwd: cwd, stdin: stdin)
    }
    func spawn(_ spec: LaunchSpec, onLine: @escaping @Sendable (OutputLine) -> Void,
               onExit: @escaping @Sendable (Int32?) -> Void) throws -> RunningProcess {
        try base.spawn(spec, onLine: onLine, onExit: onExit)
    }
    func fileExists(_ path: String) -> Bool { base.fileExists(path) }
    func readFile(_ path: String) throws -> String { try base.readFile(path) }
    func createDirectory(_ path: String) throws { try base.createDirectory(path) }
    func removeItem(_ path: String) throws { try base.removeItem(path) }
    func which(_ binary: String) async -> String? { await base.which(binary) }
}
