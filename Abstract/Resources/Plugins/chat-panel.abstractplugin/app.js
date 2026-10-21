"use strict";

let lastContext = null;
let lastSnapshot = null;

const headingEl = document.getElementById("heading");
const whereEl = document.getElementById("where");
const logEl = document.getElementById("log");
const emptyEl = document.getElementById("empty");
emptyEl.append(window.AbstractUI.empty("Nothing has run yet", "Its chat menu item and ⌘K command log here."));

function render() {
  const title = ChatPanel.chatTitle(lastContext, lastSnapshot);
  if (lastContext && lastContext.place === "chatPanel") {
    headingEl.textContent = title || "This chat";
    whereEl.textContent = title
      ? "This tab sits beside the chat above. It can see the chat's title because you granted it your chats."
      : "This tab sits beside a chat, but wasn't granted your chats, so it knows only the chat's id.";
  }
}

function log(line) {
  if (!line) return;
  emptyEl.hidden = true;
  logEl.prepend(window.AbstractUI.h("li", { class: "ab-row" },
    window.AbstractUI.h("span", { class: "ab-status ab-done", "aria-hidden": "true" }),
    window.AbstractUI.h("span", { class: "ab-row-title" }, line)));
}

window.AbstractPlugin.on("context", (context) => {
  lastContext = context;
  render();
});

window.AbstractPlugin.on("snapshot", (snapshot) => {
  lastSnapshot = snapshot;
  render();
});

window.AbstractPlugin.on("invoke", (invocation) => {
  log(ChatPanel.logLine(invocation));
});

window.AbstractPlugin.send("getSnapshot", {});
