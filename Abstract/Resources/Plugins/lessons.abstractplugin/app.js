"use strict";

// Lessons' screen (ABS-102). The chat menu item opens it with the chat it
// was chosen on; you pick where the lessons go, and the chat's own agent
// is sent the request. The edit it makes shows in that chat's Review.

const lessons = window.Lessons;
const host = window.AbstractPlugin;

let snapshot = { chats: [] };
let chatId = null;
let target = "instructions";
let sending = false;

const aboutEl = document.getElementById("about");
const idleEl = document.getElementById("idle");
const formEl = document.getElementById("form");
const targetsEl = document.getElementById("targets");
const skillRowEl = document.getElementById("skill-row");
const skillEl = document.getElementById("skill");
const requestEl = document.getElementById("request");
const sayEl = document.getElementById("said");
const sendEl = document.getElementById("send");

for (const option of lessons.targets) {
  const label = document.createElement("label");
  label.className = "target";
  const input = document.createElement("input");
  input.type = "radio";
  input.name = "target";
  input.value = option.id;
  input.checked = option.id === target;
  input.addEventListener("change", () => { target = option.id; render(); });
  const words = document.createElement("span");
  const title = document.createElement("strong");
  title.textContent = option.title;
  const detail = document.createElement("span");
  detail.className = "note";
  detail.textContent = option.detail;
  words.append(title, detail);
  label.append(input, words);
  targetsEl.append(label);
}

function say(message) {
  sayEl.hidden = !message;
  sayEl.textContent = message || "";
}

function render() {
  const chat = lessons.chatOf(snapshot, chatId);
  idleEl.hidden = !!chatId;
  formEl.hidden = !chatId;
  aboutEl.textContent = chatId
    ? `From “${chat ? chat.title : "this chat"}”. Its agent writes the lessons, and the change waits in the chat's Review for you to keep or discard.`
    : "";
  const named = lessons.takesSkillName(target);
  skillRowEl.hidden = !named;
  skillEl.placeholder = target === "newSkill"
    ? "Optional: the agent names it if you don't"
    : "Optional: the agent picks the one that fits if you don't";
  requestEl.textContent = lessons.request(target, named ? skillEl.value : "") || "";
  sendEl.disabled = sending || !chatId;
}

skillEl.addEventListener("input", render);

formEl.addEventListener("submit", async (event) => {
  event.preventDefault();
  if (sending || !chatId) return;
  const text = lessons.request(target, lessons.takesSkillName(target) ? skillEl.value : "");
  if (!text) return;
  sending = true;
  say(null);
  render();
  const sentTo = chatId;
  const reply = await host.send("sendMessage", { chatId: sentTo, text });
  sending = false;
  if (reply && reply.sent === true) {
    // Back to the chat, to watch the agent write it.
    const opened = await host.send("openChat", { chatId: sentTo });
    if (!opened || opened.message) {
      say("Sent. Open the chat to watch its agent write the lessons; the change will be in its Review.");
    }
  } else {
    say((reply && reply.message) || "The request couldn't be sent.");
  }
  render();
});

host.on("snapshot", (next) => {
  snapshot = next || { chats: [] };
  render();
});

host.on("invoke", (invocation) => {
  if (!invocation || invocation.place !== "chatMenu" || !invocation.chatId) return;
  chatId = invocation.chatId;
  say(null);
  render();
});

render();
host.send("getSnapshot");
