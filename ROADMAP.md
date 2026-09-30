# Roadmap

Abstract runs several CLI coding agents in parallel, each in its own git worktree,
and helps you review, finish and ship what they changed.

**The plan lives in Linear**, in workspace `abstract-ade`, team `ABS`. Every piece of
work is a ticket, and no ticket is built until a person has reviewed it. This file holds
the rules those tickets, and the agents that file and build them, follow.

## How the weekly release works

- A **minor release is cut every Friday** from `main` (Actions → *Cut release* → `minor`).
  Everything merged since the previous tag ships in it. Nothing is cut on merge.
- **Release notes are generated from PR titles.** The cut workflow calls GitHub's
  `generate-notes`, which lists every merged PR since the last tag, grouped by label
  (AGENTS.md), and puts the optional hand-written `notes` input above that list. So the
  PR title *is* the release note line, and a ticket's title becomes its PR title.
- **The week's headline** goes into the `notes` input when the release is cut: two
  sentences a user would want to read, written from what merged that week.
- **Fixes after the cut** go to `main` first, then get cherry-picked onto `vX.Y.x` and
  released with *Patch release* (see AGENTS.md).
- **Freeze on Thursday.** A PR that isn't green and reviewed by Thursday evening ships
  the week after.

## Tickets

**Who files them.** The *product owner* automation researches once a week and files at
most three tickets in **Triage**. Anyone can file one by hand the same way.

**What a ticket holds.**

- **Title:** the release-note line. One sentence saying what changes for the user, in
  the present tense, with no ticket numbers. A spike's title starts with `Spike:`.
- **Description**, a short paragraph under each heading: Problem (who hits it and when),
  Evidence, Proposal (in Abstract's own concepts and screens), Done when (observable),
  Tests, Size, Not this. A spike has Question and Output instead of Proposal and Tests.
- **Last line:** `PR label: <feature|fix|agents|internal>`, the label its PR gets. Without
  one, Bug → `fix`, Feature → `feature`, and Improvement → `agents` when it's about one
  agent catching up, `internal` for tests, CI and docs, `feature` otherwise.
- **Blocked by:** a Linear relation (`linear issue relation add ABS-n blocked-by ABS-m`),
  also named in the description. An L ticket is always blocked by its spike.
- **Priority:** the order agents take accepted tickets in.

Sizes: **S** fits in a day for one agent, **M** two to three days, **L** a week.

**Triage is the review.** Nothing leaves Triage without a person moving it:

| Move it to | Meaning | Who acts next |
|---|---|---|
| **Todo** | Accepted. Ready for an agent, highest priority first. | the builder automation |
| **Backlog** | Good idea, not now. Agents never take it. | nobody, until it is moved to Todo |
| **Canceled** / **Duplicate** | No. The product owner won't file it again. | nobody |

Set the priority while you are there: Urgent and High get taken before Medium and Low.
Moving a Todo ticket back to Backlog pauses it.

**From Todo to Done.**

1. The *builder* automation takes the highest-priority unassigned Todo ticket whose
   blockers are Done and that has no open PR, sets it to **In Progress** and assigns
   itself.
2. It builds it on a fresh branch off `main`, one ticket per PR, with the ticket's title
   as the PR title and `Fixes ABS-n` in the body, then sets the ticket to **In Review**.
   The Linear GitHub integration keeps the two in step from here.
3. Merging the PR moves the ticket to **Done**.

**How an agent builds a ticket.** Do what the Proposal says, stop when Done when is
true, and add the tests. `cd Packages/AbstractCore && swift test` must pass and the app
must build. Never change `project.yml`'s version (AGENTS.md). Recorded agent streams
must not carry a real home directory, account, plugin or skill list. Follow the product
rules below: if a ticket turns out to need a new concept the user has to learn, stop and
say so in a draft PR and on the ticket instead of adding it. A spike's PR holds only its
note; no code is kept.

## Product rules

These come from how Abstract has been built so far and decisions already taken.

- **Correctness before orchestration.** Make the concepts Abstract already has
  (Chats, Changes, Commit, Push, PR, Automations, Devices) behave correctly in more
  cases before adding new concepts or encoding one team's workflow. Ask: does this add
  an idea the user must learn, or make an existing one right?
- **Agents are equals.** Anything Claude can do in the app, Codex and OpenCode should do
  too, as far as their CLIs allow. When a CLI can't, say so in the UI instead of failing
  quietly.
- **Subscription CLIs only.** Abstract never calls a model API and never holds a model
  key. It also never knows which model server an agent uses (Ollama, LM Studio); that
  is the agent's business.
- **Public repository.** No personal paths, accounts or fixtures from a real profile.
- **One type per agent.** Adding an agent is one `ProviderDefinition` plus one line in
  `ProviderRegistry`. Keep it that way.
- **Plain language in the UI and in notes.** Sentences, not labels. No jargon a
  newcomer to the app wouldn't know.

## Themes

| Theme | What it means |
|---|---|
| **Finish** | Reviewing, committing, pushing and merging work correctly, including submodules |
| **Parity** | Codex and OpenCode catch up with Claude: approvals, commands, usage, drafting |
| **Trust** | Tests around the app layer, screenshots in CI, release notes that read well |
| **Reach** | The command line, paired Macs and the menu bar make Abstract usable when its window isn't in front |
| **Speed** | The palette, shortcuts and navigation |

## Not planned

- Calling model APIs, holding model keys, or pricing tables.
- A workflow or pipeline builder that chains agents. Abstract runs agents; it does not
  choreograph them.
- Windows or Linux builds of the app itself (an SSH executor is the path to remote Linux).
- Merging a release branch back into `main`.

## Before Linear

Until 2026-09-30 this file listed the work week by week, with `R-` IDs. R-1000 to
R-1004 and R-1106 were built from it (#10, #13, #14, #15, #17, #20). Every item not yet
started, and the ideas on its "Later" list, moved to Linear Triage as ABS-13 to ABS-44;
each of those tickets names where it came from. "Pull requests across submodules" from
that list is ABS-19.
