"use strict";

// Second opinion's tab in a chat's side panel (ABS-134). Reviews are asked
// for and sent from the chat's Review; this shows where they stand.

const ui = window.AbstractUI;
const h = ui.h;
const host = window.AbstractPlugin;

let chatId = null;
let reviews = null;

const panelEl = document.getElementById("panel");

function render() {
  panelEl.textContent = "";
  if (reviews === null) {
    panelEl.append(ui.skeleton(3));
    return;
  }
  if (!chatId) {
    panelEl.append(ui.empty("Open this beside a chat", "Second opinion shows the review of the chat whose side panel it's in."));
    return;
  }
  const state = window.OpinionPanel.describe(reviews[chatId]);
  if (!state) {
    panelEl.append(ui.empty("No second opinion yet",
      "In this chat's Review, choose Ask Codex to Review, or another agent. It reads the changes without touching them."));
    return;
  }
  const steps = h("div", { class: "rounds", "aria-label": state.roundLine });
  for (let i = 1; i <= state.rounds; i++) {
    steps.append(h("span", { class: "round" + (i < state.round || (i === state.round && state.phase === "done") ? " done" : i === state.round ? " current" : "") }));
  }
  const busy = state.phase === "reviewing" || state.phase === "fixing";
  panelEl.append(h("div", { class: "ab-card review" },
    h("div", { class: "review-head" },
      h("span", { class: "ab-status " + (busy ? "ab-working" : state.phase === "waiting" ? "ab-needsYou" : "ab-done"), "aria-hidden": "true" }),
      h("span", { class: "review-title" }, state.title)),
    h("p", { class: "ab-secondary ab-small" }, state.detail),
    h("div", { class: "review-foot" }, steps, h("span", { class: "ab-tertiary ab-small" }, state.roundLine))));
}

async function load() {
  const reply = await host.send("storage.get", { key: "reviews" });
  reviews = (reply && reply.value) || {};
  render();
}

host.on("context", (context) => {
  if (context && context.chatId) chatId = context.chatId;
  render();
});
host.on("snapshot", load);
setInterval(load, 15000);
load();
host.send("getSnapshot");
