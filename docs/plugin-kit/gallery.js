// Draws each kit component once per theme, side by side, for docs/plugins.md.
(function () {
  const h = AbstractUI.h;
  const themes = ["graphite", "paper", "ink"];

  function themed(name) {
    const panel = h("div", { class: "panel", "data-abstract-theme": name });
    const theme = window.ABSTRACT_THEMES[name];
    for (const key of Object.keys(theme.tokens)) panel.style.setProperty("--abstract-" + key, theme.tokens[key]);
    panel.style.setProperty("color-scheme", theme.colorScheme);
    panel.append(h("div", { class: "theme-name" }, name));
    return panel;
  }

  const components = {
    buttons: () => h("div", { class: "line" },
      h("button", { class: "ab-button ab-primary" }, "Allow"),
      h("button", { class: "ab-button" }, "Deny"),
      h("button", { class: "ab-button demo-hover" }, "Hover"),
      h("button", { class: "ab-button ab-ghost" }, "Open Chat"),
      h("button", { class: "ab-button", disabled: true }, "Off"),
      h("span", { class: "ab-kbd" }, "⌘K")),
    inputs: () => h("div", { class: "stack" },
      h("label", { class: "ab-search" }, h("input", { type: "search", placeholder: "Search chats" }), h("span", { class: "ab-kbd" }, "/")),
      h("label", { class: "ab-field" }, h("span", null, "Skill name"), h("input", { class: "ab-input", value: "release-checklist" }))),
    tabs: () => h("div", { class: "stack" },
      AbstractUI.tabs({ style: "segmented", selected: "board", tabs: [
        { id: "board", label: "Board" }, { id: "list", label: "List" }, { id: "mine", label: "Mine", count: 5 }] }).element,
      AbstractUI.tabs({ style: "underline", selected: "waiting", tabs: [
        { id: "waiting", label: "Waiting", count: 3 }, { id: "answered", label: "Answered" }] }).element),
    rows: () => h("ul", { class: "ab-list" },
      h("li", { class: "ab-row" }, h("span", { class: "ab-status ab-needsYou" }), h("span", { class: "ab-row-title" }, "Retry webhook deliveries"), h("span", { class: "ab-row-meta" }, "3m")),
      h("li", { class: "ab-row demo-hover" }, h("span", { class: "ab-status ab-working" }), h("span", { class: "ab-row-title" }, "Hovered row"), h("span", { class: "ab-row-meta" }, "1m")),
      h("li", { class: "ab-row ab-selected" }, h("span", { class: "ab-status ab-readyToReview" }), h("span", { class: "ab-row-title" }, "Selected row"), h("span", { class: "ab-row-meta" }, "35m")),
      h("li", { class: "ab-row demo-focus" }, h("span", { class: "ab-status ab-done" }), h("span", { class: "ab-row-title" }, "Focused row"), h("span", { class: "ab-row-meta" }, "2d"))),
    chips: () => h("div", { class: "line" },
      h("button", { class: "ab-chip" }, "Project"),
      h("button", { class: "ab-chip ab-active" }, "Agent", h("span", { class: "ab-chip-value" }, "Codex")),
      h("button", { class: "ab-chip", "aria-pressed": "true" }, "Archived 1"),
      h("button", { class: "ab-button ab-ghost ab-small" }, "Clear")),
    badges: () => h("div", { class: "stack" },
      h("div", { class: "line" },
        h("span", { class: "ab-status ab-needsYou" }), "Needs you",
        h("span", { class: "ab-status ab-working" }), "Working",
        h("span", { class: "ab-status ab-readyToReview" }), "Review",
        h("span", { class: "ab-status ab-done" }), "Done"),
      h("div", { class: "line" },
        h("span", { class: "ab-badge ab-pr-open" }, "#128"), h("span", { class: "ab-badge ab-pr-draft" }, "#133"),
        h("span", { class: "ab-badge ab-pr-merged" }, "#97"), h("span", { class: "ab-badge ab-pr-closed" }, "#90")),
      h("div", { class: "line" },
        h("span", { class: "ab-badge ab-passed" }, h("span", { class: "ab-glyph" }), "Checks pass"),
        h("span", { class: "ab-badge ab-failing" }, h("span", { class: "ab-glyph" }), "Checks fail"),
        h("span", { class: "ab-badge ab-running" }, h("span", { class: "ab-glyph" }), "Running"),
        h("span", { class: "ab-badge ab-outline" }, "Draft"))),
    cards: () => h("div", { class: "stack" },
      h("div", { class: "ab-card" }, h("strong", null, "Derive chat status"), h("p", { class: "ab-tertiary ab-small" }, "abstract · Claude Code")),
      h("div", { class: "ab-card ab-selected" }, h("strong", null, "Selected card"), h("p", { class: "ab-tertiary ab-small" }, "payments-api · Codex"))),
    choices: () => h("div", { class: "stack" },
      h("label", { class: "ab-choice" }, h("input", { type: "radio", name: "c" + Math.random(), checked: true }),
        h("span", { class: "ab-choice-text" }, h("strong", null, "Project instructions"), h("span", null, "AGENTS.md or CLAUDE.md"))),
      h("label", { class: "ab-choice" }, h("input", { type: "radio", name: "x" + Math.random() }),
        h("span", { class: "ab-choice-text" }, h("strong", null, "A new skill"), h("span", null, "A skill of its own")))),
    menu: () => h("div", { class: "ab-popover demo-popover", role: "menu" },
      h("div", { class: "ab-menu-item", role: "menuitemcheckbox", "aria-checked": "true" }, h("span", { class: "ab-check" }), "abstract"),
      h("div", { class: "ab-menu-item ab-selected", role: "menuitemcheckbox", "aria-checked": "false" }, h("span", { class: "ab-check" }), "payments-api"),
      h("div", { class: "ab-menu-item", role: "menuitemcheckbox", "aria-checked": "false" }, h("span", { class: "ab-check" }), "Standalone")),
    notices: () => h("div", { class: "stack" },
      h("p", { class: "ab-notice" }, "Studio isn't reachable, so its chats aren't shown."),
      h("p", { class: "ab-notice ab-error" }, "That couldn't be answered.")),
    empty: () => AbstractUI.empty("Nothing is waiting for you", "When an agent asks for permission or has a question, it shows up here."),
    skeleton: () => AbstractUI.skeleton(4),
  };

  const gallery = document.getElementById("gallery");
  const only = new URLSearchParams(location.search).get("component");
  for (const name of Object.keys(components)) {
    if (only && only !== name) continue;
    const row = h("section", { class: "component", id: name });
    for (const theme of themes) {
      const panel = themed(theme);
      panel.append(components[name]());
      row.append(panel);
    }
    gallery.append(row);
  }
})();
