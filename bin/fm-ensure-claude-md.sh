#!/usr/bin/env bash
# Ensure a project worktree keeps CLAUDE.md as its real project-intrinsic
# knowledge file. This fork targets Claude Code, so CLAUDE.md is canonical: a
# real committed file, with no AGENTS.md and no symlink. Creates a minimal
# CLAUDE.md skeleton when neither file exists, migrates the legacy world (a real
# AGENTS.md with CLAUDE.md as a symlink) by promoting AGENTS.md to CLAUDE.md and
# dropping the symlink, leaves an existing real CLAUDE.md untouched, and refuses
# to clobber distinct real files or other ambiguous states.
# This is a worktree utility for crewmates, not a supervision script, so it does
# not call fm-guard.sh.
# Usage: fm-ensure-claude-md.sh [repo-or-worktree-dir]
set -eu

usage() {
  echo "usage: fm-ensure-claude-md.sh [repo-or-worktree-dir]" >&2
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac
[ "$#" -le 1 ] || { usage; exit 1; }

DIR=${1:-.}
[ -d "$DIR" ] || { echo "error: not a directory: $DIR" >&2; exit 1; }
DIR=$(cd "$DIR" && pwd -P)
cd "$DIR"

AGENTS=AGENTS.md
CLAUDE=CLAUDE.md

write_skeleton() {
  cat > "$CLAUDE" <<'EOF'
# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

- Add durable project-specific notes here as they are discovered through real work.
EOF
}

# CLAUDE.md is already the real regular file: nothing to do, unless a stray
# AGENTS.md still sits alongside it (which this convention no longer allows).
if [ -f "$CLAUDE" ] && [ ! -L "$CLAUDE" ]; then
  if [ -e "$AGENTS" ] || [ -L "$AGENTS" ]; then
    echo "conflict: CLAUDE.md is the real file but a stray AGENTS.md also exists in $DIR; reconcile them manually" >&2
    exit 1
  fi
  echo "unchanged: CLAUDE.md is already the real file in $DIR"
  exit 0
fi

# Legacy world: a real AGENTS.md, with CLAUDE.md a symlink to it (or missing).
# Promote AGENTS.md to CLAUDE.md and drop any symlink.
if [ -f "$AGENTS" ] && [ ! -L "$AGENTS" ]; then
  if [ -L "$CLAUDE" ]; then
    rm -f "$CLAUDE"
    mv "$AGENTS" "$CLAUDE"
    echo "migrated: promoted AGENTS.md to CLAUDE.md and removed the symlink in $DIR"
    exit 0
  fi
  if [ ! -e "$CLAUDE" ]; then
    mv "$AGENTS" "$CLAUDE"
    echo "migrated: renamed AGENTS.md to CLAUDE.md in $DIR"
    exit 0
  fi
  echo "conflict: AGENTS.md and a non-regular CLAUDE.md both exist in $DIR; reconcile them manually" >&2
  exit 1
fi

# AGENTS.md present but not a plain regular file (symlink or special): refuse.
if [ -e "$AGENTS" ] || [ -L "$AGENTS" ]; then
  echo "conflict: AGENTS.md in $DIR is not a regular file; reconcile it manually" >&2
  exit 1
fi

# CLAUDE.md is a symlink with no AGENTS.md to resolve: refuse.
if [ -L "$CLAUDE" ]; then
  echo "conflict: CLAUDE.md in $DIR is a symlink but there is no AGENTS.md to promote; reconcile it manually" >&2
  exit 1
fi

# CLAUDE.md exists but is neither a regular file nor a symlink: refuse.
if [ -e "$CLAUDE" ]; then
  echo "conflict: CLAUDE.md in $DIR exists but is not a regular file; reconcile it manually" >&2
  exit 1
fi

# Neither file exists: lay down the skeleton.
write_skeleton
echo "created: CLAUDE.md in $DIR"
