---
name: port-upstream
description: Review and port useful commits from upstream (kunchenguid/firstmate) into this psmux/Windows fork, one gated PR at a time. Use when the captain asks to pull in upstream changes, check what is new upstream, or port a specific upstream commit. This fork diverged at the psmux port, so it NEVER merges or fast-forwards from upstream - it cherry-picks and adapts.
user-invocable: true
---

# Port upstream into the fork

This is a hard fork of [kunchenguid/firstmate](https://github.com/kunchenguid/firstmate),
diverged at the psmux/Windows port. Upstream changes are pulled in by
**cherry-pick-and-adapt**, never by merge or fast-forward: a merge from upstream
would reintroduce raw `tmux`, `AGENTS.md`, and the secondmate subsystem this fork
deliberately replaced or omits.

`bin/fm-port.sh` is the report-only engine; this skill is the workflow around it.
It never edits the repo - the porting is yours, gated as a PR for the captain.

## 1. See what is new upstream

```sh
bin/fm-port.sh            # upstream-only commits, classified, oldest first
bin/fm-port.sh --json     # same, machine-readable
bin/fm-port.sh <sha>      # one commit: classification, per-file buckets, full diff
```

Each commit lands in one bucket (advisory - it routes attention, never blocks):

- **clean** - touches no fork-adapted surface; a cherry-pick should apply. Verify, then PR.
- **needs-adapt** - touches an adapted surface (raw `tmux`, `AGENTS.md`, or a script
  the fork keeps differently). Hand-port: re-apply the `tmux`->`$FM_MUX` and
  `AGENTS.md`->`CLAUDE.md` deltas.
- **likely-skip** - the secondmate subsystem this fork omits. Skip unless the captain
  wants to adopt secondmates.

Relay the list to the captain (lavish for a structured review) and let them choose
what to port. Never port speculatively.

## 2. Port a chosen commit (or small batch)

For each commit the captain greenlights:

1. Work in an isolated worktree (EnterWorktree or an `isolation: worktree` agent) -
   never a loose branch.
2. `git cherry-pick <sha>` if **clean**; for **needs-adapt**, apply the change by
   hand and re-apply the fork's adaptations (`$FM_MUX`, `CLAUDE.md`, drop secondmate
   bits). Fold any `AGENTS.md` doc delta into `CLAUDE.md`.
3. Verify no raw `tmux` leaked in: `grep -n '\btmux\b' bin/*.sh` should show only
   `$FM_MUX` resolution and comments.
4. `bash -n` every touched script; run any ported tests.
5. Open a **gated PR to the fork** (`fork` remote) for the captain's merge - exactly
   like any firstmate-repo change. The captain's merge rule applies.

Batch related commits into one PR when they share a new file (e.g. two fixes that
both introduce one helper), but keep unrelated commits in separate PRs.

## 3. Guardrails

- **Never** `git merge` or fast-forward upstream into the fork. `bin/fm-port.sh` has
  no merge path; do not add one by hand.
- Every ported change is a PR the captain merges - never self-merge (the standing
  rule for this repo).
- Skip `likely-skip` commits unless the captain explicitly adopts that subsystem.
- The upstream remote defaults to `origin`; override with `FM_PORT_UPSTREAM_REMOTE`
  if your remotes are named differently.
