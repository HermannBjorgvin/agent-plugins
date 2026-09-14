#!/usr/bin/env bash
# Adopt a running player: rebind its reports to an orchestrator and type the player skill
# invocation into its pane. Without trailing text the player treats it as a handoff and
# answers with a PROGRESS summary (or repeats DONE); with text, the text becomes its new task.
#
# Usage: adopt.sh <session> [--repo PATH] [--orchestrator codex:<thread-id>|tmux:<session>]
#                 [--agent claude|codex|...] [<text…>]
# Inspect screen.sh first and adopt only players idle at their input prompt. The pane must be
# alive with an agent (not a shell) at the terminal, and its directory must be a git worktree;
# otherwise nothing is rebound or typed. Old sessions without @player-agent default to Claude.
set -eu
. "$(dirname "$(realpath "$0")")/_lib.sh"
[ $# -ge 1 ] || { sed -n '2,10p' "$0" >&2; exit 2; }
session="$1"; shift; ORCH=""; AGENT=""
while [ $# -gt 0 ]; do case "$1" in
  --repo) ORCH_REPO="$2"; shift;; --orchestrator) ORCH="$2"; shift;;
  --agent) AGENT="$2"; shift;; --*) echo "adopt.sh: unknown argument $1" >&2; exit 2;; *) break;; esac; shift; done
TEXT="$*"
ORCH="$(resolve_orchestrator "$ORCH")" || exit 2
target="$(resolve_session "$session")" || exit 1
is_player_session "$target" || { echo "adopt.sh: $target is not a player session" >&2; exit 1; }
session_exists "$target" || exit 1
tt="$(tmux_target "$target")"
[ "$(tmux display-message -p -t "$tt" '#{pane_dead}')" = 0 ] || { echo "adopt.sh: $target has a dead pane; use spawn.sh --resume instead" >&2; exit 1; }
pane_owned_by_agent tmux "$target" || { echo "adopt.sh: no agent is reading $target (a shell owns the pane); nothing rebound" >&2; exit 1; }
[ -n "$AGENT" ] || AGENT="$(tmux show-options -v -t "$tt" @player-agent 2>/dev/null || true)"
case "${AGENT:-claude}" in codex) invocation='$orchestra:player';; *) invocation="$(claude_player_invocation)";; esac
worktree="$(tmux display-message -p -t "$tt" '#{pane_current_path}')"
git -C "$worktree" rev-parse --absolute-git-dir >/dev/null 2>&1 || { echo "adopt.sh: $worktree is not a git worktree; nothing rebound" >&2; exit 1; }
# The socket that reaches this orchestrator's tmux server: the one we are talking to now.
socket="$(tmux display-message -p -t "$tt" '#{socket_path}')"
report_script="$(realpath "$PLAYER_SCRIPTS/report.sh")"
(cd "$worktree" && bash "$report_script" --orchestrator "$ORCH" --socket "$socket")
msg="$invocation $ORCH${TEXT:+ $TEXT}"
# A slash/dollar invocation must start the input line. Single-line text is typed literally;
# multi-line text is pasted as one bracketed block so embedded newlines do not submit early.
case "$msg" in
  *$'\n'*) paste_into "$target" "$msg";;
  *) tmux send-keys -t "$tt" -l "$msg"; sleep 0.3; tmux send-keys -t "$tt" Enter;;
esac
echo "adopted $target -> reports to $ORCH${TEXT:+ (new task sent)}${TEXT:- (expect a PROGRESS handoff report)}"
