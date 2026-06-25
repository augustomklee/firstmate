#!/usr/bin/env bash
# Resolve the multiplexer command ($FM_MUX).
#
# Default is herdr (https://herdr.dev), the agent multiplexer: tmux-style panes
# plus native AI-agent state awareness. firstmate speaks tmux, so herdr is driven
# through the tmux-verb translation shim bin/fm-mux-herdr.sh (crewmates become tabs
# in a dedicated workspace; see that file). psmux (Windows) / tmux (real Unix) are
# the retained FALLBACK - tmux-compatible, used when herdr is not installed.
#
# Resolution (FM_USE_HERDR overrides the auto default):
#   FM_USE_HERDR=1   -> force herdr (the shim)
#   FM_USE_HERDR=0   -> force psmux/tmux (skip herdr even if installed)
#   unset / "auto"   -> herdr if `herdr` is on PATH, else psmux, else tmux
# Explicitly setting FM_MUX still wins over all of this.
#
# Source this file; do not execute it. After sourcing, call as "$FM_MUX <verb>".
if [ -z "${FM_MUX:-}" ]; then
  _fm_herdr_shim="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-mux-herdr.sh"
  # herdr is a Windows-native binary; the installer adds it to the Windows user
  # PATH, which a fresh MSYS/Git-Bash may not inherit. So treat herdr as present
  # if it's on PATH, FM_HERDR_BIN points at it, or it's at the standalone install
  # location (mirrors the shim's own resolution).
  _fm_herdr_present() {
    command -v herdr >/dev/null 2>&1 && return 0
    [ -n "${FM_HERDR_BIN:-}" ] && [ -x "${FM_HERDR_BIN}" ] && return 0
    [ -x "${LOCALAPPDATA:-}/Programs/Herdr/bin/herdr.exe" ] && return 0
    [ -x "${HOME:-}/.herdr/packages/standalone/current/herdr.exe" ] && return 0
    return 1
  }
  case "${FM_USE_HERDR:-auto}" in
    1) FM_MUX="$_fm_herdr_shim" ;;
    0) if command -v psmux >/dev/null 2>&1; then FM_MUX=psmux; else FM_MUX=tmux; fi ;;
    *) if _fm_herdr_present; then FM_MUX="$_fm_herdr_shim"
       elif command -v psmux >/dev/null 2>&1; then FM_MUX=psmux
       else FM_MUX=tmux; fi ;;
  esac
  unset _fm_herdr_shim
  unset -f _fm_herdr_present 2>/dev/null || true
fi
