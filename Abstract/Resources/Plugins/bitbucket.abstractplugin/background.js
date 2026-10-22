// Bitbucket Cloud and Data Center's code host. bkt's global --json flag
// wraps results in pull_requests, pull_request, statuses and comments; this
// script maps both API shapes to Abstract's existing pull request contract.
const BitbucketHost = (() => {
  // bkt has no --output flag, though `auth status --help` still shows one.
  const authStatus = ["auth", "status", "--json"];
  const install = "brew install avivsinai/tap/bitbucket-cli";
  const update = "brew upgrade bitbucket-cli";
  let auth = null;
  const value = (object, ...keys) => keys.reduce((part, key) => part == null ? undefined : part[key], object);
  const text = (part) => typeof part === "string" ? part : null;
  const date = (part) => {
    if (part == null || part === "") return null;
    const parsed = new Date(part);
    return Number.isNaN(parsed.getTime()) ? null : parsed.toISOString().replace(/\.\d{3}Z$/, "Z");
  };
  const who = (part) => text(value(part, "user", "name")) || text(part && (part.nickname || part.username || part.display_name || part.name || part.displayName)) || "someone";
  const state = (part) => ({ OPEN: "open", MERGED: "merged", DECLINED: "closed", SUPERSEDED: "closed" })[String(part || "").toUpperCase()] || "open";
  const hostname = (url) => {
    const match = /^[a-z]+:\/\/([^/:]+)/i.exec(String(url || ""));
    return match ? match[1].toLowerCase() : null;
  };
  const matchesRemote = (host, name) => hostname(host.base_url) === name ||
    (host.kind === "cloud" && name === "bitbucket.org" && hostname(host.base_url) === "api.bitbucket.org");

  function hosts(info) {
    return [...new Set((info && info.hosts || []).filter((host) => host.kind === "dc")
      .map((host) => hostname(host.base_url))
      .filter(Boolean))].slice(0, 16);
  }

  function context(info, remote) {
    if (!remote || !info) return null;
    const match = /^(?:\w+:\/\/)?(?:[^@\/]+@)?([^:/]+)(?::\d+)?[:/]/.exec(remote);
    const name = match && match[1].toLowerCase();
    const configured = (info.hosts || []).filter((host) => matchesRemote(host, name));
    if (!configured.length) return null;
    const names = new Set(configured.map((host) => host.key));
    const available = (info.contexts || []).filter((one) => names.has(one.host));
    return available.find((one) => one.active) || available[0] || null;
  }

  function kind(info, remote) {
    const chosen = context(info, remote);
    const host = chosen && (info.hosts || []).find((one) => one.key === chosen.host);
    return host ? host.kind : /bitbucket\.org/i.test(remote || "") ? "cloud" : "dc";
  }

  function repository(remote) {
    const path = String(remote || "").replace(/^[a-z]+:\/\/[^/]+\//i, "")
      .replace(/^[^@/]+@[^:]+:/, "");
    const parts = path.split("/").filter(Boolean);
    if (parts.length < 2) return null;
    const repo = parts[parts.length - 1].replace(/\.git$/, "");
    const group = parts[parts.length - 2];
    return repo && group ? { group, repo } : null;
  }

  function pr(json, deployment) {
    if (!json || !Number.isInteger(json.id) || typeof json.title !== "string") return null;
    const cloud = deployment === "cloud";
    // Reviewers and participants overlap. Cloud's reviewers are bare users
    // and only its participants carry votes; Data Center lists both.
    const votes = new Map();
    for (const one of [...(json.reviewers || []), ...(json.participants || [])]) {
      if (!one || one.role === "AUTHOR") continue;
      const author = who(one.user || one);
      const verdict = one.approved === true || one.state === "approved" ? "approved" :
        one.state === "changes_requested" || one.status === "NEEDS_WORK" ? "changesRequested" : "pending";
      if (verdict === "pending" && (one.role === "PARTICIPANT" || votes.has(author))) continue;
      votes.set(author, verdict);
    }
    const reviews = [...votes].map(([author, verdict]) => ({ author, verdict, body: "", submittedAt: null, association: null }));
    const reviewDecision = reviews.some((one) => one.verdict === "changesRequested") ? "changesRequested" :
      reviews.some((one) => one.verdict === "pending") ? "reviewRequired" :
      reviews.some((one) => one.verdict === "approved") ? "approved" : null;
    const url = cloud ? value(json, "links", "html", "href") : value(json, "links", "self", 0, "href");
    return {
      number: json.id, title: json.title, state: state(json.state), isDraft: json.draft === true,
      url: text(url), head: cloud ? text(value(json, "source", "branch", "name")) || "" : text(value(json, "fromRef", "displayId")) || "",
      base: cloud ? text(value(json, "destination", "branch", "name")) || "" : text(value(json, "toRef", "displayId")) || "",
      author: cloud ? who(json.author) : who(json.author), reviewDecision,
      mergeable: null, mergeState: null, additions: null, deletions: null, changedFiles: null,
      createdAt: date(cloud ? json.created_on : json.createdDate), updatedAt: date(cloud ? json.updated_on : json.updatedDate),
      body: text(cloud ? json.description || value(json, "summary", "raw") : json.description), mergeCommit: null,
      hostTitle: "Bitbucket", mergeMethods: ["squash", "merge", "fastForward"],
      checks: [], reviews, comments: [], threads: [],
    };
  }

  function checks(json) {
    return (json && json.statuses || []).filter((one) => one && (one.key || one.name)).map((one) => {
      const current = String(one.state || "").toUpperCase();
      const outcome = ["SUCCESSFUL", "SUCCESS", "PASSED"].includes(current) ? "passed" :
        ["FAILED", "FAILURE", "ERROR", "STOPPED"].includes(current) ? "failed" :
        current === "SKIPPED" ? "skipped" : "pending";
      return { name: one.name || one.key, workflow: null, outcome, url: text(one.url) };
    });
  }

  function comments(json, deployment) {
    // Data Center nests replies under comments; Cloud returns a flat list.
    const list = [];
    const seen = new Set();
    const collect = (items, parentID = null) => {
      for (const entry of items || []) {
        if (!entry || entry.deleted || seen.has(entry.id)) continue;
        seen.add(entry.id);
        const one = parentID != null && !entry.parent ? { ...entry, parent: { id: parentID } } : entry;
        list.push(one);
        collect(entry.comments, one.id);
      }
    };
    collect(json && json.comments);
    const cloud = deployment === "cloud";
    const parent = (one) => value(one, "parent", "id");
    const anchor = (one) => cloud ? one.inline : one.anchor;
    const message = (one) => cloud ? text(value(one, "content", "raw")) || "" : text(one.text) || "";
    const author = (one) => who(cloud ? one.user : one.author);
    const created = (one) => date(cloud ? one.created_on : one.createdDate);
    const reply = (one) => ({ id: String(one.id), author: author(one), avatar: cloud ? text(value(one, "user", "links", "avatar", "href")) : null,
      body: message(one), createdAt: created(one), url: null, association: null });
    const descendants = (id) => list.filter((child) => parent(child) === id)
      .flatMap((child) => [child, ...descendants(child.id)]);
    const roots = list.filter((one) => !parent(one));
    const threads = roots.filter((one) => anchor(one) && anchor(one).path).map((one) => {
      const location = anchor(one);
      const children = descendants(one.id);
      const line = cloud ? location.to || location.from : location.line;
      return { id: String(one.id), path: location.path, line: Number.isInteger(line) && line > 0 ? line : null,
        originalLine: Number.isInteger(line) && line > 0 ? line : null,
        isResolved: cloud ? !!one.resolution : one.threadResolved === true || one.state === "RESOLVED",
        isOutdated: cloud ? false : location.orphaned === true, diffHunk: null, commit: null,
        comments: [one, ...children].map(reply) };
    });
    const inlineIDs = new Set(threads.flatMap((thread) => thread.comments.map((one) => one.id)));
    return { comments: list.filter((one) => !inlineIDs.has(String(one.id))).map((one) => ({ author: author(one), body: message(one),
      createdAt: created(one), isBot: false, association: null })), threads };
  }

  // An older or newer bkt that lacks a flag or command Abstract uses.
  const outdated = (stderr) => /unknown (?:shorthand )?(?:flag|command)/i.test(stderr || "");
  function failure(out, args) {
    const said = (out.stderr || "").trim();
    if (outdated(said)) {
      const error = new Error(`This bkt doesn't support what Abstract asks of it (${said}). Update it with ${update}.`);
      error.outdated = true;
      return error;
    }
    return new Error(said || `bkt ${args.slice(0, 2).join(" ")} failed.`);
  }
  async function runOK(run, args, where) {
    const out = await run(args, where);
    if (!out.ok) throw failure(out, args);
    return out;
  }
  function parsed(out) {
    try { return JSON.parse(out.stdout); } catch { throw new Error("bkt answered with something Abstract couldn't read."); }
  }
  async function getAuth(run, where) {
    const out = await runOK(run, authStatus, where);
    auth = parsed(out);
    return auth;
  }
  function whereFor(context) { return { projectKey: context.projectKey, chatId: context.chatId, callId: context.callId }; }
  function withContext(args, context) {
    const chosen = context && BitbucketHostContext(context.remote);
    const result = chosen ? args.concat(["--context", chosen.name]) : [...args];
    const target = context && repository(context.remote);
    if (target) result.push(kind(auth, context.remote) === "cloud" ? "--workspace" : "--project", target.group,
                            "--repo", target.repo);
    return result;
  }
  function BitbucketHostContext(remote) { return context(auth, remote); }

  async function list(run, where, context, requestedState, limit) {
    // bkt asks Bitbucket Cloud for --limit pull requests in one page, and
    // Cloud refuses pages over 50 with "Invalid pagelen".
    const wanted = limit || 100;
    const count = kind(auth, context.remote) === "cloud" ? Math.min(wanted, 50) : wanted;
    const args = withContext(["pr", "list", "--state", requestedState, "--limit", String(count), "--json"], context);
    const out = await runOK(run, args, where);
    return (parsed(out).pull_requests || []).map((one) => pr(one, kind(auth, context.remote))).filter(Boolean);
  }
  async function fillChecks(run, where, context, one) {
    if (one.state !== "open") return one;
    const out = await run(withContext(["pr", "checks", String(one.number), "--json"], context), where);
    if (out.ok) one.checks = checks(parsed(out));
    return one;
  }
  async function view(run, where, context, number) {
    const args = withContext(["pr", "view", String(number), "--json"], context);
    const out = await run(args, where);
    if (!out.ok) {
      if (/not found|404/i.test(out.stderr || "")) return null;
      throw failure(out, args);
    }
    const one = pr(parsed(out).pull_request, kind(auth, context.remote));
    if (!one) return null;
    await fillChecks(run, where, context, one);
    const notes = await run(withContext(["pr", "comments", String(number), "--json"], context), where);
    if (notes.ok) one.comments = comments(parsed(notes), kind(auth, context.remote)).comments;
    return one;
  }

  async function answer(op, input, context, run) {
    const where = whereFor(context);
    if (op === "access") {
      let info;
      try { info = await getAuth(run, where); } catch (error) {
        if (error && error.missing) return { access: "missing", install: error.install || install };
        // Not signed out: say what to update instead, without blocking anything.
        if (error && error.outdated) throw error;
        return { access: "signedOut", hint: "bkt auth login" };
      }
      const found = (info.hosts || [])[0];
      return found ? { access: "ready", viewer: found.username || null } : { access: "signedOut", hint: "bkt auth login" };
    }
    if (!auth) await getAuth(run, where);
    const number = () => {
      if (!Number.isInteger(input.number)) throw new Error("That needs a pull request number.");
      return String(input.number);
    };
    switch (op) {
      case "listPullRequests": {
        const all = await list(run, where, context, input.state === "open" ? "OPEN" : "ALL", input.limit);
        // The sidebar needs builds for chat branches. Keep polling bounded:
        // bkt makes one request per PR and the host budgets reads per folder.
        const branches = new Set((input.branches || []).filter((branch) => typeof branch === "string"));
        const candidates = all.filter((entry) => entry.state === "open" && (!branches.size || branches.has(entry.head)));
        for (const one of candidates.slice(0, 12)) await fillChecks(run, where, context, one);
        return { pullRequests: all };
      }
      case "pullRequest": {
        let chosen = input.number;
        if (!Number.isInteger(chosen)) {
          const open = await list(run, where, context, "OPEN", 100);
          chosen = open.find((one) => one.head === input.branch)?.number;
          if (!chosen) return { pullRequest: null };
        }
        return { pullRequest: await view(run, where, context, chosen) };
      }
      case "create": {
        const args = ["pr", "create", "--source", input.branch, "--title", input.title, "--description", input.body || "", "--json"];
        if (input.base) args.push("--target", input.base);
        if (input.draft) args.push("--draft");
        const out = await runOK(run, withContext(args, context), where);
        const created = parsed(out);
        return { pullRequest: await view(run, where, context, created.id) };
      }
      case "merge": {
        const cloud = kind(auth, context.remote) === "cloud";
        const strategy = ({ squash: "squash", merge: cloud ? "merge_commit" : "no-ff",
          fastForward: cloud ? "fast_forward" : "ff" })[input.method];
        if (!strategy) throw new Error("Bitbucket doesn't offer that merge method.");
        const args = ["pr", "merge", number(), "--strategy", strategy];
        if (input.deleteBranch === false) args.push("--close-source=false");
        await runOK(run, withContext(args, context), where);
        return {};
      }
      case "markReady":
        await runOK(run, withContext(["pr", "publish", number()], context), where); return {};
      case "close":
        await runOK(run, withContext(["pr", "decline", number()], context), where); return {};
      case "reviewThreads": {
        const out = await runOK(run, withContext(["pr", "comments", number(), "--json"], context), where);
        return { threads: comments(parsed(out), kind(auth, context.remote)).threads };
      }
      case "searchIssuesAndPullRequests": {
        if (input.kind !== "pullRequest") return { items: [] };
        const query = String(input.query || "").trim();
        const link = /^https?:\/\/[^/]+\/.*\/pull-requests\/(\d+)(?:[/?#]|$)/i.exec(query);
        if (link && context.remote) {
          const remoteHost = /^(?:\w+:\/\/)?(?:[^@\/]+@)?([^:/]+)(?::\d+)?[:/]/.exec(context.remote);
          const remoteRepo = context.remote.split(/[/:]/).pop().replace(/\.git$/, "");
          const linkedRepo = /\/([^/]+)\/pull-requests\/\d+/i.exec(query);
          if (!remoteHost || hostname(query) !== remoteHost[1].toLowerCase() ||
              !linkedRepo || linkedRepo[1] !== remoteRepo) return { items: [] };
        }
        if (/^#?\d+$/.test(query) || link) {
          const one = await view(run, where, context, link ? link[1] : query.replace(/^#/, ""));
          return { items: one ? [{ number: one.number, title: one.title, url: one.url || "", state: one.state.toUpperCase(),
            body: one.body, isPullRequest: true, isDraft: one.isDraft, base: one.base, head: one.head }] : [] };
        }
        const entries = await list(run, where, context, query ? "ALL" : "OPEN", input.limit || 30);
        return { items: entries.filter((one) => !query || one.title.toLowerCase().includes(query.toLowerCase()) || String(one.number) === query)
          .map((one) => ({ number: one.number, title: one.title, url: one.url || "", state: one.state.toUpperCase(),
            body: one.body, isPullRequest: true, isDraft: one.isDraft, base: one.base, head: one.head })) };
      }
      default: throw new Error(`Bitbucket doesn't answer ${op}.`);
    }
  }

  return { authStatus, pr, checks, comments, hosts, context, kind, state, answer };
})();

if (typeof window !== "undefined" && window.AbstractPlugin) {
  const host = window.AbstractPlugin;
  const run = (args, where) => host.cli.run(args, where);
  for (const op of ["access", "listPullRequests", "pullRequest", "create", "merge", "markReady", "close",
                    "reviewThreads", "searchIssuesAndPullRequests"]) {
    host.codeHost.handle(op, (input, context) => BitbucketHost.answer(op, input, context, run));
  }
  run(BitbucketHost.authStatus, {}).then((out) => {
    if (out.ok) {
      try { host.codeHost.setHosts(BitbucketHost.hosts(JSON.parse(out.stdout))); } catch {}
    }
  }, () => {});
}
