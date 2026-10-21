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

const ui = window.AbstractUI;
const h = ui.h;
let tab = "waiting";
let pulled = false;

const panelEl = document.getElementById("panel");
const summaryEl = document.getElementById("summary");
const errorEl = document.getElementById("error");

const tabs = ui.tabs({
  label: "Requests",
  style: "segmented",
  selected: tab,
  tabs: [{ id: "waiting", label: "Waiting" }, { id: "answered", label: "Answered" }],
  onSelect: (id) => { tab = id; render(); },
});
document.getElementById("tabs").append(tabs.element);

async function pull() {
  const asked = queue.nextPull(state);
  state = asked.state;
  const reply = await host.send("getPermissions");
  if (reply && reply.message && !reply.requests) return showError(reply.message);
  state = queue.applyPull(state, asked.seq, reply);
  pulled = true;
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
  const o = options || {};
  return h("button", {
    type: "button",
    class: "ab-button" + (o.primary ? " ab-primary" : "") + (o.ghost ? " ab-ghost" : "") + (o.picked ? " ab-picked" : ""),
    disabled: !!o.disabled,
    title: o.title || null,
    onclick: onClick,
  }, label);
}

function meta(row) {
  return h("p", { class: "meta ab-truncate" },
    [row.chatTitle, row.projectName, row.agentName].filter(Boolean).join(" · "));
}

function renderQuestions(row, disabled) {
  const box = h("div", { class: "questions" });
  const single = row.questions.length === 1 && !row.questions[0].multiSelect;
  for (const q of row.questions) {
    const chosen = (picks[row.key] && picks[row.key][q.question]) || [];
    const options = h("div", { class: "ab-buttons" });
    for (const option of q.options || []) {
      options.append(button(option.label, () => {
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
      }, { disabled, picked: chosen.includes(option.label), title: option.description }));
    }
    if (!(q.options || []).length) options.append(h("p", { class: "meta" }, "Open the chat to answer this one."));
    box.append(h("div", { class: "question" }, h("p", { class: "question-text" }, q.question), options));
  }
  if (!single) {
    const answers = queue.questionAnswers(row.questions, picks[row.key]);
    box.append(h("div", { class: "ab-buttons" }, button("Answer", () => {
      answer([row], "answerQuestion", { chatId: row.chatId, requestId: row.requestId, answers });
    }, { primary: true, disabled: disabled || !answers })));
  }
  return box;
}

function renderRow(row, offeredGroups) {
  const disabled = busy.has(row.key);
  const item = h("li", { class: "request ab-card", dataset: { key: row.key } },
    h("div", { class: "request-head" },
      h("span", { class: "ab-status ab-needsYou", "aria-hidden": "true" }),
      h("p", { class: "summary" + (row.command ? " ab-mono" : "") }, row.summary),
      h("span", { class: "age ab-tertiary ab-small" }, age(row.requestedAt))),
    meta(row));
  if (row.command && row.command.includes("\n")) item.append(h("pre", { class: "ab-selectable" }, row.command));
  if (row.kind === "question") item.append(renderQuestions(row, disabled));

  const actions = h("div", { class: "ab-buttons actions" });
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
  actions.append(h("span", { class: "ab-spacer" }),
    button("Open Chat", () => host.send("openChat", { chatId: row.chatId }), { ghost: true }));
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
    built.count === 1 ? "1 waiting" : built.count + " waiting, oldest first";
  tabs.update([
    { id: "waiting", label: "Waiting", count: built.count || null },
    { id: "answered", label: "Answered", count: built.answered.length || null },
  ]);

  panelEl.textContent = "";
  if (!pulled) {
    panelEl.append(ui.skeleton(3));
    return;
  }
  if (tab === "waiting") {
    if (built.count === 0) {
      panelEl.append(ui.empty("Nothing is waiting for you",
        "When an agent asks for permission or has a question, it shows up here."));
      return;
    }
    const list = h("ul", { class: "ab-list requests", "aria-label": "Waiting for you" });
    const offered = new Set();
    for (const row of built.rows) list.append(renderRow(row, offered));
    panelEl.append(list);
    return;
  }
  if (built.answered.length === 0) {
    panelEl.append(ui.empty("Nothing answered here yet", "What you allow, deny or answer here is listed until you leave."));
    return;
  }
  const list = h("ul", { class: "ab-list", "aria-label": "Answered here" });
  for (const row of built.answered) {
    list.append(h("li", { class: "ab-row answered" },
      h("span", { class: "ab-status ab-done", "aria-hidden": "true" }),
      h("span", { class: "ab-row-title" + (row.command ? " ab-mono" : "") }, row.summary),
      h("span", { class: "ab-row-meta" }, h("span", { class: "ab-truncate" }, row.chatTitle), row.note)));
  }
  panelEl.append(list);
}

host.on("snapshot", (next) => {
  snapshot = next || snapshot;
  pull();
});
host.send("getSnapshot");
render();
