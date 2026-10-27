"use strict";

// Pure dashboard calculations over the plugin snapshot and paged data pulls.
var Dashboard = (function () {
  var groups = [
    { key: "needsYou", title: "Needs you" },
    { key: "working", title: "Working" },
    { key: "readyToReview", title: "Ready to review" },
  ];
  var agentNames = { claude: "Claude Code", codex: "Codex", opencode: "OpenCode", muse: "Muse Code" };

  function normalizeFilter(raw) {
    return {
      project: raw && typeof raw.project === "string" ? raw.project : "",
      mac: raw && typeof raw.mac === "string" ? raw.mac : "",
    };
  }

  function projectOptions(snapshot) {
    var projects = (snapshot.projects || []).map(function (project) {
      return { key: project.key, name: project.name, macId: project.macId };
    });
    var names = {};
    projects.forEach(function (project) { names[project.name] = (names[project.name] || 0) + 1; });
    var macs = {};
    (snapshot.macs || []).forEach(function (mac) { macs[mac.id] = mac.name; });
    return projects.map(function (project) {
      return { key: project.key, label: names[project.name] > 1
        ? project.name + " · " + (macs[project.macId] || "Mac") : project.name };
    }).sort(function (a, b) { return a.label.localeCompare(b.label); });
  }

  function matches(chat, filter) {
    if (filter.project && (chat.projectKey || "__standalone__") !== filter.project) return false;
    if (filter.mac && chat.macId !== filter.mac) return false;
    return true;
  }

  function oldest(a, b) {
    return Date.parse(a.lastActivityAt || a.createdAt || 0) - Date.parse(b.lastActivityAt || b.createdAt || 0);
  }

  function localDay(date) {
    var year = date.getFullYear();
    var month = String(date.getMonth() + 1).padStart(2, "0");
    var day = String(date.getDate()).padStart(2, "0");
    return year + "-" + month + "-" + day;
  }

  function build(snapshot, usage, turns, rawFilter, now) {
    var filter = normalizeFilter(rawFilter);
    var today = new Date(now == null ? Date.now() : now);
    var chats = (snapshot.chats || []).filter(function (chat) {
      return !chat.archived && matches(chat, filter);
    });
    var byId = {};
    (snapshot.chats || []).forEach(function (chat) { byId[chat.id] = chat; });
    var cards = groups.map(function (group) {
      var all = chats.filter(function (chat) { return chat.progress === group.key; }).sort(oldest);
      return { key: group.key, title: group.title, count: all.length, chats: all.slice(0, 5) };
    });
    // Monday is the beginning of the current week in the user's local time.
    var weekStart = new Date(today.getFullYear(), today.getMonth(), today.getDate() - (today.getDay() + 6) % 7);
    var doneThisWeek = chats.filter(function (chat) {
      return chat.progress === "done" && Date.parse(chat.lastActivityAt) >= weekStart.getTime();
    }).length;

    var monthStart = new Date(today.getFullYear(), today.getMonth(), 1).getTime();
    var monthEnd = new Date(today.getFullYear(), today.getMonth() + 1, 1).getTime();
    var totals = {};
    (usage || []).forEach(function (entry) {
      var at = Date.parse(entry.at);
      if (!(at >= monthStart && at < monthEnd)) return;
      if (filter.project || filter.mac) {
        var chat = byId[entry.chatId];
        if (!chat || !matches(chat, filter)) return;
      }
      var agent = entry.agentId || "other";
      if (!totals[agent]) totals[agent] = { agentId: agent, name: agentNames[agent] || agent, tokens: 0, cost: 0 };
      totals[agent].tokens += Number(entry.totalTokens) || 0;
      totals[agent].cost += Number(entry.costUsd) || 0;
    });
    var agents = Object.keys(totals).map(function (key) { return totals[key]; })
      .sort(function (a, b) { return b.tokens - a.tokens || a.name.localeCompare(b.name); });
    var usageTotal = agents.reduce(function (sum, agent) { return sum + agent.tokens; }, 0);
    var costTotal = agents.reduce(function (sum, agent) { return sum + agent.cost; }, 0);

    var days = [];
    var dayByKey = {};
    for (var i = 13; i >= 0; i--) {
      var date = new Date(today.getFullYear(), today.getMonth(), today.getDate() - i);
      var day = { date: localDay(date), done: 0, stopped: 0, failed: 0 };
      days.push(day);
      dayByKey[day.date] = day;
    }
    (turns || []).forEach(function (turn) {
      var chat = byId[turn.chatId];
      if ((filter.project || filter.mac) && (!chat || !matches(chat, filter))) return;
      var at = Date.parse(turn.endedAt);
      if (isNaN(at)) return;
      var day = dayByKey[localDay(new Date(at))];
      if (day && Object.prototype.hasOwnProperty.call(day, turn.outcome)) day[turn.outcome]++;
    });
    return { cards: cards, doneThisWeek: doneThisWeek, agents: agents, tokens: usageTotal,
      cost: costTotal, days: days, projects: projectOptions(snapshot), macs: snapshot.macs || [] };
  }

  return { build: build, normalizeFilter: normalizeFilter, projectOptions: projectOptions };
})();

if (typeof module !== "undefined" && module.exports) module.exports = Dashboard;
if (typeof window !== "undefined") window.Dashboard = Dashboard;
