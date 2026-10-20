"use strict";

let lastContext = null;
let lastSnapshot = null;

const headingEl = document.getElementById("heading");
const whereEl = document.getElementById("where");
const logEl = document.getElementById("log");

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
  const item = document.createElement("li");
  item.textContent = line;
  logEl.prepend(item);
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
