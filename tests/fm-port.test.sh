#!/usr/bin/env bash
# fm-port.sh: fork-aware upstream porter (report-only).
# Builds a fake repo with an upstream remote carrying commits the fork lacks, then
# asserts each commit is classified into the right bucket and that running the
# porter never mutates the fork (no merge / fast-forward path).
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="$ROOT/bin/fm-port.sh"

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-port-tests.XXXXXX")
cleanup() { [ -n "${TMP_ROOT:-}" ] && rm -rf "$TMP_ROOT"; }
trap cleanup EXIT

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

git_q() { git -C "$1" -c user.email=t@t -c user.name=t -c commit.gpgsign=false "${@:2}" >/dev/null 2>&1; }

# --- build: fork repo + bare upstream + an upstream working clone --------------
FORK="$TMP_ROOT/fork"
UP_BARE="$TMP_ROOT/up.git"
UP_WORK="$TMP_ROOT/up-work"

mkdir -p "$FORK"
git_q "$FORK" init -b main
mkdir -p "$FORK/bin"
printf 'base\n' > "$FORK/README.md"
printf '#!/usr/bin/env bash\necho hi\n' > "$FORK/bin/fm-spawn.sh"   # exists in fork = adapted surface
git -C "$FORK" add -A >/dev/null 2>&1
git_q "$FORK" commit -m "base"

git init --bare -b main "$UP_BARE" >/dev/null 2>&1
git_q "$FORK" remote add origin "$UP_BARE"
git_q "$FORK" push origin main

# Upstream working clone gets the new commits, then pushes them to the bare remote.
git clone -q "$UP_BARE" "$UP_WORK" >/dev/null 2>&1
mkdir -p "$UP_WORK/bin"

# (1) clean: a brand-new ordinary file, no adapted surface, no tmux.
printf 'notes\n' > "$UP_WORK/NOTES.md"
git -C "$UP_WORK" add -A >/dev/null 2>&1
git_q "$UP_WORK" commit -m "clean: add NOTES.md"

# (2) needs-adapt: edits AGENTS.md (fork uses CLAUDE.md).
printf 'agents\n' > "$UP_WORK/AGENTS.md"
git -C "$UP_WORK" add -A >/dev/null 2>&1
git_q "$UP_WORK" commit -m "adapt: edit AGENTS.md"

# (3) needs-adapt: introduces a raw tmux call in a script.
printf '#!/usr/bin/env bash\ntmux list-windows\n' > "$UP_WORK/bin/fm-thing.sh"
git -C "$UP_WORK" add -A >/dev/null 2>&1
git_q "$UP_WORK" commit -m "adapt: add raw tmux call"

# (4) likely-skip: the secondmate subsystem the fork omits.
printf '#!/usr/bin/env bash\necho seed\n' > "$UP_WORK/bin/fm-home-seed.sh"
git -C "$UP_WORK" add -A >/dev/null 2>&1
git_q "$UP_WORK" commit -m "skip: secondmate home seed"

git_q "$UP_WORK" push origin main
git_q "$FORK" fetch origin

# --- run the porter (report-only) against the fork ----------------------------
before=$(git -C "$FORK" rev-parse HEAD)
out=$(FM_ROOT_OVERRIDE="$FORK" FM_PORT_UPSTREAM_REMOTE=origin "$PORT" --no-fetch --json 2>/dev/null)
after=$(git -C "$FORK" rev-parse HEAD)

bucket_for() {  # <subject-substring> -> bucket from the JSON
  # Split into one object per line (drop the closing brace), keep the object whose
  # subject matches, then read its bucket. Splitting on '}' (not ',') keeps each
  # object's fields - including "bucket" and "subject" - together on one line.
  printf '%s' "$out" | tr '}' '\n' | grep -F "$1" | sed -n 's/.*"bucket":"\([a-z-]*\)".*/\1/p' | head -1
}

test_clean() {
  [ "$(bucket_for 'add NOTES.md')" = clean ] || fail "NOTES.md commit not classified clean: $out"
  pass "a new ordinary file is classified clean"
}
test_agents_needs_adapt() {
  [ "$(bucket_for 'edit AGENTS.md')" = needs-adapt ] || fail "AGENTS.md commit not needs-adapt: $out"
  pass "an AGENTS.md edit is classified needs-adapt"
}
test_tmux_needs_adapt() {
  [ "$(bucket_for 'add raw tmux call')" = needs-adapt ] || fail "raw-tmux commit not needs-adapt: $out"
  pass "a raw tmux call is classified needs-adapt"
}
test_secondmate_skip() {
  [ "$(bucket_for 'secondmate home seed')" = likely-skip ] || fail "secondmate commit not likely-skip: $out"
  pass "the secondmate subsystem is classified likely-skip"
}
test_report_only_no_mutation() {
  [ "$before" = "$after" ] || fail "fm-port.sh moved HEAD ($before -> $after): it must be report-only"
  pass "running the porter never mutates the fork (HEAD unchanged)"
}
test_no_merge_path_in_source() {
  # The porter must invoke no merge/fast-forward/pull command. Strip full-line
  # comments first (the header and guidance text legitimately say "never merge"),
  # then look for actual git command tokens.
  if grep -vE '^[[:space:]]*#' "$PORT" \
       | grep -qE 'git[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?(merge|pull|rebase)\b|--ff-only'; then
    fail "fm-port.sh invokes a merge/pull/rebase/ff command; it must only read and report"
  fi
  pass "fm-port.sh invokes no merge/pull/fast-forward command"
}

test_clean
test_agents_needs_adapt
test_tmux_needs_adapt
test_secondmate_skip
test_report_only_no_mutation
test_no_merge_path_in_source
