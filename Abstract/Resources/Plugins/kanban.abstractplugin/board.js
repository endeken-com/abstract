"use strict";

// Kanban's board: pure functions over the host snapshot (ABS-84 section 4).
// Nothing here touches the DOM, so the same file is tested outside the app.

var KanbanBoard = (function () {
  var COLUMNS = [
    { key: "needsYou", title: "Needs you", empty: "Nothing needs you." },
    { key: "working", title: "Working", empty: "Nothing is working right now." },
    { key: "readyToReview", title: "Ready to review", empty: "Nothing is waiting for review." },
    { key: "done", title: "Done", empty: "Nothing is done yet." },
  ];

  var STANDALONE_KEY = "__standalone__";
  var STANDALONE_NAME = "Standalone";

  var AGENT_NAMES = {
    claude: "Claude Code",
    codex: "Codex",
    opencode: "OpenCode",
    muse: "Muse Code",
    ollama: "Codex · Ollama",
    lmstudio: "Codex · LM Studio",
  };

  function agentName(agentId) {
    return AGENT_NAMES[agentId] || agentId || "";
  }

  function projectKeyOf(chat) {
    return chat.projectKey == null ? STANDALONE_KEY : chat.projectKey;
  }

  function macById(snapshot) {
    var map = {};
    for (var i = 0; i < (snapshot.macs || []).length; i++) {
      map[snapshot.macs[i].id] = snapshot.macs[i];
    }
    return map;
  }

  // The project choices the filter offers. Same-named projects on different
  // Macs stay apart: their labels name the Mac. Standalone appears when a
  // chat has no project.
  function projectOptions(snapshot) {
    var macs = macById(snapshot);
    var options = [];
    var seen = {};
    function add(key, name, macId) {
      if (seen[key]) return;
      seen[key] = true;
      var mac = macs[macId];
      options.push({
        key: key,
        name: name,
        macId: macId || "",
        macName: mac ? mac.name : "",
        isThisMac: !!(mac && mac.isThisMac),
        standalone: key === STANDALONE_KEY,
      });
    }
    var projects = (snapshot.projects || []).slice().sort(function (a, b) {
      return a.name.localeCompare(b.name);
    });
    for (var i = 0; i < projects.length; i++) add(projects[i].key, projects[i].name, projects[i].macId);
    var chats = snapshot.chats || [];
    for (var j = 0; j < chats.length; j++) {
      if (chats[j].projectKey == null) add(STANDALONE_KEY, STANDALONE_NAME, chats[j].macId);
      else if (!seen[chats[j].projectKey]) add(chats[j].projectKey, "Project", chats[j].macId);
    }
    var nameCounts = {};
    for (var k = 0; k < options.length; k++) nameCounts[options[k].name] = (nameCounts[options[k].name] || 0) + 1;
    for (var m = 0; m < options.length; m++) {
      var o = options[m];
      o.labelIncludesMac = !o.standalone && nameCounts[o.name] > 1 && !!o.macName;
      o.label = o.labelIncludesMac ? o.name + " · " + o.macName : o.name;
    }
    return options;
  }

  function agentOptions(snapshot) {
    var seen = {};
    var options = [];
    var chats = snapshot.chats || [];
    for (var i = 0; i < chats.length; i++) {
      if (!seen[chats[i].agentId]) {
        seen[chats[i].agentId] = true;
        options.push({ key: chats[i].agentId, label: agentName(chats[i].agentId) });
      }
    }
    return options.sort(function (a, b) { return a.label.localeCompare(b.label); });
  }

  function macOptions(snapshot) {
    return (snapshot.macs || []).map(function (mac) {
      return { key: mac.id, label: mac.name, reachable: mac.reachable !== false };
    });
  }

  function emptyFilter() {
    return { projects: [], agents: [], macs: [], search: "", showArchived: false };
  }

  // Saved filters come back as whatever was stored; keep only the shape
  // the board understands.
  function normalizeFilter(raw) {
    var filter = emptyFilter();
    if (!raw || typeof raw !== "object") return filter;
    function strings(value) {
      if (!Array.isArray(value)) return [];
      var out = [];
      for (var i = 0; i < value.length; i++) if (typeof value[i] === "string") out.push(value[i]);
      return out;
    }
    filter.projects = strings(raw.projects);
    filter.agents = strings(raw.agents);
    filter.macs = strings(raw.macs);
    filter.search = typeof raw.search === "string" ? raw.search : "";
    filter.showArchived = raw.showArchived === true;
    return filter;
  }

  function isFilterActive(filter) {
    return (
      filter.projects.length > 0 ||
      filter.agents.length > 0 ||
      filter.macs.length > 0 ||
      filter.search.trim() !== "" ||
      filter.showArchived === true
    );
  }

  // The search box: the chat's title or branch, or its pull request's number.
  function matchesSearch(chat, query) {
    var q = (query || "").trim();
    if (!q) return true;
    var bare = q.charAt(0) === "#" ? q.slice(1) : q;
    if (chat.pullRequest && /^\d+$/.test(bare) && Number(bare) === chat.pullRequest.number) return true;
    var needle = q.toLowerCase();
    if ((chat.title || "").toLowerCase().indexOf(needle) !== -1) return true;
    if (chat.branch && chat.branch.toLowerCase().indexOf(needle) !== -1) return true;
    return false;
  }

  function matchesFilter(chat, filter) {
    if (filter.projects.length && filter.projects.indexOf(projectKeyOf(chat)) === -1) return false;
    if (filter.agents.length && filter.agents.indexOf(chat.agentId) === -1) return false;
    if (filter.macs.length && filter.macs.indexOf(chat.macId) === -1) return false;
    return matchesSearch(chat, filter.search);
  }

  // "now", "12m", "3h", "2d", "5w" — the sidebar's way of saying how long ago.
  function relativeAge(iso, now) {
    var then = Date.parse(iso);
    if (isNaN(then)) return "";
    var seconds = ((now == null ? Date.now() : now) - then) / 1000;
    if (Math.abs(seconds) < 45) return "now";
    var a = Math.abs(seconds);
    var text =
      a < 3600 ? Math.floor(a / 60) + "m" :
      a < 86400 ? Math.floor(a / 3600) + "h" :
      a < 604800 ? Math.floor(a / 86400) + "d" :
      Math.floor(a / 604800) + "w";
    return seconds < 0 ? "in " + text : text;
  }

  // The pull request as one short line. Checks and requested changes only
  // matter while it is open.
  function pullRequestLine(pr) {
    if (!pr) return "";
    var parts = ["#" + pr.number];
    var state = (pr.state || "open").toLowerCase();
    if (state === "open") {
      if (pr.isDraft) parts.push("draft");
      if (pr.checks) parts.push("checks " + pr.checks);
      if (pr.changesRequested) parts.push("changes requested");
    } else {
      parts.push(state);
    }
    return parts.join(" · ");
  }

  function cardFor(chat, projectsByKey, macs, multipleMacs, now) {
    var project = chat.projectKey == null ? null : projectsByKey[chat.projectKey];
    var mac = macs[chat.macId];
    return {
      id: chat.id,
      title: chat.title || "",
      projectKey: projectKeyOf(chat),
      projectName: project ? project.label : STANDALONE_NAME,
      agentId: chat.agentId,
      agentName: agentName(chat.agentId),
      branch: chat.branch || "",
      macId: chat.macId,
      // A disambiguated project label already names its Mac; saying it
      // twice helps nobody.
      macName: multipleMacs && mac && !mac.isThisMac && !(project && project.labelIncludesMac) ? mac.name : "",
      pinned: chat.pinned === true,
      archived: chat.archived === true,
      progress: chat.progress,
      lastActivityAt: chat.lastActivityAt || "",
      age: relativeAge(chat.lastActivityAt, now),
      pullRequest: chat.pullRequest || null,
      pullRequestLine: pullRequestLine(chat.pullRequest),
    };
  }

  // The whole board. Pinned chats stay in their real column; archived chats
  // are hidden unless the filter asks for them.
  function build(snapshot, rawFilter, now) {
    var filter = normalizeFilter(rawFilter);
    var options = projectOptions(snapshot);
    var projectsByKey = {};
    for (var i = 0; i < options.length; i++) projectsByKey[options[i].key] = options[i];
    var macs = macById(snapshot);
    var multipleMacs = (snapshot.macs || []).length > 1;
    var chats = snapshot.chats || [];

    var visible = chats.filter(function (chat) {
      if (chat.archived && !filter.showArchived) return false;
      return matchesFilter(chat, filter);
    });
    visible.sort(function (a, b) {
      var byTime = Date.parse(b.lastActivityAt || 0) - Date.parse(a.lastActivityAt || 0);
      if (byTime !== 0 && !isNaN(byTime)) return byTime;
      return (a.title || "").localeCompare(b.title || "");
    });

    var columns = COLUMNS.map(function (column) {
      var cards = visible
        .filter(function (chat) {
          var key = COLUMNS.some(function (c) { return c.key === chat.progress; }) ? chat.progress : "done";
          return key === column.key;
        })
        .map(function (chat) { return cardFor(chat, projectsByKey, macs, multipleMacs, now); });
      return { key: column.key, title: column.title, empty: column.empty, count: cards.length, cards: cards };
    });

    var unreachableMacs = (snapshot.macs || [])
      .filter(function (mac) { return !mac.isThisMac && mac.reachable === false; })
      .map(function (mac) { return mac.name; });

    var liveChats = chats.filter(function (chat) { return !chat.archived; }).length;
    return {
      columns: columns,
      total: chats.length,
      shown: visible.length,
      archivedCount: chats.length - liveChats,
      emptyKind: chats.length === 0 ? "noChats" : visible.length === 0 ? "noMatches" : null,
      filterActive: isFilterActive(filter),
      unreachableMacs: unreachableMacs,
      projects: options,
      agents: agentOptions(snapshot),
      macs: macOptions(snapshot),
    };
  }

  return {
    COLUMNS: COLUMNS,
    STANDALONE_KEY: STANDALONE_KEY,
    STANDALONE_NAME: STANDALONE_NAME,
    agentName: agentName,
    projectOptions: projectOptions,
    agentOptions: agentOptions,
    macOptions: macOptions,
    emptyFilter: emptyFilter,
    normalizeFilter: normalizeFilter,
    isFilterActive: isFilterActive,
    matchesSearch: matchesSearch,
    relativeAge: relativeAge,
    pullRequestLine: pullRequestLine,
    build: build,
  };
})();

if (typeof module !== "undefined" && module.exports) module.exports = KanbanBoard;
if (typeof window !== "undefined") window.KanbanBoard = KanbanBoard;
