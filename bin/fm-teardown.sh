#!/usr/bin/env bash
# Tear down a finished task: return the treehouse worktree, kill the multiplexer window,
# clear volatile state, refresh/prune the project's clone for PR-based ship tasks,
# then print a backlog-refresh reminder.
# REFUSES if the worktree holds work not on any remote, because treehouse return
# hard-resets the worktree and kills its processes. A fork counts as a remote,
# so upstream-contribution PRs pushed to a fork satisfy this in any mode.
# local-only projects additionally accept work merged into the local default
# branch (firstmate performs that merge on the captain's approval) as a fallback
# for the common case where there is no remote at all.
# Scout tasks (kind=scout in meta) carve out of that check: their worktree is
# declared scratch and the report at data/<task-id>/report.md is the work
# product - teardown proceeds once the report exists, and refuses without it.
# Usage: fm-teardown.sh <task-id> [--force]
#   --force skips the unpushed-work check. Only use it when the captain has
#   explicitly said to discard the work.
set -eu

FM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$FM_ROOT/bin/fm-guard.sh" || true
# shellcheck source=bin/fm-mux-lib.sh
. "$FM_ROOT/bin/fm-mux-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$FM_ROOT/bin/fm-tasks-axi-lib.sh"
STATE="$FM_ROOT/state"
ID=$1
FORCE=${2:-}

META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
WT=$(grep '^worktree=' "$META" | cut -d= -f2-)
T=$(grep '^window=' "$META" | cut -d= -f2-)
PROJ=$(grep '^project=' "$META" | cut -d= -f2-)

KIND=$(grep '^kind=' "$META" | cut -d= -f2- || true)
[ -n "$KIND" ] || KIND=ship
MODE=$(grep '^mode=' "$META" | cut -d= -f2- || true)
[ -n "$MODE" ] || MODE=no-mistakes
PR_URL=$(grep '^pr=' "$META" | tail -1 | cut -d= -f2- || true)

# The backlog-refresh reminder printed after teardown. When a compatible tasks-axi
# is present, firstmate routes backlog mutations through its verbs (the .tasks.toml
# markdown backend), so the reminder suggests the exact `tasks-axi done` command;
# otherwise it falls back to the hand-edit instruction. Inert when tasks-axi is
# absent - the default for this fleet today.
backlog_refresh_reminder() {
  local done_cmd report_path
  if fm_tasks_axi_compatible; then
    case "$KIND" in
      scout)
        report_path="data/$ID/report.md"
        done_cmd="tasks-axi done $ID --report $report_path"
        ;;
      *)
        if [ "$MODE" = local-only ]; then
          done_cmd="tasks-axi done $ID --note \"local main\""
        elif [ -n "$PR_URL" ]; then
          done_cmd="tasks-axi done $ID --pr $PR_URL"
        else
          done_cmd="tasks-axi done $ID --pr PR_URL"
        fi
        ;;
    esac
    printf '%s\n' "Backlog: $ID just finished. Run $done_cmd, then run tasks-axi ready for dependency-cleared candidates, check date gates, and dispatch only work whose blockers are gone and date is due."
  else
    printf '%s\n' "🌱 Backlog: $ID just finished. Update data/backlog.md - move $ID to Done (keep Done to the 10 most recent), then re-scan Queued for items now unblocked (a \"blocked-by: $ID\" may have just cleared) or now time-due, and dispatch what's ready."
  fi
}

default_branch() {
  local ref branch
  ref=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$PROJ" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

if [ -d "$WT" ] && [ "$FORCE" != "--force" ]; then
  if [ "$KIND" = scout ]; then
    # Scout worktrees are scratch by contract, but only once the deliverable exists.
    REPORT="$FM_ROOT/data/$ID/report.md"
    if [ ! -f "$REPORT" ]; then
      echo "REFUSED: scout task $ID has no report at $REPORT." >&2
      echo "The report is the work product. Have the crewmate write it (or get the captain's explicit OK to discard, then --force)." >&2
      exit 1
    fi
  else
    # The fm-spawn hook file is ours, never work product; ignore it in the dirty check.
    dirty=$(git -C "$WT" status --porcelain 2>/dev/null | grep -vE '^\?\? \.claude/' | head -1 || true)
    # A worktree's work is "safely on a remote" once HEAD is reachable from ANY
    # remote-tracking branch (empty result here). A fork is a remote too, so
    # upstream-contribution PRs pushed to a fork satisfy this regardless of mode.
    unpushed=$(git -C "$WT" log --oneline HEAD --not --remotes -- 2>/dev/null | head -5 || true)
    if [ -n "$unpushed" ] && [ "$MODE" = local-only ]; then
      # local-only ships have no remote in the common case, so the "on a remote"
      # test above is expected to be non-empty. The work is safe once it is merged
      # into the local default branch (firstmate does that merge on the captain's
      # approval). Refuse until then.
      DEFAULT=$(default_branch) || { echo "REFUSED: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master." >&2; exit 1; }
      unmerged=$(git -C "$WT" log --oneline HEAD --not "$DEFAULT" -- 2>/dev/null | head -5 || true)
      if [ -n "$dirty" ] || [ -n "$unmerged" ]; then
        echo "REFUSED: local-only worktree $WT has work not yet merged into $DEFAULT and not on any remote." >&2
        [ -n "$dirty" ] && echo "uncommitted changes present" >&2
        [ -n "$unmerged" ] && printf 'commits not yet on %s:\n%s\n' "$DEFAULT" "$unmerged" >&2
        echo "Merge the branch into local $DEFAULT first (bin/fm-merge-local.sh after the captain approves), or push to a fork/remote, or get the captain's explicit OK to discard, then --force." >&2
        exit 1
      fi
    elif [ -n "$dirty" ] || [ -n "$unpushed" ]; then
      echo "REFUSED: worktree $WT has work not on any remote." >&2
      [ -n "$dirty" ] && echo "uncommitted changes present" >&2
      [ -n "$unpushed" ] && printf 'unpushed commits:\n%s\n' "$unpushed" >&2
      echo "Push the branch (or get the captain's explicit OK to discard, then --force)." >&2
      exit 1
    fi
  fi
fi

# Best-effort: drop the local task branch so the shared repo does not accumulate refs.
if [ -d "$WT" ]; then
  branch=$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)
  if [ "$branch" != "HEAD" ]; then
    if git -C "$WT" checkout --detach -q 2>/dev/null; then
      git -C "$WT" branch -D "$branch" >/dev/null 2>&1 || true
    fi
  fi
  # Remove our hook file so a reused pool worktree cannot fire signals for a dead task.
  rm -f "$WT/.claude/settings.local.json" "$WT/.opencode/plugins/fm-turn-end.js"
  # Kills remaining processes in the worktree (including the agent), resets, returns
  # to pool. treehouse resolves the pool from the working directory, so run it from
  # the project.
  ( cd "$PROJ" && treehouse return --force "$WT" )
fi

"$FM_MUX" kill-window -t "$T" 2>/dev/null || true
rm -f "$STATE/$ID.status" "$STATE/$ID.turn-ended" "$STATE/$ID.check.sh" "$STATE/$ID.meta" "$STATE/$ID.pi-ext.ts"
if [ "$KIND" != scout ] && [ "$MODE" != local-only ]; then
  "$FM_ROOT/bin/fm-fleet-sync.sh" "$PROJ" || true
fi
echo "teardown $ID complete (window $T, worktree $WT)"
backlog_refresh_reminder
