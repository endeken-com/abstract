// Jira Cloud (ABS-142). The host owns issue search, chips and prompt text;
// this plugin reads Jira through Atlassian's signed-in CLI.
const JiraTracker = (() => {
  const install = "brew install acli";
  const noCLI = `Atlassian's acli isn't installed. Run \`${install}\`, then \`acli jira auth login\`.`;
  const signedOut = "Jira isn't signed in. Run `acli jira auth login` in a terminal, then try again.";
  const keyPattern = /^[A-Za-z][A-Za-z0-9]*-\d+$/;

  function reference(value) {
    const text = String(value || "").trim();
    if (keyPattern.test(text)) return text.toUpperCase();
    const match = /^https:\/\/([a-z0-9][a-z0-9.-]*\.atlassian\.net)\/(?:browse\/|jira\/(?:software|core)\/c\/projects\/[a-z0-9]+\/issues\/)([a-z][a-z0-9]*-\d+)(?:[/?#]\S*)?$/i.exec(text);
    return match ? match[2].toUpperCase() : null;
  }

  function site(value) {
    const match = /^(?:https:\/\/)?([a-z0-9][a-z0-9.-]*\.atlassian\.net)\/?$/i.exec(String(value || "").trim());
    return match ? `https://${match[1].toLowerCase()}` : null;
  }

  function auth(output) {
    const text = String(output || "");
    const foundSite = /^\s*Site:\s*(\S+)/im.exec(text);
    const foundAccount = /^\s*(?:Email|Account):\s*(.+)$/im.exec(text);
    if (!/(?:^|\n)\s*(?:✓\s*)?Authenticated\s*(?:\n|$)/i.test(text) || !foundSite || !site(foundSite[1])) return null;
    return { site: site(foundSite[1]), account: foundAccount ? foundAccount[1].trim() : "Jira account" };
  }

  function failure(output) {
    const line = String((output && (output.stderr || output.stdout)) || "").split("\n").map((part) => part.trim()).find(Boolean);
    return line ? line.replace(/^✗\s*/, "") : "Atlassian's acli didn't answer.";
  }

  async function run(cli, args) {
    let output;
    try { output = await cli(args); }
    catch (error) {
      if (error && error.missing) throw new Error(noCLI);
      throw error;
    }
    if (!output || !output.ok) throw new Error(failure(output));
    return output.stdout;
  }

  async function access(cli) {
    try {
      const connection = auth(await run(cli, ["jira", "auth", "status"]));
      return connection ? { ready: true, site: connection.site, account: connection.account }
                        : { ready: false, problem: signedOut };
    } catch (error) {
      if (error && error.message === noCLI) return { ready: false, problem: noCLI };
      return { ready: false, problem: `${signedOut} ${String(error.message || error)}` };
    }
  }

  async function connection(cli) {
    const result = await access(cli);
    if (!result.ready) throw new Error(result.problem);
    return result;
  }

  function parse(output) {
    try { return JSON.parse(output); }
    catch { throw new Error("Atlassian's acli returned an answer that couldn't be read."); }
  }

  function adf(value) {
    if (typeof value === "string") return value.trim();
    if (!value || typeof value !== "object") return "";
    const lines = [];
    function walk(node) {
      if (!node || typeof node !== "object") return;
      if (node.type === "text") { lines.push(String(node.text || "")); return; }
      if (node.type === "hardBreak") { lines.push("\n"); return; }
      const blocks = new Set(["paragraph", "heading", "listItem", "blockquote", "codeBlock"]);
      if (blocks.has(node.type) && lines.length && !lines[lines.length - 1].endsWith("\n")) lines.push("\n");
      if (Array.isArray(node.content)) node.content.forEach(walk);
      if (blocks.has(node.type)) lines.push("\n");
    }
    walk(value);
    return lines.join("").replace(/[ \t]+\n/g, "\n").replace(/\n{3,}/g, "\n\n").trim();
  }

  function issue(node, base, detail) {
    if (!node || typeof node.key !== "string") return null;
    const fields = node.fields || node;
    const title = fields.summary;
    if (!keyPattern.test(node.key) || typeof title !== "string" || !title.trim()) return null;
    const result = { key: node.key.toUpperCase(), title, url: `${base}/browse/${node.key.toUpperCase()}` };
    const state = fields.status && (fields.status.name || fields.status);
    if (typeof state === "string" && state) result.state = state;
    const assignee = fields.assignee && (fields.assignee.displayName || fields.assignee.name);
    if (assignee) result.assignee = assignee;
    if (detail) {
      const excerpt = adf(fields.description).slice(0, 500);
      if (excerpt) result.excerpt = excerpt;
    }
    return result;
  }

  function projectKey(value) {
    const key = String(value || "").replace(/^project:/, "").toUpperCase();
    return /^[A-Z][A-Z0-9]*$/.test(key) ? key : null;
  }

  function jql(words, project) {
    const scope = projectKey(project);
    const text = String(words || "").trim().replace(/\s+/g, " ");
    // The CLI receives this as one argument, with no shell. Escape JQL's
    // string syntax so quotes cannot add a second clause.
    const escaped = text.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
    const clause = text ? `text ~ "${escaped}"` : "assignee = currentUser() AND resolution = Unresolved";
    return `${scope ? `project = ${scope} AND ` : ""}${clause} ORDER BY updated DESC`;
  }

  async function one(cli, input, base) {
    const link = String(input || "").trim();
    if (/^https:\/\//i.test(link) && !link.toLowerCase().startsWith(`${base}/`)) return null;
    const key = reference(input);
    if (!key) return null;
    let output;
    try { output = await run(cli, ["jira", "workitem", "view", key, "--json"]); }
    catch (error) {
      if (/not found|does not exist|could not be found/i.test(String(error.message || error))) return null;
      throw error;
    }
    return issue(parse(output), base, true);
  }

  async function answer(operation, input, cli) {
    const args = input || {};
    if (operation === "access") return access(cli);
    const connected = await connection(cli);
    if (operation === "issue") return { issue: await one(cli, args.reference, connected.site) };
    if (operation === "searchIssues") {
      const term = String(args.query || "").trim();
      const key = reference(term);
      if (key) {
        const scope = projectKey(args.project);
        if (scope && !key.startsWith(`${scope}-`)) return { issues: [] };
        const found = await one(cli, term, connected.site);
        if (found) delete found.excerpt;
        return { issues: found ? [found] : [] };
      }
      const output = await run(cli, ["jira", "workitem", "search", "--jql", jql(term, args.project), "--limit", "20", "--json"]);
      const data = parse(output);
      const items = Array.isArray(data) ? data : (data.issues || data.workItems || []);
      return { issues: items.slice(0, 20).map((item) => issue(item, connected.site, false)).filter(Boolean) };
    }
    if (operation === "listProjects") {
      const data = parse(await run(cli, ["jira", "project", "list", "--limit", "500", "--json"]));
      const items = Array.isArray(data) ? data : (data.values || data.projects || []);
      return { projects: items.filter((item) => item && item.key && item.name).map((item) => ({
        id: `project:${item.key.toUpperCase()}`, name: item.name, kind: "project", key: item.key.toUpperCase(),
      })) };
    }
    throw new Error(`Jira doesn't answer ${operation}.`);
  }

  return { reference, site, auth, adf, issue, jql, access, answer, noCLI, signedOut };
})();

if (typeof window !== "undefined" && window.AbstractPlugin && window.AbstractPlugin.issueTracker) {
  const host = window.AbstractPlugin;
  host.issueTracker.handle((operation, input) => JiraTracker.answer(operation, input, (args) => host.cli.run(args)));
}
