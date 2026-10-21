"use strict";

// Second opinion's tab beside a chat (ABS-134): where this chat's review
// stands, from what the background script stores. Plain logic, so tests
// run it as is.
const OpinionPanel = (() => {
  const maxRounds = 3;

  /** The review in words, or null when this chat has none. */
  function describe(review) {
    if (!review) return null;
    const agent = review.agentName || "The reviewer";
    const round = Math.min(review.round || 1, maxRounds);
    const lines = {
      reviewing: [`${agent} is reviewing`, `${agent} reads this chat's changes without changing anything. Its findings arrive as comments in Review.`],
      waiting: [`${agent}'s findings are in Review`, "Delete what you don't want, then choose Send All and Re-review in Review."],
      fixing: ["Sent to this chat's agent", `When it finishes, ${agent} reviews the changes again.`],
      done: [`${agent}'s review is over`, round >= maxRounds
        ? `${round} rounds are done. Send what's left in Review yourself.`
        : "Ask again from Review for a new one."],
    }[review.phase] || [`${agent} is reviewing`, ""];
    return {
      agent,
      round,
      rounds: maxRounds,
      phase: review.phase,
      title: lines[0],
      detail: lines[1],
      roundLine: `Round ${round} of ${maxRounds}`,
    };
  }

  return { describe };
})();

if (typeof window !== "undefined") window.OpinionPanel = OpinionPanel;
