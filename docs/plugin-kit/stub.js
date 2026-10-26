// A stand-in for Abstract's side of the bridge, for the preview only. It
// colours the page at document start, as the host does, from ?theme=.
(function () {
  const params = new URLSearchParams(location.search);
  const themeName = params.get("theme") || "graphite";
  const theme = window.ABSTRACT_THEMES[themeName];
  const root = document.documentElement;
  function apply(payload) {
    for (const name of Object.keys(payload.tokens)) root.style.setProperty("--abstract-" + name, payload.tokens[name]);
    root.style.setProperty("--abstract-font", payload.fontFamily);
    root.style.setProperty("color-scheme", payload.colorScheme);
    root.style.setProperty("background-color", payload.tokens.canvas);
    root.setAttribute("data-abstract-theme", payload.theme);
  }
  apply(theme);

  const plugin = (location.pathname.split("/")[2] || "").replace(".abstractplugin", "");
  const data = window.PREVIEW;
  const store = Object.assign({}, data.storage[plugin] || {});
  for (const pair of (params.get("storage") || "").split(",").filter(Boolean)) {
    const [key, value] = pair.split(":");
    store[key] = JSON.parse(value);
  }
  const listeners = {};
  const emit = (type, payload) => (listeners[type] || []).forEach((fn) => fn(payload));
  const place = params.get("place") || "main";
  const chatId = params.get("chat");
  const context = Object.assign({ place, contributionId: params.get("contribution") || "main", locale: "en_US",
                                  capabilities: [] }, theme);
  if (chatId) {
    context.chatId = chatId;
    context.chat = data.snapshot.chats.find((c) => c.id === chatId);
  }

  window.AbstractPlugin = {
    on(type, fn) { (listeners[type] = listeners[type] || []).push(fn); },
    send(type, payload) {
      const p = payload || {};
      const reply = (value) => new Promise((resolve) => setTimeout(() => resolve(value), 30));
      switch (type) {
        case "getSnapshot":
          setTimeout(() => emit("snapshot", data.snapshot), Number(params.get("delay") || 120));
          return reply({});
        case "storage.get": return reply({ value: store[p.key] === undefined ? null : store[p.key] });
        case "storage.set": store[p.key] = p.value; return reply({ saved: true });
        case "getPermissions": return reply(data.permissions);
        case "openChat": console.log("openChat", p.chatId); return reply({ opened: true });
        default: console.log(type, p); return reply({});
      }
    },
    events: { subscribe() { return Promise.resolve({}); } },
    jobs: { schedule() { return Promise.resolve({}); }, cancel() { return Promise.resolve({}); } },
  };
  // As the host does: once the page has loaded.
  window.addEventListener("load", () => {
    emit("context", context);
    if (params.get("invoke")) emit("invoke", { place: "chatMenu", contributionId: params.get("invoke"), chatId });
  });
})();
