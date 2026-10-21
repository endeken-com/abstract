(async () => {
  const status = document.getElementById("status");
  const detail = document.getElementById("detail");
  try {
    const out = await window.AbstractPlugin.cli.run(["auth", "status", "--output", "json"]);
    if (!out.ok) throw new Error(out.stderr.trim() || "bkt auth status failed.");
    const hosts = JSON.parse(out.stdout).hosts || [];
    status.textContent = hosts.length ? "Signed in with the Bitbucket CLI." : "Not signed in.";
    detail.textContent = hosts.length
      ? hosts.map((host) => `${host.username || "Account"} · ${host.base_url} (${host.kind === "dc" ? "Data Center" : "Cloud"})`).join("\n")
      : "Run bkt auth login in a terminal, then come back here.";
  } catch (error) {
    status.textContent = error.missing ? "The Bitbucket CLI isn't installed." : "Bitbucket isn't ready.";
    detail.textContent = error.missing
      ? `Install it with ${error.install || "brew install bitbucket-cli"}, then run bkt auth login.`
      : String(error.message || error);
  }
})();
