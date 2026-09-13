#!/usr/bin/env bash
# List player tmux sessions with a cheap, harness-neutral state.
#
#   busy   the pane wrote output within the last QUIET seconds
#   idle   quiet for QUIET+ seconds: at a prompt, asking a question, or finished
#   dead   the pane's command has exited
#
# Scope: players of one repo (--repo <path>, else the cwd's repo) when the cwd is inside
# a git repo; every player on the machine (--all) otherwise. --all adds a REPO column and
# prints full session names, which every other script accepts.
#
# QUIET is seconds since the pane last produced output (tmux window_activity), so one
# tmux call covers every session. It cannot say *why* a session is idle — use screen.sh
# (or a small model reading it) for that. A harness that redraws a clock every second
# always reads busy; --sample N compares two screenshots N seconds apart instead.
#
# Usage: sessions.sh [--all] [--repo <path>] [--quiet SECONDS] [--sample SECONDS] [--json]
# Always exits 0 (it runs at skill load, where a failure would abort the skill).
. "$(dirname "$(realpath "$0")")/_lib.sh"

# 3 s: agent UIs animate a spinner several times a second while working, so anything
# quieter than a few seconds is waiting rather than thinking.
QUIET=3
ALL=0; SAMPLE=0; JSON=0
while [ $# -gt 0 ]; do case "$1" in
  --all) ALL=1;; --repo) ORCH_REPO="$2"; shift;; --quiet) QUIET="$2"; shift;; --sample) SAMPLE="$2"; shift;; --json) JSON=1;;
  -h|--help) sed -n '2,18p' "$0"; exit 0;;
  *) echo "sessions.sh: unknown argument $1" >&2; exit 0;; esac; shift; done
command -v tmux >/dev/null || { echo "tmux is not installed"; exit 0; }

in_repo || ALL=1
if [ $ALL = 1 ]; then prefix=""; pattern="$PLAYER_RE"; else prefix="$(session_prefix)"; pattern="^$prefix"; fi
declare -A before
if [ "$SAMPLE" -gt 0 ]; then
  while IFS= read -r n; do before[$n]="$(screen_text "$n" | md5sum)"; done \
    < <(tmux ls -F '#{session_name}' 2>/dev/null | grep -E "$pattern" || true)
  sleep "$SAMPLE"
fi

now=$(date +%s); rows=0; first=1
[ $JSON = 1 ] && printf '['
while IFS='|' read -r name dead cmd activity path title; do
  rows=$((rows+1))
  quiet=$(( now - ${activity:-$now} )); [ $quiet -lt 0 ] && quiet=0
  if [ "${dead:-1}" = 1 ]; then state=dead
  elif [ "$SAMPLE" -gt 0 ]; then
    if [ "${before[$name]:-}" != "$(screen_text "$name" | md5sum)" ]; then state=busy; else state=idle; fi
  elif [ $quiet -lt "$QUIET" ]; then state=busy
  else state=idle; fi
  short="${name#$prefix}"; repo="$(repo_of_path "$path")"
  if [ $JSON = 1 ]; then
    [ $first = 1 ] || printf ','; first=0
    printf '{"session":"%s","tmux":"%s","repo":%s,"state":"%s","cmd":"%s","quiet_s":%s,"title":%s}' \
      "$short" "$name" "$(printf %s "$repo" | jq -Rs .)" "$state" "$cmd" "$quiet" "$(printf %s "$title" | jq -Rs .)"
  elif [ $ALL = 1 ]; then
    [ $rows = 1 ] && printf '%-5s %6s  %-40s %-62s %-9s %s\n' STATE QUIET REPO SESSION CMD TITLE
    printf '%-5s %5ss  %-40s %-62s %-9s %s\n' "$state" "$quiet" "$(printf %s "$repo" | cut -c1-40)" "$short" "$cmd" "$(printf %s "$title" | cut -c1-50)"
  else
    [ $rows = 1 ] && printf '%-5s %6s  %-44s %-9s %s\n' STATE QUIET SESSION CMD TITLE
    printf '%-5s %5ss  %-44s %-9s %s\n' "$state" "$quiet" "$short" "$cmd" "$(printf %s "$title" | cut -c1-60)"
  fi
done < <(tmux list-panes -a -F '#{session_name}|#{pane_dead}|#{pane_current_command}|#{window_activity}|#{pane_current_path}|#{pane_title}' 2>/dev/null | grep -E "$pattern" || true)
[ $JSON = 1 ] && printf ']\n'
if [ $rows = 0 ] && [ $JSON = 0 ]; then
  if [ $ALL = 1 ]; then echo "no player sessions on this machine"; else echo "no sessions with prefix $prefix (repo $(repo_root)); --all lists every repo's"; fi
fi
exit 0
