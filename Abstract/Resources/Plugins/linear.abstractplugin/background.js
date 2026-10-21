// Linear (ABS-141): Abstract's official Linear plugin. It answers the
// composer's issue search for Linear: whether it can reach Linear, a
// search, one issue by key or link, and your teams and projects.
// Abstract draws the results and writes the line the agent reads; this
// script only finds issues.
//
// It connects with a personal API key, kept in the keychain as the
// plugin's `api-key` secret and put into requests to api.linear.app by
// Abstract, so this script never sees it.
//
// `LinearTracker` is plain logic: every call takes the fetch to use, so
// tests run it over recorded replies. The wiring at the bottom runs only
// inside Abstract.
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

  /**
   * Answers one of Abstract's questions. `env` is `{ fetch }`; the result
   * is what goes back as `tracker.result`.
   */
  async function answer(operation, input, env) {
    const args = input || {};
    switch (operation) {
      case "access": return apiKey.access(env.fetch);
      case "searchIssues": return { issues: await apiKey.searchIssues(env.fetch, args.query, args.project) };
      case "issue": return { issue: await apiKey.issue(env.fetch, args.reference) };
      case "listProjects": return { projects: await apiKey.listProjects(env.fetch) };
      default: throw new Error(`Linear doesn't answer ${operation}.`);
    }
  }

  return { identifier, issue, issues, projects, scope, apiKey, answer, noKey, refused };
})();

if (typeof window !== "undefined" && window.AbstractPlugin && window.AbstractPlugin.issueTracker) {
  const host = window.AbstractPlugin;
  const env = { fetch: (url, options) => host.fetch(url, options) };
  host.issueTracker.handle((operation, input) => LinearTracker.answer(operation, input, env));
}
