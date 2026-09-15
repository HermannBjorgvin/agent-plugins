#!/usr/bin/env bash
# List player tmux sessions with a cheap, harness-neutral state and the session's tags.
#
#   busy   the pane wrote output within the last QUIET seconds
#   idle   quiet for QUIET+ seconds: at a prompt, asking a question, or finished
#   dead   the pane's command has exited
#
# A player is a session tagged @orchestra-spawner (any value), @orchestra-repo and
# @orchestra-session-type worktree, whoever created it; sessions missing any of these and
# Kirby's shell/agent tabs are never listed.
# Scope: players whose @orchestra-repo is this repo (--repo <path>, else the cwd's repo) when
# the cwd is inside a git repo; every player on the machine (--all) otherwise. --all adds a
# REPO column (the @orchestra-repo tag value, cut to 40 characters like SESSION; --json has
# both whole). SESSION is the tmux session name (a label, which every other script accepts);
# BRANCH, AGENT, ORCHESTRATOR and LAST-REPORT come from the @orchestra-branch, -agent,
# -orchestrator and -last-report tags (empty when unset). --json gives "session" and "name"
# (both the tmux name), "repo", "branch", "state", "cmd", "quiet_s", "agent", "orchestrator",
# "last_report" and "title". Everything comes from one tmux list-panes call.
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
  -h|--help) sed -n '2,26p' "$0"; exit 0;;
  *) echo "sessions.sh: unknown argument $1" >&2; exit 0;; esac; shift; done
command -v tmux >/dev/null || { echo "tmux is not installed"; exit 0; }

in_repo || ALL=1
scope=""; [ $ALL = 1 ] || scope="$(repo_root)"
# A row is in scope when its tags say player (spawner, repo, session-type worktree) and, unless
# --all, its repo tag equals this repo.
in_scope() { [ -n "$1" ] && [ "$2" = "$SESSION_TYPE_WORKTREE" ] && [ -n "$3" ] && { [ $ALL = 1 ] || [ "$3" = "$scope" ]; }; }
declare -A before
if [ "$SAMPLE" -gt 0 ]; then
  while IFS= read -r n; do before[$n]="$(screen_text "=$n:" | md5sum)"; done < <(all_player_sessions)
  sleep "$SAMPLE"
fi

# Fields are tab-separated (tag values never contain a tab; the title comes last so it may). A
# whitespace IFS makes `read` collapse the empty fields of unset tags, so lines are split by hand.
FORMAT="#{session_name}${TAB}#{pane_dead}${TAB}#{pane_current_command}${TAB}#{window_activity}${TAB}#{$TAG_AGENT}${TAB}#{$TAG_ORCHESTRATOR}${TAB}#{$TAG_LAST_REPORT}${TAB}#{$TAG_REPO}${TAB}#{$TAG_BRANCH}${TAB}#{$TAG_SPAWNER}${TAB}#{$TAG_SESSION_TYPE}${TAB}#{pane_title}"
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
  name="${1:-}"; dead="${2:-}"; cmd="${3:-}"; activity="${4:-}"; agent="${5:-}"; orch="${6:-}"; last="${7:-}"; tag_repo="${8:-}"; branch="${9:-}"; spawner="${10:-}"; type="${11:-}"
  title="$(IFS="$TAB"; printf '%s' "${*:12}")"      # the last field may itself contain tabs
  in_scope "$spawner" "$type" "$tag_repo" || continue
  rows=$((rows+1))
  quiet=$(( now - ${activity:-$now} )); [ $quiet -lt 0 ] && quiet=0
  if [ "${dead:-1}" = 1 ]; then state=dead
  elif [ "$SAMPLE" -gt 0 ]; then
    if [ "${before[$name]:-}" != "$(screen_text "=$name:" | md5sum)" ]; then state=busy; else state=idle; fi
  elif [ $quiet -lt "$QUIET" ]; then state=busy
  else state=idle; fi
  repo="$tag_repo"
  if [ $JSON = 1 ]; then
    [ $first = 1 ] || printf ','; first=0
    printf '{"session":%s,"name":%s,"repo":%s,"branch":%s,"state":%s,"cmd":%s,"quiet_s":%s,"agent":%s,"orchestrator":%s,"last_report":%s,"title":%s}' \
      "$(json_str "$name")" "$(json_str "$name")" "$(json_str "$repo")" "$(json_str "$branch")" "$(json_str "$state")" "$(json_str "$cmd")" "$quiet" "$(json_str "$agent")" "$(json_str "$orch")" "$(json_str "$last")" "$(json_str "$title")"
  elif [ $ALL = 1 ]; then
    [ $rows = 1 ] && printf '%-5s %6s  %-40s %-40s %-32s %-8s %-42s %-26s %s\n' STATE QUIET REPO SESSION BRANCH AGENT ORCHESTRATOR LAST-REPORT TITLE
    printf '%-5s %5ss  %-40s %-40s %-32s %-8s %-42s %-26s %s\n' "$state" "$quiet" "$(printf %s "$repo" | cut -c1-40)" "$(printf %s "$name" | cut -c1-40)" "$(printf %s "$branch" | cut -c1-32)" "$agent" "$(printf %s "$orch" | cut -c1-42)" "$last" "$(printf %s "$title" | cut -c1-40)"
  else
    [ $rows = 1 ] && printf '%-5s %6s  %-40s %-32s %-8s %-42s %-26s %s\n' STATE QUIET SESSION BRANCH AGENT ORCHESTRATOR LAST-REPORT TITLE
    printf '%-5s %5ss  %-40s %-32s %-8s %-42s %-26s %s\n' "$state" "$quiet" "$(printf %s "$name" | cut -c1-40)" "$(printf %s "$branch" | cut -c1-32)" "$agent" "$(printf %s "$orch" | cut -c1-42)" "$last" "$(printf %s "$title" | cut -c1-40)"
  fi
done < <(tmux_on "" list-panes -a -F "$FORMAT" 2>/dev/null || true)
[ $JSON = 1 ] && printf ']\n'
if [ $rows = 0 ] && [ $JSON = 0 ]; then
  if [ $ALL = 1 ]; then echo "no player sessions on this machine"; else echo "no player sessions tagged for repo $scope; --all lists every repo's"; fi
fi
exit 0
