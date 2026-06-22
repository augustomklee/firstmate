#!/usr/bin/env bash
# Print the tail of a crewmate pane (bounded, for cheap diagnosis).
# Usage: fm-peek.sh <window> [lines=40]
#   <window> may be a bare window name (fm-xyz) or session:window.
set -eu

DIR="$(dirname "${BASH_SOURCE[0]}")"
"$DIR/fm-guard.sh" || true
# shellcheck source=bin/fm-mux-lib.sh
. "$DIR/fm-mux-lib.sh"

resolve() {
  case "$1" in
    *:*) echo "$1" ;;
    *) "$FM_MUX" list-windows -a -F '#{session_name}:#{window_name}' | grep -m1 ":$1\$" \
         || { echo "error: no window named $1" >&2; exit 1; } ;;
  esac
}

T=$(resolve "$1")
N=${2:-40}
"$FM_MUX" capture-pane -p -t "$T" -S -"$N"
