// Link status (ABS-126): GitHub pull requests and issues, and Linear
// issues, linked in a chat show how they stand after the link. Abstract
// finds the links and asks for each one while it shows, every five
// minutes; this script reads the status from GitHub or Linear.
//
// `LinkStatus` is plain logic: `lookUp` takes the fetch to use, so tests
// run it over recorded replies. The wiring at the bottom runs only inside
// Abstract.
const LinkStatus = (() => {
  const githubAPI = "https://api.github.com";
  const linearAPI = "https://api.linear.app/graphql";
  const labelLimit = 40;
  const failedConclusions = ["failure", "timed_out", "cancelled", "action_required", "startup_failure"];

  /** What a link points at, or null for any other link. */
  function parse(url) {
    let match = /^https:\/\/github\.com\/([^/]+)\/([^/]+)\/(pull|issues)\/(\d+)$/.exec(String(url || ""));
    if (match) {
      return { kind: match[3] === "pull" ? "pull" : "issue", owner: match[1], repo: match[2], number: Number(match[4]) };
    }
    match = /^https:\/\/linear\.app\/[^/]+\/issue\/([A-Za-z][A-Za-z0-9]*-\d+)$/.exec(String(url || ""));
    if (match) return { kind: "linear", identifier: match[1].toUpperCase() };
    return null;
  }

  function clip(label) {
    return label.length > labelLimit ? label.slice(0, labelLimit - 1) + "…" : label;
  }

  /** The checks on a pull request's head, in a word. */
  function checks(checkRuns) {
    const runs = (checkRuns && checkRuns.check_runs) || [];
    if (!runs.length) return null;
    if (runs.some((run) => failedConclusions.includes(run.conclusion))) return "failing";
    if (runs.some((run) => run.status !== "completed")) return "running";
    return "passed";
  }

  /** A pull request from `GET /repos/…/pulls/n`, with its checks. */
  function pullRequest(pr, checkRuns) {
    if (!pr || typeof pr.state !== "string") return null;
    if (pr.merged || pr.merged_at) return { label: "Merged", tone: "merged" };
    if (pr.state === "closed") return { label: "Closed", tone: "closed" };
    const state = pr.draft ? "Draft" : "Open";
    const tone = pr.draft ? "draft" : "open";
    switch (checks(checkRuns)) {
      case "failing": return { label: `${state} · Checks failing`, tone: "failing" };
      case "running": return { label: `${state} · Checks running`, tone };
      case "passed": return { label: `${state} · Checks passed`, tone };
      default: return { label: state, tone };
    }
  }

  /** An issue from `GET /repos/…/issues/n`, as GitHub colours it. */
  function issue(item) {
    if (!item || typeof item.state !== "string") return null;
    if (item.state === "open") return { label: "Open", tone: "open" };
    if (item.state_reason === "not_planned") return { label: "Closed as not planned", tone: "neutral" };
    return { label: "Closed", tone: "merged" };
  }

  /** A Linear issue from the GraphQL reply: its state and who has it. */
  function linear(reply) {
    const found = reply && reply.data && reply.data.issue;
    if (!found || !found.state || !found.state.name) return null;
    const tones = { started: "open", completed: "merged", canceled: "closed" };
    const tone = tones[found.state.type] || "neutral";
    const assignee = found.assignee && (found.assignee.displayName || found.assignee.name);
    return { label: clip(assignee ? `${found.state.name} · ${assignee}` : found.state.name), tone };
  }

  const linearQuery =
    "query($id: String!) { issue(id: $id) { identifier state { name type } assignee { name displayName } } }";

  /**
   * Asks with the secret first, then without it when it hasn't been
   * entered, so public repositories work with no token.
   */
  async function ask(fetch, url, options, secret) {
    const headers = (options && options.headers) || {};
    const withSecret = secret ? { secretHeaders: { Authorization: { secret: secret.secret, prefix: secret.prefix } } } : {};
    let reply = await fetch(url, Object.assign({}, options, { headers }, withSecret));
    if (secret && secret.optional && !(reply && reply.status)) {
      reply = await fetch(url, Object.assign({}, options, { headers }));
    }
    if (!reply || reply.status !== 200 || reply.bodyIsBase64) return null;
    try { return JSON.parse(reply.body); } catch { return null; }
  }

  const githubHeaders = { Accept: "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28" };
  const githubSecret = { secret: "github-token", prefix: "Bearer ", optional: true };

  /** The status for one link, or null when there's nothing to show. */
  async function lookUp(url, fetch) {
    const target = parse(url);
    if (!target) return null;
    if (target.kind === "linear") {
      const reply = await ask(fetch, linearAPI, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ query: linearQuery, variables: { id: target.identifier } }),
      }, { secret: "linear-api-key", prefix: "" });
      return linear(reply);
    }
    const repo = `${githubAPI}/repos/${target.owner}/${target.repo}`;
    if (target.kind === "issue") {
      const item = await ask(fetch, `${repo}/issues/${target.number}`, { headers: githubHeaders }, githubSecret);
      // GitHub's issue numbers cover pull requests too.
      if (!item || !item.pull_request) return issue(item);
    }
    const pr = await ask(fetch, `${repo}/pulls/${target.number}`, { headers: githubHeaders }, githubSecret);
    if (!pr) return null;
    const open = pr.state === "open" && !pr.merged;
    const sha = pr.head && pr.head.sha;
    const runs = open && sha
      ? await ask(fetch, `${repo}/commits/${sha}/check-runs?per_page=100`, { headers: githubHeaders }, githubSecret)
      : null;
    return pullRequest(pr, runs);
  }

  return { parse, checks, pullRequest, issue, linear, lookUp, labelLimit };
})();

if (typeof window !== "undefined" && window.AbstractPlugin) {
  const host = window.AbstractPlugin;
  const fetch = (url, options) => host.fetch(url, options);
  host.links.decorate("github", (url) => LinkStatus.lookUp(url, fetch));
  host.links.decorate("linear", (url) => LinkStatus.lookUp(url, fetch));
}
