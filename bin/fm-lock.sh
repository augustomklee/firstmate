#!/usr/bin/env bash
# Acquire or inspect the single-firstmate session lock.
#
# The lock identity must be stable for the whole firstmate session. The original design
# walked the process ancestry to find the agent (harness) PID. That fails under harnesses
# that run each tool call in a detached shell: Claude Code on Windows gives every Bash
# tool call a bash with ppid=1, so the chain never reaches claude.exe. Identity therefore
# resolves in two ways:
#   1. A stable per-session env marker when the harness provides one (preferred, and the
#      only thing that works when ancestry is severed) - e.g. CLAUDE_CODE_SESSION_ID.
#   2. Otherwise the harness PID found by walking ancestry (the real-Unix path, unchanged).
#
# Liveness:
#   - a PID identity is checked with `kill -0` (precise).
#   - a session-id identity cannot be pinged, so it counts as live only while its recorded
#     timestamp is fresh (within FM_LOCK_GRACE, default 6h). A crashed session's lock thus
#     auto-clears after the grace; re-acquiring as the same identity refreshes the stamp.
# Usage: fm-lock.sh           acquire; exit 1 if another live session holds it
#        fm-lock.sh status    print holder and liveness; always exits 0
set -u

FM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=bin/fm-proc-lib.sh
. "$FM_ROOT/bin/fm-proc-lib.sh"
STATE="$FM_ROOT/state"
LOCK="$STATE/.lock"
mkdir -p "$STATE"

# Known harness command names; extend when a new adapter is verified.
HARNESS_RE='claude|codex|opencode|^pi$'
GRACE=${FM_LOCK_GRACE:-21600}   # seconds a session-id lock may age before it is stale

now() { date +%s 2>/dev/null || echo 0; }

# Stable identity for this session: env session id if available, else ancestry PID.
my_identity() {
  [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] && { echo "sid:claude:$CLAUDE_CODE_SESSION_ID"; return 0; }
  [ -n "${PI_SESSION_ID:-}" ] && { echo "sid:pi:$PI_SESSION_ID"; return 0; }
  local pid=$$ comm args
  for _ in 1 2 3 4 5 6 7 8; do
    comm=$(fm_proc_comm "$pid"); [ -n "$comm" ] || return 1
    args=$(fm_proc_args "$pid")
    if printf '%s' "$(basename "$comm")" | grep -qE "$HARNESS_RE"; then echo "pid:$pid"; return 0; fi
    case "$comm" in
      *node*|*python*) printf '%s' "$args" | grep -qE "$HARNESS_RE" && { echo "pid:$pid"; return 0; } ;;
    esac
    pid=$(fm_proc_ppid "$pid")
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || return 1
  done
  return 1
}

# holder_alive <identity> <epoch>
holder_alive() {
  local id=$1 epoch=${2:-0} pid comm
  case "$id" in
    pid:*)
      pid=${id#pid:}
      kill -0 "$pid" 2>/dev/null || return 1
      comm=$(fm_proc_comm "$pid"); [ -n "$comm" ] || return 1
      printf '%s %s' "$(basename "$comm")" "$(fm_proc_args "$pid")" | grep -qE "$HARNESS_RE"
      ;;
    sid:*)
      case "$epoch" in ''|*[!0-9]*) return 1 ;; esac
      [ "$(( $(now) - epoch ))" -lt "$GRACE" ]
      ;;
    *) return 1 ;;
  esac
}

# Parse the lock file into LK_ID, LK_EPOCH (tab-separated; tolerates a legacy bare PID).
read_lock() {
  LK_ID=""; LK_EPOCH=0
  [ -f "$LOCK" ] || return 1
  local raw; raw=$(cat "$LOCK" 2>/dev/null)
  case "$raw" in
    *"	"*) LK_ID=${raw%%	*}; LK_EPOCH=${raw#*	} ;;
    [0-9]*)  LK_ID="pid:$raw"; LK_EPOCH=0 ;;
    *)       LK_ID=$raw; LK_EPOCH=0 ;;
  esac
}

if [ "${1:-}" = "status" ]; then
  if ! read_lock; then echo "lock: free"; exit 0; fi
  if holder_alive "$LK_ID" "$LK_EPOCH"; then echo "lock: held by live session ($LK_ID)"; else echo "lock: stale ($LK_ID)"; fi
  exit 0
fi

me=$(my_identity) || { echo "error: cannot determine a stable session identity" >&2; exit 1; }
if read_lock && [ "$LK_ID" != "$me" ] && holder_alive "$LK_ID" "$LK_EPOCH"; then
  echo "error: another live firstmate session holds the lock ($LK_ID); operate read-only until resolved (remove state/.lock if you are sure none is running)" >&2
  exit 1
fi
printf '%s\t%s\n' "$me" "$(now)" > "$LOCK"
echo "lock acquired: $me"
