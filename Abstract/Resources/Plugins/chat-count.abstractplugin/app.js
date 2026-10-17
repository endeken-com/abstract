"use strict";

const groups = [
  ["needsYou", "Needs you"],
  ["working", "Working"],
  ["readyToReview", "Ready to review"],
  ["done", "Done"],
];

let showDone = false;
let lastChats = [];

const countsEl = document.getElementById("counts");
const chatsEl = document.getElementById("chats");
const emptyEl = document.getElementById("empty");
const toggleEl = document.getElementById("show-done");

function render() {
  countsEl.textContent = "";
  for (const [key, label] of groups) {
    const box = document.createElement("div");
    box.className = "count";
    const number = document.createElement("strong");
    number.textContent = String(lastChats.filter((chat) => chat.progress === key && !chat.archived).length);
    const caption = document.createElement("span");
    caption.textContent = label;
    box.append(number, caption);
    countsEl.append(box);
  }

  chatsEl.textContent = "";
  const shown = lastChats.filter((chat) => !chat.archived && (showDone || chat.progress !== "done"));
  for (const chat of shown) {
    const item = document.createElement("li");
    const button = document.createElement("button");
    button.type = "button";
    button.textContent = chat.title;
    const agent = document.createElement("span");
    agent.className = "agent";
    agent.textContent = chat.agentId;
    button.append(agent);
    button.addEventListener("click", () => {
      window.AbstractPlugin.send("openChat", { chatId: chat.id });
    });
    item.append(button);
    chatsEl.append(item);
  }
  emptyEl.hidden = lastChats.length !== 0;
}

toggleEl.addEventListener("change", () => {
  showDone = toggleEl.checked;
  window.AbstractPlugin.send("storage.set", { key: "showDone", value: showDone });
  render();
});

window.AbstractPlugin.on("snapshot", (snapshot) => {
  lastChats = snapshot.chats || [];
  render();
});

window.AbstractPlugin.send("storage.get", { key: "showDone" }).then((reply) => {
  showDone = reply && reply.value === true;
  toggleEl.checked = showDone;
  render();
});
window.AbstractPlugin.send("getSnapshot", {});
