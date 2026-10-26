# ABS-46: reading git inside Abstract with libgit2

**Question.** Can the background read that ABS-45 settles on (`git --no-optional-locks status --porcelain=v2
--branch -z --untracked-files=all --ignore-submodules=none`, then `git rev-list --left-right --count
<base>...HEAD`) run inside Abstract's own process, give the same answers as `git`, and cost less?

**Method.** libgit2 1.9.7 (the latest release, 2026-08-13), built from source as a static universal library
with no network code (`USE_HTTPS=OFF USE_SSH=OFF`). A small C probe printed libgit2's status, branch,
ahead/behind and `HEAD`-to-working-tree patch in porcelain v2's shape, and a script compared them with
`git`'s for each repository. Measured on an M1 Pro (10 cores), Apple git 2.50.1, `/usr/bin/git` spawned
through a pipe as the app does. One read is status plus ahead/behind; times are medians of 30 to 50 reads
after one warm-up, and CPU counts the git processes' user and system time.

## 1. Speed and cost

| Repository | `git` processes per read | `git`: time / CPU per read | libgit2: time / CPU per read |
|---|---|---|---|
| Submodule fixture (`SubmoduleFixture`: chat worktree, 3 checked-out submodules, one nested) | 5 | 75 ms / 70 ms | 4.4 ms / 5.0 ms |
| This repository (a linked worktree, 728 files) | 2 | 32 ms / 27 ms | 8.1 ms / 7.8 ms |
| Synthetic large repository: 50,025 files, 3 submodules of 1,000 files, 20 LFS files of 1 MB, 22 changes | 5 | 174–184 ms / 507–555 ms | 242–286 ms / 233–285 ms |

- "Two processes per read" is really two plus one per checked-out submodule: `git status
  --ignore-submodules=none` starts `git status --porcelain=2` inside each one (seen with `GIT_TRACE`).
- In small and typical repositories libgit2 is 4 to 17 times faster and uses 3 to 14 times less CPU.
- In the 50,000-file repository libgit2 uses about **half the CPU**, but takes **about 40% longer**: `git`
  checks files with several threads (`core.preloadIndex`) and libgit2 with one. With
  `core.preloadIndex=false`, `git` takes 170 ms.
- Keeping the repository open between reads saves 0.5 ms to 40 ms more. libgit2 used 8 to 30 MB of memory.
- At ABS-45's ceiling of 30 reads a minute, the large repository costs 16 s of CPU a minute with `git` and
  8 s with libgit2; the fixture 2.1 s and 0.15 s.

**Same answers.** Out of 31 scenarios from the git, submodule and diff suites (modified, staged, deleted,
renames, untracked folders, spaces and non-ASCII paths, binary, symlinks, mode changes, CRLF, ignored files,
nested repositories, merge conflict, detached and unborn `HEAD`, upstream and base ahead/behind, the whole
submodule fixture in a linked worktree) the status and ahead/behind were identical in 29, and the patch
in 30. The large repository matched too. The differences:

- **Intent-to-add files** (which Abstract's own `git add -N` creates): `git` says `.A`, libgit2 says `AM`.
  The index entry carries a flag (`GIT_INDEX_ENTRY_INTENT_TO_ADD`), so a reader can map it back.
- **A nested repository with no commits** is listed by `git` as `nested/` and skipped by libgit2. It can't
  be seen from libgit2's answer; it changes the untracked count by one.
- **Diffs.** The patch text differs in a merge conflict (libgit2 prints the file as mode 0 with no
  content), in the rename similarity score (57% against 80% for a case-only rename), and in the length of
  abbreviated hashes in large repositories (7 against 8 characters).

## 2. Repositories libgit2 doesn't support

| Repository | What libgit2 does | Known before reading |
|---|---|---|
| Reftable refs (`--ref-format=reftable`) | Fails to open: `unsupported extension name extensions.refstorage` | `extensions.refStorage` in config |
| SHA-256 objects | Fails to open: `unknown object format 'sha256'` (libgit2's experimental SHA-256 build wasn't tried) | `extensions.objectFormat` in config |
| Sparse index | Fails: `unsupported mandatory extension: 'sdir'` | `index.sparse`, or the error |
| Split index (`core.splitIndex`) | Fails: `unsupported mandatory extension: 'link'` | `core.splitIndex`, or the error |
| An index extension from a newer git | Same error for any unknown mandatory extension; optional ones are skipped | The error |
| **Sparse checkout, full index** | **Wrong answer:** every file outside the checkout shows as deleted | `core.sparseCheckout` in config |
| **Filters (LFS, any `filter=` driver)** | **Wrong answer:** a filtered file only touched, or rewritten with the same content, shows as modified | `filter.<name>.clean` or `.process` in config |
| **`submodule.<name>.ignore` set** | **Wrong answer:** a dirty submodule `git` reports (`S.M.`) is missing | `ignore` in `.gitmodules` or config |
| Partial clone (`--filter=blob:none`) | Status is right; a diff needing a blob not fetched yet fails (`object not found`), where `git` fetches it | `remote.<name>.promisor` or `extensions.partialClone` |
| `core.fsmonitor` | Same answers; libgit2 ignores the monitor, so it gains nothing from it | `core.fsmonitor` |
| `.gitattributes` `text`/`eol`, `core.autocrlf`, index v4, `feature.manyFiles` (`index.skipHash`), untracked cache, EOIE/IEOT, `extensions.worktreeConfig`, global ignore file | Same answers | — |

Every hard failure is an error at open or on the first read; every wrong answer is visible in the
repository's config before reading.

## 3. Agents running git at the same time

An "agent" committed, refreshed the index and ran `pack-refs` as fast as it could (315 commits in 35 s,
with and without `index.skipHash`) while libgit2 read status and resolved refs in a loop: **1,321 status
reads and 15,277 ref reads, 0 errors, 0 failed git commands** (no `index.lock` clash). libgit2's status
never writes the index or takes its lock unless asked to (`GIT_STATUS_OPT_UPDATE_INDEX`). It reads the
index whole, and git replaces it by renaming a finished file, so a read sees the old or the new one, never
part of each. A repository kept open saw each change at the next read, including with `index.skipHash`.

## 4. Build cost

- **Size:** +2.6 MB in a universal app binary (1.3 MB per architecture), stripped, with only status,
  graph and diff in use. The full static library is 5.0 MB.
- **Build time:** 33 s with 10 jobs, 50 s with 3 (the CI runners' core count), from source. Cached by
  version on CI, it costs nothing after the first build.
- **Signing and notarisation:** linked statically, there's no new binary to sign, and the app links only
  libz, libiconv, CoreFoundation and Security from the system. There's no OpenSSL. (Not notarised in this
  spike: that needs the release credentials.)
- **Integration:** there's no maintained Swift wrapper (SwiftGit2's last release is 0.6.0, from 2019).
  It would be a small C target in `AbstractCore` over a prebuilt XCFramework, and an entry in
  `THIRD_PARTY_NOTICES.md` (GPLv2 with the linking exception).

## Fallback rule

The monitor uses libgit2 for **status, branch and ahead/behind only**. It keeps using `git` processes for
a repository, or a submodule, when any of these is true, checked when the monitor starts and whenever
`.git/config` or `.gitmodules` changes:

- `extensions.refStorage`, `extensions.objectFormat` other than `sha1`, or any other extension libgit2
  rejects;
- `core.sparseCheckout`, `index.sparse` or `core.splitIndex`;
- a `filter.<name>.clean` or `filter.<name>.process` in its config (that's how LFS shows up);
- `submodule.<name>.ignore` for any of its submodules;
- libgit2 returns an error on any read: that repository stays on `git` until its config changes.

Diffs (the Changes pane), every write, and partial clones' diffs stay on `git`.

## Go or no-go

**Go**, for the monitor's status, branch and ahead/behind, once ABS-45's monitor (b) and two-process
reads (c) have landed, behind the same interface so the fallback is one switch. It turns a read in a
typical repository from 2 to 5 processes and tens of milliseconds into none and a few, and halves the CPU
in large ones. The ticket that builds it must map intent-to-add entries, apply the fallback rule above,
and run the git and submodule suites against both readers.

**No-go** for diffs: the differences in conflicts and renames would make the Changes pane disagree with the
agent, and only the visible chat reads them.
