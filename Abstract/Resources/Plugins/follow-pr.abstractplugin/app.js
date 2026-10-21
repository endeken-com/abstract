"use strict";

// Follow PR's tab in a chat's side panel (ABS-134). It reads what the
// background script keeps; Follow itself is turned on and off in the
// chat's Pull Request tab.

const ui = window.AbstractUI;
const h = ui.h;
const host = window.AbstractPlugin;
const panel = window.FollowPanel;

let chatId = null;
let tab = "following";
let follows = null;
let history = {};

const panelEl = document.getElementById("panel");
const tabs = ui.tabs({
  label: "Follow pull request",
  style: "segmented",
  selected: tab,
  tabs: [{ id: "following", label: "Following" }, { id: "history", label: "History" }],
  onSelect: (id) => { tab = id; render(); },
});
document.getElementById("tabs").append(tabs.element);

function today() {
  const d = new Date();
  const pad = (n) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

function ago(iso) {
  const minutes = Math.max(0, Math.round((Date.now() - Date.parse(iso)) / 60000));
  if (minutes < 1) return "now";
  if (minutes < 60) return minutes + "m";
  if (minutes < 1440) return Math.round(minutes / 60) + "h";
  return Math.round(minutes / 1440) + "d";
}

function render() {
  panelEl.textContent = "";
  if (follows === null) {
    panelEl.append(ui.skeleton(3));
    return;
  }
  if (!chatId) {
    panelEl.append(ui.empty("Open this beside a chat", "Follow PR works on the chat whose side panel it's in."));
    return;
  }
  const entries = panel.history(history[chatId]);
  tabs.update([{ id: "following", label: "Following" }, { id: "history", label: "History", count: entries.length || null }]);

  if (tab === "following") {
    const state = panel.following(follows[chatId], Date.now(), today());
    if (!state) {
      panelEl.append(ui.empty("Not following",
        "Turn on Follow in this chat's Pull Request tab, and new review comments, requested changes and failed checks go to its agent."));
      return;
    }
    panelEl.append(h("div", { class: "ab-card status" },
      h("div", { class: "status-head" },
        h("span", { class: "ab-status ab-working", "aria-hidden": "true" }),
        h("span", { class: "status-title" }, "Following PR #" + state.number),
        h("span", { class: "ab-badge ab-pr-open" }, "Open")),
      h("p", { class: "ab-secondary ab-small" }, state.next || "Nothing new since the last message. New feedback goes about two minutes after it arrives."),
      h("p", { class: "ab-tertiary ab-small" }, state.sentLine)),
      h("p", { class: "ab-tertiary ab-small hint" },
        "Following stops when the pull request is merged or closed. Turn it off in the Pull Request tab."));
    return;
  }
  if (!entries.length) {
    panelEl.append(ui.empty("Nothing sent yet", "Each message Follow sends to the agent is listed here."));
    return;
  }
  panelEl.append(h("ul", { class: "ab-list" }, entries.map((entry) =>
    h("li", { class: "ab-row" },
      h("span", { class: "ab-status ab-done", "aria-hidden": "true" }),
      h("span", { class: "ab-row-title" }, entry.line),
      h("span", { class: "ab-row-meta" }, ago(entry.at))))));
}

async function load() {
  const [f, s] = await Promise.all([host.send("storage.get", { key: "follows" }), host.send("storage.get", { key: "history" })]);
  follows = (f && f.value) || {};
  history = (s && s.value) || {};
  render();
}

host.on("context", (context) => {
  if (context && context.chatId) chatId = context.chatId;
  render();
});
// A chat moving is a good moment to look again; so is every half minute.
host.on("snapshot", load);
setInterval(load, 30000);
load();
host.send("getSnapshot");
