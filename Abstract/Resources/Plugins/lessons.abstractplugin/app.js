"use strict";

// Lessons' screen (ABS-102). The chat menu item opens it with the chat it
// was chosen on, and as a tab in a chat's side panel (ABS-134) it works on
// the chat it sits beside; you pick where the lessons go, and the chat's
// own agent is sent the request. The edit it makes shows in that chat's
// Review.

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

const ui = window.AbstractUI;
let placedBeside = false;
idleEl.append(ui.empty("Pick a chat", "Choose Save What We Learned… from a chat's More menu, or open Lessons as a tab beside a chat."));

for (const option of lessons.targets) {
  const input = ui.h("input", { type: "radio", name: "target", value: option.id, checked: option.id === target });
  input.addEventListener("change", () => { target = option.id; render(); });
  targetsEl.append(ui.h("label", { class: "ab-choice" }, input,
    ui.h("span", { class: "ab-choice-text" }, ui.h("strong", null, option.title), ui.h("span", null, option.detail))));
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
    ? `${placedBeside ? "From this chat" : `From “${chat ? chat.title : "this chat"}”`}. Its agent writes the lessons, and the change waits in the chat's Review for you to keep or discard.`
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
    // Back to the chat, to watch the agent write it; beside it, it's already there.
    if (placedBeside) {
      say("Sent. Its agent is writing the lessons; the change will be in this chat's Review.");
    } else {
      const opened = await host.send("openChat", { chatId: sentTo });
      if (!opened || opened.message) {
        say("Sent. Open the chat to watch its agent write the lessons; the change will be in its Review.");
      }
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

// As a side-panel tab, the chat is the one it sits beside.
host.on("context", (context) => {
  if (!context || context.place !== "chatPanel" || !context.chatId) return;
  placedBeside = true;
  if (chatId !== context.chatId) {
    chatId = context.chatId;
    say(null);
  }
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
