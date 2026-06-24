#!/usr/bin/env bash
# Fork-aware upstream porter (report-only): list the commits upstream has that
# this fork lacks, classified by how much fork-adaptation each needs.
#
# This is the inverse of a self-updater. This is a hard fork of upstream
# (kunchenguid/firstmate) that diverged at the psmux/Windows port: every `tmux`
# call became "$FM_MUX", AGENTS.md became CLAUDE.md, and the secondmate subsystem
# is intentionally omitted. So a fast-forward / merge FROM upstream would clobber
# the port. There is deliberately NO merge or fast-forward path in this script.
# It only READS and REPORTS; the actual porting is a human/agent cherry-pick-and-
# adapt, gated as a PR (see the /port-upstream skill).
#
# What "upstream" and "the fork" mean here:
#   - UPSTREAM = the remote you port FROM (default `origin`; override with
#     FM_PORT_UPSTREAM_REMOTE). In this fork `origin` is kunchenguid/firstmate.
#   - the fork's local default branch is what you port INTO.
#
# Usage:
#   fm-port.sh                 list upstream-only commits, classified, oldest first
#   fm-port.sh --json          same, machine-readable (for the /port-upstream skill)
#   fm-port.sh <sha>           one commit: classification, per-file buckets, full diff
#   fm-port.sh --no-fetch ...  skip the upstream fetch (use already-fetched refs)
#   fm-port.sh --help
#
# Classification buckets (advisory - they route attention, never block):
#   clean        touches no fork-adapted surface; cherry-pick should apply.
#   needs-adapt  touches an adapted surface (raw tmux, AGENTS.md, or a script the
#                fork keeps differently); re-apply the $FM_MUX / CLAUDE.md deltas.
#   likely-skip  secondmate subsystem this fork omits; skip unless adopting it.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
"$SCRIPT_DIR/fm-guard.sh" 2>/dev/null || true

UPSTREAM_REMOTE=${FM_PORT_UPSTREAM_REMOTE:-origin}

# --- fork-owned surfaces (data-driven; extend as the fork diverges further) ---
# Scripts the fork adapted for psmux/$FM_MUX: a cherry-pick of an upstream commit
# touching one of these will collide and/or reintroduce raw tmux.
ADAPTED_PATHS="
bin/fm-spawn.sh
bin/fm-supervise-daemon.sh
bin/fm-send.sh
bin/fm-watch.sh
bin/fm-teardown.sh
bin/fm-bootstrap.sh
bin/fm-peek.sh
bin/fm-mux-lib.sh
bin/fm-tmux-lib.sh
bin/fm-proc-lib.sh
bin/fm-lock.sh
"
# Secondmate subsystem the fork intentionally omits.
SECONDMATE_PATHS="
bin/fm-home-seed.sh
bin/fm-backlog-handoff.sh
tests/fm-secondmate.test.sh
"

usage() { sed -n '2,/^set -eu/p' "$0" | sed 's/^# \{0,1\}//; s/^#$//'; }

FETCH=1
MODE=list
SHA=""
for a in "$@"; do
  case "$a" in
    --help|-h) usage; exit 0 ;;
    --json) MODE=json ;;
    --no-fetch) FETCH=0 ;;
    -*) echo "error: unknown flag $a" >&2; exit 1 ;;
    *) MODE=show; SHA=$a ;;
  esac
done

git -C "$FM_ROOT" rev-parse --git-dir >/dev/null 2>&1 || { echo "error: $FM_ROOT is not a git repo" >&2; exit 1; }
git -C "$FM_ROOT" remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1 || {
  echo "error: no '$UPSTREAM_REMOTE' remote (the upstream to port FROM); set FM_PORT_UPSTREAM_REMOTE" >&2
  exit 1
}

default_branch() {  # default branch name on the upstream remote
  local ref
  ref=$(git -C "$FM_ROOT" symbolic-ref --quiet --short "refs/remotes/$UPSTREAM_REMOTE/HEAD" 2>/dev/null || true)
  if [ -n "$ref" ]; then printf '%s' "${ref#"$UPSTREAM_REMOTE"/}"; return 0; fi
  local b
  for b in main master; do
    git -C "$FM_ROOT" show-ref --verify --quiet "refs/remotes/$UPSTREAM_REMOTE/$b" && { printf '%s' "$b"; return 0; }
  done
  return 1
}

if [ "$FETCH" -eq 1 ]; then git -C "$FM_ROOT" fetch --quiet "$UPSTREAM_REMOTE" 2>/dev/null || true; fi
DEFAULT=$(default_branch) || { echo "error: cannot determine $UPSTREAM_REMOTE default branch (no origin/HEAD, main, or master)" >&2; exit 1; }
UPSTREAM_REF="$UPSTREAM_REMOTE/$DEFAULT"
# Port INTO the local default branch (what the fork ships); fall back to HEAD.
LOCAL_REF=$DEFAULT
git -C "$FM_ROOT" show-ref --verify --quiet "refs/heads/$DEFAULT" || LOCAL_REF=HEAD

in_list() {  # <path> <newline-list>
  local p=$1 list=$2 item
  for item in $list; do [ "$p" = "$item" ] && return 0; done
  return 1
}

# Classify one commit. Echoes "<bucket>|<reason1; reason2; ...>".
classify() {  # <sha>
  local sha=$1 files f reasons="" bucket="clean"
  local has_secondmate=0 has_adapt=0 has_agents=0 has_tmux=0 has_absent=0
  files=$(git -C "$FM_ROOT" show --no-color --name-only --format= "$sha" 2>/dev/null | sed '/^$/d')
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if in_list "$f" "$SECONDMATE_PATHS" || printf '%s' "$f" | grep -q 'secondmate'; then
      has_secondmate=1; continue
    fi
    [ "$f" = "AGENTS.md" ] && has_agents=1
    in_list "$f" "$ADAPTED_PATHS" && has_adapt=1
    git -C "$FM_ROOT" cat-file -e "$LOCAL_REF:$f" 2>/dev/null || has_absent=1
  done <<EOF
$files
EOF
  # Raw tmux introduced in added (non-comment) lines = needs $FM_MUX rewiring.
  if git -C "$FM_ROOT" show --no-color --format= --unified=0 "$sha" 2>/dev/null \
       | grep -E '^\+' | grep -vE '^\+\+\+' | grep -vE '^\+[[:space:]]*#' \
       | grep -qE '\btmux\b'; then
    has_tmux=1
  fi

  [ "$has_secondmate" -eq 1 ] && { bucket="likely-skip"; reasons="touches secondmate subsystem (omitted in this fork)"; }
  if [ "$bucket" = clean ]; then
    [ "$has_agents" -eq 1 ] && { bucket="needs-adapt"; reasons="${reasons:+$reasons; }edits AGENTS.md (fork uses CLAUDE.md)"; }
    [ "$has_adapt" -eq 1 ]  && { bucket="needs-adapt"; reasons="${reasons:+$reasons; }touches a psmux-adapted script"; }
    [ "$has_tmux" -eq 1 ]   && { bucket="needs-adapt"; reasons="${reasons:+$reasons; }adds raw 'tmux' (rewire to \$FM_MUX)"; }
  fi
  [ "$bucket" = clean ] && [ "$has_absent" -eq 1 ] && reasons="adds files new to the fork; cherry-pick should apply"
  [ -n "$reasons" ] || reasons="no fork-adapted surface touched"
  printf '%s|%s' "$bucket" "$reasons"
}

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

commits=$(git -C "$FM_ROOT" log --no-merges --reverse --format='%H' "$LOCAL_REF..$UPSTREAM_REF" 2>/dev/null || true)

if [ "$MODE" = show ]; then
  full=$(git -C "$FM_ROOT" rev-parse --verify "$SHA^{commit}" 2>/dev/null) || { echo "error: not a commit: $SHA" >&2; exit 1; }
  res=$(classify "$full"); bucket=${res%%|*}; reasons=${res#*|}
  printf 'commit %s\n' "$(git -C "$FM_ROOT" log -1 --format='%h %s' "$full")"
  printf 'bucket: %s\nwhy: %s\n\nfiles:\n' "$bucket" "$reasons"
  git -C "$FM_ROOT" show --no-color --name-only --format= "$full" | sed '/^$/d' | while IFS= read -r f; do
    tag="clean"
    if in_list "$f" "$SECONDMATE_PATHS" || printf '%s' "$f" | grep -q 'secondmate'; then tag="skip (secondmate)"
    elif [ "$f" = AGENTS.md ]; then tag="adapt -> CLAUDE.md"
    elif in_list "$f" "$ADAPTED_PATHS"; then tag="adapt (psmux surface)"
    elif ! git -C "$FM_ROOT" cat-file -e "$LOCAL_REF:$f" 2>/dev/null; then tag="new file"
    fi
    printf '  %-22s %s\n' "$tag" "$f"
  done
  printf '\n--- diff ---\n'
  git -C "$FM_ROOT" show --no-color "$full"
  exit 0
fi

if [ -z "$commits" ]; then
  [ "$MODE" = json ] && echo '[]' || echo "Up to date: no commits on $UPSTREAM_REF that are missing from $LOCAL_REF."
  exit 0
fi

# Classify each commit ONCE into a temp file (sha<TAB>short<TAB>bucket<TAB>subject<TAB>reasons),
# then render. Process spawning is expensive on Windows, so a single pass matters.
TMP=$(mktemp "${TMPDIR:-/tmp}/fm-port.XXXXXX")
trap 'rm -f "$TMP"' EXIT
printf '%s\n' "$commits" | while IFS= read -r sha; do
  [ -n "$sha" ] || continue
  res=$(classify "$sha"); bucket=${res%%|*}; reasons=${res#*|}
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$sha" "$(git -C "$FM_ROOT" rev-parse --short "$sha")" "$bucket" \
    "$(git -C "$FM_ROOT" log -1 --format='%s' "$sha")" "$reasons" >> "$TMP"
done

if [ "$MODE" = json ]; then
  printf '['
  first=1
  while IFS="$(printf '\t')" read -r sha short bucket subject reasons; do
    [ -n "$sha" ] || continue
    [ "$first" -eq 1 ] || printf ','
    first=0
    printf '{"sha":"%s","short":"%s","bucket":"%s","subject":"%s","why":"%s"}' \
      "$sha" "$short" "$bucket" "$(json_escape "$subject")" "$(json_escape "$reasons")"
  done < "$TMP"
  printf ']\n'
  exit 0
fi

# Human list (oldest first = suggested porting order), with a summary tail.
printf 'Upstream-only commits (%s..%s), oldest first:\n\n' "$LOCAL_REF" "$UPSTREAM_REF"
while IFS="$(printf '\t')" read -r sha short bucket subject reasons; do
  [ -n "$sha" ] || continue
  printf '%-8s [%-11s] %s\n             %s\n' "$short" "$bucket" "$subject" "$reasons"
done < "$TMP"
printf '\nsummary:\n'
cut -f3 "$TMP" | sort | uniq -c
printf '\nNext: port one commit (or a small batch) at a time - branch, cherry-pick, re-apply tmux->$FM_MUX and AGENTS->CLAUDE for needs-adapt, then open a gated PR. Never merge/fast-forward %s into the fork. See the /port-upstream skill.\n' "$UPSTREAM_REF"
