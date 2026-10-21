// Linear (ABS-141): Abstract's official Linear plugin. It answers the
// composer's issue search for Linear: whether it can reach Linear, a
// search, one issue by key or link, and your teams and projects.
// Abstract draws the results and writes the line the agent reads; this
// script only finds issues.
//
// It connects one of two ways, picked on its settings page:
//
// - a personal API key, kept in the keychain as the plugin's `api-key`
//   secret and put into requests to api.linear.app by Abstract, so this
//   script never sees it;
// - the Linear CLI (`linear`, https://github.com/schpet/linear-cli),
//   signed in on this Mac, run through the `cli` capability with read
//   commands only. The CLI keeps its own credentials; this script never
//   asks it for a token.
//
// Both give the same answers. `LinearTracker` is plain logic: every call
// takes the fetch, the command runner and the saved settings to use, so
// tests run it over recorded replies and recorded CLI output. The wiring
// at the bottom runs only inside Abstract.
const LinearTracker = (() => {
  const endpoint = "https://api.linear.app/graphql";
  const excerptLimit = 12000;
  const searchLimit = 30;
  // A search lists issues without their descriptions, as the Linear CLI
  // does; Abstract asks for the one you pick, description and all.
  const listFields = "id identifier title url state { name type } assignee { name displayName }";
  const fields = `${listFields} description`;

  const noKey = "Enter your Linear API key in Settings → Plugins → Linear.";
  const refused = "Linear didn't accept this API key. Enter a new one in Settings → Plugins → Linear.";

  /** "ENG-123", or the key in a linear.app issue link; null otherwise. */
  function identifier(reference) {
    const text = String(reference || "").trim();
    if (/^[A-Za-z][A-Za-z0-9]*-\d+$/.test(text)) return text.toUpperCase();
    const match = /^https:\/\/linear\.app\/[^/\s]+\/issue\/([A-Za-z][A-Za-z0-9]*-\d+)(?:[/?#]\S*)?$/.exec(text);
    return match ? match[1].toUpperCase() : null;
  }

  /** One issue in the shape Abstract reads. */
  function issue(node) {
    if (!node || typeof node.identifier !== "string" || typeof node.title !== "string") return null;
    const out = { key: node.identifier, title: node.title, url: node.url || "" };
    if (node.state && node.state.name) out.state = node.state.name;
    const assignee = node.assignee && (node.assignee.displayName || node.assignee.name);
    if (assignee) out.assignee = assignee;
    if (typeof node.description === "string" && node.description.trim()) {
      out.excerpt = node.description.length > excerptLimit ? node.description.slice(0, excerptLimit) : node.description;
    }
    return out;
  }

  function issues(connection) {
    return ((connection && connection.nodes) || []).map(issue).filter(Boolean);
  }

  /**
   * Teams and projects, with ids that say which they are: a team by its
   * key, a project by its id, the same whichever way Linear connects.
   */
  function projects(data) {
    const teams = ((data && data.teams && data.teams.nodes) || [])
      .filter((team) => team && team.key && team.name)
      .map((team) => ({ id: `team:${team.key}`, name: team.name, kind: "team", key: team.key }));
    const found = ((data && data.projects && data.projects.nodes) || [])
      .filter((project) => project && project.id && project.name)
      .map((project) => ({ id: `project:${project.id}`, name: project.name, kind: "project" }));
    return teams.concat(found);
  }

  /** A search's filter for a team or project id from `projects`. */
  function scope(project) {
    const match = /^(team|project):(.+)$/.exec(String(project || ""));
    if (!match) return null;
    return match[1] === "team" ? { team: { key: { eq: match[2] } } } : { project: { id: { eq: match[2] } } };
  }

  // MARK: The API key

  /**
   * One GraphQL request with the key. Resolves to `data`; rejects with a
   * sentence to show. `{ missingKey: true }` when no key is entered.
   */
  async function graphql(fetch, query, variables) {
    const reply = await fetch(endpoint, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      secretHeaders: { Authorization: { secret: "api-key", prefix: "" } },
      body: JSON.stringify({ query, variables: variables || {} }),
    });
    if (!reply || typeof reply.status !== "number") {
      const message = (reply && reply.message) || "";
      if (/secret/i.test(message)) return { missingKey: true };
      throw new Error(message || "Linear couldn't be reached.");
    }
    let json = null;
    try { json = reply.bodyIsBase64 ? null : JSON.parse(reply.body); } catch { json = null; }
    const error = json && json.errors && json.errors[0] && json.errors[0].message;
    if (reply.status === 401 || (error && /auth/i.test(error) && reply.status === 400)) throw new Error(refused);
    if (error) throw new Error(error);
    if (reply.status !== 200 || !json || !json.data) throw new Error(`Linear answered with HTTP ${reply.status}.`);
    return { data: json.data };
  }

  async function data(fetch, query, variables) {
    const reply = await graphql(fetch, query, variables);
    if (reply.missingKey) throw new Error(noKey);
    return reply.data;
  }

  const apiKey = {
    async access(fetch) {
      let reply;
      try {
        reply = await graphql(fetch, "query { viewer { name email } }");
      } catch (error) {
        return { ready: false, problem: String((error && error.message) || error) };
      }
      if (reply.missingKey) return { ready: false, problem: noKey };
      const viewer = reply.data.viewer || {};
      return { ready: true, account: viewer.name || viewer.email || "Linear" };
    },

    async searchIssues(fetch, query, project) {
      const term = String(query || "").trim();
      const filter = scope(project);
      const key = identifier(term);
      if (key) {
        const found = await apiKey.issue(fetch, key);
        if (found) delete found.excerpt;
        return found ? [found] : [];
      }
      if (!term) {
        const open = { state: { type: { nin: ["completed", "canceled"] } } };
        const result = await data(fetch,
          `query($filter: IssueFilter) { viewer { assignedIssues(first: ${searchLimit}, orderBy: updatedAt, filter: $filter) { nodes { ${listFields} } } } }`,
          { filter: Object.assign(open, filter || {}) });
        return issues(result.viewer && result.viewer.assignedIssues);
      }
      const result = await data(fetch,
        `query($term: String!, $filter: IssueFilter) { searchIssues(term: $term, first: ${searchLimit}, filter: $filter) { nodes { ${listFields} } } }`,
        filter ? { term, filter } : { term });
      return issues(result.searchIssues);
    },

    async issue(fetch, reference) {
      const key = identifier(reference);
      if (!key) return null;
      const reply = await graphql(fetch, `query($id: String!) { issue(id: $id) { ${fields} } }`, { id: key })
        .catch((error) => {
          // Linear answers a key it doesn't know with an error, not null.
          if (/not found|could not find|entity not found/i.test(String(error && error.message))) return { data: { issue: null } };
          throw error;
        });
      if (reply.missingKey) throw new Error(noKey);
      return issue(reply.data.issue);
    },

    async listProjects(fetch) {
      const result = await data(fetch, "query { teams(first: 100) { nodes { id name key } } projects(first: 200) { nodes { id name } } }");
      return projects(result);
    },
  };

  // MARK: The Linear CLI

  const install = "brew install schpet/tap/linear";
  const noCLI = `The Linear CLI isn't installed. Install it with \`${install}\`, then run \`linear auth login\`.`;
  const signedOut = "The Linear CLI isn't signed in. Run `linear auth login` in a terminal, then try again.";
  const openStates = ["triage", "backlog", "unstarted", "started"];

  function plain(text) {
    // eslint-disable-next-line no-control-regex
    return String(text || "").replace(/\u001b\[[0-9;]*m/g, "");
  }

  /** The first line the CLI wrote about a failure, without its ✗. */
  function failure(out) {
    const line = plain((out && (out.stderr || out.stdout)) || "").split("\n").map((l) => l.trim()).find(Boolean);
    return line ? line.replace(/^✗\s*/, "") : "The Linear CLI didn't answer.";
  }

  /**
   * `linear auth list`'s table: each workspace's slug and organisation,
   * and which is the default. Who's signed in (names, emails) is left out.
   */
  function workspaces(text) {
    const lines = plain(text).split("\n").filter((line) => line.trim());
    const header = lines.findIndex((line) => /\bWORKSPACE\b/.test(line));
    if (header < 0) return [];
    const orgAt = lines[header].indexOf("ORG NAME");
    const userAt = lines[header].indexOf("USER");
    return lines.slice(header + 1).map((line) => {
      const isDefault = /^\s*\*/.test(line);
      const slug = line.replace(/^\s*\*?\s*/, "").split(/\s+/)[0];
      const name = orgAt >= 0 && userAt > orgAt ? line.slice(orgAt, userAt).trim() : "";
      return { slug, name: name || slug, isDefault };
    }).filter((w) => /^[a-z0-9][a-z0-9-]*$/i.test(w.slug));
  }

  /** `linear auth whoami`: the signed-in person's name. */
  function whoami(text) {
    const match = /^User:\s*(.+)$/m.exec(plain(text));
    return match ? match[1].trim() : null;
  }

  /** `linear team list`'s table: each team's key and name. */
  function teams(text) {
    const lines = plain(text).split("\n").filter((line) => line.trim());
    const header = lines.findIndex((line) => /^\s*KEY\s+NAME\b/.test(line));
    if (header < 0) return [];
    const nameAt = lines[header].indexOf("NAME");
    const after = lines[header].slice(nameAt + 4).search(/\S/);
    const nameEnd = after < 0 ? -1 : nameAt + 4 + after;
    return lines.slice(header + 1).map((line) => {
      const key = line.trim().split(/\s+/)[0];
      const name = (nameEnd > nameAt ? line.slice(nameAt, nameEnd) : line.slice(nameAt)).trim();
      return { key, name };
    }).filter((team) => /^[A-Z0-9]+$/i.test(team.key) && team.name);
  }

  function parseJSON(out) {
    try { return JSON.parse(out.stdout); } catch { throw new Error("The Linear CLI's answer couldn't be read."); }
  }

  /** The workspace to use: the one picked, while the CLI still has it, else its default. */
  function workspace(list, picked) {
    const found = list.find((w) => w.slug === picked);
    if (found) return found;
    return list.find((w) => w.isDefault) || list[0] || null;
  }

  const cli = {
    /** Runs one read command; throws with what the CLI said when it fails. */
    async run(env, args) {
      let out;
      try {
        out = await env.cli(args);
      } catch (error) {
        if (error && error.missing) throw Object.assign(new Error(noCLI), { missing: true });
        throw error;
      }
      if (!out || !out.ok) throw new Error(failure(out));
      return out;
    },

    /** The CLI's workspaces, or why there are none. */
    async workspaces(env) {
      const out = await cli.run(env, ["auth", "list"]);
      return workspaces(out.stdout);
    },

    /** The workspace this plugin uses now. */
    async current(env) {
      const list = await cli.workspaces(env);
      const picked = workspace(list, env.settings && env.settings.workspace);
      if (!picked) throw new Error(signedOut);
      return picked.slug;
    },

    async access(env) {
      try {
        const slug = await cli.current(env);
        const out = await cli.run(env, ["auth", "whoami", "--workspace", slug]);
        const name = whoami(out.stdout);
        if (!name) return { ready: false, problem: signedOut };
        return { ready: true, account: name };
      } catch (error) {
        return { ready: false, problem: String((error && error.message) || error) };
      }
    },

    async searchIssues(env, query, project) {
      const term = String(query || "").trim();
      const key = identifier(term);
      if (key) {
        const found = await cli.issue(env, key);
        if (found) delete found.excerpt;
        return found ? [found] : [];
      }
      const slug = await cli.current(env);
      const args = ["issue", "query", "--workspace", slug];
      const match = /^(team|project):(.+)$/.exec(String(project || ""));
      // What was typed goes as `--search=…`, so it's never read as an option.
      if (match && match[1] === "team") args.push(`--team=${match[2]}`);
      else args.push("--all-teams");
      if (match && match[1] === "project") args.push(`--project=${match[2]}`);
      if (term) args.push(`--search=${term}`);
      else {
        args.push("--assignee", "self");
        for (const state of openStates) args.push("--state", state);
      }
      args.push("--limit", String(searchLimit), "--json", "--no-pager");
      const out = await cli.run(env, args);
      return issues(parseJSON(out));
    },

    async issue(env, reference) {
      const key = identifier(reference);
      if (!key) return null;
      const slug = await cli.current(env);
      let out;
      try {
        out = await cli.run(env, ["issue", "view", key, "--workspace", slug, "--json", "--no-comments", "--no-download", "--no-pager"]);
      } catch (error) {
        if (/could not find|not found/i.test(String(error && error.message))) return null;
        throw error;
      }
      return issue(parseJSON(out));
    },

    async listProjects(env) {
      const slug = await cli.current(env);
      const teamsOut = await cli.run(env, ["team", "list", "--workspace", slug]);
      const projectsOut = await cli.run(env, ["project", "list", "--workspace", slug, "--all-teams", "--json"]);
      const found = parseJSON(projectsOut);
      return projects({ teams: { nodes: teams(teamsOut.stdout) }, projects: { nodes: Array.isArray(found) ? found : found.nodes } });
    },
  };

  // MARK: Choosing

  /**
   * Which way it connects: the one picked on the settings page, else the
   * API key once one is entered, else the CLI once it's signed in.
   */
  async function mode(env) {
    const picked = env.settings && env.settings.mode;
    if (picked === "apiKey" || picked === "cli") return picked;
    if (!env.cli) return "apiKey";
    const key = await apiKey.access(env.fetch);
    if (key.ready || key.problem !== noKey) return "apiKey";
    const signedIn = await cli.access(env);
    return signedIn.ready ? "cli" : "apiKey";
  }

  /**
   * Answers one of Abstract's questions. `env` is `{ fetch, cli, settings }`:
   * the fetch, the command runner (absent without the CLI grant) and the
   * saved `{ mode, workspace }`. The result goes back as `tracker.result`.
   */
  async function answer(operation, input, env) {
    const args = input || {};
    const how = await mode(env);
    if (how === "cli") {
      switch (operation) {
        case "access": return cli.access(env);
        case "searchIssues": return { issues: await cli.searchIssues(env, args.query, args.project) };
        case "issue": return { issue: await cli.issue(env, args.reference) };
        case "listProjects": return { projects: await cli.listProjects(env) };
        default: throw new Error(`Linear doesn't answer ${operation}.`);
      }
    }
    switch (operation) {
      case "access": {
        const access = await apiKey.access(env.fetch);
        // With neither connected, say both ways.
        if (!access.ready && access.problem === noKey && env.cli) {
          return { ready: false, problem: "Enter your Linear API key, or sign in to the Linear CLI, in Settings → Plugins → Linear." };
        }
        return access;
      }
      case "searchIssues": return { issues: await apiKey.searchIssues(env.fetch, args.query, args.project) };
      case "issue": return { issue: await apiKey.issue(env.fetch, args.reference) };
      case "listProjects": return { projects: await apiKey.listProjects(env.fetch) };
      default: throw new Error(`Linear doesn't answer ${operation}.`);
    }
  }

  return {
    identifier, issue, issues, projects, scope, apiKey, cli, mode, answer, workspaces, whoami, teams, workspace,
    noKey, refused, noCLI, signedOut, install,
  };
})();

/** What `LinearTracker` runs with inside Abstract, with the settings as saved now. */
async function linearEnvironment(host) {
  const read = async (key) => {
    const reply = await host.send("storage.get", { key });
    return reply && reply.value !== undefined ? reply.value : null;
  };
  return {
    fetch: (url, options) => host.fetch(url, options),
    cli: host.cli ? (args) => host.cli.run(args) : null,
    settings: { mode: await read("mode"), workspace: await read("workspace") },
  };
}

if (typeof window !== "undefined" && window.AbstractPlugin && window.AbstractPlugin.issueTracker) {
  const host = window.AbstractPlugin;
  host.issueTracker.handle(async (operation, input) => LinearTracker.answer(operation, input, await linearEnvironment(host)));
}
