#!/usr/bin/env bash
# Type text into a session and press Enter — answer a question, add a follow-up, nudge.
# Text is prefixed "[orchestrator] " so the player knows it is not the user speaking;
# --raw sends it verbatim (e.g. a menu choice like "1" or "y").
#
# Usage: send.sh <session> [--repo <path>] <text…>
#        send.sh <session> [--repo <path>] --raw <text…>
#        send.sh <session> [--repo <path>] --key <tmux key>     e.g. Escape, C-c, Enter, Up
#        send.sh <session> [--repo <path>] --type <text…>       typed literally, not pasted:
#                                                               for slash commands (/reload-skills)
# The session is a branch (resolved in this repo, --repo, or uniquely across repos) or an exact
# tmux session name of a tagged player; never a prefix, never a session without the tags. Long
# text is fine: it is pasted from a buffer, not passed on the tmux command line.
. "$(dirname "$(realpath "$0")")/_lib.sh"
[ $# -ge 2 ] || { sed -n '2,13p' "$0" >&2; exit 2; }
session="$1"; shift
if [ "${1:-}" = "--repo" ]; then ORCH_REPO="$2"; shift 2; fi
[ $# -ge 1 ] || { sed -n '2,13p' "$0" >&2; exit 2; }
target="$(resolve_session "$session")" || exit 1
session_exists "$target" || exit 1
tt="$(tmux_target "$target")"
if [ "$1" = "--key" ]; then tmux send-keys -t "$tt" "$2"; exit; fi
if [ "$1" = "--type" ]; then shift; tmux send-keys -t "$tt" -l "$*" && sleep 0.3 && tmux send-keys -t "$tt" Enter && echo "typed into $target"; exit; fi
if [ "$1" = "--raw" ]; then shift; msg="$*"; else msg="[orchestrator] $*"; fi
# Bracketed paste keeps multi-line text as one message; the pause before Enter lets a slow UI
# ingest the paste so the newline is not folded into it.
paste_into "$target" "$msg" || { echo "send.sh: could not paste into $target" >&2; exit 1; }
echo "sent to $target"
