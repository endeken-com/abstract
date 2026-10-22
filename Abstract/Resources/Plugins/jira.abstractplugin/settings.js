"use strict";

const ui = window.AbstractUI;
const h = ui.h;
const settings = document.getElementById("settings");

whenPlaced(() => JiraTracker.access((args) => window.AbstractPlugin.cli.run(args)).then((connection) => {
  settings.textContent = "";
  settings.append(h("section", { class: "ab-section" },
    h("h2", { class: "ab-section-title" }, "Jira connection"),
    h("p", { class: "status" }, connection.ready
      ? `Connected to ${connection.site} as ${connection.account}. Abstract uses acli to read Jira issues.`
      : connection.problem)));
}).catch((error) => {
  settings.textContent = "";
  settings.append(h("p", { class: "status" }, String(error.message || error)));
}));
