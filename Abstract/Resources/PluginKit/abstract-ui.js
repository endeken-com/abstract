"use strict";

// Abstract's plugin kit (ABS-134): small DOM helpers for the components in
// abstract-ui.css. Link it before your own scripts:
//
//   <script src="/_abstract/abstract-ui.js"></script>
//
// Nothing here talks to the host; it only builds and wires elements.

var AbstractUI = (function () {
  // h("button", { class: "ab-button", onclick: fn }, "Label", child, …)
  function h(tag, props) {
    var el = document.createElement(tag);
    var attrs = props || {};
    for (var key in attrs) {
      var value = attrs[key];
      if (value == null || value === false) continue;
      if (key === "class") el.className = value;
      else if (key === "text") el.textContent = value;
      else if (key === "dataset") for (var d in value) el.dataset[d] = value[d];
      else if (key.indexOf("on") === 0 && typeof value === "function") el.addEventListener(key.slice(2), value);
      else el.setAttribute(key, value === true ? "" : String(value));
    }
    for (var i = 2; i < arguments.length; i++) append(el, arguments[i]);
    return el;
  }

  function append(el, child) {
    if (child == null || child === false) return;
    if (Array.isArray(child)) child.forEach(function (c) { append(el, c); });
    else el.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }

  // A tab strip. `tabs` is [{ id, label, count? }]; arrow keys move between
  // tabs, Home and End jump. Returns { element, select(id), update(tabs) }.
  function tabs(options) {
    var style = options.style || "underline";
    var strip = h("div", {
      class: "ab-tabs" + (style === "underline" ? " ab-underline" : style === "segmented" ? " ab-segmented" : ""),
      role: "tablist",
      "aria-label": options.label || null,
    });
    var selected = options.selected;
    var current = [];

    function render() {
      strip.textContent = "";
      current.forEach(function (tab) {
        var on = tab.id === selected;
        var button = h("button", {
          type: "button",
          class: "ab-tab",
          role: "tab",
          id: "tab-" + tab.id,
          "aria-selected": on ? "true" : "false",
          tabindex: on ? "0" : "-1",
          dataset: { tab: tab.id },
          onclick: function () { choose(tab.id, false); },
        }, tab.label);
        if (tab.count != null) button.append(h("span", { class: "ab-count", text: String(tab.count) }));
        strip.append(button);
      });
    }

    function choose(id, focus) {
      if (id !== selected) {
        selected = id;
        render();
        if (options.onSelect) options.onSelect(id);
      }
      if (focus) {
        var button = strip.querySelector('[data-tab="' + id + '"]');
        if (button) button.focus();
      }
    }

    strip.addEventListener("keydown", function (event) {
      var ids = current.map(function (tab) { return tab.id; });
      var index = ids.indexOf(selected);
      var next = null;
      if (event.key === "ArrowRight") next = ids[(index + 1) % ids.length];
      if (event.key === "ArrowLeft") next = ids[(index - 1 + ids.length) % ids.length];
      if (event.key === "Home") next = ids[0];
      if (event.key === "End") next = ids[ids.length - 1];
      if (next == null) return;
      event.preventDefault();
      choose(next, true);
    });

    function update(next) {
      current = next.slice();
      // Redrawing mustn't take the focus away from a tab being used.
      var focused = strip.contains(document.activeElement);
      render();
      if (focused) {
        var button = strip.querySelector('[data-tab="' + selected + '"]');
        if (button) button.focus();
      }
    }
    update(options.tabs || []);
    return { element: strip, select: function (id) { choose(id, false); }, update: update };
  }

  // An empty state: a quiet mark, a title and a sentence.
  function empty(title, message, action) {
    return h("div", { class: "ab-empty" },
      h("div", { class: "ab-empty-mark", "aria-hidden": "true" }),
      h("p", { class: "ab-empty-title", text: title }),
      message ? h("p", { class: "ab-empty-message", text: message }) : null,
      action || null);
  }

  // Placeholder rows while the first data arrives.
  function skeleton(rows) {
    var box = h("div", { "aria-busy": "true", "aria-label": "Loading" });
    for (var i = 0; i < (rows || 4); i++) {
      box.append(h("div", { class: "ab-skeleton-row" },
        h("span", { class: "ab-skeleton" }),
        h("span", { class: "ab-skeleton" })));
      var bars = box.lastChild.querySelectorAll(".ab-skeleton");
      bars[0].style.width = "14px";
      bars[1].style.width = 30 + ((i * 37) % 45) + "%";
    }
    return box;
  }

  // A popover under `anchor`, built by `build(close)`. Closes on Escape, a
  // click outside, or when `close` is called.
  var openPopover = null;
  function popover(anchor, build) {
    if (openPopover) openPopover.close();
    var box = h("div", { class: "ab-popover", role: "menu" });
    var rect = anchor.getBoundingClientRect();
    box.style.top = rect.bottom + window.scrollY + 4 + "px";
    box.style.left = Math.min(rect.left + window.scrollX, window.innerWidth - 220) + "px";
    function onKey(event) { if (event.key === "Escape") { event.stopPropagation(); close(); } }
    function onClick(event) { if (!box.contains(event.target) && !anchor.contains(event.target)) close(); }
    function close() {
      box.remove();
      document.removeEventListener("keydown", onKey, true);
      document.removeEventListener("mousedown", onClick, true);
      anchor.setAttribute("aria-expanded", "false");
      if (openPopover && openPopover.box === box) openPopover = null;
    }
    append(box, build(close));
    document.body.append(box);
    document.addEventListener("keydown", onKey, true);
    document.addEventListener("mousedown", onClick, true);
    anchor.setAttribute("aria-expanded", "true");
    openPopover = { box: box, close: close };
    return { element: box, close: close };
  }

  // Redraws `container` with `render()`, then slides each child whose
  // data-key was already there from where it was: cards moving between
  // columns glide instead of jumping. New ones rise into place.
  function flip(container, render) {
    var before = {};
    container.querySelectorAll("[data-key]").forEach(function (el) {
      before[el.dataset.key] = el.getBoundingClientRect();
    });
    var hadAny = Object.keys(before).length > 0;
    render();
    if (!hadAny || window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;
    container.querySelectorAll("[data-key]").forEach(function (el) {
      var old = before[el.dataset.key];
      if (!el.animate) return;
      if (!old) {
        el.animate([{ transform: "translateY(4px)" }, { transform: "none" }],
          { duration: 180, easing: "cubic-bezier(0.2, 0.8, 0.2, 1)" });
        return;
      }
      var now = el.getBoundingClientRect();
      var dx = old.left - now.left;
      var dy = old.top - now.top;
      if (Math.abs(dx) < 1 && Math.abs(dy) < 1) return;
      el.animate([{ transform: "translate(" + dx + "px, " + dy + "px)" }, { transform: "none" }],
        { duration: 220, easing: "cubic-bezier(0.2, 0.8, 0.2, 1)" });
    });
  }

  // Whether a key press belongs to a text field rather than the page's
  // own shortcuts.
  function isTyping(event) {
    var target = event.target;
    if (!target || !target.tagName) return false;
    var tag = target.tagName.toLowerCase();
    return tag === "input" || tag === "textarea" || tag === "select" || target.isContentEditable;
  }

  // Keeps the selected element in view without jumping the page.
  function reveal(el) {
    if (el && el.scrollIntoView) el.scrollIntoView({ block: "nearest", inline: "nearest" });
  }

  return { h: h, tabs: tabs, empty: empty, skeleton: skeleton, popover: popover, flip: flip,
           isTyping: isTyping, reveal: reveal };
})();

if (typeof window !== "undefined") window.AbstractUI = AbstractUI;
