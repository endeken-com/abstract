// Second opinion (ABS-112): another agent reviews a chat's changes,
// read-only, in the same worktree. Its findings become comments in the
// chat's Review, marked with its name, for you to send or delete. "Send
// All and Re-review" sends them and asks it again, for three rounds at
// most; after that it's up to you.
//
// `SecondOpinion` is plain logic with no host calls, so tests run it as is.
// The wiring at the bottom runs only inside Abstract.
const SecondOpinion = (() => {
  const maxRounds = 3;
  const maxComments = 50;
  const maxCommentLength = 2000;

  // `path:line — problem — suggestion`, as the prompt asks. Agents add
  // bullets, numbering, bold, backticks, a line range or a plain hyphen.
  const findingPattern =
    /^\s*(?:[-*•]\s+|\d+[.)]\s+)?(?:\*\*)?`?([^\s`*:]+):(\d+)(?:[-–]\d+)?`?(?:\*\*)?\s+(?:—|–|--|-)\s+(.+)$/;
  const separator = /\s+(?:—|–|--)\s+/;

  /** Findings in a reviewer's reply, in order, without repeats. */
  function parseFindings(text) {
    const findings = [];
    const seen = new Set();
    for (const raw of String(text || "").split("\n")) {
      const match = findingPattern.exec(raw);
      if (!match) continue;
      const path = match[1].replace(/^\.\//, "");
      const line = Number(match[2]);
      // Only files in the worktree: Review can't place anything else.
      if (!path || path.startsWith("/") || path.split("/").includes("..") || !(line >= 1)) continue;
      const parts = match[3].split(separator).map((part) => part.trim()).filter(Boolean);
      const problem = parts[0];
      if (!problem) continue;
      const suggestion = parts.slice(1).join(" — ") || null;
      const key = `${path}:${line}:${problem}`;
      if (seen.has(key)) continue;
      seen.add(key);
      findings.push({ path, line, problem, suggestion });
    }
    return findings;
  }

  /** Each finding as a Review comment on its line. */
  function toComments(findings) {
    return findings.slice(0, maxComments).map((finding) => {
      let text = finding.problem;
      if (finding.suggestion) text += `\nSuggestion: ${finding.suggestion}`;
      if (text.length > maxCommentLength) text = text.slice(0, maxCommentLength - 1) + "…";
      return { path: finding.path, line: finding.line, text };
    });
  }

  /** What the reviewer is asked to look at, from what Review compares. */
  function describeScope(scope) {
    const value = String(scope || "uncommitted");
    if (value === "committed") {
      return "the commits on this branch that aren't on the branch it started from";
    }
    const commit = /^commit (\S+)/.exec(value);
    if (commit) return `the commit ${commit[1]} (\`git show ${commit[1]}\`)`;
    return "the uncommitted changes (`git diff HEAD`, and any new files `git status` lists)";
  }

  const format =
    "Report each finding on a line of its own, exactly like this:\n" +
    "path/to/file.ext:42 — what is wrong — what to do instead\n" +
    "The path is relative to the repository root, and the line is the line in the file as it is now. " +
    "Write nothing else on those lines. If nothing needs changing, say “No findings.”";

  function reviewPrompt(scope, chatName) {
    const about = chatName ? ` in “${chatName}”` : "";
    return (
      `Review another agent's work${about}, in this worktree. Don't change any files and don't propose a plan.\n\n` +
      `Review ${describeScope(scope)}. Look for bugs, cases it misses, and anything that doesn't do what ` +
      `the change sets out to do. Skip matters of taste.\n\n` + format
    );
  }

  function reReviewPrompt(scope) {
    return (
      `The author has worked on your findings. Review ${describeScope(scope)} again, as it is now, ` +
      `the same way. Don't repeat findings that were fixed.\n\n` + format
    );
  }

  /**
   * The next step for one reviewed chat. `review` is its stored state or
   * null; `happening` is what just happened. Returns the new state (null
   * to forget it), what to do, and what to tell you.
   *   { kind: "ask", agentId, agentName, scope }
   *   { kind: "reviewerFinished", outcome, found }
   *   { kind: "send" }
   *   { kind: "authorFinished", outcome }
   */
  function step(review, happening) {
    const agent = (review && review.agentName) || "The reviewer";
    switch (happening.kind) {
      case "ask": {
        // Asking again starts over with a new reviewer; the old one's
        // replies are no longer read.
        const next = {
          agentId: happening.agentId, agentName: happening.agentName, scope: happening.scope || "uncommitted",
          reviewerId: null, round: 1, phase: "reviewing",
        };
        return { review: next, effect: { kind: "startReviewer" } };
      }
      case "reviewerFinished": {
        if (!review || review.phase !== "reviewing") return { review };
        if (happening.outcome !== "done") {
          return { review: { ...review, phase: "done" }, notice: `${agent}'s review stopped before it finished.` };
        }
        if (happening.found === 0) {
          return { review: { ...review, phase: "done" }, notice: `${agent} found nothing to change.` };
        }
        const found = `${happening.found} finding${happening.found === 1 ? "" : "s"}`;
        if (review.round >= maxRounds) {
          return {
            review: { ...review, phase: "done" },
            notice: `Round ${review.round}: ${agent}'s ${found} are in Review. That's the last round; send what you choose yourself.`,
          };
        }
        return {
          review: { ...review, phase: "waiting" },
          notice: `${agent}'s ${found} are in Review. Delete what you don't want, then Send All and Re-review.`,
        };
      }
      case "send": {
        if (!review) return { review, notice: "Ask another agent to review this chat first." };
        if (review.phase === "reviewing") return { review, notice: `${agent} is still reviewing.` };
        if (review.phase === "fixing") return { review, notice: "Already sent; waiting for the agent to finish." };
        if (review.phase === "done") {
          return {
            review,
            notice: review.round >= maxRounds
              ? `${review.round} rounds are done. Send what's left in Review yourself.`
              : `${agent}'s review is over. Ask again for a new one.`,
          };
        }
        return { review: { ...review, phase: "fixing" }, effect: { kind: "sendReview" } };
      }
      case "authorFinished": {
        if (!review || review.phase !== "fixing") return { review };
        if (happening.outcome !== "done") {
          return { review: { ...review, phase: "waiting" }, notice: "The agent stopped before it finished; nothing was sent for review." };
        }
        return {
          review: { ...review, round: review.round + 1, phase: "reviewing" },
          effect: { kind: "reReview" },
        };
      }
      default:
        return { review };
    }
  }

  /** The reviewer's last reply: its words since the last message it was sent. */
  function lastReply(items) {
    const words = [];
    for (let i = items.length - 1; i >= 0; i--) {
      const item = items[i];
      if (item.kind === "user") break;
      if (item.kind === "assistant" && item.text) words.unshift(item.text);
    }
    return words.join("\n");
  }

  return { maxRounds, parseFindings, toComments, describeScope, reviewPrompt, reReviewPrompt, step, lastReply };
})();

if (typeof window !== "undefined" && window.AbstractPlugin) {
  const host = window.AbstractPlugin;
  // By reviewed chat id. Kept, so a relaunch carries on where it was.
  let reviews = {};
  let chats = [];
  const loaded = host.send("storage.get", { key: "reviews" }).then((reply) => {
    reviews = (reply && reply.value) || {};
  });

  const save = () => host.send("storage.set", { key: "reviews", value: reviews });
  const notice = (text) => text && host.send("showNotice", { text });
  const chatName = (id) => (chats.find((chat) => chat.id === id) || {}).title;

  host.on("snapshot", (snapshot) => { chats = (snapshot && snapshot.chats) || []; });

  async function apply(chatId, happening) {
    await loaded;
    const result = SecondOpinion.step(reviews[chatId] || null, happening);
    if (result.review) reviews[chatId] = result.review; else delete reviews[chatId];
    await save();
    await notice(result.notice);
    if (result.effect) await perform(chatId, result.effect);
  }

  async function perform(chatId, effect) {
    const review = reviews[chatId];
    if (effect.kind === "startReviewer") {
      const reply = await host.send("createChat", {
        reviewOf: chatId, agentId: review.agentId, policy: "read-only",
        prompt: SecondOpinion.reviewPrompt(review.scope, chatName(chatId)),
      });
      if (reply && reply.chatId) {
        review.reviewerId = reply.chatId;
      } else {
        delete reviews[chatId];
        await notice((reply && reply.message) || "The review couldn't start.");
      }
    } else if (effect.kind === "sendReview") {
      const reply = await host.send("sendReview", { chatId });
      if (!reply || reply.sent !== true) {
        review.phase = "waiting";
        await notice((reply && reply.message) || "Your Review comments couldn't be sent.");
      }
    } else if (effect.kind === "reReview") {
      const reply = await host.send("sendMessage", {
        chatId: review.reviewerId, text: SecondOpinion.reReviewPrompt(review.scope),
      });
      if (!reply || reply.sent !== true) {
        review.phase = "done";
        await notice((reply && reply.message) || `${review.agentName} couldn't be asked again.`);
      }
    }
    await save();
  }

  /** The reviewer's last reply, read back through its transcript. */
  async function readReply(reviewerId) {
    const first = await host.send("getTranscript", { chatId: reviewerId, offset: 0, limit: 1 });
    const total = (first && first.total) || 0;
    if (!total) return null;
    const page = await host.send("getTranscript", { chatId: reviewerId, offset: Math.max(0, total - 200), limit: 200 });
    return SecondOpinion.lastReply((page && page.items) || []);
  }

  async function reviewerFinished(chatId, review, outcome) {
    let found = 0;
    if (outcome === "done") {
      const reply = await readReply(review.reviewerId);
      if (reply === null) {
        reviews[chatId] = { ...review, phase: "done" };
        await save();
        await notice(`Can't read ${review.agentName}'s reply: pick this project for Second opinion in Settings → Plugins.`);
        return;
      }
      const comments = SecondOpinion.toComments(SecondOpinion.parseFindings(reply));
      if (comments.length) {
        const added = await host.send("addReviewComments", { chatId, author: review.agentName, comments });
        found = (added && added.added) || 0;
      }
    }
    await apply(chatId, { kind: "reviewerFinished", outcome, found });
  }

  host.events.subscribe(["turn.finished"], async (event) => {
    await loaded;
    for (const [chatId, review] of Object.entries(reviews)) {
      if (review.reviewerId === event.chatId) return reviewerFinished(chatId, review, event.outcome);
      if (chatId === event.chatId) return apply(chatId, { kind: "authorFinished", outcome: event.outcome });
    }
  });

  host.on("invoke", (invocation) => {
    if (!invocation || invocation.place !== "review" || !invocation.chatId) return;
    if (invocation.contributionId === "ask") {
      return apply(invocation.chatId, {
        kind: "ask", agentId: invocation.agentId, agentName: invocation.agentName, scope: invocation.scope,
      });
    }
    if (invocation.contributionId === "send") return apply(invocation.chatId, { kind: "send" });
  });

  host.send("getSnapshot");
}
