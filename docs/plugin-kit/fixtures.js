// Made-up data for the preview: no real paths, accounts or projects.
(function () {
  const now = Date.now();
  const ago = (minutes) => new Date(now - minutes * 60000).toISOString();
  const chat = (id, title, project, agent, progress, minutes, extra) => Object.assign({
    id, title, projectKey: project, agentId: agent, branch: null, status: "finished", progress,
    pinned: false, archived: false, createdAt: ago(minutes + 600), lastActivityAt: ago(minutes),
    hasChanges: true, backgroundTasks: 0, pullRequest: null, macId: "mac-a",
  }, extra || {});
  const snapshot = {
    revision: 1,
    macs: [
      { id: "mac-a", name: "Desk", isThisMac: true, reachable: true },
      { id: "mac-b", name: "Studio", isThisMac: false, reachable: true },
    ],
    projects: [
      { key: "mac-a:p1", name: "abstract", macId: "mac-a", archived: false },
      { key: "mac-a:p2", name: "payments-api", macId: "mac-a", archived: false },
      { key: "mac-a:p3", name: "marketing-site", macId: "mac-a", archived: false },
      { key: "mac-b:p1", name: "abstract", macId: "mac-b", archived: false },
    ],
    chats: [
      chat("c1", "Retry idempotent webhook deliveries with exponential backoff", "mac-a:p2", "claude", "needsYou", 3,
        { branch: "fix/webhook-retries", status: "waitingInput", pinned: true }),
      chat("c2", "Allow running the migration script", "mac-a:p1", "codex", "needsYou", 12,
        { branch: "feat/sqlite-migrations", status: "waitingInput" }),
      chat("c3", "Add a command palette with fuzzy search", "mac-a:p1", "claude", "working", 1,
        { branch: "feat/command-palette", status: "running" }),
      chat("c4", "Tighten the hero copy and fix layout shift on mobile", "mac-a:p3", "codex", "working", 4,
        { branch: "fix/hero-layout-shift", status: "running" }),
      chat("c5", "Index sessions by worktree for faster lookups", "mac-b:p1", "opencode", "working", 9,
        { branch: "perf/session-index", status: "running", macId: "mac-b" }),
      chat("c6", "Derive chat status from process liveness", "mac-a:p1", "claude", "readyToReview", 35,
        { branch: "fix/status-liveness", pullRequest: { number: 128, state: "open", isDraft: false, checks: "passed", changesRequested: false } }),
      chat("c7", "Localise the checkout flow", "mac-a:p3", "claude", "readyToReview", 80,
        { branch: "feat/i18n-checkout", pullRequest: { number: 131, state: "open", isDraft: false, checks: "failing", changesRequested: true } }),
      chat("c8", "Document the plugin kit", "mac-a:p1", "codex", "readyToReview", 190,
        { branch: "docs/plugin-kit", pullRequest: { number: 133, state: "open", isDraft: true, checks: "running", changesRequested: false } }),
      chat("c9", "Upgrade the payment SDK", "mac-a:p2", "opencode", "done", 1500,
        { branch: "chore/sdk-upgrade", pullRequest: { number: 97, state: "merged", isDraft: false, checks: "passed", changesRequested: false } }),
      chat("c10", "Rename settings keys", null, "claude", "done", 4300, { branch: "chore/settings-keys" }),
      chat("c11", "Old spike: virtualised transcript", "mac-a:p1", "claude", "done", 20000, { archived: true }),
    ],
  };
  const permissions = {
    requests: [
      { chatId: "c1", requestId: "r1", kind: "permission", toolName: "Bash", command: "npm run db:migrate -- --env staging",
        requestedAt: ago(3) },
      { chatId: "c2", requestId: "r2", kind: "permission", toolName: "Edit", path: "Sources/Store/Migrations.swift",
        added: 42, removed: 7, requestedAt: ago(12) },
      { chatId: "c4", requestId: "r3", kind: "question", requestedAt: ago(14), questions: [
        { question: "Which breakpoint should the hero switch layouts at?", multiSelect: false,
          options: [{ label: "640px" }, { label: "768px" }, { label: "1024px" }] },
      ] },
    ],
  };
  const storage = {
    "follow-pr": {
      follows: { c6: { number: 128, seen: [], failing: [], pending: [{ key: "a", kind: "code" }, { key: "b", kind: "check" }],
                       dueAt: now + 70000, waiting: false, day: "", sent: 2 } },
      history: { c6: [
        { at: ago(50), number: 128, count: 3, kinds: ["code", "code", "check"] },
        { at: ago(140), number: 128, count: 1, kinds: ["changesRequested"] },
      ] },
    },
    "second-opinion": {
      reviews: { c6: { agentId: "codex", agentName: "Codex", scope: "uncommitted", reviewerId: "c8", round: 2, phase: "waiting" } },
    },
  };
  window.PREVIEW = { snapshot, permissions, storage };
})();
