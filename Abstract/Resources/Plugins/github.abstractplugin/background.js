// GitHub (ABS-139): Abstract's code host for projects on GitHub. Abstract
// keeps its pull request screens and asks this script for what they show;
// it answers through the GitHub CLI, run by Abstract under the commands
// the manifest lists, in the project's folder or the chat's worktree.
//
// `GitHubHost` is plain logic: `answer` takes the `run` to use, so tests
// run it over recorded `gh` output. The wiring at the bottom runs only
// inside Abstract.
const GitHubHost = (() => {
  const summaryFields = "number,title,state,isDraft,url,headRefName,baseRefName,author,reviewDecision,updatedAt,"
    + "statusCheckRollup,additions,deletions,mergeCommit";
  const detailFields = summaryFields + ",mergeable,mergeStateStatus,changedFiles,createdAt,body,reviews,comments";
  const threadsQuery = `query($owner: String!, $name: String!, $number: Int!) { repository(owner: $owner, name: $name) { pullRequest(number: $number) {
  reviewThreads(first: 100) { nodes { id isResolved isOutdated path line originalLine
    comments(first: 50) { nodes { id author { login avatarUrl } authorAssociation body createdAt url diffHunk originalCommit { oid } } } } } } } }`;
  const verdicts = { APPROVED: "approved", CHANGES_REQUESTED: "changesRequested", COMMENTED: "commented",
                     DISMISSED: "dismissed", PENDING: "pending" };
  const decisions = { APPROVED: "approved", CHANGES_REQUESTED: "changesRequested", REVIEW_REQUIRED: "reviewRequired" };
  const methods = ["squash", "merge", "rebase"];

  const text = (value) => (typeof value === "string" ? value : null);
  const count = (value) => (typeof value === "number" ? value : null);
  const login = (author) => (author && typeof author.login === "string" ? author.login : null);

  /** A check run (Actions) or a commit status (other CI), as one shape. */
  function check(c) {
    if (!c) return null;
    if (typeof c.name === "string") {
      let outcome = "pending";
      if (c.status === "COMPLETED") {
        if (c.conclusion === "SUCCESS" || c.conclusion === "NEUTRAL") outcome = "passed";
        else if (c.conclusion === "SKIPPED" || c.conclusion === "STALE") outcome = "skipped";
        else outcome = "failed";
      }
      return { name: c.name, workflow: text(c.workflowName), outcome, url: text(c.detailsUrl) };
    }
    if (typeof c.context === "string") {
      const outcome = c.state === "SUCCESS" ? "passed" : (c.state === "FAILURE" || c.state === "ERROR") ? "failed" : "pending";
      return { name: c.context, workflow: null, outcome, url: text(c.targetUrl) };
    }
    return null;
  }

  /** A pull request from `gh pr view/list --json`, in Abstract's shape; null without a number and title. */
  function pullRequest(json) {
    if (!json || typeof json.number !== "number" || typeof json.title !== "string") return null;
    return {
      number: json.number,
      title: json.title,
      state: String(json.state || "OPEN").toLowerCase(),
      isDraft: json.isDraft === true,
      url: text(json.url),
      head: text(json.headRefName) || "",
      base: text(json.baseRefName) || "",
      author: login(json.author),
      reviewDecision: decisions[json.reviewDecision] || null,
      mergeable: text(json.mergeable),
      mergeState: text(json.mergeStateStatus),
      additions: count(json.additions),
      deletions: count(json.deletions),
      changedFiles: count(json.changedFiles),
      createdAt: text(json.createdAt),
      updatedAt: text(json.updatedAt),
      body: text(json.body),
      mergeCommit: json.mergeCommit && text(json.mergeCommit.oid),
      checks: (json.statusCheckRollup || []).map(check).filter(Boolean),
      reviews: (json.reviews || []).filter((r) => verdicts[r.state]).map((r) => ({
        author: login(r.author) || "someone", verdict: verdicts[r.state], body: text(r.body) || "",
        submittedAt: text(r.submittedAt), association: text(r.authorAssociation),
      })),
      comments: (json.comments || []).map((c) => {
        const author = login(c.author) || "someone";
        return {
          author, body: text(c.body) || "", createdAt: text(c.createdAt),
          // Apps and bots (Linear, Vercel, CI) post as accounts with no tie to the repo.
          isBot: author.endsWith("[bot]") || c.authorAssociation === "NONE",
          association: text(c.authorAssociation),
        };
      }),
      threads: [],
    };
  }

  /** Review threads from the GraphQL reply, replies in order. */
  function threads(json) {
    const nodes = (((((json || {}).data || {}).repository || {}).pullRequest || {}).reviewThreads || {}).nodes || [];
    return nodes.filter((t) => t && typeof t.id === "string" && typeof t.path === "string").map((t) => {
      const comments = ((t.comments || {}).nodes || []).filter((c) => c && typeof c.id === "string");
      const first = comments[0] || {};
      return {
        id: t.id, path: t.path, line: count(t.line), originalLine: count(t.originalLine),
        isResolved: t.isResolved === true, isOutdated: t.isOutdated === true,
        diffHunk: text(first.diffHunk), commit: first.originalCommit ? text(first.originalCommit.oid) : null,
        comments: comments.map((c) => ({
          id: c.id, author: login(c.author) || "someone", avatar: c.author ? text(c.author.avatarUrl) : null,
          body: text(c.body) || "", createdAt: text(c.createdAt), url: text(c.url), association: text(c.authorAssociation),
        })),
      };
    });
  }

  /** An issue or pull request to attach. */
  function item(json, isPullRequest) {
    if (!json || typeof json.number !== "number" || typeof json.title !== "string") return null;
    return {
      number: json.number, title: json.title, url: text(json.url) || "", state: text(json.state) || "OPEN",
      body: text(json.body), isPullRequest, isDraft: json.isDraft === true,
      base: text(json.baseRefName), head: text(json.headRefName),
    };
  }

  /** "12", "#12" or a github.com link: one item, looked up directly. */
  function directReference(query) {
    if (/^#?\d+$/.test(query)) return query.replace(/^#/, "");
    if (query.startsWith("https://github.com/") && (query.includes("/issues/") || query.includes("/pull/"))) return query;
    return null;
  }

  /** From GitHub's `viewerPermission`: ADMIN, MAINTAIN and WRITE can push. */
  function access(permission) {
    switch (String(permission || "").trim().toUpperCase()) {
      case "ADMIN": case "MAINTAIN": case "WRITE": return "push";
      case "READ": case "TRIAGE": return "readOnly";
      default: return "unknown";
    }
  }

  /** The hosts `gh auth status` says it is signed in to, besides github.com. */
  function signedInHosts(output) {
    const hosts = new Set();
    for (const match of String(output || "").matchAll(/Logged in to ([A-Za-z0-9.-]+)/g)) {
      const host = match[1].toLowerCase().replace(/\.$/, "");
      if (host !== "github.com" && host.includes(".")) hosts.add(host);
    }
    return [...hosts].sort();
  }

  /** The Actions runs a pull request's failed checks belong to. */
  function failedRuns(json) {
    const runs = new Set();
    for (const c of (json && json.statusCheckRollup) || []) {
      const one = check(c);
      const match = one && one.outcome === "failed" && /\/actions\/runs\/(\d+)/.exec(one.url || "");
      if (match) runs.add(match[1]);
    }
    return [...runs];
  }

  function trimmed(value) { return String(value || "").trim(); }

  function parse(out) {
    try { return JSON.parse(out.stdout); } catch { throw new Error("gh answered with something Abstract couldn't read."); }
  }

  /** Runs `args`, throwing gh's own words when it fails. */
  async function ok(run, args, where) {
    const out = await run(args, where);
    if (!out.ok) throw new Error(trimmed(out.stderr) || `gh ${args.slice(0, 2).join(" ")} failed.`);
    return out;
  }

  async function view(run, selector, where) {
    const out = await run(["pr", "view", String(selector), "--json", detailFields], where);
    if (!out.ok) {
      if (/no pull requests found/i.test(out.stderr)) return null;
      throw new Error(trimmed(out.stderr) || "gh pr view failed.");
    }
    return pullRequest(parse(out));
  }

  async function viewer(run, where) {
    const out = await run(["api", "graphql", "-f", "query={ viewer { login } }"], where);
    if (!out.ok) return null;
    try { return JSON.parse(out.stdout).data.viewer.login || null; } catch { return null; }
  }

  async function search(run, input, where) {
    const isPR = input.kind === "pullRequest";
    const kind = isPR ? "pr" : "issue";
    const fields = "number,title,url,state,body" + (isPR ? ",isDraft,baseRefName,headRefName" : "");
    const query = trimmed(input.query);
    const one = directReference(query);
    if (one) {
      const out = await run([kind, "view", one, "--json", fields], where);
      if (!out.ok) return { items: [] };
      const found = item(parse(out), isPR);
      return { items: found ? [found] : [] };
    }
    const filter = query ? ["--state", "all", "--search", query] : ["--state", "open"];
    const out = await run([kind, "list", "--limit", String(input.limit || 30), "--json", fields].concat(filter), where);
    if (!out.ok) {
      if (/git remote/.test(out.stderr)) throw new Error("This project's repository isn't on GitHub.");
      throw new Error(trimmed(out.stderr) || `gh ${kind} list failed.`);
    }
    return { items: (parse(out) || []).map((json) => item(json, isPR)).filter(Boolean) };
  }

  /**
   * One code host operation. `run(args, where)` runs gh and resolves with
   * { ok, code, stdout, stderr }, or throws (with `missing`) when it can't.
   * `context` is { projectKey, chatId, callId }: where the commands run.
   */
  async function answer(op, input, context, run) {
    const where = { projectKey: context.projectKey, chatId: context.chatId, callId: context.callId };
    const number = () => {
      if (typeof input.number !== "number") throw new Error("That needs a pull request number.");
      return String(input.number);
    };
    switch (op) {
      case "access": {
        // On the Mac the chat or project is on: a chat on a paired Mac uses that Mac's sign-in.
        let out;
        try { out = await run(["auth", "status"], where); } catch (error) {
          if (error && error.missing) return { access: "missing", install: error.install || "brew install gh" };
          throw error;
        }
        if (!out.ok) return { access: "signedOut", hint: "gh auth login" };
        return { access: "ready", viewer: await viewer(run, where) };
      }
      case "listPullRequests": {
        const state = input.state === "open" ? "open" : "all";
        const out = await ok(run, ["pr", "list", "--state", state, "--limit", String(input.limit || 100),
                                   "--json", summaryFields], where);
        return { pullRequests: (parse(out) || []).map(pullRequest).filter(Boolean) };
      }
      case "pullRequest":
        return { pullRequest: await view(run, typeof input.number === "number" ? input.number : input.branch, where) };
      case "create": {
        const args = ["pr", "create", "--head", input.branch, "--title", input.title, "--body", input.body || ""];
        if (input.base) args.push("--base", input.base);
        if (input.draft) args.push("--draft");
        await ok(run, args, where);
        return { pullRequest: await view(run, input.branch, where) };
      }
      case "merge": {
        if (!methods.includes(input.method)) throw new Error("GitHub merges by squash, merge or rebase.");
        const args = ["pr", "merge", number(), `--${input.method}`];
        if (input.deleteBranch) args.push("--delete-branch");
        await ok(run, args, where);
        return {};
      }
      case "markReady":
        await ok(run, ["pr", "ready", number()], where);
        return {};
      case "close":
        await ok(run, ["pr", "close", number()], where);
        return {};
      case "updateBranch":
        await ok(run, ["pr", "update-branch", number()], where);
        return {};
      case "rerunFailed": {
        const out = await ok(run, ["pr", "view", number(), "--json", "statusCheckRollup"], where);
        const runs = failedRuns(parse(out));
        if (!runs.length) throw new Error("No failed GitHub Actions runs to run again.");
        for (const id of runs) await ok(run, ["run", "rerun", id, "--failed"], where);
        return {};
      }
      case "reviewThreads": {
        const out = await ok(run, ["api", "graphql", "-F", "owner={owner}", "-F", "name={repo}", "-F", `number=${number()}`,
                                   "-f", `query=${threadsQuery}`], where);
        return { threads: threads(parse(out)) };
      }
      case "pushAccess": {
        const out = await run(["repo", "view", String(input.slug || ""), "--json", "viewerPermission", "--jq", ".viewerPermission"], {});
        return { access: out.ok ? access(out.stdout) : "unknown" };
      }
      case "searchIssuesAndPullRequests":
        return search(run, input, where);
      default:
        throw new Error(`GitHub doesn't answer ${op}.`);
    }
  }

  return { pullRequest, check, threads, item, directReference, access, signedInHosts, failedRuns, answer,
           summaryFields, detailFields };
})();

if (typeof window !== "undefined" && window.AbstractPlugin) {
  const host = window.AbstractPlugin;
  const run = (args, where) => host.cli.run(args, where);
  for (const op of ["access", "listPullRequests", "pullRequest", "create", "merge", "markReady", "close", "reviewThreads",
                    "rerunFailed", "updateBranch", "pushAccess", "searchIssuesAndPullRequests"]) {
    host.codeHost.handle(op, (input, context) => GitHubHost.answer(op, input, context, run));
  }
  // GitHub Enterprise: the hosts gh is signed in to are this plugin's too.
  run(["auth", "status"], {}).then((out) => {
    const hosts = GitHubHost.signedInHosts(out.stdout + "\n" + out.stderr);
    if (hosts.length) host.codeHost.setHosts(hosts);
  }, () => {});
}
