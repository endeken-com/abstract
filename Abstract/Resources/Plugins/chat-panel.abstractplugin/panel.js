"use strict";

// Pure logic over what the host hands this plugin, kept apart from the DOM
// so the host's tests can run it directly (like Kanban's board.js).
const ChatPanel = (() => {
  // The chat this showing sits beside: the context carries it under
  // chats.read; without the grant only its id arrives.
  function chatTitle(context, snapshot) {
    if (context && context.chat && context.chat.title) return context.chat.title;
    const chatId = context && context.chatId;
    if (chatId && snapshot && Array.isArray(snapshot.chats)) {
      const chat = snapshot.chats.find((row) => row.id === chatId);
      if (chat) return chat.title;
    }
    return null;
  }

  // One log line for a menu item or command the host ran.
  function logLine(invocation) {
    if (!invocation) return null;
    if (invocation.place === "chatMenu" && invocation.chatId) {
      return `Menu item ${invocation.contributionId} ran for chat ${invocation.chatId}`;
    }
    if (invocation.place === "palette") {
      return `Command ${invocation.contributionId} ran from ⌘K`;
    }
    return `${invocation.contributionId} ran`;
  }

  return { chatTitle, logLine };
})();
