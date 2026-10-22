"use strict";

// Linear's settings page (ABS-141): how it connects, and whether that
// works now. An API key is entered above this page, in Settings →
// Plugins, and kept in the keychain; the Linear CLI uses its own sign-in,
// and you pick which of its workspaces to search.

const ui = window.AbstractUI;
const h = ui.h;
const host = window.AbstractPlugin;

const settingsEl = document.getElementById("settings");

let env = null;
let state = null;

async function load() {
  env = await linearEnvironment(host);
  const [key, cli, how] = await Promise.all([
    LinearTracker.apiKey.access(env.fetch),
    LinearTracker.cli.access(env),
    LinearTracker.mode(env),
  ]);
  let workspaces = [];
  try { workspaces = await LinearTracker.cli.workspaces(env); } catch { workspaces = []; }
  const current = LinearTracker.workspace(workspaces, env.settings.workspace);
  state = { key, cli, how, workspaces, workspace: current && current.slug };
  render();
}

async function save(key, value) {
  await host.send("storage.set", { key, value });
  await load();
}

function choice(id, title, detail) {
  const input = h("input", { type: "radio", name: "mode", value: id, checked: state.how === id,
                             onchange: () => save("mode", id) });
  return h("label", { class: "ab-choice" }, input,
    h("span", { class: "ab-choice-text" }, h("strong", null, title), h("span", null, detail)));
}

function render() {
  settingsEl.textContent = "";
  if (!state) { settingsEl.append(ui.skeleton(2)); return; }
  const { key, cli } = state;
  const section = h("section", { class: "ab-section" },
    h("h2", { class: "ab-section-title" }, "How Linear connects"),
    choice("apiKey", "API key",
      key.ready ? `Connected as ${key.account}. The key is entered above and sent only to api.linear.app.`
                : "A personal API key, entered under Linear above. It stays in your keychain and goes only to api.linear.app."
                  + (key.problem && key.problem !== LinearTracker.noKey ? ` ${key.problem}` : "")),
    choice("cli", "Linear CLI",
      cli.ready ? `Signed in as ${cli.account}. Abstract runs linear to read issues and never sees its token.` : cli.problem));
  settingsEl.append(section);

  if (state.how === "cli" && state.workspaces.length > 1) {
    const select = h("select", { class: "ab-input", onchange: (event) => save("workspace", event.target.value) },
      state.workspaces.map((w) => h("option", { value: w.slug, selected: w.slug === state.workspace },
        w.name === w.slug ? w.slug : `${w.name} (${w.slug})`)));
    settingsEl.append(h("section", { class: "ab-section" },
      h("h2", { class: "ab-section-title" }, "Workspace"),
      h("p", { class: "status" }, "The Linear CLI is signed in to several workspaces. Issues are found in this one."),
      select));
  }
}

whenPlaced(() => {
  render();
  load().catch((error) => {
    settingsEl.textContent = "";
    settingsEl.append(h("p", { class: "status problem" }, String((error && error.message) || error)));
  });
});
