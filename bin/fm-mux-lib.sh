#!/usr/bin/env bash
# Resolve the terminal multiplexer command.
#
# On Windows the user's real multiplexer is psmux - a tmux 3.3.6-compatible wrapper
# (psmux.exe) with Windows-aware pane setup and Claude teammate-mode integration. The
# bundled raw tmux.exe sets panes up differently: `treehouse get` launched under raw
# tmux drops into cmd.exe, while under psmux it lands in the MINGW64 bash subshell the
# POSIX launch path expects. So prefer psmux when present and fall back to tmux on real
# Unix. Override explicitly with FM_MUX.
#
# Source this file; do not execute it. After sourcing, call the multiplexer as "$FM_MUX".
if [ -z "${FM_MUX:-}" ]; then
  if command -v psmux >/dev/null 2>&1; then FM_MUX=psmux; else FM_MUX=tmux; fi
fi
