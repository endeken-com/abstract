# Agent instructions

## Versioning

Every change merged into `main` ships as a new DMG release, so every branch bumps the
app version exactly once. The version is `CFBundleShortVersionString` in `project.yml`
(`MAJOR.MINOR.PATCH`); don't edit it by hand.

```bash
scripts/bump-version.sh patch   # or minor / major
```

The script bumps from `main`'s version, not the branch's, so running it again is safe:
rerun it with a bigger level if the work grows, and never bump twice. CI rejects a pull
request whose version isn't exactly one step past `main`.

### Choosing the level

Decide from the conversation — what the user asked for and why — together with the
diff. The user's framing wins: "fix", "broken", "tweak" points to patch; "add", "new",
"support", "let me" points to minor. If the user names a level, use it.

**major** — users must relearn or redo something:
- a feature, screen, setting, or CLI flag is removed or works fundamentally differently
- saved data (database, settings, session logs) needs a migration that can't go back,
  or older versions can no longer read it
- the minimum macOS version rises
- the user says it's a major release or a breaking change

**minor** — users gain something they can see:
- a new feature, screen, setting, shortcut, menu item, or agent provider
- a visible change to how an existing feature behaves, beyond fixing it

**patch** — everything else:
- bug fixes, crash fixes, performance work
- copy, styling, or layout tweaks that don't add capability
- refactors, tests, docs, CI, build scripts, dependency updates

When one branch mixes kinds, use the highest one. When it's ambiguous, pick the lower
level and say which one you chose in your reply, so the user can overrule it.

Bump in the same commit as the change, or in a follow-up commit on the same branch
before the pull request.
