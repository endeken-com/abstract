"use strict";

// Kanban's screen (ABS-86, ABS-134). The board's rules are pure functions
// in board.js; this file draws them with Abstract's plugin kit and wires
// the keyboard: J/K or arrows to move, H/L across, Enter to open, / to
// search, 1–3 for the tabs.

const board = window.KanbanBoard;
const ui = window.AbstractUI;
const h = ui.h;

let snapshot = { macs: [], projects: [], chats: [] };
let loaded = false;
let filter = board.emptyFilter();
let view = "board";
let selectedId = null;
let lastView = null;
let current = null;

const viewEl = document.getElementById("view");
const summaryEl = document.getElementById("summary");
const searchEl = document.getElementById("search");
const filtersEl = document.getElementById("filters");
const unreachableEl = document.getElementById("unreachable");

const tabs = ui.tabs({
  label: "Views",
  style: "segmented",
  selected: view,
  tabs: board.VIEWS.map((v) => ({ id: v.id, label: v.title })),
  onSelect: (id) => setView(id),
});
document.getElementById("tabs").append(tabs.element);

const filterGroups = [
  { key: "projects", title: "Project", options: (built) => built.projects },
  { key: "agents", title: "Agent", options: (built) => built.agents },
  { key: "macs", title: "Mac", options: (built) => built.macs, onlyIfMany: true },
];

function saveFilter() {
  window.AbstractPlugin.send("storage.set", { key: "filters", value: filter });
}

function setView(id) {
  const next = board.normalizeView(id);
  if (next === view) return;
  view = next;
  tabs.select(view);
  window.AbstractPlugin.send("storage.set", { key: "view", value: view });
  render();
}

// ---------- Pieces ----------

function pullRequestBadges(card) {
  const pr = card.pullRequest;
  if (!pr) return [];
  const state = (pr.state || "open").toLowerCase();
  const kind = state === "open" ? (pr.isDraft ? "draft" : "open") : state === "merged" ? "merged" : "closed";
  const words = { open: "Open", draft: "Draft", merged: "Merged", closed: "Closed" };
  const badges = [h("span", { class: "ab-badge ab-pr-" + kind, title: "Pull request #" + pr.number + ": " + words[kind] },
    "#" + pr.number)];
  if (state === "open" && pr.checks) {
    const checks = { passed: ["ab-passed", "Checks pass"], failing: ["ab-failing", "Checks fail"], running: ["ab-running", "Checks running"] }[pr.checks];
    if (checks) badges.push(h("span", { class: "ab-badge " + checks[0] }, h("span", { class: "ab-glyph" }), checks[1]));
  }
  if (state === "open" && pr.changesRequested) badges.push(h("span", { class: "ab-badge ab-outline" }, "Changes requested"));
  return badges;
}

function metaLine(card) {
  return [card.projectName, card.agentName, card.macName].filter(Boolean).join(" · ");
}

function openCard(id) {
  selectedId = id;
  markSelection();
  window.AbstractPlugin.send("openChat", { chatId: id });
}

function cardEl(card) {
  const badges = pullRequestBadges(card);
  const foot = card.branch || badges.length || card.archived
    ? h("span", { class: "card-foot" },
        card.branch ? h("span", { class: "branch ab-mono ab-truncate", title: card.branch }, card.branch) : null,
        badges,
        card.archived ? h("span", { class: "ab-badge ab-outline" }, "Archived") : null)
    : null;
  return h("button", {
    type: "button",
    class: "card ab-card ab-interactive",
    dataset: { key: card.id },
    tabindex: "-1",
    onclick: () => openCard(card.id),
  },
    h("span", { class: "card-top" },
      h("span", { class: "title" }, card.title || "Untitled chat"),
      card.pinned ? h("span", { class: "pin", title: "Pinned", "aria-label": "Pinned" }) : null),
    h("span", { class: "card-meta" },
      h("span", { class: "ab-truncate" }, metaLine(card)),
      card.age ? h("span", { class: "age", title: "Last activity" }, card.age) : null),
    card.subtasksTotal > 0 ? h("span", { class: "card-meta" },
      `${card.subtasksDone} of ${card.subtasksTotal} sub-tasks done`) : null,
    foot);
}

function rowEl(card, progress) {
  return h("button", {
    type: "button",
    class: "row ab-row ab-interactive",
    dataset: { key: card.id },
    tabindex: "-1",
    onclick: () => openCard(card.id),
  },
    h("span", { class: "ab-status ab-" + progress, "aria-hidden": "true" }),
    h("span", { class: "title ab-truncate" },
      (card.parentId ? "↳ " : "") + (card.title || "Untitled chat") +
        (card.subtasksTotal > 0 ? ` · ${card.subtasksDone} of ${card.subtasksTotal} sub-tasks done` : ""),
      card.pinned ? h("span", { class: "pin", title: "Pinned", "aria-label": "Pinned" }) : null),
    h("span", { class: "cell ab-truncate" }, card.projectName),
    h("span", { class: "cell ab-truncate" }, [card.agentName, card.macName].filter(Boolean).join(" · ")),
    h("span", { class: "cell branch ab-mono ab-truncate" }, card.branch || ""),
    h("span", { class: "cell badges" }, pullRequestBadges(card)),
    h("span", { class: "age" }, card.age || ""));
}

function groupHeader(group, tag) {
  return h(tag, { class: tag === "h2" ? "column-header" : "ab-group-header" },
    h("span", { class: "ab-status ab-" + group.key, "aria-hidden": "true" }),
    h("span", null, group.title),
    h("span", { class: "ab-count" }, String(group.count)));
}

// ---------- Views ----------

function renderBoard(groups) {
  const grid = h("div", { class: "board" });
  for (const column of groups) {
    const section = h("section", { class: "column", "aria-label": column.title }, groupHeader(column, "h2"));
    if (column.cards.length === 0) section.append(h("p", { class: "column-empty" }, column.empty));
    else section.append(h("div", { class: "cards" }, column.cards.map(cardEl)));
    grid.append(section);
  }
  return grid;
}

function renderList(groups) {
  const box = h("div", { class: "list" });
  for (const group of groups) {
    box.append(groupHeader(group, "div"), h("div", { class: "rows" }, group.cards.map((card) => rowEl(card, group.key))));
  }
  return box;
}

function emptyFor(built) {
  if (built.emptyKind === "noChats") {
    return ui.empty("No chats yet", "Start a chat and it appears here, in the column for what it needs from you.");
  }
  if (built.emptyKind === "noMatches") {
    return ui.empty("No chats match", "Nothing matches these filters.",
      h("button", { type: "button", class: "ab-button", onclick: clearFilters }, "Clear Filters"));
  }
  if (view === "mine") {
    return ui.empty("Nothing needs you", "Chats waiting on your answer or your review show up here.");
  }
  return null;
}

function renderFilters(built) {
  filtersEl.textContent = "";
  for (const group of filterGroups) {
    const options = group.options(built);
    if (group.onlyIfMany && options.length < 2) continue;
    const chosen = filter[group.key];
    const names = options.filter((o) => chosen.includes(o.key)).map((o) => o.label);
    const chip = h("button", {
      type: "button",
      class: "ab-chip" + (chosen.length ? " ab-active" : ""),
      "aria-haspopup": "menu",
      "aria-expanded": "false",
      onclick: () => openFilter(chip, group, options),
    }, group.title,
      chosen.length ? h("span", { class: "ab-chip-value" }, names.length === 1 ? names[0] : chosen.length + " selected") : null);
    filtersEl.append(chip);
  }
  filtersEl.append(h("button", {
    type: "button",
    class: "ab-chip" + (filter.showArchived ? " ab-active" : ""),
    "aria-pressed": filter.showArchived ? "true" : "false",
    onclick: () => {
      filter.showArchived = !filter.showArchived;
      saveFilter();
      render();
    },
  }, "Archived" + (built.archivedCount ? " " + built.archivedCount : "")));
  if (built.filterActive) {
    filtersEl.append(h("button", { type: "button", class: "ab-button ab-ghost ab-small", onclick: clearFilters }, "Clear"));
  }
}

function openFilter(anchor, group, options) {
  ui.popover(anchor, () => {
    if (!options.length) return h("p", { class: "ab-menu-item ab-tertiary" }, "Nothing to choose yet.");
    return options.map((option) => {
      const item = h("div", {
        class: "ab-menu-item",
        role: "menuitemcheckbox",
        tabindex: "0",
        "aria-checked": filter[group.key].includes(option.key) ? "true" : "false",
      }, h("span", { class: "ab-check", "aria-hidden": "true" }), h("span", { class: "ab-truncate" }, option.label));
      const toggle = () => {
        const selected = new Set(filter[group.key]);
        if (selected.has(option.key)) selected.delete(option.key);
        else selected.add(option.key);
        filter[group.key] = [...selected];
        item.setAttribute("aria-checked", selected.has(option.key) ? "true" : "false");
        saveFilter();
        render();
      };
      item.addEventListener("click", toggle);
      item.addEventListener("keydown", (event) => {
        if (event.key === "Enter" || event.key === " ") { event.preventDefault(); toggle(); }
      });
      return item;
    });
  });
}

function clearFilters() {
  filter = board.emptyFilter();
  searchEl.value = "";
  saveFilter();
  render();
}

function skeleton() {
  const grid = h("div", { class: "board" });
  for (const column of board.COLUMNS) {
    const section = h("section", { class: "column" },
      h("h2", { class: "column-header" }, h("span", { class: "ab-status ab-" + column.key }), h("span", null, column.title)));
    const cards = h("div", { class: "cards" });
    for (let i = 0; i < 2; i++) {
      const card = h("div", { class: "card ab-card" }, h("span", { class: "ab-skeleton" }), h("span", { class: "ab-skeleton" }));
      card.lastChild.style.width = "55%";
      card.lastChild.style.marginTop = "8px";
      cards.append(card);
    }
    section.append(cards);
    grid.append(section);
  }
  return grid;
}

// ---------- Render ----------

function render() {
  if (!loaded) {
    viewEl.textContent = "";
    viewEl.append(skeleton());
    return;
  }
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

  renderFilters(built);
  if (document.activeElement !== searchEl) searchEl.value = filter.search;

  summaryEl.textContent = built.shown === built.total
    ? built.total + (built.total === 1 ? " chat" : " chats")
    : built.shown + " of " + built.total;
  tabs.update(board.VIEWS.map((v) => ({ id: v.id, label: v.title, count: v.id === "mine" ? board.mineCount(built) : null })));

  unreachableEl.hidden = built.unreachableMacs.length === 0;
  if (built.unreachableMacs.length) {
    unreachableEl.textContent =
      built.unreachableMacs.join(", ") +
      (built.unreachableMacs.length === 1 ? " isn't reachable" : " aren't reachable") +
      ", so its chats aren't shown.";
  }

  const groups = board.groups(built, view);
  current = groups;
  if (selectedId && !groups.some((g) => g.cards.some((c) => c.id === selectedId))) selectedId = null;

  const draw = () => {
    viewEl.textContent = "";
    // The Board keeps its columns even when a filter empties some of them.
    const empty = built.emptyKind || (view !== "board" && groups.length === 0) ? emptyFor(built) : null;
    if (empty) {
      viewEl.append(empty);
      return;
    }
    const content = view === "board" ? renderBoard(groups) : renderList(groups);
    viewEl.append(content);
    markSelection();
  };
  // Same view: cards glide to their new column. A new view fades in.
  if (lastView === view) ui.flip(viewEl, draw);
  else {
    draw();
    viewEl.firstChild && viewEl.firstChild.classList.add("ab-tabpanel");
  }
  viewEl.dataset.view = view;
  lastView = view;
}

function markSelection() {
  for (const el of viewEl.querySelectorAll("[data-key]")) {
    const on = el.dataset.key === selectedId;
    el.classList.toggle("ab-selected", on);
    el.setAttribute("aria-current", on ? "true" : "false");
  }
}

function move(direction) {
  if (!current) return;
  const next = board.navigate(current, selectedId, direction, view);
  if (!next) return;
  selectedId = next;
  markSelection();
  ui.reveal(viewEl.querySelector('[data-key="' + CSS.escape(next) + '"]'));
}

// ---------- Input ----------

let searchTimer = null;
searchEl.addEventListener("input", () => {
  filter.search = searchEl.value;
  render();
  clearTimeout(searchTimer);
  searchTimer = setTimeout(saveFilter, 250);
});
searchEl.addEventListener("keydown", (event) => {
  if (event.key === "Escape") {
    event.preventDefault();
    if (searchEl.value) {
      searchEl.value = "";
      filter.search = "";
      saveFilter();
      render();
    } else {
      searchEl.blur();
    }
  } else if (event.key === "ArrowDown" || event.key === "Enter") {
    event.preventDefault();
    searchEl.blur();
    move("first");
  }
});

document.addEventListener("keydown", (event) => {
  if (ui.isTyping(event)) return;
  if (document.querySelector(".ab-popover")) return;
  const action = board.keyAction(event.key, { meta: event.metaKey, ctrl: event.ctrlKey, alt: event.altKey });
  if (!action) return;
  event.preventDefault();
  if (action === "search") {
    searchEl.focus();
    searchEl.select();
  } else if (action === "open") {
    if (selectedId) openCard(selectedId);
  } else if (action === "escape") {
    selectedId = null;
    markSelection();
  } else if (action.indexOf("view:") === 0) {
    setView(action.slice(5));
  } else {
    move(action);
  }
});

window.AbstractPlugin.on("snapshot", (next) => {
  snapshot = next || snapshot;
  loaded = true;
  render();
});
window.AbstractPlugin.on("themeChanged", () => render());

Promise.all([
  window.AbstractPlugin.send("storage.get", { key: "filters" }),
  window.AbstractPlugin.send("storage.get", { key: "view" }),
]).then(([filters, saved]) => {
  filter = board.normalizeFilter(filters && filters.value);
  view = board.normalizeView(saved && saved.value);
  tabs.select(view);
  render();
});
window.AbstractPlugin.send("getSnapshot", {});
render();
