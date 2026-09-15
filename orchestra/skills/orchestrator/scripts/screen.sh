#!/usr/bin/env bash
# Print one session's screen as plain text (ANSI stripped by tmux).
#
# Usage: screen.sh <session> [--lines N] [--history N] [--repo <path>]
#   --lines N    only the last N non-blank lines
#   --history N  include N lines of scrollback above the visible screen (a dead pane's
#                last output often sits just above the screen, so dead panes default to 40)
#   --repo P     resolve a branch in that repo (an exact session name needs no repo)
. "$(dirname "$(realpath "$0")")/_lib.sh"
[ $# -ge 1 ] || { sed -n '2,8p' "$0" >&2; exit 2; }
session="$1"; shift
LINES=0; HISTORY=0
while [ $# -gt 0 ]; do case "$1" in
  --lines) LINES="$2"; shift;; --history) HISTORY="$2"; shift;; --repo) ORCH_REPO="$2"; shift;;
  *) echo "screen.sh: unknown argument $1" >&2; exit 2;; esac; shift; done
target="$(resolve_session "$session")" || exit 1
session_exists "$target" || exit 1
[ "$HISTORY" -gt 0 ] || [ "$(tmux_on "" display-message -p -t "$(tmux_target "$target")" '#{pane_dead}')" != 1 ] || HISTORY=40
text="$(tmux capture-pane -p -t "$(tmux_target "$target")" -S "-$HISTORY" | sed -e 's/[[:space:]]*$//' | awk 'NF{blank=0} !NF{blank++} blank<2')"
if [ "$LINES" -gt 0 ]; then printf '%s\n' "$text" | grep -v '^\s*$' | tail -n "$LINES"; else printf '%s\n' "$text"; fi
