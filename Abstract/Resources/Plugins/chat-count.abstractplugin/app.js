"use strict";

const ui = window.AbstractUI;
const h = ui.h;

const groups = [
  ["needsYou", "Needs you"],
  ["working", "Working"],
  ["readyToReview", "Ready to review"],
  ["done", "Done"],
];
const AGENTS = { claude: "Claude Code", codex: "Codex", opencode: "OpenCode" };

let showDone = false;
let lastChats = null;

const countsEl = document.getElementById("counts");
const chatsEl = document.getElementById("chats");
const iconButton = document.getElementById("sample-icon");
const iconImage = iconButton.querySelector("img");

function showIcon(reply) {
  if (!reply || !reply.previewDataURL) return;
  iconImage.src = reply.previewDataURL;
  iconImage.hidden = false;
}

iconButton.addEventListener("click", async () => {
  const { x, y, width, height } = iconButton.getBoundingClientRect();
  showIcon(await window.AbstractPlugin.send("icon.choose", {
    key: "ChatCount", anchor: { x, y, width, height },
  }));
});
window.AbstractPlugin.send("icon.get", { key: "ChatCount" }).then(showIcon);

// Its one remembered setting, as a segmented control.
const tabs = ui.tabs({
  label: "Which chats",
  style: "segmented",
  selected: "open",
  tabs: [{ id: "open", label: "Open" }, { id: "all", label: "All" }],
  onSelect: (id) => {
    showDone = id === "all";
    window.AbstractPlugin.send("storage.set", { key: "showDone", value: showDone });
    render();
  },
});
document.getElementById("tabs").append(tabs.element);

function render() {
  countsEl.textContent = "";
  chatsEl.textContent = "";
  if (lastChats === null) {
    chatsEl.append(ui.skeleton(5));
    return;
  }
  for (const [key, label] of groups) {
    const count = lastChats.filter((chat) => chat.progress === key && !chat.archived).length;
    countsEl.append(h("div", { class: "count ab-card" },
      h("strong", null, String(count)),
      h("span", null, h("span", { class: "ab-status ab-" + key, "aria-hidden": "true" }), label)));
  }

  const shown = lastChats.filter((chat) => !chat.archived && (showDone || chat.progress !== "done"));
  if (lastChats.length === 0) {
    chatsEl.append(ui.empty("No chats yet", "Start a chat and it's counted here."));
    return;
  }
  if (shown.length === 0) {
    chatsEl.append(ui.empty("Every chat is done", "Choose All to see them."));
    return;
  }
  const list = h("ul", { class: "ab-list" });
  for (const chat of shown) {
    list.append(h("li", null, h("button", {
      type: "button",
      class: "ab-row ab-interactive chat",
      onclick: () => window.AbstractPlugin.send("openChat", { chatId: chat.id }),
    },
      h("span", { class: "ab-status ab-" + chat.progress, "aria-hidden": "true" }),
      h("span", { class: "ab-row-title" }, chat.title),
      h("span", { class: "ab-row-meta" }, AGENTS[chat.agentId] || chat.agentId))));
  }
  chatsEl.append(list);
}

window.AbstractPlugin.on("snapshot", (snapshot) => {
  lastChats = snapshot.chats || [];
  render();
});

window.AbstractPlugin.send("storage.get", { key: "showDone" }).then((reply) => {
  showDone = reply && reply.value === true;
  tabs.select(showDone ? "all" : "open");
  render();
});
window.AbstractPlugin.send("getSnapshot", {});
render();
