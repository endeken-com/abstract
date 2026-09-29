# Agent instructions

## Versions and releases

Pull requests never change the app's version, and nothing on `main` holds one:
`project.yml` keeps `MARKETING_VERSION` at `0.0.0` (local builds are dev builds, and their
updater stays off). CI sets the real version from git tags when it builds a release
(`scripts/next-version.sh`).

Releases are cut on purpose, never on merge:

- **Cut**: Actions → *Cut release* → `minor` or `major`. Branches `vX.Y.x` off `main`,
  tags `vX.Y.0`, and publishes the signed DMG and the update.
- **Patch**: merge the fix into `main` first, then cherry-pick it onto `vX.Y.x` in a pull
  request against that branch. Once that merges: Actions → *Patch release* → `vX.Y.x`,
  which tags `vX.Y.(n+1)`.
- **Nightly**: `main` builds every day at 06:00 UTC when it changed (Actions → *Nightly*
  → force, to build one now).

A release branch only ever receives cherry-picked fixes, and is never merged back into
`main`.

### Choosing the level for a cut

When asked to cut a release, read what merged since the last one
(`gh release view --json tagName` for the last tag, then the merged pull requests since it)
and choose from that together with what the user said. If the user names a level, use it.

**major** — users must relearn or redo something:
- a feature, screen, setting, or CLI flag is removed or works fundamentally differently
- saved data (database, settings, session logs) needs a migration that can't go back,
  or older versions can no longer read it
- the minimum macOS version rises
- the user says it's a major release or a breaking change

**minor** — everything else. Fixes alone still ship as a minor cut from `main`; patch
releases are only for fixes cherry-picked onto a release branch.

When it's ambiguous, pick minor and say so in your reply, so the user can overrule it.

## Pull request titles and labels

A pull request's title is its line in the release notes, word for word. Write what
changed for the user, in the present tense, with no ticket numbers or `feat:` prefixes.

Give every pull request one label, which picks its section in the notes
(`.github/release.yml`):

| Label | Section |
|---|---|
| `feature` | New |
| `fix` | Fixed |
| `agents` | Agents |
| `internal` | Under the hood |

`internal` wins over the others: tests, CI, docs and refactors stay under "Under the
hood" even if they carry a second label. A pull request with no label lands in "Other
changes".

## Test fixtures

Recorded agent streams (like `Tests/AbstractCoreTests/Fixtures/claude-stream.jsonl`)
must not carry a real home directory, account, plugin or skill list. Record them in a
clean profile, or strip those fields before committing: this repository is public.
