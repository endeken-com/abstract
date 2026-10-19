"use strict";

const board = window.KanbanBoard;

let snapshot = { macs: [], projects: [], chats: [] };
let filter = board.emptyFilter();

const boardEl = document.getElementById("board");
const summaryEl = document.getElementById("summary");
const searchEl = document.getElementById("search");
const emptyEl = document.getElementById("empty");
const unreachableEl = document.getElementById("unreachable");
const clearEl = document.getElementById("clear-filters");
const archivedEl = document.getElementById("show-archived");

const filterGroups = [
  { id: "filter-projects", key: "projects", options: (built) => built.projects, none: "No projects yet." },
  { id: "filter-agents", key: "agents", options: (built) => built.agents, none: "No agents yet." },
  { id: "filter-macs", key: "macs", options: (built) => built.macs, none: "No Macs yet." },
];

function saveFilter() {
  window.AbstractPlugin.send("storage.set", { key: "filters", value: filter });
}

function renderChoices(built) {
  for (const group of filterGroups) {
    const box = document.querySelector("#" + group.id + " .choices");
    const options = group.options(built);
    // Keep the open panel's checkboxes stable while it is being used;
    // a snapshot arriving mid-click must not rebuild it under the pointer.
    const details = document.getElementById(group.id);
    if (details.open) continue;
    box.textContent = "";
    if (options.length === 0) {
      const none = document.createElement("span");
      none.className = "none";
      none.textContent = group.none;
      box.append(none);
      continue;
    }
    for (const option of options) {
      const label = document.createElement("label");
      const input = document.createElement("input");
      input.type = "checkbox";
      input.checked = filter[group.key].includes(option.key);
      input.addEventListener("change", () => {
        const selected = new Set(filter[group.key]);
        if (input.checked) selected.add(option.key);
        else selected.delete(option.key);
        filter[group.key] = [...selected];
        saveFilter();
        render();
      });
      const text = document.createElement("span");
      text.textContent = option.label;
      label.append(input, text);
      box.append(label);
    }
    const summary = details.querySelector("summary");
    const base = group.id === "filter-projects" ? "Projects" : group.id === "filter-agents" ? "Agents" : "Macs";
    summary.textContent = filter[group.key].length ? base + " (" + filter[group.key].length + ")" : base;
  }
}

function renderCard(card) {
  const item = document.createElement("li");
  const button = document.createElement("button");
  button.type = "button";
  button.className = "card";

  const title = document.createElement("span");
  title.className = "title";
  title.textContent = card.title;
  if (card.pinned) {
    const pin = document.createElement("span");
    pin.className = "pin";
    pin.textContent = "Pinned";
    title.append(pin);
  }
  button.append(title);

  const lines = [];
  lines.push([card.projectName, card.agentName, card.macName].filter(Boolean).join(" · "));
  if (card.branch) lines.push(card.branch);
  if (card.pullRequestLine) lines.push(card.pullRequestLine);
  lines.forEach((line, index) => {
    if (!line) return;
    const meta = document.createElement("span");
    meta.className = index === 0 ? "meta" : "meta quiet";
    meta.textContent = line;
    button.append(meta);
  });
  if (card.age) {
    const age = document.createElement("span");
    age.className = "meta quiet";
    age.textContent = "Last activity " + card.age + (card.age === "now" ? "" : " ago");
    button.append(age);
  }
  if (card.archived) {
    const archived = document.createElement("span");
    archived.className = "meta quiet";
    archived.textContent = "Archived";
    button.append(archived);
  }

  button.addEventListener("click", () => {
    window.AbstractPlugin.send("openChat", { chatId: card.id });
  });
  item.append(button);
  return item;
}

function render() {
  const built = board.build(snapshot, filter);

  // A filter choice for something that no longer exists would hide chats
  // for no visible reason, so choices are pruned to what is on offer.
  const pruned = {
    projects: filter.projects.filter((key) => built.projects.some((o) => o.key === key)),
    agents: filter.agents.filter((key) => built.agents.some((o) => o.key === key)),
    macs: filter.macs.filter((key) => built.macs.some((o) => o.key === key)),
  };
  if (JSON.stringify(pruned) !== JSON.stringify({ projects: filter.projects, agents: filter.agents, macs: filter.macs })) {
    Object.assign(filter, pruned);
    saveFilter();
    return render();
  }

  renderChoices(built);
  archivedEl.checked = filter.showArchived;
  if (document.activeElement !== searchEl) searchEl.value = filter.search;
  clearEl.hidden = !built.filterActive;

  summaryEl.textContent =
    built.shown === built.total
      ? built.total + (built.total === 1 ? " chat" : " chats") + ", by what they need from you."
      : "Showing " + built.shown + " of " + built.total + " chats.";

  unreachableEl.hidden = built.unreachableMacs.length === 0;
  if (built.unreachableMacs.length) {
    unreachableEl.textContent =
      built.unreachableMacs.join(", ") +
      (built.unreachableMacs.length === 1 ? " isn't reachable" : " aren't reachable") +
      ", so its chats aren't shown.";
  }

  emptyEl.hidden = built.emptyKind === null;
  if (built.emptyKind === "noChats") emptyEl.textContent = "No chats yet. Start a chat and it will appear here.";
  if (built.emptyKind === "noMatches") emptyEl.textContent = "No chats match these filters. Clear the filters to see them all.";

  boardEl.textContent = "";
  for (const column of built.columns) {
    const section = document.createElement("section");
    section.className = "column";
    const heading = document.createElement("h2");
    heading.textContent = column.title;
    const count = document.createElement("span");
    count.className = "count";
    count.textContent = String(column.count);
    heading.append(count);
    section.append(heading);
    if (column.cards.length === 0) {
      const none = document.createElement("p");
      none.className = "column-empty";
      none.textContent = column.empty;
      section.append(none);
    } else {
      const list = document.createElement("ul");
      for (const card of column.cards) list.append(renderCard(card));
      section.append(list);
    }
    boardEl.append(section);
  }
}

let searchTimer = null;
searchEl.addEventListener("input", () => {
  filter.search = searchEl.value;
  render();
  clearTimeout(searchTimer);
  searchTimer = setTimeout(saveFilter, 250);
});

archivedEl.addEventListener("change", () => {
  filter.showArchived = archivedEl.checked;
  saveFilter();
  render();
});

clearEl.addEventListener("click", () => {
  filter = board.emptyFilter();
  saveFilter();
  render();
});

window.AbstractPlugin.on("snapshot", (next) => {
  snapshot = next || snapshot;
  render();
});
window.AbstractPlugin.on("themeChanged", () => render());

window.AbstractPlugin.send("storage.get", { key: "filters" }).then((reply) => {
  filter = board.normalizeFilter(reply && reply.value);
  render();
});
window.AbstractPlugin.send("getSnapshot", {});
render();
