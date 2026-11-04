// A sample third-party agent plugin (ABS-185), adapted from Paseo's
// plugin-examples/provider-direct (github.com/getpaseo/paseo, Apache-2.0):
// a provider implemented directly against the boundary, with a catalog,
// capability negotiation, persistence and replay. In Abstract the host runs
// the program and the script reads what it prints, so its program is `echo`
// and each turn's reply is the line echo prints back.
"use strict";

const SUPPORTED = ["prompt.message", "session.persistence", "naming"];

AbstractAgent.register({
  id: "direct-example",

  catalog() {
    return { models: [{ id: "example-1", label: "Example 1", efforts: [] }], versions: [] };
  },

  // One turn: echo prints a reply line, with the session it belongs to.
  launch(ctx, resumeId) {
    const session = resumeId || "example:" + AbstractAgent.uuid();
    const turn = resumeId ? "resumed" : "first";
    return { args: [JSON.stringify({ type: "reply", session, turn, model: ctx.model || "example-1", text: "Echo: " + ctx.prompt })] };
  },

  parser() {
    let session = null;
    return {
      feed(lines) {
        return lines.map(({ line, stream }) => {
          let reply;
          try { reply = JSON.parse(line); } catch (e) { reply = null; }
          if (stream !== "stdout" || !reply || reply.type !== "reply") return [{ type: "raw", line, stream }];
          const events = [];
          if (reply.session !== session) {
            session = reply.session;
            events.push({ type: "sessionId", id: session });
          }
          events.push({ type: "system", model: reply.model, sessionId: session });
          events.push({ type: "text", role: "assistant", text: reply.text, blockId: "assistant-" + reply.turn, partial: false });
          events.push({ type: "turnEnd", usage: { inputTokens: 0, outputTokens: 0, cacheRead: 0, cacheWrite: 0 } });
          return events;
        });
      },
      exit(code) {
        return code === 0 ? [{ type: "status", status: "finished" }]
          : [{ type: "error", message: "echo exited with code " + code }, { type: "status", status: "errored" }];
      },
    };
  },

  naming: {
    launch({ prompt, home }) { return { args: ["Example name"], cwd: home }; },
    answer(output) { return output.trim() || null; },
  },

  // For tests: Paseo's negotiation, as the host does it.
  supported: SUPPORTED,
});
