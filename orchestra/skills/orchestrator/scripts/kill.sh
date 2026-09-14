#!/usr/bin/env bash
# Kill ONE named player session's tmux session (its agent). Leaves the worktree and branch
# alone — remove those with `git worktree remove` (and `git branch -d`) after the PR merges.
# Refuses anything that is not a single player session (kirby-<key>-<name>, any repo);
# the user's own terminal sessions (kirby-term-shell-*) are never touched. Names match
# exactly: "feature" never kills "feature-2". A task prompt buffer the launcher never consumed
# (orchestra-prompt-<session>) is deleted with the session so nothing stays on the server.
#
# Usage: kill.sh <session> [--repo <path>]
. "$(dirname "$(realpath "$0")")/_lib.sh"
[ $# -ge 1 ] || { sed -n '2,9p' "$0" >&2; exit 2; }
session="$1"; shift
if [ "${1:-}" = "--repo" ]; then ORCH_REPO="$2"; shift 2; fi
[ $# -eq 0 ] || { sed -n '2,9p' "$0" >&2; exit 2; }
target="$(resolve_session "$session")" || exit 1
is_player_session "$target" || { echo "kill.sh: $target is not a player session" >&2; exit 1; }
session_exists "$target" || exit 1
tmux kill-session -t "=$target" && echo "killed $target"
tmux delete-buffer -b "$(prompt_buffer_name "$target")" 2>/dev/null; true
