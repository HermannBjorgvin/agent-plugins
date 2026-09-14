#!/usr/bin/env bash
# Send one message to the orchestrator as `[player <name>] KIND: text`.
#
# Usage: report.sh PROGRESS|QUESTION|BLOCKED|DONE <text…>
#        report.sh --orchestrator          print the current reporting target
#
# The target (codex:<thread-id> or tmux:<session>) is the @orchestra-orchestrator tag on this
# player's own tmux session, set by spawn.sh and adopt.sh; a player cannot change it. The
# session and the socket of the server holding it come from ORCHESTRA_SESSION and
# ORCHESTRA_SOCKET (injected by spawn.sh; the pane's own tmux environment points at a scratch
# server, so every call here passes -S). No file is read or written.
# Delivery is reported only when the transport accepted the message; then @orchestra-last-report
# is set to "<KIND> <ISO-8601 UTC>". A refused message is appended to @orchestra-undelivered on the
# player's session and the exit status is nonzero; if even that tag cannot be written, the message
# is echoed to stderr and marked NOT RECORDED. Nothing retries.
set -eu
. "$(dirname "$(realpath "$0")")/_routing.sh"
name="${ORCHESTRA_PLAYER:-$(basename "$(pwd)")}"
session="${ORCHESTRA_SESSION:-}"; sock="${ORCHESTRA_SOCKET:-}"
if [ "${1:-}" = "--orchestrator" ]; then
  [ $# -eq 1 ] || { echo 'report.sh: the reporting target is the @orchestra-orchestrator tag on this session, set by spawn.sh and adopt.sh; a player cannot rebind itself' >&2; exit 2; }
  [ -n "$session" ] || { echo 'report.sh: ORCHESTRA_SESSION is not set; not running in a player pane' >&2; exit 2; }
  target="$(tag_get "$sock" "$session" "$TAG_ORCHESTRATOR")"; printf '%s\n' "${target:-<unset>}"; exit
fi
[ $# -ge 2 ] || { sed -n '2,16p' "$0" >&2; exit 2; }
kind="$1"; shift
case "$kind" in PROGRESS|QUESTION|BLOCKED|DONE) ;; *) echo "report.sh: KIND must be PROGRESS, QUESTION, BLOCKED or DONE" >&2; exit 2;; esac
msg="[player $name] $kind: $*"
# Called after a failed send. Records when it can and says exactly what happened; never retries.
fallback() {
  if [ -n "$session" ] && record_undelivered "$sock" "$session" "$msg" 2>/dev/null; then
    echo "report.sh: NOT DELIVERED ($1); recorded on session $session in $TAG_UNDELIVERED" >&2
  else
    echo "report.sh: NOT DELIVERED ($1) and NOT RECORDED (no player session tag reachable). The message was:" >&2
    printf '%s\n' "$msg" >&2
  fi
  exit 1
}
delivered() {
  tag_set "$sock" "$session" "$TAG_LAST_REPORT" "$kind $(date -u +%Y-%m-%dT%H:%M:%SZ)" 2>/dev/null ||
    echo "report.sh: delivered, but could not set $TAG_LAST_REPORT on $session" >&2
}
[ -n "$session" ] || fallback 'ORCHESTRA_SESSION is not set; not running in a player pane'
target="$(tag_get "$sock" "$session" "$TAG_ORCHESTRATOR")"
# No fallback to CODEX_THREAD_ID: that is the player's own conversation, not its parent.
[ -n "$target" ] || fallback "orchestrator target is not set ($TAG_ORCHESTRATOR on $session)"
target="$(normalize_target "$target" 2>/dev/null)" || fallback "invalid orchestrator target ${target}"
case "$target" in
  codex:*)
    if codex queue --thread "${target#codex:}" --message "$msg"; then delivered; echo "queued for $target"; exit 0; fi
    fallback 'Codex queue refused the message; inspect before retrying to avoid duplicate reports';;
  tmux:*) target="${target#tmux:}";;
esac
t() { tmux_on "$sock" "$@"; }
t has-session -t "=$target" 2>/dev/null || fallback "orchestrator session $target is gone"
# Would the paste be run as a shell command? Only an agent at the terminal may receive it.
pane_owned_by_agent "$sock" "$target" || fallback "a shell owns $target now, not an agent"
# One bracketed paste (-p) keeps embedded newlines from submitting early; the buffer is loaded
# from stdin because tmux rejects command lines over ~16 KiB. The pause lets a slow UI ingest
# the paste before Enter.
tt="$(tmux_target "$target")"
printf '%s' "$msg" | t load-buffer -b "player-$$" - || fallback "tmux could not load the message"
t paste-buffer -p -d -b "player-$$" -t "$tt" || fallback "tmux could not paste into $target"
sleep 0.3
t send-keys -t "$tt" Enter || fallback "tmux could not submit the message in $target"
delivered
echo "sent to $target"
