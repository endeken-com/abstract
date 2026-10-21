"use strict";

// Linear's settings page (ABS-141): how it connects, and whether that
// works now. The API key itself is entered above this page, in
// Settings → Plugins, and kept in the keychain.

const ui = window.AbstractUI;
const h = ui.h;
const host = window.AbstractPlugin;
const env = { fetch: (url, options) => host.fetch(url, options) };

const settingsEl = document.getElementById("settings");

function render(access) {
  settingsEl.textContent = "";
  settingsEl.append(h("section", { class: "ab-section" },
    h("h2", { class: "ab-section-title" }, "API key"),
    h("p", { class: "status" },
      "Linear issues are found with a personal API key, entered under Linear in Settings → Plugins. " +
      "It stays in your keychain, and Abstract sends it only to api.linear.app."),
    access === null
      ? ui.skeleton(1)
      : h("p", { class: access.ready ? "status" : "status problem" },
          access.ready ? `Connected as ${access.account}.` : access.problem)));
}

render(null);
LinearTracker.apiKey.access(env.fetch).then(render, (error) => render({ ready: false, problem: String(error) }));
