(async () => {
  const status = document.getElementById("status");
  const detail = document.getElementById("detail");
  try {
    // bkt has no --output flag, though `auth status --help` still shows one.
    const out = await window.AbstractPlugin.cli.run(["auth", "status", "--json"]);
    if (!out.ok) {
      const said = out.stderr.trim();
      if (/unknown (?:shorthand )?(?:flag|command)/i.test(said)) {
        status.textContent = "This version of the Bitbucket CLI needs an update.";
        detail.textContent = `Update it with brew upgrade bitbucket-cli, then come back here.\n${said}`;
        return;
      }
      throw new Error(said || "bkt auth status failed.");
    }
    const hosts = JSON.parse(out.stdout).hosts || [];
    status.textContent = hosts.length ? "Signed in with the Bitbucket CLI." : "Not signed in.";
    detail.textContent = hosts.length
      ? hosts.map((host) => `${host.username || "Account"} · ${host.base_url} (${host.kind === "dc" ? "Data Center" : "Cloud"})`).join("\n")
      : "Run bkt auth login in a terminal, then come back here.";
  } catch (error) {
    status.textContent = error.missing ? "The Bitbucket CLI isn't installed." : "Bitbucket isn't ready.";
    detail.textContent = error.missing
      ? `Install it with ${error.install || "brew install avivsinai/tap/bitbucket-cli"}, then run bkt auth login.`
      : String(error.message || error);
  }
})();
