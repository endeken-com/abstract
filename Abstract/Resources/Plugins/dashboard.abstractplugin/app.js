"use strict";

const host = window.AbstractPlugin;
const ui = window.AbstractUI;
const h = ui.h;
const content = document.getElementById("content");
const projectSelect = document.getElementById("project");
const macSelect = document.getElementById("mac");
let snapshot = null;
let usage = null;
let turns = null;
let filter = Dashboard.normalizeFilter();
let home = false;
let refreshTimer = null;
let loading = false;
let loadError = "";

function money(value) {
  return new Intl.NumberFormat(undefined, { style: "currency", currency: "USD", maximumFractionDigits: 2 }).format(value);
}

function number(value) {
  return new Intl.NumberFormat().format(value);
}

function open(chat) {
  host.send("openChat", { chatId: chat.id });
}

function pick(select, allLabel, options, selected) {
  select.textContent = "";
  select.append(h("option", { value: "" }, allLabel));
  for (const option of options) select.append(h("option", { value: option.key }, option.label));
  if (selected && options.some((option) => option.key === selected)) select.value = selected;
  else select.value = "";
  return select.value;
}

function chatList(card) {
  if (!card.chats.length) return h("p", { class: "empty ab-tertiary" }, "Nothing here.");
  return h("ul", { class: "chat-list ab-list" }, card.chats.map((chat) => h("li", null,
    h("button", { type: "button", class: "chat ab-row ab-interactive", onclick: () => open(chat) },
      h("span", { class: "ab-status ab-" + card.key, "aria-hidden": "true" }),
      h("span", { class: "ab-row-title ab-truncate" }, chat.title || "Untitled chat")))));
}

function render() {
  if (!snapshot) {
    content.textContent = "";
    content.append(ui.skeleton(4));
    return;
  }
  if (!home) {
    filter.project = pick(projectSelect, "All projects", Dashboard.projectOptions(snapshot).concat(
      (snapshot.chats || []).some((chat) => !chat.projectKey) ? [{ key: "__standalone__", label: "Standalone" }] : []), filter.project);
    filter.mac = pick(macSelect, "All Macs", (snapshot.macs || []).map((mac) => ({ key: mac.id, label: mac.name })), filter.mac);
  }
  const built = Dashboard.build(snapshot, usage, turns, filter);
  content.textContent = "";
  if (loadError && !home) content.append(h("p", { class: "ab-notice" }, loadError));
  const counts = h("div", { class: "counts" }, built.cards.map((card) => h("section", { class: "count ab-card" },
    h("span", { class: "count-heading" }, h("span", { class: "ab-status ab-" + card.key }), card.title),
    h("strong", null, number(card.count)),
    home ? null : chatList(card))));
  counts.append(h("section", { class: "count ab-card" },
    h("span", { class: "count-heading" }, "Done this week"),
    h("strong", null, number(built.doneThisWeek))));
  content.append(counts);
  if (home) return;

  const usageSection = h("section", { class: "section" },
    h("h2", null, "This month"),
    h("p", { class: "headline" }, number(built.tokens) + " tokens · " + money(built.cost)),
    h("p", { class: "ab-tertiary ab-small" }, "Cost uses the same figures as Settings → Usage."));
  if (usage === null) usageSection.append(h("p", { class: "ab-tertiary" }, "Loading usage…"));
  else if (!built.agents.length) usageSection.append(h("p", { class: "ab-tertiary" }, "No usage this month."));
  else usageSection.append(h("div", { class: "agents" }, built.agents.map((agent) => h("div", { class: "agent ab-card" },
    h("span", null, agent.name), h("strong", null, number(agent.tokens) + " tokens"),
    h("span", { class: "ab-tertiary" }, money(agent.cost))))));
  content.append(usageSection);

  const history = h("section", { class: "section" }, h("h2", null, "Last 14 days"));
  if (turns === null) history.append(h("p", { class: "ab-tertiary" }, "Loading turn history…"));
  else {
    const max = Math.max(1, ...built.days.map((day) => day.done + day.stopped + day.failed));
    const chart = h("div", { class: "chart", role: "img", "aria-label": "Turns per day, split by outcome" });
    for (const day of built.days) {
      const total = day.done + day.stopped + day.failed;
      const stack = h("div", { class: "stack", title: day.date + ": " + day.done + " done, " + day.stopped + " stopped, " + day.failed + " failed" });
      for (const outcome of ["done", "stopped", "failed"]) {
        if (day[outcome]) {
          const bar = h("span", { class: "bar " + outcome });
          bar.style.height = (100 * day[outcome] / max) + "%";
          stack.append(bar);
        }
      }
      chart.append(h("div", { class: "day" }, stack, h("span", { class: "day-label" }, day.date.slice(5))));
    }
    history.append(chart, h("p", { class: "legend ab-tertiary ab-small" },
      h("span", { class: "dot done" }), "Done", h("span", { class: "dot stopped" }), "Stopped",
      h("span", { class: "dot failed" }), "Failed"));
  }
  content.append(history);
  if (built.macs.some((mac) => !mac.isThisMac)) {
    content.append(h("p", { class: "ab-notice ab-small" },
      "Chat counts include paired Macs. Usage and turn history come from this Mac."));
  }
}

async function pages(type, payload, stop) {
  const items = [];
  for (let offset = 0; ; offset += 200) {
    const page = await host.send(type, { ...payload, offset, limit: 200 });
    const rows = page && Array.isArray(page.items) ? page.items : [];
    items.push(...rows);
    if (!page || !page.hasMore || !rows.length || (stop && rows.some(stop))) break;
  }
  return items;
}

async function refresh() {
  if (home || loading) return;
  loading = true;
  try {
    const firstOfMonth = new Date(new Date().getFullYear(), new Date().getMonth(), 1).getTime();
    const [usageRows, turnRows] = await Promise.all([
      pages("getUsage", { view: "entries" }, (row) => Date.parse(row.at) < firstOfMonth),
      pages("getTurns", {}),
    ]);
    usage = usageRows;
    turns = turnRows;
    loadError = "";
  } catch (error) {
    loadError = "Dashboard data could not be loaded. " + String(error.message || error);
  } finally {
    loading = false;
    render();
  }
}

function scheduleRefresh() {
  clearTimeout(refreshTimer);
  refreshTimer = setTimeout(refresh, 1000);
}

for (const select of [projectSelect, macSelect]) select.addEventListener("change", () => {
  filter = { project: projectSelect.value, mac: macSelect.value };
  host.send("storage.set", { key: "filters", value: filter });
  render();
});

host.on("context", (context) => {
  home = context && context.place === "home";
  document.body.classList.toggle("home", home);
  render();
  if (!home) scheduleRefresh();
});
host.on("snapshot", (next) => {
  snapshot = next;
  render();
  scheduleRefresh();
});
Promise.resolve(host.send("storage.get", { key: "filters" })).then((reply) => {
  filter = Dashboard.normalizeFilter(reply && reply.value);
  render();
});
host.send("getSnapshot", {});
setInterval(refresh, 60 * 1000);
render();
