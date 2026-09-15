#!/usr/bin/env bash
# Kill ONE player session's tmux session (its agent). Leaves the worktree and branch alone —
# remove those with `git worktree remove` (and `git branch -d`) after the PR merges.
# <session> is a branch (resolved in this repo, --repo, or uniquely across repos) or an exact
# tmux session name. Only a session whose tags say it is a player (@orchestra-spawner set,
# @orchestra-session-type worktree) is killed; a session that merely wears such a name, the
# user's own terminals and Kirby's shell/agent tabs are refused. A task prompt buffer the
# launcher never consumed (orchestra-prompt-<session>) is deleted with the session so nothing
# stays on the server.
#
# Usage: kill.sh <session> [--repo <path>]
. "$(dirname "$(realpath "$0")")/_lib.sh"
[ $# -ge 1 ] || { sed -n '2,11p' "$0" >&2; exit 2; }
session="$1"; shift
if [ "${1:-}" = "--repo" ]; then ORCH_REPO="$2"; shift 2; fi
[ $# -eq 0 ] || { sed -n '2,11p' "$0" >&2; exit 2; }
target="$(resolve_session "$session")" || exit 1
is_player_session "$target" || { echo "kill.sh: $target is not a player session (its tags do not say $TAG_SPAWNER + $TAG_SESSION_TYPE $SESSION_TYPE_WORKTREE); nothing killed" >&2; exit 1; }
session_exists "$target" || exit 1
tmux kill-session -t "=$target" || { echo "kill.sh: tmux could not kill $target" >&2; exit 1; }
tmux delete-buffer -b "$(prompt_buffer_name "$target")" 2>/dev/null || :
echo "killed $target"
