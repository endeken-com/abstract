// The rules are pure functions so the host's plugin tests can exercise them.
const Delegation = (() => {
  const maxChildren = 5;
  const maxDepth = 2;

  function depth(chats, id) {
    const byId = new Map(chats.map((chat) => [chat.id, chat]));
    const seen = new Set();
    let current = id, count = 0;
    while (current) {
      if (seen.has(current)) throw new Error("A chat can't be its own sub-task.");
      seen.add(current);
      const chat = byId.get(current);
      if (!chat) throw new Error("The parent chat isn't available on this Mac.");
      current = chat.parentId;
      if (current) count++;
    }
    return count;
  }

  function check(state, chats, parentId, input) {
    const parent = chats.find((chat) => chat.id === parentId);
    if (!parent) throw new Error("The parent chat isn't available.");
    if (depth(chats, parentId) >= maxDepth) throw new Error("Sub-tasks can be at most two chats deep.");
    if (state.children.filter((child) => child.parentId === parentId).length >= maxChildren)
      throw new Error("A chat can have at most five sub-tasks.");
    const title = String(input.title || "").trim();
    const prompt = String(input.prompt || "").trim();
    const agent = String(input.agent || "").trim();
    if (!title || !prompt || !agent) throw new Error("Give the sub-task a title, a prompt and an agent.");
    if (title.length > 160 || prompt.length > 8000 || agent.length > 60)
      throw new Error("That sub-task is too long.");
    const projectKey = input.project || parent.projectKey;
    if (!projectKey || projectKey !== parent.projectKey)
      throw new Error("Sub-tasks must stay in the parent's project on this Mac.");
    if (!parent.branch) throw new Error("Commit the parent chat's work before starting a sub-task.");
    const normalized = prompt.toLowerCase().replace(/\s+/g, " ");
    let ancestor = parentId;
    while (ancestor) {
      if (state.children.some((child) => child.id === ancestor && child.prompt.toLowerCase().replace(/\s+/g, " ") === normalized))
        throw new Error("That prompt repeats an open ancestor's sub-task.");
      ancestor = chats.find((chat) => chat.id === ancestor)?.parentId;
    }
    return { title, prompt, agent, projectKey, parent };
  }

  function waitedOn(state, parentId, requested) {
    const children = state.children.filter((child) => child.parentId === parentId);
    const ids = requested === undefined ? children.filter((child) => !child.reported).map((child) => child.id) : requested;
    if (!Array.isArray(ids) || !ids.length || new Set(ids).size !== ids.length ||
        ids.some((id) => !children.some((child) => child.id === id)))
      throw new Error("Wait for one or more of this chat's sub-tasks.");
    return ids;
  }

  function ready(state, parentId) {
    const ids = state.waits[parentId];
    if (!ids) return null;
    const children = ids.map((id) => state.children.find((child) => child.id === id));
    if (!children.some((child) => child.outcome === "failed" || child.outcome === "stalled") &&
        !children.every((child) => child.outcome)) return null;
    return children;
  }

  function report(children) {
    return "Your sub-tasks have news. Review each child chat and merge the branches you want into this branch.\n\n" +
      children.map((child) => {
        const lines = [`${child.title} (${child.agent}): ${child.outcome || "still working"}.`];
        if (child.summary) lines.push(child.summary.slice(0, 2000));
        if (child.branch) lines.push(`Branch: ${child.branch}`);
        if (child.changedFiles != null) lines.push(`Changed files: ${child.changedFiles}`);
        lines.push(`Chat: ${child.id}`);
        return lines.join("\n");
      }).join("\n\n");
  }

  function finish(state, childId, outcome, summary, changedFiles, branch) {
    const child = state.children.find((item) => item.id === childId);
    if (!child || child.outcome) return false;
    child.outcome = outcome;
    child.summary = String(summary || "").slice(0, 2000);
    child.changedFiles = changedFiles;
    child.branch = branch || child.branch;
    return true;
  }

  return { maxChildren, maxDepth, depth, check, waitedOn, ready, report, finish };
})();

if (typeof module !== "undefined" && module.exports) module.exports = Delegation;

if (typeof window !== "undefined" && window.AbstractPlugin) {
  const host = window.AbstractPlugin;
  let state = { children: [], waits: {} };
  let chats = [];
  const loaded = host.send("storage.get", { key: "delegation" }).then((reply) => {
    if (reply && reply.value && Array.isArray(reply.value.children)) state = reply.value;
  });
  let queue = loaded;
  const enqueue = (work) => {
    const next = queue.then(work, work);
    queue = next.catch(() => {});
    return next;
  };
  const save = () => host.send("storage.set", { key: "delegation", value: state });
  const chat = (id) => chats.find((item) => item.id === id);

  async function wake(parentId) {
    const children = Delegation.ready(state, parentId);
    if (!children) return;
    const reply = await host.send("sendMessage", { chatId: parentId, text: Delegation.report(children) });
    if (reply && reply.sent) {
      for (const child of children) if (child.outcome) child.reported = true;
      delete state.waits[parentId];
      await save();
    }
  }

  host.on("snapshot", (snapshot) => { chats = (snapshot && snapshot.chats) || []; });

  host.tools.handle("delegate", (input, context) => enqueue(async () => {
    await host.send("getSnapshot");
    const existing = state.children.find((child) => child.parentId === context.chatId &&
      child.title === String(input.title || "").trim() &&
      child.prompt === String(input.prompt || "").trim() && child.agent === String(input.agent || "").trim());
    if (existing) return `This sub-task is already in chat ${existing.id}. Call wait_for, then end your turn.`;
    const request = Delegation.check(state, chats, context.chatId, input);
    const reply = await host.send("createChat", {
      parentId: context.chatId, projectKey: request.projectKey, agentId: request.agent,
      title: request.title,
      prompt: request.prompt + "\n\nThis is a sub-task of another chat. Work in this chat's own branch and worktree. " +
        "The parent's uncommitted changes are not available here. End with a concise report of what you did, " +
        "what failed, and what the parent should do next. Do not merge your branch into the parent's branch.",
    });
    if (!reply || !reply.chatId) throw new Error((reply && reply.message) || "The sub-task couldn't start.");
    state.children.push({ id: reply.chatId, parentId: context.chatId, title: request.title,
      prompt: request.prompt, agent: request.agent, projectKey: request.projectKey,
      createdAt: Date.now(), lastActivityAt: Date.now(), branch: null, outcome: null });
    await save();
    await host.send("getSnapshot");
    if (chat(reply.chatId)?.status === "errored") {
      Delegation.finish(state, reply.chatId, "failed", "The child chat couldn't start.", 0, null);
      await save();
    }
    return `Started ${request.title} with ${request.agent}. Child chat: ${reply.chatId}. ` +
      "It has its own branch. Call wait_for after starting the other sub-tasks, then end your turn.";
  }));

  host.tools.handle("wait_for", (input, context) => enqueue(async () => {
    const ids = Delegation.waitedOn(state, context.chatId, input.children);
    state.waits[context.chatId] = ids;
    await save();
    // Return the tool result before a completed child's message starts another turn.
    setTimeout(() => enqueue(() => wake(context.chatId)), 0);
    return "Waiting. End your turn; you'll be sent the sub-tasks' reports.";
  }));

  host.events.subscribe(["turn.finished", "chat.statusChanged"], (event) => enqueue(async () => {
    const child = state.children.find((item) => item.id === event.chatId);
    if (!child) return;
    await host.send("getSnapshot");
    child.lastActivityAt = Date.now();
    if (event.type === "turn.finished") {
      Delegation.finish(state, child.id, event.outcome === "done" ? "done" : "failed",
        event.summary, event.changedFiles, chat(child.id)?.branch);
    }
    await save();
    await wake(child.parentId);
  }));

  host.jobs.schedule("stalled-children", "FREQ=MINUTELY", () => enqueue(async () => {
    // A fresh snapshot carries each chat's last activity and branch.
    await host.send("getSnapshot");
    for (const child of state.children) {
      if (child.outcome) continue;
      const row = chat(child.id);
      if (!row) {
        Delegation.finish(state, child.id, "failed", "The child chat is no longer available.", null, child.branch);
        await wake(child.parentId);
        continue;
      }
      if (row?.status === "errored") {
        Delegation.finish(state, child.id, "failed", "The child chat failed.", null, row.branch);
        await wake(child.parentId);
        continue;
      }
      if (row.status === "idle" || row.status === "finished") {
        const turns = await host.send("getTurns", { chatId: child.id, offset: 0, limit: 200 });
        const items = (turns && turns.items) || [];
        const last = items[items.length - 1];
        if (last) {
          Delegation.finish(state, child.id, last.outcome === "done" ? "done" : "failed",
            last.summary, null, row.branch);
          await wake(child.parentId);
          continue;
        }
      }
      if (row?.stalled) {
        Delegation.finish(state, child.id, "stalled", "No activity for 15 minutes.", null, row?.branch);
        await wake(child.parentId);
      }
    }
    await save();
  }));

  host.send("getSnapshot");
}
