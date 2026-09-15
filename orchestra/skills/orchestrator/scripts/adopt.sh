#!/usr/bin/env bash
# Adopt a running player: point its reports at an orchestrator and type the player skill
# invocation into its pane. Without trailing text the player treats it as a handoff and
# answers with a PROGRESS summary (or repeats DONE); with text, the text becomes its new task.
#
# Usage: adopt.sh <session> [--repo PATH] [--orchestrator codex:<thread-id>|tmux:<session>]
#                 [--agent claude|codex|...] [<text…>]
# Inspect screen.sh first and adopt only players idle at their input prompt. The pane must be
# alive with an agent (not a shell) at the terminal; otherwise nothing is changed or typed.
# <session> is a branch (resolved in this repo, --repo, or uniquely across repos) or an exact
# tmux session name; only a session tagged as a player (@orchestra-spawner set,
# @orchestra-session-type worktree) is adopted, whoever created it. The target is written to the
# session's @orchestra-orchestrator tag, which report.sh reads; the player's own ORCHESTRA_SOCKET
# already names this server. Sessions without an @orchestra-agent tag default to Claude.
set -eu
. "$(dirname "$(realpath "$0")")/_lib.sh"
[ $# -ge 1 ] || { sed -n '2,14p' "$0" >&2; exit 2; }
session="$1"; shift; ORCH=""; AGENT=""
while [ $# -gt 0 ]; do case "$1" in
  --repo) ORCH_REPO="$2"; shift;; --orchestrator) ORCH="$2"; shift;;
  --agent) AGENT="$2"; shift;; --*) echo "adopt.sh: unknown argument $1" >&2; exit 2;; *) break;; esac; shift; done
TEXT="$*"
ORCH="$(resolve_orchestrator "$ORCH")" || exit 2
target="$(resolve_session "$session")" || exit 1
is_player_session "$target" || { echo "adopt.sh: $target is not a player session (its tags do not say $TAG_SPAWNER + $TAG_SESSION_TYPE $SESSION_TYPE_WORKTREE); nothing changed" >&2; exit 1; }
session_exists "$target" || exit 1
tt="$(tmux_target "$target")"
[ "$(tmux_on "" display-message -p -t "$tt" '#{pane_dead}')" = 0 ] || { echo "adopt.sh: $target has a dead pane; use spawn.sh --resume instead" >&2; exit 1; }
pane_owned_by_agent "" "$target" || { echo "adopt.sh: no agent is reading $target (a shell owns the pane); nothing changed" >&2; exit 1; }
[ -n "$AGENT" ] || AGENT="$(tag_get "" "$target" "$TAG_AGENT")"
case "${AGENT:-claude}" in codex) invocation='$player';; *) invocation="$(claude_player_invocation)";; esac
tag_set "" "$target" "$TAG_ORCHESTRATOR" "$ORCH" || { echo "adopt.sh: could not set $TAG_ORCHESTRATOR on $target" >&2; exit 1; }
msg="$invocation${TEXT:+ $TEXT}"
# A slash/dollar invocation must start the input line. Single-line text is typed literally;
# multi-line text is pasted as one bracketed block so embedded newlines do not submit early.
case "$msg" in
  *$'\n'*) paste_into "$target" "$msg";;
  *) tmux send-keys -t "$tt" -l "$msg"; sleep 0.3; tmux send-keys -t "$tt" Enter;;
esac
echo "adopted $target -> reports to $ORCH${TEXT:+ (new task sent)}${TEXT:- (expect a PROGRESS handoff report)}"
