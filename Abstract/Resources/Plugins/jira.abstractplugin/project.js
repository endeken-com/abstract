"use strict";

// Jira's section in a project's settings (ABS-143): the Jira project this
// Abstract project uses. Abstract saves the pick in this plugin's storage
// under the project, searches it first (`project = KEY`), and tells the
// project's agents ABSTRACT_JIRA_PROJECT. The same page is Jira's settings
// page; the context says which it is.

/** Starts `settings`, or this project's section when placed in one. */
function whenPlaced(settings) {
  let started = false;
  const begin = (context) => {
    if (started) return;
    started = true;
    if (context && context.place === "projectSettings") jiraProjectLink();
    else settings();
  };
  // Abstract sends the context once the page has loaded, and again when
  // the theme changes; only the first starts the page.
  window.AbstractPlugin.on("context", begin);
}

async function jiraProjectLink() {
  const ui = window.AbstractUI;
  const h = ui.h;
  const host = window.AbstractPlugin;
  const el = document.getElementById("settings");
  const show = (...nodes) => { el.textContent = ""; el.append(...nodes); };
  show(ui.skeleton(2));

  let link;
  let found;
  try {
    [link, found] = await Promise.all([
      host.issueTracker.projectLink(),
      JiraTracker.answer("listProjects", {}, (args) => host.cli.run(args)),
    ]);
  } catch (error) {
    show(h("p", { class: "status problem" }, String((error && error.message) || error)));
    return;
  }
  link = link || {};
  const projects = (found && found.projects) || [];

  // One save at a time, each from the link as the last one left it.
  let saving = Promise.resolve();

  function save(project) {
    saving = saving.then(async () => {
      const next = project ? { project: { id: project.id, name: project.name, key: project.key } } : null;
      try {
        link = (await host.issueTracker.setProjectLink(next)) || {};
        draw();
      } catch (error) {
        draw(String((error && error.message) || error));
      }
    });
    return saving;
  }

  function draw(problem) {
    const current = link.project;
    // A saved pick Jira no longer lists stays shown until it's changed.
    const options = current && !projects.some((item) => item.id === current.id) ? [current].concat(projects) : projects;
    const select = h("select", {
      class: "ab-input",
      "aria-label": "Jira project",
      onchange: (event) => save(options.find((item) => item.id === event.target.value) || null),
    },
    h("option", { value: "", selected: !current }, "None"),
    options.map((item) => h("option", { value: item.id, selected: !!current && current.id === item.id },
      `${item.name} (${item.key})`)));
    show(h("section", { class: "ab-section" },
      h("h2", { class: "ab-section-title" }, "Jira project"),
      h("p", { class: "status" }, "The composer's Jira search in this project looks in this project first."),
      select),
    problem ? h("p", { class: "status problem" }, problem) : null);
  }

  draw();
}
