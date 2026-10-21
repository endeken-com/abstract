// Follow pull request (ABS-109): with Follow on in a chat's Pull Request
// tab, new review comments, requested changes and failed checks on its
// pull request go to the chat's agent. What arrives within two minutes
// goes as one message, after any turn already running. Following stops
// when the pull request is merged or closed. After ten automatic turns on
// one pull request in a day, each next one asks you first.
//
// `FollowPR` is plain logic with no host calls, so tests run it as is.
// The wiring at the bottom runs only inside Abstract.
const FollowPR = (() => {
  const batchMs = 2 * 60 * 1000;
  const dailyLimit = 10;
  const itemTextLimit = 1500;
  const messageLimit = 18000;
  // Enough to never send an item twice; older keys are long gone from GitHub's lists too.
  const seenLimit = 1000;

  /** The local calendar day of `now`, which the daily limit counts in. */
  function day(now) {
    const d = new Date(now);
    const pad = (n) => String(n).padStart(2, "0");
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
  }

  /**
   * What reviewers said on the pull request, each with a key so it's sent
   * once: comments on the code (not in resolved threads), reviews that
   * request changes or say something, and comments that aren't a bot's.
   */
  function feedback(pr) {
    const out = [];
    for (const thread of (pr && pr.threads) || []) {
      if (thread.isResolved) continue;
      const line = thread.line != null ? thread.line : thread.originalLine;
      for (const comment of thread.comments || []) {
        out.push({ key: `thread:${comment.id}`, kind: "code", path: thread.path, line: line == null ? null : line,
                   author: comment.author, body: comment.body || "" });
      }
    }
    for (const review of (pr && pr.reviews) || []) {
      const body = (review.body || "").trim();
      if (review.verdict !== "changesRequested" && !(review.verdict === "commented" && body)) continue;
      out.push({ key: `review:${review.author}:${review.submittedAt}:${review.verdict}`, kind: review.verdict,
                 author: review.author, body });
    }
    for (const comment of (pr && pr.comments) || []) {
      const body = (comment.body || "").trim();
      if (comment.isBot || !body) continue;
      out.push({ key: `comment:${comment.author}:${comment.createdAt}`, kind: "comment", author: comment.author, body });
    }
    return out;
  }

  /** Checks failing now. One that passes and fails again is news again. */
  function failedChecks(pr) {
    return ((pr && pr.checks) || []).filter((check) => check.outcome === "failed").map((check) => ({
      key: `check:${check.workflow || ""}/${check.name}`, kind: "check",
      name: check.name, workflow: check.workflow || null, url: check.url || null,
    }));
  }

  function clip(text, limit) {
    const value = String(text || "").trim();
    return value.length > limit ? value.slice(0, limit - 1) + "…" : value;
  }

  function describe(item) {
    const body = clip(item.body, itemTextLimit).replace(/\n/g, "\n  ");
    switch (item.kind) {
      case "code": {
        const place = item.line == null ? item.path : `${item.path}:${item.line}`;
        return `- ${item.author} on \`${place}\`: ${body}`;
      }
      case "changesRequested":
        return body ? `- ${item.author} requested changes: ${body}` : `- ${item.author} requested changes.`;
      case "check":
        return `- Check failed: ${item.workflow ? `${item.workflow} / ` : ""}${item.name}${item.url ? ` (${item.url})` : ""}`;
      default:
        return `- ${item.author} commented: ${body}`;
    }
  }

  /** One message for a batch: what's new, then what to do with it. */
  function message(number, items) {
    const head = `New on PR #${number}:\n\n`;
    const checks = items.some((item) => item.kind === "check");
    const tail =
      "\n\nAddress what needs a change, then tell me what you changed." +
      (checks ? " `gh run view --log-failed` shows a failed check's steps." : "");
    const lines = [];
    let length = head.length + tail.length;
    for (let i = 0; i < items.length; i++) {
      const line = describe(items[i]);
      const more = `- and ${items.length - i} more on GitHub.`;
      if (length + line.length + 1 + more.length > messageLimit) { lines.push(more); break; }
      lines.push(line);
      length += line.length + 1;
    }
    return head + lines.join("\n") + tail;
  }

  function remember(keys, added) {
    const all = keys.concat(added.filter((key) => !keys.includes(key)));
    return all.slice(Math.max(0, all.length - seenLimit));
  }

  /**
   * The next step for one followed chat. `follow` is its stored state or
   * null; `happening` is what just happened, with `now` (ms). Returns the
   * new state (null to stop following), what to do, and what to tell you.
   *   { kind: "follow", pr }          Follow was turned on
   *   { kind: "unfollow" }            Follow was turned off
   *   { kind: "update", pr }          the pull request changed
   *   { kind: "due", working }        a batch's two minutes are up
   *   { kind: "turnFinished" }        the chat's agent finished a turn
   * Effects: { kind: "send", text, ask } — send the batch; `ask` asks you first.
   */
  function step(follow, happening) {
    const now = happening.now;
    switch (happening.kind) {
      case "follow": {
        const pr = happening.pr;
        if (!pr || pr.state !== "open") {
          return { follow: null, notice: "This chat's pull request isn't open, so there's nothing to follow." };
        }
        // What's already there isn't news.
        return {
          follow: {
            number: pr.number, seen: remember([], feedback(pr).map((item) => item.key)),
            failing: failedChecks(pr).map((item) => item.key),
            pending: [], dueAt: null, waiting: false, day: day(now), sent: 0,
          },
        };
      }
      case "unfollow":
        return { follow: null };
      case "update": {
        const pr = happening.pr;
        if (!follow || !pr) return { follow };
        if (pr.number !== follow.number) return { follow: null };
        if (pr.state === "merged" || pr.state === "closed") {
          return { follow: null, notice: `PR #${pr.number} was ${pr.state}, so it's no longer followed.` };
        }
        const fresh = feedback(pr).filter((item) => !follow.seen.includes(item.key));
        const failing = failedChecks(pr);
        const newlyFailed = failing.filter((item) => !follow.failing.includes(item.key));
        const queued = new Set(follow.pending.map((item) => item.key));
        const added = fresh.concat(newlyFailed).filter((item) => !queued.has(item.key));
        const next = {
          ...follow,
          seen: remember(follow.seen, fresh.map((item) => item.key)),
          failing: failing.map((item) => item.key),
          pending: follow.pending.concat(added),
        };
        // The two minutes run from the first item of a batch.
        if (added.length && !follow.pending.length) next.dueAt = now + batchMs;
        return { follow: next };
      }
      case "due":
        if (!follow || !follow.pending.length || now < follow.dueAt) return { follow };
        // Never in the middle of a turn: the batch waits for it to end.
        if (happening.working) return { follow: { ...follow, waiting: true } };
        return send(follow, now);
      case "turnFinished":
        if (!follow || !follow.pending.length) return { follow };
        if (now < follow.dueAt) return { follow: { ...follow, waiting: false } };
        return send(follow, now);
      default:
        return { follow };
    }
  }

  function send(follow, now) {
    const today = day(now);
    const sent = follow.day === today ? follow.sent : 0;
    const ask = sent >= dailyLimit;
    const result = {
      follow: { ...follow, pending: [], dueAt: null, waiting: false, day: today, sent: sent + 1 },
      effect: { kind: "send", text: message(follow.number, follow.pending), ask },
    };
    if (sent === dailyLimit) {
      result.notice = `PR #${follow.number} has had ${dailyLimit} automatic turns today, so each next one asks you first.`;
    }
    return result;
  }

  return { batchMs, dailyLimit, day, feedback, failedChecks, message, step };
})();

if (typeof window !== "undefined" && window.AbstractPlugin) {
  const host = window.AbstractPlugin;
  // By followed chat id. Kept, so a relaunch carries on where it was.
  let follows = {};
  // Whether each chat's agent is working, from the first snapshot and then
  // status events: a background script isn't sent a snapshot per change.
  const working = {};
  const timers = {};

  const notice = (text) => text && host.send("showNotice", { text });
  const save = () => host.send("storage.set", { key: "follows", value: follows });
  const readPullRequest = async (chatId) => {
    const reply = await host.send("getPullRequest", { chatId });
    return (reply && reply.pullRequest) || null;
  };

  // One change at a time, in order: each reads and writes `follows`.
  let queue = host.send("storage.get", { key: "follows" }).then((reply) => {
    follows = (reply && reply.value) || {};
    for (const chatId of Object.keys(follows)) arm(chatId);
  });
  const enqueue = (work) => {
    queue = queue.then(work, work);
    return queue;
  };

  /** Wakes up when a chat's batch is due. */
  function arm(chatId) {
    clearTimeout(timers[chatId]);
    delete timers[chatId];
    const follow = follows[chatId];
    if (!follow || !follow.dueAt) return;
    timers[chatId] = setTimeout(() => apply(chatId, { kind: "due" }), Math.max(0, follow.dueAt - Date.now()) + 100);
  }

  function apply(chatId, happening, read) {
    return enqueue(async () => {
      if (read) happening = { ...happening, pr: await readPullRequest(chatId) };
      const result = FollowPR.step(follows[chatId] || null, { ...happening, now: Date.now(), working: !!working[chatId] });
      if (result.follow) follows[chatId] = result.follow; else delete follows[chatId];
      await save();
      arm(chatId);
      await notice(result.notice);
      if (result.effect && result.effect.kind === "send") {
        const reply = await host.send("sendMessage", { chatId, text: result.effect.text, ask: result.effect.ask });
        if (!reply || reply.sent !== true) {
          await notice((reply && reply.message) || "The news from the pull request couldn't be sent.");
        }
      }
    });
  }

  host.on("snapshot", (snapshot) => {
    for (const chat of (snapshot && snapshot.chats) || []) working[chat.id] = chat.progress === "working";
  });

  host.events.subscribe(["pullRequest.updated", "turn.finished", "chat.statusChanged"], (event) => {
    if (event.type === "chat.statusChanged") {
      working[event.chatId] = event.status === "working";
      return;
    }
    if (!follows[event.chatId]) return;
    if (event.type === "turn.finished") {
      working[event.chatId] = false;
      return apply(event.chatId, { kind: "turnFinished" });
    }
    // Merged or closed is in the event itself; anything else is read in full.
    const pr = event.pullRequest;
    if (pr && pr.state !== "open") return apply(event.chatId, { kind: "update", pr });
    return apply(event.chatId, { kind: "update" }, true);
  });

  host.on("invoke", (invocation) => {
    if (!invocation || invocation.place !== "pullRequest" || invocation.contributionId !== "follow" || !invocation.chatId) return;
    if (invocation.on) return apply(invocation.chatId, { kind: "follow" }, true);
    return apply(invocation.chatId, { kind: "unfollow" });
  });

  host.send("getSnapshot");
}
