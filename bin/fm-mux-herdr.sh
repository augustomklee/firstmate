#!/usr/bin/env bash
# fm-mux-herdr.sh — a tmux-verb -> herdr translation shim, so firstmate can drive
# herdr (https://herdr.dev) as a TRIAL multiplexer without rewiring its call sites.
#
# Why a shim and not FM_MUX=herdr: firstmate speaks the tmux command language
# (new-session / new-window / send-keys / capture-pane / display-message /
# list-windows / kill-window, plus #{...} formats). herdr does NOT — it has its own
# CLI over a socket (workspace/tab/pane create|list|read|send-text|send-keys|close).
# This script accepts the exact tmux argv firstmate emits on "$FM_MUX <verb> ..."
# and re-expresses it as herdr calls, so EVERY existing call site works unchanged.
# It is selected only when FM_USE_HERDR=1 (see bin/fm-mux-lib.sh); psmux stays the
# default, so the real fleet is untouched and the trial is fully reversible.
#
# Topology (the captain's plan): ONE shared herdr session. firstmate is confined to
# a single dedicated "crewmates" workspace — every crewmate `fm-<id>` becomes a TAB
# in it (NOT a new session, NOT a workspace-per-crewmate). The captain's hand-driven
# Claude sessions live in OTHER workspaces. Isolation is structural: every
# enumeration here passes --workspace <crewmates>, so firstmate cannot see or touch
# any pane outside that workspace. The workspace is auto-ensured (created on first
# use) and resolved by label.
#
# Object-model mapping:
#   tmux session "firstmate"   -> the crewmates workspace (label $FM_HERDR_WS)
#   tmux window  "fm-<id>"     -> a tab in that workspace, labelled "fm-<id>"
#   tmux target  "firstmate:fm-<id>[.pane]" -> that tab's single pane
#
# Known degraded primitive (the "relax" we flagged): herdr exposes neither a cursor
# row (#{cursor_y}) nor an absolute-line capture, so fm-tmux-lib's exact
# "capture just the cursor row with ANSI" composer check cannot be reproduced 1:1.
# We emulate it with a best-effort picker: return the composer/input line chosen
# from the visible ANSI buffer (skipping blank/border-only and footer lines, bottom
# up). firstmate's existing ghost/border strip + classify then runs unchanged. This
# is good enough for a trial; a real switch would instead lean on herdr's native
# `wait agent-status` / pane.agent_status. Tune the footer filter with
# FM_HERDR_FOOTER_RE.
#
# Env:
#   FM_HERDR_WS       crewmates workspace label   (default: crewmates)
#   FM_HERDR_BIN      herdr executable            (default: herdr on PATH)
#   FM_HERDR_FOOTER_RE  regex of footer lines to skip when picking the composer row
set -u

WS_LABEL="${FM_HERDR_WS:-crewmates}"
HERDR="${FM_HERDR_BIN:-herdr}"
if ! command -v "$HERDR" >/dev/null 2>&1; then
  # Fall back to the standalone install location the PowerShell installer uses.
  for c in "${LOCALAPPDATA:-}/Programs/Herdr/bin/herdr.exe" "$HOME/.herdr/packages/standalone/current/herdr.exe"; do
    [ -x "$c" ] && { HERDR="$c"; break; }
  done
fi

FOOTER_RE="${FM_HERDR_FOOTER_RE:-^\\?|shortcuts|esc to interrupt|esc interrupt|ctrl\\+|tab to|enter to send|newline|accept edits|bypass}"

# ensure_server: start a headless herdr server if none is running, so a crewmate
# spawn never hard-fails when the captain is momentarily outside herdr (the default
# is herdr-if-installed, which may run before they've attached). Idempotent.
ensure_server() {
  "$HERDR" status server 2>/dev/null | grep -q '^status: running' && return 0
  "$HERDR" server >/dev/null 2>&1 &
  local i=0
  while [ "$i" -lt 15 ]; do
    "$HERDR" status server 2>/dev/null | grep -q '^status: running' && return 0
    sleep 0.4; i=$((i + 1))
  done
  return 1
}

# ---- herdr JSON helpers (node is a firstmate-required tool; see fm-bootstrap) ----

# ws_id: print the crewmates workspace id, or fail (exit 1) if it does not exist.
ws_id() {
  "$HERDR" workspace list 2>/dev/null | WS_LABEL="$WS_LABEL" node -e '
    let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{
      const o=JSON.parse(s);
      const w=((o.result&&o.result.workspaces)||[]).find(w=>w.label===process.env.WS_LABEL);
      if(w&&w.workspace_id){process.stdout.write(w.workspace_id)}else{process.exit(1)}
    }catch(e){process.exit(2)}});'
}

# ensure_ws: print the crewmates workspace id, creating it (auto-ensure) if absent.
ensure_ws() {
  local id
  if id=$(ws_id); then printf '%s' "$id"; return 0; fi
  "$HERDR" workspace create --label "$WS_LABEL" --no-focus 2>/dev/null | node -e '
    let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{
      const o=JSON.parse(s);process.stdout.write(o.result.workspace.workspace_id)
    }catch(e){process.exit(2)}});'
}

# tab_labels <ws>: one tab label per line (firstmate greps these).
tab_labels() {
  "$HERDR" tab list --workspace "$1" 2>/dev/null | node -e '
    let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{
      const o=JSON.parse(s);((o.result&&o.result.tabs)||[]).forEach(t=>console.log(t.label))
    }catch(e){process.exit(2)}});'
}

# tab_id_for <ws> <label>: print the tab id whose label matches, or fail.
tab_id_for() {
  "$HERDR" tab list --workspace "$1" 2>/dev/null | LBL="$2" node -e '
    let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{
      const o=JSON.parse(s);
      const t=((o.result&&o.result.tabs)||[]).find(t=>t.label===process.env.LBL);
      if(t&&t.tab_id){process.stdout.write(t.tab_id)}else{process.exit(1)}
    }catch(e){process.exit(2)}});'
}

# pane_id_for <ws> <tab_id>: print the (single) pane id in that tab, or fail.
pane_id_for() {
  "$HERDR" pane list --workspace "$1" 2>/dev/null | TAB="$2" node -e '
    let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{
      const o=JSON.parse(s);
      const p=((o.result&&o.result.panes)||[]).find(p=>p.tab_id===process.env.TAB);
      if(p&&p.pane_id){process.stdout.write(p.pane_id)}else{process.exit(1)}
    }catch(e){process.exit(2)}});'
}

# window_of <target>: extract the tmux window name from "sess:win[.pane]" or a bare
# "win", which is our tab label (e.g. fm-abc).
window_of() { local t=$1; t=${t##*:}; t=${t%%.*}; printf '%s' "$t"; }

# pane_for_target <target>: resolve a tmux target to a herdr pane id, or fail.
pane_for_target() {
  local ws label tab
  ws=$(ws_id) || return 1
  label=$(window_of "$1")
  tab=$(tab_id_for "$ws" "$label") || return 1
  pane_id_for "$ws" "$tab"
}

# composer_line <pane>: emulate `capture-pane -e -S cy -E cy` — return the single
# ANSI line firstmate should classify as the composer/cursor row. Walk the visible
# buffer bottom-up, skip blank/border-only and footer lines, return the first real
# line VERBATIM (ANSI preserved). Empty output => firstmate reads an empty composer.
composer_line() {
  "$HERDR" pane read "$1" --source visible --format ansi 2>/dev/null | FOOT="$FOOTER_RE" node -e '
    let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
      const raw=s.replace(/\r/g,"").replace(/\n$/,"").split("\n");
      const foot=new RegExp(process.env.FOOT,"i");
      const strip=l=>l.replace(/\x1b\[[0-9;:]*[A-Za-z]/g,"")
                       .replace(/[│┃|╭╮╰╯┌┐└┘─━═]/g,"")
                       .trim();
      for(let i=raw.length-1;i>=0;i--){
        const p=strip(raw[i]);
        if(!p) continue;
        if(foot.test(p)) continue;
        process.stdout.write(raw[i]);
        return;
      }
    });'
}

# tail_text <pane> <n>: emulate `capture-pane -p -S -<n>` — last n visible lines, plain.
tail_text() {
  "$HERDR" pane read "$1" --source visible --format text 2>/dev/null | tail -n "$2"
}

# is_keyname <token>: 0 if the token is a tmux key name (vs literal text).
is_keyname() {
  case "$1" in
    Enter|Return|Escape|Esc|Tab|Space|BSpace|BTab|Up|Down|Left|Right|Home|End|\
    PageUp|PageDown|PPage|NPage|Insert|IC|Delete|DC|\
    F[1-9]|F1[0-2]|C-*|M-*|S-*) return 0 ;;
    *) return 1 ;;
  esac
}

# herdr_key <token>: map a tmux key name to herdr's send-keys key syntax.
herdr_key() {
  case "$1" in
    Enter|Return) printf 'enter' ;;
    Escape|Esc)   printf 'escape' ;;
    Tab|BTab)     printf 'tab' ;;
    Space)        printf 'space' ;;
    BSpace)       printf 'backspace' ;;
    Up)    printf 'up' ;;    Down)  printf 'down' ;;
    Left)  printf 'left' ;;  Right) printf 'right' ;;
    Home)  printf 'home' ;;  End)   printf 'end' ;;
    PageUp|PPage)   printf 'pageup' ;;
    PageDown|NPage) printf 'pagedown' ;;
    Insert|IC) printf 'insert' ;;
    Delete|DC) printf 'delete' ;;
    C-*) printf 'ctrl+%s' "$(printf '%s' "${1#C-}" | tr 'A-Z' 'a-z')" ;;
    M-*) printf 'alt+%s'  "$(printf '%s' "${1#M-}" | tr 'A-Z' 'a-z')" ;;
    S-*) printf 'shift+%s' "$(printf '%s' "${1#S-}" | tr 'A-Z' 'a-z')" ;;
    F[1-9]|F1[0-2]) printf '%s' "$(printf '%s' "$1" | tr 'A-Z' 'a-z')" ;;
    *) printf '%s' "$1" ;;
  esac
}

# ---- argv parser: collect the tmux flags firstmate uses; rest -> POS[] ----
verb="${1:-}"; shift || true
T=""; SVAL=""; EVAL=""; NAME=""; CDIR=""; SNAME=""; FMT=""
f_p=0; f_e=0; f_l=0; f_a=0
POS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -t) T=$2; shift 2 ;;
    -s) SNAME=$2; shift 2 ;;
    -n) NAME=$2; shift 2 ;;
    -c) CDIR=$2; shift 2 ;;
    -S) SVAL=$2; shift 2 ;;
    -E) EVAL=$2; shift 2 ;;
    -F) FMT=$2; shift 2 ;;
    -p) f_p=1; shift ;;
    -e) f_e=1; shift ;;
    -l) f_l=1; shift ;;
    -a) f_a=1; shift ;;
    -d) shift ;;            # "detached" — implicit for herdr create (--no-focus)
    --) shift; while [ "$#" -gt 0 ]; do POS+=("$1"); shift; done ;;
    *) POS+=("$1"); shift ;;
  esac
done

case "$verb" in
  has-session)
    # exit 0 iff the crewmates workspace exists.
    ws_id >/dev/null 2>&1
    ;;

  new-session)
    # Ensure the crewmates workspace (auto-create). -d/-s firstmate are no-ops here.
    ensure_server || exit 1
    ensure_ws >/dev/null 2>&1
    ;;

  new-window)
    # New crewmate -> a tab in the crewmates workspace, labelled $NAME, cwd $CDIR.
    ensure_server || exit 1
    ws=$(ensure_ws) || exit 1
    if [ -n "$CDIR" ]; then
      "$HERDR" tab create --workspace "$ws" --label "$NAME" --cwd "$CDIR" --no-focus >/dev/null 2>&1
    else
      "$HERDR" tab create --workspace "$ws" --label "$NAME" --no-focus >/dev/null 2>&1
    fi
    ;;

  list-windows)
    # -a -F '#{session_name}:#{window_name}'  -> firstmate:<label> for crewmates ws only.
    # -t SES -F '#{window_name}'              -> bare labels.
    ws=$(ws_id) || exit 0   # no workspace yet => no windows (match tmux: empty list)
    if [ "$f_a" = 1 ]; then
      tab_labels "$ws" | while IFS= read -r l; do printf 'firstmate:%s\n' "$l"; done
    else
      tab_labels "$ws"
    fi
    ;;

  send-keys)
    pane=$(pane_for_target "$T") || exit 1
    if [ "$f_l" = 1 ]; then
      # Literal text: send each positional verbatim.
      for a in "${POS[@]:-}"; do
        [ -n "$a" ] || continue
        "$HERDR" pane send-text "$pane" "$a" >/dev/null 2>&1 || exit 1
      done
    else
      # Mixed sequence: key names go as keys, everything else as literal text.
      for a in "${POS[@]:-}"; do
        [ -n "$a" ] || continue
        if is_keyname "$a"; then
          "$HERDR" pane send-keys "$pane" "$(herdr_key "$a")" >/dev/null 2>&1 || exit 1
        else
          "$HERDR" pane send-text "$pane" "$a" >/dev/null 2>&1 || exit 1
        fi
      done
    fi
    ;;

  capture-pane)
    pane=$(pane_for_target "$T") || exit 1
    if [ -n "$EVAL" ]; then
      # -S cy -E cy : the single composer/cursor row (always wants ANSI here).
      composer_line "$pane"
    else
      # -S -N : tail of the visible buffer, plain text.
      n=${SVAL#-}; [ -n "$n" ] || n=40
      case "$n" in *[!0-9]*) n=40 ;; esac
      tail_text "$pane" "$n"
    fi
    ;;

  display-message)
    # The format/message is a POSITIONAL arg here ('#{cursor_y}', '#{pane_id}', or a
    # status string), not -F. Inspect the first positional.
    fmt="${POS[0]:-}"
    if [ "$f_p" = 1 ]; then
      case "$fmt" in
        *cursor_y*)
          # No cursor row in herdr. Emit a valid number so fm-tmux-lib proceeds; the
          # paired `capture-pane -S cy -E cy` is what actually drives composer detect.
          pane_for_target "$T" >/dev/null 2>&1 || exit 1
          printf '0'
          ;;
        *)
          # #{pane_id} or other: used only as an existence probe (>/dev/null).
          pane=$(pane_for_target "$T") || exit 1
          printf '%s' "$pane"
          ;;
      esac
    else
      # Status-line message (no -p). herdr has no equivalent; firstmate uses `|| true`.
      :
    fi
    ;;

  kill-window)
    ws=$(ws_id) || exit 0
    label=$(window_of "$T")
    tab=$(tab_id_for "$ws" "$label") || exit 0
    "$HERDR" tab close "$tab" >/dev/null 2>&1 || true
    ;;

  agent-status)
    # Non-tmux verb (firstmate inject-guard, fm-tmux-lib.sh): print the pane's herdr
    # agent_status (idle|working|blocked|done|unknown), populated by the herdr Claude
    # integration hook. Fails if the pane is gone, so callers can treat that as unknown.
    pane=$(pane_for_target "$T") || exit 1
    "$HERDR" pane get "$pane" 2>/dev/null | node -e '
      let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{
        process.stdout.write((JSON.parse(s).result.pane.agent_status)||"unknown")
      }catch(e){process.exit(2)}});'
    ;;

  *)
    echo "fm-mux-herdr: unsupported verb: $verb" >&2
    exit 2
    ;;
esac
