// The GitHub plugin's page under Settings → Plugins: whether the GitHub
// CLI is installed and signed in, the way the GitHub row in Settings →
// Integrations said before.
(async () => {
  const status = document.getElementById("status");
  const detail = document.getElementById("detail");
  try {
    const out = await window.AbstractPlugin.cli.run(["auth", "status"]);
    if (out.ok) {
      status.textContent = "Signed in with the GitHub CLI.";
      detail.textContent = (out.stdout + out.stderr).trim().split("\n")
        .map((line) => line.trim()).filter((line) => /Logged in to/.test(line)).join("\n");
    } else {
      status.textContent = "Not signed in.";
      detail.textContent = "Run gh auth login in a terminal, then come back here.";
    }
  } catch (error) {
    status.textContent = error.missing ? "The GitHub CLI isn't installed." : "The GitHub CLI couldn't be asked.";
    detail.textContent = error.missing ? `Install it with ${error.install || "brew install gh"}, then run gh auth login.`
                                       : String(error.message || error);
  }
})();
