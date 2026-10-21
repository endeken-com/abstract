// Approvals in the background (ABS-111): keeps the sidebar row's count
// right with the screen closed. Events move it at once; a pull of what's
// waiting follows each, and is what the count settles on.
//
// The queue's rules live in queue.js, which this page loads first.
(function () {
  if (typeof window === "undefined" || !window.AbstractPlugin) return;
  const host = window.AbstractPlugin;
  let state = null;
  let pullTimer = null;
  let shown = -1;

  function showCount() {
    const count = window.ApprovalsQueue.count(state);
    if (count === shown) return;
    shown = count;
    host.send("setBadge", { count });
  }

  async function pull() {
    const asked = window.ApprovalsQueue.nextPull(state);
    state = asked.state;
    const reply = await host.send("getPermissions");
    state = window.ApprovalsQueue.applyPull(state, asked.seq, reply);
    showCount();
  }

  function pullSoon() {
    clearTimeout(pullTimer);
    pullTimer = setTimeout(pull, 300);
  }

  function start() {
    state = window.ApprovalsQueue.emptyState();
    host.events.subscribe(["permission.requested", "permission.resolved"], (event) => {
      state = window.ApprovalsQueue.applyEvent(state, event, new Date().toISOString());
      showCount();
      pullSoon();
    });
    return pull();
  }

  const script = document.createElement("script");
  script.src = "queue.js";
  script.addEventListener("load", start);
  document.head.append(script);
})();
