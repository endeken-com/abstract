"use strict";

// Follow PR's tab beside a chat (ABS-134): whether the chat follows its
// pull request, what waits to be sent, and what went. Plain logic over
// what the background script stores, so tests run it as is.
const FollowPanel = (() => {
  const KINDS = {
    code: ["code comment", "code comments"],
    changesRequested: ["change request", "change requests"],
    commented: ["review", "reviews"],
    comment: ["comment", "comments"],
    check: ["failed check", "failed checks"],
  };

  /** "2 code comments and 1 failed check". */
  function describeKinds(kinds) {
    const counts = {};
    const order = [];
    for (const kind of kinds || []) {
      if (!(kind in counts)) order.push(kind);
      counts[kind] = (counts[kind] || 0) + 1;
    }
    const parts = order.map((kind) => {
      const words = KINDS[kind] || ["item", "items"];
      return `${counts[kind]} ${counts[kind] === 1 ? words[0] : words[1]}`;
    });
    if (parts.length <= 1) return parts[0] || "Nothing";
    return parts.slice(0, -1).join(", ") + " and " + parts[parts.length - 1];
  }

  /** In words, how long until `at` (ms) from `now`. */
  function until(at, now) {
    const seconds = Math.max(0, Math.round((at - now) / 1000));
    if (seconds < 60) return "in under a minute";
    const minutes = Math.round(seconds / 60);
    return `in ${minutes} min`;
  }

  /**
   * The Following tab for one chat: null when it isn't followed, else its
   * pull request, what's waiting and when it goes, and today's count.
   */
  function following(follow, now, today) {
    if (!follow) return null;
    const pending = (follow.pending || []).length;
    let next = null;
    if (pending) {
      next = follow.waiting
        ? `${describeKinds(follow.pending.map((item) => item.kind))} wait for the agent's turn to end.`
        : `${describeKinds(follow.pending.map((item) => item.kind))} go to the agent ${until(follow.dueAt || now, now)}.`;
    }
    const sentToday = follow.day === today ? follow.sent || 0 : 0;
    return {
      number: follow.number,
      pending,
      next,
      sentToday,
      sentLine: sentToday === 0 ? "Nothing sent today." : sentToday === 1 ? "Sent once today." : `Sent ${sentToday} times today.`,
    };
  }

  /** The History tab: newest first, one line each. */
  function history(entries) {
    return (entries || []).map((entry) => ({
      at: entry.at,
      number: entry.number,
      line: `${describeKinds(entry.kinds)} from PR #${entry.number}`,
    }));
  }

  return { describeKinds, until, following, history };
})();

if (typeof window !== "undefined") window.FollowPanel = FollowPanel;
