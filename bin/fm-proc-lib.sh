#!/usr/bin/env bash
# Portable process-introspection helpers.
#
# The fleet scripts originally read process info with `ps -o comm=/args=/ppid= -p <pid>`.
# That BSD/procps syntax is rejected by the Cygwin/MSYS `ps` shipped with Git Bash on
# Windows ("ps: unknown option -- o"). Where the Cygwin/MSYS procfs is present we read
# /proc/<pid>/{exename,cmdline,ppid}; otherwise we fall back to `ps -o` for real Unix.
#
# Source this file; do not execute it. Each helper prints to stdout and is empty on miss.

fm_proc_comm() {  # command path of <pid> (callers basename it, as the ps version required)
  if [ -r "/proc/$1/exename" ]; then
    cat "/proc/$1/exename" 2>/dev/null
  else
    ps -o comm= -p "$1" 2>/dev/null
  fi
}

fm_proc_args() {  # full command line of <pid>, space-joined
  if [ -r "/proc/$1/cmdline" ]; then
    tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null
  else
    ps -o args= -p "$1" 2>/dev/null
  fi
}

fm_proc_ppid() {  # parent pid of <pid>
  if [ -r "/proc/$1/ppid" ]; then
    tr -dc '0-9' < "/proc/$1/ppid" 2>/dev/null
  else
    ps -o ppid= -p "$1" 2>/dev/null | tr -d ' '
  fi
}
