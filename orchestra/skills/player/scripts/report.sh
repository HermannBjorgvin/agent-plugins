#!/usr/bin/env bash
# Send one message to a Codex thread or the orchestrator's tmux session as `[player <name>] KIND: text`.
#
# Usage: report.sh PROGRESS|QUESTION|BLOCKED|DONE <text…>
#        report.sh --orchestrator <target> [--socket PATH]   bind future reports to that target
#        report.sh --orchestrator                             print the current binding
#
# Targets: codex:<thread-id> or tmux:<session>; a bare name is a legacy tmux session.
# The binding lives in this worktree's git directory and wins over ORCHESTRATOR_TARGET and
# legacy ORCHESTRATOR_SESSION; outside a git worktree only the environment applies and no
# binding is written (a global binding would silently route unrelated players).
# Delivery is reported only when the transport accepted the message. A failed send is saved
# to ORCHESTRATOR_MAIL_DIR or ~/.claude/orchestrator-mail when possible; if even that fails,
# the message is echoed to stderr and marked NOT SAVED. Exit is nonzero in both cases.
set -eu
. "$(dirname "$(realpath "$0")")/_routing.sh"
name="${PLAYER_NAME:-$(basename "$(pwd)")}"
binding=""
if gitdir="$(git rev-parse --absolute-git-dir 2>/dev/null)"; then binding="$gitdir/player-orchestrator"; fi
if [ "${1:-}" = "--orchestrator" ]; then
  if [ -n "${2:-}" ]; then
    target="$(normalize_target "$2")" || exit 2
    [ -n "$binding" ] || { echo 'report.sh: not inside a git worktree; the binding is only persisted per worktree (set ORCHESTRATOR_TARGET instead)' >&2; exit 2; }
    socket="${ORCHESTRATOR_TMUX_SOCKET:-/tmp/tmux-$(id -u)/default}"
    if [ -s "$binding" ] && [ "$(normalize_target "$(head -n1 "$binding")" 2>/dev/null || true)" = "$target" ]; then
      bound_socket="$(sed -n '2p' "$binding")"; socket="${bound_socket:-$socket}"
    fi
    if [ "${3:-}" = --socket ]; then socket="$4"; elif [ $# -gt 2 ]; then echo 'unexpected binding arguments' >&2; exit 2; fi
    # One atomic file carries both destination and socket. Legacy one-line bindings still work.
    temporary="$(mktemp "${binding}.XXXXXX")" || { echo "report.sh: cannot write $binding" >&2; exit 1; }
    printf '%s\n%s\n' "$target" "$socket" > "$temporary" && mv "$temporary" "$binding" || { rm -f "$temporary"; echo "report.sh: cannot write $binding" >&2; exit 1; }
    echo "reports now go to $target ($binding)"; exit
  fi
  if [ -n "$binding" ] && [ -s "$binding" ]; then head -n1 "$binding"; else printf '%s\n' "${ORCHESTRATOR_TARGET:-${ORCHESTRATOR_SESSION:-<unset>}}"; fi
  exit
fi
[ $# -ge 2 ] || { sed -n '2,15p' "$0" >&2; exit 2; }
kind="$1"; shift
case "$kind" in PROGRESS|QUESTION|BLOCKED|DONE) ;; *) echo "report.sh: KIND must be PROGRESS, QUESTION, BLOCKED or DONE" >&2; exit 2;; esac
msg="[player $name] $kind: $*"
target="${ORCHESTRATOR_TARGET:-${ORCHESTRATOR_SESSION:-}}"
sock="${ORCHESTRATOR_TMUX_SOCKET:-/tmp/tmux-$(id -u)/default}"
if [ -n "$binding" ] && [ -s "$binding" ]; then
  target="$(head -n1 "$binding")"
  bound_socket="$(sed -n '2p' "$binding")"
  sock="${bound_socket:-$sock}"
fi
# No fallback to CODEX_THREAD_ID: that is the player's own conversation, not its parent.
mail_dir="${ORCHESTRATOR_MAIL_DIR:-$HOME/.claude/orchestrator-mail}"
mail_key="$(printf '%s' "${target:-unknown}" | tr -c 'a-zA-Z0-9_-' '_')"
mailbox="$mail_dir/$mail_key.log"
# Called after a failed send. Saves when it can and says exactly what happened; never retries.
fallback() {
  if mkdir -p "$mail_dir" 2>/dev/null && printf '%s  %s\n' "$(date -Is)" "$msg" >> "$mailbox" 2>/dev/null; then
    echo "report.sh: NOT DELIVERED ($1); saved in $mailbox" >&2
  else
    echo "report.sh: NOT DELIVERED ($1) and NOT SAVED (cannot write $mailbox). The message was:" >&2
    printf '%s\n' "$msg" >&2
  fi
  exit 1
}
[ -n "$target" ] || fallback 'orchestrator target is not set'
target="$(normalize_target "$target" 2>/dev/null)" || fallback "invalid orchestrator target ${target}"
case "$target" in
  codex:*)
    if codex queue --thread "${target#codex:}" --message "$msg"; then echo "queued for $target"; exit 0; fi
    fallback 'Codex queue refused the message; inspect before retrying to avoid duplicate reports';;
  tmux:*) target="${target#tmux:}";;
esac
t() { tmux -S "$sock" "$@"; }
t has-session -t "=$target" 2>/dev/null || fallback "orchestrator session $target is gone"
# Would the paste be run as a shell command? Only an agent at the terminal may receive it.
pane_owned_by_agent tmux -S "$sock" "$target" || fallback "a shell owns $target now, not an agent"
# One bracketed paste (-p) keeps embedded newlines from submitting early; the buffer is loaded
# from stdin because tmux rejects command lines over ~16 KiB. The pause lets a slow UI ingest
# the paste before Enter.
tt="$(tmux_target "$target")"
printf '%s' "$msg" | t load-buffer -b "player-$$" - || fallback "tmux could not load the message"
t paste-buffer -p -d -b "player-$$" -t "$tt" || fallback "tmux could not paste into $target"
sleep 0.3
t send-keys -t "$tt" Enter || fallback "tmux could not submit the message in $target"
echo "sent to $target"
