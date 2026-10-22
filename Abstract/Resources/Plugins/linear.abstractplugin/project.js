"use strict";

// Linear's section in a project's settings (ABS-143): the team, and
// optionally the project, this Abstract project uses. Abstract saves the
// pick in this plugin's storage under the project, searches it first, and
// tells the project's agents ABSTRACT_LINEAR_TEAM and ABSTRACT_LINEAR_PROJECT.
// The same page is Linear's settings page; the context says which it is.

/** Starts `settings`, or this project's section when placed in one. */
function whenPlaced(settings) {
  let started = false;
  const begin = (context) => {
    if (started) return;
    started = true;
    if (context && context.place === "projectSettings") linearProjectLink();
    else settings();
  };
  // Abstract sends the context once the page has loaded, and again when
  // the theme changes; only the first starts the page.
  window.AbstractPlugin.on("context", begin);
}

/** `{ id, name, key? }` of a team or project, as the link keeps it. */
function linkTarget(item) {
  if (!item) return undefined;
  const target = { id: item.id, name: item.name };
  if (item.key) target.key = item.key;
  return target;
}

async function linearProjectLink() {
  const ui = window.AbstractUI;
  const h = ui.h;
  const host = window.AbstractPlugin;
  const el = document.getElementById("settings");
  const show = (...nodes) => { el.textContent = ""; el.append(...nodes); };
  show(ui.skeleton(2));

  let link;
  let found;
  try {
    const env = await linearEnvironment(host);
    [link, found] = await Promise.all([
      host.issueTracker.projectLink(),
      LinearTracker.answer("listProjects", {}, env),
    ]);
  } catch (error) {
    show(h("p", { class: "status problem" }, String((error && error.message) || error)));
    return;
  }
  link = link || {};
  const all = (found && found.projects) || [];
  const teams = all.filter((item) => item.kind === "team");
  const projects = all.filter((item) => item.kind === "project");

  // One save at a time, each from the link as the last one left it.
  let saving = Promise.resolve();

  /** Applies `change(link)`, which returns `{ team, project }`, then saves. */
  function save(change) {
    saving = saving.then(async () => {
      const { team, project } = change(link);
      const next = team || project ? { team: linkTarget(team), project: linkTarget(project) } : null;
      try {
        link = (await host.issueTracker.setProjectLink(next)) || {};
        draw();
      } catch (error) {
        draw(String((error && error.message) || error));
      }
    });
    return saving;
  }

  function picker(title, detail, items, current, pick) {
    // A saved pick Linear no longer lists stays shown until it's changed.
    const options = current && !items.some((item) => item.id === current.id) ? [current].concat(items) : items;
    const select = h("select", {
      class: "ab-input",
      "aria-label": title,
      onchange: (event) => pick(options.find((item) => item.id === event.target.value) || null),
    },
    h("option", { value: "", selected: !current }, "None"),
    options.map((item) => h("option", { value: item.id, selected: !!current && current.id === item.id },
      item.key ? `${item.name} (${item.key})` : item.name)));
    return h("section", { class: "ab-section" },
      h("h2", { class: "ab-section-title" }, title),
      h("p", { class: "status" }, detail),
      select);
  }

  function draw(problem) {
    show(
      picker("Team", "The composer's Linear search in this project looks in this team first.",
        // A project picked under another team doesn't carry over.
        teams, link.team, (team) => save((current) => ({
          team,
          project: team && current.team && team.id === current.team.id ? current.project : null,
        }))),
      picker("Project", "Optional: one Linear project, searched instead of the whole team.",
        projects, link.project, (project) => save((current) => ({ team: current.team, project }))),
      problem ? h("p", { class: "status problem" }, problem) : null);
  }

  draw();
}
