"use strict";

// Approvals' screen (ABS-111). Each snapshot the host pushes means a chat
// moved, so the list of what's waiting is pulled again; the queue's rules
// are in queue.js.

const queue = window.ApprovalsQueue;
const host = window.AbstractPlugin;
const NOTE = "Answered from Approvals";

let state = queue.emptyState();
let snapshot = { chats: [], projects: [] };
// Picks for questions with several parts, kept across redraws.
const picks = {};
const busy = new Set();
let shownCount = -1;

const queueEl = document.getElementById("queue");
const summaryEl = document.getElementById("summary");
const emptyEl = document.getElementById("empty");
const errorEl = document.getElementById("error");
const answeredSection = document.getElementById("answered-section");
const answeredEl = document.getElementById("answered");

async function pull() {
  const asked = queue.nextPull(state);
  state = asked.state;
  const reply = await host.send("getPermissions");
  if (reply && reply.message && !reply.requests) return showError(reply.message);
  state = queue.applyPull(state, asked.seq, reply);
  render();
}

function showError(message) {
  errorEl.hidden = !message;
  errorEl.textContent = message || "";
}

function age(iso) {
  if (!iso) return "";
  const seconds = Math.max(0, (Date.now() - Date.parse(iso)) / 1000);
  if (seconds < 60) return "just now";
  const minutes = Math.round(seconds / 60);
  if (minutes < 60) return minutes + " min ago";
  const hours = Math.round(minutes / 60);
  if (hours < 24) return hours + (hours === 1 ? " hour ago" : " hours ago");
  const days = Math.round(hours / 24);
  return days + (days === 1 ? " day ago" : " days ago");
}

async function answer(targets, message, payload) {
  const id = targets.map((t) => queue.key(t.chatId, t.requestId)).join("|");
  if (busy.has(id)) return;
  busy.add(id);
  showError(null);
  render();
  const reply = await host.send(message, payload);
  busy.delete(id);
  if (reply && reply.done === true) {
    state = queue.markAnswered(state, targets, NOTE);
  } else {
    showError((reply && reply.message) || "That couldn't be answered.");
  }
  render();
  pull();
}

function button(label, onClick, options) {
  const b = document.createElement("button");
  b.type = "button";
  b.textContent = label;
  if (options && options.primary) b.className = "primary";
  if (options && options.disabled) b.disabled = true;
  b.addEventListener("click", onClick);
  return b;
}

function meta(row) {
  const line = document.createElement("p");
  line.className = "meta";
  line.textContent = [row.chatTitle, row.projectName, row.agentName, age(row.requestedAt)].filter(Boolean).join(" · ");
  return line;
}

function renderQuestions(row, disabled) {
  const box = document.createElement("div");
  box.className = "questions";
  const single = row.questions.length === 1 && !row.questions[0].multiSelect;
  for (const q of row.questions) {
    const block = document.createElement("div");
    block.className = "question";
    const text = document.createElement("p");
    text.className = "question-text";
    text.textContent = q.question;
    block.append(text);
    const options = document.createElement("div");
    options.className = "options";
    const chosen = (picks[row.key] && picks[row.key][q.question]) || [];
    for (const option of q.options || []) {
      const b = button(option.label, () => {
        if (single) {
          return answer([row], "answerQuestion",
            { chatId: row.chatId, requestId: row.requestId, answers: { [q.question]: option.label } });
        }
        const mine = (picks[row.key] = picks[row.key] || {});
        const now = new Set(mine[q.question] || []);
        if (q.multiSelect) { if (now.has(option.label)) now.delete(option.label); else now.add(option.label); }
        else { now.clear(); now.add(option.label); }
        mine[q.question] = [...now];
        render();
      }, { disabled });
      if (chosen.includes(option.label)) b.className = "picked";
      if (option.description) b.title = option.description;
      options.append(b);
    }
    if (!(q.options || []).length) {
      const none = document.createElement("p");
      none.className = "meta";
      none.textContent = "Open the chat to answer this one.";
      options.append(none);
    }
    block.append(options);
    box.append(block);
  }
  if (!single) {
    const answers = queue.questionAnswers(row.questions, picks[row.key]);
    box.append(button("Answer", () => {
      answer([row], "answerQuestion", { chatId: row.chatId, requestId: row.requestId, answers });
    }, { primary: true, disabled: disabled || !answers }));
  }
  return box;
}

function renderRow(row, offeredGroups) {
  const item = document.createElement("li");
  item.className = "row";
  const disabled = busy.has(row.key);

  const summary = document.createElement("p");
  summary.className = "summary";
  summary.textContent = row.summary;
  item.append(summary, meta(row));

  if (row.command && row.command.includes("\n")) {
    const pre = document.createElement("pre");
    pre.textContent = row.command;
    item.append(pre);
  }
  if (row.kind === "question") item.append(renderQuestions(row, disabled));

  const actions = document.createElement("div");
  actions.className = "actions";
  if (row.kind === "permission") {
    const target = [{ chatId: row.chatId, requestId: row.requestId }];
    actions.append(
      button("Allow", () => answer(target, "answerPermission",
        { chatId: row.chatId, requestId: row.requestId, allow: true }), { primary: true, disabled }),
      button("Deny", () => answer(target, "answerPermission",
        { chatId: row.chatId, requestId: row.requestId, allow: false }), { disabled }));
    // Offered once, on the oldest row of exactly the same command.
    const group = row.sameCommand.map((t) => queue.key(t.chatId, t.requestId)).join("|");
    if (row.sameCommand.length >= 2 && !offeredGroups.has(group)) {
      offeredGroups.add(group);
      actions.append(button("Allow All " + row.sameCommand.length, () => answer(row.sameCommand, "answerPermissions",
        { requests: row.sameCommand, allow: true }), { disabled: busy.has(group) }));
    }
  }
  actions.append(button("Open Chat", () => host.send("openChat", { chatId: row.chatId })));
  item.append(actions);
  return item;
}

function render() {
  const built = queue.build(state, snapshot);
  if (built.count !== shownCount) {
    shownCount = built.count;
    host.send("setBadge", { count: built.count });
  }
  summaryEl.textContent = built.count === 0 ? "" :
    built.count === 1 ? "1 request is waiting for you." : built.count + " requests are waiting for you, oldest first.";
  emptyEl.hidden = built.count !== 0;

  queueEl.textContent = "";
  const offered = new Set();
  for (const row of built.rows) queueEl.append(renderRow(row, offered));

  answeredSection.hidden = built.answered.length === 0;
  answeredEl.textContent = "";
  for (const row of built.answered) {
    const item = document.createElement("li");
    item.className = "row answered";
    const summary = document.createElement("p");
    summary.className = "summary";
    summary.textContent = row.summary;
    const note = document.createElement("p");
    note.className = "meta";
    note.textContent = row.note;
    item.append(summary, meta(row), note);
    answeredEl.append(item);
  }
}

host.on("snapshot", (next) => {
  snapshot = next || snapshot;
  pull();
});
host.send("getSnapshot");
render();
