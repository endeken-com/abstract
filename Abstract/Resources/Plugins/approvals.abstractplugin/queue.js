"use strict";

// Approvals' queue (ABS-111): every permission request and question waiting
// across your chats. Pure functions over what the host sends — the
// `getPermissions` list, `permission.requested` and `permission.resolved`
// events, and the snapshot — so the same file is tested outside the app.
//
// The list the host returns is the truth. Events only move the count
// between two pulls, and arrive in any order relative to them: a request
// that was resolved, or answered here, never comes back, and a pull sent
// before an event can't undo it.

var ApprovalsQueue = (function () {
  var ANSWERED_KEEP = 20;
  var TOMBSTONE_KEEP = 500;

  var AGENT_NAMES = {
    claude: "Claude Code",
    codex: "Codex",
    opencode: "OpenCode",
    muse: "Muse Code",
    ollama: "Codex · Ollama",
    lmstudio: "Codex · LM Studio",
  };

  function key(chatId, requestId) {
    return chatId + "\n" + requestId;
  }

  function emptyState() {
    // `sent`: the last pull asked for; `applied`: the newest one taken in.
    return { pending: {}, gone: {}, goneOrder: [], answered: [], sent: 0, applied: 0 };
  }

  function copy(state) {
    var pending = {};
    for (var k in state.pending) pending[k] = state.pending[k];
    var gone = {};
    for (var g in state.gone) gone[g] = true;
    return {
      pending: pending, gone: gone, goneOrder: state.goneOrder.slice(), answered: state.answered.slice(),
      sent: state.sent, applied: state.applied,
    };
  }

  // A request that stopped waiting stays gone: ids are never reused.
  function bury(state, k) {
    delete state.pending[k];
    if (state.gone[k]) return;
    state.gone[k] = true;
    state.goneOrder.push(k);
    while (state.goneOrder.length > TOMBSTONE_KEEP) delete state.gone[state.goneOrder.shift()];
  }

  /** Number the next pull, so a late reply to an older one is ignored. */
  function nextPull(state) {
    var next = copy(state);
    next.sent += 1;
    return { state: next, seq: next.sent };
  }

  /** One event, as a background script hears it. `now` is an ISO date. */
  function applyEvent(state, event, now) {
    if (!event || !event.chatId || !event.requestId) return state;
    var next = copy(state);
    var k = key(event.chatId, event.requestId);
    if (event.type === "permission.resolved") {
      bury(next, k);
    } else if (event.type === "permission.requested") {
      if (next.gone[k] || next.pending[k]) return state;
      next.pending[k] = {
        chatId: event.chatId,
        requestId: event.requestId,
        kind: event.kind || "permission",
        toolName: event.toolName || "",
        questions: (event.questions || []).map(function (q) { return { question: q, options: [] }; }),
        requestedAt: now || null,
        // Heard after pull `sent` went out: a reply to that pull, or an
        // older one, may not list it yet.
        heardAfter: next.sent,
      };
    }
    return next;
  }

  /** A `getPermissions` reply to pull `seq`. */
  function applyPull(state, seq, reply) {
    if (!reply || !Array.isArray(reply.requests) || seq <= state.applied) return state;
    var next = copy(state);
    next.applied = seq;
    var pending = {};
    for (var k in next.pending) {
      // Heard of after this pull was sent: keep it until a pull lists it.
      if (next.pending[k].heardAfter >= seq) pending[k] = next.pending[k];
    }
    for (var i = 0; i < reply.requests.length; i++) {
      var request = reply.requests[i];
      var rk = key(request.chatId, request.requestId);
      if (next.gone[rk]) continue;
      pending[rk] = request;
    }
    next.pending = pending;
    return next;
  }

  /** Answered here: the row says so instead of waiting. */
  function markAnswered(state, targets, note) {
    var next = copy(state);
    for (var i = 0; i < targets.length; i++) {
      var k = key(targets[i].chatId, targets[i].requestId);
      var row = next.pending[k];
      bury(next, k);
      if (row) next.answered.unshift({ row: row, note: note });
    }
    next.answered = next.answered.slice(0, ANSWERED_KEEP);
    return next;
  }

  function count(state) {
    return Object.keys(state.pending).length;
  }

  function byAge(a, b) {
    var at = a.requestedAt || "";
    var bt = b.requestedAt || "";
    if (at !== bt) return at < bt ? -1 : 1;
    return a.requestId < b.requestId ? -1 : a.requestId > b.requestId ? 1 : 0;
  }

  // Exactly the same command: the only requests offered "Allow all".
  function commandKey(row) {
    return row.kind === "permission" && typeof row.command === "string" && row.command !== ""
      ? row.toolName + "\n" + row.command
      : null;
  }

  function agentName(agentId) {
    return AGENT_NAMES[agentId] || agentId || "";
  }

  /** What one row reads as: what it wants, in a short line. */
  function describe(row) {
    if (row.kind === "question") {
      var n = (row.questions || []).length;
      return n > 1 ? n + " questions" : "A question for you";
    }
    if (row.kind === "plan") return "A plan is waiting for your approval";
    if (row.command) return "Run " + row.command.split("\n")[0];
    var tool = row.toolName || "a tool";
    if (row.path) {
      var size = row.added != null || row.removed != null
        ? " (+" + (row.added || 0) + " −" + (row.removed || 0) + ")" : "";
      return (/^(edit|multiedit|write|notebookedit|apply_patch|applypatch|file_change|edit_file|write_file)$/i.test(tool)
        ? "Edit " : tool + " ") + row.path + size;
    }
    if (row.url) return tool + " " + row.url;
    if (row.description) return tool + ": " + row.description;
    return "Use " + tool;
  }

  /**
   * The screen: waiting rows oldest first, each with its chat, project and
   * agent, and the ones that can be allowed together; then what was
   * answered here.
   */
  function build(state, snapshot) {
    var chats = {};
    var list = (snapshot && snapshot.chats) || [];
    for (var i = 0; i < list.length; i++) chats[list[i].id] = list[i];
    var projects = {};
    var plist = (snapshot && snapshot.projects) || [];
    for (var j = 0; j < plist.length; j++) projects[plist[j].key] = plist[j].name;

    function decorate(row) {
      var chat = chats[row.chatId];
      return {
        key: key(row.chatId, row.requestId),
        chatId: row.chatId,
        requestId: row.requestId,
        kind: row.kind,
        toolName: row.toolName,
        command: row.command || null,
        summary: describe(row),
        questions: row.questions || [],
        requestedAt: row.requestedAt || null,
        chatTitle: chat ? chat.title : "A chat",
        projectName: chat && chat.projectKey ? projects[chat.projectKey] || "" : chat ? "Standalone" : "",
        agentName: chat ? agentName(chat.agentId) : "",
        sameCommand: [],
      };
    }

    var rows = Object.keys(state.pending).map(function (k) { return state.pending[k]; }).sort(byAge).map(decorate);
    var groups = {};
    for (var r = 0; r < rows.length; r++) {
      var ck = commandKey(state.pending[rows[r].key]);
      if (!ck) continue;
      (groups[ck] = groups[ck] || []).push(rows[r]);
    }
    for (var g in groups) {
      if (groups[g].length < 2) continue;
      var targets = groups[g].map(function (row) { return { chatId: row.chatId, requestId: row.requestId }; });
      for (var m = 0; m < groups[g].length; m++) groups[g][m].sameCommand = targets;
    }
    return {
      rows: rows,
      count: rows.length,
      answered: state.answered.map(function (item) {
        var row = decorate(item.row);
        row.note = item.note;
        return row;
      }),
    };
  }

  /**
   * The answers `answerQuestion` takes: each question's text to the chosen
   * labels, joined the way Abstract's own card joins them. Null until
   * every question has one.
   */
  function questionAnswers(questions, picks) {
    var answers = {};
    for (var i = 0; i < questions.length; i++) {
      var chosen = (picks && picks[questions[i].question]) || [];
      if (!chosen.length) return null;
      answers[questions[i].question] = chosen.join(", ");
    }
    return questions.length ? answers : null;
  }

  return {
    emptyState: emptyState,
    nextPull: nextPull,
    applyEvent: applyEvent,
    applyPull: applyPull,
    markAnswered: markAnswered,
    count: count,
    build: build,
    describe: describe,
    questionAnswers: questionAnswers,
    key: key,
  };
})();

if (typeof window !== "undefined") window.ApprovalsQueue = ApprovalsQueue;
