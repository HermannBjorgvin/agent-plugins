#!/usr/bin/env bash
# List player tmux sessions with a cheap, harness-neutral state and the session's tags.
#
#   busy   the pane wrote output within the last QUIET seconds
#   idle   quiet for QUIET+ seconds: at a prompt, asking a question, or finished
#   dead   the pane's command has exited
#
# Scope: players of one repo (--repo <path>, else the cwd's repo) when the cwd is inside
# a git repo; every player on the machine (--all) otherwise. --all adds a REPO column and
# prints full session names, which every other script accepts.
#
# AGENT, ORCHESTRATOR and LAST-REPORT come from the session's @orchestra-agent,
# @orchestra-orchestrator and @orchestra-last-report tags (empty when unset); REPO prefers
# @orchestra-repo and falls back to the pane's path. --json adds "agent", "orchestrator",
# "last_report", "repo" and "branch" (@orchestra-branch) fields. Everything comes from one
# tmux list-panes call.
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
  -h|--help) sed -n '2,24p' "$0"; exit 0;;
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

# Fields are tab-separated (tag values never contain a tab; the title comes last so it may). A
# whitespace IFS makes `read` collapse the empty fields of unset tags, so lines are split by hand.
TAB=$'\t'
FORMAT="#{session_name}${TAB}#{pane_dead}${TAB}#{pane_current_command}${TAB}#{window_activity}${TAB}#{pane_current_path}${TAB}#{$TAG_AGENT}${TAB}#{$TAG_ORCHESTRATOR}${TAB}#{$TAG_LAST_REPORT}${TAB}#{$TAG_REPO}${TAB}#{$TAG_BRANCH}${TAB}#{pane_title}"
split_tabs() {
  local line="$1"; F=()
  while case "$line" in *"$TAB"*) true;; *) false;; esac; do F+=("${line%%"$TAB"*}"); line="${line#*"$TAB"}"; done
  F+=("$line")
}
json_str() { printf %s "$1" | jq -Rs .; }
now=$(date +%s); rows=0; first=1
[ $JSON = 1 ] && printf '['
while IFS= read -r line; do
  split_tabs "$line"; set -- "${F[@]}"
  name="${1:-}"; dead="${2:-}"; cmd="${3:-}"; activity="${4:-}"; path="${5:-}"; agent="${6:-}"; orch="${7:-}"; last="${8:-}"; tag_repo="${9:-}"; branch="${10:-}"
  title="$(IFS="$TAB"; printf '%s' "${*:11}")"      # the last field may itself contain tabs
  rows=$((rows+1))
  quiet=$(( now - ${activity:-$now} )); [ $quiet -lt 0 ] && quiet=0
  if [ "${dead:-1}" = 1 ]; then state=dead
  elif [ "$SAMPLE" -gt 0 ]; then
    if [ "${before[$name]:-}" != "$(screen_text "$name" | md5sum)" ]; then state=busy; else state=idle; fi
  elif [ $quiet -lt "$QUIET" ]; then state=busy
  else state=idle; fi
  short="${name#"$prefix"}"; repo="${tag_repo:-$(repo_of_path "$path")}"
  if [ $JSON = 1 ]; then
    [ $first = 1 ] || printf ','; first=0
    printf '{"session":"%s","tmux":"%s","repo":%s,"branch":%s,"state":"%s","cmd":"%s","quiet_s":%s,"agent":%s,"orchestrator":%s,"last_report":%s,"title":%s}' \
      "$short" "$name" "$(json_str "$repo")" "$(json_str "$branch")" "$state" "$cmd" "$quiet" "$(json_str "$agent")" "$(json_str "$orch")" "$(json_str "$last")" "$(json_str "$title")"
  elif [ $ALL = 1 ]; then
    [ $rows = 1 ] && printf '%-5s %6s  %-32s %-52s %-8s %-42s %-26s %s\n' STATE QUIET REPO SESSION AGENT ORCHESTRATOR LAST-REPORT TITLE
    printf '%-5s %5ss  %-32s %-52s %-8s %-42s %-26s %s\n' "$state" "$quiet" "$(printf %s "${repo/#$HOME\//}" | cut -c1-32)" "$short" "$agent" "$(printf %s "$orch" | cut -c1-42)" "$last" "$(printf %s "$title" | cut -c1-40)"
  else
    [ $rows = 1 ] && printf '%-5s %6s  %-40s %-8s %-42s %-26s %s\n' STATE QUIET SESSION AGENT ORCHESTRATOR LAST-REPORT TITLE
    printf '%-5s %5ss  %-40s %-8s %-42s %-26s %s\n' "$state" "$quiet" "$short" "$agent" "$(printf %s "$orch" | cut -c1-42)" "$last" "$(printf %s "$title" | cut -c1-40)"
  fi
done < <(tmux_on "" list-panes -a -F "$FORMAT" 2>/dev/null | grep -E "$pattern" || true)
[ $JSON = 1 ] && printf ']\n'
if [ $rows = 0 ] && [ $JSON = 0 ]; then
  if [ $ALL = 1 ]; then echo "no player sessions on this machine"; else echo "no sessions with prefix $prefix (repo $(repo_root)); --all lists every repo's"; fi
fi
exit 0
