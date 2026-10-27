import Foundation
import Testing
@testable import AbstractCore

/// ABS-165, per the ABS-167 design note: which indicator a tool row gets,
/// from the name and input it already carries. Unknown tools never guess
/// a brand. The phone mirrors these cases in `toolIndicator.test.js`.
@Suite struct ToolIndicatorTests {
    private func bash(_ command: String) -> ToolIndicator {
        ToolIndicator.resolve(name: "Bash", input: .object(["command": .string(command)]))
    }

    private func resolve(_ name: String, _ input: JSONValue = .object([:]), pluginId: String? = nil) -> ToolIndicator {
        ToolIndicator.resolve(name: name, input: input, pluginId: pluginId)
    }

    @Test(arguments: [
        ("gh pr list", ToolIndicator.brand("GitHub")),
        ("bkt pr list", .brand("Bitbucket")),
        ("glab mr list", .brand("GitLab")),
        ("acli jira issue view ABC-1", .brand("Jira")),
        ("jira issue list", .brand("Jira")),
        ("linear issue view ENG-1", .brand("Linear")),
        ("abstract history Sources/A.swift", .brand("Abstract")),
        ("git status", .brand("Git")),
        ("docker ps", .brand("Docker")),
        ("docker-compose up", .brand("Docker")),
        ("podman ps", .brand("Docker")),
        ("kubectl get pods", .brand("Kubernetes")),
        ("k9s", .brand("Kubernetes")),
        ("helm list", .brand("Helm")),
        ("terraform plan", .brand("Terraform")),
        ("tofu plan", .brand("Terraform")),
        ("aws s3 ls", .brand("AWS")),
        ("gcloud projects list", .brand("GoogleCloud")),
        ("az account show", .brand("Azure")),
        ("node server.js", .brand("Node")),
        ("npm test", .brand("Npm")),
        ("pnpm test", .brand("Pnpm")),
        ("yarn build", .brand("Yarn")),
        ("bun run dev", .brand("Bun")),
        ("deno task dev", .brand("Deno")),
        ("python3 app.py", .brand("Python")),
        ("pip install requests", .brand("Python")),
        ("uv sync", .brand("Uv")),
        ("pytest tests/", .brand("Pytest")),
        ("go test ./...", .brand("Go")),
        ("cargo build", .brand("Rust")),
        ("swift test", .brand("Swift")),
        ("xcodebuild -scheme App", .brand("Swift")),
        ("xcrun simctl list", .brand("Swift")),
        ("ruby app.rb", .brand("Ruby")),
        ("bundle install", .brand("Ruby")),
        ("gem list", .brand("Ruby")),
        ("brew list", .brand("Homebrew")),
        ("psql -c 'select 1'", .brand("PostgreSQL")),
        ("pg_dump db", .brand("PostgreSQL")),
        ("mysql -e 'select 1'", .brand("MySQL")),
        ("redis-cli ping", .brand("Redis")),
        ("mongosh --eval 'db.stats()'", .brand("MongoDB")),
        ("sqlite3 app.db", .brand("SQLite")),
        ("jest --watch", .brand("Jest")),
        ("vitest run", .brand("Vitest")),
        ("playwright test", .brand("Playwright")),
        ("eslint src", .brand("ESLint")),
        ("prettier --write src", .brand("Prettier")),
        ("tsc --noEmit", .brand("TypeScript")),
        ("vercel deploy", .brand("Vercel")),
        ("firebase deploy", .brand("Firebase")),
        ("sentry-cli releases list", .brand("Sentry")),
        ("stripe listen", .brand("Stripe")),
        ("supabase status", .brand("Supabase")),
        ("make test", .kind(symbol: "hammer")),
        ("cmake --build .", .kind(symbol: "hammer")),
        ("rg pattern src", .kind(symbol: "magnifyingglass")),
        ("fd name src", .kind(symbol: "magnifyingglass")),
        ("curl https://example.com", .kind(symbol: "network")),
        ("ssh host uptime", .kind(symbol: "network")),
        ("code .", .kind(symbol: "macwindow")),
        ("open https://example.com", .kind(symbol: "macwindow")),
        ("ls -la", .kind(symbol: "terminal")),
        ("unknown-tool --flag", .kind(symbol: "terminal")),
    ])
    func catalogExecutables(_ command: String, _ expected: ToolIndicator) {
        #expect(bash(command) == expected, "\(command)")
    }

    @Test(arguments: [
        // Wrappers the command actually ran under.
        ("FOO=1 /usr/local/bin/gh pr list", ToolIndicator.brand("GitHub")),
        ("NO_COLOR=1 FOO=bar linear issue view ENG-1", .brand("Linear")),
        ("sudo -E linear issue view ENG-1", .brand("Linear")),
        ("sudo -u root gh auth status", .brand("GitHub")),
        ("env NO_COLOR=1 bkt pr list", .brand("Bitbucket")),
        ("env -i -u HOME gh pr list", .brand("GitHub")),
        ("~/bin/linear issue view ENG-1", .brand("Linear")),
        ("./node_modules/.bin/eslint src", .brand("ESLint")),
        ("command gh pr list", .brand("GitHub")),
        ("exec gh pr list", .brand("GitHub")),
        ("nohup linear sync", .brand("Linear")),
        ("nice -n 5 make test", .kind(symbol: "hammer")),
        ("time gh pr list", .brand("GitHub")),
        ("builtin cd src && gh pr list", .brand("GitHub")),
        ("echo file | xargs -I {} gh pr view {}", .brand("GitHub")),
        ("(gh pr list)", .brand("GitHub")),
        // Nested shells, one level.
        ("bash -c 'gh pr list'", .brand("GitHub")),
        ("sudo bash -c \"linear issue view ENG-1\"", .brand("Linear")),
        // A wrapper with a flag we don't know abandons its segment.
        ("sudo --preserve-env=HOME gh pr list", .kind(symbol: "terminal")),
        ("env -S gh pr list", .kind(symbol: "terminal")),
        ("xargs -a files gh pr view", .kind(symbol: "terminal")),
    ])
    func wrappedCommands(_ command: String, _ expected: ToolIndicator) {
        #expect(bash(command) == expected, "\(command)")
    }

    @Test func codexWrappedShell() {
        // Codex wraps every command in `zsh -lc "…"`; unwrap hands back the command.
        #expect(ToolIndicator.unwrapShell("/bin/zsh -lc \"gh pr list\"") == "gh pr list")
        #expect(resolve("Bash", .object(["command": .string("/bin/zsh -lc \"gh pr list\"")])) == .brand("GitHub"))
    }

    @Test(arguments: [
        // Runners look through only when the next token is a catalog tool.
        ("uv run pytest tests/", ToolIndicator.brand("Pytest")),
        ("uv tool run pytest", .brand("Pytest")),
        ("uvx pytest", .brand("Pytest")),
        ("npx tsc --noEmit", .brand("TypeScript")),
        ("npx unknown-tool", .brand("Npm")),
        ("npm exec eslint src", .brand("ESLint")),
        ("pnpm dlx prettier --write .", .brand("Prettier")),
        ("yarn exec jest", .brand("Jest")),
        ("bunx prettier --write .", .brand("Prettier")),
        ("bundle exec rake test", .brand("Ruby")),
        ("pipx run pytest", .brand("Pytest")),
        ("poetry run pytest", .brand("Pytest")),
        // Without the runner verb there is no look-through.
        ("pnpm test", .brand("Pnpm")),
        ("npm run test", .brand("Npm")),
        ("uv pip install pytest", .brand("Uv")),
    ])
    func runnerWrappers(_ command: String, _ expected: ToolIndicator) {
        #expect(bash(command) == expected, "\(command)")
    }

    @Test(arguments: [
        ("cd app && gh pr list | jq .", ToolIndicator.brand("GitHub")),
        ("make && make test", .kind(symbol: "hammer")),
        ("git add .; gh pr create", .brand("Git")),
        ("false || linear issue view ENG-1", .brand("Linear")),
        ("gh pr list\ngh pr view 1", .brand("GitHub")),
        ("echo 'gh && linear' ; bkt pr list", .brand("Bitbucket")),
        ("echo \"a;b\" && linear issue list", .brand("Linear")),
        ("cd app\nnpm test", .brand("Npm")),
    ])
    func chainsAndPipes(_ command: String, _ expected: ToolIndicator) {
        #expect(bash(command) == expected, "\(command)")
    }

    @Test(arguments: [
        // A brand that is only an argument never matches.
        ("echo linear", ToolIndicator.kind(symbol: "terminal")),
        ("grep gh file.txt", .kind(symbol: "magnifyingglass")),
        ("git log --grep=linear", .brand("Git")),
        ("git -c x=y log", .brand("Git")),
        // `acli` is Atlassian-wide; only its Jira product is Jira.
        ("acli confluence page view 1", .kind(symbol: "terminal")),
        ("acli", .kind(symbol: "terminal")),
        // No expansion: a variable executable is unresolvable.
        ("$GH pr list", .kind(symbol: "terminal")),
        ("`gh` pr list", .kind(symbol: "terminal")),
        // Prefixes and near misses are not the tool.
        ("github-thing pr list", .kind(symbol: "terminal")),
        ("ghr pr list", .kind(symbol: "terminal")),
        ("linearctl issue list", .kind(symbol: "terminal")),
    ])
    func wrongBrandGuards(_ command: String, _ expected: ToolIndicator) {
        #expect(bash(command) == expected, "\(command)")
    }

    @Test(arguments: [
        // Claude and Codex spell MCP calls the same way once parsed.
        ("mcp__github__list_pull_requests", ToolIndicator.brand("GitHub")),
        ("mcp__github__code_history", .brand("GitHub")),
        ("mcp__linear__get_issue", .brand("Linear")),
        ("mcp__linear-mcp__get_issue", .brand("Linear")),
        ("mcp__mcp-linear__get_issue", .brand("Linear")),
        ("mcp__bitbucket__list_pull_requests", .brand("Bitbucket")),
        ("mcp__gitlab__list_merge_requests", .brand("GitLab")),
        ("mcp__jira__get_issue", .brand("Jira")),
        ("mcp__atlassian__get_issue", .brand("Jira")),
        ("mcp__sentry__list_issues", .brand("Sentry")),
        ("mcp__supabase__list_tables", .brand("Supabase")),
        // An unknown server keeps its own name, never a guessed brand.
        ("mcp__weather__forecast", .mcpServer(name: "weather")),
        ("mcp__MyServer__do_thing", .mcpServer(name: "MyServer")),
        // Abstract's own MCP servers, under any spelling.
        ("mcp__abstract-code-history__code_history", .brand("Abstract")),
        ("mcp__abstract-code-history__chat_excerpt", .brand("Abstract")),
        ("abstract-code-history_code_history", .brand("Abstract")),
        ("code_history", .brand("Abstract")),
        ("chat_excerpt", .brand("Abstract")),
        ("mcp__abstract-branch__name_branch", .brand("Abstract")),
        ("abstract-branch_name_branch", .brand("Abstract")),
        ("name_branch", .brand("Abstract")),
        // OpenCode's one-underscore spelling is only trusted for known servers.
        ("linear_get_issue", .brand("Linear")),
        ("github_list_pull_requests", .brand("GitHub")),
        ("weather_forecast", .generic),
        ("some_tool", .generic),
    ])
    func mcpSpellings(_ name: String, _ expected: ToolIndicator) {
        #expect(resolve(name) == expected, "\(name)")
    }

    @Test func pluginTools() {
        let github = "mcp__abstract-plugins__github_list_prs"
        #expect(resolve(github, pluginId: "sh.abstract.github") == .brand("GitHub"))
        #expect(resolve(github, pluginId: "sh.abstract.bitbucket") == .brand("Bitbucket"))
        #expect(resolve(github, pluginId: "sh.abstract.linear") == .brand("Linear"))
        #expect(resolve(github, pluginId: "sh.abstract.jira") == .brand("Jira"))
        // Any other plugin keeps today's puzzle piece. The brand comes
        // from the plugin id, never from the tool's name text.
        #expect(resolve(github, pluginId: "dev.example.echo") == .kind(symbol: "puzzlepiece.extension"))
        // Uninstalled since the chat ran: Abstract's own mark.
        #expect(resolve(github) == .brand("Abstract"))
        #expect(resolve("abstract-plugins_github_list_prs", pluginId: "sh.abstract.github") == .brand("GitHub"))
    }

    @Test(arguments: [
        ("Read", ToolIndicator.kind(symbol: "doc.text")),
        ("read_file", .kind(symbol: "doc.text")),
        ("Write", .kind(symbol: "doc.badge.plus")),
        ("Edit", .kind(symbol: "pencil")),
        ("edit_file", .kind(symbol: "pencil")),
        ("Grep", .kind(symbol: "magnifyingglass")),
        ("WebFetch", .kind(symbol: "globe")),
        ("TodoWrite", .kind(symbol: "checklist")),
        ("ExitPlanMode", .kind(symbol: "list.bullet.clipboard")),
        ("Task", .kind(symbol: "person.2")),
        ("AskUserQuestion", .kind(symbol: "questionmark.bubble")),
        ("SomethingElse", .generic),
    ])
    func builtinTools(_ name: String, _ expected: ToolIndicator) {
        #expect(resolve(name) == expected, "\(name)")
    }

    @Test func emptyInputStaysGeneric() {
        // Muse's exec journal carries no arguments, so a shell row can't
        // be told apart from any other: the plain terminal, no brand.
        #expect(resolve("bash", .object([:])) == .kind(symbol: "terminal"))
        #expect(resolve("bash") == .kind(symbol: "terminal"))
        #expect(resolve("mystery_tool") == .generic)
    }

    @Test func skillUse() {
        let input = JSONValue.object(["skill": .string("doctor")])
        #expect(resolve("Skill", input) == .kind(symbol: "book.closed"))
        // A command reading a skill reads as using it, unless suppressed
        // for a pending approval.
        let read = JSONValue.object(["command": .string("cat /Users/x/.agents/skills/doctor/SKILL.md")])
        #expect(resolve("Bash", read) == .kind(symbol: "book.closed"))
        #expect(ToolIndicator.resolve(name: "Bash", input: read, pluginId: nil, skillUse: false) == .kind(symbol: "terminal"))
    }

    @Test func commandUnderCmdKey() {
        #expect(resolve("bash", .object(["cmd": .string("gh pr list")])) == .brand("GitHub"))
    }

    @Test func monogramIsStable() {
        let first = ToolIndicator.monogram(name: "weather")
        #expect(first.letter == "W")
        #expect(first == ToolIndicator.monogram(name: "weather"))
        #expect(first == ToolIndicator.monogram(name: "Weather"))
        #expect((0..<7).contains(first.colorIndex))
        #expect(ToolIndicator.monogram(name: "my-server").letter == "M")
        #expect(ToolIndicator.monogram(name: "-x").letter == "X")
    }

    @Test func foldedCommandRuns() {
        func call(_ command: String) -> ToolCall {
            ToolCall(id: command, name: "Bash", input: .object(["command": .string(command)]))
        }
        #expect(ToolIndicator.foldedCommands([call("gh pr list"), call("/usr/local/bin/gh pr view 1")]) == .brand("GitHub"))
        #expect(ToolIndicator.foldedCommands([call("gh pr list"), call("bkt pr list")]) == .kind(symbol: "terminal"))
        #expect(ToolIndicator.foldedCommands([]) == .kind(symbol: "terminal"))
    }

    @Test func labels() {
        #expect(ToolIndicator.brand("GitHub").label == "GitHub")
        #expect(ToolIndicator.brand("Abstract").label == "Abstract")
        #expect(ToolIndicator.mcpServer(name: "weather").label == "weather MCP server")
    }

    @Test func everyBrandHasAGlyphSource() {
        for entry in ToolIndicator.catalog {
            #expect(entry.symbol != nil || entry.simpleIcon != nil || entry.id == "Abstract", "\(entry.id)")
        }
        // No executable or alias is claimed by two entries.
        var executables: Set<String> = []
        var aliases: Set<String> = []
        for entry in ToolIndicator.catalog {
            for exe in entry.executables { #expect(executables.insert(exe).inserted, "\(exe) duplicated") }
            for alias in entry.mcpAliases { #expect(aliases.insert(alias).inserted, "\(alias) duplicated") }
        }
    }
}
